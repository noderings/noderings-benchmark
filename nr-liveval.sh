#!/bin/sh
#
# nr-liveval: Noderings live validation benchmark
#
# Measures CPU, memory, storage, and network performance on Linux VPS and cloud
# instances. Emits results.json containing mean (average) metrics, Noderings index scores
# (1000 = reference VPS profile), and per-metric stability ratings.
#
# Copyright (c) 2026 Node Rings
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# SPDX-License-Identifier: MIT
# Repository: https://github.com/noderings/noderings-benchmark
# Docs: ./nr-liveval.sh --help | ./nr-liveval.sh --license
# Scoring: methodology and noderings_score in results.json

# /bin/sh shebang so minimal images (e.g. Alpine) reach bootstrap before bash is required.
# Always re-exec with bash once: on RHEL/CentOS /bin/sh is bash in POSIX mode (mapfile/process-sub fail).
if [ -z "${NR_LIVEVAL_REEXEC:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    export NR_LIVEVAL_REEXEC=1
    exec bash "$0" "$@"
  fi
  if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    apk add --no-cache bash >/dev/null 2>&1 || true
    if command -v bash >/dev/null 2>&1; then
      export NR_LIVEVAL_REEXEC=1
      exec bash "$0" "$@"
    fi
  fi
  printf '[nr-liveval] ERROR: bash 4+ required (on Alpine as root: apk add bash)\n' >&2
  exit 1
fi

set -euo pipefail

BENCH_SAMPLES="${BENCH_SAMPLES:-5}"
BENCH_WARMUP="${BENCH_WARMUP:-1}"
BENCH_SETTLE_MS="${BENCH_SETTLE_MS:-2000}"
BENCH_NETWORK_SAMPLES="${BENCH_NETWORK_SAMPLES:-5}"

# Reference VPS baseline profile (Noderings index 1000). Override via NR_REF_* (see --help).
build_nr_reference_json() {
  jq -n \
    --argjson cpu_single "${NR_REF_CPU_SINGLE:-1000}" \
    --argjson cpu_multi "${NR_REF_CPU_MULTI:-4000}" \
    --argjson cpu_scaling "${NR_REF_CPU_SCALING:-4.0}" \
    --argjson memory_write "${NR_REF_MEMORY_WRITE_MIB_S:-5000}" \
    --argjson memory_read "${NR_REF_MEMORY_READ_MIB_S:-6000}" \
    --argjson storage_read "${NR_REF_STORAGE_READ_MIB_S:-2500}" \
    --argjson storage_write "${NR_REF_STORAGE_WRITE_MIB_S:-1500}" \
    --argjson network_download "${NR_REF_NETWORK_DOWNLOAD_MBPS:-100}" \
    --argjson network_upload "${NR_REF_NETWORK_UPLOAD_MBPS:-50}" \
    '{
      cpu_single_events_per_s: $cpu_single,
      cpu_multi_events_per_s: $cpu_multi,
      cpu_scaling_efficiency: $cpu_scaling,
      memory_write_mib_s: $memory_write,
      memory_read_mib_s: $memory_read,
      storage_read_mib_s: $storage_read,
      storage_write_mib_s: $storage_write,
      network_download_mbps: $network_download,
      network_upload_mbps: $network_upload
    }'
}

default_results_dir() {
  if [[ -n "${RESULTS_DIR:-}" ]]; then
    printf '%s' "$RESULTS_DIR"
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf '%s' "/tmp/nr-liveval/results"
  else
    printf '%s' "${HOME:-/tmp}/.cache/nr-liveval/results"
  fi
}

RESULTS_DIR="$(default_results_dir)"

# --- helpers -----------------------------------------------------------------

log()  { printf '[nr-liveval] %s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARN: $*"; }

check_bash_version() {
  if [[ -z "${BASH_VERSINFO[0]:-}" ]] || (( BASH_VERSINFO[0] < 4 )); then
    die "bash 4.0+ required"
  fi
}

ensure_steps_dir() {
  mkdir -p "${RESULTS_DIR}/steps"
}

step_name_to_code() {
  printf '%s' "${1#step_}"
}

write_step_failure() {
  local code=$1 msg=$2
  ensure_steps_dir
  jq -n --arg code "$code" --arg err "$msg" \
    '{code: $code, error: $err}' >"$RESULTS_DIR/steps/${code}.json"
}

run_with_timeout() {
  local budget=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$budget" "$@"
  else
    warn "timeout(1) unavailable; step runs without wall-clock limit"
    "$@"
  fi
}

df_field_bytes() {
  # Root filesystem size/available bytes (df column 2=size, 4=available).
  local col=$1
  local val
  val="$(df -PB1 / 2>/dev/null | awk -v c="$col" 'NR==2{print $c; exit}')"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s' "$val"
    return 0
  fi
  val="$(df -B1 / 2>/dev/null | awk -v c="$col" 'NR==2{print $c; exit}')"
  [[ "$val" =~ ^[0-9]+$ ]] && printf '%s' "$val"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -ne 0 ]] || return 0
  die "package installation requires root (or SKIP_INSTALL=1 when tools are preinstalled)"
}

detect_os_id() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
    return 0
  fi
  printf 'unknown'
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v apk >/dev/null 2>&1; then echo apk
  elif command -v zypper >/dev/null 2>&1; then echo zypper
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  else echo unknown
  fi
}

NR_APT_UPDATED=0

apt_prepare_noninteractive() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export DEBIAN_PRIORITY=critical
  # Disable man-db auto-update during apt installs to avoid long post-install triggers.
  if command -v debconf-set-selections >/dev/null 2>&1; then
    echo 'man-db man-db/auto-update boolean false' | debconf-set-selections 2>/dev/null || true
  fi
}

apt_update_once() {
  apt_prepare_noninteractive
  if [[ "${NR_APT_UPDATED:-0}" == 1 ]]; then
    return 0
  fi
  log "apt: updating package lists..."
  apt-get update -qq
  NR_APT_UPDATED=1
}

apt_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

apt_install_packages() {
  local pkg missing=()
  for pkg in "$@"; do
    [[ -z "$pkg" ]] && continue
    if apt_pkg_installed "$pkg"; then
      continue
    fi
    missing+=("$pkg")
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  apt_update_once
  log "apt: installing ${missing[*]}..."
  apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "${missing[@]}"
}

pkg_install_optional() {
  local pkg pm
  pm="$(detect_pkg_manager)"
  for pkg in "$@"; do
    [[ -z "$pkg" ]] && continue
    if [[ "$pm" == apt ]]; then
      apt_install_packages "$pkg" || warn "optional package not installed: $pkg"
    else
      pkg_install "$pkg" 2>/dev/null || warn "optional package not installed: $pkg"
    fi
  done
}

pkg_install_dns_utils() {
  case "$(detect_pkg_manager)" in
    apt)    pkg_install_optional dnsutils ;;
    apk)    pkg_install_optional bind-tools ;;
    pacman) pkg_install_optional bind ;;
    *)      pkg_install_optional bind-utils ;;
  esac
}

verify_core_tools() {
  local missing=()
  local c
  for c in sysbench jq curl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    die "required tools missing: ${missing[*]} (install as root or set SKIP_INSTALL=1)"
  fi
  command -v fio >/dev/null 2>&1 || warn "fio not installed; disk benchmark omitted"
}

pkg_install() {
  local pm
  pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      apt_install_packages "$@"
      ;;
    dnf)  dnf install -y "$@" ;;
    yum)  yum install -y "$@" ;;
    apk)  apk add --no-cache "$@" ;;
    zypper) zypper --non-interactive install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    *) die "unsupported package manager; install manually: $*" ;;
  esac
}

is_rhel_family() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
      rhel|centos|almalinux|rocky|ol|scientific) return 0 ;;
    esac
    [[ "${ID_LIKE:-}" == *rhel* ]] && return 0
  fi
  return 1
}

rpm_pkg_satisfied() {
  local pkg=$1
  case "$pkg" in
    curl)
      command -v curl >/dev/null 2>&1 && return 0
      rpm -q curl-minimal >/dev/null 2>&1
      ;;
    coreutils)
      command -v df >/dev/null 2>&1 && command -v sleep >/dev/null 2>&1 && return 0
      rpm -q coreutils-single >/dev/null 2>&1
      ;;
    *)
      rpm -q "$pkg" >/dev/null 2>&1
      ;;
  esac
}

rpm_install_packages() {
  local installer=$1
  shift
  local pkg missing=()
  for pkg in "$@"; do
    [[ -z "$pkg" ]] && continue
    rpm_pkg_satisfied "$pkg" || missing+=("$pkg")
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  "$installer" install -y "${missing[@]}"
}

dnf_install_packages() {
  rpm_install_packages dnf "$@"
}

yum_install_packages() {
  rpm_install_packages yum "$@"
}

ensure_epel_rhel() {
  is_rhel_family || return 0
  case "$(detect_pkg_manager)" in
    dnf|yum)
      if ! rpm -q epel-release >/dev/null 2>&1; then
        log "enabling EPEL (sysbench on RHEL/Alma/Rocky/CentOS Stream family)"
        pkg_install epel-release || warn "epel-release installation failed; sysbench may be unavailable"
      fi
      ;;
  esac
}

read_host_shortname() {
  local h
  if h="$(hostname -s 2>/dev/null)" && [[ -n "$h" ]]; then
    printf '%s' "$h"
    return 0
  fi
  if h="$(hostname 2>/dev/null)" && [[ -n "$h" ]]; then
    printf '%s' "${h%%.*}"
    return 0
  fi
  if [[ -r /etc/hostname ]]; then
    read -r h </etc/hostname
    h="${h%%$'\r'}"
    [[ -n "$h" ]] && { printf '%s' "${h%%.*}"; return 0; }
  fi
  printf '%s' "${HOSTNAME:-unknown}"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c (install tools or set SKIP_INSTALL=1)"
  done
}

steal_percent() {
  local line total steal
  read -r _ line < /proc/stat || return 1
  # shellcheck disable=SC2086
  set -- $line
  steal=${9:-0}
  total=0
  for v in "$@"; do total=$((total + v)); done
  [[ "$total" -eq 0 ]] && { echo "0"; return 0; }
  awk -v s="$steal" -v t="$total" 'BEGIN { printf "%.2f", (s / t) * 100 }'
}

read_sysfs_freq_mhz() {
  local path=$1
  [[ -r "$path" ]] || return 1
  local khz
  khz="$(tr -d '[:space:]' <"$path" 2>/dev/null)" || return 1
  [[ "$khz" =~ ^[0-9]+$ && "$khz" -gt 0 ]] || return 1
  awk -v k="$khz" 'BEGIN { printf "%.2f", k / 1000 }'
}

read_cpu_mhz_from_cpuinfo() {
  awk -F: '
    /^[[:space:]]*cpu MHz/ {
      gsub(/^[ \t]+/, "", $2)
      sum += $2
      n++
    }
    END { if (n > 0) printf "%.2f", sum / n }
  ' /proc/cpuinfo 2>/dev/null
}

collect_cpu_mhz_info() {
  local cur="" min="" max="" src="" note="" base=/sys/devices/system/cpu/cpu0/cpufreq

  cur="$(lscpu_field 'CPU MHz' 2>/dev/null || true)"
  min="$(lscpu_field 'CPU min MHz' 2>/dev/null || true)"
  max="$(lscpu_field 'CPU max MHz' 2>/dev/null || true)"
  [[ -n "$cur" || -n "$min" || -n "$max" ]] && src="lscpu"

  if [[ -z "$cur" ]]; then
    cur="$(read_cpu_mhz_from_cpuinfo)"
    [[ -n "$cur" && -z "$src" ]] && src="proc_cpuinfo"
  fi

  if [[ -z "$cur" ]]; then
    cur="$(read_sysfs_freq_mhz "$base/scaling_cur_freq" 2>/dev/null)" \
      || cur="$(read_sysfs_freq_mhz "$base/cpuinfo_cur_freq" 2>/dev/null)" || true
    [[ -n "$cur" ]] && src="sysfs_cpufreq"
  fi
  if [[ -z "$min" ]]; then
    min="$(read_sysfs_freq_mhz "$base/scaling_min_freq" 2>/dev/null)" \
      || min="$(read_sysfs_freq_mhz "$base/cpuinfo_min_freq" 2>/dev/null)" || true
  fi
  if [[ -z "$max" ]]; then
    max="$(read_sysfs_freq_mhz "$base/scaling_max_freq" 2>/dev/null)" \
      || max="$(read_sysfs_freq_mhz "$base/cpuinfo_max_freq" 2>/dev/null)" || true
  fi
  [[ -n "$min" || -n "$max" ]] && [[ -z "$src" ]] && src="sysfs_cpufreq"

  if [[ -z "$cur" && -z "$min" && -z "$max" ]]; then
    note="CPU frequency data unavailable from hypervisor (typical for KVM guests without cpufreq)"
  fi

  jq -n \
    --arg cur "${cur:-}" \
    --arg min "${min:-}" \
    --arg max "${max:-}" \
    --arg src "${src:-}" \
    --arg note "${note:-}" \
    '{
      current: (if $cur == "" then null else ($cur | tonumber) end),
      min: (if $min == "" then null else ($min | tonumber) end),
      max: (if $max == "" then null else ($max | tonumber) end),
      source: (if $src == "" then null else $src end),
      available: (($cur != "") or ($min != "") or ($max != "")),
      note: (if $note == "" then null else $note end)
    }'
}

read_cpu_mhz() {
  local mhz
  mhz="$(collect_cpu_mhz_info | jq -r '.current // empty')"
  [[ -n "$mhz" && "$mhz" != "null" ]] || return 1
  printf '%s' "$mhz"
}

parse_sysbench_events_per_s() {
  echo "$1" | awk -F: '/events per second/{gsub(/^[ \t]+/,"",$2); print $2; exit}'
}

sysbench_version() {
  sysbench --version 2>&1 | head -1 | awk '{print $2}'
}

cpu_thread_cap() {
  local max_threads="${CPU_THREADS:-${SYSBENCH_CPU_MAX_THREADS:-}}"
  if [[ -z "$max_threads" ]]; then
    max_threads="$(lscpu_field 'CPU(s)' || echo 2)"
    [[ "$max_threads" -gt 8 ]] && max_threads=8
    [[ "$max_threads" -lt 2 ]] && max_threads=2
  fi
  printf '%s' "$max_threads"
}

curl_https_timings_ms() {
  local url=$1
  local out connect_ms appconnect_ms
  out="$(curl -sS -o /dev/null -w '%{time_connect} %{time_appconnect}' \
    --connect-timeout 10 --max-time 15 "$url" 2>/dev/null)" || return 1
  connect_ms="$(awk '{printf "%.2f", $1 * 1000}' <<<"$out")"
  appconnect_ms="$(awk '{printf "%.2f", $2 * 1000}' <<<"$out")"
  jq -n --arg connect "$connect_ms" --arg appconnect "$appconnect_ms" \
    '{tcp_connect_ms: ($connect | tonumber), tls_appconnect_ms: ($appconnect | tonumber)}'
}

lscpu_field() {
  local field=$1
  if command -v lscpu >/dev/null 2>&1; then
    lscpu 2>/dev/null | awk -F: -v f="$field" '$1 == f {sub(/^[ \t]+/,"",$2); print $2; exit}'
  fi
}

cpu_flag_enabled() {
  local flag=$1
  if command -v lscpu >/dev/null 2>&1; then
    lscpu 2>/dev/null | awk -v f="$flag" '/Flags:/{print; exit}' | grep -qw "$flag" && return 0
  fi
  grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -qw "$flag"
}

parse_sysbench_memory_mib_s() {
  echo "$1" | sed -n 's/.*(\([0-9.]*\) MiB\/sec).*/\1/p' | head -1
}

run_sysbench_memory() {
  local oper=$1 mode=$2 mem_mib=$3 seconds=$4
  local out
  out="$(sysbench memory \
    --memory-total-size="${mem_mib}M" \
    --memory-oper="$oper" \
    --memory-access-mode="$mode" \
    --threads=1 \
    --time="$seconds" \
    run 2>&1)" || return 1
  parse_sysbench_memory_mib_s "$out"
}

# --- reproducibility / sampling ----------------------------------------------

bench_cleanup() {
  sync 2>/dev/null || true
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] && [[ -w /proc/sys/vm/drop_caches ]]; then
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  fi
  local settle
  settle="$(awk -v ms="${BENCH_SETTLE_MS}" 'BEGIN { printf "%.3f", ms/1000 }')"
  sleep "$settle"
}

# Aggregate sample lines from stdin into mean/min/max/stddev/CV statistics (JSON).
bench_compute_stats() {
  jq -s '
    [.[] | tonumber] as $vals
    | if ($vals | length) == 0 then
        {samples: [], mean: null, min: null, max: null, stddev: null, cv_percent: null}
      else
        ($vals | sort) as $s
        | ($s | length) as $n
        | ($vals | add / $n) as $mean
        | (if $n < 2 then 0
           else ($vals | map((. - $mean) * (. - $mean)) | add / ($n - 1) | sqrt) end) as $sd
        | {
            samples: $vals,
            mean: ($mean * 100 | round | . / 100),
            min: ($s[0] * 100 | round | . / 100),
            max: ($s[-1] * 100 | round | . / 100),
            stddev: ($sd * 100 | round | . / 100),
            cv_percent: (
              if $mean != 0 and $n >= 2 then ($sd / $mean * 100 * 100 | round | . / 100) else null end
            )
          }
      end
  '
}

bench_stability_rating() {
  local cv="${1:-}"
  [[ -z "$cv" || "$cv" == "null" ]] && { echo "unknown"; return; }
  awk -v cv="$cv" 'BEGIN {
    if (cv <= 3) print "stable";
    else if (cv <= 8) print "moderate";
    else print "unstable";
  }'
}

bench_metric_score() {
  local name=$1 unit=$2 formula=$3 stats_json=$4
  local mean cv rating
  mean="$(echo "$stats_json" | jq -r '.mean // empty')"
  cv="$(echo "$stats_json" | jq -r '.cv_percent // empty')"
  rating="$(bench_stability_rating "$cv")"
  jq -n \
    --arg name "$name" \
    --arg unit "$unit" \
    --arg formula "$formula" \
    --arg rating "$rating" \
    --argjson stats "$stats_json" \
    '{
      metric: $name,
      unit: $unit,
      value: $stats.mean,
      formula: $formula,
      statistics: $stats,
      stability: $rating
    }'
}

# --- benchmark steps ---------------------------------------------------------

step_install_tools() {
  if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
    log "SKIP_INSTALL=1; verifying tool availability"
    verify_core_tools
    return 0
  fi

  require_root
  local pm os_id
  pm="$(detect_pkg_manager)"
  os_id="$(detect_os_id)"
  log "detected os=$os_id pkg_manager=$pm"

  case "$pm" in
    apt)
      apt_install_packages sysbench fio jq curl dnsutils || \
        die "could not install required packages (apt): sysbench fio jq curl dnsutils"
      ;;
    dnf)
      ensure_epel_rhel
      dnf_install_packages sysbench fio jq curl ca-certificates coreutils bind-utils || \
        die "could not install core packages on dnf (enable EPEL on RHEL family)"
      ;;
    yum)
      ensure_epel_rhel
      yum_install_packages sysbench fio jq curl ca-certificates coreutils bind-utils || \
        die "could not install core packages on yum (enable EPEL on RHEL family)"
      ;;
    apk)
      pkg_install bash sysbench fio jq curl ca-certificates coreutils bind-tools || \
        die "could not install core packages (apk)"
      ;;
    zypper)
      pkg_install sysbench fio jq curl ca-certificates coreutils bind-utils || \
        die "could not install core packages (zypper)"
      ;;
    pacman)
      pkg_install sysbench fio jq curl ca-certificates coreutils || \
        die "could not install core packages (pacman)"
      pkg_install_dns_utils
      ;;
    *)
      die "unsupported package manager (os=$os_id). Install manually: sysbench fio jq curl"
      ;;
  esac

  if [[ "${RUN_SPEEDTEST:-0}" == "1" ]]; then
    pkg_install_optional speedtest-cli speedtest
  fi

  verify_core_tools
  log "install-tools: complete ($(sysbench --version 2>&1 | head -1))"
}

step_host_probe() {
  require_cmd jq
  ensure_steps_dir

  local kernel arch hostname os_id os_version cpu_model=""
  local mem_total_kb mem_available_kb swap_total_kb swap_free_kb
  local sockets=1 cores_per_socket=1 threads_per_core=1 logical_cpus=1
  local architecture="" cpu_op_mode="" virt_lscpu="" thread_siblings=""
  local mhz_json aes_ni=false sha_ni=false sb_ver="" virt=""

  kernel="$(uname -r)"
  arch="$(uname -m)"
  hostname="$(read_host_shortname)"
  os_id="$(detect_os_id)"
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    os_version="${VERSION_ID:-}${NAME:+ ($NAME)}"
  fi

  mhz_json="$(collect_cpu_mhz_info)"
  cpu_model="$(lscpu_field 'Model name')"
  [[ -z "$cpu_model" ]] && cpu_model="$(awk -F: '/model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  sockets="$(lscpu_field 'Socket(s)' || echo 1)"
  cores_per_socket="$(lscpu_field 'Core(s) per socket' || echo 1)"
  threads_per_core="$(lscpu_field 'Thread(s) per core' || echo 1)"
  logical_cpus="$(lscpu_field 'CPU(s)' || echo 1)"
  architecture="$(lscpu_field 'Architecture')"
  cpu_op_mode="$(lscpu_field 'CPU op-mode')"
  virt_lscpu="$(lscpu_field 'Virtualization type')"
  thread_siblings="$(lscpu_field 'Thread sibling')"

  local total_cores=$(( sockets * cores_per_socket ))
  local l1d l1i l2 l3 numa_nodes numa
  l1d="$(lscpu_field 'L1d cache')"
  l1i="$(lscpu_field 'L1i cache')"
  l2="$(lscpu_field 'L2 cache')"
  l3="$(lscpu_field 'L3 cache')"
  numa_nodes="$(lscpu_field 'NUMA node(s)')"
  numa="$(lscpu_field 'NUMA node0 CPU(s)')"
  cpu_flag_enabled aes && aes_ni=true
  cpu_flag_enabled sha_ni && sha_ni=true

  mem_total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  mem_available_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  swap_total_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  swap_free_kb="$(awk '/SwapFree/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"

  command -v sysbench >/dev/null 2>&1 && sb_ver="$(sysbench_version)"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    [[ "$virt" == "none" ]] && virt="bare-metal-or-unknown"
  fi

  jq -n \
    --arg code "host_probe" \
    --arg kernel "$kernel" \
    --arg arch "$arch" \
    --arg hostname "$hostname" \
    --arg os_id "$os_id" \
    --arg os_version "$os_version" \
    --arg model "${cpu_model:-unknown}" \
    --argjson mem_total_kb "$mem_total_kb" \
    --argjson mem_available_kb "$mem_available_kb" \
    --argjson swap_total_kb "$swap_total_kb" \
    --argjson swap_free_kb "$swap_free_kb" \
    --arg sysbench_version "$sb_ver" \
    --arg virtualization "$virt" \
    --argjson mhz "$mhz_json" \
    --argjson sockets "${sockets:-1}" \
    --argjson cores_per_socket "${cores_per_socket:-1}" \
    --argjson threads_per_core "${threads_per_core:-1}" \
    --argjson logical_cpus "${logical_cpus:-1}" \
    --argjson total_cores "$total_cores" \
    --arg architecture "${architecture:-}" \
    --arg cpu_op_mode "${cpu_op_mode:-}" \
    --arg virt_lscpu "${virt_lscpu:-}" \
    --arg thread_siblings "${thread_siblings:-}" \
    --arg l1d "${l1d:-}" \
    --arg l1i "${l1i:-}" \
    --arg l2 "${l2:-}" \
    --arg l3 "${l3:-}" \
    --arg numa_nodes "${numa_nodes:-}" \
    --arg numa "${numa:-}" \
    --argjson aes_ni "$aes_ni" \
    --argjson sha_ni "$sha_ni" \
    '{
      code: $code,
      host: {
        hostname: $hostname,
        kernel: $kernel,
        arch: $arch,
        os_id: $os_id,
        os_version: $os_version,
        virtualization: (if $virtualization == "" then null else $virtualization end),
        mem_total_mib: (if $mem_total_kb > 0 then ($mem_total_kb / 1024) else null end),
        mem_available_mib: (if $mem_available_kb > 0 then ($mem_available_kb / 1024) else null end),
        swap_total_mib: (if $swap_total_kb > 0 then ($swap_total_kb / 1024) else null end),
        swap_free_mib: (if $swap_free_kb > 0 then ($swap_free_kb / 1024) else null end)
      },
      cpu: {
        model_name: $model,
        architecture: (if $architecture == "" then null else $architecture end),
        cpu_op_mode: (if $cpu_op_mode == "" then null else $cpu_op_mode end),
        virtualization_type: (if $virt_lscpu == "" then null else $virt_lscpu end),
        sockets: $sockets,
        cores_per_socket: $cores_per_socket,
        total_cores: $total_cores,
        threads_per_core: $threads_per_core,
        logical_cpus: $logical_cpus,
        thread_siblings: (if $thread_siblings == "" then null else $thread_siblings end),
        cache: {
          l1d: (if $l1d == "" then null else $l1d end),
          l1i: (if $l1i == "" then null else $l1i end),
          l2: (if $l2 == "" then null else $l2 end),
          l3: (if $l3 == "" then null else $l3 end)
        },
        numa_nodes: (if $numa_nodes == "" then null else ($numa_nodes | tonumber?) end),
        numa_node0_cpus: (if $numa == "" then null else $numa end),
        aes_ni: $aes_ni,
        sha_ni: $sha_ni,
        mhz: $mhz
      },
      sysbench_version: (if $sysbench_version == "" then null else $sysbench_version end)
    }' >"$RESULTS_DIR/steps/host_probe.json"

  if [[ "$(echo "$mhz_json" | jq -r '.available')" == "true" ]]; then
    log "host-probe: complete ($os_id $arch, ${cpu_model:-unknown}, ${logical_cpus} CPUs, $(echo "$mhz_json" | jq -r '.current // .max // "n/a"') MHz)"
  else
    log "host-probe: complete ($os_id $arch, ${cpu_model:-unknown}, ${logical_cpus} CPUs)"
  fi
}

step_cpu_sysbench() {
  require_cmd sysbench jq
  ensure_steps_dir

  local cpu_seconds="${SYSBENCH_CPU_SECONDS:-10}"
  local samples="$BENCH_SAMPLES" warmup="$BENCH_WARMUP"
  local max_threads
  max_threads="$(cpu_thread_cap)"
  local cpu_max_prime=20000

  run_cpu_once() {
    local threads=$1 out
    out="$(sysbench cpu --cpu-max-prime="$cpu_max_prime" --threads="$threads" --time="$cpu_seconds" run 2>&1)" || return 1
    parse_sysbench_events_per_s "$out"
  }

  local steal_before mhz_before steal_after mhz_after
  steal_before="$(steal_percent)"
  mhz_before="$(read_cpu_mhz || echo "")"

  local w i v single_lines="" multi_lines=""
  for ((w = 0; w < warmup; w++)); do
    sysbench cpu --cpu-max-prime="$cpu_max_prime" --threads=1 --time=3 run >/dev/null 2>&1 || true
    bench_cleanup
  done

  for ((i = 0; i < samples; i++)); do
    bench_cleanup
    if v="$(run_cpu_once 1)"; then
      single_lines+="${v}"$'\n'
      log "cpu sample $((i + 1))/${samples} single: ${v} events/s"
    else
      warn "cpu single sample $((i + 1)) failed"
    fi
    if [[ "$max_threads" -ge 2 ]]; then
      bench_cleanup
      if v="$(run_cpu_once "$max_threads")"; then
        multi_lines+="${v}"$'\n'
        log "cpu sample $((i + 1))/${samples} multi (${max_threads}t): ${v} events/s"
      else
        warn "cpu multi sample $((i + 1)) failed"
      fi
    fi
  done

  local single_stats multi_stats
  single_stats="$(printf '%s' "$single_lines" | bench_compute_stats)"
  multi_stats="$(printf '%s' "$multi_lines" | bench_compute_stats)"

  if [[ "$(echo "$single_stats" | jq '.samples | length')" -eq 0 ]]; then
    write_step_failure cpu_sysbench "all single-core cpu samples failed"
    exit 1
  fi

  steal_after="$(steal_percent)"
  mhz_after="$(read_cpu_mhz || echo "")"

  local throttle_warn=false
  if [[ -n "$mhz_before" && -n "$mhz_after" ]]; then
    if awk -v b="$mhz_before" -v a="$mhz_after" 'BEGIN { exit (b > 0 && a < b * 0.85) ? 0 : 1 }'; then
      throttle_warn=true
    fi
  fi

  local sb_ver single_score multi_score efficiency
  sb_ver="$(sysbench_version)"
  single_score="$(bench_metric_score "single_core_events_per_s" "events_per_second" \
    "mean of ${samples} sysbench CPU samples, threads=1, after warmup and cache sync" \
    "$single_stats")"
  multi_score="$(bench_metric_score "multi_core_events_per_s" "events_per_second" \
    "mean of ${samples} sysbench CPU samples, threads=${max_threads}, after warmup and cache sync" \
    "$multi_stats")"
  efficiency="$(jq -n \
    --argjson single "$single_stats" \
    --argjson multi "$multi_stats" \
    'if ($single.mean != null and $multi.mean != null and $single.mean > 0)
     then {value: (($multi.mean / $single.mean) * 100 | round | . / 100), unit: "x", formula: "multi_core_mean / single_core_mean"}
     else null end')"

  jq -n \
    --arg code "cpu_sysbench" \
    --argjson seconds "$cpu_seconds" \
    --argjson samples "$samples" \
    --argjson warmup "$warmup" \
    --argjson max_threads "$max_threads" \
    --argjson cpu_max_prime "$cpu_max_prime" \
    --arg sysbench_version "$sb_ver" \
    --arg steal_b "$steal_before" \
    --arg steal_a "$steal_after" \
    --arg mhz_b "$mhz_before" \
    --arg mhz_a "$mhz_after" \
    --argjson throttle "$throttle_warn" \
    --argjson single_score "$single_score" \
    --argjson multi_score "$multi_score" \
    --argjson efficiency "$efficiency" \
    '{
      code: $code,
      tool: "sysbench",
      tool_version: $sysbench_version,
      test: "cpu",
      cpu_max_prime: $cpu_max_prime,
      duration_seconds_per_sample: $seconds,
      samples: $samples,
      warmup_runs: $warmup,
      max_threads_tested: $max_threads,
      single_core: $single_score,
      multi_core: $multi_score,
      scaling_efficiency: $efficiency,
      steal_percent_before: ($steal_b | tonumber),
      steal_percent_after: ($steal_a | tonumber),
      cpu_mhz_before: (if $mhz_b == "" then null else ($mhz_b | tonumber) end),
      cpu_mhz_after: (if $mhz_a == "" then null else ($mhz_a | tonumber) end),
      throttle_warn: $throttle
    }' >"$RESULTS_DIR/steps/cpu_sysbench.json"

  log "cpu-sysbench: complete (single-core mean=$(echo "$single_stats" | jq -r '.mean') events/s)"
}

step_memory_sysbench() {
  require_cmd sysbench jq
  ensure_steps_dir

  local mem_total_kb mem_mib="${SYSBENCH_MEMORY_MIB:-256}" mem_seconds="${SYSBENCH_MEMORY_SECONDS:-10}"
  local samples="$BENCH_SAMPLES" warmup="$BENCH_WARMUP"
  mem_total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"

  if [[ "$mem_total_kb" -gt 0 ]]; then
    local half_mib=$((mem_total_kb / 1024 / 2))
    [[ "$half_mib" -lt "$mem_mib" ]] && mem_mib="$half_mib"
  fi
  [[ "$mem_mib" -lt 64 ]] && mem_mib=64

  local w i v write_lines="" read_lines="" sb_ver
  sb_ver="$(sysbench_version)"

  for ((w = 0; w < warmup; w++)); do
    run_sysbench_memory write seq "$mem_mib" 3 >/dev/null 2>&1 || true
    bench_cleanup
  done

  for ((i = 0; i < samples; i++)); do
    bench_cleanup
    if v="$(run_sysbench_memory write seq "$mem_mib" "$mem_seconds")"; then
      write_lines+="${v}"$'\n'
      log "memory sample $((i + 1))/${samples} write: ${v} MiB/s"
    else
      warn "memory write sample $((i + 1)) failed"
    fi
    bench_cleanup
    if v="$(run_sysbench_memory read seq "$mem_mib" "$mem_seconds")"; then
      read_lines+="${v}"$'\n'
      log "memory sample $((i + 1))/${samples} read: ${v} MiB/s"
    else
      warn "memory read sample $((i + 1)) failed"
    fi
  done

  local write_stats read_stats
  write_stats="$(printf '%s' "$write_lines" | bench_compute_stats)"
  read_stats="$(printf '%s' "$read_lines" | bench_compute_stats)"

  if [[ "$(echo "$write_stats" | jq '.samples | length')" -eq 0 ]]; then
    write_step_failure memory_sysbench "all memory write samples failed"
    exit 1
  fi

  local write_score read_score
  write_score="$(bench_metric_score "sequential_write_mib_s" "mib_per_second" \
    "mean of ${samples} sysbench memory sequential write samples after warmup and cache sync" \
    "$write_stats")"
  read_score="$(bench_metric_score "sequential_read_mib_s" "mib_per_second" \
    "mean of ${samples} sysbench memory sequential read samples after warmup and cache sync" \
    "$read_stats")"

  jq -n \
    --arg code "memory_sysbench" \
    --argjson mem_mib "$mem_mib" \
    --argjson seconds "$mem_seconds" \
    --argjson samples "$samples" \
    --argjson warmup "$warmup" \
    --arg sysbench_version "$sb_ver" \
    --argjson write_score "$write_score" \
    --argjson read_score "$read_score" \
    '{
      code: $code,
      tool: "sysbench",
      tool_version: $sysbench_version,
      working_set_mib: $mem_mib,
      duration_seconds_per_sample: $seconds,
      samples: $samples,
      warmup_runs: $warmup,
      sequential_write: $write_score,
      sequential_read: $read_score
    }' >"$RESULTS_DIR/steps/memory_sysbench.json"

  log "memory-sysbench: complete (write mean=$(echo "$write_stats" | jq -r '.mean') read mean=$(echo "$read_stats" | jq -r '.mean') MiB/s)"
}

step_storage_info() {
  require_cmd jq
  ensure_steps_dir

  local root_src fstype size_b avail_b disk_name rota tran storage_type="unknown"
  root_src="$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"
  fstype="$(df -PT / 2>/dev/null | awk 'NR==2{print $2}')"
  size_b="$(df_field_bytes 2)"
  avail_b="$(df_field_bytes 4)"

  if [[ -n "$root_src" ]] && command -v lsblk >/dev/null 2>&1; then
    disk_name="$(lsblk -ndo NAME "$root_src" 2>/dev/null | head -1)"
    if [[ -n "$disk_name" ]]; then
      read -r rota tran <<<"$(lsblk -d -no ROTA,TRAN "/dev/$disk_name" 2>/dev/null | head -1)"
      if [[ "$tran" == "nvme" ]]; then storage_type="nvme"
      elif [[ "$rota" == "0" ]]; then storage_type="ssd"
      elif [[ "$rota" == "1" ]]; then storage_type="hdd"
      fi
    fi
  fi

  local size_gib="" avail_gib=""
  [[ -n "$size_b" && "$size_b" -gt 0 ]] && size_gib="$(awk -v b="$size_b" 'BEGIN { printf "%.2f", b/1073741824 }')"
  [[ -n "$avail_b" && "$avail_b" -gt 0 ]] && avail_gib="$(awk -v b="$avail_b" 'BEGIN { printf "%.2f", b/1073741824 }')"

  jq -n \
    --arg code "storage_info" \
    --arg root_device "${root_src:-}" \
    --arg fstype "${fstype:-}" \
    --arg disk_name "${disk_name:-}" \
    --arg storage_type "$storage_type" \
    --arg tran "${tran:-}" \
    --arg size_gib "$size_gib" \
    --arg avail_gib "$avail_gib" \
    '{
      code: $code,
      root_device: (if $root_device == "" then null else $root_device end),
      filesystem_type: (if $fstype == "" then null else $fstype end),
      block_device: (if $disk_name == "" then null else $disk_name end),
      storage_type: $storage_type,
      transport: (if $tran == "" then null else $tran end),
      root_size_gib: (if $size_gib == "" then null else ($size_gib | tonumber) end),
      root_avail_gib: (if $avail_gib == "" then null else ($avail_gib | tonumber) end)
    }' >"$RESULTS_DIR/steps/storage_info.json"

  log "storage-info: complete (${storage_type} ${fstype} on ${root_src:-unknown})"
}

step_disk_fio() {
  ensure_steps_dir

  if ! command -v fio >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    write_step_failure disk_fio "fio or jq not installed"
    warn "disk-fio omitted (install fio or set SKIP_INSTALL=1)"
    return 0
  fi

  local fio_size="${FIO_SIZE:-64M}" fio_runtime="${FIO_RUNTIME:-15}"
  local fio_file="${FIO_FILE:-$RESULTS_DIR/fio.dat}"
  local samples="$BENCH_SAMPLES"
  mkdir -p "$(dirname "$fio_file")"

  run_fio_mib_s() {
    local rw=$1
    rm -f "$fio_file" 2>/dev/null || true
    bench_cleanup
    local json
    json="$(fio --name="seq_${rw}" --filename="$fio_file" --rw="$rw" --bs=1M --size="$fio_size" \
      --numjobs=1 --iodepth=1 --direct=1 --runtime="$fio_runtime" --time_based=1 \
      --output-format=json 2>/dev/null)" || return 1
    rm -f "$fio_file" 2>/dev/null || true
    if [[ "$rw" == "read" ]]; then
      echo "$json" | jq -r '.jobs[0].read.bw_bytes // 0 | . / 1048576'
    else
      echo "$json" | jq -r '.jobs[0].write.bw_bytes // 0 | . / 1048576'
    fi
  }

  local i v read_lines="" write_lines=""
  for ((i = 0; i < samples; i++)); do
    if v="$(run_fio_mib_s read)"; then
      read_lines+="${v}"$'\n'
      log "disk sample $((i + 1))/${samples} read: ${v} MiB/s"
    else
      warn "disk read sample $((i + 1)) failed"
    fi
    if v="$(run_fio_mib_s write)"; then
      write_lines+="${v}"$'\n'
      log "disk sample $((i + 1))/${samples} write: ${v} MiB/s"
    else
      warn "disk write sample $((i + 1)) failed"
    fi
  done

  local read_stats write_stats
  read_stats="$(printf '%s' "$read_lines" | bench_compute_stats)"
  write_stats="$(printf '%s' "$write_lines" | bench_compute_stats)"

  if [[ "$(echo "$read_stats" | jq '.samples | length')" -eq 0 ]]; then
    write_step_failure disk_fio "all disk read samples failed"
    warn "disk-fio incomplete (verify disk space and permissions for $fio_file)"
    return 0
  fi

  local fio_ver=""
  command -v fio >/dev/null 2>&1 && fio_ver="$(fio --version 2>&1 | head -1 | awk '{print $2}')"

  local read_score write_score
  read_score="$(bench_metric_score "sequential_read_mib_s" "mib_per_second" \
    "mean of ${samples} fio sequential read samples (1M direct I/O) after cache sync" \
    "$read_stats")"
  write_score="$(bench_metric_score "sequential_write_mib_s" "mib_per_second" \
    "mean of ${samples} fio sequential write samples (1M direct I/O) after cache sync" \
    "$write_stats")"

  jq -n \
    --arg code "disk_fio" \
    --arg fio_size "$fio_size" \
    --argjson fio_runtime "$fio_runtime" \
    --arg fio_file "$fio_file" \
    --arg fio_version "$fio_ver" \
    --argjson samples "$samples" \
    --argjson read_score "$read_score" \
    --argjson write_score "$write_score" \
    '{
      code: $code,
      tool: "fio",
      tool_version: (if $fio_version == "" then null else $fio_version end),
      test_file: $fio_file,
      test_size: $fio_size,
      runtime_seconds_per_sample: $fio_runtime,
      samples: $samples,
      direct_io: true,
      iodepth: 1,
      numjobs: 1,
      sequential_read: $read_score,
      sequential_write: $write_score
    }' >"$RESULTS_DIR/steps/disk_fio.json"

  log "disk-fio: complete (read mean=$(echo "$read_stats" | jq -r '.mean') write mean=$(echo "$write_stats" | jq -r '.mean') MiB/s)"
}

step_network_probe() {
  require_cmd jq curl
  ensure_steps_dir

  local ping_target="${PING_TARGET:-1.1.1.1}"
  local ping6_target="${PING6_TARGET:-2606:4700:4700::1111}"
  local https_target="${HTTPS_TARGET:-${TLS_TARGET:-${TCP_CONNECT_TARGET:-https://google.com}}}"
  local dns_target="${DNS_TARGET:-google.com}"
  local dns_resolver="${DNS_RESOLVER:-1.1.1.1}"
  local ipv4=false ipv6=false ping_out="" ping6_out=""
  local loss="" avg="" mdev="" loss6="" avg6=""
  local dns_ms="" dns_tool="getent"
  local curl_timings="null"

  ip -4 addr show scope global 2>/dev/null | grep -q 'inet ' && ipv4=true
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' && ipv6=true

  if command -v dig >/dev/null 2>&1; then
    dns_tool="dig"
    dns_ms="$(dig @"$dns_resolver" "$dns_target" +stats 2>/dev/null | awk '/Query time:/{print $4; exit}')"
  elif command -v drill >/dev/null 2>&1; then
    dns_tool="drill"
    dns_ms="$(drill @"$dns_resolver" "$dns_target" 2>/dev/null | awk '/Query time:/{print $3; exit}')"
  elif command -v getent >/dev/null 2>&1; then
    local start end
    start=$(date +%s%N)
    getent hosts "$dns_target" >/dev/null 2>&1 || true
    end=$(date +%s%N)
    dns_ms=$(( (end - start) / 1000000 ))
  fi

  if command -v ping >/dev/null 2>&1; then
    ping_out="$(ping -c "${PING_COUNT:-10}" -W "${PING_TIMEOUT:-2}" "$ping_target" 2>/dev/null)" || ping_out=""
    loss="$(echo "$ping_out" | awk -F',' '/packet loss/{for(i=1;i<=NF;i++) if($i~/loss/) print $i}' | grep -oE '[0-9]+' | head -1)"
    mapfile -t _rtt < <(echo "$ping_out" | awk '/^rtt /{print; exit}' | grep -oE '[0-9]+\.[0-9]+')
    avg="${_rtt[1]:-}"
    mdev="${_rtt[3]:-}"
  fi

  if $ipv6 && command -v ping6 >/dev/null 2>&1; then
    ping6_out="$(ping6 -c "${PING_COUNT:-10}" -W "${PING_TIMEOUT:-2}" "$ping6_target" 2>/dev/null)" || ping6_out=""
    loss6="$(echo "$ping6_out" | awk -F',' '/packet loss/{for(i=1;i<=NF;i++) if($i~/loss/) print $i}' | grep -oE '[0-9]+' | head -1)"
    mapfile -t _rtt6 < <(echo "$ping6_out" | awk '/^rtt /{print; exit}' | grep -oE '[0-9]+\.[0-9]+')
    avg6="${_rtt6[1]:-}"
  elif $ipv6 && command -v ping >/dev/null 2>&1; then
    ping6_out="$(ping -6 -c "${PING_COUNT:-10}" -W "${PING_TIMEOUT:-2}" "$ping6_target" 2>/dev/null)" || ping6_out=""
    loss6="$(echo "$ping6_out" | awk -F',' '/packet loss/{for(i=1;i<=NF;i++) if($i~/loss/) print $i}' | grep -oE '[0-9]+' | head -1)"
    mapfile -t _rtt6 < <(echo "$ping6_out" | awk '/^rtt /{print; exit}' | grep -oE '[0-9]+\.[0-9]+')
    avg6="${_rtt6[1]:-}"
  fi

  if curl_timings="$(curl_https_timings_ms "$https_target" 2>/dev/null)"; then
    :
  else
    curl_timings="null"
    warn "HTTPS probe to $https_target failed"
  fi

  jq -n \
    --arg code "network_probe" \
    --argjson ipv4 "$ipv4" \
    --argjson ipv6 "$ipv6" \
    --arg ping_target "$ping_target" \
    --arg ping6_target "$ping6_target" \
    --arg https_target "$https_target" \
    --arg dns_target "$dns_target" \
    --arg dns_resolver "$dns_resolver" \
    --arg dns_tool "$dns_tool" \
    --arg dns_ms "${dns_ms:-}" \
    --arg loss "${loss:-}" \
    --arg avg "${avg:-}" \
    --arg mdev "${mdev:-}" \
    --arg loss6 "${loss6:-}" \
    --arg avg6 "${avg6:-}" \
    --argjson curl "$curl_timings" \
    '{
      code: $code,
      ipv4_enabled: $ipv4,
      ipv6_enabled: $ipv6,
      dns: {
        tool: $dns_tool,
        query: $dns_target,
        resolver: $dns_resolver,
        resolve_ms: (if $dns_ms == "" then null else ($dns_ms | tonumber) end)
      },
      icmp_ipv4: {
        target: $ping_target,
        packet_loss_percent: (if $loss == "" then null else ($loss | tonumber) end),
        rtt_avg_ms: (if $avg == "" then null else ($avg | tonumber) end),
        jitter_ms: (if $mdev == "" then null else ($mdev | tonumber) end)
      },
      icmp_ipv6: (
        if $ipv6 == false then null
        else {
          target: $ping6_target,
          packet_loss_percent: (if $loss6 == "" then null else ($loss6 | tonumber) end),
          rtt_avg_ms: (if $avg6 == "" then null else ($avg6 | tonumber) end)
        }
        end
      ),
      https: (
        if $curl == null then null
        else { target: $https_target, tcp_connect_ms: $curl.tcp_connect_ms, tls_appconnect_ms: $curl.tls_appconnect_ms }
        end
      )
    }' >"$RESULTS_DIR/steps/network_probe.json"

  log "network-probe: complete (icmp_avg_ms=${avg:-n/a} dns_ms=${dns_ms:-n/a} https=$https_target)"
}

# Convert curl speed_download / speed_upload (bytes/s) to megabits per second.
bps_to_mbps() {
  awk -v s="${1:-0}" 'BEGIN { printf "%.2f", (s * 8) / 1000000 }'
}

# Convert speedtest-cli JSON bit rates to megabits per second.
speedtest_cli_bps_to_mbps() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b / 1000000 }'
}

run_speedtest_net() {
  # Optional Speedtest.net measurement (speedtest-cli or Ookla CLI). Returns JSON on stdout.
  local json="" tool="" ver="" dl_mbps="" ul_mbps="" ping_ms="" server=""
  local st_bin="" st_ver_out=""

  if [[ "${RUN_SPEEDTEST:-0}" != "1" ]]; then
    return 1
  fi
  if [[ "${SKIP_SPEEDTEST:-0}" == "1" ]]; then
    return 1
  fi

  if command -v speedtest-cli >/dev/null 2>&1; then
    st_bin="speedtest-cli"
  elif command -v speedtest >/dev/null 2>&1; then
    st_ver_out="$(speedtest --version 2>&1 | head -1)"
    if grep -qi ookla <<<"$st_ver_out"; then
      st_bin="speedtest-ookla"
    else
      st_bin="speedtest-cli"
    fi
  else
    return 1
  fi

  case "$st_bin" in
    speedtest-cli)
      tool="speedtest-cli"
      ver="$(speedtest-cli --version 2>&1 | head -1 | awk '{print $NF}')"
      if [[ ! -x "$(command -v speedtest-cli)" ]] && command -v speedtest >/dev/null 2>&1; then
        json="$(speedtest --json 2>/dev/null)" || json="$(speedtest --json --secure 2>/dev/null)" || json=""
      else
        json="$(speedtest-cli --json 2>/dev/null)" || json="$(speedtest-cli --json --secure 2>/dev/null)" || json=""
      fi
      if [[ -n "$json" ]]; then
        dl_mbps="$(speedtest_cli_bps_to_mbps "$(echo "$json" | jq -r '.download // 0')")"
        ul_mbps="$(speedtest_cli_bps_to_mbps "$(echo "$json" | jq -r '.upload // 0')")"
        ping_ms="$(echo "$json" | jq -r '.ping // empty' 2>/dev/null)"
        server="$(echo "$json" | jq -r '.server.name // .server.sponsor // empty' 2>/dev/null)"
      fi
      ;;
    speedtest-ookla)
      tool="speedtest"
      ver="$(speedtest --version 2>&1 | head -1 | awk '{print $NF}')"
      json="$(speedtest -f json --accept-license --accept-gdpr 2>/dev/null)" || json=""
      if [[ -n "$json" ]]; then
        dl_mbps="$(echo "$json" | jq -r '(.download.bandwidth // 0) | . * 8 / 1000000' 2>/dev/null | awk '{printf "%.2f", $1}')"
        ul_mbps="$(echo "$json" | jq -r '(.upload.bandwidth // 0) | . * 8 / 1000000' 2>/dev/null | awk '{printf "%.2f", $1}')"
        ping_ms="$(echo "$json" | jq -r '.ping.latency // empty' 2>/dev/null)"
        server="$(echo "$json" | jq -r '.server.name // .server.host // empty' 2>/dev/null)"
      fi
      ;;
  esac

  [[ -n "$json" && -n "$dl_mbps" && "$dl_mbps" != "0.00" ]] || return 1

  jq -n \
    --arg tool "$tool" \
    --arg ver "$ver" \
    --arg dl "$dl_mbps" \
    --arg ul "$ul_mbps" \
    --arg ping "${ping_ms:-}" \
    --arg server "${server:-}" \
    '{
      source: "speedtest.net",
      tool: $tool,
      tool_version: (if $ver == "" then null else $ver end),
      server: (if $server == "" then null else $server end),
      ping_ms: (if $ping == "" then null else ($ping | tonumber) end),
      download_mbps: ($dl | tonumber),
      upload_mbps: (if $ul == "" or $ul == "0.00" then null else ($ul | tonumber) end)
    }'
}

run_http_download_test() {
  local -a urls=() timeout="${NETWORK_DOWNLOAD_TIMEOUT:-30}"
  if [[ -n "${NETWORK_DOWNLOAD_URL:-}" ]]; then
    urls+=("$NETWORK_DOWNLOAD_URL")
  else
    urls+=(
      "https://proof.ovh.net/files/10Mb.dat"
      "http://speedtest.tele2.net/10MB.zip"
      "https://speed.hetzner.de/10MB.bin"
    )
  fi

  local url="" curl_out="" time_total="" bytes="" speed_bps="" mbps=""
  for url in "${urls[@]}"; do
    log "network download: $url"
    if curl_out="$(curl -sS -L -o /dev/null \
      --connect-timeout 15 --max-time "$timeout" \
      -w '%{time_total} %{size_download} %{speed_download}' \
      "$url" 2>/dev/null)"; then
      time_total="$(awk '{print $1}' <<<"$curl_out")"
      bytes="$(awk '{print $2}' <<<"$curl_out")"
      speed_bps="$(awk '{print $3}' <<<"$curl_out")"
      if [[ -n "$bytes" ]] && awk -v b="$bytes" 'BEGIN { exit (b >= 5000000) ? 0 : 1 }'; then
        mbps="$(bps_to_mbps "$speed_bps")"
        jq -n \
          --arg url "$url" --argjson bytes "$bytes" --arg time_total "$time_total" \
          --argjson speed_bps "$speed_bps" --arg mbps "$mbps" \
          --arg mib "$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1048576 }')" \
          '{ ok: true, url: $url, bytes_downloaded: $bytes, size_mib: ($mib|tonumber),
             duration_seconds: ($time_total|tonumber), speed_bytes_per_second: $speed_bps,
             throughput_mbps: ($mbps|tonumber) }'
        return 0
      fi
      warn "download below minimum size from $url (${bytes:-0} bytes)"
    else
      warn "download failed: $url"
    fi
  done
  jq -n '{ok:false,note:"all download URLs failed"}'
}

run_http_upload_test() {
  local upload_mib="${NETWORK_UPLOAD_MIB:-5}" timeout="${NETWORK_UPLOAD_TIMEOUT:-30}"
  local upload_file="${NETWORK_UPLOAD_FILE:-/tmp/nr-liveval-upload.bin}"
  local -a urls=()

  if [[ -n "${NETWORK_UPLOAD_URL:-}" ]]; then
    urls+=("$NETWORK_UPLOAD_URL")
  else
    urls+=(
      "http://speedtest.tele2.net/upload.php"
      "http://speedtest.ftp.otenet.gr/upload.php"
    )
  fi

  rm -f "$upload_file" 2>/dev/null || true
  if ! dd if=/dev/zero of="$upload_file" bs=1M count="$upload_mib" status=none 2>/dev/null; then
    jq -n --argjson mib "$upload_mib" '{ok:false,note:"could not create upload payload"}'
    return 0
  fi

  local url="" curl_out="" time_total="" bytes="" speed_bps="" mbps=""
  for url in "${urls[@]}"; do
    log "network upload: $url"
    if curl_out="$(curl -sS -T "$upload_file" \
      --connect-timeout 15 --max-time "$timeout" \
      -o /dev/null \
      -w '%{time_total} %{size_upload} %{speed_upload}' \
      "$url" 2>/dev/null)"; then
      time_total="$(awk '{print $1}' <<<"$curl_out")"
      bytes="$(awk '{print $2}' <<<"$curl_out")"
      speed_bps="$(awk '{print $3}' <<<"$curl_out")"
      if [[ -n "$bytes" ]] && awk -v b="$bytes" 'BEGIN { exit (b >= 5000000) ? 0 : 1 }'; then
        mbps="$(bps_to_mbps "$speed_bps")"
        rm -f "$upload_file" 2>/dev/null || true
        jq -n \
          --arg url "$url" --argjson bytes "$bytes" --arg time_total "$time_total" \
          --argjson speed_bps "$speed_bps" --arg mbps "$mbps" \
          --argjson mib "$upload_mib" \
          '{ ok: true, url: $url, bytes_uploaded: $bytes, size_mib: $mib,
             duration_seconds: ($time_total|tonumber), speed_bytes_per_second: $speed_bps,
             throughput_mbps: ($mbps|tonumber) }'
        return 0
      fi
      warn "upload below minimum size to $url (${bytes:-0} bytes)"
    else
      warn "upload failed: $url"
    fi
  done
  rm -f "$upload_file" 2>/dev/null || true
  jq -n '{ok:false,note:"all upload URLs failed"}'
}

step_network_speed() {
  require_cmd curl jq
  ensure_steps_dir

  local curl_ver st_json dl_json ul_json
  curl_ver="$(curl --version 2>&1 | head -1 | awk '{print $2}')"

  st_json="$(run_speedtest_net 2>/dev/null)" || st_json="null"
  if [[ "$st_json" != "null" && -n "$st_json" ]]; then
    log "speedtest.net: complete (download=$(echo "$st_json" | jq -r '.download_mbps') Mbps upload=$(echo "$st_json" | jq -r '.upload_mbps // "n/a"') Mbps)"
  else
    log "speedtest.net: disabled (set RUN_SPEEDTEST=1 to enable)"
    st_json="null"
  fi

  local net_samples="$BENCH_NETWORK_SAMPLES" i dl_lines="" ul_lines="" dl_json ul_json
  for ((i = 0; i < net_samples; i++)); do
    [[ "$i" -gt 0 ]] && bench_cleanup
    dl_json="$(run_http_download_test)"
    if [[ "$(echo "$dl_json" | jq -r '.ok')" == "true" ]]; then
      dl_lines+="$(echo "$dl_json" | jq -r '.throughput_mbps')"$'\n'
      log "network download sample $((i + 1))/${net_samples}: $(echo "$dl_json" | jq -r '.throughput_mbps') Mbps"
    fi
    ul_json="$(run_http_upload_test)"
    if [[ "$(echo "$ul_json" | jq -r '.ok')" == "true" ]]; then
      ul_lines+="$(echo "$ul_json" | jq -r '.throughput_mbps')"$'\n'
      log "network upload sample $((i + 1))/${net_samples}: $(echo "$ul_json" | jq -r '.throughput_mbps') Mbps"
    fi
  done

  local dl_stats ul_stats dl_score ul_score
  dl_stats="$(printf '%s' "$dl_lines" | bench_compute_stats)"
  ul_stats="$(printf '%s' "$ul_lines" | bench_compute_stats)"

  if [[ "$(echo "$dl_stats" | jq '.samples | length')" -eq 0 || "$(echo "$ul_stats" | jq '.samples | length')" -eq 0 ]]; then
    warn "HTTP download/upload incomplete; partial network_speed metrics recorded"
  fi

  dl_score="$(bench_metric_score "download_mbps" "megabits_per_second" \
    "mean HTTP download throughput over successful samples (10 MiB transfer target)" \
    "$dl_stats")"
  ul_score="$(bench_metric_score "upload_mbps" "megabits_per_second" \
    "mean HTTP upload throughput over successful samples (5-10 MiB transfer target)" \
    "$ul_stats")"

  jq -n \
    --arg code "network_speed" \
    --arg curl_version "$curl_ver" \
    --argjson samples "$net_samples" \
    --argjson speedtest "$st_json" \
    --argjson download "$dl_score" \
    --argjson upload "$ul_score" \
    '{
      code: $code,
      curl_version: (if $curl_version == "" then null else $curl_version end),
      samples: $samples,
      speedtest_net: (if $speedtest == null then null else $speedtest end),
      http_download: $download,
      http_upload: $upload
    }' >"$RESULTS_DIR/steps/network_speed.json"
}

step_merge_results() {
  require_cmd jq
  ensure_steps_dir

  local steps_dir="$RESULTS_DIR/steps"
  [[ -d "$steps_dir" ]] && [[ -n "$(ls -A "$steps_dir" 2>/dev/null)" ]] || die "no step results in $steps_dir"

  local nr_ref
  nr_ref="$(build_nr_reference_json)"

  BENCH_SAMPLES="$BENCH_SAMPLES" BENCH_WARMUP="$BENCH_WARMUP" \
  jq -s --argjson samples "$BENCH_SAMPLES" --argjson warmup "$BENCH_WARMUP" --argjson ref "$nr_ref" '
    def pick($c): [.[] | select(.code == $c)] | first;

    def nr_index($v; $r):
      if $v == null or $r == null or ($r | tonumber) == 0 then null
      else (($v / ($r | tonumber)) * 1000 | round)
      end;

    def nr_geom_mean($scores):
      [ $scores[] | select(. != null) ] as $a
      | if ($a | length) == 0 then null
        elif ($a | length) == 1 then $a[0]
        else ( [$a[] | (. / 1000) | log] | add / ($a | length) | exp * 1000 | round )
        end;

    def nr_harm_mean($scores):
      [ $scores[] | select(. != null and . > 0) ] as $a
      | if ($a | length) == 0 then null
        elif ($a | length) == 1 then $a[0]
        else ( ($a | length) / ( [$a[] | 1 / .] | add ) | round )
        end;

    def nr_weighted($pairs):
      [ $pairs[] | select(.score != null) ] as $p
      | if ($p | length) == 0 then null
        else (($p | map(.weight) | add) as $tw | ($p | map(.weight * .score) | add) / $tw | round)
        end;

    def nr_component($name; $value; $reference; $score):
      {
        metric: $name,
        value: $value,
        reference: $reference,
        score: $score
      };

    . as $steps |
    ($steps | pick("host_probe")) as $probe |
    ($steps | pick("cpu_sysbench")) as $cpu |
    ($steps | pick("memory_sysbench")) as $mem |
    ($steps | pick("storage_info")) as $stor |
    ($steps | pick("disk_fio")) as $disk |
    ($steps | pick("network_probe")) as $nprobe |
    ($steps | pick("network_speed")) as $net |

    ($cpu.single_core.value // null) as $cpu_single_v |
    ($cpu.multi_core.value // null) as $cpu_multi_v |
    ($cpu.scaling_efficiency.value // null) as $cpu_scale_v |
    (nr_index($cpu_single_v; $ref.cpu_single_events_per_s)) as $cpu_single_s |
    (nr_index($cpu_multi_v; $ref.cpu_multi_events_per_s)) as $cpu_multi_s |
    (nr_index($cpu_scale_v; $ref.cpu_scaling_efficiency)) as $cpu_scale_s |
    (nr_weighted([
      {weight: 0.40, score: $cpu_single_s},
      {weight: 0.45, score: $cpu_multi_s},
      {weight: 0.15, score: $cpu_scale_s}
    ])) as $cpu_nr |

    ($mem.sequential_write.value // null) as $mem_write_v |
    ($mem.sequential_read.value // null) as $mem_read_v |
    (nr_index($mem_write_v; $ref.memory_write_mib_s)) as $mem_write_s |
    (nr_index($mem_read_v; $ref.memory_read_mib_s)) as $mem_read_s |
    (nr_geom_mean([$mem_write_s, $mem_read_s])) as $mem_nr |

    (if $disk == null then null else $disk.sequential_read.value end) as $stor_read_v |
    (if $disk == null then null else $disk.sequential_write.value end) as $stor_write_v |
    (nr_index($stor_read_v; $ref.storage_read_mib_s)) as $stor_read_s |
    (nr_index($stor_write_v; $ref.storage_write_mib_s)) as $stor_write_s |
    (nr_geom_mean([$stor_read_s, $stor_write_s])) as $storage_nr |

    ($net.http_download.value // null) as $net_dl_v |
    ($net.http_upload.value // null) as $net_ul_v |
    (nr_index($net_dl_v; $ref.network_download_mbps)) as $net_dl_s |
    (nr_index($net_ul_v; $ref.network_upload_mbps)) as $net_ul_s |
    (nr_harm_mean([$net_dl_s, $net_ul_s])) as $net_nr |

    {
      finished_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      methodology: {
        model: "absolute_mean_sampling_with_noderings_index",
        description: "Mean (average) metrics in native units. Noderings index scores normalize each category against a reference VPS profile (scale 1000).",
        samples_per_metric: $samples,
        warmup_runs: $warmup,
        cleanup_between_samples: "sync; drop_caches when root; settle delay (BENCH_SETTLE_MS)",
        raw_metrics: "sections.*.metrics.*.value = per-metric mean; stability derived from sample CV%",
        noderings_index: {
          scale: 1000,
          meaning: "Index score of 1000 indicates category mean performance equivalent to the reference VPS profile",
          reference_vps: $ref,
          category_formulas: {
            cpu: "weighted mean of per-metric index scores: 40% single-core, 45% multi-core, 15% scaling efficiency",
            memory: "geometric mean of sequential write and read index scores",
            storage: "geometric mean of fio sequential read and write index scores",
            network: "harmonic mean of HTTP download and upload index scores",
            overall: "geometric mean of available category index scores (equal weight per category)"
          }
        },
        stability_thresholds: {
          stable: "CV <= 3%",
          moderate: "CV <= 8%",
          unstable: "CV > 8%"
        }
      },
      noderings_score: {
        overall: (nr_geom_mean([$cpu_nr, $mem_nr, $storage_nr, $net_nr])),
        categories: {
          cpu: (
            if $cpu_nr == null then null
            else {
              score: $cpu_nr,
              formula: "weighted index blend: 0.40 single-core + 0.45 multi-core + 0.15 scaling efficiency",
              weights: {single_core: 0.40, multi_core: 0.45, scaling_efficiency: 0.15},
              components: [
                nr_component("single_core_events_per_s"; $cpu_single_v; $ref.cpu_single_events_per_s; $cpu_single_s),
                nr_component("multi_core_events_per_s"; $cpu_multi_v; $ref.cpu_multi_events_per_s; $cpu_multi_s),
                nr_component("scaling_efficiency"; $cpu_scale_v; $ref.cpu_scaling_efficiency; $cpu_scale_s)
              ]
            }
            end
          ),
          memory: (
            if $mem_nr == null then null
            else {
              score: $mem_nr,
              formula: "geometric mean of write and read index scores",
              components: [
                nr_component("sequential_write_mib_s"; $mem_write_v; $ref.memory_write_mib_s; $mem_write_s),
                nr_component("sequential_read_mib_s"; $mem_read_v; $ref.memory_read_mib_s; $mem_read_s)
              ]
            }
            end
          ),
          storage: (
            if $storage_nr == null then null
            else {
              score: $storage_nr,
              formula: "geometric mean of fio sequential read and write index scores",
              components: [
                nr_component("sequential_read_mib_s"; $stor_read_v; $ref.storage_read_mib_s; $stor_read_s),
                nr_component("sequential_write_mib_s"; $stor_write_v; $ref.storage_write_mib_s; $stor_write_s)
              ]
            }
            end
          ),
          network: (
            if $net_nr == null then null
            else {
              score: $net_nr,
              formula: "harmonic mean of HTTP download and upload index scores",
              components: [
                nr_component("http_download_mbps"; $net_dl_v; $ref.network_download_mbps; $net_dl_s),
                nr_component("http_upload_mbps"; $net_ul_v; $ref.network_upload_mbps; $net_ul_s)
              ]
            }
            end
          )
        }
      },
      probe: (
        if $probe == null then null
        else {
          host: $probe.host,
          cpu: $probe.cpu,
          storage: ($stor // null)
        }
        end
      ),
      sections: {
        cpu: {
          documentation: {
            category: "cpu",
            collects: "sysbench CPU prime throughput (single-thread and multi-thread)",
            how: "sysbench cpu --cpu-max-prime=20000; fixed duration per sample; warmup discarded; cache sync between samples",
            score: "single_core and multi_core mean events/s; scaling_efficiency = multi_mean / single_mean"
          },
          metrics: {
            single_core: ($cpu.single_core // null),
            multi_core: ($cpu.multi_core // null),
            scaling_efficiency: ($cpu.scaling_efficiency // null)
          },
          hypervisor: {
            steal_percent_before: ($cpu.steal_percent_before // null),
            steal_percent_after: ($cpu.steal_percent_after // null),
            cpu_mhz_before: ($cpu.cpu_mhz_before // null),
            cpu_mhz_after: ($cpu.cpu_mhz_after // null),
            throttle_warn: ($cpu.throttle_warn // false)
          }
        },
        memory: {
          documentation: {
            category: "memory",
            collects: "sysbench sequential memory bandwidth (write then read)",
            how: "Fixed working-set size; sequential access; single thread; cache drop between samples",
            score: "sequential_write and sequential_read mean MiB/s"
          },
          metrics: {
            sequential_write: ($mem.sequential_write // null),
            sequential_read: ($mem.sequential_read // null)
          }
        },
        storage: (
          if $disk == null then {
            documentation: {
              category: "storage",
              collects: "fio sequential read/write bandwidth",
              how: "1M blocks, direct IO, test file removed between samples",
              score: "sequential read/write mean MiB/s"
            },
            skipped: true,
            note: "storage benchmark not executed"
          }
          else {
            documentation: {
              category: "storage",
              collects: "fio sequential read/write bandwidth on root filesystem",
              how: "fio sequential 1M blocks, direct I/O; test file removed and caches synced between samples",
              score: "sequential_read and sequential_write mean MiB/s"
            },
            metrics: {
              sequential_read: $disk.sequential_read,
              sequential_write: $disk.sequential_write
            }
          }
          end
        ),
        network: {
          documentation: {
            category: "network",
            collects: "HTTP download/upload throughput (Mbps); optional speedtest.net; latency probes (diagnostic)",
            how: "curl HTTP transfer to public endpoints (10 MiB target); mean across samples; ICMP/DNS/TLS from network_probe excluded from scoring",
            score: "http_download and http_upload mean Mbps"
          },
          metrics: {
            http_download: ($net.http_download // null),
            http_upload: ($net.http_upload // null),
            speedtest_net: ($net.speedtest_net // null)
          },
          latency_probe: (
            if $nprobe == null then null
            else {
              dns_resolve_ms: ($nprobe.dns.resolve_ms // null),
              icmp_rtt_avg_ms: ($nprobe.icmp_ipv4.rtt_avg_ms // null),
              icmp_jitter_ms: ($nprobe.icmp_ipv4.jitter_ms // null),
              tcp_connect_ms: ($nprobe.https.tcp_connect_ms // null),
              tls_appconnect_ms: ($nprobe.https.tls_appconnect_ms // null)
            }
            end
          )
        }
      },
      misc: {
        tools: {
          sysbench_version: ($probe.sysbench_version // $cpu.tool_version // null)
        },
        steps: [ $steps[] | {code} + (if .error then {error: .error} else {} end) ]
      }
    }
  ' "$steps_dir"/*.json | tee "$RESULTS_DIR/results.json"

  local overall cpu_s mem_s stor_s net_s
  overall="$(jq -r '.noderings_score.overall // "n/a"' "$RESULTS_DIR/results.json")"
  cpu_s="$(jq -r '.noderings_score.categories.cpu.score // "n/a"' "$RESULTS_DIR/results.json")"
  mem_s="$(jq -r '.noderings_score.categories.memory.score // "n/a"' "$RESULTS_DIR/results.json")"
  stor_s="$(jq -r '.noderings_score.categories.storage.score // "n/a"' "$RESULTS_DIR/results.json")"
  net_s="$(jq -r '.noderings_score.categories.network.score // "n/a"' "$RESULTS_DIR/results.json")"
  log "scores: overall=${overall} cpu=${cpu_s} memory=${mem_s} storage=${stor_s} network=${net_s} (index 1000=reference)"
}

# --- orchestration -----------------------------------------------------------

run_step() {
  local fn=$1 budget=${2:-60}
  shift 2
  local name code rc
  name="${fn#step_}"
  code="$(step_name_to_code "$fn")"
  log "=== $name (max ${budget}s) ==="
  ensure_steps_dir
  if run_with_timeout "$budget" bash "$0" --step "$fn" "$@"; then
    return 0
  fi
  rc=$?
  if [[ $rc -eq 124 ]]; then
    warn "$name timed out after ${budget}s"
  else
    warn "$name exited $rc"
  fi
  if [[ ! -f "$RESULTS_DIR/steps/${code}.json" ]]; then
    write_step_failure "$code" "step failed (exit $rc)"
  fi
  return 1
}

run_suite() {
  local mode=$1

  RESULTS_DIR="$(default_results_dir)"
  export RESULTS_DIR
  rm -rf "$RESULTS_DIR" 2>/dev/null || true
  ensure_steps_dir

  log "nr-liveval mode=$mode os=$(detect_os_id) pm=$(detect_pkg_manager)"
  log "results dir: $RESULTS_DIR"

  run_step step_install_tools 300 || true
  run_step step_host_probe 15 || true
  run_step step_cpu_sysbench 300 || true
  run_step step_memory_sysbench 180 || true

  if [[ "$mode" == "sysbench" ]]; then
    log "sysbench-only mode; disk and network steps omitted"
    run_step step_merge_results 30 || die "failed to merge results"
    [[ -f "$RESULTS_DIR/results.json" ]] || die "results.json was not created"
    log "complete (sysbench-only): $RESULTS_DIR/results.json"
    return 0
  fi

  run_step step_storage_info 10 || true
  run_step step_disk_fio 240 || true
  run_step step_network_probe 30 || true
  run_step step_network_speed 300 || true
  run_step step_merge_results 30 || die "failed to merge results"
  [[ -f "$RESULTS_DIR/results.json" ]] || die "results.json was not created"
  log "complete (full): $RESULTS_DIR/results.json"
}

run_self_test() {
  export RESULTS_DIR="${RESULTS_DIR:-/tmp/nr-liveval-selftest}"
  export SYSBENCH_CPU_SECONDS="${SYSBENCH_CPU_SECONDS:-3}"
  export SYSBENCH_MEMORY_SECONDS="${SYSBENCH_MEMORY_SECONDS:-5}"

  if ! command -v sysbench >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "self-test requires sysbench and jq (install packages or run: sudo $0)"
    exit 1
  fi

  export SKIP_INSTALL=1
  run_suite sysbench
  echo ""
  echo "self-test: complete"
  jq '{
    cpu: .sections.cpu.metrics,
    memory: .sections.memory.metrics,
    model: .methodology.model
  }' "$RESULTS_DIR/results.json"
}

show_license() {
  cat <<'EOF'
nr-liveval: Noderings live validation benchmark

Copyright (c) 2026 Node Rings

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

SPDX-License-Identifier: MIT
EOF
}

show_help() {
  cat <<'EOF'
nr-liveval: Noderings live validation benchmark

NAME
  nr-liveval.sh: collect VPS performance metrics and emit results.json

SYNOPSIS
  sudo ./nr-liveval.sh [--full]
  sudo ./nr-liveval.sh --sysbench-only
  ./nr-liveval.sh --self-test
  SKIP_INSTALL=1 ./nr-liveval.sh

DESCRIPTION
  Benchmark suite for Linux cloud instances and VPS hosts. Installs required
  tools when run as root (unless SKIP_INSTALL=1), executes sequential workload
  steps, and writes machine-readable output to RESULTS_DIR/results.json.

  Output includes host probe data, per-category mean metrics, Noderings index
  scores (1000 = reference VPS profile), methodology metadata, and step audit.

OUTPUT SCHEMA
  probe            Host, CPU, and storage inventory
  sections         cpu, memory, storage, network (metrics and documentation)
  noderings_score  Overall and per-category index scores
  methodology      Sampling, stability thresholds, and index formulas
  misc             Tool versions and executed steps

WORKLOADS
  probe     Host/OS, memory, CPU model, topology, cache, clock, disk inventory
  cpu       sysbench CPU (single-core and multi-core)
  memory    sysbench sequential read/write bandwidth
  storage   fio sequential read/write on root filesystem
  network   DNS, ICMP, HTTPS probes; HTTP download/upload throughput
            speedtest.net when RUN_SPEEDTEST=1

ENVIRONMENT
  Unset variables retain script defaults. Avoid exporting empty values; VAR=""
  overrides ${VAR:-default} with a blank assignment in bash.

  RESULTS_DIR              Output directory (default: /tmp/nr-liveval/results as root,
                           ~/.cache/nr-liveval/results otherwise)
  SKIP_INSTALL=1           Skip package installation; verify tools only
  CPU_THREADS              sysbench multi-core thread cap (default min(logical, 8))
  SYSBENCH_CPU_SECONDS     CPU sample duration (default 10)
  SYSBENCH_MEMORY_MIB      Memory working-set size (default 256)
  SYSBENCH_MEMORY_SECONDS  Memory sample duration (default 10)
  FIO_SIZE                 fio test file size (default 64M)
  FIO_RUNTIME              fio runtime per sample (default 15)
  NETWORK_DOWNLOAD_TIMEOUT HTTP download timeout seconds (default 30)
  NETWORK_UPLOAD_TIMEOUT   HTTP upload timeout seconds (default 30)
  NETWORK_UPLOAD_MIB       Upload payload size MiB (default 5)
  RUN_SPEEDTEST=1          Enable speedtest.net (default: disabled)
  SKIP_SPEEDTEST=1         Disable speedtest.net even when RUN_SPEEDTEST=1
  PING_TARGET              ICMPv4 target (default 1.1.1.1)
  HTTPS_TARGET             HTTPS/TLS probe URL (default https://google.com)
  DNS_TARGET               DNS query name (default google.com)
  NETWORK_DOWNLOAD_URL     Override HTTP download URL
  NETWORK_UPLOAD_URL       Override HTTP upload URL
  BENCH_SAMPLES            Samples per metric (default 5)
  BENCH_WARMUP             Discarded warmup iterations (default 1)
  BENCH_SETTLE_MS          Inter-sample settle delay ms (default 2000)
  BENCH_NETWORK_SAMPLES    HTTP download/upload repetitions (default 5)

REFERENCE VPS (NR_REF_*)
  Baseline profile for Noderings index scoring. Index 1000 when measured mean
  matches the reference value for that metric.

  NR_REF_CPU_SINGLE              Single-core events/s (default 1000)
  NR_REF_CPU_MULTI               Multi-core events/s (default 4000)
  NR_REF_CPU_SCALING             Multi/single ratio (default 4.0)
  NR_REF_MEMORY_WRITE_MIB_S      Memory write MiB/s (default 5000)
  NR_REF_MEMORY_READ_MIB_S       Memory read MiB/s (default 6000)
  NR_REF_STORAGE_READ_MIB_S      Disk read MiB/s (default 2500)
  NR_REF_STORAGE_WRITE_MIB_S     Disk write MiB/s (default 1500)
  NR_REF_NETWORK_DOWNLOAD_MBPS   HTTP download Mbps (default 100)
  NR_REF_NETWORK_UPLOAD_MBPS     HTTP upload Mbps (default 50)

SCORING
  Raw metrics
    sections.*.metrics.*.value: mean (average) in native units (events/s, MiB/s, Mbps).
    sections.*.metrics.*.statistics: also includes min, max, stddev, and CV%.
    sections.*.metrics.*.stability: stable (CV<=3%), moderate (CV<=8%), unstable.

  Noderings index (noderings_score)
    Per-metric: round(1000 * measured_mean / reference_value)
    CPU:      weighted blend: 40% single-core, 45% multi-core, 15% scaling
    Memory:   geometric mean of write and read index scores
    Storage:  geometric mean of fio read and write index scores
    Network:  harmonic mean of download and upload index scores
    Overall:  geometric mean of available category index scores

DISTRIBUTIONS
  Package installation via apt, dnf, yum (+EPEL), apk, zypper, or pacman.
  OS ID is auto-detected from /etc/os-release.

REQUIREMENTS
  bash 4+, Linux with /proc, outbound HTTPS for network workloads.
  Core packages: sysbench, jq, curl; fio and DNS utilities installed when available.

EXIT STATUS
  0  results.json produced
  1  fatal error before results.json was written

COPYRIGHT
  Copyright (c) 2026 Node Rings: MIT License (see --license)
  https://github.com/noderings/noderings-benchmark
EOF
}

# --- entry -------------------------------------------------------------------

check_bash_version

if [[ "${1:-}" == --version ]]; then
  echo "nr-liveval"
  echo "Copyright (c) 2026 Node Rings: MIT License: https://github.com/noderings/noderings-benchmark"
  exit 0
fi

if [[ "${1:-}" == --license ]]; then
  show_license
  exit 0
fi

if [[ "${1:-}" == --step ]]; then
  shift
  fn=$1
  shift
  RESULTS_DIR="$(default_results_dir)"
  export RESULTS_DIR
  "$fn" "$@"
  exit $?
fi

MODE=full
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sysbench-only) MODE=sysbench; shift ;;
    --full)          MODE=full; shift ;;
    --self-test)     run_self_test; exit 0 ;;
    --version)       echo "nr-liveval"; echo "Copyright (c) 2026 Node Rings: MIT License: https://github.com/noderings/noderings-benchmark"; exit 0 ;;
    --license)       show_license; exit 0 ;;
    -h|--help)       show_help; exit 0 ;;
    *)               die "unknown argument: $1 (try --help)" ;;
  esac
done

run_suite "$MODE"
