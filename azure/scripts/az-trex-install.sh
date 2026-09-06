#!/usr/bin/env bash
#
# trex-install.sh
# Bootstrap script for: TRex Installation Runbook Azure VM, Ubuntu 22.04, MANA NICs
#
# Usage:
#   sudo ./trex-install.sh [data_nic1] [data_nic2]
#     data_nic1/2 default to eth1 / eth2 if not given.

set -euo pipefail

DATA_NIC1="${1:-eth1}"
DATA_NIC2="${2:-eth2}"
MGMT_NIC="eth0"
TREX_DIR="${TREX_DIR:-/opt/trex-core}"
TREX_CFG="/etc/trex_cfg.yaml"
IMDS_URL="http://169.254.169.254/metadata/instance/network?api-version=2021-02-01"
LOG_FILE="/var/log/trex-install.log"

# Authoritative definition of which NIC is which. Port 0 == SOURCE_IP,
# port 1 == DEST_IP. Everything downstream keys off these two constants and
# not off interface names
SOURCE_IP="${SOURCE_IP:-10.10.1.10}"
DEST_IP="${DEST_IP:-10.10.2.10}"

exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "\n===> $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

# Normalise a MAC to lowercase colon-separated form, so MACs from different
# sources (sysfs, ip -br link, vdev UUID suffix) compare reliably.
norm_mac() {
  local raw="${1//[:-]/}"
  raw="${raw,,}"
  [[ "${#raw}" -eq 12 ]] || return 1
  echo "${raw:0:2}:${raw:2:2}:${raw:4:2}:${raw:6:2}:${raw:8:2}:${raw:10:2}"
}

if [[ $EUID -ne 0 ]]; then
  die "run this as root (sudo ./trex-install.sh)"
fi

log "Starting TRex/MANA install bootstrap. Logging to $LOG_FILE"

# ---------------------------------------------------------------------------
# Step 2: Verify interfaces after boot
# ---------------------------------------------------------------------------
log "Step 2: Verifying NIC drivers"


# MANA (like other Azure accelerated-networking VFs) attaches as a second,
# hidden interface "mastered by" the visible eth1/eth2 (which itself always
# stays on hv_netvsc). Resolve that VF interface name here so the rest of
# the script (driver check, bus-info, MAC) operates on the right device.
get_vf_ifname() {
  local primary="$1"
  ip -br link show master "$primary" 2>/dev/null | awk '{print $1}' | head -1
}

check_data_nic() {
  local nic="$1"
  if ! ip a show "$nic" &>/dev/null; then
    die "interface $nic not found — pass correct data NIC names as args"
  fi

  local vf
  vf=$(get_vf_ifname "$nic")
  if [[ -z "$vf" ]]; then
    die "$nic has no enslaved VF interface (checked 'ip -br link show master $nic'). Accelerated networking may not be attached yet — check the NIC's setting in the Azure portal, or wait ~30s after boot and retry."
  fi

  local drv
  drv=$(ethtool -i "$vf" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')
  if [[ "$drv" != "mana" ]]; then
    die "$nic's VF interface ($vf) driver is '$drv', expected 'mana'."
  fi
  if ! lspci | grep -qi microsoft; then
    die "no Microsoft Corporation device found in lspci — MANA VF may not be attached yet"
  fi
  echo "  $nic: VF=$vf driver=mana OK"
}

check_mgmt_nic() {
  local drv
  drv=$(ethtool -i "$MGMT_NIC" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')
  if [[ "$drv" != "hv_netvsc" ]]; then
    die "$MGMT_NIC driver is '$drv', expected 'hv_netvsc'"
  fi
  echo "  $MGMT_NIC: driver=hv_netvsc OK"
}

check_data_nic "$DATA_NIC1"
check_data_nic "$DATA_NIC2"
check_mgmt_nic

# ---------------------------------------------------------------------------
# Step 3: Build toolchain
# ---------------------------------------------------------------------------
log "Step 3: Installing build toolchain"
apt-get update -y
apt-get install -y build-essential binutils python3 python3-distutils python3-venv zlib1g-dev git pkg-config curl

# ---------------------------------------------------------------------------
# Step 4: RDMA/verbs packages
# ---------------------------------------------------------------------------
log "Step 4: Installing RDMA/verbs packages"
apt-get install -y libibverbs-dev librdmacm-dev libnuma-dev libmnl-dev ibverbs-utils rdma-core

log "Loading mana_ib module if needed"
if ! lsmod | grep -q '^mana_ib'; then
  modprobe mana_ib
fi
lsmod | grep mana || die "mana_ib failed to load"

log "Checking ibv_devinfo"
if ! ibv_devinfo 2>/dev/null | grep -q "hca_id"; then
  echo "  ibv_devinfo found no devices — likely rdma-core < v44. Pulling backports PPA."
  add-apt-repository -y ppa:canonical-server/server-backports
  apt-get update -y
  apt-get install -y --only-upgrade rdma-core libibverbs1 libibverbs-dev librdmacm-dev

  RDMA_VER=$(dpkg -l | awk '/rdma-core/{print $3}' | head -1)
  echo "  rdma-core version now: $RDMA_VER"

  if ! ibv_devinfo 2>/dev/null | grep -q "hca_id"; then
    die "still no IB devices after backports upgrade — investigate manually before continuing"
  fi
fi
echo "  ibv_devinfo: MANA verbs device(s) present"

log "Mapping HCAs to interface names (ibdev2netdev) — informational, config generation below uses MAC/bus-info directly"
if command -v ibdev2netdev &>/dev/null; then
  ibdev2netdev
else
  echo "  WARNING: ibdev2netdev not found on PATH"
fi

log "Checking kernel version (DPDK on MANA needs 6.14+, or a backport of the Ethernet/InfiniBand drivers)"
echo "  Running kernel: $(uname -r)"
KVER_MAJOR=$(uname -r | cut -d. -f1)
KVER_MINOR=$(uname -r | cut -d. -f2)
if (( KVER_MAJOR < 6 || (KVER_MAJOR == 6 && KVER_MINOR < 14) )); then
  echo "  WARNING: kernel is below 6.14 and may lack the required MANA DPDK backport."
  echo "  This can cause probe failures later even if everything else here succeeds."
  echo "  Continuing, but if t-rex fails to start, check for an HWE kernel with the backport."
fi

# ---------------------------------------------------------------------------
# Step 5: Download TRex source (master branch tarball — not a tagged release)
# ---------------------------------------------------------------------------
# Tarball via codeload.github.com instead of `git clone`
log "Step 5: Downloading TRex source (master branch tarball)"

TREX_TARBALL_URL="https://github.com/cisco-system-traffic-generator/trex-core/archive/refs/heads/master.tar.gz"
mkdir -p "$TREX_DIR"
rm -rf "$TREX_DIR/.git"  # stale git metadata from a previous git-clone-based install, if any

curl -fsSL "$TREX_TARBALL_URL" -o /tmp/trex-core.tar.gz \
  || die "failed to download $TREX_TARBALL_URL"

tar -xzf /tmp/trex-core.tar.gz -C "$TREX_DIR" --strip-components=1
rm -f /tmp/trex-core.tar.gz
cd "$TREX_DIR"

TREX_COMMIT_INFO=$(curl -fsSL "https://api.github.com/repos/cisco-system-traffic-generator/trex-core/commits/master" || true)
if [[ -n "$TREX_COMMIT_INFO" ]]; then
  TREX_SHA=$(echo "$TREX_COMMIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha','?')[:7])" 2>/dev/null || echo "?")
  TREX_DATE=$(echo "$TREX_COMMIT_INFO" | python3 -c "import json,sys; print(json.load(sys.stdin).get('commit',{}).get('author',{}).get('date','?')[:10])" 2>/dev/null || echo "?")
  echo "  Downloaded master @ $TREX_SHA ($TREX_DATE)"
else
  echo "  Downloaded master (commit info lookup failed - not fatal, continuing)"
fi
echo "  NOTE: this is unreleased/unregression-tested code, not a tagged release."

# ---------------------------------------------------------------------------
# Step 6: Configure the build
# ---------------------------------------------------------------------------
log "Step 6: Configuring build"
cd "$TREX_DIR/linux_dpdk"
./b configure --no-ofed-check --with-mana --no-mlx=all | tee /tmp/trex_configure.log
grep -q "'configure' finished successfully" /tmp/trex_configure.log \
  || die "configure did not report success — check /tmp/trex_configure.log"

# ---------------------------------------------------------------------------
# Step 7: Build (with -Werror fallback)
# ---------------------------------------------------------------------------
log "Step 7: Building TRex"
if ! ./b build 2>&1 | tee /tmp/trex_build.log; then
  if grep -q -- '-Werror=' /tmp/trex_build.log; then
    echo "  Build failed on -Werror=*. Patching ws_main.py with -Wno-error and retrying."
    WS_MAIN="$TREX_DIR/linux_dpdk/../ws_main.py"
    if grep -q "gcc_flags = " "$WS_MAIN" 2>/dev/null; then
      sed -i "s/\(gcc_flags = \[.*\)\]/\1, '-Wno-error']/" "$WS_MAIN"
      ./b build || die "build still failing after -Wno-error patch — inspect /tmp/trex_build.log"
    else
      die "could not locate gcc_flags in ws_main.py to patch automatically"
    fi
  else
    die "build failed for a non -Werror reason — inspect /tmp/trex_build.log"
  fi
fi
echo "  Build completed"

# ---------------------------------------------------------------------------
# Step 9a (before Step 8's rebind): resolve IP/gateway via IMDS
# ---------------------------------------------------------------------------
# MAC must be read before azure_mana_trex_setup.sh runs: it unbinds the
# primary interfaces from the kernel, after which "ip -br link show master"
# no longer works on them.
log "Step 9a: Resolving IP/gateway for $DATA_NIC1 / $DATA_NIC2 via Azure IMDS"

# MAC is read the same way Microsoft's own MANA/DPDK reference does: off the
# "master" listing for the primary (visible) interface, not off the VF's own
# sysfs entry. The two normally match, but this is the documented method.
get_master_mac() { ip -br link show master "$1" 2>/dev/null | awk '{print $3}' | head -1; }

MAC1=$(get_master_mac "$DATA_NIC1"); [[ -n "$MAC1" ]] || die "could not read MAC for $DATA_NIC1"
MAC2=$(get_master_mac "$DATA_NIC2"); [[ -n "$MAC2" ]] || die "could not read MAC for $DATA_NIC2"
if [[ "$MAC1" == "$MAC2" ]]; then
  die "MAC addresses for $DATA_NIC1 and $DATA_NIC2 are identical — refusing to continue"
fi
echo "  $DATA_NIC1: mac=$MAC1"
echo "  $DATA_NIC2: mac=$MAC2"

IMDS_JSON=$(curl -s -H "Metadata:true" "$IMDS_URL") || die "IMDS request failed — is this actually an Azure VM?"
[[ -n "$IMDS_JSON" ]] || die "empty response from IMDS"

# Written to its own file rather than fed to `python3 -`
IMDS_RESOLVE_PY="$(mktemp /tmp/trex_imds_resolve.XXXXXX.py)"
cat > "$IMDS_RESOLVE_PY" <<'PYEOF'
import json, sys, ipaddress

mac_target = sys.argv[1]
data = json.load(sys.stdin)

for iface in data.get("interface", []):
    iface_mac = iface.get("macAddress", "").upper()
    if iface_mac != mac_target:
        continue
    ipv4 = iface.get("ipv4", {})
    subnet = ipv4.get("subnet", [{}])[0]
    addr = ipv4.get("ipAddress", [{}])[0].get("privateIpAddress")
    prefix = subnet.get("prefix")
    if not addr or not prefix:
        continue
    net = ipaddress.ip_interface(f"{addr}/{prefix}").network
    gw = str(list(net.hosts())[0]) if net.num_addresses > 2 else str(net.network_address)
    print(f"{addr} {gw}")
    sys.exit(0)

sys.exit(1)
PYEOF

resolve_from_imds() {
  local mac_nocolon
  mac_nocolon=$(echo "$1" | tr -d ':' | tr '[:lower:]' '[:upper:]')
  python3 "$IMDS_RESOLVE_PY" "$mac_nocolon"
}

RESOLVED1=$(echo "$IMDS_JSON" | resolve_from_imds "$MAC1") || die "could not find $DATA_NIC1 (mac=$MAC1) in IMDS network metadata"
RESOLVED2=$(echo "$IMDS_JSON" | resolve_from_imds "$MAC2") || die "could not find $DATA_NIC2 (mac=$MAC2) in IMDS network metadata"
rm -f "$IMDS_RESOLVE_PY"

IP1=$(echo "$RESOLVED1" | awk '{print $1}'); GW1=$(echo "$RESOLVED1" | awk '{print $2}')
IP2=$(echo "$RESOLVED2" | awk '{print $1}'); GW2=$(echo "$RESOLVED2" | awk '{print $2}')

echo "  $DATA_NIC1: ip=$IP1 gateway=$GW1 (gateway = first usable host in subnet, Azure default — check this if you use a custom UDR)"
echo "  $DATA_NIC2: ip=$IP2 gateway=$GW2"

# ---------------------------------------------------------------------------
# Step 9a-2 (Phase H): validate the IP pair, then assign roles by IP
# ---------------------------------------------------------------------------
# Fail closed on infra drift. If the resolved pair isn't exactly {SOURCE_IP, DEST_IP}
log "Step 9a-2: Validating IP pair and assigning port roles"

if [[ "$IP1" == "$IP2" ]]; then
  die "both data NICs resolved to the same IP ($IP1) — IMDS/MAC mapping is wrong, refusing to continue"
fi
for want in "$SOURCE_IP" "$DEST_IP"; do
  if [[ "$IP1" != "$want" && "$IP2" != "$want" ]]; then
    die "expected IP $want on one of the data NICs, but resolved ($IP1, $IP2) — check the attached NICs' subnets and the OpenTofu network module, or override SOURCE_IP/DEST_IP if this VM intentionally uses different addressing"
  fi
done

MAC1_N=$(norm_mac "$MAC1") || die "could not normalise MAC '$MAC1' for $DATA_NIC1"
MAC2_N=$(norm_mac "$MAC2") || die "could not normalise MAC '$MAC2' for $DATA_NIC2"

if [[ "$IP1" == "$SOURCE_IP" ]]; then
  P0_NIC="$DATA_NIC1"; P0_MAC="$MAC1_N"; P0_IP="$IP1"; P0_GW="$GW1"
  P1_NIC="$DATA_NIC2"; P1_MAC="$MAC2_N"; P1_IP="$IP2"; P1_GW="$GW2"
else
  P0_NIC="$DATA_NIC2"; P0_MAC="$MAC2_N"; P0_IP="$IP2"; P0_GW="$GW2"
  P1_NIC="$DATA_NIC1"; P1_MAC="$MAC1_N"; P1_IP="$IP1"; P1_GW="$GW1"
  echo "  NOTE: argument order is reversed relative to the SOURCE_IP/DEST_IP convention."
  echo "        Roles reassigned by IP — this is the fix working as designed, not an error."
fi

echo "  port 0 = $P0_NIC  ip=$P0_IP  gw=$P0_GW  mac=$P0_MAC"
echo "  port 1 = $P1_NIC  ip=$P1_IP  gw=$P1_GW  mac=$P1_MAC"

# ---------------------------------------------------------------------------
# Step 8: Azure MANA setup script (unbinds data NICs, rebinds for DPDK use)
# ---------------------------------------------------------------------------
# This script unbinds each primary interface's vmbus device from hv_netvsc
# and rebinds it to uio_hv_generic, then prints the exact interfaces/
# ext_dpdk_opt/interfaces_vdevs values trex_cfg.yaml needs.
log "Step 8: Running azure_mana_trex_setup.sh"
cd "$TREX_DIR/scripts"
SETUP_LOG="$(mktemp /tmp/azure_mana_setup.XXXXXX.log)"
./azure_mana_trex_setup.sh 2>&1 | tee "$SETUP_LOG"

log "Step 9: Generating $TREX_CFG from azure_mana_trex_setup.sh's own output"

IFACES_LINE=$(grep -E "interfaces:\s*\[" "$SETUP_LOG" | grep -v interfaces_vdevs | tail -1)
VDEVS_LINE=$(grep -E "interfaces_vdevs\s*:" "$SETUP_LOG" | tail -1)

[[ -n "$IFACES_LINE" ]] || die "could not find an 'interfaces:' line in azure_mana_trex_setup.sh output ($SETUP_LOG) — its output format may have changed, check manually"
[[ -n "$VDEVS_LINE" ]] || die "could not find an 'interfaces_vdevs:' line in azure_mana_trex_setup.sh output ($SETUP_LOG) — its output format may have changed, check manually"

BUS1=$(echo "$IFACES_LINE" | grep -oP "'[^']*'" | tr -d "'" | sed -n '1p')
BUS2=$(echo "$IFACES_LINE" | grep -oP "'[^']*'" | tr -d "'" | sed -n '2p')
DEV_UUID1=$(echo "$VDEVS_LINE" | grep -oP "'[^']*'" | tr -d "'" | sed -n '1p')
DEV_UUID2=$(echo "$VDEVS_LINE" | grep -oP "'[^']*'" | tr -d "'" | sed -n '2p')

[[ -n "$BUS1" && -n "$BUS2" ]] || die "parsed empty bus-info from azure_mana_trex_setup.sh output — check $SETUP_LOG manually"
[[ -n "$DEV_UUID1" && -n "$DEV_UUID2" ]] || die "parsed empty vmbus device UUIDs from azure_mana_trex_setup.sh output — check $SETUP_LOG manually"

echo "  Parsed from setup script: bus-info=[$BUS1, $BUS2] interfaces_vdevs=[$DEV_UUID1, $DEV_UUID2]"

# ---------------------------------------------------------------------------
# Step 9b (Phase H): match each vdev to a port by its embedded MAC
# ---------------------------------------------------------------------------
# The setup script's own output order is NOT trustworthy as a port order, it
# reflects that script's hardcoded internal PRIMARY1/PRIMARY2, which has no
# relationship to $DATA_NIC1/$DATA_NIC2 or to $SOURCE_IP/$DEST_IP.
log "Step 9b: Matching vdev UUIDs to ports by embedded MAC"

uuid_to_mac() {
  local uuid="${1//-/}"
  [[ "${#uuid}" -ge 12 ]] || return 1
  norm_mac "${uuid: -12}"
}

VMAC1=$(uuid_to_mac "$DEV_UUID1") || die "vdev UUID '$DEV_UUID1' does not end in 12 hex characters — the UUID-to-MAC assumption no longer holds. Stop and re-verify against $SETUP_LOG before trusting any generated config."
VMAC2=$(uuid_to_mac "$DEV_UUID2") || die "vdev UUID '$DEV_UUID2' does not end in 12 hex characters — the UUID-to-MAC assumption no longer holds. Stop and re-verify against $SETUP_LOG before trusting any generated config."

echo "  vdev $DEV_UUID1 -> mac $VMAC1 (bus $BUS1)"
echo "  vdev $DEV_UUID2 -> mac $VMAC2 (bus $BUS2)"

[[ "$VMAC1" != "$VMAC2" ]] || die "both vdev UUIDs resolve to the same MAC ($VMAC1) — cannot disambiguate the two ports, check $SETUP_LOG manually"

declare -A VDEV_BY_MAC BUS_BY_MAC
VDEV_BY_MAC["$VMAC1"]="$DEV_UUID1"; BUS_BY_MAC["$VMAC1"]="$BUS1"
VDEV_BY_MAC["$VMAC2"]="$DEV_UUID2"; BUS_BY_MAC["$VMAC2"]="$BUS2"

[[ -n "${VDEV_BY_MAC[$P0_MAC]:-}" ]] \
  || die "no vdev UUID found whose embedded MAC matches port 0's NIC $P0_NIC (mac=$P0_MAC) — setup script reported MACs [$VMAC1, $VMAC2]. Either it did not enumerate both data NICs, or it picked up the mgmt NIC. Check $SETUP_LOG."
[[ -n "${VDEV_BY_MAC[$P1_MAC]:-}" ]] \
  || die "no vdev UUID found whose embedded MAC matches port 1's NIC $P1_NIC (mac=$P1_MAC) — setup script reported MACs [$VMAC1, $VMAC2]. Check $SETUP_LOG."

P0_UUID="${VDEV_BY_MAC[$P0_MAC]}"; P0_BUS="${BUS_BY_MAC[$P0_MAC]}"
P1_UUID="${VDEV_BY_MAC[$P1_MAC]}"; P1_BUS="${BUS_BY_MAC[$P1_MAC]}"

if [[ "$P0_UUID" == "$DEV_UUID2" ]]; then
  echo "  NOTE: setup script's output order is reversed relative to the port convention."
  echo "        Re-ordered by MAC match — this is the fix working as designed, not an error."
fi

echo "  port 0: bus=$P0_BUS vdev=$P0_UUID ip=$P0_IP"
echo "  port 1: bus=$P1_BUS vdev=$P1_UUID ip=$P1_IP"

if [[ -f "$TREX_CFG" ]]; then
  BACKUP="${TREX_CFG}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TREX_CFG" "$BACKUP"
  echo "  existing $TREX_CFG backed up to $BACKUP"
fi

# interfaces, interfaces_vdevs and port_info are all positionally paired.
# They are emitted from the same P0_*/P1_* variables so they cannot drift
cat > "$TREX_CFG" <<EOF
# Generated by trex-install.sh — port roles resolved by MAC, not by order.
# port 0 = $P0_NIC ($P0_IP)   port 1 = $P1_NIC ($P1_IP)
# interfaces / interfaces_vdevs / port_info are positionally paired: do not
# edit one without editing the others (see Phase H).
- version: 2
  interfaces: ['${P0_BUS}', '${P1_BUS}']
  port_mtu: 9000
  ext_dpdk_opt: ['--vdev=net_vdev_netvsc,ignore=1', '--vdev=net_vdev_netvsc,ignore=1']
  interfaces_vdevs: ['${P0_UUID}', '${P1_UUID}']
  port_info:
    - ip: ${P0_IP}
      default_gw: ${P0_GW}
    - ip: ${P1_IP}
      default_gw: ${P1_GW}
EOF

echo
echo "  Wrote $TREX_CFG:"
echo "  -------------------------------------------"
sed 's/^/  /' "$TREX_CFG"
echo "  -------------------------------------------"
echo "  Review this — especially default_gw if you're on a custom route table (UDR) —"
echo "  before proceeding."

log "Configuring hugepages (required by DPDK/EAL)"
./trex-cfg
if ! grep -qi 'HugePages_Total:\s*[1-9]' /proc/meminfo; then
  echo "  WARNING: HugePages_Total is still 0 after trex-cfg — t-rex-64 will likely fail EAL init."
  echo "  Check /proc/meminfo and 'mount | grep huge' manually."
fi

# ---------------------------------------------------------------------------
# Step 10: Sanity-check and run
# ---------------------------------------------------------------------------
log "Automated steps complete."
cat <<EOF

Sanity-check and run:

  ibv_devinfo                 # both devices should show PORT_ACTIVE
  cd $TREX_DIR/scripts
  sudo ./t-rex-64 -i

In a second session:

  cd $TREX_DIR/scripts
  ./trex-console
  trex> start -f stl/imix.py -m 10%
  trex> tui
EOF

log "Done. Full log at $LOG_FILE"