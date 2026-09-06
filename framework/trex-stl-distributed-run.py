#!/usr/bin/env python3
#
# trex-stl-run.py
# Runs a TRex stateless traffic test at a fixed RFC 2544 frame size, writes one JSON snapshot tagged
# with this VM's cloud metadata (name/region/SKU) via IMDS. Traffic runs continuously for
# --warmup + --duration seconds; stats are cleared right after warmup so results cover exactly
# --duration seconds of steady-state traffic.
#
# Run on the trex VM after t-rex-64 is already running in stateless server mode (connects as a client).
# Usage: python3 trex-stl-run.py [--cloud auto|azure|aws] [--ports 0 1]
#            [--bidir] [--frame-size 64] [--mult 100mbps] [--warmup 10] --duration 30 [--output FILE]
#
# Output: {"meta": {cloud, vm_name, region, vm_sku, frame_size, pg_ids, latency_pps, warmup, duration,
#          timestamp}, "stats": {...}}

import argparse
import json
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import URLError

from trex_stl_lib.api import STLClient, STLStream, STLPktBuilder, STLTXCont, STLVM, STLFlowLatencyStats
from scapy.all import Ether, IP, UDP

AZURE_IMDS_COMPUTE_URL = "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
AWS_IMDS_TOKEN_URL = "http://169.254.169.254/latest/api/token"
AWS_IMDS_META_URL = "http://169.254.169.254/latest/meta-data"
DMI_SYS_VENDOR_PATH = "/sys/class/dmi/id/sys_vendor"

# RFC 2544 standard frame sizes (bytes). IP ranges swap src/dst by direction so --bidir produces real bidirectional traffic.
# Bulk traffic uses a single fixed UDP port (UDP_PORT); the latency stream uses its own (LATENCY_UDP_PORT), so the two are distinguishable in firewall logs.
RFC2544_FRAME_SIZES = (64, 128, 256, 512, 1024, 1280, 1518)
IP_RANGES = {
    "src": {"start": "16.0.0.1", "end": "16.0.0.5"},
    "dst": {"start": "48.0.0.1", "end": "48.0.0.5"},
}
# Fixed UDP source and destination port for the bulk stream
UDP_PORT = 12
# Fixed UDP source/destination port for the dedicated latency-sampling stream
LATENCY_UDP_PORT = 1212
# RFC 2544 frame sizes are wire sizes inclusive of the 4-byte FCS, but TRex's frame_size (and the
# scapy packet length built here) excludes it. RFC2544_FRAME_SIZES stays in RFC terms; _build_packet()
# subtracts FCS_BYTES so the frame actually on the wire matches the requested RFC size
FCS_BYTES = 4
# Each TX port gets its own flow_stats pg_id (PG_ID_BASE + direction) so per-direction latency stays identifiable.     
PG_ID_BASE = 7
# Default rate (pps) of the dedicated latency-sampling stream run alongside the bulk stream. 
LATENCY_PPS = 100

# Issues a single HTTP request and returns the decoded response body.
def _http(url, headers=None, timeout=5, method="GET"):
    req = urllib.request.Request(url, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode()

# Fetches this VM's name/region/SKU from Azure IMDS.
def get_vm_metadata_azure(timeout=5):
    data = json.loads(_http(AZURE_IMDS_COMPUTE_URL, {"Metadata": "true"}, timeout))
    return {"cloud": "azure", "vm_name": data["name"], "region": data["location"], "vm_sku": data["vmSize"]}

# Fetches this VM's name/region/SKU from AWS IMDSv2 (token then metadata lookups).
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

# Detects which cloud this VM runs in via DMI sys_vendor, falling back to IMDS probes.
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

# Resolves "auto" to a concrete cloud and fetches this VM's metadata for it.
def get_vm_metadata(cloud="auto"):
    if cloud == "auto":
        cloud = detect_cloud()
    return GET_VM_METADATA_BY_CLOUD[cloud]()

def _build_packet(src, dst, frame_size, udp_port=UDP_PORT, udp_chksum=None):
    """Build a fresh STLPktBuilder (fixed frame size, src/dst IP incrementing via its own STLVM).
    frame_size is the RFC 2544 wire size (FCS-inclusive); FCS_BYTES is subtracted before sizing the
    packet TRex actually sends. udp_chksum=None leaves scapy to compute a normal checksum; pass 0 for
    the latency stream (see build_streams). vm.fix_chksum() only recomputes the IP header checksum
    (needed since src/dst vary per packet here) - it doesn't touch the UDP checksum, so it won't
    overwrite udp_chksum=0."""
    vm = STLVM()
    vm.var(name="src", min_value=src["start"], max_value=src["end"], size=4, op="inc")
    vm.var(name="dst", min_value=dst["start"], max_value=dst["end"], size=4, op="inc")
    vm.write(fv_name="src", pkt_offset="IP.src")
    vm.write(fv_name="dst", pkt_offset="IP.dst")
    vm.fix_chksum()

    base_pkt = Ether() / IP() / UDP(sport=udp_port, dport=udp_port, chksum=udp_chksum)
    pad = max(0, (frame_size - FCS_BYTES) - len(base_pkt)) * "x"
    return STLPktBuilder(pkt=base_pkt / pad, vm=vm)

def build_streams(direction, frame_size, latency_pps):
    """Build the bulk (--mult-scaled) stream for one direction (0 = src->dst, else swapped), plus a
    small fixed-rate latency-sampling stream (own STLPktBuilder instance, not shared with the bulk
    stream, and on LATENCY_UDP_PORT rather than UDP_PORT) if latency_pps > 0.

    The latency stream ships with udp_chksum=0 (RFC 768: "not computed", legal for IPv4) rather than a
    computed checksum. TRex overwrites the last 16 bytes of an STLFlowLatencyStats-tagged packet's
    payload with its own latency header after the checksum has already been computed, so the checksum
    that ships is wrong for what's actually on the wire, a stateful firewall (e.g. Azure Firewall)
    validates it, sees a malformed packet, and drops it silently (no rule-match log entry, since a
    malformed-packet drop isn't a rule decision)."""
    src, dst = (IP_RANGES["dst"], IP_RANGES["src"]) if direction else (IP_RANGES["src"], IP_RANGES["dst"])

    streams = [STLStream(packet=_build_packet(src, dst, frame_size), mode=STLTXCont())]
    if latency_pps:
        streams.append(STLStream(
            packet=_build_packet(src, dst, frame_size, udp_port=LATENCY_UDP_PORT, udp_chksum=0),
            mode=STLTXCont(pps=latency_pps),
            flow_stats=STLFlowLatencyStats(pg_id=PG_ID_BASE + direction),
        ))
    return streams

# Connects to the TRex server, runs warmup+duration traffic on the chosen ports, and returns the resulting stats.
def run_trex(mult, duration, frame_size, ports=None, bidir=False, warmup=0, latency_pps=LATENCY_PPS):
    c = STLClient()
    c.connect()
    try:
        ports = ports if ports is not None else c.get_all_ports()
        c.reset(ports=ports)

        tx_ports = ports if bidir else ports[:1]
        for direction, port in enumerate(tx_ports):
            c.add_streams(build_streams(direction, frame_size, latency_pps), ports=[port])

        # Warmup + duration run as one uninterrupted burst; counters are zeroed right after warmup so returned stats cover only `duration` seconds.
        c.start(ports=tx_ports, mult=mult, duration=warmup + duration)
        if warmup:
            time.sleep(warmup)
            c.clear_stats(ports=tx_ports)
        c.wait_on_traffic(ports=tx_ports)

        pg_ids = [PG_ID_BASE + d for d in range(len(tx_ports))] if latency_pps else []
        return c.get_stats(), pg_ids
    finally:
        c.disconnect()

# Parses CLI args, runs the TRex test, and writes the tagged stats JSON to disk.
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--cloud", choices=["auto", "azure", "aws"], default="auto",
                     help="Cloud the VM is running in, for IMDS metadata lookup. "
                          "Default 'auto' detects it (DMI sys_vendor, falling back to IMDS probes).")
    ap.add_argument("--ports", type=int, nargs="+", default=None, metavar="PORT",
                     help="Ports to use. Default: all ports the TRex server exposes.")
    ap.add_argument("--bidir", action="store_true",
                     help="Send traffic on every port (src/dst swapped per port) instead of "
                          "just the first port.")
    ap.add_argument("--frame-size", type=int, choices=RFC2544_FRAME_SIZES, default=64,
                     help="RFC 2544 frame size in bytes, as a wire size inclusive of the 4-byte FCS "
                          "(e.g. 1518 is the MTU-1500 point). Adjusted by -FCS_BYTES internally before "
                          "building the packet, since TRex's own frame_size excludes the FCS.")
    ap.add_argument("--mult", default="1gbps", help="Traffic rate, e.g. '1000pps', '1gbps'")
    ap.add_argument("--latency-pps", type=int, default=LATENCY_PPS,
                     help="Rate (pps) of a small dedicated stream added alongside the bulk traffic to "
                          "measure latency. Kept separate because STLFlowLatencyStats-tagged streams "
                          f"cap out far below bulk line-rate on this driver/NIC combo regardless of "
                          f"--mult (default {LATENCY_PPS} is well under that ceiling). Use 0 to disable "
                          "and let --mult scale pure bulk throughput (e.g. for a max-rate run).")
    ap.add_argument("--warmup", type=float, default=10,
                     help="Seconds of traffic to run and discard before measuring, so the DUT reaches "
                          "steady state first. Traffic runs uninterrupted; stats are cleared right after "
                          "this window (via clear_stats()) so the results cover exactly --duration seconds. "
                          "Use 0 to disable.")
    ap.add_argument("--duration", type=float, required=True, help="Seconds of traffic to measure (after warmup)")
    ap.add_argument("--output", default=None,
                     help="Output path. Defaults to trex_stl_stats_fs<frame size>_<UTC timestamp>.json so "
                          "repeated runs don't overwrite each other.")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    output_path = args.output or f"trex_stl_stats_fs{args.frame_size}_{now.strftime('%Y%m%dT%H%M%SZ')}.json"

    meta = get_vm_metadata(args.cloud)
    stats, pg_ids = run_trex(args.mult, args.duration, args.frame_size, args.ports, args.bidir, args.warmup,
                              args.latency_pps)
    output = {
        "meta": {
            **meta,
            "frame_size": args.frame_size,
            "mult": args.mult,
            "pg_ids": pg_ids,
            "latency_pps": args.latency_pps,
            "warmup": args.warmup,
            "duration": args.duration,
            "timestamp": now.isoformat(),
        },
        "stats": stats,
    }

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2, default=str)

    print(f"Wrote {output_path}")

if __name__ == "__main__":
    main()