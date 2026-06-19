#!/usr/bin/env bash
#
# vps_tools.sh — VPS 常用命令交互式工具箱
# 支持 Debian/Ubuntu/CentOS/Alpine 等，兼容 systemd/OpenRC
#
# 用法: bash /var/vps_tools.sh
#

set -o pipefail
shopt -s extglob

# ---------------------------------------------------------------------------
# 颜色与基础
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    BLUE=$'\e[34m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

SUDO=""; [[ "$(id -u)" -eq 0 ]] || SUDO="sudo"
has() { command -v "$1" >/dev/null 2>&1; }

info()  { echo -e "${GREEN}●${RESET} $*"; }
warn()  { echo -e "${YELLOW}▲${RESET} $*"; }
err()   { echo -e "${RED}✖${RESET} $*"; }
run()   { echo -e "${DIM}\$ $*${RESET}"; "$@"; }

pause() {
    echo
    read -rp "${YELLOW}按回车键返回...${RESET}" _
}

detect_pkg() {
    PKG="unknown"
    if has apt-get; then PKG="apt"; fi
    if has dnf;     then PKG="dnf"; fi
    if has yum;     then PKG="yum"; fi
    if has apk;     then PKG="apk"; fi
    if has pacman;  then PKG="pacman"; fi
}
detect_pkg

detect_init() {
    if has systemctl && [ -d /run/systemd/system ]; then INIT="systemd"
    elif has rc-service; then INIT="openrc"
    elif has service;    then INIT="service"
    else INIT="unknown"; fi
}
detect_init

IS_ALPINE=0; [[ -f /etc/alpine-release ]] && IS_ALPINE=1

# 重复字符串 n 次（避免 tr 对 Unicode 处理异常）
repeat() {
    local n="$1" ch="$2" out=""
    local i
    for ((i=0; i<n; i++)); do out+="$ch"; done
    echo -n "$out"
}

# 根据 locale 选择表格字符（UTF-8 用 box-drawing，否则 ASCII）
if [[ "${LANG,,}" == *utf-8* || "${LANG,,}" == *utf8* || \
      "${LC_ALL,,}" == *utf-8* || "${LC_ALL,,}" == *utf8* ]]; then
    BOX_TL='┌'; BOX_TM='┬'; BOX_TR='┐'
    BOX_ML='├'; BOX_MM='┼'; BOX_MR='┤'
    BOX_BL='└'; BOX_BM='┴'; BOX_BR='┘'
    BOX_H='─'; BOX_V='│'
    BANNER_TOP='┌'$(repeat 42 '─')'┐'; BANNER_BOT='└'$(repeat 42 '─')'┘'
    BANNER_V='│'
else
    BOX_TL='+'; BOX_TM='+'; BOX_TR='+'
    BOX_ML='+'; BOX_MM='+'; BOX_MR='+'
    BOX_BL='+'; BOX_BM='+'; BOX_BR='+'
    BOX_H='-'; BOX_V='|'
    BANNER_TOP='+'$(repeat 42 '-')'+'; BANNER_BOT='+'$(repeat 42 '-')'+'
    BANNER_V='|'
fi

# ---------------------------------------------------------------------------
# 终端与格式化
# ---------------------------------------------------------------------------
TERM_W=${COLUMNS:-$(stty size 2>/dev/null | awk '{print $2}' || echo 80)}
(( TERM_W < 40 )) && TERM_W=80

# 计算可见长度（去除 ANSI）
vlen() {
    local s="$1"
    s=${s//$'\e'\[[0-9;]*m/}
    echo "${#s}"
}

# 截断字符串到指定可见长度，末尾加 …
trunc() {
    local s="$1" max="$2"
    local l; l=$(vlen "$s")
    if (( l <= max )); then
        echo "$s"
    else
        printf "%s" "$s" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-$((max-1)) | tr -d '\n'
        echo "…"
    fi
}

# 用 Unicode box-drawing 画表格
# print_table <col1_align> <col2_align> ... 然后 "ROW\t..." 行（参数）
# align: L 左对齐, R 右对齐, C 居中
# 调用示例:
#   print_table L R R "Name\tValue\tUnit" "mem\t3.8\tGB"
table() {
    local -a aligns=()
    local -a rows=()
    local max_cols=0 i j line cell len align w

    # 前几个参数是列对齐方式
    while [[ $# -gt 0 && "$1" =~ ^[LlRrCc]$ ]]; do
        aligns+=("${1^^}")
        shift
    done

    # 剩余是行
    while [[ $# -gt 0 ]]; do
        rows+=("$1")
        shift
    done

    # 计算列数、列宽
    local -a widths=()
    for line in "${rows[@]}"; do
        IFS=$'\t' read -ra cols <<< "$line"
        (( ${#cols[@]} > max_cols )) && max_cols=${#cols[@]}
        for i in "${!cols[@]}"; do
            len=$(vlen "${cols[$i]}")
            [[ -z "${widths[$i]}" || $len -gt ${widths[$i]} ]] && widths[$i]=$len
        done
    done

    # 默认左对齐
    for ((i=0; i<max_cols; i++)); do
        [[ -z "${aligns[$i]}" ]] && aligns[$i]="L"
        [[ -z "${widths[$i]}" ]] && widths[$i]=3
        # 最大列宽上限
        if (( widths[i] > 45 )); then widths[$i]=45; fi
    done

    local top="${BOX_TL}" mid="${BOX_ML}" bot="${BOX_BL}"
    for ((i=0; i<max_cols; i++)); do
        local pad=$(repeat "$((widths[i]+2))" "${BOX_H}")
        top+="${pad}"; mid+="${pad}"; bot+="${pad}"
        if (( i < max_cols-1 )); then
            top+="${BOX_TM}"; mid+="${BOX_MM}"; bot+="${BOX_BM}"
        else
            top+="${BOX_TR}"; mid+="${BOX_MR}"; bot+="${BOX_BR}"
        fi
    done

    echo "$top"
    local first=1
    for line in "${rows[@]}"; do
        [[ "$line" == "--" ]] && continue
        IFS=$'\t' read -ra cols <<< "$line"
        if (( first )); then
            printf '%s' "${BOLD}${BOX_V}"
            first=0
        else
            printf '%s' "${BOX_V}"
        fi
        for ((i=0; i<max_cols; i++)); do
            cell="${cols[$i]:-}"
            cell=$(trunc "$cell" "${widths[$i]}")
            len=$(vlen "$cell")
            w=$(( widths[i] - len ))
            align="${aligns[$i]}"
            if [[ "$align" == "R" ]]; then
                printf '%*s %s %s' "$w" '' "$cell" "${BOX_V}"
            elif [[ "$align" == "C" ]]; then
                local wl=$(( w/2 )) wr=$(( w - wl ))
                printf '%*s%s%*s %s' "$wl" '' "$cell" "$wr" '' "${BOX_V}"
            else
                printf ' %s%*s %s' "$cell" "$w" '' "${BOX_V}"
            fi
        done
        echo -e "${RESET}"
        if (( first )); then
            (( ${#rows[@]} > 1 )) && echo "$mid"
        fi
    done
    echo "$bot"
}

# 键值对（无边框，用于简单信息）
kv() {
    local max=0 i k v
    for ((i=1; i<=$#; i+=2)); do
        k="${!i}"
        local l=$(vlen "$k")
        (( l > max )) && max=$l
    done
    for ((i=1; i<=$#; i+=2)); do
        k="${!i}"
        local j=$((i+1)); v="${!j}"
        printf "  ${CYAN}%-${max}s${RESET} ${DIM}│${RESET} %s\n" "$k" "$v"
    done
}

# 居中大标题（带圆角边框）
section() {
    local txt=" $* " len=${#txt}
    local pad=$(( (TERM_W - len - 4) / 2 ))
    (( pad < 2 )) && pad=2
    local side=$(( TERM_W - pad * 2 - len - 4 ))
    local left=$(repeat "$pad" "${BOX_H}")
    local right=$(repeat "$side" "${BOX_H}")
    printf '\n  %s%s%s%s%s%s%s\n' "${BOX_TL}" "$left" "${BOX_H}${BOX_H}" "${BOLD}${txt}${RESET}" "${BOX_H}${BOX_H}" "$right" "${BOX_TR}"
}

# 小标题
subtitle() { printf "\n  ${BOLD}${CYAN}▸ %s${RESET}\n" "$*"; }

# 带边框的 KV 卡片
kv_card() {
    local max_k=0 i k v
    for ((i=1; i<=$#; i+=2)); do
        k="${!i}"
        local l=$(vlen "$k")
        (( l > max_k )) && max_k=$l
    done
    local inner=$(( max_k + 3 + 40 ))
    local total=$(( inner + 4 ))
    (( total > TERM_W - 4 )) && total=$(( TERM_W - 4 ))
    local hr=$(repeat "$((total-2))" "${BOX_H}")

    printf '  %s%s%s\n' "${BOX_TL}" "$hr" "${BOX_TR}"
    for ((i=1; i<=$#; i+=2)); do
        k="${!i}"
        local j=$((i+1)); v="${!j}"
        local line
        printf -v line ' %-*s %s %s' "$max_k" "$k" "${BOX_V}" "$v"
        local pad=$(( total - 2 - $(vlen "$line") ))
        (( pad < 0 )) && pad=0
        printf '  %s%s%*s%s\n' "${BOX_V}" "$line" "$pad" '' "${BOX_V}"
    done
    printf '  %s%s%s\n' "${BOX_BL}" "$hr" "${BOX_BR}"
}

# 进度条
bar() {
    local pct="$1" label="${2:-}" width=28
    pct=${pct%\%}
    [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || pct=0
    local ipct=$(awk -v p="$pct" 'BEGIN{printf "%d", p}')
    (( ipct > 100 )) && ipct=100
    local fill=$(( width * ipct / 100 ))
    local color
    if   (( ipct < 70 )); then color="$GREEN"
    elif (( ipct < 90 )); then color="$YELLOW"
    else                         color="$RED"; fi
    local bar_ch='█' empty_ch='░'
    if [[ "${BOX_H}" == "-" ]]; then
        bar_ch='#'; empty_ch='-'
    fi
    local bar=$(repeat "$fill" "$bar_ch")
    local empty=$(repeat "$((width-fill))" "$empty_ch")
    [[ -n "$label" ]] && printf "  ${DIM}%s${RESET} " "$label"
    printf "${color}%s%s${RESET} ${BOLD}%3d%%${RESET}\n" "$bar" "$empty" "$ipct"
}

# 单位换算为 GB
to_gb() {
    local s="$1" num unit
    num=$(echo "$s" | sed -E 's/^([0-9.,]+).*/\1/; s/,//g')
    unit=$(echo "$s" | sed -E 's/^[0-9.,]+//')
    case "$unit" in
        Ki|K|k)  awk -v n="$num" 'BEGIN{printf "%.2f", n/1024/1024}' ;;
        Mi|M)    awk -v n="$num" 'BEGIN{printf "%.2f", n/1024}' ;;
        Gi|G)    awk -v n="$num" 'BEGIN{printf "%.2f", n}' ;;
        Ti|T)    awk -v n="$num" 'BEGIN{printf "%.2f", n*1024}' ;;
        *)       awk -v n="$num" 'BEGIN{printf "%.2f", n}' ;;
    esac
}

# 安全百分比
pct_of() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%d", b?a*100/b:0}'; }

# 计算 CPU 总占用率（基于 /proc/stat）
cpu_usage() {
    local a1 b1 c1 d1 e1 f1 g1 idle1 total1
    local a2 b2 c2 d2 e2 f2 g2 idle2 total2
    read -r _ a1 b1 c1 d1 e1 f1 g1 _ < /proc/stat
    idle1=$((d1))
    total1=$((a1+b1+c1+d1+e1+f1+g1))
    sleep 0.5
    read -r _ a2 b2 c2 d2 e2 f2 g2 _ < /proc/stat
    idle2=$((d2))
    total2=$((a2+b2+c2+d2+e2+f2+g2))
    awk -v i1="$idle1" -v t1="$total1" -v i2="$idle2" -v t2="$total2" \
        'BEGIN{d=t2-t1; if(d>0) printf "%d", (d-(i2-i1))*100/d; else print 0}'
}

# 读取网络接口流量（单位换算）
iface_traffic() {
    local iface="$1" dir="$2"
    local f="/sys/class/net/$iface/statistics/${dir}_bytes"
    [[ -f "$f" ]] || { echo "0"; return; }
    local bytes=$(cat "$f")
    to_human "$bytes"
}

# 将字节转为人类可读
to_human() {
    local b="$1"
    awk -v b="$b" 'BEGIN{
        if(b>=1099511627776) printf "%.2f TB", b/1099511627776;
        else if(b>=1073741824) printf "%.2f GB", b/1073741824;
        else if(b>=1048576) printf "%.2f MB", b/1048576;
        else if(b>=1024) printf "%.2f KB", b/1024;
        else printf "%d B", b;
    }'
}

# 检测是否为 procps 版 ps（支持 --sort）
has_procps_ps() {
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu >/dev/null 2>&1
}

# 美化时长
pretty_uptime() {
    local s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60))
    local out=""
    ((d>0)) && out+="${d}天 "
    ((h>0)) && out+="${h}时 "
    ((m>0)) && out+="${m}分"
    echo "${out:-少于1分钟}"
}

# 从 /proc/cpuinfo 取 CPU 频率
cpu_mhz() {
    local mhz=$(awk '/^cpu MHz/{print $4; exit}' /proc/cpuinfo 2>/dev/null)
    if [[ -n "$mhz" ]]; then
        awk -v m="$mhz" 'BEGIN{printf "%.1f GHz", m/1000}'
    else
        echo "-"
    fi
}

# TCP/UDP 连接数
tcp_udp_count() {
    local tcp=0 udp=0
    if [[ -f /proc/net/tcp ]]; then
        tcp=$(awk 'NR>1 {count++} END{print count+0}' /proc/net/tcp)
    fi
    if [[ -f /proc/net/udp ]]; then
        udp=$(awk 'NR>1 {count++} END{print count+0}' /proc/net/udp)
    fi
    echo "${tcp}|${udp}"
}

# 总网络流量（所有接口累加）
total_traffic() {
    local dir="$1" total=0
    for f in /sys/class/net/*/statistics/${dir}_bytes; do
        [[ -f "$f" ]] && total=$((total + $(cat "$f")))
    done
    to_human "$total"
}

# 网络拥塞算法
net_algo() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "-"
}

# 通过外部 API 获取 IP 信息
ip_info() {
    local ip="" org="" city="" country="" dns=""
    if has curl; then
        ip=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)
    elif has wget; then
        ip=$(wget -qO- https://api.ipify.org 2>/dev/null)
    fi
    [[ -z "$ip" ]] && { echo ""; return; }

    local json
    if has curl; then
        json=$(curl -s --max-time 6 "https://ipinfo.io/${ip}/json" 2>/dev/null)
    elif has wget; then
        json=$(wget -qO- "https://ipinfo.io/${ip}/json" 2>/dev/null)
    fi
    org=$(echo "$json" | awk -F'"' '/"org":/{print $4}')
    city=$(echo "$json" | awk -F'"' '/"city":/{print $4}')
    country=$(echo "$json" | awk -F'"' '/"country":/{print $4}')

    # DNS
    if has resolvectl; then
        dns=$(resolvectl dns 2>/dev/null | awk '{print $NF}' | head -n1)
    elif [[ -f /etc/resolv.conf ]]; then
        dns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
    fi

    echo -e "运营商\t${org:-未知}\nIPv4地址\t${ip}\nDNS地址\t${dns:-未知}\n地理位置\t${country:-未知} ${city:-未知}"
}

# 按参考图风格打印信息
sysinfo_query() {
    section "系统信息查询"

    local host=$(hostname 2>/dev/null || echo 'localhost')
    local os=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    [[ -z "$os" ]] && os=$(uname -o)
    local cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
    local cpu_cores=$(nproc)
    local cpu_freq=$(cpu_mhz)
    local cpu_pct=$(cpu_usage)
    local load=$(awk '{print $1", "$2", "$3}' /proc/loadavg)
    local tcpudp=$(tcp_udp_count)
    local mem_total mem_used mem_pct swap_total swap_used swap_pct
    read -r _ mem_total mem_used _ _ _ mem_avail _ < <(free -m | awk 'NR==2{print}')
    mem_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.2f", t?u*100/t:0}')
    read -r _ swap_total swap_used _ < <(free -m | awk 'NR==3{print $1,$2,$3}')
    swap_pct=$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{printf "%.2f", t?u*100/t:0}')
    local rx=$(total_traffic "rx")
    local tx=$(total_traffic "tx")
    local algo=$(net_algo)
    local up=$(pretty_uptime)

    # 硬盘：根分区
    local disk_used disk_total disk_mount
    read -r disk_total disk_used _ _ disk_mount _ < <(df -h / 2>/dev/null | awk 'NR==2{print $2,$3,$4,$5,$6,$7}')

    # 输出：参考图风格
    printf '  ${CYAN}%-14s${RESET} %s\n' "主机名:" "$host"
    printf '  ${CYAN}%-14s${RESET} %s\n' "系统版本:" "$os"
    printf '  ${CYAN}%-14s${RESET} %s\n' "Linux版本:" "$(uname -r)"
    printf '  ${CYAN}%-14s${RESET} %s\n' "CPU架构:" "$(uname -m)"
    printf '  ${CYAN}%-14s${RESET} %s\n' "CPU型号:" "$cpu_model"
    printf '  ${CYAN}%-14s${RESET} %s\n' "CPU核心数:" "${cpu_cores}"
    printf '  ${CYAN}%-14s${RESET} %s\n' "CPU频率:" "$cpu_freq"
    printf '  ${CYAN}%-14s${RESET} %s\n' "CPU占用:" "${cpu_pct}%"
    printf '  ${CYAN}%-14s${RESET} %s\n' "系统负载:" "$load"
    printf '  ${CYAN}%-14s${RESET} %s\n' "TCP|UDP连接数:" "$tcpudp"
    printf '  ${CYAN}%-14s${RESET} %s\n' "物理内存:" "${mem_used}M/${mem_total}M (${mem_pct}%)"
    printf '  ${CYAN}%-14s${RESET} %s\n' "虚拟内存:" "${swap_used}M/${swap_total}M (${swap_pct}%)"
    printf '  ${CYAN}%-14s${RESET} %s\n' "硬盘占用:" "${disk_used}/${disk_total} (${disk_mount})"
    printf '  ${CYAN}%-14s${RESET} %s\n' "总接收:" "$rx"
    printf '  ${CYAN}%-14s${RESET} %s\n' "总发送:" "$tx"
    printf '  ${CYAN}%-14s${RESET} %s\n' "网络算法:" "$algo"

    # IP 信息
    local ipi=$(ip_info)
    if [[ -n "$ipi" ]]; then
        echo
        while IFS=$'\t' read -r k v; do
            printf '  ${CYAN}%-14s${RESET} %s\n' "$k" "$v"
        done <<< "$ipi"
    fi

    printf '  ${CYAN}%-14s${RESET} %s\n' "系统时间:" "$(date '+%Y-%m-%d %I:%M %p %Z')"
    printf '  ${CYAN}%-14s${RESET} %s\n' "运行时长:" "$up"
    pause
}

# ---------------------------------------------------------------------------
# 0. 仪表盘
# ---------------------------------------------------------------------------
dashboard() {
    section "仪表盘"

    # CPU
    subtitle "CPU"
    local cpu_pct=$(cpu_usage)
    local cpu_model="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
    printf "  ${DIM}%s${RESET}\n" "$cpu_model"
    bar "$cpu_pct" "CPU 使用率"

    # 内存
    subtitle "内存"
    local total used avail
    read -r _ total used _ _ _ avail _ < <(free -k | awk 'NR==2{print}')
    local mem_pct=$(pct_of "$used" "$total")
    local used_h=$(to_human "$(($used*1024))")
    local total_h=$(to_human "$(($total*1024))")
    local avail_h=$(to_human "$(($avail*1024))")
    printf "  ${DIM}%s / %s${RESET}   可用: ${GREEN}%s${RESET}\n" "$used_h" "$total_h" "$avail_h"
    bar "$mem_pct" "内存使用率"

    # 负载
    subtitle "系统负载"
    local a b c tasks; read -r a b c tasks _ < /proc/loadavg
    local cores=$(nproc)
    local la_pct=$(awk -v a="$a" -v c="$cores" 'BEGIN{printf "%d", a*100/c}')
    printf "  ${DIM}1m:${RESET} %s   ${DIM}5m:${RESET} %s   ${DIM}15m:${RESET} %s   ${DIM}任务:${RESET} %s\n" "$a" "$b" "$c" "$tasks"
    bar "$la_pct" "负载 / 核心数"

    # 磁盘
    subtitle "磁盘"
    while IFS=$'\t' read -r mount size used avail pct; do
        bar "$pct" "$mount"
    done < <(df -h 2>/dev/null | awk 'NR>1 && $1 !~ /^overlay|tmpfs|devtmpfs$/ {gsub(/%/,"",$5); print $6"\t"$2"\t"$3"\t"$4"\t"$5}' | head -n 5)

    # 网络
    subtitle "网络接口"
    local pub=""
    if has curl; then pub=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    elif has wget; then pub=$(wget -qO- https://api.ipify.org 2>/dev/null); fi
    [[ -n "$pub" ]] && printf "  ${DIM}公网 IP:${RESET} %s\n" "$pub"

    local -a nrows=($'接口\tIPv4\t接收\t发送')
    declare -A ip4
    while IFS=$'\t' read -r iface ip fam; do
        [[ "$fam" == "IPv4" ]] && ip4[$iface]="$ip"
    done < <(ip -o addr show 2>/dev/null | awk '$3=="inet" {print $2"\t"$4"\t""IPv4"}')
    local r
    for iface in /sys/class/net/*; do
        iface=$(basename "$iface")
        [[ "$iface" == "lo" ]] && continue
        local rx=$(iface_traffic "$iface" "rx")
        local tx=$(iface_traffic "$iface" "tx")
        printf -v r '%s\t%s\t%s\t%s' "$iface" "${ip4[$iface]:-—}" "$rx" "$tx"
        nrows+=("$r")
    done
    table L L R R "${nrows[@]}"

    # Top 进程
    subtitle "Top 进程"
    if has_procps_ps; then
        local -a prows=($'PID\t进程\tCPU%\tMEM%')
        while IFS=$'\t' read -r p c m u; do
            prows+=("$p"$'\t'"$c"$'\t'"$m"$'\t'"$u")
        done < <(ps -eo pid,comm:20,%cpu,%mem --sort=-%cpu | awk 'NR>1&& NR<=7 && $2!="ps" && $2!="awk" {print $1"\t"$2"\t"$3"\t"$4}')
        table R L R R "${prows[@]}"
    else
        top -bn1 2>/dev/null | head -n 12 || ps
    fi
    pause
}

# ---------------------------------------------------------------------------
# 1. 系统信息
# ---------------------------------------------------------------------------
system_info() {
    section "系统信息"
    local os="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)"
    [[ -z "$os" ]] && os="$(uname -o)"
    local up="$(uptime -p 2>/dev/null || uptime)"
    local cpu="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
    local a b c; read -r a b c _ < /proc/loadavg

    kv_card \
        "操作系统" "$os" \
        "内核版本" "$(uname -r)" \
        "系统架构" "$(uname -m)" \
        "运行时间" "$up" \
        "CPU 型号" "$cpu" \
        "CPU 核心" "$(nproc) 核" \
        "包管理器" "$PKG" \
        "Init 系统" "$INIT" \
        "系统负载" "$a / $b / $c"
    pause
}

# ---------------------------------------------------------------------------
# 2. 资源监控
# ---------------------------------------------------------------------------
resource_monitor() {
    section "资源监控"
    local total used free avail
    read -r _ total used free _ _ avail _ < <(free -k | awk 'NR==2{print}')
    local used_gb=$(to_gb "${used}K")
    local avail_gb=$(to_gb "${avail}K")
    local total_gb=$(to_gb "${total}K")
    local mem_pct=$(pct_of "$used" "$total")

    subtitle "内存使用"
    kv_card \
        "总量" "${total_gb} GB" \
        "已用" "${used_gb} GB (${mem_pct}%)" \
        "可用" "${avail_gb} GB"
    bar "$mem_pct" "内存使用率"

    subtitle "系统负载"
    local a b c tasks; read -r a b c tasks _ < /proc/loadavg
    kv_card \
        "1分钟" "$a" \
        "5分钟" "$b" \
        "15分钟" "$c" \
        "活跃任务" "$tasks"

    subtitle "进程排行"
    if has_procps_ps; then
        local -a topcpu=($'PID\t进程\tCPU%\tMEM%')
        while IFS=$'\t' read -r p c m u; do
            topcpu+=("$p"$'\t'"$c"$'\t'"$m"$'\t'"$u")
        done < <(ps -eo pid,comm:20,%cpu,%mem --sort=-%cpu | awk 'NR>1{print $1"\t"$2"\t"$3"\t"$4}' | head -n 6)

        local -a topmem=($'PID\t进程\tCPU%\tMEM%')
        while IFS=$'\t' read -r p c m u; do
            topmem+=("$p"$'\t'"$c"$'\t'"$m"$'\t'"$u")
        done < <(ps -eo pid,comm:20,%cpu,%mem --sort=-%mem | awk 'NR>1{print $1"\t"$2"\t"$3"\t"$4}' | head -n 6)

        echo
        table R L R R "${topcpu[@]}"
        echo
        table R L R R "${topmem[@]}"
    else
        top -bn1 2>/dev/null | head -n 12 || ps
    fi
    pause
}

# ---------------------------------------------------------------------------
# 3. 网络管理
# ---------------------------------------------------------------------------
network_menu() {
    while true; do
        section "网络管理"
        cat <<EOF
  1. 内网 IP
  2. 公网 IP
  3. 监听端口
  4. 连接统计
  5. ping 测试
  0. 返回
EOF
        read -rp "请选择: " n
        case "$n" in
            1)
                section "内网 IP"
                local -a rows=($'接口\tIPv4 地址\tIPv6 地址')
                local r
                declare -A iface4 iface6
                while IFS=$'\t' read -r iface ip fam; do
                    if [[ "$fam" == "IPv4" ]]; then
                        [[ -n "${iface4[$iface]}" ]] && iface4[$iface]+=", "
                        iface4[$iface]+="$ip"
                    else
                        [[ -n "${iface6[$iface]}" ]] && iface6[$iface]+=", "
                        iface6[$iface]+="$ip"
                    fi
                done < <(ip -o addr show 2>/dev/null | awk '
                    $3=="inet"  {print $2 "\t" $4 "\tIPv4"}
                    $3=="inet6" {print $2 "\t" $4 "\tIPv6"}')
                for iface in "${!iface4[@]}" "${!iface6[@]}"; do
                    [[ -n "${seen[$iface]}" ]] && continue
                    seen[$iface]=1
                    printf -v r '%s\t%s\t%s' "$iface" "${iface4[$iface]:-—}" "${iface6[$iface]:-—}"
                    rows+=("$r")
                done
                table L L L "${rows[@]}"
                pause ;;
            2)
                section "公网 IP"
                local pub=""
                if has curl; then pub=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
                elif has wget; then pub=$(wget -qO- https://api.ipify.org 2>/dev/null); fi
                if [[ -n "$pub" ]]; then
                    kv_card "公网 IPv4" "$pub"
                else
                    err "获取失败"
                fi
                pause ;;
            3)
                section "监听端口"
                if has ss; then
                    local -a rows=($'协议\t地址\t端口\t状态\t进程')
                    local r
                    while IFS=$'\t' read -r proto addr port state proc; do
                        printf -v r '%s\t%s\t%s\t%s\t%s' "$proto" "$addr" "$port" "$state" "$proc"
                        rows+=("$r")
                    done < <($SUDO ss -tulnpH 2>/dev/null | awk '
                        NF>=6 {
                            proto=$1; state=$2; local=$5; proc=$0
                            sub(/.*users:/, "", proc)
                            gsub(/\)/, "", proc)
                            gsub(/^\(\("/, "", proc)
                            gsub(/"/, "", proc)
                            # 只保留进程名，去掉 fd
                            n=split(proc, b, ","); proc=b[1]
                            # 拆分地址和端口（兼容 IPv6）
                            if (local ~ /^\[/) {
                                match(local, /\[([^]]+)\]:([0-9]+)/, m)
                                addr=m[1]; port=m[2]
                            } else {
                                n=split(local, a, ":"); port=a[n]
                                addr=local; sub(":" port "$", "", addr)
                            }
                            print proto "\t" addr "\t" port "\t" state "\t" proc
                        }' | head -n 30)
                    table L L R C L "${rows[@]}"
                else
                    run $SUDO netstat -tulnp
                fi
                pause ;;
            4)
                section "连接统计"
                if has ss; then
                    local -a rows=($'协议\t连接数')
                    local tcp total
                    tcp=$(ss -s 2>/dev/null | awk '/TCP:/{print $2}' | tr -d ',')
                    total=$(ss -s 2>/dev/null | awk '/TCP:/{getline; print $2}' | tr -d ',' 2>/dev/null)
                    [[ -n "$tcp" ]] && rows+=("TCP"$'\t'"$tcp")
                    [[ -n "$total" ]] && rows+=("总计"$'\t'"$total")
                    if (( ${#rows[@]} > 1 )); then
                        table L R "${rows[@]}"
                    else
                        ss -s 2>/dev/null | sed -n '/TCP:/,/UDP:/p' | sed '$d'
                    fi
                else
                    info "总连接数"; netstat -an 2>/dev/null | wc -l
                fi
                pause ;;
            5)
                read -rp "目标地址 (默认 8.8.8.8): " host
                host="${host:-8.8.8.8}"
                run ping -c 4 "$host"
                pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 4. 磁盘管理
# ---------------------------------------------------------------------------
disk_menu() {
    section "磁盘管理"

    subtitle "磁盘空间"
    local -a rows=($'挂载点\t文件系统\t总量\t已用\t可用\t使用率')
    local row
    while IFS=$'\t' read -r fs mount type size used avail pct; do
        printf -v row '%s\t%s\t%s\t%s\t%s\t%s' "$mount" "$fs" "$size" "$used" "$avail" "$pct"
        rows+=("$row")
    done < <(df -hT 2>/dev/null | awk 'NR>1 && $2 != "overlay" && $2 != "tmpfs" && $2 != "devtmpfs" {
        if (NF==7) { print $1"\t"$7"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6 }
        else       { print $1"\t"$6"\t-\t"$2"\t"$3"\t"$4"\t"$5 }
    }')
    table L L R R R R "${rows[@]}"

    # 使用率进度条
    df -h 2>/dev/null | awk 'NR>1 && $1 !~ /^overlay|tmpfs|devtmpfs$/ {print $1"\t"$6"\t"$5}' | head -n 8 | while IFS=$'\t' read -r fs mount pct; do
        bar "$pct" "$mount"
    done

    subtitle "当前目录占用 Top 10"
    local -a drows=($'路径\t大小')
    while IFS=$'\t' read -r size path; do
        printf -v row '%s\t%s' "$path" "$size"
        drows+=("$row")
    done < <(du -sh ./* 2>/dev/null | awk '{print $1"\t"$2}' | { sort -rh 2>/dev/null || sort -r; } | head -n 10)
    table L R "${drows[@]}"

    if has lsblk; then
        subtitle "块设备"
        lsblk 2>/dev/null | sed 's/^/  /'
    fi
    pause
}

# ---------------------------------------------------------------------------
# 5. 进程管理
# ---------------------------------------------------------------------------
process_menu() {
    while true; do
        section "进程管理"
        cat <<EOF
  1. 实时监控 (top/htop)
  2. 查找进程
  3. 结束进程 (kill)
  0. 返回
EOF
        read -rp "请选择: " p
        case "$p" in
            1) if has htop; then run htop; else run top; fi ;;
            2)
                read -rp "关键字: " kw
                if [[ -n "$kw" ]]; then
                    local -a rows=($'PID\t用户\tCPU%\t内存%\t命令')
                    while read -r pid user cpu mem comm; do
                        rows+=("$pid"$'\t'"$user"$'\t'"$cpu"$'\t'"$mem"$'\t'"$comm")
                    done < <(ps -eo pid,user:12,%cpu,%mem,comm:30 --sort=-%cpu 2>/dev/null | grep -i "$kw" | grep -v grep | head -n 20)
                    table R L R R L "${rows[@]}"
                fi
                pause ;;
            3)
                read -rp "PID: " pid
                [[ "$pid" =~ ^[0-9]+$ ]] && { run $SUDO kill -15 "$pid" || run $SUDO kill -9 "$pid"; } || err "PID 无效"
                pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 6. 服务管理
# ---------------------------------------------------------------------------
svc_action() {
    local act="$1" svc="$2"
    case "$INIT" in
        systemd)
            case "$act" in
                status)  run $SUDO systemctl status "$svc" --no-pager ;;
                enable)  run $SUDO systemctl enable "$svc" ;;
                disable) run $SUDO systemctl disable "$svc" ;;
                *)       run $SUDO systemctl "$act" "$svc" ;;
            esac ;;
        openrc)
            case "$act" in
                enable)  run $SUDO rc-update add "$svc" ;;
                disable) run $SUDO rc-update del "$svc" ;;
                *)       run $SUDO rc-service "$svc" "$act" ;;
            esac ;;
        *)
            case "$act" in
                enable|disable) warn "当前 init 不支持自启设置"; return 1 ;;
                *)       run $SUDO service "$svc" "$act" ;;
            esac ;;
    esac
}

service_menu() {
    [[ "$INIT" == "unknown" ]] && { warn "未识别 init 系统"; pause; return; }
    read -rp "服务名 (如 sshd/nginx): " svc
    [[ -z "$svc" ]] && { err "服务名不能为空"; pause; return; }
    while true; do
        section "服务管理: $svc"
        cat <<EOF
  1. 查看状态
  2. 启动服务
  3. 停止服务
  4. 重启服务
  5. 开机自启
  6. 取消自启
  0. 返回
EOF
        read -rp "请选择: " s
        case "$s" in
            1) svc_action status "$svc"; pause ;;
            2) svc_action start "$svc"  && info "已启动"; pause ;;
            3) svc_action stop "$svc"   && info "已停止"; pause ;;
            4) svc_action restart "$svc" && info "已重启"; pause ;;
            5) svc_action enable "$svc"  && info "已设为自启"; pause ;;
            6) svc_action disable "$svc" && info "已取消自启"; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 7. 用户管理
# ---------------------------------------------------------------------------
user_menu() {
    section "用户管理"

    subtitle "当前登录用户"
    local -a rows=($'用户\t终端\t登录时间\t来源')
    if who >/dev/null 2>&1; then
        while IFS=$'\t' read -r u t d s; do
            rows+=("$u"$'\t'"$t"$'\t'"$d"$'\t'"$s")
        done < <(who | awk '{print $1"\t"$2"\t"$3" "$4"\t"$5}')
    fi
    table L L L L "${rows[@]}"

    subtitle "普通用户 (UID>=1000)"
    local -a urows=($'用户\tUID\t家目录\tShell')
    while IFS=$'\t' read -r u i h s; do
        urows+=("$u"$'\t'"$i"$'\t'"$h"$'\t'"$s")
    done < <(awk -F: '$3>=1000 && $3<65534 {print $1"\t"$3"\t"$6"\t"$7}' /etc/passwd)
    table L R L L "${urows[@]}"
    pause
}

# ---------------------------------------------------------------------------
# 8. 防火墙管理
# ---------------------------------------------------------------------------
firewall_menu() {
    section "防火墙管理"
    if has ufw; then
        info "UFW 状态"
        run $SUDO ufw status verbose
        warn "放行端口: $SUDO ufw allow <port>/tcp"
    elif has firewall-cmd; then
        info "firewalld 配置"
        run $SUDO firewall-cmd --list-all
    else
        info "iptables 规则"
        run $SUDO iptables -L -n -v 2>/dev/null || warn "未安装 iptables"
    fi
    pause
}

# ---------------------------------------------------------------------------
# 9. 系统更新
# ---------------------------------------------------------------------------
system_update() {
    section "系统更新"
    case "$PKG" in
        apt)    run $SUDO apt-get update && run $SUDO apt-get upgrade -y ;;
        dnf)    run $SUDO dnf upgrade -y ;;
        yum)    run $SUDO yum update -y ;;
        apk)    run $SUDO apk update && run $SUDO apk upgrade ;;
        pacman) run $SUDO pacman -Syu --noconfirm ;;
        *)      err "未识别包管理器" ;;
    esac
    pause
}

# ---------------------------------------------------------------------------
# A. Alpine 专属
# ---------------------------------------------------------------------------
need() { has "$1" || { err "未找到 $1（尝试: apk add alpine-conf）"; return 1; }; }

apk_menu() {
    while true; do
        section "apk 包管理"
        cat <<EOF
  1. 更新索引 (apk update)
  2. 升级全部 (apk upgrade)
  3. 安装软件
  4. 卸载软件
  5. 搜索软件
  6. 已装列表
  7. 一键安装常用包
  0. 返回
EOF
        read -rp "请选择: " p
        case "$p" in
            1) run $SUDO apk update; pause ;;
            2) run $SUDO apk upgrade; pause ;;
            3) read -rp "包名: " pkgs; [[ -n "$pkgs" ]] && run $SUDO apk add $pkgs; pause ;;
            4) read -rp "包名: " pkgs; [[ -n "$pkgs" ]] && run $SUDO apk del $pkgs; pause ;;
            5) read -rp "关键字: " kw; [[ -n "$kw" ]] && run apk search "$kw"; pause ;;
            6) run apk info; pause ;;
            7)
                local tools="bash curl wget vim nano htop git iproute2 iptables tzdata bash-completion"
                info "将安装: $tools"
                read -rp "确认? [y/N] " yn
                case "$yn" in [yY]*) run $SUDO apk add $tools ;; *) warn "已取消" ;; esac
                pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

openrc_list() {
    section "OpenRC 服务清单"
    if has rc-status; then
        info "运行级别状态"
        run $SUDO rc-status --all
        echo
        info "开机自启"
        run $SUDO rc-update show
    else
        warn "未安装 OpenRC"
    fi
    pause
}

setup_menu() {
    while true; do
        section "Alpine 配置向导"
        cat <<EOF
  1. setup-sshd
  2. setup-timezone
  3. setup-ntp
  4. setup-hostname
  5. setup-apkrepos
  6. setup-interfaces
  0. 返回
EOF
        read -rp "请选择: " s
        case "$s" in
            1) need setup-sshd       && run $SUDO setup-sshd; pause ;;
            2) need setup-timezone   && run $SUDO setup-timezone; pause ;;
            3) need setup-ntp        && run $SUDO setup-ntp; pause ;;
            4) need setup-hostname   && run $SUDO setup-hostname; pause ;;
            5) need setup-apkrepos   && run $SUDO setup-apkrepos; pause ;;
            6) need setup-interfaces && run $SUDO setup-interfaces; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

alpine_menu() {
    (( IS_ALPINE )) || { warn "非 Alpine 系统"; pause; return; }
    while true; do
        section "Alpine 专属工具"
        cat <<EOF
  1. apk 包管理
  2. OpenRC 服务
  3. setup 向导
  0. 返回
EOF
        read -rp "请选择: " a
        case "$a" in
            1) apk_menu ;;
            2) openrc_list ;;
            3) setup_menu ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# T. 进阶工具
# ---------------------------------------------------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"

ssh_restart() {
    case "$INIT" in
        systemd) run $SUDO systemctl restart sshd 2>/dev/null || run $SUDO systemctl restart ssh ;;
        openrc)  run $SUDO rc-service sshd restart ;;
        *)       run $SUDO service sshd restart 2>/dev/null || run $SUDO service ssh restart ;;
    esac
}

set_sshd_option() {
    local key="$1" val="$2" bak
    [[ -f "$SSHD_CONFIG" ]] || { err "未找到 $SSHD_CONFIG"; return 1; }
    bak="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    run $SUDO cp "$SSHD_CONFIG" "$bak"
    $SUDO sed -i -E "/^[#[:space:]]*${key}[[:space:]]/d" "$SSHD_CONFIG"
    echo "$key $val" | $SUDO tee -a "$SSHD_CONFIG" >/dev/null
    info "已写入: ${key} ${val}"
    if $SUDO sshd -t 2>/dev/null; then
        info "配置校验通过"
        return 0
    else
        err "校验失败，已回滚！"
        $SUDO cp "$bak" "$SSHD_CONFIG"
        return 1
    fi
}

ssh_menu() {
    while true; do
        section "SSH 安全加固"
        warn "操作前请另开一个 SSH 会话，避免被锁"
        cat <<EOF
  1. 修改 SSH 端口
  2. 禁止 root 密码登录
  3. 完全禁用密码登录
  4. 添加公钥到 authorized_keys
  5. 查看当前 SSH 配置
  0. 返回
EOF
        read -rp "请选择: " s
        case "$s" in
            1) read -rp "新端口: " port
               if [[ "$port" =~ ^[0-9]+$ ]] && (( port>=1 && port<=65535 )); then
                   if set_sshd_option Port "$port"; then
                       warn "放行端口: ufw allow ${port}/tcp 或 firewall-cmd --add-port=${port}/tcp --permanent"
                       read -rp "重启 SSH? [y/N] " yn; case "$yn" in [yY]*) ssh_restart ;; esac
                   fi
               else err "端口无效"; fi; pause ;;
            2) set_sshd_option PermitRootLogin prohibit-password && read -rp "重启? [y/N] " yn && case "$yn" in [yY]*) ssh_restart ;; esac; pause ;;
            3) warn "确保已能用密钥登录"; read -rp "输入 yes 确认: " c
               [[ "$c" == "yes" ]] && set_sshd_option PasswordAuthentication no && read -rp "重启? [y/N] " yn && case "$yn" in [yY]*) ssh_restart ;; esac
               pause ;;
            4) read -rp "粘贴公钥: " pubkey
               if [[ "$pubkey" =~ ^(ssh-|ecdsa-) ]]; then
                   mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
                   echo "$pubkey" >> "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
                   info "已添加"
               else err "格式错误"; fi; pause ;;
            5) section "SSH 当前配置"
               grep -Ei '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' "$SSHD_CONFIG" 2>/dev/null || warn "未显式配置（使用默认值）"
               pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

swap_menu() {
    while true; do
        section "Swap 管理"
        info "当前 Swap:"; swapon --show 2>/dev/null || cat /proc/swaps 2>/dev/null
        cat <<EOF
  1. 创建 Swap 文件
  2. 删除 Swap 文件
  0. 返回
EOF
        read -rp "请选择: " s
        local file="/swapfile"
        case "$s" in
            1) [[ -e "$file" ]] && { warn "$file 已存在"; pause; continue; }
               read -rp "大小 GB (默认 1): " sz; sz="${sz:-1}"
               [[ "$sz" =~ ^[0-9]+$ ]] || { err "请输入整数"; pause; continue; }
               if has fallocate; then run $SUDO fallocate -l "${sz}G" "$file"; fi
               [[ -s "$file" ]] || run $SUDO dd if=/dev/zero of="$file" bs=1M count=$((sz*1024))
               run $SUDO chmod 600 "$file"
               run $SUDO mkswap "$file" && run $SUDO swapon "$file" || { err "启用失败"; pause; continue; }
               grep -q "^${file} " /etc/fstab 2>/dev/null || echo "$file none swap sw 0 0" | $SUDO tee -a /etc/fstab >/dev/null
               info "完成"; free -h 2>/dev/null || free -m; pause ;;
            2) [[ -e "$file" ]] || { warn "$file 不存在"; pause; continue; }
               run $SUDO swapoff "$file" 2>/dev/null
               $SUDO sed -i "\#^${file} #d" /etc/fstab 2>/dev/null
               run $SUDO rm -f "$file"; info "已删除"; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

bbr_menu() {
    local conf="/etc/sysctl.d/99-bbr.conf"
    while true; do
        section "BBR 加速"
        cat <<EOF
  1. 开启 BBR
  2. 查看 BBR 状态
  0. 返回
EOF
        read -rp "请选择: " s
        case "$s" in
            1) $SUDO modprobe tcp_bbr 2>/dev/null
               printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' | $SUDO tee "$conf" >/dev/null
               $SUDO sysctl --system >/dev/null 2>&1 || $SUDO sysctl -p "$conf" >/dev/null 2>&1
               local cur; cur="$($SUDO sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
               [[ "$cur" == "bbr" ]] && info "BBR 已开启" || warn "当前算法: ${cur:-未知}（内核可能不支持）"
               pause ;;
            2) section "BBR 状态"
               $SUDO sysctl net.ipv4.tcp_congestion_control 2>/dev/null
               $SUDO sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null
               lsmod 2>/dev/null | grep -i bbr || echo "(未加载或已编译进内核)"
               pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

docker_menu() {
    while true; do
        section "Docker"
        if has docker; then info "版本: $(docker --version)"; else warn "未安装"; fi
        cat <<EOF
  1. 安装 Docker
  2. 启动/查看 Docker 服务
  3. 容器列表 (docker ps -a)
  4. 镜像列表 (docker images)
  0. 返回
EOF
        read -rp "请选择: " s
        case "$s" in
            1) has docker && { info "已安装"; pause; continue; }
               if [[ "$PKG" == "apk" ]]; then
                   run $SUDO apk add --no-cache docker docker-cli-compose
                   [[ "$INIT" == "openrc" ]] && { run $SUDO rc-update add docker default; run $SUDO rc-service docker start; }
               else
                   warn "将执行: curl -fsSL https://get.docker.com | sh"
                   read -rp "确认? [y/N] " yn
                   case "$yn" in
                       [yY]*) if has curl; then run bash -c "curl -fsSL https://get.docker.com | $SUDO sh"
                              elif has wget; then run bash -c "wget -qO- https://get.docker.com | $SUDO sh"
                              else err "需要 curl/wget"; fi
                              [[ "$INIT" == "systemd" ]] && run $SUDO systemctl enable --now docker ;;
                       *) warn "已取消" ;;
                   esac
               fi; pause ;;
            2) svc_action status docker || svc_action start docker; pause ;;
            3) has docker && run $SUDO docker ps -a || err "未安装"; pause ;;
            4) has docker && run $SUDO docker images || err "未安装"; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

advanced_menu() {
    while true; do
        section "进阶工具"
        cat <<EOF
  1. SSH 安全加固
  2. Swap 虚拟内存
  3. BBR 加速
  4. Docker 安装与管理
  0. 返回
EOF
        read -rp "请选择: " a
        case "$a" in
            1) ssh_menu ;;
            2) swap_menu ;;
            3) bbr_menu ;;
            4) docker_menu ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 主菜单
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        local t=$(date '+%Y-%m-%d %H:%M:%S')
        local host=$(hostname 2>/dev/null || echo 'localhost')
        printf '\n'
        printf "  ${BOLD}${CYAN}%s${RESET}\n" "${BANNER_TOP}"
        printf "  ${BOLD}${CYAN}%s${RESET}  ${BOLD}VPS 运维工具箱${RESET}${DIM}  %s@${RESET}${CYAN}%s${RESET}     ${BOLD}${CYAN}%s${RESET}\n" "${BANNER_V}" "$USER" "$host" "${BANNER_V}"
        printf "  ${BOLD}${CYAN}%s${RESET}  ${DIM}%s${RESET}   pkg:%s  init:%s      ${BOLD}${CYAN}%s${RESET}\n" "${BANNER_V}" "$t" "$PKG" "$INIT" "${BANNER_V}"
        printf "  ${BOLD}${CYAN}%s${RESET}\n\n" "${BANNER_BOT}"

        cat <<EOF
   ${GREEN}1.${RESET} 系统信息
   ${GREEN}2.${RESET} 资源监控
   ${GREEN}3.${RESET} 网络管理
   ${GREEN}4.${RESET} 磁盘管理
   ${GREEN}5.${RESET} 进程管理
   ${GREEN}6.${RESET} 服务管理
   ${GREEN}7.${RESET} 用户管理
   ${GREEN}8.${RESET} 防火墙管理
   ${GREEN}9.${RESET} 系统更新
   ${GREEN}10.${RESET} 进阶工具 (SSH加固 / Swap / BBR / Docker)
   ${GREEN}11.${RESET} 仪表盘 (一屏总览)
   ${GREEN}12.${RESET} 系统信息查询
EOF
        (( IS_ALPINE )) && echo -e "   ${GREEN}13.${RESET} Alpine 专属工具"
        echo -e "   ${GREEN}0.${RESET} 退出"
        echo
        read -rp "请输入选项: " choice
        case "$choice" in
            1) system_info ;;
            2) resource_monitor ;;
            3) network_menu ;;
            4) disk_menu ;;
            5) process_menu ;;
            6) service_menu ;;
            7) user_menu ;;
            8) firewall_menu ;;
            9) system_update ;;
            10) advanced_menu ;;
            11) dashboard ;;
            12) sysinfo_query ;;
            13) alpine_menu ;;
            0) info "再见!"; exit 0 ;;
            *) err "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu
