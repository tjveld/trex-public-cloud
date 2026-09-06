#!/usr/bin/env python3
#
# trex-astf-run.py
# Runs a TRex ASTF (stateful) traffic test using the stock "SFR" traffic mix;
# HTTP browsing/GET/POST,HTTPS, Exchange, POP mail, Oracle, SMTP, Citrix, each replayed at its own connections/sec rate
# Writes one JSON snapshot tagged with this VM's cloud metadata (name/region/SKU) via IMDS.
# Traffic runs continuously for --warmup + --duration seconds; stats are cleared right after warmup so results cover exactly --duration
#
# The SFR mix replays real pcap captures, which ship with TRex under scripts/avl/ - point --avl-dir
#
# Run on the trex VM after t-rex-64 is already running in astf server mode (connects as a client).
# Usage: python3 trex-astf-run.py [--cloud auto|azure|aws] [--avl-dir DIR]
#            [--mult 1.0] [--warmup 10] --duration 30 [--wait-timeout SECS]
#            [--output FILE]
#
# Output: {"meta": {cloud, vm_name, region, vm_sku, latency_pps, warmup, duration,
#          wait_timeout, timed_out, active_flows_at_end, timestamp}, "stats": {...}}

import argparse
import json
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import URLError

from trex.astf.api import ASTFClient, ASTFProfile, ASTFCapInfo, ASTFIPGen, ASTFIPGenDist, ASTFIPGenGlobal

try:
    from trex.common.trex_exceptions import TRexTimeoutError as _WAIT_TIMEOUT_EXC
except ImportError:  # pragma: no cover - depends on installed TRex version
    from trex.common.trex_exceptions import TRexError as _WAIT_TIMEOUT_EXC

AZURE_IMDS_COMPUTE_URL = "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
AWS_IMDS_TOKEN_URL = "http://169.254.169.254/latest/api/token"
AWS_IMDS_META_URL = "http://169.254.169.254/latest/meta-data"
DMI_SYS_VENDOR_PATH = "/sys/class/dmi/id/sys_vendor"

# Stock TRex "SFR" cap list (TCP only): filename under --avl-dir, connections/sec rate, and an optional fixed dest port.
SFR_CAP_LIST = (
    {"file": "delay_10_http_browsing_0.pcap", "cps": 709.89},
    {"file": "delay_10_http_get_0.pcap", "cps": 404.52, "port": 8080},
    {"file": "delay_10_http_post_0.pcap", "cps": 404.52, "port": 8081},
    {"file": "delay_10_https_0.pcap", "cps": 130.87},
    {"file": "delay_10_exchange_0.pcap", "cps": 253.81},
    {"file": "delay_10_mail_pop_0.pcap", "cps": 4.759},
    {"file": "delay_10_oracle_0.pcap", "cps": 79.3178},
    {"file": "delay_10_smtp_0.pcap", "cps": 7.3369},
    {"file": "delay_10_citrix_0.pcap", "cps": 43.6248},
)
SFR_IP_RANGES = {"client": ["16.0.0.1", "16.0.0.255"], "server": ["48.0.0.1", "48.0.255.255"]}
SFR_IP_OFFSET = "1.0.0.0"
DEFAULT_AVL_DIR = "/opt/trex-core/scripts/avl"
# Rate of a parallel ICMP-based latency probe TRex injects alongside the ASTF traffic (0 = disabled).
LATENCY_PPS = 100
# Default --mult: ASTFClient.start()'s mult is a plain float, ultiplier applied to every SFR_CAP_LIST entry's own cps
DEFAULT_MULT = 1.0
# Seconds added to (warmup + duration) to bound wait_on_traffic().
DEFAULT_WAIT_GRACE = 30.0

def _http(url, headers=None, timeout=5, method="GET"):
    req = urllib.request.Request(url, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode()

def get_vm_metadata_azure(timeout=5):
    data = json.loads(_http(AZURE_IMDS_COMPUTE_URL, {"Metadata": "true"}, timeout))
    return {"cloud": "azure", "vm_name": data["name"], "region": data["location"], "vm_sku": data["vmSize"]}

def get_vm_metadata_aws(timeout=5):
    token = _http(AWS_IMDS_TOKEN_URL, {"X-aws-ec2-metadata-token-ttl-seconds": "60"}, timeout, method="PUT")
    hdr = {"X-aws-ec2-metadata-token": token}
    return {
        "cloud": "aws",
        "vm_name": _http(f"{AWS_IMDS_META_URL}/instance-id", hdr, timeout),
        "region": _http(f"{AWS_IMDS_META_URL}/placement/region", hdr, timeout),
        "vm_sku": _http(f"{AWS_IMDS_META_URL}/instance-type", hdr, timeout),
    }

GET_VM_METADATA_BY_CLOUD = {
    "azure": get_vm_metadata_azure,
    "aws": get_vm_metadata_aws,
}

def detect_cloud():
    try:
        vendor = Path(DMI_SYS_VENDOR_PATH).read_text()
        for marker, cloud in (("Microsoft", "azure"), ("Amazon", "aws")):
            if marker in vendor:
                return cloud
    except OSError:
        pass

    for cloud, get_meta in GET_VM_METADATA_BY_CLOUD.items():
        try:
            get_meta(timeout=2)
            return cloud
        except (URLError, OSError, TimeoutError):
            continue

    raise RuntimeError(
        "Could not auto-detect cloud provider. Pass --cloud azure|aws explicitly."
    )


def get_vm_metadata(cloud="auto"):
    if cloud == "auto":
        cloud = detect_cloud()
    return GET_VM_METADATA_BY_CLOUD[cloud]()


def build_sfr_profile(avl_dir):
    """Build the hardcoded SFR ASTFProfile, resolving each cap file under avl_dir."""
    ip_gen = ASTFIPGen(
        glob=ASTFIPGenGlobal(ip_offset=SFR_IP_OFFSET),
        dist_client=ASTFIPGenDist(ip_range=SFR_IP_RANGES["client"], distribution="seq"),
        dist_server=ASTFIPGenDist(ip_range=SFR_IP_RANGES["server"], distribution="seq"),
    )
    cap_list = [
        ASTFCapInfo(file=str(Path(avl_dir) / c["file"]), cps=c["cps"], **({"port": c["port"]} if "port" in c else {}))
        for c in SFR_CAP_LIST
    ]
    return ASTFProfile(default_ip_gen=ip_gen, cap_list=cap_list)

def _active_flows(stats):
    """Best-effort read of flows still open at the end of the run. Prefers the client-side
    m_active_flows (the ASTF TUI's 'Active-flows'), falls back to the global counter, and returns
    None if neither is present, so a missing value is distinguishable from a genuine zero."""
    try:
        return stats["traffic"]["client"]["m_active_flows"]
    except (KeyError, TypeError):
        pass
    try:
        return stats["global"]["active_flows"]
    except (KeyError, TypeError):
        return None

def run_trex(mult, duration, avl_dir, warmup=0, latency_pps=LATENCY_PPS, wait_timeout=None):
    """Run one ASTF test. Returns (stats, timed_out, active_flows_at_end)."""
    c = ASTFClient()
    c.connect()
    try:
        c.reset()
        c.load_profile(build_sfr_profile(avl_dir))
        c.clear_stats()

        # Warmup + duration run as one uninterrupted burst; counters are zeroed right after warmup so returned stats cover only `duration` seconds.
        c.start(mult=mult, duration=warmup + duration, latency_pps=latency_pps)
        if warmup:
            time.sleep(warmup)
            c.clear_stats()

        # Bounded wait: a run whose flows never drain is force-stopped and flagged rather than hanging the process.
        timed_out = False
        try:
            c.wait_on_traffic(timeout=wait_timeout)
        except _WAIT_TIMEOUT_EXC:
            timed_out = True
            c.stop()

        stats = c.get_stats()
        return stats, timed_out, _active_flows(stats)
    finally:
        c.disconnect()

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cloud", choices=["auto", "azure", "aws"], default="auto",
                     help="Cloud the VM is running in, for IMDS metadata lookup. "
                          "Default 'auto' detects it (DMI sys_vendor, falling back to IMDS probes).")
    ap.add_argument("--avl-dir", default=DEFAULT_AVL_DIR,
                     help=f"Directory holding the SFR pcap captures on this VM's TRex install. Default: {DEFAULT_AVL_DIR}")
    ap.add_argument("--mult", type=float, default=DEFAULT_MULT,
                     help="Scalar multiplier applied to every SFR capture's own cps rate (e.g. 2.0 = "
                          "double every capture's baseline connections/sec). A plain float - "
                          f"ASTFClient.start() does not accept unit strings like '1gbps'/'50%%'. Default "
                          f"{DEFAULT_MULT} (the profile's own baseline rates, unscaled).")
    ap.add_argument("--latency-pps", type=int, default=LATENCY_PPS,
                     help="Rate (pps) of a parallel ICMP latency probe TRex injects alongside the ASTF "
                          "traffic. 0 disables it.")
    ap.add_argument("--warmup", type=float, default=10,
                     help="Seconds of traffic to run and discard before measuring, so the DUT reaches "
                          "steady state first. Traffic runs uninterrupted; stats are cleared right after "
                          "this window (via clear_stats()) so the results cover exactly --duration seconds. "
                          "Use 0 to disable.")
    ap.add_argument("--duration", type=float, required=True, help="Seconds of traffic to measure (after warmup)")
    ap.add_argument("--wait-timeout", type=float, default=None,
                     help="Seconds to wait for flows to drain after traffic stops, before force-stopping "
                          f"and flagging the run. Default: warmup + duration + {DEFAULT_WAIT_GRACE:g}. "
                          "Bounded because an unbounded wait_on_traffic() has been observed to hang "
                          "indefinitely when path impairment (e.g. netem delay at the DUT) leaves a few "
                          "long-tail flows undrained. Set to 0 to wait indefinitely (original behaviour).")
    ap.add_argument("--output", default=None,
                     help="Output path. Defaults to trex_astf_stats_mult<mult>_<UTC timestamp>.json so "
                          "repeated runs don't overwrite each other.")
    args = ap.parse_args()

    # 0 means "wait indefinitely"; wait_on_traffic() treats timeout=None that way.
    if args.wait_timeout is None:
        wait_timeout = args.warmup + args.duration + DEFAULT_WAIT_GRACE
    elif args.wait_timeout <= 0:
        wait_timeout = None
    else:
        wait_timeout = args.wait_timeout

    now = datetime.now(timezone.utc)
    mult_tag = str(args.mult).replace(".", "p")
    output_path = args.output or f"trex_astf_stats_mult{mult_tag}_{now.strftime('%Y%m%dT%H%M%SZ')}.json"

    meta = get_vm_metadata(args.cloud)
    stats, timed_out, active_flows_at_end = run_trex(
        args.mult, args.duration, args.avl_dir, args.warmup, args.latency_pps, wait_timeout
    )
    output = {
        "meta": {
            **meta,
            "profile": "sfr",
            "avl_dir": args.avl_dir,
            "mult": args.mult,
            "latency_pps": args.latency_pps,
            "warmup": args.warmup,
            "duration": args.duration,
            "wait_timeout": wait_timeout,
            "timed_out": timed_out,
            "active_flows_at_end": active_flows_at_end,
            "timestamp": now.isoformat(),
        },
        "stats": stats,
    }

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2, default=str)

    if timed_out:
        print(f"WARNING: flows did not drain within {wait_timeout:g}s - traffic force-stopped. "
              f"active_flows_at_end={active_flows_at_end}. Run is FLAGGED (meta.timed_out=true) "
              f"and is not directly comparable to a clean run.")
    print(f"Wrote {output_path}")

if __name__ == "__main__":
    main()