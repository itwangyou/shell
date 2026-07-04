#!/bin/bash
# ============================================
# Debian nftables 中转管理工具 (v1.3)
# 用法: bash <(curl -sL <URL>)
# =============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NFT_TABLE="nat-trans"
RULES_FILE="/etc/nftables-trans.nft"
SYSCTL_FORWARD_FILE="/etc/sysctl.d/99-nftables-trans-forward.conf"
RESTORE_SCRIPT="/usr/local/sbin/nftables-trans-restore"
SYSTEMD_SERVICE="/etc/systemd/system/nftables-trans.service"

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
        read -r -p "👉 请选择 [1-$count]: " choice

        MAIN_IFACE=$(echo "$ifaces" | sed -n "${choice}p")

        if [[ -z "$MAIN_IFACE" ]]; then
            echo -e "${RED}❌ 无效选择${NC}"
            exit 1
        fi

        echo -e "${GREEN}✅ 已选择网卡: ${YELLOW}$MAIN_IFACE${NC}"
    fi
}

# 2. 确保 IPv4 转发当前生效，并写入脚本专用持久化配置
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

    if restore_rules_from_file_replace_current; then
        echo -e "${GREEN}✅ 已从 $RULES_FILE 恢复规则${NC}"
    else
        echo -e "${RED}❌ 从 $RULES_FILE 恢复失败（规则文件可能损坏），为避免覆盖旧文件，已停止${NC}"
        echo -e "${YELLOW}请检查: $RULES_FILE${NC}"
        exit 1
    fi
}

restore_rules_from_file_replace_current() {
    local tmp
    tmp=$(mktemp /tmp/nftables-trans-restore-now.XXXXXX) || return 1

    {
        if nft list table ip "$NFT_TABLE" &>/dev/null; then
            echo "delete table ip $NFT_TABLE"
        fi
        cat "$RULES_FILE"
    } > "$tmp"

    if nft -c -f "$tmp" &>/dev/null && nft -f "$tmp"; then
        rm -f "$tmp"
        return 0
    fi

    rm -f "$tmp"
    return 1
}

rules_have_dnat() {
    grep -q ' dnat to ' "$1" 2>/dev/null
}

check_current_saved_rules_diff() {
    if [[ ! -s "$RULES_FILE" ]]; then
        return 0
    fi

    if ! nft list table ip "$NFT_TABLE" &>/dev/null; then
        return 0
    fi

    local current_tmp
    current_tmp=$(mktemp /tmp/nftables-trans-current.XXXXXX) || {
        echo -e "${YELLOW}⚠️ 创建临时文件失败，跳过当前/保存规则差异检测${NC}"
        return 0
    }

    if ! nft list table ip "$NFT_TABLE" > "$current_tmp"; then
        rm -f "$current_tmp"
        echo -e "${YELLOW}⚠️ 读取当前 nft 规则失败，跳过当前/保存规则差异检测${NC}"
        return 0
    fi

    if ! cmp -s "$current_tmp" "$RULES_FILE"; then
        echo -e "${YELLOW}⚠️ 检测到当前内存规则与保存文件不一致${NC}"

        if rules_have_dnat "$RULES_FILE" && ! rules_have_dnat "$current_tmp"; then
            echo -e "${YELLOW}保存文件中存在转发规则，但当前内存规则中没有转发规则。${NC}"
            read -r -p "👉 是否从保存文件恢复规则？(y/n): " c

            if [[ "$c" =~ ^[Yy]$ ]]; then
                if restore_rules_from_file_replace_current; then
                    echo -e "${GREEN}✅ 已从保存文件恢复规则${NC}"
                else
                    echo -e "${RED}❌ 从保存文件恢复失败，已保留当前内存规则${NC}"
                fi
            else
                echo -e "${YELLOW}继续使用当前内存规则；后续保存可能覆盖旧保存文件${NC}"
            fi
        else
            echo -e "${YELLOW}继续使用当前内存规则；后续保存会以当前规则为准${NC}"
        fi
    fi

    rm -f "$current_tmp"
}

# 4. 初始化 nftables table 和 chain
init_nft_table() {
    if ! nft list table ip "$NFT_TABLE" &>/dev/null; then
        nft add table ip "$NFT_TABLE" || {
            echo -e "${RED}❌ 创建 nftables 表失败${NC}"
            exit 1
        }
        echo -e "${GREEN}✅ 已创建 nftables 表: $NFT_TABLE${NC}"
    fi

    if ! nft list chain ip "$NFT_TABLE" prerouting &>/dev/null; then
        nft add chain ip "$NFT_TABLE" prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' || {
            echo -e "${RED}❌ 创建 prerouting 链失败${NC}"
            exit 1
        }
        echo -e "${GREEN}✅ 已创建 prerouting 链${NC}"
    fi

    if ! nft list chain ip "$NFT_TABLE" postrouting &>/dev/null; then
        nft add chain ip "$NFT_TABLE" postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' || {
            echo -e "${RED}❌ 创建 postrouting 链失败${NC}"
            exit 1
        }
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

save_rules_or_warn() {
    if ! save_rules; then
        echo -e "${YELLOW}⚠️ 当前规则已在内存中变更，但保存失败；重启后可能丢失${NC}"
        return 1
    fi

    return 0
}

# 6. 基础输入校验与规范化
valid_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    local value=$((10#$port))
    [[ "$value" -ge 1 && "$value" -le 65535 ]]
}

normalize_port() {
    local port="$1"

    valid_port "$port" || return 1
    echo "$((10#$port))"
}

normalize_ipv4() {
    local ip="$1"
    local IFS=.
    local a b c d extra n value

    read -r a b c d extra <<< "$ip"

    [[ -z "$extra" ]] || return 1

    for n in "$a" "$b" "$c" "$d"; do
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        value=$((10#$n))
        [[ "$value" -ge 0 && "$value" -le 255 ]] || return 1
    done

    echo "$((10#$a)).$((10#$b)).$((10#$c)).$((10#$d))"
}

valid_ipv4() {
    normalize_ipv4 "$1" >/dev/null
}

# 7. 检查同协议同本地端口是否已被占用
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

# 8. 使用更精确的 MASQUERADE：只处理已 DNAT 的连接
has_precise_masquerade_rule() {
    nft list chain ip "$NFT_TABLE" postrouting 2>/dev/null \
        | grep -Fq "ct status dnat oifname \"$MAIN_IFACE\" masquerade"
}

remove_broad_masquerade_rules() {
    local rules

    rules=$(nft -a list chain ip "$NFT_TABLE" postrouting 2>/dev/null) || return 1

    echo "$rules" \
        | awk -v iface="$MAIN_IFACE" '
            $0 ~ /^[ \t]*oifname "[^"]+" masquerade # handle [0-9]+$/ && index($0, "oifname \"" iface "\" masquerade") > 0 {
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

# 9. UFW 处理：DNAT 转发应使用 ufw route，而不是普通 ufw allow
ufw_is_active() {
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'
}

ufw_route_allow_if_active() {
    local proto="$1"
    local bip="$2"
    local bport="$3"

    if ufw_is_active; then
        if ufw route allow proto "$proto" to "$bip" port "$bport" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 已放行 UFW routed 流量: $proto → $bip:$bport${NC}"
        else
            echo -e "${YELLOW}⚠️ UFW routed 放行失败，请手动检查: ufw route allow proto $proto to $bip port $bport${NC}"
        fi
    fi
}

ufw_route_delete_if_unused() {
    local proto="$1"
    local bip="$2"
    local bport="$3"
    local target="${bip}:${bport}"

    if ! ufw_is_active; then
        return 0
    fi

    if nft list chain ip "$NFT_TABLE" prerouting 2>/dev/null \
        | awk -v p="$proto" -v t="$target" '
            index($0, p " dport ") > 0 && index($0, "dnat to " t) > 0 { found=1 }
            END { exit found ? 0 : 1 }
        '; then
        return 0
    fi

    ufw --force route delete allow proto "$proto" to "$bip" port "$bport" >/dev/null 2>&1 || true
}

collect_forward_targets() {
    nft list chain ip "$NFT_TABLE" prerouting 2>/dev/null \
        | awk '
            / dnat to / {
                proto=""; target=""
                for (i=1; i<=NF; i++) {
                    if ($i == "tcp" || $i == "udp") proto=$i
                    if ($i == "to" && (i+1)<=NF) target=$(i+1)
                }
                if (proto != "" && target ~ /^[0-9.]+:[0-9]+$/) print proto, target
            }
        ' \
        | sort -u
}


# 10. 本地监听端口占用检测
get_local_listeners_on_port() {
    local port="$1"
    local proto_filter="${2:-any}"

    if command -v ss &>/dev/null; then
        ss -H -lntu 2>/dev/null | awk -v p=":$port" -v proto="$proto_filter" '
            $5 ~ p"$" {
                if (proto == "any" || $1 == proto) print
            }
        '
    elif command -v netstat &>/dev/null; then
        netstat -lntu 2>/dev/null | awk -v p=":$port" -v proto="$proto_filter" '
            $4 ~ p"$" {
                if (proto == "any" || tolower($1) ~ "^" proto) print
            }
        '
    fi
}

warn_if_local_port_in_use() {
    local port="$1"
    local proto_choice="$2"
    local listeners=""

    case "$proto_choice" in
        1)
            listeners=$(get_local_listeners_on_port "$port" tcp; get_local_listeners_on_port "$port" udp)
            ;;
        2)
            listeners=$(get_local_listeners_on_port "$port" tcp)
            ;;
        3)
            listeners=$(get_local_listeners_on_port "$port" udp)
            ;;
        *)
            listeners=$(get_local_listeners_on_port "$port" any)
            ;;
    esac

    if [[ -n "$listeners" ]]; then
        echo -e "${YELLOW}⚠️ 检测到本机已有服务监听端口 $port:${NC}"
        echo "$listeners" | sort -u
        echo -e "${YELLOW}DNAT 规则仍可添加，但该端口已有本机服务时可能造成访问结果不符合预期。${NC}"
        read -r -p "👉 确认继续？(y/n): " c

        if [[ ! "$c" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}已取消${NC}"
            return 1
        fi
    fi

    return 0
}

# 11. 配置 Debian/systemd 开机自动恢复
setup_autoload() {
    if ! command -v systemctl &>/dev/null; then
        echo -e "${YELLOW}⚠️ 未检测到 systemctl，无法配置 systemd 开机自启；当前规则仍已生效并保存${NC}"
        return 1
    fi

    cat > "$RESTORE_SCRIPT" << 'SCRIPT'
#!/bin/sh
set -eu

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

NFT_TABLE="nat-trans"
RULES_FILE="/etc/nftables-trans.nft"
TMP_FILE=$(mktemp /tmp/nftables-trans-restore.XXXXXX) || {
    echo "nftables-trans: failed to create temporary file" >&2
    exit 1
}

cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT INT TERM

if [ ! -s "$RULES_FILE" ]; then
    echo "nftables-trans: rules file not found or empty, skip restore" >&2
    exit 0
fi

if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
    echo "delete table ip $NFT_TABLE" > "$TMP_FILE"
else
    : > "$TMP_FILE"
fi

cat "$RULES_FILE" >> "$TMP_FILE"

if nft -c -f "$TMP_FILE" >/dev/null 2>&1; then
    nft -f "$TMP_FILE"
else
    echo "nftables-trans: saved rules check failed, skip restore" >&2
    exit 1
fi
SCRIPT

    chmod +x "$RESTORE_SCRIPT"

    cat > "$SYSTEMD_SERVICE" << EOF
[Unit]
Description=Restore nftables NAT forwarding rules managed by nftables-trans
After=nftables.service
ConditionPathExists=$RULES_FILE

[Service]
Type=oneshot
ExecStart=$RESTORE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true

    if systemctl enable nftables-trans.service 2>/dev/null; then
        echo -e "${GREEN}✅ 已配置开机自动恢复服务: nftables-trans.service${NC}"
    else
        echo -e "${YELLOW}⚠️ 配置 systemd 自启失败，请手动检查: systemctl enable nftables-trans.service${NC}"
        return 1
    fi
}

# 12. 环境初始化
init_env() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ 请使用 root 运行${NC}"
        exit 1
    fi

    if ! grep -qiE '(^ID=debian|ID_LIKE=.*debian)' /etc/os-release; then
        echo -e "${YELLOW}⚠️ 此脚本专为 Debian 系统设计，继续可能出错${NC}"
        read -r -p "👉 仍然继续？(y/n): " c
        [[ ! "$c" =~ ^[Yy]$ ]] && exit 1
    fi

    local MISSING=()

    if ! command -v ip &>/dev/null; then
        MISSING+=("iproute2")
    fi

    if ! command -v nft &>/dev/null; then
        MISSING+=("nftables")
    fi

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo -e "${YELLOW}📦 安装缺失依赖: ${MISSING[*]}${NC}"

        if ! apt-get update -qq; then
            echo -e "${RED}❌ apt update 失败${NC}"
            exit 1
        fi

        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}"; then
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
    check_current_saved_rules_diff
    init_nft_table
    ensure_masquerade_rule
    save_rules_or_warn
    setup_autoload
}

# 13. 添加线路
add_rule() {
    echo -e "\n${BLUE}--- 新增转发线路 ---${NC}"

    read -r -p "👉 本地监听端口: " LPORT

    [[ -z "$LPORT" ]] && {
        echo -e "${RED}❌ 端口不能为空${NC}"
        return
    }

    if ! valid_port "$LPORT"; then
        echo -e "${RED}❌ 端口无效，范围应为 1-65535${NC}"
        return
    fi
    LPORT=$(normalize_port "$LPORT") || {
        echo -e "${RED}❌ 端口规范化失败${NC}"
        return
    }

    if [[ "$LPORT" -eq 22 ]]; then
        echo -e "${YELLOW}⚠️ 警告：本地端口 22 通常是 SSH 端口，错误转发可能导致无法登录${NC}"
        read -r -p "👉 确认继续？(y/n): " c

        [[ ! "$c" =~ ^[Yy]$ ]] && {
            echo -e "${YELLOW}已取消${NC}"
            return
        }
    fi

    read -r -p "👉 后端服务器 IP: " BIP

    [[ -z "$BIP" ]] && {
        echo -e "${RED}❌ IP 不能为空${NC}"
        return
    }

    if ! valid_ipv4 "$BIP"; then
        echo -e "${RED}❌ IP 格式无效，请输入合法的 IPv4 地址${NC}"
        return
    fi
    BIP=$(normalize_ipv4 "$BIP") || {
        echo -e "${RED}❌ IP 规范化失败${NC}"
        return
    }

    read -r -p "👉 后端服务器端口: " BPORT

    [[ -z "$BPORT" ]] && {
        echo -e "${RED}❌ 端口不能为空${NC}"
        return
    }

    if ! valid_port "$BPORT"; then
        echo -e "${RED}❌ 端口无效，范围应为 1-65535${NC}"
        return
    fi
    BPORT=$(normalize_port "$BPORT") || {
        echo -e "${RED}❌ 端口规范化失败${NC}"
        return
    }

    read -r -p "👉 协议 [1]TCP+UDP(默认) [2]仅TCP [3]仅UDP (回车默认1): " proto
    proto=${proto:-1}

    case "$proto" in
        1|2|3)
            ;;
        *)
            echo -e "${RED}❌ 无效选择${NC}"
            return
            ;;
    esac

    if ! warn_if_local_port_in_use "$LPORT" "$proto"; then
        return
    fi

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

            ufw_route_allow_if_active tcp "$BIP" "$BPORT"
            ufw_route_allow_if_active udp "$BIP" "$BPORT"
            echo -e "${GREEN}✅ 已添加: TCP+UDP $LPORT → $BIP:$BPORT${NC}"
            ;;
        2)
            nft add rule ip "$NFT_TABLE" prerouting tcp dport "$LPORT" dnat to "$BIP:$BPORT" || {
                echo -e "${RED}❌ 添加 TCP 规则失败${NC}"
                return
            }

            ufw_route_allow_if_active tcp "$BIP" "$BPORT"
            echo -e "${GREEN}✅ 已添加: TCP $LPORT → $BIP:$BPORT${NC}"
            ;;
        3)
            nft add rule ip "$NFT_TABLE" prerouting udp dport "$LPORT" dnat to "$BIP:$BPORT" || {
                echo -e "${RED}❌ 添加 UDP 规则失败${NC}"
                return
            }

            ufw_route_allow_if_active udp "$BIP" "$BPORT"
            echo -e "${GREEN}✅ 已添加: UDP $LPORT → $BIP:$BPORT${NC}"
            ;;
    esac

    save_rules_or_warn
}

# 14. 查看规则
list_rules() {
    echo -e "\n${BLUE}--- 当前 NAT 转发规则 ---${NC}"

    local rules
    if ! rules=$(nft -a list chain ip "$NFT_TABLE" prerouting 2>&1); then
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
    if ! mask_rules=$(nft -a list chain ip "$NFT_TABLE" postrouting 2>&1); then
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

    if ufw_is_active; then
        echo -e "\n${BLUE}--- UFW 状态 ---${NC}"
        echo -e "${YELLOW}UFW 已启用；脚本使用 ufw route allow 处理 DNAT 转发流量${NC}"
    fi
}

# 15. 删除线路
delete_rule() {
    list_rules
    echo ""

    read -r -p "👉 输入要删除的规则 handle 编号: " HANDLE

    [[ -z "$HANDLE" ]] && {
        echo -e "${RED}❌ handle 不能为空${NC}"
        return
    }

    ! [[ "$HANDLE" =~ ^[0-9]+$ ]] && {
        echo -e "${RED}❌ handle 必须为数字${NC}"
        return
    }

    if nft -a list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -qE "handle ${HANDLE}$"; then
        local del_line del_proto del_target del_bip del_bport

        del_line=$(nft -a list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -E "handle ${HANDLE}$")
        del_proto=$(echo "$del_line" | awk '{ for (i=1; i<=NF; i++) if ($i=="tcp" || $i=="udp") { print $i; exit } }')
        del_target=$(echo "$del_line" | sed -n 's/.* dnat to \([0-9.]*:[0-9]*\).* handle .*/\1/p')

        nft delete rule ip "$NFT_TABLE" prerouting handle "$HANDLE" || {
            echo -e "${RED}❌ 删除规则失败${NC}"
            return
        }

        if [[ -n "$del_proto" && -n "$del_target" ]]; then
            del_bip=${del_target%:*}
            del_bport=${del_target##*:}
            ufw_route_delete_if_unused "$del_proto" "$del_bip" "$del_bport"
        fi

        save_rules_or_warn
        echo -e "${GREEN}✅ 已删除转发规则 handle #$HANDLE 并保存${NC}"
    elif nft -a list chain ip "$NFT_TABLE" postrouting 2>/dev/null | grep -qE "handle ${HANDLE}$"; then
        echo -e "${YELLOW}⚠️ 该规则为 MASQUERADE 伪装规则，删除后可能导致回包失败${NC}"
        read -r -p "👉 确认删除？(y/n): " c

        if [[ "$c" =~ ^[Yy]$ ]]; then
            nft delete rule ip "$NFT_TABLE" postrouting handle "$HANDLE" || {
                echo -e "${RED}❌ 删除 MASQUERADE 规则失败${NC}"
                return
            }
            save_rules_or_warn
            echo -e "${GREEN}✅ 已删除 MASQUERADE 规则 handle #$HANDLE 并保存${NC}"
        else
            echo -e "${YELLOW}已取消${NC}"
        fi
    else
        echo -e "${RED}❌ 未找到 handle #$HANDLE 对应的规则${NC}"
    fi
}

# 16. 清空重置
reset_rules() {
    echo -e "\n${RED}⚠️ 此操作将清空所有 NAT 转发规则，MASQUERADE 保留${NC}"
    read -r -p "👉 确认清空？(y/n): " c

    [[ ! "$c" =~ ^[Yy]$ ]] && {
        echo -e "${YELLOW}已取消${NC}"
        return
    }

    local targets
    targets=$(collect_forward_targets)

    if nft flush chain ip "$NFT_TABLE" prerouting; then
        if ufw_is_active && [[ -n "$targets" ]]; then
            echo "$targets" | while read -r proto target; do
                local bip bport
                bip=${target%:*}
                bport=${target##*:}
                ufw --force route delete allow proto "$proto" to "$bip" port "$bport" >/dev/null 2>&1 || true
            done
        fi

        echo -e "${GREEN}✅ 已清空所有转发规则${NC}"
        save_rules_or_warn
    else
        echo -e "${RED}❌ 清空转发规则失败，未清理 UFW route 规则${NC}"
        return
    fi
}

# 17. 卸载脚本配置
uninstall_tool() {
    echo -e "\n${RED}⚠️ 卸载将删除本脚本创建的配置和规则:${NC}"
    echo "  - nftables 表: ip $NFT_TABLE"
    echo "  - 规则文件: $RULES_FILE"
    echo "  - systemd 服务: $SYSTEMD_SERVICE"
    echo "  - 恢复脚本: $RESTORE_SCRIPT"
    echo "  - IPv4 转发持久化配置: $SYSCTL_FORWARD_FILE"
    echo -e "${YELLOW}注意：不会把当前 net.ipv4.ip_forward 改回 0，避免影响其他服务。${NC}"
    read -r -p "👉 确认卸载？请输入 yes: " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}已取消${NC}"
        return
    fi

    local targets=""
    targets=$(collect_forward_targets)

    if ufw_is_active && [[ -n "$targets" ]]; then
        read -r -p "👉 是否同时清理对应 UFW route 规则？(y/n): " clean_ufw
        if [[ "$clean_ufw" =~ ^[Yy]$ ]]; then
            echo "$targets" | while read -r proto target; do
                local bip bport
                bip=${target%:*}
                bport=${target##*:}
                ufw --force route delete allow proto "$proto" to "$bip" port "$bport" >/dev/null 2>&1 || true
            done
            echo -e "${GREEN}✅ 已尝试清理对应 UFW route 规则${NC}"
        fi
    fi

    if command -v systemctl &>/dev/null; then
        systemctl disable --now nftables-trans.service >/dev/null 2>&1 || true
    fi

    if nft list table ip "$NFT_TABLE" &>/dev/null; then
        if nft delete table ip "$NFT_TABLE"; then
            echo -e "${GREEN}✅ 已删除 nftables 表: $NFT_TABLE${NC}"
        else
            echo -e "${YELLOW}⚠️ 删除 nftables 表失败，请手动检查: nft delete table ip $NFT_TABLE${NC}"
        fi
    else
        echo -e "${GREEN}✅ nftables 表不存在，跳过${NC}"
    fi

    rm -f "$RULES_FILE" "$RESTORE_SCRIPT" "$SYSTEMD_SERVICE" "$SYSCTL_FORWARD_FILE"

    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed nftables-trans.service >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}✅ 卸载完成${NC}"
    exit 0
}

# === 主程序 ===
init_env

while true; do
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Debian nftables 中转管理工具 (v1.3.1)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "  [1] 添加转发线路"
    echo "  [2] 查看当前规则"
    echo "  [3] 删除指定线路"
    echo "  [4] 清空重置所有规则"
    echo "  [5] 卸载脚本配置"
    echo "  [0] 退出脚本"
    echo -e "${BLUE}========================================${NC}"

    read -r -p "👉 请选择操作 [0-5]: " choice

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
        5)
            uninstall_tool
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
