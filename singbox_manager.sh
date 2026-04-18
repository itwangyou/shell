#!/bin/bash
# sing-box 全能管理脚本
# 功能：服务管理 / 配置工具 / 密钥生成 / 数据库管理 / 自动升级

set -euo pipefail

# ================= 配置区 =================
SINGBOX_BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box"
DEFAULT_CONFIG="/etc/sing-box/config.json"
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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_err "请使用 root 权限运行此脚本！"
        exit 1
    fi
}

check_install() {
    if ! command -v sing-box &> /dev/null; then
        print_err "sing-box 未安装！"
        exit 1
    fi
}

get_config_path() {
    local cfg=""
    if systemctl cat "$SERVICE_NAME" &>/dev/null; then
        cfg=$(systemctl cat "$SERVICE_NAME" 2>/dev/null | grep -oE '\-c\s+[^ ]+' | tail -n1 | awk '{print $NF}' || true)
    fi
    if [[ -z "$cfg" ]] && [[ -f "$DEFAULT_CONFIG" ]]; then
        cfg="$DEFAULT_CONFIG"
    fi
    if [[ -z "$cfg" ]]; then
        cfg=$(find /etc/sing-box /usr/local/etc/sing-box -name "*.json" 2>/dev/null | head -n1 || true)
    fi
    echo "$cfg"
}

# ================= 服务管理 =================
show_status() {
    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || echo "  服务未运行"
    echo ""
    sing-box version 2>/dev/null || true
}

start_service() {
    systemctl start "$SERVICE_NAME" && print_ok "服务已启动" || print_err "启动失败"
}

stop_service() {
    systemctl stop "$SERVICE_NAME" && print_ok "服务已停止" || print_err "停止失败"
}

restart_service() {
    systemctl restart "$SERVICE_NAME" && print_ok "服务已重启" || print_err "重启失败"
}

enable_autostart() { systemctl enable "$SERVICE_NAME" && print_ok "已启用自启"; }
disable_autostart() { systemctl disable "$SERVICE_NAME" && print_ok "已取消自启"; }

view_logs() {
    print_info "显示最近 50 条日志 (Ctrl+C 退出实时模式):"
    journalctl -u "$SERVICE_NAME" --no-pager -n 50 -f 2>/dev/null || print_err "无日志"
}

# ================= 配置工具 =================
check_config() {
    local cfg=$(get_config_path)
    [[ -n "$cfg" ]] && [[ -f "$cfg" ]] || { print_err "未找到配置"; return; }
    print_info "检查配置: $cfg"
    sing-box check -c "$cfg" && print_ok "配置正确" || print_err "配置有误"
}

format_config() {
    local cfg=$(get_config_path)
    [[ -n "$cfg" ]] && [[ -f "$cfg" ]] || { print_err "未找到配置"; return; }
    print_info "格式化: $cfg"
    sing-box format -w -c "$cfg" && print_ok "格式化完成" || print_err "失败"
}

merge_configs() {
    print_info "请输入要合并的配置文件路径（空格分隔，按回车结束）："
    read -r files
    [[ -n "$files" ]] || return
    print_info "执行合并..."
    local args=()
    for f in $files; do args+=("-c" "$f"); done
    sing-box merge /tmp/merged_config.json "${args[@]}" && print_ok "已合并到 /tmp/merged_config.json" || print_err "合并失败"
}

# ================= 生成密钥 =================
gen_uuid() {
    local uuid=$(sing-box generate uuid 2>/dev/null)
    print_ok "生成的 UUID: $uuid"
    echo "$uuid" | xclip -selection clipboard 2>/dev/null && print_info "已复制到剪贴板 (xclip)" || true
}

gen_reality_key() {
    print_warn "生成 Reality 密钥对..."
    local output=$(sing-box generate reality-keypair 2>/dev/null)
    echo "-----------------------------"
    echo "$output"
    echo "-----------------------------"
    print_info "请将 'PrivateKey' 填入你的入站配置，'PublicKey' 分享给客户端"
}

gen_aes() {
    print_info "请选择加密算法:"
    echo " 1) 2022-blake3-aes-128-gcm (需 16 字节密钥)"
    echo " 2) 2022-blake3-aes-256-gcm (需 32 字节密钥)"
    read -p "请选择 [1-2, 默认 2]: " choice
    local len=32
    [[ "$choice" == "1" ]] && len=16
    
    print_warn "正在生成 $len 字节 (对应 $((len*8))位) 密钥..."
    local output=$(sing-box generate rand --base64 "$len" 2>/dev/null)
    echo "-----------------------------"
    echo "$output"
    echo "-----------------------------"
}

# ================= 数据库与升级 =================
manage_geoip() {
    print_info "当前 GeoIP 状态:"
    sing-box geoip --help 2>/dev/null | head -n 5
    print_info "下载最新版 GeoIP 数据库..."
    sing-box geoip download -o /var/lib/sing-box/geoip.db 2>/dev/null && print_ok "下载成功" || print_err "下载失败 (请检查权限)"
}

manage_geosite() {
    print_info "当前 GeoSite 状态:"
    sing-box geosite --help 2>/dev/null | head -n 5
    print_info "下载最新版 GeoSite 数据库..."
    sing-box geosite download -o /var/lib/sing-box/geosite.db 2>/dev/null && print_ok "下载成功" || print_err "下载失败 (请检查权限)"
}

upgrade_singbox() {
    check_install
    print_info "检查新版本..."
    local latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": *"[^"]*"' | grep -o '[0-9.]*')
    local current=$(sing-box version | head -1 | grep -o '[0-9.]*' | head -1)
    
    [[ -z "$latest" ]] && { print_err "网络错误"; return; }

    echo "当前: $current | 最新: $latest"
    [[ "$current" == "$latest" ]] && { print_ok "已是最新版"; return; }

    read -p "是否升级? (y/n): " -r
    [[ $REPLY =~ ^[Yy]$ ]] || return

    local arch=$(uname -m)
    [[ "$arch" == "x86_64" ]] && arch="amd64" || [[ "$arch" == "aarch64" ]] && arch="arm64"

    local filename="sing-box-${latest}-linux-${arch}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${latest}/${filename}"
    
    curl -L -o "/tmp/$filename" "$url"
    tar -xzf "/tmp/$filename" -C /tmp
    cp "/tmp/sing-box-${latest}-linux-${arch}/sing-box" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf "/tmp/$filename" "/tmp/sing-box-${latest}-linux-${arch}"
    print_ok "升级成功！重启服务以生效"
}

# ================= 菜单 =================
menu() {
    echo ""
    echo -e "${BLUE}=== sing-box 全能管理 ===${NC}"
    echo -e "${GREEN}[服务管理]${NC}"
    echo " 1. 启动     2. 停止     3. 重启     4. 查看状态"
    echo " 5. 查看日志     6. 设置自启     7. 取消自启"
    echo -e "${GREEN}[配置工具]${NC}"
    echo " 8. 检查配置 9. 格式化配置 10. 合并配置"
    echo -e "${GREEN}[密钥生成]${NC}"
    echo " 11. 生成 UUID   12. 生成 Reality 密钥   13. 生成 AES 密钥"
    echo -e "${GREEN}[数据库/升级]${NC}"
    echo " 14. 更新 GeoIP  15. 更新 GeoSite"
    echo " 16. 升级 sing-box   0. 退出"
    echo -e "${BLUE}=========================${NC}"
    read -p "请选择: " choice

    case $choice in
        1) start_service ;; 2) stop_service ;; 3) restart_service ;; 4) show_status ;;
        5) view_logs ;; 6) enable_autostart ;; 7) disable_autostart ;;
        8) check_config ;; 9) format_config ;; 10) merge_configs ;;
        11) gen_uuid ;; 12) gen_reality_key ;; 13) gen_aes ;;
        14) manage_geoip ;; 15) manage_geosite ;; 16) upgrade_singbox ;;
        0) exit 0 ;; *) print_err "无效选项" ;;
    esac
}

main() {
    check_root
    check_install
    while true; do menu; read -n 1 -s -r -p "按回车继续..."; done
}

main
