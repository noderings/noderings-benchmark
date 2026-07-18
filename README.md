# noderings-benchmark

**Noderings live validation benchmark**: single-file Linux tool for VPS / cloud instance validation. Used by [Noderings](https://noderings.com) to measure CPU, memory, storage, and network before fleet rollout.

Repository: https://github.com/noderings/noderings-benchmark

## Quick start

**On a pilot VPS** (download directly from GitHub: used by Noderings live validation):

```bash
curl -fsSL -o nr-liveval.sh \
  https://raw.githubusercontent.com/noderings/noderings-benchmark/main/nr-liveval.sh
chmod +x nr-liveval.sh
sudo ./nr-liveval.sh
```

**From a git checkout:**

```bash
git clone https://github.com/noderings/noderings-benchmark.git
cd noderings-benchmark
chmod +x nr-liveval.sh
./nr-liveval.sh --help

# Full benchmark (installs packages on first run)
sudo ./nr-liveval.sh

# View summary
jq '.sections.cpu.metrics' /tmp/nr-liveval/results/results.json
```

Non-root users can run with pre-installed tools (`SKIP_INSTALL=1`); results go to `~/.cache/nr-liveval/results/`.

## Requirements

| Required | Purpose |
|----------|---------|
| bash 4+ | Script runtime |
| Linux | `/proc`, standard coreutils |
| sysbench, jq, curl, gzip | Core benchmarks |

Optional (installed automatically when possible; workloads skipped if missing):

| Tool | Workload |
|------|----------|
| fio | Disk I/O |
| clang or gcc | Compiler CPU test |
| imagemagick (`magick` / `convert`) | Image CPU test |
| pigz | Faster multi-core gzip |
| openssl | AES CPU test (usually pre-installed) |

## Supported distributions

Auto-install via: **apt**, **dnf**, **yum** (+ EPEL), **apk**, **zypper**, **pacman**.

Tested on: Ubuntu, Debian, Fedora, AlmaLinux, Rocky Linux, **CentOS Stream 9**, Arch, Alpine. CentOS 7 (EOL) is not supported.

```bash
SKIP_INSTALL=1 ./nr-liveval.sh   # skip package install
./nr-liveval.sh --sysbench-only  # CPU + memory only (no disk/network)
./nr-liveval.sh --self-test      # short smoke test (~30s)
./nr-liveval.sh --version
./nr-liveval.sh --license
```

## Output

| Path | Description |
|------|-------------|
| `results.json` | Full report |
| `steps/*.json` | Per-step raw results |
| `sections.*.metrics` | Mean benchmark values (events/s, MiB/s, Mbps) with stability per metric |
| `noderings_score` | Overall + per-category index scores (1000 = reference VPS; see `methodology.noderings_index`) |
| `methodology` | Sampling, cleanup, stability thresholds, and score formulas |
| `sections.*.documentation` | What each category collects and how metrics are derived |

Default `RESULTS_DIR`:

- root: `/tmp/nr-liveval/results`
- non-root: `~/.cache/nr-liveval/results`

Override: `RESULTS_DIR=/path/to/out ./nr-liveval.sh`

## Scoring

**Raw metrics**: each value is the **mean (average)** over repeated samples (default 5) in real units (events/s, MiB/s, Mbps). Min, max, and CV% are also stored under `statistics`. Samples are separated by a settle delay (`BENCH_SETTLE_MS`, default 2000 ms) with cache sync between runs.

**Noderings score**: indexed vs a reference VPS profile where **1000 = reference** on each category:

| Category | Formula |
|----------|---------|
| CPU | Weighted blend: 40% single-core + 45% multi-core + 15% scaling efficiency |
| Memory | Geometric mean of write/read index scores |
| Storage | Geometric mean of fio read/write index scores |
| Network | Harmonic mean of HTTP download/upload index scores |
| **Overall** | Geometric mean of available category scores |

Override reference baselines with `NR_REF_*` env vars (see `./nr-liveval.sh --help`). Stability ratings (`stable` / `moderate` / `unstable`) come from CV% on raw samples.

## Resilience

- A failed optional step does not abort the full run; warnings appear in logs and `misc.steps` (with `error` when a step aborted).
- Missing optional tools skip related steps; remaining categories still report metrics.
- `results.json` is always written when the merge step succeeds.

## License

MIT License: Copyright (c) 2026 Node Rings. See [LICENSE](./LICENSE) or `./nr-liveval.sh --license`.
