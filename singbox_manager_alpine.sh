#!/bin/bash
# sing-box 全能管理脚本 v2.1 (Alpine Linux 专用)
# 功能：服务管理 / 配置工具 / 密钥生成 / 一键安装卸载 / 自动升级

set -euo pipefail

# ================= 配置区 =================
SINGBOX_BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box"
DEFAULT_CONFIG="/etc/sing-box/config.json"
SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
LOG_DIR="/var/log/sing-box"
# ==========================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# 基础检查
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_err "请使用 root 权限运行此脚本！"
        exit 1
    fi
}

check_bin() {
    if ! command -v sing-box &> /dev/null; then
        print_err "未检测到 sing-box 程序，请先选择 13 安装。"
        return 1
    fi
}

get_config_path() {
    local cfg=""
    if [[ -f "$DEFAULT_CONFIG" ]]; then
        cfg="$DEFAULT_CONFIG"
    fi
    [[ -z "$cfg" ]] && cfg=$(find /etc/sing-box /usr/local/etc/sing-box -name "*.json" 2>/dev/null | head -n1 || true)
    echo "$cfg"
}

# ================= 服务管理 =================
show_status() {
    check_bin || return
    rc-service "$SERVICE_NAME" status 2>/dev/null || echo "  服务未运行"
    echo ""
    sing-box version 2>/dev/null || true
}

start_service() {
    check_bin || return
    rc-service "$SERVICE_NAME" start && print_ok "服务已启动" || print_err "启动失败"
}

stop_service() {
    rc-service "$SERVICE_NAME" stop 2>/dev/null && print_ok "服务已停止" || print_warn "服务可能未安装"
}

restart_service() {
    check_bin || return
    rc-service "$SERVICE_NAME" restart && print_ok "服务已重启" || print_err "重启失败"
}

enable_autostart() {
    rc-update add "$SERVICE_NAME" default && print_ok "已启用自启" || print_err "启用失败"
}

disable_autostart() {
    rc-update del "$SERVICE_NAME" default && print_ok "已取消自启" || print_err "取消失败"
}

view_logs() {
    local log_files=()
    [[ -f "${LOG_DIR}/error.log" ]] && log_files+=("${LOG_DIR}/error.log")
    [[ -f "${LOG_DIR}/access.log" ]] && log_files+=("${LOG_DIR}/access.log")
    if [[ ${#log_files[@]} -eq 0 ]]; then
        print_warn "暂无日志文件"
        return
    fi
    print_info "显示最近 50 条日志 (按回车键退出):"
    tail -n 50 -f "${log_files[@]}" 2>/dev/null &
    local pid=$!
    read -r
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

# ================= 配置工具 =================
view_config() {
    check_bin || return
    local cfg=$(get_config_path)
    [[ -n "$cfg" ]] && [[ -f "$cfg" ]] || { print_err "未找到配置文件"; return; }
    print_info "配置文件: $cfg"
    echo "-----------------------------"
    cat "$cfg"
    echo "-----------------------------"
}

format_config() {
    check_bin || return
    local cfg=$(get_config_path)
    [[ -n "$cfg" ]] && [[ -f "$cfg" ]] || { print_err "未找到配置文件"; return; }
    print_info "格式化: $cfg"
    sing-box format -w -c "$cfg" && print_ok "格式化完成" || print_err "失败"
}

# ================= 密钥生成 =================
gen_uuid() {
    check_bin || return
    local uuid=$(sing-box generate uuid 2>/dev/null)
    print_ok "生成的 UUID: $uuid"
}

gen_reality_key() {
    check_bin || return
    print_warn "生成 Reality 密钥对..."
    local output=$(sing-box generate reality-keypair 2>/dev/null)
    echo "-----------------------------"
    echo "$output"
    echo "-----------------------------"
    print_info "请将 'PrivateKey' 填入服务端，'PublicKey' 填入客户端"
}

gen_aes() {
    check_bin || return
    print_info "请选择加密算法:"
    echo " 1) 2022-blake3-aes-128-gcm (需 16 字节密钥)"
    echo " 2) 2022-blake3-aes-256-gcm (需 32 字节密钥)"
    read -p "请选择 [1-2, 默认 1]: " choice
    local len=16
    [[ "$choice" == "2" ]] && len=32
    
    print_warn "正在生成 $len 字节 (对应 $((len*8))位) 密钥..."
    local output=$(sing-box generate rand --base64 "$len" 2>/dev/null)
    echo "-----------------------------"
    echo "$output"
    echo "-----------------------------"
}

# ================= 安装与卸载 =================
install_singbox() {
    command -v sing-box &>/dev/null && { print_warn "sing-box 已安装，请使用升级选项 (15)"; return; }
    print_info "正在获取最新版本..."
    local latest=$(curl -s --connect-timeout 10 --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": *"[^"]*"' | grep -o '[0-9.]*')
    [[ -z "$latest" ]] && { print_err "无法获取版本信息"; return; }
    
    print_info "最新版本: $latest，正在下载..."
    local arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) print_err "不支持的架构: $arch"; return ;;
    esac
    
    # Alpine 必须用 musl 版本
    local url="https://github.com/SagerNet/sing-box/releases/download/v${latest}/sing-box-${latest}-linux-${arch}-musl.tar.gz"
    if ! curl -sfL --connect-timeout 15 --max-time 60 -o /tmp/sing-box.tar.gz "$url"; then
        print_err "下载失败，请检查网络或版本可用性"
        return
    fi

    print_info "正在安装..."
    mkdir -p /tmp/sb-install
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/sb-install --strip-components=1
    cp /tmp/sb-install/sing-box "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf /tmp/sing-box.tar.gz /tmp/sb-install
    
    print_info "正在注册系统服务..."
    mkdir -p "$LOG_DIR"
    cat > "$SERVICE_FILE" << 'EOF'
#!/sbin/openrc-run

name="sing-box"
description="sing-box proxy service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box/access.log"
error_log="/var/log/sing-box/error.log"
retry="SIGTERM/5/SIGKILL/5"

start_pre() {
    [ -f /etc/sing-box/config.json ] || { eerror "Config file not found: /etc/sing-box/config.json"; return 1; }
    /usr/local/bin/sing-box check -c /etc/sing-box/config.json || { eerror "Config check failed"; return 1; }
}
EOF
    chmod +x "$SERVICE_FILE"
    mkdir -p /etc/sing-box
    
    print_ok "安装成功！版本: $(sing-box version | head -1)"
    print_info "请将配置文件放入 /etc/sing-box/config.json 然后启动服务"
}

uninstall_singbox() {
    read -p "确定要卸载 sing-box 吗？所有配置和数据将被删除！(y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    print_info "正在停止服务..."
    rc-service "$SERVICE_NAME" stop 2>/dev/null || true
    pkill -9 sing-box 2>/dev/null || true
    rc-update del "$SERVICE_NAME" default 2>/dev/null || true

    print_info "正在删除文件..."
    rm -f "$SINGBOX_BIN"
    rm -f "$SERVICE_FILE"
    
    print_info "正在清理配置、数据和日志目录..."
    rm -rf /etc/sing-box/
    rm -rf /var/lib/sing-box/
    rm -rf "$LOG_DIR"
    
    print_ok "卸载完成！"
}

# ================= 升级管理 =================

upgrade_singbox() {
    check_bin || return
    print_info "检查新版本..."
    local latest=$(curl -s --connect-timeout 10 --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": *"[^"]*"' | grep -o '[0-9.]*')
    local current=$(sing-box version | head -1 | grep -o '[0-9.]*' | head -1)
    
    [[ -z "$latest" ]] && { print_err "网络错误"; return; }
    echo "当前: $current | 最新: $latest"
    [[ "$current" == "$latest" ]] && { print_ok "已是最新版"; return; }

    read -p "是否升级? (y/n): " -r
    [[ $REPLY =~ ^[Yy]$ ]] || return
    
    local arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) print_err "不支持的架构: $arch"; return ;;
    esac
    # Alpine 必须用 musl 版本
    local url="https://github.com/SagerNet/sing-box/releases/download/v${latest}/sing-box-${latest}-linux-${arch}-musl.tar.gz"
    
    if ! curl -sfL --connect-timeout 15 --max-time 60 -o /tmp/sing-box.tar.gz "$url"; then
        print_err "下载失败，请检查网络或版本可用性"
        return
    fi
    mkdir -p /tmp/sb-upgrade
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/sb-upgrade --strip-components=1

    # 覆盖前自动备份旧版本（验证失败可回滚）
    [[ -f "$SINGBOX_BIN" ]] && cp "$SINGBOX_BIN" "${SINGBOX_BIN}.bak"

    cp /tmp/sb-upgrade/sing-box "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"

    if ! sing-box version &>/dev/null; then
        print_err "升级后二进制验证失败，正在恢复旧版本..."
        [[ -f "${SINGBOX_BIN}.bak" ]] && mv "${SINGBOX_BIN}.bak" "$SINGBOX_BIN"
        rm -rf /tmp/sing-box.tar.gz /tmp/sb-upgrade
        return
    fi

    # 验证通过，清理备份和临时文件
    rm -f "${SINGBOX_BIN}.bak"
    rm -rf /tmp/sing-box.tar.gz /tmp/sb-upgrade
    print_ok "升级成功！版本: $(sing-box version | head -1)"
    print_info "请手动重启服务以生效: rc-service sing-box restart"
}

# ================= 菜单 =================
menu() {
    echo ""
    echo -e "${BLUE}=== sing-box 管理脚本 (Alpine) ===${NC}"
    echo ""
    echo -e "${GREEN}[服务管理]${NC}"
    echo " 1. 启动"
    echo " 2. 停止"
    echo " 3. 重启"
    echo " 4. 查看状态"
    echo " 5. 查看日志"
    echo " 6. 设置开机自启"
    echo " 7. 取消开机自启"
    echo ""
    echo -e "${GREEN}[配置工具]${NC}"
    echo " 8.  查看配置"
    echo " 9.  格式化配置"
    echo ""
    echo -e "${GREEN}[密钥生成]${NC}"
    echo " 10. 生成 UUID"
    echo " 11. 生成 AES 密钥"
    echo " 12. 生成 Reality 密钥"
    echo ""
    echo -e "${GREEN}[安装服务]${NC}"
    echo " 13. 安装 sing-box"
    echo " 14. 卸载 sing-box"
    echo " 15. 升级 sing-box"
    echo ""
    echo " 0. 退出"
    echo ""
    echo -e "${BLUE}==================================${NC}"
    read -p "请选择: " choice

    case $choice in
        1) start_service ;; 2) stop_service ;; 3) restart_service ;; 4) show_status ;;
        5) view_logs ;; 6) enable_autostart ;; 7) disable_autostart ;;
        8) view_config ;; 9) format_config ;;
        10) gen_uuid ;; 11) gen_aes ;; 12) gen_reality_key ;;
        13) install_singbox ;; 14) uninstall_singbox ;;
        15) upgrade_singbox ;;
        0) exit 0 ;; *) print_err "无效选项" ;;
    esac
}

main() {
    check_root
    while true; do menu; read -n 1 -s -r -p "按回车继续..."; done
}

main