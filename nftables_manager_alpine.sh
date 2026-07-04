#!/bin/bash
# =============================================
# Alpine nftables 中转管理工具 (v1.3)
# 用法: bash <(curl -sL <URL>)
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NFT_TABLE="nat-trans"
RULES_FILE="/etc/nftables-trans.nft"
SYSCTL_FORWARD_FILE="/etc/sysctl.d/99-nftables-trans-forward.conf"

# 1. 自动检测主出站网卡
detect_main_iface() {
    local ifaces
    ifaces=$(ip -4 route show default | awk '{print $5}' | sort -u)

    if [[ -z "$ifaces" ]]; then
        echo -e "${RED}❌ 未检测到默认路由网卡，请检查网络配置${NC}"
        exit 1
    fi

    local count
    count=$(echo "$ifaces" | wc -l)

    if [[ $count -eq 1 ]]; then
        MAIN_IFACE="$ifaces"
        echo -e "${GREEN}✅ 检测到主出站网卡: ${YELLOW}$MAIN_IFACE${NC}"
    else
        echo -e "${YELLOW}⚠️ 检测到多个默认路由网卡:${NC}"
        echo "$ifaces" | cat -n
        read -p "👉 请选择 [1-$count]: " choice

        MAIN_IFACE=$(echo "$ifaces" | sed -n "${choice}p")

        if [[ -z "$MAIN_IFACE" ]]; then
            echo -e "${RED}❌ 无效选择${NC}"
            exit 1
        fi

        echo -e "${GREEN}✅ 已选择网卡: ${YELLOW}$MAIN_IFACE${NC}"
    fi
}

# 2. 确保 IPv4 转发当前生效，并写入持久化配置
ensure_ip_forward() {
    local current
    current=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)

    if [[ "$current" != "1" ]]; then
        if sysctl -w net.ipv4.ip_forward=1 &>/dev/null; then
            echo -e "${GREEN}✅ 已启用当前 IPv4 转发${NC}"
        else
            echo -e "${RED}❌ 启用 IPv4 转发失败，请检查容器权限${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}✅ 当前 IPv4 转发已启用${NC}"
    fi

    mkdir -p /etc/sysctl.d

    if [[ -f "$SYSCTL_FORWARD_FILE" ]] \
        && grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$SYSCTL_FORWARD_FILE"; then
        echo -e "${GREEN}✅ IPv4 转发持久化配置已存在${NC}"
    else
        if echo "net.ipv4.ip_forward=1" > "$SYSCTL_FORWARD_FILE"; then
            echo -e "${GREEN}✅ 已写入 IPv4 转发持久化配置 ($SYSCTL_FORWARD_FILE)${NC}"
        else
            echo -e "${RED}❌ 写入 IPv4 转发持久化配置失败${NC}"
            exit 1
        fi
    fi
}

# 3. 当前 nft 表不存在但保存文件存在时，先恢复保存规则，避免后续 save_rules 覆盖旧文件
restore_saved_rules_if_needed() {
    if nft list table ip "$NFT_TABLE" &>/dev/null; then
        return 0
    fi

    if [[ ! -s "$RULES_FILE" ]]; then
        return 0
    fi

    echo -e "${YELLOW}⚠️ 当前 nft 表不存在，检测到已保存规则，尝试恢复${NC}"

    if ! nft -c -f "$RULES_FILE" &>/dev/null; then
        echo -e "${RED}❌ 已保存规则文件语法检查失败，为避免覆盖旧文件，已停止${NC}"
        echo -e "${YELLOW}请检查: $RULES_FILE${NC}"
        exit 1
    fi

    if nft -f "$RULES_FILE"; then
        echo -e "${GREEN}✅ 已从 $RULES_FILE 恢复规则${NC}"
    else
        echo -e "${RED}❌ 从 $RULES_FILE 恢复规则失败，为避免覆盖旧文件，已停止${NC}"
        exit 1
    fi
}

# 4. 初始化 nftables table 和 chain
init_nft_table() {
    if ! nft list table ip "$NFT_TABLE" &>/dev/null; then
        nft add table ip "$NFT_TABLE"
        echo -e "${GREEN}✅ 已创建 nftables 表: $NFT_TABLE${NC}"
    fi

    if ! nft list chain ip "$NFT_TABLE" prerouting &>/dev/null; then
        nft add chain ip "$NFT_TABLE" prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
        echo -e "${GREEN}✅ 已创建 prerouting 链${NC}"
    fi

    if ! nft list chain ip "$NFT_TABLE" postrouting &>/dev/null; then
        nft add chain ip "$NFT_TABLE" postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
        echo -e "${GREEN}✅ 已创建 postrouting 链${NC}"
    fi
}

# 5. 原子保存规则，避免 nft list 失败时清空旧文件
save_rules() {
    local tmp

    tmp=$(mktemp "${RULES_FILE}.tmp.XXXXXX") || {
        echo -e "${RED}❌ 创建临时规则文件失败${NC}"
        return 1
    }

    if nft list table ip "$NFT_TABLE" > "$tmp"; then
        if mv "$tmp" "$RULES_FILE"; then
            echo -e "${GREEN}💾 规则已保存至 $RULES_FILE${NC}"
            return 0
        else
            rm -f "$tmp"
            echo -e "${RED}❌ 保存失败，旧规则文件未被覆盖${NC}"
            return 1
        fi
    else
        rm -f "$tmp"
        echo -e "${RED}❌ 读取 nftables 规则失败，旧规则文件未被覆盖${NC}"
        return 1
    fi
}

# 6. 检查同协议同本地端口是否已被占用
port_proto_in_use() {
    local proto="$1"
    local port="$2"

    nft list chain ip "$NFT_TABLE" prerouting 2>/dev/null \
        | grep -Eq "(^|[[:space:]])${proto}[[:space:]]+dport[[:space:]]+${port}[[:space:]]+dnat[[:space:]]+to[[:space:]]+"
}

ensure_no_port_conflict() {
    local proto_choice="$1"
    local lport="$2"
    local conflict=0

    case "$proto_choice" in
        1)
            if port_proto_in_use tcp "$lport"; then
                echo -e "${RED}❌ TCP 本地端口 $lport 已存在转发规则${NC}"
                conflict=1
            fi

            if port_proto_in_use udp "$lport"; then
                echo -e "${RED}❌ UDP 本地端口 $lport 已存在转发规则${NC}"
                conflict=1
            fi
            ;;
        2)
            if port_proto_in_use tcp "$lport"; then
                echo -e "${RED}❌ TCP 本地端口 $lport 已存在转发规则${NC}"
                conflict=1
            fi
            ;;
        3)
            if port_proto_in_use udp "$lport"; then
                echo -e "${RED}❌ UDP 本地端口 $lport 已存在转发规则${NC}"
                conflict=1
            fi
            ;;
    esac

    return "$conflict"
}

# 7. 使用更精确的 MASQUERADE：只处理已 DNAT 的连接
has_precise_masquerade_rule() {
    nft list chain ip "$NFT_TABLE" postrouting 2>/dev/null \
        | grep -Fq "ct status dnat oifname \"$MAIN_IFACE\" masquerade"
}

remove_broad_masquerade_rules() {
    local rules

    rules=$(nft -a list chain ip "$NFT_TABLE" postrouting 2>/dev/null) || return 1

    echo "$rules" \
        | awk -v iface="$MAIN_IFACE" '
            index($0, "ct status dnat") == 0 && index($0, "oifname \"" iface "\" masquerade") > 0 && $0 ~ /handle [0-9]+$/ {
                sub(/^.* handle /, "", $0)
                print $0
            }
        ' \
        | while read -r handle; do
            if [[ -n "$handle" ]]; then
                if nft delete rule ip "$NFT_TABLE" postrouting handle "$handle"; then
                    echo -e "${GREEN}✅ 已移除旧的宽泛 MASQUERADE 规则 handle #$handle${NC}"
                else
                    echo -e "${RED}❌ 移除旧 MASQUERADE 规则 handle #$handle 失败${NC}"
                fi
            fi
        done
}

ensure_masquerade_rule() {
    if has_precise_masquerade_rule; then
        echo -e "${GREEN}✅ 精确 MASQUERADE 规则已存在，跳过${NC}"
    else
        if nft add rule ip "$NFT_TABLE" postrouting ct status dnat oifname "$MAIN_IFACE" masquerade; then
            echo -e "${GREEN}✅ 已添加精确 MASQUERADE: ct status dnat oifname $MAIN_IFACE masquerade${NC}"
        else
            echo -e "${RED}❌ 添加 MASQUERADE 规则失败${NC}"
            exit 1
        fi
    fi

    remove_broad_masquerade_rules
}

# 8. 配置开机自动加载规则：先 nft -c -f 检查，再加载
setup_autoload() {
    mkdir -p /etc/local.d

    cat > /etc/local.d/nftables-restore.start << 'SCRIPT'
#!/bin/sh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

NFT_TABLE="nat-trans"
RULES_FILE="/etc/nftables-trans.nft"

if [ -s "$RULES_FILE" ]; then
    CHECK_FILE=$(mktemp /tmp/nftables-trans-check.XXXXXX) || {
        echo "nftables-trans: failed to create temporary check file" >&2
        exit 1
    }

    {
        echo "destroy table ip $NFT_TABLE"
        cat "$RULES_FILE"
    } > "$CHECK_FILE"

    if nft -c -f "$CHECK_FILE" >/dev/null 2>&1; then
        if ! nft -f "$CHECK_FILE" >/dev/null 2>&1; then
            echo "nftables-trans: restore failed" >&2
        fi
    else
        echo "nftables-trans: saved rules check failed, skip restore" >&2
    fi

    rm -f "$CHECK_FILE"
fi
SCRIPT

    chmod +x /etc/local.d/nftables-restore.start

    if rc-update add local default 2>/dev/null; then
        echo -e "${GREEN}✅ 已配置开机自动加载规则 (local.d)${NC}"
    else
        echo -e "${YELLOW}⚠️ 配置 local 服务自启失败，请手动检查 rc-update add local default${NC}"
    fi
}

# 9. 环境初始化
init_env() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ 请使用 root 运行${NC}"
        exit 1
    fi

    if ! grep -qi alpine /etc/os-release; then
        echo -e "${YELLOW}⚠️ 此脚本专为 Alpine 设计，继续可能出错${NC}"
        read -p "👉 仍然继续？(y/n): " c
        [[ ! "$c" =~ ^[Yy]$ ]] && exit 1
    fi

    local MISSING=""

    if ! command -v ip &>/dev/null; then
        MISSING+="iproute2 "
    fi

    if ! command -v nft &>/dev/null; then
        MISSING+="nftables "
    fi

    if [[ -n "$MISSING" ]]; then
        echo -e "${YELLOW}📦 安装缺失依赖: $MISSING${NC}"

        if ! apk add --no-cache $MISSING; then
            echo -e "${RED}❌ 依赖安装失败${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}✅ 依赖已完备，跳过安装${NC}"
    fi

    if ! nft list ruleset &>/dev/null; then
        echo -e "${RED}❌ 当前环境无法使用 nftables，请检查容器是否具备 NET_ADMIN / nftables 权限${NC}"
        exit 1
    fi

    ensure_ip_forward
    detect_main_iface
    restore_saved_rules_if_needed
    init_nft_table
    ensure_masquerade_rule
    setup_autoload
    save_rules
}

# 10. 添加线路
add_rule() {
    echo -e "\n${BLUE}--- 新增转发线路 ---${NC}"

    read -p "👉 本地监听端口: " LPORT

    [[ -z "$LPORT" ]] && {
        echo -e "${RED}❌ 端口不能为空${NC}"
        return
    }

    if ! [[ "$LPORT" =~ ^[0-9]+$ ]] || [[ "$LPORT" -lt 1 || "$LPORT" -gt 65535 ]]; then
        echo -e "${RED}❌ 端口无效，范围应为 1-65535${NC}"
        return
    fi

    if [[ "$LPORT" -eq 22 ]]; then
        echo -e "${YELLOW}⚠️ 警告：本地端口 22 通常是 SSH 端口，错误转发可能导致无法登录${NC}"
        read -p "👉 确认继续？(y/n): " c

        [[ ! "$c" =~ ^[Yy]$ ]] && {
            echo -e "${YELLOW}已取消${NC}"
            return
        }
    fi

    read -p "👉 后端服务器 IP: " BIP

    [[ -z "$BIP" ]] && {
        echo -e "${RED}❌ IP 不能为空${NC}"
        return
    }

    if ! [[ "$BIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}❌ IP 格式无效，请输入合法的 IPv4 地址${NC}"
        return
    fi

    read -p "👉 后端服务器端口: " BPORT

    [[ -z "$BPORT" ]] && {
        echo -e "${RED}❌ 端口不能为空${NC}"
        return
    }

    if ! [[ "$BPORT" =~ ^[0-9]+$ ]] || [[ "$BPORT" -lt 1 || "$BPORT" -gt 65535 ]]; then
        echo -e "${RED}❌ 端口无效，范围应为 1-65535${NC}"
        return
    fi

    read -p "👉 协议 [1]TCP+UDP(默认) [2]仅TCP [3]仅UDP (回车默认1): " proto
    proto=${proto:-1}

    case "$proto" in
        1|2|3)
            ;;
        *)
            echo -e "${RED}❌ 无效选择${NC}"
            return
            ;;
    esac

    if ! ensure_no_port_conflict "$proto" "$LPORT"; then
        echo -e "${YELLOW}⚠️ 为避免同协议同端口冲突，本次添加已取消${NC}"
        return
    fi

    case "$proto" in
        1)
            nft add rule ip "$NFT_TABLE" prerouting tcp dport "$LPORT" dnat to "$BIP:$BPORT" || {
                echo -e "${RED}❌ 添加 TCP 规则失败${NC}"
                return
            }

            nft add rule ip "$NFT_TABLE" prerouting udp dport "$LPORT" dnat to "$BIP:$BPORT" || {
                echo -e "${RED}❌ 添加 UDP 规则失败，正在回滚 TCP 规则${NC}"

                local tcp_handle
                tcp_handle=$(nft -a list chain ip "$NFT_TABLE" prerouting \
                    | awk -v port="$LPORT" -v target="$BIP:$BPORT" '
                        index($0, "tcp dport " port " dnat to " target) > 0 && $0 ~ /handle [0-9]+$/ {
                            sub(/^.* handle /, "", $0)
                            print $0
                        }
                    ' \
                    | tail -1)

                if [[ -n "$tcp_handle" ]]; then
                    nft delete rule ip "$NFT_TABLE" prerouting handle "$tcp_handle" 2>/dev/null
                fi

                return
            }

            echo -e "${GREEN}✅ 已添加: TCP+UDP $LPORT → $BIP:$BPORT${NC}"
            ;;
        2)
            nft add rule ip "$NFT_TABLE" prerouting tcp dport "$LPORT" dnat to "$BIP:$BPORT" || {
                echo -e "${RED}❌ 添加 TCP 规则失败${NC}"
                return
            }

            echo -e "${GREEN}✅ 已添加: TCP $LPORT → $BIP:$BPORT${NC}"
            ;;
        3)
            nft add rule ip "$NFT_TABLE" prerouting udp dport "$LPORT" dnat to "$BIP:$BPORT" || {
                echo -e "${RED}❌ 添加 UDP 规则失败${NC}"
                return
            }

            echo -e "${GREEN}✅ 已添加: UDP $LPORT → $BIP:$BPORT${NC}"
            ;;
    esac

    save_rules
}

# 11. 查看规则
list_rules() {
    echo -e "\n${BLUE}--- 当前 NAT 转发规则 ---${NC}"

    local rules
    rules=$(nft -a list chain ip "$NFT_TABLE" prerouting 2>&1)

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}❌ 读取转发规则失败: $rules${NC}"
    else
        local matched
        matched=$(echo "$rules" | grep "dnat")

        if [[ -z "$matched" ]]; then
            echo -e "${YELLOW}暂无转发规则${NC}"
        else
            echo "$matched"
        fi
    fi

    echo -e "\n${BLUE}--- 回包伪装规则 ---${NC}"

    local mask_rules
    mask_rules=$(nft -a list chain ip "$NFT_TABLE" postrouting 2>&1)

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}❌ 读取伪装规则失败: $mask_rules${NC}"
    else
        local matched
        matched=$(echo "$mask_rules" | grep "masquerade")

        if [[ -z "$matched" ]]; then
            echo -e "${YELLOW}暂无伪装规则${NC}"
        else
            echo "$matched"
        fi
    fi
}

# 12. 删除线路
delete_rule() {
    list_rules
    echo ""

    read -p "👉 输入要删除的规则 handle 编号: " HANDLE

    [[ -z "$HANDLE" ]] && {
        echo -e "${RED}❌ handle 不能为空${NC}"
        return
    }

    ! [[ "$HANDLE" =~ ^[0-9]+$ ]] && {
        echo -e "${RED}❌ handle 必须为数字${NC}"
        return
    }

    if nft -a list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -qE "handle ${HANDLE}$"; then
        nft delete rule ip "$NFT_TABLE" prerouting handle "$HANDLE"
        save_rules
        echo -e "${GREEN}✅ 已删除转发规则 handle #$HANDLE 并保存${NC}"
    elif nft -a list chain ip "$NFT_TABLE" postrouting 2>/dev/null | grep -qE "handle ${HANDLE}$"; then
        echo -e "${YELLOW}⚠️ 该规则为 MASQUERADE 伪装规则，删除后可能导致回包失败${NC}"
        read -p "👉 确认删除？(y/n): " c

        if [[ "$c" =~ ^[Yy]$ ]]; then
            nft delete rule ip "$NFT_TABLE" postrouting handle "$HANDLE"
            save_rules
            echo -e "${GREEN}✅ 已删除 MASQUERADE 规则 handle #$HANDLE 并保存${NC}"
        else
            echo -e "${YELLOW}已取消${NC}"
        fi
    else
        echo -e "${RED}❌ 未找到 handle #$HANDLE 对应的规则${NC}"
    fi
}

# 13. 清空重置
reset_rules() {
    echo -e "\n${RED}⚠️ 此操作将清空所有 NAT 转发规则，MASQUERADE 保留${NC}"
    read -p "👉 确认清空？(y/n): " c

    [[ ! "$c" =~ ^[Yy]$ ]] && {
        echo -e "${YELLOW}已取消${NC}"
        return
    }

    nft flush chain ip "$NFT_TABLE" prerouting
    echo -e "${GREEN}✅ 已清空所有转发规则${NC}"
    save_rules
}

# === 主程序 ===
init_env

while true; do
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Alpine nftables 中转管理工具 (v1.3.2)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "  [1] 添加转发线路"
    echo "  [2] 查看当前规则"
    echo "  [3] 删除指定线路"
    echo "  [4] 清空重置所有规则"
    echo "  [0] 退出脚本"
    echo -e "${BLUE}========================================${NC}"

    read -p "👉 请选择操作 [0-4]: " choice

    case "$choice" in
        1)
            add_rule
            ;;
        2)
            list_rules
            ;;
        3)
            delete_rule
            ;;
        4)
            reset_rules
            ;;
        0)
            echo -e "${GREEN}👋 再见${NC}"
            break
            ;;
        *)
            echo -e "${RED}❌ 无效选择${NC}"
            ;;
    esac
done
