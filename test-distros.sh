#!/bin/sh
# Quick container smoke test for nr-liveval.sh across distros.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/nr-liveval.sh"
export BENCH_SAMPLES=1 BENCH_WARMUP=0

run() {
  name="$1"
  image="$2"
  cmd="$3"
  printf '\n========== %s (%s) ==========\n' "$name" "$image"
  if docker run --rm --network host -v "$SCRIPT:/nr-liveval.sh:ro" "$image" sh -c "$cmd"; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    return 1
  fi
}

COMMON='cp /nr-liveval.sh /tmp/nr && chmod +x /tmp/nr && export RESULTS_DIR=/tmp/r BENCH_SAMPLES=1 BENCH_WARMUP=0 && /tmp/nr --sysbench-only && test -f /tmp/r/results.json'

fail=0
run "ubuntu" "ubuntu:24.04" "$COMMON" || fail=1
run "debian" "debian:12" "$COMMON" || fail=1
run "fedora" "fedora:41" "$COMMON" || fail=1
run "alma" "almalinux:9" "$COMMON" || fail=1
run "rocky" "rockylinux:9" "$COMMON" || fail=1
run "centos-stream" "quay.io/centos/centos:stream9" "$COMMON" || fail=1
run "arch" "archlinux:latest" "$COMMON" || fail=1
run "alpine" "alpine:3.20" "$COMMON" || fail=1

exit "$fail"
