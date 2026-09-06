#!/usr/bin/env python3
#
# trex-stl-orchestrator.py
# Runs trex-stl-run.py across every RFC 2544 frame size crossed with every --mult speed,
# RUNS_PER_COMBO times each, at a fixed duration. Results saved under ~/trex_results/
#
# Usage: python3 trex-stl-orchestrator.py [--dry-run] [--max-offered-mpps MPPS]

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
RUN_SCRIPT = SCRIPT_DIR / "trex-stl-run.py"
RESULTS_DIR = Path.home() / "trex_results"

# Matrix definition.
FRAME_SIZES = (64, 128, 256, 512, 1024, 1280, 1518)  # RFC 2544 standard wire sizes (FCS-inclusive)
MULT_VALUES = ("100mbps", "500mbps", "1gbps", "2gbps", "5gbps", "10gbps")  # traffic speed, 10/25/50/75/100% of a 20 Gbps max
RUNS_PER_COMBO = 5
DURATION_SECONDS = 30
WARMUP_SECONDS = 0
COOLDOWN_SECONDS = 10  # pause between runs

# Ethernet L1 framing overhead atop every wire-size frame in FRAME_SIZES: 8-byte preamble + 12-byte
# inter-frame gap. Needed to convert a --mult bps rate into an offered pps figure:
#   pps = bps / (8 * (frame_size + FRAME_OVERHEAD_BYTES))
FRAME_OVERHEAD_BYTES = 20

# Small frames mean far higher pps than large ones at the same bps rate, and every generator/NIC
# driver combo has its own pps ceiling. MAX_OFFERED_MPPS excludes any (frame_size, mult) combo whose 
# offered rate would exceed it.
# This default is Azure MANA's ceiling (this project's az-* VMs): ~8.50 Mpps multi-core.
# A different platform's ceiling belongs on the command line via --max-offered-mpps, not by editing this constant.
MAX_OFFERED_MPPS = 8.50

_MULT_RATE_RE = re.compile(r"^(\d+(?:\.\d+)?)([kmg])bps$", re.I)
_MULT_UNITS = {"k": 1e3, "m": 1e6, "g": 1e9}

# Offered packets/sec (millions) for one (frame_size, mult) combo, or None if mult isn't a plain bps rate
def _offered_mpps(frame_size, mult):
    match = _MULT_RATE_RE.match(mult)
    if not match:
        return None
    bps = float(match.group(1)) * _MULT_UNITS[match.group(2).lower()]
    return bps / (8 * (frame_size + FRAME_OVERHEAD_BYTES)) / 1e6

def mult_values_for(frame_size):
    return tuple(
        m for m in MULT_VALUES
        if (mpps := _offered_mpps(frame_size, m)) is None or mpps <= MAX_OFFERED_MPPS
    )

# 5/10gbps runs push a lot of bandwidth through the firewall, which drives up cost.
# Cap the repeat count for those two mults instead of the usual RUNS_PER_COMBO.
HIGH_BANDWIDTH_MULTS = ("5gbps", "10gbps")
HIGH_BANDWIDTH_RUNS_PER_COMBO = 3

def runs_per_combo_for(mult):
    return HIGH_BANDWIDTH_RUNS_PER_COMBO if mult in HIGH_BANDWIDTH_MULTS else RUNS_PER_COMBO

# Total run count for the current MAX_OFFERED_MPPS/matrix.
def total_runs():
    return sum(runs_per_combo_for(mult) for fs in FRAME_SIZES for mult in mult_values_for(fs))

# Runs trex-stl-report.py once for a given frame size/mult/run index and returns a summary.
def run_one(frame_size, mult, run_index, batch_timestamp, run_number, total):
    mult_tag = mult.replace("%", "pct")
    output_path = RESULTS_DIR / f"trex_stl_stats_fs{frame_size}_mult{mult_tag}_run{run_index}_{batch_timestamp}.json"
    cmd = [
        sys.executable, str(RUN_SCRIPT),
        "--frame-size", str(frame_size),
        "--mult", mult,
        "--duration", str(DURATION_SECONDS),
        "--warmup", str(WARMUP_SECONDS),
        "--output", str(output_path),
    ]
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] Run {run_number}/{total} - {frame_size}B @ {mult} run {run_index}/{runs_per_combo_for(mult)}: {' '.join(cmd)}")
    start = time.monotonic()
    result = subprocess.run(cmd)
    elapsed = time.monotonic() - start

    return {
        "frame_size": frame_size,
        "mult": mult,
        "run": run_index,
        "output": str(output_path),
        "success": result.returncode == 0,
        "elapsed_seconds": round(elapsed, 1),
    }

# Prints the frame-size x mult matrix as a table, plus an estimated completion time.
def print_matrix():
    rows = [(fs, ", ".join(mult_values_for(fs)), sum(runs_per_combo_for(m) for m in mult_values_for(fs))) for fs in FRAME_SIZES]

    headers = ("Frame Size", "Mults", "Runs")
    widths = [max(len(h), *(len(str(r[i])) for r in rows)) for i, h in enumerate(headers)]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)

    print(fmt.format(*headers))
    print("  ".join("-" * w for w in widths))
    for fs, mults, runs in rows:
        print(fmt.format(f"{fs}B", mults, runs))

    total = total_runs()
    run_seconds = DURATION_SECONDS + WARMUP_SECONDS
    est_seconds = total * run_seconds + (total - 1) * COOLDOWN_SECONDS
    print(f"\n{len(FRAME_SIZES)} frame sizes, {total} total runs "
          f"({RUNS_PER_COMBO} repeats/mult, {HIGH_BANDWIDTH_RUNS_PER_COMBO} for {'/'.join(HIGH_BANDWIDTH_MULTS)}, "
          f"{run_seconds}s/run + {COOLDOWN_SECONDS}s cooldown), "
          f"est. {est_seconds / 3600:.1f}h.")

# Runs the full frame-size x mult x run-count matrix.
def main():
    global MAX_OFFERED_MPPS

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true",
                     help="Print the test matrix as a table and exit, without running anything.")
    ap.add_argument("--max-offered-mpps", type=float, default=None,
                     help="Override MAX_OFFERED_MPPS for this run instead of editing the constant in "
                          f"the file (default {MAX_OFFERED_MPPS}, tuned for Azure MANA). Use this to "
                          "target a different platform's pps ceiling, e.g. --max-offered-mpps 0.82 for "
                          "AWS ENA - see the MAX_OFFERED_MPPS comment above for how that value was chosen.")
    args = ap.parse_args()

    if args.max_offered_mpps is not None:
        MAX_OFFERED_MPPS = args.max_offered_mpps

    if args.dry_run:
        print_matrix()
        return

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    batch_timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    combos = [
        (frame_size, mult, run_index)
        for frame_size in FRAME_SIZES
        for mult in mult_values_for(frame_size)
        for run_index in range(1, runs_per_combo_for(mult) + 1)
    ]
    total = total_runs()
    summary = []
    for run_number, (frame_size, mult, run_index) in enumerate(combos, start=1):
        summary.append(run_one(frame_size, mult, run_index, batch_timestamp, run_number, total))
        if run_number < total and COOLDOWN_SECONDS > 0:
            print(f"Cooling down for {COOLDOWN_SECONDS}s before next run...")
            time.sleep(COOLDOWN_SECONDS)

    failures = [m for m in summary if not m["success"]]

    summary_path = RESULTS_DIR / f"trex_stl_summary_{batch_timestamp}.json"
    with open(summary_path, "w") as f:
        json.dump({
            "frame_sizes": FRAME_SIZES,
            "mult_values": MULT_VALUES,
            "frame_overhead_bytes": FRAME_OVERHEAD_BYTES,
            "max_offered_mpps": MAX_OFFERED_MPPS,
            "runs_per_combo": RUNS_PER_COMBO,
            "high_bandwidth_mults": HIGH_BANDWIDTH_MULTS,
            "high_bandwidth_runs_per_combo": HIGH_BANDWIDTH_RUNS_PER_COMBO,
            "duration": DURATION_SECONDS,
            "warmup": WARMUP_SECONDS,
            "cooldown": COOLDOWN_SECONDS,
            "runs": summary,
        }, f, indent=2)

    print(f"\n{len(summary)} runs complete, {len(failures)} failed. Summary: {summary_path}")
    if failures:
        sys.exit(1)

if __name__ == "__main__":
    main()
