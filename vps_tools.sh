#!/usr/bin/env bash
#
# vps_tools.sh —— VPS 常用命令交互式脚本
# 适用于 Debian/Ubuntu/CentOS 等常见发行版
#
# 用法: bash vps_tools.sh    或    chmod +x vps_tools.sh && ./vps_tools.sh
#

set -o pipefail

# ---------------------------------------------------------------------------
# 颜色与基础工具
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
    BLUE=$'\e[34m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
fi

# 是否拥有 root 权限；非 root 时给命令加 sudo（用 id -u 而非 $EUID，兼容非 bash）
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# 命令是否存在
has() { command -v "$1" >/dev/null 2>&1; }

# 打印标题
title() { echo -e "\n${BOLD}${CYAN}===== $* =====${RESET}"; }

# 信息 / 警告 / 错误
info()  { echo -e "${GREEN}[*]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
err()   { echo -e "${RED}[x]${RESET} $*"; }

# 执行命令前回显，便于学习
run() {
    echo -e "${BLUE}\$ $*${RESET}"
    "$@"
}

# 等待用户回车后返回菜单
pause() {
    echo
    read -rp "${YELLOW}按回车键返回菜单...${RESET}" _
}

# 检测包管理器
detect_pkg() {
    if has apt-get;      then PKG="apt";    fi
    if has dnf;          then PKG="dnf";    fi
    if has yum;          then PKG="yum";    fi
    if has apk;          then PKG="apk";    fi
    if has pacman;       then PKG="pacman"; fi
    PKG="${PKG:-unknown}"
}
detect_pkg

# 检测 init 系统：systemd / openrc(Alpine) / 传统 service
detect_init() {
    if has systemctl && [ -d /run/systemd/system ]; then INIT="systemd"
    elif has rc-service; then INIT="openrc"
    elif has service;    then INIT="service"
    else INIT="unknown"; fi
}
detect_init

# ---------------------------------------------------------------------------
# 兼容性辅助函数（兼容 BusyBox / Alpine）
# ---------------------------------------------------------------------------
# 内存信息：BusyBox 的 free 可能不支持 -h
mem_info() { free -h 2>/dev/null || free -m 2>/dev/null || free; }

# 磁盘信息：BusyBox 的 df 不支持 -T
disk_info() { df -hT 2>/dev/null || df -h; }

# 本机地址：BusyBox 的 ip 不支持 -brief
ip_addr() { ip -brief addr 2>/dev/null || ip addr 2>/dev/null || ifconfig; }

# 全部进程：兼容 procps 与 BusyBox 两种 ps
ps_all() { ps -ef 2>/dev/null || ps aux 2>/dev/null || ps; }

# CPU/内存占用最高的进程（仅在 procps 版 ps 可用时调用）
top_proc() {  # $1=cpu|mem
    ps -eo pid,comm,%cpu,%mem --sort=-"%${1}" | head -n 6
}

# 是否为 Alpine 系统
if [ -f /etc/alpine-release ]; then IS_ALPINE=1; else IS_ALPINE=0; fi

# 检查命令是否存在（用于可选的 setup 向导）
need() { has "$1" || { err "未找到 $1（可尝试: $SUDO apk add alpine-conf）"; return 1; }; }

# ---------------------------------------------------------------------------
# 1. 系统信息
# ---------------------------------------------------------------------------
system_info() {
    title "系统信息"
    if has hostnamectl; then run hostnamectl; else run uname -a; fi
    echo
    if [[ -f /etc/os-release ]]; then
        info "发行版:"; grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release
    fi
    echo
    info "内核版本:";   run uname -r
    info "运行时间:";   run uptime -p 2>/dev/null || run uptime
    info "CPU 型号:";   grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //'
    info "CPU 核心数:"; nproc
    pause
}

# ---------------------------------------------------------------------------
# 2. 资源监控（CPU / 内存 / 负载）
# ---------------------------------------------------------------------------
resource_monitor() {
    title "资源监控"
    info "内存使用:"; run mem_info
    echo
    info "系统负载:"; run uptime
    echo
    if ps -eo pid,comm,%cpu,%mem --sort=-%cpu >/dev/null 2>&1; then
        info "占用 CPU 最高的进程:"; top_proc cpu
        echo
        info "占用内存最高的进程:"; top_proc mem
    else
        # BusyBox top 仅能按 CPU 排序，显示一次概览即可
        info "进程概览 (BusyBox top):"; top -bn1 2>/dev/null | head -n 12 || ps
    fi
    pause
}

# ---------------------------------------------------------------------------
# 3. 网络管理
# ---------------------------------------------------------------------------
network_menu() {
    while true; do
        title "网络管理"
        cat <<EOF
  1) 查看本机 IP（内网）
  2) 查看公网 IP
  3) 查看监听端口
  4) 查看当前连接数
  5) 测试连通性 (ping)
  0) 返回主菜单
EOF
        read -rp "请选择: " n
        case "$n" in
            1) title "内网 IP"; run ip_addr; pause ;;
            2) title "公网 IP"
               if has curl; then run curl -s https://api.ipify.org; echo
               elif has wget; then run wget -qO- https://api.ipify.org; echo
               else warn "未安装 curl/wget"; fi; pause ;;
            3) title "监听端口"
               if has ss; then run $SUDO ss -tulnp
               else run $SUDO netstat -tulnp; fi; pause ;;
            4) title "连接数统计"
               if has ss; then run bash -c "ss -s"; else run bash -c "netstat -an | wc -l"; fi; pause ;;
            5) read -rp "要 ping 的地址 (默认 8.8.8.8): " host
               host="${host:-8.8.8.8}"; run ping -c 4 "$host"; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 4. 磁盘管理
# ---------------------------------------------------------------------------
disk_menu() {
    title "磁盘管理"
    info "磁盘空间:"; run disk_info
    echo
    info "当前目录下占用前 10:"
    du -sh ./* 2>/dev/null | { sort -rh 2>/dev/null || sort -r; } | head -n 10
    echo
    if has lsblk; then info "块设备:"; run lsblk; fi
    pause
}

# ---------------------------------------------------------------------------
# 5. 进程管理
# ---------------------------------------------------------------------------
process_menu() {
    while true; do
        title "进程管理"
        cat <<EOF
  1) 实时监控 (top)
  2) 按名称查找进程
  3) 结束指定 PID
  0) 返回主菜单
EOF
        read -rp "请选择: " p
        case "$p" in
            1) if has htop; then run htop; else run top; fi ;;
            2) read -rp "进程名关键字: " kw
               if [[ -n "$kw" ]]; then
                   echo -e "${BLUE}\$ ps | grep -i '$kw'${RESET}"
                   ps_all | grep -i --color=auto "$kw" | grep -v grep
               fi; pause ;;
            3) read -rp "要结束的 PID: " pid
               if [[ "$pid" =~ ^[0-9]+$ ]]; then
                   run $SUDO kill -15 "$pid" || run $SUDO kill -9 "$pid"
               else err "PID 必须是数字"; fi; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 6. 服务管理 (systemd)
# ---------------------------------------------------------------------------
# 服务操作分发：屏蔽 systemd / openrc / service 差异
svc_action() {  # $1=动作 $2=服务名
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
        service)
            case "$act" in
                enable|disable) warn "传统 service 模式不支持自启，请用 chkconfig / update-rc.d"; return 1 ;;
                *)       run $SUDO service "$svc" "$act" ;;
            esac ;;
    esac
}

service_menu() {
    if [ "$INIT" = "unknown" ]; then warn "未识别的 init 系统，无法管理服务"; pause; return; fi
    read -rp "服务名 (如 nginx、sshd): " svc
    [[ -z "$svc" ]] && { err "服务名不能为空"; pause; return; }
    while true; do
        title "服务管理: $svc  [init: $INIT]"
        cat <<EOF
  1) 查看状态    2) 启动    3) 停止
  4) 重启        5) 开机自启    6) 取消自启
  0) 返回主菜单
EOF
        read -rp "请选择: " s
        case "$s" in
            1) svc_action status  "$svc"; pause ;;
            2) svc_action start   "$svc" && info "已启动"; pause ;;
            3) svc_action stop    "$svc" && info "已停止"; pause ;;
            4) svc_action restart "$svc" && info "已重启"; pause ;;
            5) svc_action enable  "$svc" && info "已设为开机自启"; pause ;;
            6) svc_action disable "$svc" && info "已取消开机自启"; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 7. 用户管理
# ---------------------------------------------------------------------------
user_menu() {
    title "用户管理"
    info "当前登录用户:"; run who
    echo
    info "普通用户列表 (UID>=1000):"
    awk -F: '$3>=1000 && $3<65534 {print $1" (uid="$3")"}' /etc/passwd
    pause
}

# ---------------------------------------------------------------------------
# 8. 防火墙管理
# ---------------------------------------------------------------------------
firewall_menu() {
    title "防火墙管理"
    if has ufw; then
        info "UFW 状态:"; run $SUDO ufw status verbose
        echo; warn "如需放行端口: sudo ufw allow <端口>/tcp"
    elif has firewall-cmd; then
        info "firewalld 状态:"; run $SUDO firewall-cmd --list-all
        echo; warn "如需放行端口: sudo firewall-cmd --add-port=<端口>/tcp --permanent && sudo firewall-cmd --reload"
    else
        info "iptables 规则:"; run $SUDO iptables -L -n -v
    fi
    pause
}

# ---------------------------------------------------------------------------
# 9. 系统更新
# ---------------------------------------------------------------------------
system_update() {
    title "系统更新 (包管理器: $PKG)"
    case "$PKG" in
        apt)    run $SUDO apt-get update && run $SUDO apt-get upgrade -y ;;
        dnf)    run $SUDO dnf upgrade -y ;;
        yum)    run $SUDO yum update -y ;;
        apk)    run $SUDO apk update && run $SUDO apk upgrade ;;
        pacman) run $SUDO pacman -Syu --noconfirm ;;
        *)      err "未识别的包管理器，无法自动更新" ;;
    esac
    pause
}

# ---------------------------------------------------------------------------
# A. Alpine 专属工具
# ---------------------------------------------------------------------------
# apk 包管理
apk_menu() {
    while true; do
        title "apk 包管理"
        cat <<EOF
  1) 更新软件索引 (apk update)
  2) 升级所有软件 (apk upgrade)
  3) 安装软件
  4) 卸载软件
  5) 搜索软件
  6) 查看已安装列表
  7) 一键安装常用工具
  0) 返回
EOF
        read -rp "请选择: " p
        case "$p" in
            1) run $SUDO apk update; pause ;;
            2) run $SUDO apk upgrade; pause ;;
            3) read -rp "要安装的包名(空格分隔): " pkgs
               [[ -n "$pkgs" ]] && run $SUDO apk add $pkgs; pause ;;
            4) read -rp "要卸载的包名(空格分隔): " pkgs
               [[ -n "$pkgs" ]] && run $SUDO apk del $pkgs; pause ;;
            5) read -rp "搜索关键字: " kw
               [[ -n "$kw" ]] && run apk search "$kw"; pause ;;
            6) run apk info; pause ;;
            7) local tools="bash curl wget vim nano htop git iproute2 iptables tzdata bash-completion"
               info "将安装: $tools"
               read -rp "确认安装? [y/N] " yn
               case "$yn" in [yY]*) run $SUDO apk add $tools ;; *) warn "已取消" ;; esac
               pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

# OpenRC 服务清单
openrc_list() {
    title "OpenRC 服务清单"
    if ! has rc-status; then warn "未安装 OpenRC（rc-status 不存在）"; pause; return; fi
    info "各运行级别的服务及状态 (rc-status --all):"
    run $SUDO rc-status --all
    echo
    info "已设为开机自启的服务 (rc-update show):"
    run $SUDO rc-update show
    pause
}

# setup-* 配置向导
setup_menu() {
    while true; do
        title "Alpine 配置向导 (setup-*)"
        warn "以下为官方交互式向导，按提示操作，Ctrl+C 可中途取消"
        cat <<EOF
  1) setup-sshd       配置 SSH 服务
  2) setup-timezone   配置时区
  3) setup-ntp        配置时间同步
  4) setup-hostname   配置主机名
  5) setup-apkrepos   配置软件源(镜像)
  6) setup-interfaces 配置网络接口
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
    if [[ "$IS_ALPINE" != 1 ]]; then warn "当前不是 Alpine 系统，此菜单不可用"; pause; return; fi
    while true; do
        title "Alpine 专属工具"
        cat <<EOF
  1) apk 包管理
  2) OpenRC 服务清单
  3) setup-* 配置向导
  0) 返回主菜单
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
# T. 进阶工具（SSH 加固 / Swap / BBR / Docker）—— 跨发行版通用
# ---------------------------------------------------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"

# 重启 SSH 服务（兼容不同服务名与 init）
ssh_restart() {
    case "$INIT" in
        systemd) run $SUDO systemctl restart sshd 2>/dev/null || run $SUDO systemctl restart ssh ;;
        openrc)  run $SUDO rc-service sshd restart ;;
        *)       run $SUDO service sshd restart 2>/dev/null || run $SUDO service ssh restart ;;
    esac
}

# 设置一个 sshd 配置项：备份 → 去重 → 追加 → 校验，失败回滚
set_sshd_option() {  # $1=配置项 $2=值
    local key="$1" val="$2" bak
    [[ -f "$SSHD_CONFIG" ]] || { err "未找到 $SSHD_CONFIG"; return 1; }
    bak="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    run $SUDO cp "$SSHD_CONFIG" "$bak" && info "已备份到 $bak"
    $SUDO sed -i -E "/^[#[:space:]]*${key}[[:space:]]/d" "$SSHD_CONFIG"
    echo "$key $val" | $SUDO tee -a "$SSHD_CONFIG" >/dev/null
    info "已写入: ${key} ${val}"
    if $SUDO sshd -t 2>/dev/null; then
        info "sshd 配置校验通过"
        return 0
    else
        err "sshd 配置校验失败，已回滚！"
        $SUDO cp "$bak" "$SSHD_CONFIG"
        return 1
    fi
}

ssh_menu() {
    while true; do
        title "SSH 安全加固"
        warn "操作前请确保另开一个 SSH 会话，避免被锁在外面"
        cat <<EOF
  1) 修改 SSH 端口
  2) 禁止 root 密码登录 (仅允许密钥)
  3) 完全禁用密码登录 (仅密钥)
  4) 添加公钥到 authorized_keys
  5) 查看当前 SSH 关键配置
  0) 返回
EOF
        read -rp "请选择: " s
        case "$s" in
            1) read -rp "新端口 (1-65535): " port
               if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                   if set_sshd_option Port "$port"; then
                       warn "请先放行新端口再重启! 例: ufw allow ${port}/tcp 或 firewall-cmd --add-port=${port}/tcp --permanent"
                       warn "CentOS 若开启 SELinux: semanage port -a -t ssh_port_t -p tcp ${port}"
                       read -rp "现在重启 SSH 使其生效? [y/N] " yn
                       case "$yn" in [yY]*) ssh_restart ;; *) warn "未重启，稍后手动重启生效" ;; esac
                   fi
               else err "端口无效"; fi; pause ;;
            2) if set_sshd_option PermitRootLogin prohibit-password; then
                   read -rp "重启 SSH 生效? [y/N] " yn; case "$yn" in [yY]*) ssh_restart ;; esac
               fi; pause ;;
            3) warn "确认你已能用密钥登录，否则将无法再用密码进入!"
               read -rp "确定要禁用密码登录? 输入 yes 继续: " c
               if [ "$c" = "yes" ]; then
                   if set_sshd_option PasswordAuthentication no; then
                       read -rp "重启 SSH 生效? [y/N] " yn; case "$yn" in [yY]*) ssh_restart ;; esac
                   fi
               else warn "已取消"; fi; pause ;;
            4) read -rp "粘贴公钥 (ssh-ed25519/ssh-rsa 开头): " pubkey
               if [[ "$pubkey" =~ ^(ssh-|ecdsa-) ]]; then
                   mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
                   echo "$pubkey" >> "$HOME/.ssh/authorized_keys"
                   chmod 600 "$HOME/.ssh/authorized_keys"
                   info "已添加到 $HOME/.ssh/authorized_keys"
               else err "公钥格式不正确"; fi; pause ;;
            5) title "当前 SSH 关键配置 ($SSHD_CONFIG)"
               grep -Ei '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' "$SSHD_CONFIG" 2>/dev/null || warn "未读取到显式配置(使用默认值)"
               pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

swap_menu() {
    while true; do
        title "Swap 虚拟内存管理"
        info "当前 Swap:"; swapon --show 2>/dev/null || cat /proc/swaps 2>/dev/null; echo
        cat <<EOF
  1) 创建 Swap 文件
  2) 删除 Swap 文件
  0) 返回
EOF
        read -rp "请选择: " s
        local file="/swapfile"
        case "$s" in
            1) if [ -e "$file" ]; then warn "$file 已存在"; pause; continue; fi
               read -rp "Swap 大小 (GB, 默认 1): " sz; sz="${sz:-1}"
               [[ "$sz" =~ ^[0-9]+$ ]] || { err "请输入整数"; pause; continue; }
               if has fallocate; then run $SUDO fallocate -l "${sz}G" "$file"; fi
               if [ ! -s "$file" ]; then
                   info "使用 dd 创建(较慢)..."
                   run $SUDO dd if=/dev/zero of="$file" bs=1M count=$((sz*1024))
               fi
               run $SUDO chmod 600 "$file"
               run $SUDO mkswap "$file" && run $SUDO swapon "$file" || { err "启用失败"; pause; continue; }
               if ! grep -q "^${file} " /etc/fstab 2>/dev/null; then
                   echo "$file none swap sw 0 0" | $SUDO tee -a /etc/fstab >/dev/null
                   info "已写入 /etc/fstab (开机自动挂载)"
               fi
               info "完成"; run free -h 2>/dev/null || free -m; pause ;;
            2) if [ ! -e "$file" ]; then warn "$file 不存在"; pause; continue; fi
               run $SUDO swapoff "$file" 2>/dev/null
               $SUDO sed -i "\#^${file} #d" /etc/fstab 2>/dev/null
               run $SUDO rm -f "$file"
               info "已删除 $file 并清理 fstab"; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

bbr_menu() {
    local conf="/etc/sysctl.d/99-bbr.conf"
    while true; do
        title "BBR 拥塞控制加速"
        cat <<EOF
  1) 开启 BBR
  2) 查看 BBR 状态
  0) 返回
EOF
        read -rp "请选择: " s
        case "$s" in
            1) $SUDO modprobe tcp_bbr 2>/dev/null
               printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' | $SUDO tee "$conf" >/dev/null
               info "已写入 $conf"
               $SUDO sysctl --system >/dev/null 2>&1 || $SUDO sysctl -p "$conf" >/dev/null 2>&1
               local cur; cur="$($SUDO sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
               if [ "$cur" = "bbr" ]; then info "BBR 已开启 (当前算法: $cur)"
               else warn "当前算法: ${cur:-未知}。若内核 <4.9 或无 tcp_bbr 模块则不支持"; fi
               pause ;;
            2) title "BBR 状态"
               info "当前算法:";   $SUDO sysctl net.ipv4.tcp_congestion_control 2>/dev/null
               info "可用算法:";   $SUDO sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null
               info "bbr 模块:";   lsmod 2>/dev/null | grep -i bbr || echo "(未加载，可能已编译进内核)"
               pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

docker_menu() {
    while true; do
        title "Docker 安装与管理"
        if has docker; then info "Docker 已安装: $(docker --version 2>/dev/null)"; else warn "尚未安装 Docker"; fi
        cat <<EOF
  1) 安装 Docker
  2) 启动 / 查看 Docker 服务
  3) 查看容器 (docker ps -a)
  4) 查看镜像 (docker images)
  0) 返回
EOF
        read -rp "请选择: " s
        case "$s" in
            1) if has docker; then info "已安装，无需重复"; pause; continue; fi
               if [ "$PKG" = "apk" ]; then
                   run $SUDO apk add --no-cache docker docker-cli-compose
                   [ "$INIT" = "openrc" ] && { run $SUDO rc-update add docker default; run $SUDO rc-service docker start; }
               else
                   warn "将执行官方安装脚本: curl -fsSL https://get.docker.com | sh"
                   read -rp "确认从 get.docker.com 安装? [y/N] " yn
                   case "$yn" in
                       [yY]*) if has curl; then run bash -c "curl -fsSL https://get.docker.com | $SUDO sh"
                              elif has wget; then run bash -c "wget -qO- https://get.docker.com | $SUDO sh"
                              else err "需要 curl 或 wget"; fi
                              [ "$INIT" = "systemd" ] && run $SUDO systemctl enable --now docker ;;
                       *) warn "已取消" ;;
                   esac
               fi; pause ;;
            2) svc_action status docker || svc_action start docker; pause ;;
            3) has docker && run $SUDO docker ps -a || err "Docker 未安装"; pause ;;
            4) has docker && run $SUDO docker images || err "Docker 未安装"; pause ;;
            0) break ;;
            *) err "无效选择" ;;
        esac
    done
}

advanced_menu() {
    while true; do
        title "进阶工具"
        cat <<EOF
  1) SSH 安全加固
  2) Swap 虚拟内存
  3) BBR 加速
  4) Docker 安装与管理
  0) 返回主菜单
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
        echo -e "${BOLD}${CYAN}"
        echo "  ┌────────────────────────────────────┐"
        echo "  │        VPS 常用命令工具箱           │"
        echo "  └────────────────────────────────────┘"
        echo -e "${RESET}"
        [[ -n "$SUDO" ]] && warn "当前非 root，特权命令将使用 sudo"
        cat <<EOF
   ${GREEN}1)${RESET} 系统信息          ${GREEN}2)${RESET} 资源监控
   ${GREEN}3)${RESET} 网络管理          ${GREEN}4)${RESET} 磁盘管理
   ${GREEN}5)${RESET} 进程管理          ${GREEN}6)${RESET} 服务管理
   ${GREEN}7)${RESET} 用户管理          ${GREEN}8)${RESET} 防火墙管理
   ${GREEN}9)${RESET} 系统更新          ${GREEN}0)${RESET} 退出
EOF
        echo -e "   ${GREEN}t)${RESET} 进阶工具 ${CYAN}(SSH加固 / Swap / BBR / Docker)${RESET}"
        [[ "$IS_ALPINE" == 1 ]] && echo -e "   ${GREEN}a)${RESET} Alpine 专属工具 ${CYAN}(apk / OpenRC / setup)${RESET}"
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
            *) err "无效选项，请重新输入"; sleep 1 ;;
        esac
    done
}

main_menu
