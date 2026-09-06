# TRex Reporting Framework

Scripts for driving [TRex](https://trex-tgn.cisco.com/) traffic tests against the NVA/firewall under
test, writing one JSON result per run tagged with the VM's cloud metadata. Two pairs, **STL**
(stateless) and **ASTF** (stateful): each pair is a single-run script plus an orchestrator that runs
it across a parameter matrix.

| File | Mode | Purpose |
|---|---|---|
| [trex-stl-run.py](trex-stl-run.py) | STL | One stateless run at a fixed RFC 2544 frame size |
| [trex-stl-orchestrator.py](trex-stl-orchestrator.py) | STL | Runs trex-stl-run.py across a frame-size x speed x repeat matrix |
| [trex-astf-run.py](trex-astf-run.py) | ASTF | One stateful run using TRex's stock "SFR" traffic mix |
| [trex-astf-orchestrator.py](trex-astf-orchestrator.py) | ASTF | Runs trex-astf-run.py across a speed x repeat matrix |

## Prerequisites

- Runs **on the TRex VM itself**, as a Python 3 client connecting to a locally running TRex server
  (`t-rex-64`, already started in the matching mode: stateless for STL, ASTF for ASTF).
- Needs `trex_stl_lib` / `trex.astf.api` and `scapy` importable. The install scripts don't put the
  client library on `PYTHONPATH`, so a bare `python3 trex-stl-run.py` fails with
  `ModuleNotFoundError: No module named 'trex_stl_lib'`. Fix:

  ```bash
  export PYTHONPATH="/opt/trex-core/scripts/automation/trex_control_plane/interactive:$PYTHONPATH"
  ```

- No third-party Python packages beyond what TRex's own install provides.

## trex-stl-run.py

Sends a single, fixed-size RFC 2544 UDP stream for a set duration. Latency is measured by default via
a small separate low-rate stream alongside the bulk traffic.

```bash
python3 trex-stl-run.py --duration 30
python3 trex-stl-run.py --ports 0 1 --bidir --frame-size 1518 --mult 1gbps --warmup 10 --duration 60
```

| Flag | Default | Notes |
|---|---|---|
| `--cloud auto\|azure\|aws` | `auto` | Detects via DMI `sys_vendor`, falls back to probing both clouds' IMDS. |
| `--ports PORT [PORT ...]` | all ports | Whatever `c.get_all_ports()` returns. |
| `--bidir` | off | Traffic on every port, src/dst swapped per port: genuine full duplex, not mirrored. |
| `--frame-size {64,128,256,512,1024,1280,1518}` | `64` | RFC 2544 wire size, FCS-inclusive: `1518` puts a 1518-byte frame on the wire, not 1522. |
| `--mult` | `1gbps` | Bulk stream rate, e.g. `1000pps`, `1gbps`. |
| `--latency-pps` | `100` | Rate of the dedicated latency stream, kept low since it caps around 350-400 pps regardless of `--mult`. `0` disables latency measurement. |
| `--warmup` | `10` | Seconds run and discarded before stats are cleared, so results cover exactly `--duration`. `0` disables it. |
| `--duration` | *(required)* | Seconds measured, after warmup. |
| `--output` | `trex_stl_stats_fs<frame_size>_<UTC timestamp>.json` | |

Each TX port's latency stream gets its own `flow_stats` `pg_id` (`7 + direction`); `meta.pg_ids` says
which port each `stats["latency"][<pg_id>]` entry belongs to.

## trex-astf-run.py

Runs TRex's stock **SFR** traffic mix (HTTP, HTTPS, Exchange, POP mail, Oracle, SMTP, Citrix), each
replayed from a real pcap capture at its own connections/sec rate.

```bash
python3 trex-astf-run.py --duration 30
python3 trex-astf-run.py --avl-dir /opt/trex-core/scripts/avl --mult 2.0 --warmup 10 --duration 60
```

| Flag | Default | Notes |
|---|---|---|
| `--cloud auto\|azure\|aws` | `auto` | Same as the STL script. |
| `--avl-dir` | `/opt/trex-core/scripts/avl` | Directory holding the SFR pcap captures; adjust if yours differs. |
| `--mult` | `1.0` | Float multiplier on every SFR capture's own cps rate (`2.0` doubles it). Not unit strings like `1gbps`. |
| `--latency-pps` | `100` | Rate of a parallel ICMP-based latency probe. `0` disables it. |
| `--warmup` | `10` | Same semantics as the STL script. |
| `--duration` | *(required)* | Seconds measured, after warmup. |
| `--wait-timeout` | `warmup + duration + 30` | Bounds the post-traffic drain wait, since an unbounded wait can hang on long-tail flows. `0` waits indefinitely; a run that hits this is flagged `meta.timed_out=true`. |
| `--output` | `trex_astf_stats_mult<mult>_<UTC timestamp>.json` | |

No `--ports`/`--bidir`: ASTF assigns ports from the server's own topology, and the SFR mix is already
bidirectional.

## Orchestrators

Static-config batch runners: **edit the constants at the top of the file**, then run with no
arguments. Each invokes the matching run script once per combination, saves every run's JSON under
`~/trex_results/`, and writes one summary JSON with every run's parameters, output path,
success/failure, and elapsed time.

Both support `--dry-run`, printing the matrix and an estimated wall-clock time without running or
writing anything.

```bash
python3 trex-stl-orchestrator.py --dry-run
python3 trex-stl-orchestrator.py
python3 trex-astf-orchestrator.py --dry-run
python3 trex-astf-orchestrator.py
```

- **trex-stl-orchestrator.py**: `FRAME_SIZES` (all 7 RFC 2544 sizes) x `MULT_VALUES` (6 speeds,
  `100mbps` to `10gbps`) x `RUNS_PER_COMBO` (5 repeats). Small frames (`64`, `128`) are capped to the
  first 4 `MULT_VALUES`, since they hit far higher pps at the same `--mult` and can outrun a test
  machine's pps ceiling. **190 runs** total, 30s each (about 2.1 hours).
- **trex-astf-orchestrator.py**: `MULT_VALUES` (5 cps multipliers, `0.25` to `5.0`) x
  `RUNS_PER_MULT` (5 repeats) = **25 runs**, 60s each (about 0.6 hours). `AVL_DIR = None` defers to
  `trex-astf-run.py`'s own default.