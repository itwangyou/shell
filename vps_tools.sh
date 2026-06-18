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

# 根据 locale 选择表格字符（UTF-8 用 box-drawing，否则 ASCII）
if [[ "${LANG,,}" == *utf-8* || "${LANG,,}" == *utf8* || \
      "${LC_ALL,,}" == *utf-8* || "${LC_ALL,,}" == *utf8* ]]; then
    BOX_TL='┌'; BOX_TM='┬'; BOX_TR='┐'
    BOX_ML='├'; BOX_MM='┼'; BOX_MR='┤'
    BOX_BL='└'; BOX_BM='┴'; BOX_BR='┘'
    BOX_H='─'; BOX_V='│'
else
    BOX_TL='+'; BOX_TM='+'; BOX_TR='+'
    BOX_ML='+'; BOX_MM='+'; BOX_MR='+'
    BOX_BL='+'; BOX_BM='+'; BOX_BR='+'
    BOX_H='-'; BOX_V='|'
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
        # 最大列宽上限，避免超长
        if (( widths[i] > 60 )); then widths[$i]=60; fi
    done

    local top="${BOX_TL}" mid="${BOX_ML}" bot="${BOX_BL}"
    for ((i=0; i<max_cols; i++)); do
        local pad=$(printf '%*s' "$((widths[i]+2))" '' | tr ' ' "${BOX_H}")
        top+="${pad}"; mid+="${pad}"; bot+="${pad}"
        if (( i < max_cols-1 )); then
            top+="${BOX_TM}"; mid+="${BOX_MM}"; bot+="${BOX_BM}"
        else
            top+="${BOX_TR}"; mid+="${BOX_MR}"; bot+="${BOX_BR}"
        fi
    done

    echo "$top"
    local first=1 zebra=0
    for line in "${rows[@]}"; do
        [[ "$line" == "--" ]] && continue
        IFS=$'\t' read -ra cols <<< "$line"
        if (( first )); then
            first=0
        else
            (( zebra++ % 2 == 0 )) && echo -en "${DIM}"
        fi
        printf '%s' "${BOX_V}"
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

# 键值对列表
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
        printf "  ${CYAN}%-${max}s${RESET}  ${DIM}│${RESET}  %s\n" "$k" "$v"
    done
}

# 居中大标题
section() {
    local txt=" $* " len=${#txt} pad=$(( (TERM_W - len) / 2 ))
    printf '\n'
    printf '%*s' "$pad" '' | tr ' ' '='
    printf '%s' "${BOLD}${CYAN}${txt}${RESET}"
    printf '%*s\n' "$(( TERM_W - pad - len ))" '' | tr ' ' '='
}

# 小标题
subtitle() { echo -e "\n${BOLD}$*${RESET}"; }

# 进度条
bar() {
    local pct="$1" label="${2:-}" width=32
    pct=${pct%\%}
    [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || pct=0
    local ipct=$(awk -v p="$pct" 'BEGIN{printf "%d", p}')
    (( ipct > 100 )) && ipct=100
    local fill=$(( width * ipct / 100 ))
    local color
    if   (( ipct < 70 )); then color="$GREEN"
    elif (( ipct < 90 )); then color="$YELLOW"
    else                         color="$RED"; fi
    local bar=$(printf '%*s' "$fill" '' | tr ' ' '#')
    local empty=$(printf '%*s' "$((width-fill))" '' | tr ' ' '-')
    [[ -n "$label" ]] && printf '  %-18s ' "$label"
    printf "${color}%s%s${RESET} %3d%%\n" "$bar" "$empty" "$ipct"
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

# ---------------------------------------------------------------------------
# 1. 系统信息
# ---------------------------------------------------------------------------
system_info() {
    section "系统信息"
    local os="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)"
    [[ -z "$os" ]] && os="$(uname -o)"
    local up="$(uptime -p 2>/dev/null || uptime)"
    local cpu="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"

    subtitle "基础信息"
    kv \
        "操作系统" "$os" \
        "内核版本" "$(uname -r)" \
        "系统架构" "$(uname -m)" \
        "运行时间" "$up" \
        "CPU 型号" "$cpu" \
        "CPU 核心" "$(nproc) 核" \
        "包管理器" "$PKG" \
        "Init 系统" "$INIT"

    if [[ -f /proc/loadavg ]]; then
        local a b c; read -r a b c _ < /proc/loadavg
        subtitle "系统负载"
        table R R R \
            $'1分钟\t5分钟\t15分钟' \
            "${a}"$'\t'"${b}"$'\t'"${c}"
    fi
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
    local free_gb=$(to_gb "${free}K")
    local avail_gb=$(to_gb "${avail}K")
    local total_gb=$(to_gb "${total}K")
    local mem_pct=$(pct_of "$used" "$total")

    subtitle "内存使用"
    table L R R R R \
        $'类型\t总量\t已用\t可用\t使用率' \
        $'物理内存\t'"${total_gb} GB"$'\t'"${used_gb} GB"$'\t'"${avail_gb} GB"$'\t'"${mem_pct}%"
    bar "$mem_pct" "内存"

    subtitle "系统负载"
    local a b c tasks; read -r a b c tasks _ < /proc/loadavg
    table R R R L \
        $'1分钟\t5分钟\t15分钟\t活跃任务' \
        $''"${a}"$'\t'"${b}"$'\t'"${c}"$'\t'"${tasks}"

    subtitle "进程排行"
    if ps -eo pid,comm,%cpu,%mem --sort=-%cpu >/dev/null 2>&1; then
        local -a topcpu=($'PID\t进程名\tCPU%\t内存%')
        while IFS=$'\t' read -r p c m u; do
            topcpu+=("$p"$'\t'"$c"$'\t'"$m"$'\t'"$u")
        done < <(ps -eo pid,comm:20,%cpu,%mem --sort=-%cpu | awk 'NR>1{print $1"\t"$2"\t"$3"\t"$4}' | head -n 6)

        local -a topmem=($'PID\t进程名\tCPU%\t内存%')
        while IFS=$'\t' read -r p c m u; do
            topmem+=("$p"$'\t'"$c"$'\t'"$m"$'\t'"$u")
        done < <(ps -eo pid,comm:20,%cpu,%mem --sort=-%mem | awk 'NR>1{print $1"\t"$2"\t"$3"\t"$4}' | head -n 6)

        echo -e "\n${DIM}CPU 占用最高:${RESET}"
        table R L R R "${topcpu[@]}"
        echo -e "\n${DIM}内存占用最高:${RESET}"
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
  1) 内网 IP          2) 公网 IP
  3) 监听端口          4) 连接统计
  5) ping 测试         0) 返回
EOF
        read -rp "请选择: " n
        case "$n" in
            1)
                section "内网 IP"
                local -a rows=($'接口\t地址\t族')
                local r
                while IFS=$'\t' read -r iface ip fam; do
                    printf -v r '%s\t%s\t%s' "$iface" "$ip" "$fam"
                    rows+=("$r")
                done < <(ip -o addr show 2>/dev/null | awk '
                    $3=="inet"  {print $2 "\t" $4 "\tIPv4"}
                    $3=="inet6" {print $2 "\t" $4 "\tIPv6"}')
                table L L C "${rows[@]}"
                pause ;;
            2)
                section "公网 IP"
                local pub=""
                if has curl; then pub=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
                elif has wget; then pub=$(wget -qO- https://api.ipify.org 2>/dev/null); fi
                [[ -n "$pub" ]] && kv "IPv4" "$pub" || err "获取失败"
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
                            sub(/.*users:/, "", proc); gsub(/\)/, "", proc)
                            gsub(/^\(\("/, "", proc); gsub(/"/, "", proc)
                            n=split(local, a, ":"); port=a[n]; addr=local; sub(":" port "$", "", addr)
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
                    ss -s 2>/dev/null | sed -n '/TCP:/,/UDP:/p' | sed '$d'
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
    local -a rows=($'文件系统\t挂载点\t类型\t总量\t已用\t可用\t使用率')
    local row
    while IFS=$'\t' read -r fs mount type size used avail pct; do
        printf -v row '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$fs" "$mount" "$type" "$size" "$used" "$avail" "$pct"
        rows+=("$row")
    done < <(df -hT 2>/dev/null | awk 'NR>1 && $2 != "overlay" {
        if (NF==7) { print $1"\t"$7"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6 }
        else       { print $1"\t"$6"\t-\t"$2"\t"$3"\t"$4"\t"$5 }
    }')
    table L L L R R R R "${rows[@]}"

    # 进度条（过滤 overlay，限制数量）
    df -h 2>/dev/null | awk 'NR>1 && $1 !~ /^overlay$/ {print $1"\t"$6"\t"$5}' | head -n 8 | while IFS=$'\t' read -r fs mount pct; do
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
        run lsblk
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
  1) 实时监控 (top/htop)    2) 查找进程
  3) 结束进程 (kill)         0) 返回
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
  1) 状态    2) 启动    3) 停止
  4) 重启    5) 自启    6) 取消自启
  0) 返回
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
  1) 更新索引    2) 升级全部
  3) 安装        4) 卸载
  5) 搜索        6) 已装列表
  7) 一键常用包  0) 返回
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
  1) setup-sshd       2) setup-timezone
  3) setup-ntp        4) setup-hostname
  5) setup-apkrepos   6) setup-interfaces
  0) 返回
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
  1) apk 包管理    2) OpenRC 服务
  3) setup 向导    0) 返回
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
  1) 修改端口          2) 禁止 root 密码登录
  3) 完全禁用密码登录   4) 添加公钥
  5) 查看当前配置       0) 返回
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
  1) 创建 Swap 文件    2) 删除 Swap 文件
  0) 返回
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
  1) 开启 BBR    2) 查看状态    0) 返回
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
  1) 安装 Docker    2) 启动/查看服务
  3) 容器列表      4) 镜像列表
  0) 返回
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
  1) SSH 加固    2) Swap
  3) BBR         4) Docker
  0) 返回
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
        printf "  ${BOLD}${CYAN}┌──────────────────────────────────────────┐${RESET}\n"
        printf "  ${BOLD}${CYAN}│${RESET}  ${BOLD}VPS 运维工具箱${RESET}${DIM}  %s@${RESET}${CYAN}%s${RESET}     ${BOLD}${CYAN}│${RESET}\n" "$USER" "$host"
        printf "  ${BOLD}${CYAN}│${RESET}  ${DIM}%s${RESET}   pkg:%s  init:%s      ${BOLD}${CYAN}│${RESET}\n" "$t" "$PKG" "$INIT"
        printf "  ${BOLD}${CYAN}└──────────────────────────────────────────┘${RESET}\n\n"

        cat <<EOF
   ${GREEN}1)${RESET} 系统信息    ${GREEN}2)${RESET} 资源监控    ${GREEN}3)${RESET} 网络管理
   ${GREEN}4)${RESET} 磁盘管理    ${GREEN}5)${RESET} 进程管理    ${GREEN}6)${RESET} 服务管理
   ${GREEN}7)${RESET} 用户管理    ${GREEN}8)${RESET} 防火墙    ${GREEN}9)${RESET} 系统更新
   ${GREEN}t)${RESET} 进阶工具   ${GREEN}0)${RESET} 退出
EOF
        (( IS_ALPINE )) && echo -e "   ${GREEN}a)${RESET} Alpine 专属"
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
            t|T) advanced_menu ;;
            a|A) alpine_menu ;;
            0) info "再见!"; exit 0 ;;
            *) err "无效选项"; sleep 1 ;;
        esac
    done
}

main_menu
