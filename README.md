# NVA vs Cloud-Native Services

Infrastructure-as-code for a dissertation project (COMP70046) comparing
**third-party Network Virtual Appliances (NVAs)** against **cloud-native
firewall services** on Azure and AWS, using [Cisco TRex](https://trex-tgn.cisco.com/)
as a DPDK-based stateful traffic generator to measure throughput, latency,
and failover behaviour.

Every environment is provisioned from code with [OpenTofu](https://opentofu.org/)
(Terraform-compatible, MPL-2.0). Deployments are small, independent stacks
that can be brought up, tested, and destroyed on their own

---

## Repository layout

```
├── aws/
│   ├── modules/        # network, routing, vm, firewall, fortigate (AWS-specific)
│   ├── scripts/        # aws-trex-install.sh — TRex/ENA bootstrap, run as EC2 user-data
│   └── deployments/    # aws-1-vpc … aws-4-vpc-trex-fortinet (see table below)
├── azure/
│   ├── modules/        # vnet, vm, firewall, fortigate (Azure-specific)
│   ├── scripts/        # az-trex-install.sh — TRex/MANA bootstrap, run as VM custom_data
│   └── deployments/    # az-1-vnet … az-5-vnet-trex-fortinet (see table below)
└── framework/          # TRex client scripts that run ON the trex VM itself (not IaC) --
                         # STL/ASTF single-run + orchestrator script pairs that drive the
                         # actual frame-size/speed test matrix against whichever DUT is in
                         # path, and write the per-run JSON results analyse/ consumes --
                         # see framework/README.md
```

Azure and AWS are **not** unified behind a shared cloud-agnostic module
layer, that's a deliberate choice, not an oversight, because the two
platforms diverge meaningfully at the resource level (accelerated
networking toggle vs. NIC-type-driven ENA, VPC peering vs. VNet peering
route propagation, etc.).

---

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.5
- Cloud CLI authenticated for the target platform (`az login` for Azure,
  `aws configure`/SSO for AWS). Each deployment's provider block picks up
  credentials from the ambient CLI session. 
- An SSH key pair (AWS deployments) and/or an admin username/password
  (Azure deployments) for the VMs being provisioned.
- Marketplace subscriptions where a deployment uses a vendor VM image
  (FortiGate on either cloud, VyOS on Azure). There's no Terraform-native
  way to accept a Marketplace agreement on AWS, and it's a one-time,
  per-account manual step.

## How it's deployed

Each folder under `aws/deployments/` and `azure/deployments/` is a fully
independent OpenTofu root module with its own state nothing is shared
between them beyond the modules and scripts they both pull from.

```bash
# open any deployment folder
cd azure/deployments/az-2-vnet-trex

# Supply the variables that have no default (see that deployment's variables.tf)
# a *.auto.tfvars file, -var, or a TF_VAR_ environment variable all work
$env:TF_VAR_vm_admin_password = "…"                                           # Azure
$env:TF_VAR_vm_admin_ssh_public_key = (Get-Content ~/.ssh/<keyname>.pub -Raw)  # AWS

tofu init
tofu plan
tofu apply

# ...run tests against the deployed environment...

# tear dowwn after testing
tofu destroy   
```

Every deployment also resolves the *deployer's own current public IP* at
`apply` time (via the `http` provider) and scopes management-plane access
(SSH/RDP, NVA admin UIs) to just that address, there's no standing broad
inbound exposure at any point. Re-running `apply` re-resolves the IP and
naturally revokes the previous one. See §4 of
[`notes/iac-framework-and-design-notes.md`](notes/iac-framework-and-design-notes.md).

Deployments build on each other in number order within a platform (e.g.
`az-3-vnet-trex-azfw` is `az-2-vnet-trex` plus Azure Firewall inline) but
each still applies/destroys independently, none of them use remote state
from another deployment.

## TRex installation via script

TRex isn't baked into a custom image, it's built from source on first
boot by a bootstrap script wired in as VM boot-time user data:

| Script | Platform / NIC path | Wired in via |
|---|---|---|
| [`azure/scripts/az-trex-install.sh`](azure/scripts/az-trex-install.sh) | Azure, MANA-accelerated NICs | `custom_data` on the trex VM resource |
| [`aws/scripts/aws-trex-install.sh`](aws/scripts/aws-trex-install.sh) | AWS, ENA NICs | `custom_data` (EC2 user-data) on the trex instance resource |

Both scripts, on first boot, automatically:

1. Resolve which attached NIC is management vs. data-plane-port-0 vs.
   data-plane-port-1 by IMDS device index on AWS, by matching MAC
   addresses on Azure, rather than trusting interface naming, which
   isn't stable across instance types/images.
2. Install the build toolchain and (Azure only) the RDMA/verbs stack MANA
   needs.
3. Clone and build `trex-core` from the TRex GitHub repo (`master` HEAD, 
   documented as unreleased/unregression-tested by design, since a tagged
   release doesn't carry the NIC-driver fixes these environments need).
4. Bind the two data-plane NICs to DPDK (`igb_uio` on AWS;
   `azure_mana_trex_setup.sh`'s VF rebind on Azure).
5. Resolve each data NIC's real IP/gateway from the platform's metadata
   service and generate `/etc/trex_cfg.yaml`, cross-checked against an
   expected IP pair before writing anything, so a swapped NIC role fails
   loudly instead of silently producing a config that looks plausible but
   is wrong (see the header comments in `az-trex-install.sh` for the
   incident this defends against).
6. Reserve hugepages for DPDK/EAL.

Both are safe to re-run manually (e.g. over SSH, if you need to rebuild
after a config change). Every step checks whether it's already satisfied,
and any existing `trex_cfg.yaml` is backed up before being overwritten.
Once bootstrap completes, TRex is started manually from the VM:

```bash
cd /opt/trex-core/scripts
# STL (stateless)
sudo ./t-rex-64 -i

# ASTF (stateful), AWS/ENA needs --lro-disable
sudo ./t-rex-64 --astf -i --no-scapy-server --lro-disable 

# in a second session:
./trex-console
trex> start -f astf/http_simple.py -m 10
trex> tui
```
