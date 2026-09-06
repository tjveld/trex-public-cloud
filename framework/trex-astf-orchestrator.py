#!/usr/bin/env python3
#
# trex-astf-orchestrator.py
# Runs trex-astf-run.py across every --mult speed, RUNS_PER_MULT times each, at a fixed duration. 
# Results saved under ~/trex_results/ 
#
# Usage: python3 trex-astf-orchestrator.py [--dry-run]
#        --dry-run prints the test matrix as a table and exits without running anything.

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
RUN_SCRIPT = SCRIPT_DIR / "trex-astf-run.py"
RESULTS_DIR = Path.home() / "trex_results"

# Matrix definition.
# ASTFClient.start()'s mult is a scalar multiplier of every SFR capture's own cps rate, not a bps/percentage string. 
# Placeholder values (0.5x-10x the SFR profile's own ~2 Kcps combined baseline)
MULT_VALUES = (0.25, 0.5, 1.0, 2.5, 5.0)
RUNS_PER_MULT = 5
DURATION_SECONDS = 60
WARMUP_SECONDS = 0
AVL_DIR = None  # Use trex-astf-run.py's own default.
COOLDOWN_SECONDS = 20  # pause between runs so the firewall/NVA under test can 'reset' state

TOTAL_RUNS = len(MULT_VALUES) * RUNS_PER_MULT

# Runs trex-astf-run.py once for a given --mult speed/run index and returns a summary dict for this run.
def run_one(mult, run_index, batch_timestamp, run_number):
    mult_tag = str(mult).replace(".", "p")
    output_path = RESULTS_DIR / f"trex_astf_stats_mult{mult_tag}_run{run_index}_{batch_timestamp}.json"
    cmd = [
        sys.executable, str(RUN_SCRIPT),
        "--mult", str(mult),
        "--duration", str(DURATION_SECONDS),
        "--warmup", str(WARMUP_SECONDS),
        "--output", str(output_path),
    ]
    if AVL_DIR:
        cmd += ["--avl-dir", AVL_DIR]

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] Run {run_number}/{TOTAL_RUNS} @ {mult} run {run_index}/{RUNS_PER_MULT}: {' '.join(cmd)}")
    start = time.monotonic()
    result = subprocess.run(cmd)
    elapsed = time.monotonic() - start

    return {
        "mult": mult,
        "run": run_index,
        "output": str(output_path),
        "success": result.returncode == 0,
        "elapsed_seconds": round(elapsed, 1),
    }

# Prints the mult matrix as a table (all mults on a single line) plus an estimated completion time.
def print_matrix():
    mults = ", ".join(str(m) for m in MULT_VALUES)
    headers = ("Mults", "Repeats/mult", "Total Runs")
    row = (mults, str(RUNS_PER_MULT), str(TOTAL_RUNS))
    widths = [max(len(h), len(r)) for h, r in zip(headers, row)]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)

    print(fmt.format(*headers))
    print("  ".join("-" * w for w in widths))
    print(fmt.format(*row))

    run_seconds = DURATION_SECONDS + WARMUP_SECONDS
    est_seconds = TOTAL_RUNS * run_seconds + (TOTAL_RUNS - 1) * COOLDOWN_SECONDS
    print(f"\n{len(MULT_VALUES)} mult values, {TOTAL_RUNS} total runs "
          f"({RUNS_PER_MULT} repeats/mult, {run_seconds}s/run + {COOLDOWN_SECONDS}s cooldown), "
          f"est. {est_seconds / 3600:.1f}h.")

# Runs the full mult-speed x run-count matrix and writes a summary JSON of all runs.
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true",
                     help="Print the test matrix as a table and exit, without running anything.")
    args = ap.parse_args()

    if args.dry_run:
        print_matrix()
        return

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    batch_timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    combos = [
        (mult, run_index)
        for mult in MULT_VALUES
        for run_index in range(1, RUNS_PER_MULT + 1)
    ]
    summary = []
    for run_number, (mult, run_index) in enumerate(combos, start=1):
        summary.append(run_one(mult, run_index, batch_timestamp, run_number))
        if run_number < TOTAL_RUNS and COOLDOWN_SECONDS > 0:
            print(f"Cooling down for {COOLDOWN_SECONDS}s before next run...")
            time.sleep(COOLDOWN_SECONDS)

    failures = [m for m in summary if not m["success"]]

    summary_path = RESULTS_DIR / f"trex_astf_summary_{batch_timestamp}.json"
    with open(summary_path, "w") as f:
        json.dump({
            "mult_values": MULT_VALUES,
            "runs_per_mult": RUNS_PER_MULT,
            "duration": DURATION_SECONDS,
            "warmup": WARMUP_SECONDS,
            "avl_dir": AVL_DIR,
            "cooldown": COOLDOWN_SECONDS,
            "runs": summary,
        }, f, indent=2)

    print(f"\n{len(summary)} runs complete, {len(failures)} failed. Summary: {summary_path}")
    if failures:
        sys.exit(1)

if __name__ == "__main__":
    main()
