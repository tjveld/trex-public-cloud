#!/usr/bin/env bash
#
# trex-install-aws.sh
# Bootstrap script for: TRex on AWS EC2, Ubuntu 22.04, ENA (Elastic Network Adapter)
# Usage:
#   sudo ./trex-install-aws.sh
#     NIC roles are resolved automatically via AWS IMDS device-index, not
#     by name or argument — device-index 0 = management, 1 = data port 0,
#     2 = data port 1. This matches whatever device_index values your
#     OpenTofu network_interface blocks assign at attach time, so it's
#     accurate regardless of what systemd happens to name the interfaces
#     (ens5/ens6/ens7 today, potentially different on another instance
#     type or after an AMI change). See Step 0.

set -euo pipefail

TREX_DIR="${TREX_DIR:-/opt/trex-core}"
TREX_CFG="/etc/trex_cfg.yaml"
KMOD_DIR="/opt/dpdk-kmods"
IMDS_TOKEN_URL="http://169.254.169.254/latest/api/token"
IMDS_BASE="http://169.254.169.254/latest/meta-data/network/interfaces/macs"
LOG_FILE="/var/log/trex-install-aws.log"

# Expected data-NIC IPs, used to sanity-check MAC->role resolution in Step 7
# before anything is written to trex_cfg.yaml. Same defensive pattern as the
# hardened Azure script (session-notes-mana-portorder-and-firewall-ports.md).
EXPECTED_IP1="${EXPECTED_IP1:-10.10.1.10}"
EXPECTED_IP2="${EXPECTED_IP2:-10.10.2.10}"

exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo -e "\n===> $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "run this as root (sudo ./trex-install-aws.sh)"
fi

log "Starting TRex/ENA install bootstrap. Logging to $LOG_FILE"

# ---------------------------------------------------------------------------
# Step 0: Resolve NIC roles by AWS IMDS device-index (not by name or argument)
# ---------------------------------------------------------------------------
# device-number, exposed per-MAC by IMDS, is the ENI attach index set by
# your OpenTofu network_interface device_index values — this is the actual
# ground truth for role assignment, not systemd's interface naming (which
# is a downstream side effect of device-index, not an independent source of
# truth, and could shift on a different instance type or AMI). Convention:
# device-index 0 = management, 1 = data port 0, 2 = data port 1.
log "Step 0: Resolving NIC roles via IMDS device-index"

TOKEN=$(curl -s -X PUT "$IMDS_TOKEN_URL" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
[[ -n "$TOKEN" ]] || die "could not get IMDSv2 token — is this actually an AWS EC2 instance?"

declare -A MAC_TO_DEVIDX
for mac in $(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS_BASE/"); do
  mac="${mac%/}"
  devidx=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS_BASE/$mac/device-number")
  [[ -n "$devidx" ]] || die "could not read device-number for MAC $mac via IMDS"
  MAC_TO_DEVIDX["$mac"]="$devidx"
done

[[ "${#MAC_TO_DEVIDX[@]}" -ge 3 ]] \
  || die "expected at least 3 ENIs (mgmt + 2 data) via IMDS, found ${#MAC_TO_DEVIDX[@]} — check the instance's attached ENIs"

SORTED_MACS=()
while IFS= read -r line; do
  SORTED_MACS+=("$(awk '{print $2}' <<<"$line")")
done < <(for mac in "${!MAC_TO_DEVIDX[@]}"; do echo "${MAC_TO_DEVIDX[$mac]} $mac"; done | sort -n)

MGMT_MAC="${SORTED_MACS[0]}"
MAC1="${SORTED_MACS[1]}"
MAC2="${SORTED_MACS[2]}"

mac_to_iface() {
  local target_mac="$1" iface addr
  for iface in /sys/class/net/*; do
    iface=$(basename "$iface")
    [[ "$iface" == "lo" ]] && continue
    addr=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
    if [[ "${addr,,}" == "${target_mac,,}" ]]; then
      echo "$iface"
      return 0
    fi
  done
  return 1
}

MGMT_NIC=$(mac_to_iface "$MGMT_MAC") || die "could not map mgmt MAC $MGMT_MAC (device-index 0) to a local interface — is it up? check 'ip -br link'"
DATA_NIC1=$(mac_to_iface "$MAC1")   || die "could not map data1 MAC $MAC1 (device-index 1) to a local interface — is it up? check 'ip -br link'"
DATA_NIC2=$(mac_to_iface "$MAC2")   || die "could not map data2 MAC $MAC2 (device-index 2) to a local interface — is it up? check 'ip -br link'"

echo "  device-index 0 (mgmt):  $MGMT_NIC (mac=$MGMT_MAC)"
echo "  device-index 1 (data0): $DATA_NIC1 (mac=$MAC1)"
echo "  device-index 2 (data1): $DATA_NIC2 (mac=$MAC2)"

# ---------------------------------------------------------------------------
# Step 1: Verify interfaces after boot
# ---------------------------------------------------------------------------
# Unlike Azure (hv_netvsc vs mana), AWS Nitro instances use ena on every
# ENI including mgmt — there's no separate "accelerated" driver to check
# for. This step just confirms the interfaces exist and are ena-backed.
log "Step 1: Verifying NIC drivers"

check_nic() {
  local nic="$1"
  if ! ip a show "$nic" &>/dev/null; then
    die "interface $nic not found — this was resolved via IMDS device-index in Step 0; check 'ip -br link' and IMDS device-number output above for a mismatch"
  fi
  local drv
  drv=$(ethtool -i "$nic" 2>/dev/null | awk -F': ' '/^driver:/{print $2}')
  if [[ "$drv" != "ena" ]]; then
    echo "  WARNING: $nic driver is '$drv', not 'ena'. If this is an older instance type (e.g. c4 with Intel 82599 VF), some steps below (igb_uio binding) still apply, but the ENA-specific assumptions may not."
  else
    echo "  $nic: driver=ena OK"
  fi
}

check_nic "$DATA_NIC1"
check_nic "$DATA_NIC2"
check_nic "$MGMT_NIC"

# ---------------------------------------------------------------------------
# Step 2: Build toolchain
# ---------------------------------------------------------------------------
log "Step 2: Installing build toolchain"
apt-get update -y
apt-get install -y build-essential binutils python3 python3-distutils python3-venv zlib1g-dev git pkg-config curl "linux-headers-$(uname -r)"

# gcc-12 specifically: AWS's Ubuntu 22.04 kernel packages are built with
# gcc-12, while build-essential on 22.04 defaults to installing gcc-11.
# Kernel module builds (Step 6, igb_uio) are compiler-version-sensitive —
# a mismatch doesn't just warn, it can produce a module that silently
# misbehaves, so this is installed explicitly rather than left to
# build-essential's default and forced via CC= at the igb_uio build step.
apt-get install -y gcc-12 \
  || echo "  WARNING: gcc-12 package not found — check 'uname -v' for the kernel's actual build compiler and adjust Step 6's CC= accordingly"

# NOTE: no RDMA/verbs packages here — that stack (libibverbs-dev, rdma-core,
# etc.) was specifically for MANA's RDMA-based VF model. ENA doesn't use it.

# ---------------------------------------------------------------------------
# Step 3: Download TRex source (master branch tarball — not a tagged release)
# ---------------------------------------------------------------------------
# Tarball via codeload.github.com instead of `git clone` - GitHub has been
# intermittently challenging anonymous git-protocol (git-upload-pack)
# requests for HTTPS auth from multiple unrelated networks (confirmed on
# this project's Azure VM, AWS VM, and a home WSL machine, all at the same
# time, while plain HTTPS/API access from all three stayed completely
# clean). A tarball download sidesteps git's smart-HTTP protocol entirely
# and has been reliable where `git clone` was not. (dpdk-kmods below is a
# separate host, dpdk.org, and unaffected - left as a git clone.)
log "Step 3: Downloading TRex source (master branch tarball)"

TREX_TARBALL_URL="https://github.com/cisco-system-traffic-generator/trex-core/archive/refs/heads/master.tar.gz"
mkdir -p "$TREX_DIR"
rm -rf "$TREX_DIR/.git"  # stale git metadata from a previous git-clone-based install, if any

curl -fsSL "$TREX_TARBALL_URL" -o /tmp/trex-core.tar.gz \
  || die "failed to download $TREX_TARBALL_URL"

# --strip-components=1: the archive's own top-level dir (trex-core-master/)
# is stripped so contents land directly in $TREX_DIR, matching git clone's
# layout. Overwrites in place rather than wiping $TREX_DIR first, so a
# re-run doesn't discard build output from later steps.
tar -xzf /tmp/trex-core.tar.gz -C "$TREX_DIR" --strip-components=1
rm -f /tmp/trex-core.tar.gz
cd "$TREX_DIR"

# The tarball carries no git metadata to identify which commit this is -
# ask the GitHub API for master's current HEAD instead (plain unauthenticated
# REST call, unaffected by the git-protocol issue above).
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
# Step 4: Configure the build
# ---------------------------------------------------------------------------
# No --with-mana equivalent needed — ena is a standard DPDK net driver
# built by default.
# --no-mlx=all skips the mlx4/mlx5 driver build entirely, neither ENA
# data NIC is Mellanox hardware, so there's no reason to compile that
# vendored driver code. 
log "Step 4: Configuring build"
cd "$TREX_DIR/linux_dpdk"
./b configure --no-ofed-check --no-mlx=all | tee /tmp/trex_configure.log
grep -q "'configure' finished successfully" /tmp/trex_configure.log \
  || die "configure did not report success — check /tmp/trex_configure.log"

# ---------------------------------------------------------------------------
# Step 5: Build (with -Werror fallback, same pattern as the Azure script)
# ---------------------------------------------------------------------------
log "Step 5: Building TRex"
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
# Step 6: Prepare igb_uio kernel module
# ---------------------------------------------------------------------------
# This is the binding path Cisco's own GitHub issue tracker shows working
# for TRex+ENA (issue #509). Recent DPDK dropped igb_uio from its main
# tree, so check whether TRex's bundled/vendored dpdk copy already built
# it; if not, build it from the separate dpdk-kmods repo against the
# running kernel's headers.
log "Step 6: Preparing igb_uio kernel module"
RUNNING_KERNEL="$(uname -r)"
IGB_UIO_KO=""

for candidate in $(find "$TREX_DIR" -name "igb_uio.ko" 2>/dev/null); do
  candidate_vermagic=$(modinfo -F vermagic "$candidate" 2>/dev/null | awk '{print $1}')
  if [[ "$candidate_vermagic" == "$RUNNING_KERNEL" ]]; then
    IGB_UIO_KO="$candidate"
    echo "  Found matching bundled igb_uio.ko at $candidate (vermagic=$candidate_vermagic)"
    break
  else
    echo "  Skipping $candidate — vermagic '$candidate_vermagic' does not match running kernel '$RUNNING_KERNEL'"
  fi
done

if [[ -n "$IGB_UIO_KO" ]]; then
  : # matching bundled module found above, use it
else
  echo "  No igb_uio.ko with matching vermagic found in trex-core's bundled prebuilts — building from dpdk-kmods against $RUNNING_KERNEL"
  if [[ ! -d "$KMOD_DIR" ]]; then
    GIT_TERMINAL_PROMPT=0 git clone https://dpdk.org/git/dpdk-kmods "$KMOD_DIR" \
      || die "could not clone dpdk-kmods from https://dpdk.org/git/dpdk-kmods — check network access to dpdk.org, or dpdk.org's availability"
  fi
  # CC=gcc-12 forces the match with the kernel's actual build compiler
  # (installed in Step 2) rather than trusting whatever 'gcc' resolves to
  # by default on this system.
  make -C "$KMOD_DIR/linux/igb_uio" CC=gcc-12 || die "igb_uio build failed — check kernel headers match 'uname -r' ($RUNNING_KERNEL), confirm gcc-12 is installed ('gcc-12 --version'), and inspect $KMOD_DIR/linux/igb_uio manually"
  IGB_UIO_KO="$KMOD_DIR/linux/igb_uio/igb_uio.ko"
  [[ -f "$IGB_UIO_KO" ]] || die "igb_uio.ko not produced by build — check $KMOD_DIR/linux/igb_uio manually"
  built_vermagic=$(modinfo -F vermagic "$IGB_UIO_KO" 2>/dev/null | awk '{print $1}')
  [[ "$built_vermagic" == "$RUNNING_KERNEL" ]] \
    || die "freshly built igb_uio.ko vermagic ('$built_vermagic') still doesn't match running kernel ('$RUNNING_KERNEL') — check kernel-headers package version"
fi

modprobe uio
if ! lsmod | grep -q '^igb_uio'; then
  insmod "$IGB_UIO_KO" || die "insmod $IGB_UIO_KO failed — check dmesg for details"
fi
lsmod | grep igb_uio || die "igb_uio not loaded after insmod attempt"
echo "  igb_uio loaded"

# ---------------------------------------------------------------------------
# Step 7: Resolve IP/gateway via AWS IMDSv2, before binding takes the NICs
# ---------------------------------------------------------------------------
# TOKEN, MAC1 (device-index 1), and MAC2 (device-index 2) were already
# resolved in Step 0, reused here.
log "Step 7: Resolving IP/gateway for $DATA_NIC1 / $DATA_NIC2 via AWS IMDSv2"

resolve_from_imds() {
  local mac="$1"
  local ip subnet_cidr gw
  ip=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS_BASE/$mac/local-ipv4s" | head -1)
  subnet_cidr=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS_BASE/$mac/subnet-ipv4-cidr-block")
  [[ -n "$ip" && -n "$subnet_cidr" ]] || return 1
  # AWS VPC convention: the gateway is always the first usable address in the subnet (network address + 1)
  python3 -c "
import ipaddress, sys
net = ipaddress.ip_network('$subnet_cidr', strict=False)
print('$ip', str(net.network_address + 1))
"
}

RESOLVED1=$(resolve_from_imds "$MAC1") || die "could not resolve $DATA_NIC1 (mac=$MAC1) via IMDS"
RESOLVED2=$(resolve_from_imds "$MAC2") || die "could not resolve $DATA_NIC2 (mac=$MAC2) via IMDS"
IP1=$(echo "$RESOLVED1" | awk '{print $1}'); GW1=$(echo "$RESOLVED1" | awk '{print $2}')
IP2=$(echo "$RESOLVED2" | awk '{print $1}'); GW2=$(echo "$RESOLVED2" | awk '{print $2}')

echo "  $DATA_NIC1: ip=$IP1 gateway=$GW1"
echo "  $DATA_NIC2: ip=$IP2 gateway=$GW2"

if [[ "$IP1" == "$EXPECTED_IP2" && "$IP2" == "$EXPECTED_IP1" ]]; then
  die "resolved IPs are swapped relative to expected ($DATA_NIC1/device-index1 resolved to $EXPECTED_IP2, $DATA_NIC2/device-index2 resolved to $EXPECTED_IP1) — the OpenTofu module's device_index values for the two data ENIs are likely swapped. Fix the IaC, don't just swap the expected values here."
elif [[ "$IP1" != "$EXPECTED_IP1" || "$IP2" != "$EXPECTED_IP2" ]]; then
  die "resolved IPs ($IP1, $IP2) do not match expected ($EXPECTED_IP1, $EXPECTED_IP2) — refusing to write a config from unverified role assignment. Check the attached ENIs' subnets and device_index values, or override EXPECTED_IP1/EXPECTED_IP2 if this instance intentionally uses different addressing."
fi
echo "  Role verification passed: $DATA_NIC1=port0 ($IP1), $DATA_NIC2=port1 ($IP2)"

# ---------------------------------------------------------------------------
# Step 8: Bind data NICs to igb_uio and generate trex_cfg.yaml
# ---------------------------------------------------------------------------
log "Step 8: Binding data NICs to igb_uio and generating $TREX_CFG"

get_bus_info() { ethtool -i "$1" 2>/dev/null | awk -F': ' '/^bus-info:/{print $2}'; }
BUS1=$(get_bus_info "$DATA_NIC1"); [[ -n "$BUS1" ]] || die "could not read bus-info for $DATA_NIC1"
BUS2=$(get_bus_info "$DATA_NIC2"); [[ -n "$BUS2" ]] || die "could not read bus-info for $DATA_NIC2"
echo "  $DATA_NIC1: bus-info=$BUS1"
echo "  $DATA_NIC2: bus-info=$BUS2"

cd "$TREX_DIR/scripts"
ip link set "$DATA_NIC1" down
ip link set "$DATA_NIC2" down
./dpdk_nic_bind.py --bind=igb_uio "$BUS1" "$BUS2" \
  || die "dpdk_nic_bind.py failed to bind $BUS1/$BUS2 to igb_uio — check './dpdk_nic_bind.py --status' manually"
./dpdk_nic_bind.py --status

if [[ -f "$TREX_CFG" ]]; then
  BACKUP="${TREX_CFG}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TREX_CFG" "$BACKUP"
  echo "  existing $TREX_CFG backed up to $BACKUP"
fi

cat > "$TREX_CFG" <<EOF
- version: 2
  interfaces: ['${BUS1}', '${BUS2}']
  port_info:
    - ip: ${IP1}
      default_gw: ${GW1}
    - ip: ${IP2}
      default_gw: ${GW2}
EOF

echo
echo "  Wrote $TREX_CFG:"
echo "  -------------------------------------------"
sed 's/^/  /' "$TREX_CFG"
echo "  -------------------------------------------"
echo "  NOTE: ENA has been reported to auto-reduce max packet len from 9238"
echo "  to 9216 (a warning, not the hard MTU failure MANA had). If you hit"
echo "  an MTU-related error rather than just a warning, add 'port_mtu: 9216'"
echo "  to this file manually."

# ---------------------------------------------------------------------------
# Step 9: Hugepages
# ---------------------------------------------------------------------------
log "Step 9: Configuring hugepages (required by DPDK/EAL)"

# Clear any stale reservations left behind by a previous unclean t-rex-64
# exit (Ctrl+C, crash, closed SSH session, etc.) before reserving fresh
# ones. DPDK/EAL does not reliably release hugepages back to the pool on
# an unclean exit.
rm -f /dev/hugepages/rtemap_* 2>/dev/null || true
rm -rf /var/run/dpdk/rte 2>/dev/null || true

if command -v dpdk-hugepages.py &>/dev/null; then
  dpdk-hugepages.py --setup 2G
else
  echo "  dpdk-hugepages.py not found — falling back to manual reservation"
  echo 1024 | tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
fi

if ! grep -qi 'HugePages_Total:\s*[1-9]' /proc/meminfo; then
  echo "  WARNING: HugePages_Total is still 0. As with the Azure setup, runtime"
  echo "  reservation can fail on memory that's already fragmented (common on"
  echo "  a VM that's been up a while). If t-rex-64 fails with 'Cannot get"
  echo "  hugepage information', reserve at boot instead via GRUB:"
  echo "    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"hugepagesz=2M hugepages=1024 /' /etc/default/grub"
  echo "    sudo update-grub && sudo reboot"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "Automated steps complete."
cat <<EOF

Sanity-check and run:

  cd $TREX_DIR/scripts
  sudo ./dpdk_nic_bind.py --status   # both data NICs should show drv=igb_uio

  # STL (stateless) mode — confirmed working as-is:
  sudo ./t-rex-64 -i

  # ASTF (stateful) mode — REQUIRES --lro-disable, or it will start
  # cleanly, print "Requested RX offload TCP_LRO is not supported", and
  # then exit silently (exit code 1, no further output). Root cause,
  # confirmed via strace: TRex's net_ena capability profile hardcodes
  # SLRO support based on driver name, but ENA's actual queried
  # rx_offload_capa never includes TCP_LRO (0x200e has no 0x10 bit)
  # --lro-disable avoids the request entirely:
  sudo ./t-rex-64 --astf -i --no-scapy-server --lro-disable

In a second session:

  cd $TREX_DIR/scripts
  ./trex-console
  trex> start -f stl/imix.py -m 10%          # STL
  trex> start -f astf/http_simple.py -m 10   # ASTF smoke test
  trex> tui

EOF

log "Done. Full log at $LOG_FILE"