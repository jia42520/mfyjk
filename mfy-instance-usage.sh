#!/usr/bin/env bash

set -uo pipefail

INTERVAL="${INTERVAL:-2}"
SORT_BY="${SORT_BY:-net}"
ONLY_RUNNING="${ONLY_RUNNING:-1}"
WATCH="${WATCH:-0}"
INTERACTIVE="${INTERACTIVE:-0}"
HAS_ARGS="0"
VIRSH_TIMEOUT="${VIRSH_TIMEOUT:-5}"
DISPLAY_LIMIT="${DISPLAY_LIMIT:-20}"
DOMAIN_REFRESH_EVERY="${DOMAIN_REFRESH_EVERY:-5}"
VCPU_REFRESH_EVERY="${VCPU_REFRESH_EVERY:-60}"
VCPU_MODE="${VCPU_MODE:-fast}"
INSTANCE_NAME_WIDTH="${INSTANCE_NAME_WIDTH:-12}"
TERM_COLS="0"
NAME_WIDTH="$INSTANCE_NAME_WIDTH"
TABLE_FMT=""
WATCH_STOP="0"
IN_MENU_WATCH="0"
LAST_STATS_MODE="auto"
STATS_FAIL_COUNT="0"
STATS_MODE="${STATS_MODE:-auto}"

if [[ $# -gt 0 ]]; then
  HAS_ARGS="1"
fi

usage() {
  cat <<'EOF'
用法: ./mfy-instance-usage.sh [选项]

选项:
  -i, --interval 秒数        采样间隔，默认 2
  -s, --sort 字段           排序字段: cpu|mem|rx|tx|net，默认 net
  -a, --all                 显示全部实例，默认只显示运行中的实例
  -w, --watch               实时监测模式，Ctrl+C 退出或返回菜单
  -m, --menu                交互菜单模式
  -t, --timeout 秒数        单个 virsh 命令超时时间，默认 5
  -n, --limit 数量          显示最高占用的前 N 个实例，默认 20，0 为全部显示
  --domain-refresh 轮数     实时监测每 N 轮刷新实例列表，默认 5
  --vcpu-refresh 轮数       实时监测每 N 轮刷新 vCPU 缓存，默认 60
  --vcpu-mode 模式          vCPU 缓存模式: fast|exact，默认 fast
  --name-width 宽度         实例名称列宽，默认 12
  --stats-mode 模式         采集模式: auto|full|basic，默认 auto
  -h, --help                显示帮助

示例:
  ./mfy-instance-usage.sh
  ./mfy-instance-usage.sh --watch --limit 20
  ./mfy-instance-usage.sh --sort cpu --limit 10
  ./mfy-instance-usage.sh --interval 3 --timeout 5 --sort net
EOF
}

require_value() {
  local option="$1"
  local value="${2-}"

  if [[ -z "$value" || "$value" == -* ]]; then
    echo "$option 需要提供参数值" >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interval)
      require_value "$1" "${2-}"
      INTERVAL="${2:-}"
      shift 2
      ;;
    -s|--sort)
      require_value "$1" "${2-}"
      SORT_BY="${2:-}"
      shift 2
      ;;
    -a|--all)
      ONLY_RUNNING="0"
      shift
      ;;
    -w|--watch)
      WATCH="1"
      shift
      ;;
    -m|--menu)
      INTERACTIVE="1"
      shift
      ;;
    -t|--timeout)
      require_value "$1" "${2-}"
      VIRSH_TIMEOUT="${2:-}"
      shift 2
      ;;
    -n|--limit)
      require_value "$1" "${2-}"
      DISPLAY_LIMIT="${2:-}"
      shift 2
      ;;
    --domain-refresh)
      require_value "$1" "${2-}"
      DOMAIN_REFRESH_EVERY="${2:-}"
      shift 2
      ;;
    --vcpu-refresh)
      require_value "$1" "${2-}"
      VCPU_REFRESH_EVERY="${2:-}"
      shift 2
      ;;
    --vcpu-mode)
      require_value "$1" "${2-}"
      VCPU_MODE="${2:-}"
      shift 2
      ;;
    --name-width)
      require_value "$1" "${2-}"
      INSTANCE_NAME_WIDTH="${2:-}"
      NAME_WIDTH="$INSTANCE_NAME_WIDTH"
      shift 2
      ;;
    --stats-mode)
      require_value "$1" "${2-}"
      STATS_MODE="${2:-}"
      LAST_STATS_MODE="$STATS_MODE"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! [[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk "BEGIN { exit !($INTERVAL > 0) }"; then
  echo "采样间隔必须是大于 0 的数字" >&2
  exit 1
fi

if ! [[ "$VIRSH_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk "BEGIN { exit !($VIRSH_TIMEOUT > 0) }"; then
  echo "virsh 超时时间必须是大于 0 的数字" >&2
  exit 1
fi

if ! [[ "$DISPLAY_LIMIT" =~ ^[0-9]+$ ]]; then
  echo "显示数量必须是大于等于 0 的整数" >&2
  exit 1
fi

if ! [[ "$DOMAIN_REFRESH_EVERY" =~ ^[0-9]+$ ]] || (( DOMAIN_REFRESH_EVERY < 1 )); then
  echo "实例列表刷新轮数必须是大于 0 的整数" >&2
  exit 1
fi

if ! [[ "$VCPU_REFRESH_EVERY" =~ ^[0-9]+$ ]] || (( VCPU_REFRESH_EVERY < 1 )); then
  echo "vCPU 缓存刷新轮数必须是大于 0 的整数" >&2
  exit 1
fi

case "$VCPU_MODE" in
  fast|exact) ;;
  *)
    echo "vCPU 缓存模式只支持: fast|exact" >&2
    exit 1
    ;;
esac

if ! [[ "$INSTANCE_NAME_WIDTH" =~ ^[0-9]+$ ]] || (( INSTANCE_NAME_WIDTH < 6 )); then
  echo "实例名称列宽必须是大于等于 6 的整数" >&2
  exit 1
fi

case "$SORT_BY" in
  cpu|mem|rx|tx|net) ;;
  *)
    echo "排序字段只支持: cpu|mem|rx|tx|net" >&2
    exit 1
    ;;
esac

case "$STATS_MODE" in
  auto|full|basic) ;;
  *)
    echo "采集模式只支持: auto|full|basic" >&2
    exit 1
    ;;
esac

if [[ "$STATS_MODE" == "auto" ]]; then
  LAST_STATS_MODE="auto"
fi

for bin in virsh awk sort date tput mktemp cat; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "缺少依赖命令: $bin" >&2
    exit 1
  fi
done

if command -v timeout >/dev/null 2>&1; then
  virsh_safe() {
    timeout "$VIRSH_TIMEOUT" virsh "$@" 2>/dev/null || true
  }
else
  virsh_safe() {
    virsh "$@" 2>/dev/null || true
  }
fi

tmp_dir="$(mktemp -d)"
trap 'tput cnorm 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT

load_domains() {
  if [[ "$ONLY_RUNNING" == "1" ]]; then
    virsh_safe list --name | awk 'NF' > "$tmp_dir/domains"
  else
    virsh_safe list --all --name | awk 'NF' > "$tmp_dir/domains"
  fi

  awk 'NF {print $0 "\t" NR}' "$tmp_dir/domains" > "$tmp_dir/domain_ids"
}

load_vcpus() {
  : > "$tmp_dir/vcpus"

  if [[ "$VCPU_MODE" == "fast" ]]; then
    virsh_safe domstats --vcpu |
      awk '
        function flush_domain() {
          if (name != "" && vcpus > 0) print name "\t" vcpus
        }
        function clean_domain(value) {
          sub(/^Domain:[[:space:]]*/, "", value)
          gsub(/^\047/, "", value)
          gsub(/\047$/, "", value)
          return value
        }
        /^Domain:/ {
          flush_domain()
          name=clean_domain($0)
          vcpus=0
          next
        }
        {
          pos=index($0, "=")
          if (pos <= 0) next
          key=substr($0, 1, pos-1)
          value=substr($0, pos+1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          if ((key=="vcpu.current" || key=="vcpu.maximum") && value+0 > vcpus) vcpus=value+0
          else if (key ~ /^vcpu\.[0-9]+\.state$/) {
            split(key, parts, ".")
            index_value=parts[2]+1
            if (index_value > vcpus) vcpus=index_value
          }
        }
        END {flush_domain()}
      ' > "$tmp_dir/vcpus"

    return 0
  fi

  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue

    virsh_safe vcpucount "$domain" |
      awk -v domain="$domain" '
        $1 == "current" && $2 == "live" && $3 ~ /^[0-9]+$/ {current_live=$3}
        $1 == "current" && $2 == "config" && $3 ~ /^[0-9]+$/ {current_config=$3}
        $1 == "maximum" && $2 == "config" && $3 ~ /^[0-9]+$/ {maximum_config=$3}
        END {
          vcpus=current_live
          if (vcpus <= 0) vcpus=current_config
          if (vcpus <= 0) vcpus=maximum_config
          if (vcpus > 0) print domain "\t" vcpus
        }' >> "$tmp_dir/vcpus"
  done < "$tmp_dir/domains"
}

stats_has_metrics() {
  local file="$1"

  awk '
    {
      pos=index($0, "=")
      if (pos <= 0) next
      key=substr($0, 1, pos-1)
      value=substr($0, pos+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if ((key=="cpu.time" || key=="cpu.total.time" || key=="balloon.current" || key=="balloon.actual" || key=="balloon.rss" || key ~ /^net\.[0-9]+\.rx[._]bytes$/ || key ~ /^net\.[0-9]+\.tx[._]bytes$/) && value+0 > 0) found=1
    }
    END {exit found ? 0 : 1}
  ' "$file"
}

collect_domstats() {
  local out="$1"
  : > "$out"

  case "$STATS_MODE" in
    full)
      virsh_safe domstats --state --cpu-total --balloon --interface > "$out"
      LAST_STATS_MODE="full"
      ;;
    basic)
      virsh_safe domstats > "$out"
      LAST_STATS_MODE="basic"
      ;;
    *)
      case "$LAST_STATS_MODE" in
        full)
          virsh_safe domstats --state --cpu-total --balloon --interface > "$out"
          if [[ ! -s "$out" ]] || ! stats_has_metrics "$out"; then
            virsh_safe domstats > "$out"
            if [[ -s "$out" ]]; then
              LAST_STATS_MODE="basic"
            else
              LAST_STATS_MODE="full"
            fi
          fi
          ;;
        basic)
          virsh_safe domstats > "$out"
          if [[ ! -s "$out" ]]; then
            LAST_STATS_MODE="basic"
          fi
          ;;
        *)
          virsh_safe domstats --state --cpu-total --balloon --interface > "$out"
          if [[ -s "$out" ]] && stats_has_metrics "$out"; then
            LAST_STATS_MODE="full"
          else
            virsh_safe domstats > "$out"
            if [[ -s "$out" ]]; then
              LAST_STATS_MODE="basic"
            else
              LAST_STATS_MODE="auto"
            fi
          fi
          ;;
      esac
      ;;
  esac

  if [[ "$STATS_MODE" == "auto" && ! -s "$out" ]]; then
    : > "$out"
  fi

  if [[ "$STATS_MODE" == "auto" && "$LAST_STATS_MODE" == "full" && -s "$out" ]] && ! stats_has_metrics "$out"; then
    virsh_safe domstats > "$out"
    if [[ -s "$out" ]]; then
      LAST_STATS_MODE="basic"
    fi
  fi

  if [[ -s "$out" ]]; then
    STATS_FAIL_COUNT="0"
  else
    STATS_FAIL_COUNT=$((STATS_FAIL_COUNT + 1))
  fi
}

stats_status_text() {
  if (( STATS_FAIL_COUNT > 0 )); then
    printf '%s/%s次空结果' "$LAST_STATS_MODE" "$STATS_FAIL_COUNT"
  else
    printf '%s' "$LAST_STATS_MODE"
  fi
}

now_ns() {
  date +%s%N
}

pad_cell() {
  local text="$1"
  local width="$2"
  local display_width="${3:-${#text}}"
  local padding=$((width - display_width))

  if (( padding < 0 )); then
    padding="0"
  fi

  printf '%s' "$text"
  printf '%*s' "$padding" ''
}

format_header() {
  pad_cell "ID" 8 2
  printf ' '
  pad_cell "实例" "$NAME_WIDTH" 4
  printf ' '
  pad_cell "状态" 10 4
  printf ' '
  pad_cell "CPU" 9 3
  printf ' '
  pad_cell "内存" 14 4
  printf ' '
  pad_cell "下行" 12 4
  printf ' '
  pad_cell "上行" 12 4
  printf ' '
  pad_cell "总网速" 12 6
  printf '\n'
}

format_rows() {
  local output_limit="$1"

  awk -F'\t' -v display_limit="$output_limit" -v name_width="$NAME_WIDTH" -v table_fmt="$TABLE_FMT" '
    function fit_name(value) {
      if (length(value) <= name_width) return value
      if (name_width <= 1) return substr(value, 1, name_width)
      return substr(value, 1, name_width - 1) "~"
    }
    {
      if (display_limit > 0 && shown >= display_limit) next
      shown++
      printf table_fmt, $2, name_width, fit_name($3), $4, $5, $6, $7, $8, $9
    }'
}

parse_snapshot() {
  local raw="$1"
  local out="$2"

  if [[ ! -s "$raw" ]]; then
    awk -F'\t' '
      FNR==NR {
        vcpu_cache[$1]=$2
        next
      }
      {
        cpu_count=vcpu_cache[$1]+0
        if (cpu_count <= 0) cpu_count=1
        print $1 "\t" $2 "\tunknown\t" cpu_count "\t0\t0\t0\t0\t0"
      }
    ' "$tmp_dir/vcpus" "$tmp_dir/domain_ids" > "$out"
    return 0
  fi

  awk -v vcpu_file="$tmp_dir/vcpus" -v domain_file="$tmp_dir/domain_ids" '
    function reset_domain() {
      name=""
      dom_id="-"
      state="running"
      state_code=""
      vcpus=0
      cpu_time=0
      mem_used=0
      mem_total=0
      mem_unused=-1
      rx_bytes=0
      tx_bytes=0
    }
    function clean_domain(value) {
      sub(/^Domain:[[:space:]]*/, "", value)
      gsub(/^\047/, "", value)
      gsub(/\047$/, "", value)
      return value
    }
    function flush_domain() {
      if (name == "") return
      if (only[name] != 1) return
      if (state_code == 1) state="running"
      else if (state_code == 3) state="paused"
      else if (state_code == 5) state="shutoff"
      else if (state_code != "") state="state" state_code
      if (vcpu_cache[name]+0 > 0) vcpus=vcpu_cache[name]+0
      if (vcpus <= 0) vcpus=1
      if (mem_total > 0 && mem_unused >= 0) mem_used=mem_total-mem_unused
      if (mem_used <= 0 && mem_total > 0 && mem_unused < 0) mem_used=mem_total
      if (mem_used < 0) mem_used=0
      print name "\t" dom_id "\t" state "\t" vcpus "\t" cpu_time "\t" mem_used "\t" mem_total "\t" rx_bytes "\t" tx_bytes
      seen[name]=1
    }
    FILENAME == vcpu_file {
      vcpu_cache[$1]=$2
      next
    }
    FILENAME == domain_file {
      split($0, parts, "\t")
      if (parts[1] != "") {
        only[parts[1]]=1
        fallback_id[parts[1]]=parts[2]
        order[++domain_count]=parts[1]
      }
      next
    }
    /^Domain:/ {
      flush_domain()
      reset_domain()
      name=clean_domain($0)
      dom_id=fallback_id[name]
      next
    }
    {
      pos=index($0, "=")
      if (pos <= 0) next
      key=substr($0, 1, pos-1)
      value=substr($0, pos+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (key=="state.state") state_code=value+0
      else if (key=="cpu.time" || key=="cpu.total.time") cpu_time=value+0
      else if (key=="vcpu.current" || key=="vcpu.maximum") vcpus=value+0
      else if (key=="balloon.current" || key=="balloon.maximum" || key=="balloon.actual") mem_total=value+0
      else if (key=="balloon.unused") mem_unused=value+0
      else if (key=="balloon.rss") mem_used=value+0
      else if (key ~ /^vcpu\.[0-9]+\.state$/) vcpus++
      else if (key ~ /^net\.[0-9]+\.rx\.bytes$/ || key ~ /^net\.[0-9]+\.rx_bytes$/) rx_bytes+=value+0
      else if (key ~ /^net\.[0-9]+\.tx\.bytes$/ || key ~ /^net\.[0-9]+\.tx_bytes$/) tx_bytes+=value+0
    }
    END {
      flush_domain()
      for (i=1; i<=domain_count; i++) {
        domain=order[i]
        cpu_count=vcpu_cache[domain]+0
        if (cpu_count <= 0) cpu_count=1
        if (seen[domain] != 1) print domain "\t" fallback_id[domain] "\tunknown\t" cpu_count "\t0\t0\t0\t0\t0"
      }
    }
  ' "$tmp_dir/vcpus" "$tmp_dir/domain_ids" "$raw" > "$out"
}

build_result() {
  local first="$1"
  local second="$2"
  local output_limit="$3"
  local sample_interval="${4:-$INTERVAL}"

  awk -F'\t' -v interval="$sample_interval" -v sort_by="$SORT_BY" '
    function human_rate(bytes_per_sec) {
      if (bytes_per_sec >= 1073741824) return sprintf("%.2fGB/s", bytes_per_sec / 1073741824)
      if (bytes_per_sec >= 1048576) return sprintf("%.2fMB/s", bytes_per_sec / 1048576)
      if (bytes_per_sec >= 1024) return sprintf("%.2fKB/s", bytes_per_sec / 1024)
      return sprintf("%.0fB/s", bytes_per_sec)
    }
    function human_mem(kib) {
      if (kib >= 1048576) return sprintf("%.2fGB", kib / 1048576)
      if (kib >= 1024) return sprintf("%.2fMB", kib / 1024)
      return sprintf("%.0fKB", kib)
    }
    function key_for(cpu_pct, mem_pct, rx_rate, tx_rate) {
      if (sort_by == "mem") return mem_pct
      if (sort_by == "rx") return rx_rate
      if (sort_by == "tx") return tx_rate
      if (sort_by == "net") return rx_rate + tx_rate
      return cpu_pct
    }
    NR==FNR {
      cpu[$1]=$5
      rx[$1]=$8
      tx[$1]=$9
      next
    }
    {
      name=$1
      dom_id=$2
      state=$3
      vcpus=$4+0
      cpu_delta=$5-cpu[name]
      rx_delta=$8-rx[name]
      tx_delta=$9-tx[name]
      if (vcpus <= 0) vcpus=1
      if (cpu_delta < 0) cpu_delta=0
      if (rx_delta < 0) rx_delta=0
      if (tx_delta < 0) tx_delta=0
      cpu_pct=(cpu_delta / 1000000000 / interval / vcpus) * 100
      mem_used=$6+0
      mem_total=$7+0
      if (mem_total > 0 && mem_used > mem_total) mem_used=mem_total
      mem_pct=mem_total > 0 ? mem_used / mem_total * 100 : 0
      rx_rate=rx_delta / interval
      tx_rate=tx_delta / interval
      sort_key=key_for(cpu_pct, mem_pct, rx_rate, tx_rate)
      printf "%.6f\t%s\t%s\t%s\t%.2f%%\t%s\t%s\t%s\t%s\n", sort_key, dom_id, name, state, cpu_pct, human_mem(mem_used), human_rate(rx_rate), human_rate(tx_rate), human_rate(rx_rate + tx_rate)
    }
  ' "$first" "$second" |
    sort -rn -k1,1 |
    format_rows "$output_limit"
}

host_net_snapshot() {
  local out="$1"

  awk -F'[: ]+' '
    $1 !~ /^(lo|virbr|vnet|tap|br-|docker|veth)/ && $2 ~ /^[0-9]+$/ {
      rx+=$2
      tx+=$10
    }
    END {print rx+0, tx+0}
  ' /proc/net/dev > "$out"
}

human_rate_value() {
  awk -v value="${1:-0}" '
    BEGIN {
      if (value >= 1073741824) printf "%.2fGB/s", value / 1073741824
      else if (value >= 1048576) printf "%.2fMB/s", value / 1048576
      else if (value >= 1024) printf "%.2fKB/s", value / 1024
      else printf "%.0fB/s", value
    }'
}

host_bandwidth_line() {
  local first="$1"
  local second="$2"
  local sample_interval="${3:-$INTERVAL}"
  local first_rx first_tx second_rx second_tx rx_rate tx_rate total_rate

  read -r first_rx first_tx < "$first"
  read -r second_rx second_tx < "$second"
  rx_rate="$(awk -v a="${first_rx:-0}" -v b="${second_rx:-0}" -v interval="$sample_interval" 'BEGIN {d=b-a; if (d<0) d=0; printf "%.0f", d/interval}')"
  tx_rate="$(awk -v a="${first_tx:-0}" -v b="${second_tx:-0}" -v interval="$sample_interval" 'BEGIN {d=b-a; if (d<0) d=0; printf "%.0f", d/interval}')"
  total_rate="$(awk -v rx="$rx_rate" -v tx="$tx_rate" 'BEGIN {printf "%.0f", rx+tx}')"

  printf '母鸡带宽 | 下行: %s | 上行: %s | 总: %s\n' "$(human_rate_value "$rx_rate")" "$(human_rate_value "$tx_rate")" "$(human_rate_value "$total_rate")"
}

sample_once() {
  local output_limit="${1:-$DISPLAY_LIMIT}"
  local first_ns second_ns sample_interval

  update_table_layout
  load_domains

  if [[ ! -s "$tmp_dir/domains" ]]; then
    echo "未发现实例"
    return 0
  fi

  load_vcpus

  collect_domstats "$tmp_dir/raw_first"
  first_ns="$(now_ns)"
  parse_snapshot "$tmp_dir/raw_first" "$tmp_dir/first"
  sleep "$INTERVAL"
  collect_domstats "$tmp_dir/raw_second"
  second_ns="$(now_ns)"
  parse_snapshot "$tmp_dir/raw_second" "$tmp_dir/second"
  sample_interval="$(awk -v first="$first_ns" -v second="$second_ns" -v fallback="$INTERVAL" 'BEGIN {d=(second-first)/1000000000; if (d <= 0) d=fallback; print d}')"
  format_header
  build_result "$tmp_dir/first" "$tmp_dir/second" "$output_limit" "$sample_interval"
}

render_once() {
  local output_limit="${1:-$DISPLAY_LIMIT}"

  sample_once "$output_limit"
}

watch_display_limit() {
  local rows max_rows

  rows="$(tput lines 2>/dev/null || echo 24)"
  [[ "$rows" =~ ^[0-9]+$ ]] || rows="24"
  max_rows=$((rows - 4))

  if (( max_rows < 1 )); then
    max_rows="1"
  fi

  if (( DISPLAY_LIMIT > 0 && DISPLAY_LIMIT < max_rows )); then
    echo "$DISPLAY_LIMIT"
  else
    echo "$max_rows"
  fi
}

update_table_layout() {
  local cols fixed max_width name_width

  cols="$(tput cols 2>/dev/null || echo 120)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols="120"
  fixed=$((8 + 10 + 9 + 14 + 12 + 12 + 12 + 7))
  max_width=$((cols - fixed))
  name_width="$INSTANCE_NAME_WIDTH"

  if (( max_width < 6 )); then
    max_width="6"
  fi

  if (( name_width > max_width )); then
    name_width="$max_width"
  elif (( name_width < 6 )); then
    name_width="6"
  fi

  TERM_COLS="$cols"
  NAME_WIDTH="$name_width"
  TABLE_FMT="%-8s %-*s %-10s %-9s %-14s %-12s %-12s %-12s\n"
}

validate_interval() {
  local value="${1:-$INTERVAL}"

  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk "BEGIN { exit !($value > 0) }"
}

choose_sort() {
  local choice

  while true; do
    echo
    echo "请选择排序方式"
    echo "1) CPU 占用"
    echo "2) 内存占用"
    echo "3) 下行网速"
    echo "4) 上行网速"
    echo "5) 总网速"
    read -r -p "请输入选项 [1-5]: " choice || return

    case "$choice" in
      1) SORT_BY="cpu"; return ;;
      2) SORT_BY="mem"; return ;;
      3) SORT_BY="rx"; return ;;
      4) SORT_BY="tx"; return ;;
      5) SORT_BY="net"; return ;;
      *) echo "无效选项，请重新输入" ;;
    esac
  done
}

set_interval() {
  local value

  while true; do
    echo
    read -r -p "请输入刷新/采样间隔秒数，当前 ${INTERVAL}s: " value || return
    [[ -n "$value" ]] || return

    if validate_interval "$value"; then
      INTERVAL="$value"
      return
    fi

    echo "采样间隔必须是大于 0 的数字"
  done
}

set_display_limit() {
  local value

  while true; do
    echo
    read -r -p "请输入显示数量，0 表示全部显示，当前 ${DISPLAY_LIMIT}: " value || return
    [[ -n "$value" ]] || return

    if [[ "$value" =~ ^[0-9]+$ ]]; then
      DISPLAY_LIMIT="$value"
      return
    fi

    echo "显示数量必须是大于等于 0 的整数"
  done
}

toggle_scope() {
  if [[ "$ONLY_RUNNING" == "1" ]]; then
    ONLY_RUNNING="0"
    echo "已切换为显示全部实例"
  else
    ONLY_RUNNING="1"
    echo "已切换为只显示运行中实例"
  fi
}

stop_watch() {
  WATCH_STOP="1"
}

pause_menu() {
  echo
  read -r -p "按回车返回菜单..." _ || true
}

watch_loop() {
  local last_cols current_cols last_lines current_lines effective_limit loop_count status_text first_ns second_ns sample_interval

  WATCH_STOP="0"
  tput civis 2>/dev/null || true
  trap 'stop_watch' INT
  trap 'tput cnorm 2>/dev/null || true; rm -rf "$tmp_dir"; exit 0' TERM

  update_table_layout
  load_domains
  load_vcpus
  loop_count="0"
  last_cols="$TERM_COLS"
  last_lines="$(tput lines 2>/dev/null || echo 24)"
  printf '\033[2J\033[H'
  status_text="$(stats_status_text)"
  echo "魔方云实例资源实时监测 | 采样间隔: ${INTERVAL}s | 排序: ${SORT_BY} | 显示: ${DISPLAY_LIMIT} | 模式: ${status_text} | 退出: Ctrl+C"
  echo "母鸡带宽 | 下行: 0B/s | 上行: 0B/s | 总: 0B/s"
  format_header

  while [[ "$WATCH_STOP" != "1" ]]; do
    loop_count=$((loop_count + 1))
    current_cols="$(tput cols 2>/dev/null || echo "$last_cols")"
    current_lines="$(tput lines 2>/dev/null || echo "$last_lines")"

    if [[ "$current_cols" != "$last_cols" || "$current_lines" != "$last_lines" ]]; then
      update_table_layout
      last_cols="$TERM_COLS"
      last_lines="$current_lines"
      printf '\033[2J\033[H'
      status_text="$(stats_status_text)"
      echo "魔方云实例资源实时监测 | 采样间隔: ${INTERVAL}s | 排序: ${SORT_BY} | 显示: ${DISPLAY_LIMIT} | 模式: ${status_text} | 退出: Ctrl+C"
      echo "母鸡带宽 | 下行: 0B/s | 上行: 0B/s | 总: 0B/s"
      format_header
    fi

    if (( loop_count > 1 && loop_count % DOMAIN_REFRESH_EVERY == 0 )); then
      load_domains
    fi

    if (( loop_count > 1 && loop_count % VCPU_REFRESH_EVERY == 0 )); then
      load_vcpus
    fi

    effective_limit="$(watch_display_limit)"

    if [[ ! -s "$tmp_dir/domains" ]]; then
      printf '未发现实例\n' > "$tmp_dir/watch_output"
      printf '母鸡带宽 | 下行: 0B/s | 上行: 0B/s | 总: 0B/s\n' > "$tmp_dir/host_bandwidth"
      sleep "$INTERVAL"
      if [[ "$WATCH_STOP" == "1" ]]; then
        break
      fi
      status_text="$(stats_status_text)"
      printf '\033[1;1H\033[K'
      echo "魔方云实例资源实时监测 | 采样间隔: ${INTERVAL}s | 排序: ${SORT_BY} | 显示: ${DISPLAY_LIMIT} | 模式: ${status_text} | 退出: Ctrl+C"
      printf '\033[2;1H\033[K'
      cat "$tmp_dir/host_bandwidth"
      printf '\033[4;1H\033[J'
      cat "$tmp_dir/watch_output"
      continue
    fi

    host_net_snapshot "$tmp_dir/host_first"
    collect_domstats "$tmp_dir/raw_first"
    first_ns="$(now_ns)"
    parse_snapshot "$tmp_dir/raw_first" "$tmp_dir/first"
    sleep "$INTERVAL"
    if [[ "$WATCH_STOP" == "1" ]]; then
      break
    fi

    host_net_snapshot "$tmp_dir/host_second"
    collect_domstats "$tmp_dir/raw_second"
    second_ns="$(now_ns)"
    parse_snapshot "$tmp_dir/raw_second" "$tmp_dir/second"
    sample_interval="$(awk -v first="$first_ns" -v second="$second_ns" -v fallback="$INTERVAL" 'BEGIN {d=(second-first)/1000000000; if (d <= 0) d=fallback; print d}')"
    host_bandwidth_line "$tmp_dir/host_first" "$tmp_dir/host_second" "$sample_interval" > "$tmp_dir/host_bandwidth"
    build_result "$tmp_dir/first" "$tmp_dir/second" "$effective_limit" "$sample_interval" > "$tmp_dir/watch_output"

    if [[ "$WATCH_STOP" == "1" ]]; then
      break
    fi

    printf '\033[1;1H\033[K'
    status_text="$(stats_status_text)"
    echo "魔方云实例资源实时监测 | 采样间隔: ${INTERVAL}s | 排序: ${SORT_BY} | 显示: ${DISPLAY_LIMIT} | 模式: ${status_text} | 退出: Ctrl+C"
    printf '\033[2;1H\033[K'
    cat "$tmp_dir/host_bandwidth"
    printf '\033[4;1H\033[J'
    cat "$tmp_dir/watch_output"
  done

  trap - INT
  tput cnorm 2>/dev/null || true
  printf '\033[2J\033[H'

  if [[ "$IN_MENU_WATCH" == "1" || -t 0 ]]; then
    return 0
  fi

  exit 0
}

interactive_menu() {
  local choice scope_text limit_text

  while true; do
    if [[ "$ONLY_RUNNING" == "1" ]]; then
      scope_text="只显示运行中实例"
    else
      scope_text="显示全部实例"
    fi

    if [[ "$DISPLAY_LIMIT" == "0" ]]; then
      limit_text="全部"
    else
      limit_text="前 ${DISPLAY_LIMIT} 个"
    fi

    printf '\033c'
    echo "魔方云实例资源监测交互菜单"
    echo "当前配置: 排序=${SORT_BY} | 间隔=${INTERVAL}s | 超时=${VIRSH_TIMEOUT}s | 范围=${scope_text} | 显示=${limit_text}"
    echo
    echo "1) 单次查看"
    echo "2) 实时监测"
    echo "3) 修改排序方式"
    echo "4) 修改刷新/采样间隔"
    echo "5) 切换实例范围"
    echo "6) 修改显示数量"
    echo "0) 退出"
    echo
    read -r -p "请选择操作 [0-6]: " choice || exit 0

    case "$choice" in
      1)
        echo
        render_once
        pause_menu
        ;;
      2)
        IN_MENU_WATCH="1"
        watch_loop
        IN_MENU_WATCH="0"
        ;;
      3)
        choose_sort
        ;;
      4)
        set_interval
        ;;
      5)
        toggle_scope
        sleep 1
        ;;
      6)
        set_display_limit
        ;;
      0)
        exit 0
        ;;
      *)
        echo "无效选项，请重新输入"
        sleep 1
        ;;
    esac
  done
}

if [[ "$WATCH" == "1" ]]; then
  watch_loop
  if [[ -t 0 ]]; then
    interactive_menu
  fi
fi

if [[ "$INTERACTIVE" == "1" || "$HAS_ARGS" == "0" && -t 0 ]]; then
  interactive_menu
fi

render_once
