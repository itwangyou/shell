#!/bin/bash
# sing-box 全能管理脚本 v2.1 (Alpine Linux 专用)
# 功能：服务管理 / 配置工具 / 密钥生成 / 安装卸载 / 自动升级

set -euo pipefail

# ================= 配置区 =================
SINGBOX_BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box"
DEFAULT_CONFIG="/etc/sing-box/config.json"
CONFIG_DIR="${DEFAULT_CONFIG%/*}"
DATA_DIR="/var/lib/sing-box"
SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
PID_FILE="/run/${SERVICE_NAME}.pid"
LOG_DIR="/var/log/sing-box"
LOG_TAIL_PID=""
LOCK_DIR="/run/singbox-manager.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
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

check_alpine() {
    if [[ ! -f /etc/alpine-release ]]; then
        print_err "此脚本仅支持 Alpine Linux。"
        return 1
    fi
}

ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi

    print_warn "未检测到 jq，正在通过 apk 自动安装..."
    if ! command -v apk >/dev/null 2>&1; then
        print_err "未找到 apk，无法自动安装 jq"
        return 1
    fi

    if ! apk add --no-cache jq; then
        print_err "jq 自动安装失败，请检查 Alpine 软件源和网络"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        print_err "apk 执行成功，但仍未检测到 jq"
        return 1
    fi

    print_ok "jq 安装完成"
}

check_deps() {
    local deps=(
        bash curl tar mktemp rc-service rc-update
        uname chmod cp mv rm mkdir cat tail kill sha256sum sleep awk
    )
    local dep
    local missing=0

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            print_err "缺少依赖: $dep"
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        print_err "请先安装缺失依赖后再运行。"
        return 1
    fi
}

check_openrc() {
    if [[ ! -x /sbin/openrc-run ]]; then
        print_err "未检测到 OpenRC: /sbin/openrc-run"
        return 1
    fi
}

release_lock() {
    local lock_pid=""

    if [[ -f "$LOCK_PID_FILE" ]]; then
        lock_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
    fi

    if [[ "$lock_pid" == "$$" ]]; then
        rm -rf "$LOCK_DIR"
    fi
}

release_resources() {
    stop_log_tail
    release_lock
}

acquire_lock() {
    local lock_parent="${LOCK_DIR%/*}"
    local old_pid=""

    mkdir -p "$lock_parent"

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        if [[ -f "$LOCK_PID_FILE" ]]; then
            old_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
        fi

        if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            print_err "已有 sing-box 管理脚本正在运行 (PID: $old_pid)，请勿重复执行。"
            return 1
        fi

        print_warn "检测到残留锁，正在清理..."
        rm -rf "$LOCK_DIR"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            print_err "清理残留锁后仍无法创建管理锁"
            return 1
        fi
    fi

    if ! printf '%s\n' "$$" > "$LOCK_PID_FILE"; then
        print_err "写入管理锁 PID 失败"
        rm -rf "$LOCK_DIR"
        return 1
    fi

    trap release_resources EXIT
}

check_bin() {
    if [[ ! -x "$SINGBOX_BIN" ]]; then
        print_err "未检测到 sing-box 程序: $SINGBOX_BIN，请先选择 13 安装。"
        return 1
    fi
}

get_singbox_version_info() {
    local __result_var="$1"
    local __format="${2:-line}"
    local output
    local first_line
    local parsed_version

    if ! output=$("$SINGBOX_BIN" version 2>/dev/null); then
        print_err "无法读取 sing-box 版本"
        return 1
    fi

    first_line="${output%%$'\n'*}"
    if [[ ! "$first_line" =~ ([0-9][0-9A-Za-z.+-]*) ]]; then
        print_err "无法解析 sing-box 版本: $first_line"
        return 1
    fi
    parsed_version="${BASH_REMATCH[1]}"

    case "$__format" in
        line) printf -v "$__result_var" '%s' "$first_line" ;;
        number) printf -v "$__result_var" '%s' "$parsed_version" ;;
        *)
            print_err "未知版本输出格式: $__format"
            return 1
            ;;
    esac
}

check_config() {
    if [[ ! -f "$DEFAULT_CONFIG" ]]; then
        print_err "未找到配置文件: $DEFAULT_CONFIG"
        return 1
    fi
}

# ================= 服务管理 =================
show_status() {
    check_bin || return
    rc-service "$SERVICE_NAME" status 2>/dev/null || echo "  服务未运行"
    echo ""
    "$SINGBOX_BIN" version 2>/dev/null || true
}

start_service() {
    check_bin || return
    if rc-service "$SERVICE_NAME" start; then
        print_ok "服务已启动"
    else
        print_err "启动失败"
        return 1
    fi
}

stop_service() {
    if rc-service "$SERVICE_NAME" stop 2>/dev/null; then
        print_ok "服务已停止"
    else
        print_warn "服务可能未安装"
        return 1
    fi
}

restart_service() {
    check_bin || return
    if rc-service "$SERVICE_NAME" restart; then
        print_ok "服务已重启"
    else
        print_err "重启失败"
        return 1
    fi
}

enable_autostart() {
    check_bin || return
    if rc-update add "$SERVICE_NAME" default; then
        print_ok "已启用自启"
    else
        print_err "启用失败"
        return 1
    fi
}

disable_autostart() {
    if rc-update del "$SERVICE_NAME" default; then
        print_ok "已取消自启"
    else
        print_err "取消失败"
        return 1
    fi
}

stop_log_tail() {
    if [[ -n "$LOG_TAIL_PID" ]]; then
        kill "$LOG_TAIL_PID" 2>/dev/null || true
        wait "$LOG_TAIL_PID" 2>/dev/null || true
        LOG_TAIL_PID=""
    fi
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
    LOG_TAIL_PID=$!
    read -r
    stop_log_tail
}

# ================= 配置工具 =================
view_config() {
    check_config || return
    print_info "配置文件: $DEFAULT_CONFIG"
    echo "-----------------------------"
    if ! cat "$DEFAULT_CONFIG"; then
        print_err "读取配置文件失败"
        return 1
    fi
    echo "-----------------------------"
}

format_config() {
    check_bin || return
    check_config || return
    print_info "格式化: $DEFAULT_CONFIG"
    if "$SINGBOX_BIN" format -w -c "$DEFAULT_CONFIG"; then
        print_ok "格式化完成"
    else
        print_err "失败"
        return 1
    fi
}

# ================= 密钥生成 =================
gen_uuid() {
    check_bin || return
    local uuid
    if ! uuid=$("$SINGBOX_BIN" generate uuid 2>/dev/null); then
        print_err "UUID 生成失败"
        return 1
    fi
    print_ok "生成的 UUID: $uuid"
}

gen_reality_key() {
    check_bin || return
    print_warn "生成 Reality 密钥对..."
    local output
    if ! output=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null); then
        print_err "Reality 密钥对生成失败"
        return 1
    fi
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
    read -r -p "请选择 [1-2, 默认 1]: " choice
    local len=16
    if [[ "$choice" == "2" ]]; then
        len=32
    fi

    print_warn "正在生成 $len 字节 (对应 $((len*8))位) 密钥..."
    local output
    if ! output=$("$SINGBOX_BIN" generate rand --base64 "$len" 2>/dev/null); then
        print_err "AES 密钥生成失败"
        return 1
    fi
    echo "-----------------------------"
    echo "$output"
    echo "-----------------------------"
}

# ================= 安装与卸载 =================
GITHUB_RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

get_latest_release() {
    local __version_var="$1"
    local __release_var="$2"
    local __sb_release_payload
    local __sb_release_version

    if ! __sb_release_payload=$(curl -fsSL --retry 3 --retry-delay 2 \
        --connect-timeout 10 --max-time 30 "$GITHUB_RELEASE_API"); then
        print_err "无法获取 GitHub Release 信息"
        return 1
    fi

    if ! __sb_release_version=$(jq -er '.tag_name | strings | ltrimstr("v")' <<< "$__sb_release_payload"); then
        print_err "Release 信息中缺少有效版本号"
        return 1
    fi

    if [[ ! "$__sb_release_version" =~ ^[0-9][0-9A-Za-z.+-]*$ ]]; then
        print_err "Release 信息中的版本号格式无效: $__sb_release_version"
        return 1
    fi

    printf -v "$__version_var" '%s' "$__sb_release_version"
    printf -v "$__release_var" '%s' "$__sb_release_payload"
}

get_release_asset_digest() {
    local __result_var="$1"
    local release_payload="$2"
    local asset_name="$3"
    local __sb_asset_digest

    if ! __sb_asset_digest=$(jq -er --arg name "$asset_name" '
        .assets[]
        | select(.name == $name)
        | .digest
        | strings
        | select(test("^sha256:[0-9a-fA-F]{64}$"))
    ' <<< "$release_payload"); then
        print_err "Release 中未找到资产或有效 SHA-256: $asset_name"
        return 1
    fi

    printf -v "$__result_var" '%s' "${__sb_asset_digest#sha256:}"
}

detect_singbox_arch() {
    local __result_var="$1"
    local resolved_arch

    resolved_arch=$(uname -m)
    case "$resolved_arch" in
        x86_64) resolved_arch="amd64" ;;
        aarch64) resolved_arch="arm64" ;;
        *)
            print_err "不支持的架构: $resolved_arch"
            return 1
            ;;
    esac

    printf -v "$__result_var" '%s' "$resolved_arch"
}

build_asset_name() {
    local __result_var="$1"
    local version="$2"
    local arch="$3"

    printf -v "$__result_var" '%s' \
        "sing-box-${version}-linux-${arch}-musl.tar.gz"
}

build_download_url() {
    local __result_var="$1"
    local version="$2"
    local asset_name="$3"
    local base_url="https://github.com/SagerNet/sing-box/releases/download"

    printf -v "$__result_var" '%s' \
        "${base_url}/v${version}/${asset_name}"
}

download_singbox_binary() {
    local __result_var="$1"
    local version="$2"
    local release_json="$3"
    local tmpdir="$4"
    local detected_arch
    local asset_name
    local expected_sha256
    local actual_sha256
    local download_url
    local archive
    local extract_dir
    local downloaded_bin

    detect_singbox_arch detected_arch || return 1
    build_asset_name asset_name "$version" "$detected_arch"
    get_release_asset_digest expected_sha256 "$release_json" "$asset_name" || return 1
    build_download_url download_url "$version" "$asset_name"

    archive="$tmpdir/$asset_name"
    extract_dir="$tmpdir/extract"
    downloaded_bin="$extract_dir/sing-box"

    if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
        --connect-timeout 15 --max-time 180 \
        -o "$archive" "$download_url"; then
        print_err "下载失败，请检查网络或版本可用性"
        return 1
    fi

    if ! actual_sha256=$(sha256sum "$archive" | awk '{print $1}'); then
        print_err "无法计算下载文件 SHA-256"
        rm -f "$archive"
        return 1
    fi

    if [[ ! "$actual_sha256" =~ ^[0-9a-fA-F]{64}$ || \
          "${actual_sha256,,}" != "${expected_sha256,,}" ]]; then
        print_err "下载文件 SHA-256 校验失败，已拒绝安装"
        rm -f "$archive"
        return 1
    fi
    print_ok "下载文件 SHA-256 校验通过"

    if ! mkdir -p "$extract_dir"; then
        print_err "创建解压目录失败"
        return 1
    fi

    if ! tar -xzf "$archive" -C "$extract_dir" --strip-components=1; then
        print_err "解压失败，请检查下载包"
        return 1
    fi

    if [[ ! -x "$downloaded_bin" ]]; then
        print_err "压缩包中未找到可执行 sing-box"
        return 1
    fi

    if ! "$downloaded_bin" version &>/dev/null; then
        print_err "下载的 sing-box 二进制验证失败"
        return 1
    fi

    printf -v "$__result_var" '%s' "$downloaded_bin"
}

install_binary_atomic() {
    local src="$1"
    local dst="$2"
    local dst_dir="${dst%/*}"
    local new_target="${dst}.new.$$"

    if ! mkdir -p "$dst_dir"; then
        print_err "创建安装目录失败"
        return 1
    fi

    if ! cp "$src" "$new_target"; then
        print_err "复制新二进制失败"
        rm -f "$new_target"
        return 1
    fi

    if ! chmod +x "$new_target"; then
        print_err "设置新二进制权限失败"
        rm -f "$new_target"
        return 1
    fi

    if ! mv -f "$new_target" "$dst"; then
        print_err "替换新二进制失败"
        rm -f "$new_target"
        return 1
    fi
}

write_service_file_atomic() {
    local service_dir="${SERVICE_FILE%/*}"
    local service_tmp="${SERVICE_FILE}.new.$$"

    if ! mkdir -p "$service_dir"; then
        print_err "创建服务目录失败"
        return 1
    fi

    if ! cat > "$service_tmp" << EOF
#!/sbin/openrc-run

name="$SERVICE_NAME"
description="sing-box proxy service"
command="$SINGBOX_BIN"
command_args="run -c $DEFAULT_CONFIG"
command_background=true
pidfile="$PID_FILE"
output_log="${LOG_DIR}/access.log"
error_log="${LOG_DIR}/error.log"
retry="SIGTERM/5/SIGKILL/5"

start_pre() {
    [ -f "$DEFAULT_CONFIG" ] || { eerror "Config file not found: $DEFAULT_CONFIG"; return 1; }
    "$SINGBOX_BIN" check -c "$DEFAULT_CONFIG" || { eerror "Config check failed"; return 1; }
}
EOF
    then
        print_err "写入服务文件失败"
        rm -f "$service_tmp"
        return 1
    fi

    if ! chmod +x "$service_tmp"; then
        print_err "设置服务文件权限失败"
        rm -f "$service_tmp"
        return 1
    fi

    if ! mv -f "$service_tmp" "$SERVICE_FILE"; then
        print_err "安装服务文件失败"
        rm -f "$service_tmp"
        return 1
    fi
}

install_singbox() {
    if [[ -x "$SINGBOX_BIN" ]]; then
        print_warn "sing-box 已安装，请使用升级选项 (15)"
        return 0
    fi

    print_info "正在获取最新版本..."
    local latest
    local release_payload
    get_latest_release latest release_payload || return 1
    print_info "最新版本: $latest，正在下载..."

    local tmpdir
    if ! tmpdir=$(mktemp -d); then
        print_err "创建临时目录失败"
        return 1
    fi
    trap 'rm -rf "$tmpdir"; trap - RETURN' RETURN

    local new_bin
    download_singbox_binary new_bin "$latest" "$release_payload" "$tmpdir" || return 1

    print_info "正在安装..."
    install_binary_atomic "$new_bin" "$SINGBOX_BIN" || return 1

    print_info "正在注册系统服务..."
    if ! mkdir -p "$LOG_DIR"; then
        print_err "创建日志目录失败"
        return 1
    fi
    write_service_file_atomic || return 1
    if ! mkdir -p "$CONFIG_DIR"; then
        print_err "创建配置目录失败"
        return 1
    fi

    local installed_version
    get_singbox_version_info installed_version line || return 1
    print_ok "安装成功！版本: $installed_version"
    print_info "请将配置文件放入 $DEFAULT_CONFIG 然后启动服务"
}

uninstall_singbox() {
    read -r -p "确定要卸载 sing-box 吗？所有配置和数据将被删除！(y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    print_info "正在停止服务..."
    rc-service "$SERVICE_NAME" stop 2>/dev/null || true
    rc-update del "$SERVICE_NAME" default 2>/dev/null || true

    print_info "正在删除文件..."
    if ! rm -f "$SINGBOX_BIN"; then
        print_err "删除二进制失败"
        return 1
    fi
    if ! rm -f "$SERVICE_FILE"; then
        print_err "删除服务文件失败"
        return 1
    fi

    print_info "正在清理配置、数据和日志目录..."
    if ! rm -rf "$CONFIG_DIR"; then
        print_err "删除配置目录失败"
        return 1
    fi
    if ! rm -rf "$DATA_DIR"; then
        print_err "删除数据目录失败"
        return 1
    fi
    if ! rm -rf "$LOG_DIR"; then
        print_err "删除日志目录失败"
        return 1
    fi

    print_ok "卸载完成！"
}

# ================= 升级管理 =================

is_service_running() {
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1
}

wait_for_service_running() {
    local attempts=5
    local i

    for ((i = 0; i < attempts; i++)); do
        if is_service_running; then
            return 0
        fi
        sleep 1
    done
    return 1
}

restore_previous_binary() {
    local backup="$1"

    if [[ ! -f "$backup" ]]; then
        print_err "找不到旧版本备份，无法回滚: $backup"
        return 1
    fi

    if ! install_binary_atomic "$backup" "$SINGBOX_BIN"; then
        print_err "恢复旧版本二进制失败"
        return 1
    fi
    return 0
}

rollback_upgrade() {
    local backup="$1"
    local was_running="$2"
    local reason="$3"

    print_err "$reason，正在回滚旧版本..."
    if [[ "$was_running" == "true" ]]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    fi

    restore_previous_binary "$backup" || return 1

    if [[ "$was_running" == "true" ]]; then
        if ! rc-service "$SERVICE_NAME" start >/dev/null 2>&1 || ! wait_for_service_running; then
            print_err "旧版本已恢复，但服务恢复启动失败，请立即人工检查"
            return 1
        fi
    fi

    return 0
}

rollback_and_fail() {
    local backup="$1"
    local was_running="$2"
    local reason="$3"

    if rollback_upgrade "$backup" "$was_running" "$reason"; then
        if ! rm -f "$backup"; then
            print_warn "旧版本已恢复，但备份清理失败: $backup"
        fi
        return 1
    fi

    print_err "自动回滚失败，旧版本备份已保留: $backup"
    return 2
}

upgrade_singbox() {
    check_bin || return
    print_info "检查新版本..."
    local latest
    local release_payload
    get_latest_release latest release_payload || return 1

    local current
    get_singbox_version_info current number || return 1

    echo "当前: $current | 最新: $latest"
    [[ "$current" == "$latest" ]] && { print_ok "已是最新版"; return; }

    read -r -p "是否升级? (y/n): "
    [[ $REPLY =~ ^[Yy]$ ]] || return

    local tmpdir
    if ! tmpdir=$(mktemp -d); then
        print_err "创建临时目录失败"
        return 1
    fi
    trap 'rm -rf "$tmpdir"; trap - RETURN' RETURN

    local new_bin
    download_singbox_binary new_bin "$latest" "$release_payload" "$tmpdir" || return 1

    local backup="${SINGBOX_BIN}.bak.$$"
    local was_running=false
    if is_service_running; then
        was_running=true
    fi

    if ! cp "$SINGBOX_BIN" "$backup"; then
        print_err "备份旧版本失败"
        return 1
    fi
    if ! chmod +x "$backup"; then
        print_err "设置旧版本备份权限失败"
        rm -f "$backup"
        return 1
    fi

    if ! install_binary_atomic "$new_bin" "$SINGBOX_BIN"; then
        print_err "替换新版本二进制失败"
        rm -f "$backup"
        return 1
    fi

    if ! "$SINGBOX_BIN" version &>/dev/null; then
        rollback_and_fail "$backup" "$was_running" "升级后二进制验证失败"
        return $?
    fi

    if [[ -f "$DEFAULT_CONFIG" ]] && ! "$SINGBOX_BIN" check -c "$DEFAULT_CONFIG"; then
        rollback_and_fail "$backup" "$was_running" "升级后二进制与当前配置不兼容"
        return $?
    fi

    if [[ "$was_running" == "true" ]]; then
        print_info "正在重启服务并验证运行状态..."
        if ! rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || ! wait_for_service_running; then
            rollback_and_fail "$backup" "$was_running" "新版本服务启动或健康检查失败"
            return $?
        fi
    fi

    if ! rm -f "$backup"; then
        print_err "升级完成，但清理旧版本备份失败: $backup"
        return 1
    fi

    local upgraded_version
    get_singbox_version_info upgraded_version line || return 1
    print_ok "升级成功！版本: $upgraded_version"
    if [[ "$was_running" == "true" ]]; then
        print_info "服务已重启并通过状态检查"
    else
        print_info "服务升级前未运行，未自动启动"
    fi
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
    read -r -p "请选择: " choice

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
    check_alpine
    ensure_jq
    check_deps
    check_openrc
    acquire_lock
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while true; do
        menu || true
        read -n 1 -s -r -p "按回车继续..."
    done
}

main