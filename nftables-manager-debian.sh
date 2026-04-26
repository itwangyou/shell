#!/bin/bash
# ============================================
# Debian nftables 中转管理工具 (v1.1)
# 用法: bash <(curl -sL <URL>)
# =============================================

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
NFT_TABLE="nat-trans"
RULES_FILE="/etc/nftables-trans.nft"

# 1. 自动检测主出站网卡 (基于默认路由)
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
            echo -e "${RED}❌ 无效选择${NC}"; exit 1
        fi
        echo -e "${GREEN}✅ 已选择网卡: ${YELLOW}$MAIN_IFACE${NC}"
    fi
}

# 2. 初始化 nftables table 和 chain
init_nft_table() {
    if ! nft list table ip "$NFT_TABLE" &>/dev/null; then
        nft add table ip "$NFT_TABLE"
        nft add chain ip "$NFT_TABLE" prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
        nft add chain ip "$NFT_TABLE" postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
        echo -e "${GREEN}✅ 已初始化 nftables NAT 表${NC}"
    fi
}

# 3. 保存规则 (持久化)
save_rules() {
    mkdir -p /etc/nftables.d
    # 先写 destroy 指令 (不存在的 table 不报错)，确保 nft -f 加载时先删旧 table 再创建
    echo "destroy table ip $NFT_TABLE" > "$RULES_FILE"
    nft list table ip "$NFT_TABLE" >> "$RULES_FILE"
    echo -e "${GREEN}💾 规则已保存至 $RULES_FILE${NC}"
}

# 4. 环境初始化
init_env() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; fi

    if ! grep -qi debian /etc/os-release; then
        echo -e "${YELLOW}⚠️ 此脚本专为 Debian 设计，继续可能出错${NC}"
        read -p "👉 仍然继续？(y/n): " c; [[ ! "$c" =~ ^[Yy]$ ]] && exit 1
    fi

    echo -e "\n${YELLOW}📦 检查依赖...${NC}"
    apt update -qq

    # 检测并安装缺失的依赖
    local MISSING=""
    if ! command -v ip &>/dev/null; then
        MISSING="iproute2"
    fi
    [[ -n "$MISSING" ]] && echo -e "${YELLOW}   安装缺失依赖: $MISSING${NC}"
    if ! apt install -y $MISSING nftables; then
        echo -e "${RED}❌ 依赖安装失败${NC}"; exit 1
    fi

    # 开启内核转发
    sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf && \
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 检测主网卡
    detect_main_iface

    # 初始化 nftables table
    init_nft_table

    # 绑定 MASQUERADE 到主网卡 (如已存在则跳过)
    if ! nft list chain ip "$NFT_TABLE" postrouting 2>/dev/null | grep -q "oifname \"$MAIN_IFACE\" masquerade"; then
        nft add rule ip "$NFT_TABLE" postrouting oifname "$MAIN_IFACE" masquerade
        echo -e "${GREEN}✅ 已绑定 MASQUERADE 到 $MAIN_IFACE${NC}"
    else
        echo -e "${GREEN}✅ MASQUERADE 规则已存在，跳过${NC}"
    fi

    # 配置开机自动加载
    setup_autoload

    # 首次保存
    save_rules
}

# 5. 配置开机自动加载规则
setup_autoload() {
    # 确保 /etc/nftables.conf 包含 include 目录
    mkdir -p /etc/nftables.d
    if [[ -f /etc/nftables.conf ]] && ! grep -q '/etc/nftables.d' /etc/nftables.conf; then
        echo 'include "/etc/nftables.d/*.conf"' >> /etc/nftables.conf
    elif [[ ! -f /etc/nftables.conf ]]; then
        echo 'include "/etc/nftables.d/*.conf"' > /etc/nftables.conf
    fi

    # 创建软链接: 将规则文件纳入 include 范围
    ln -sf "$RULES_FILE" /etc/nftables.d/trans.conf

    # 启用 nftables 服务开机自启
    systemctl enable nftables 2>/dev/null
    echo -e "${GREEN}✅ 已配置开机自动加载规则 (systemd nftables.service)${NC}"
}

# 6. 添加线路
add_rule() {
    echo -e "\n${BLUE}--- 新增转发线路 ---${NC}"
    read -p "👉 本地监听端口: " LPORT
    [[ -z "$LPORT" ]] && { echo -e "${RED}❌ 端口不能为空${NC}"; return; }
    if ! [[ "$LPORT" =~ ^[0-9]+$ ]] || [[ "$LPORT" -lt 1 || "$LPORT" -gt 65535 ]]; then
        echo -e "${RED}❌ 端口无效，范围应为 1-65535${NC}"; return
    fi
    read -p "👉 后端服务器 IP: " BIP
    [[ -z "$BIP" ]] && { echo -e "${RED}❌ IP 不能为空${NC}"; return; }
    if ! [[ "$BIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}❌ IP 格式无效，请输入合法的 IPv4 地址${NC}"; return
    fi
    read -p "👉 后端服务器端口: " BPORT
    [[ -z "$BPORT" ]] && { echo -e "${RED}❌ 端口不能为空${NC}"; return; }
    if ! [[ "$BPORT" =~ ^[0-9]+$ ]] || [[ "$BPORT" -lt 1 || "$BPORT" -gt 65535 ]]; then
        echo -e "${RED}❌ 端口无效，范围应为 1-65535${NC}"; return
    fi

    read -p "👉 协议 [1]TCP+UDP(默认) [2]仅TCP [3]仅UDP (回车默认1): " proto
    proto=${proto:-1}

    # 检查重复规则（精确匹配，避免子串误判）
    local dup=0
    case $proto in
        1)
            local tcp_dup=0 udp_dup=0
            nft list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -qE "tcp dport ${LPORT} dnat to ${BIP}:${BPORT}([[:space:]]|$)" && tcp_dup=1
            nft list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -qE "udp dport ${LPORT} dnat to ${BIP}:${BPORT}([[:space:]]|$)" && udp_dup=1
            [[ $tcp_dup -eq 1 && $udp_dup -eq 1 ]] && dup=1
            ;;
        2)
            nft list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -qE "tcp dport ${LPORT} dnat to ${BIP}:${BPORT}([[:space:]]|$)" && dup=1
            ;;
        3)
            nft list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -qE "udp dport ${LPORT} dnat to ${BIP}:${BPORT}([[:space:]]|$)" && dup=1
            ;;
    esac
    if [[ $dup -eq 1 ]]; then
        echo -e "${YELLOW}⚠️ 该转发规则已存在，跳过${NC}"; return
    fi

    # 添加规则（检查执行结果）
    case $proto in
        1)
            nft add rule ip "$NFT_TABLE" prerouting tcp dport "$LPORT" dnat to "$BIP:$BPORT" || { echo -e "${RED}❌ 添加 TCP 规则失败${NC}"; return; }
            nft add rule ip "$NFT_TABLE" prerouting udp dport "$LPORT" dnat to "$BIP:$BPORT" || { echo -e "${RED}❌ 添加 UDP 规则失败${NC}"; return; }
            echo -e "${GREEN}✅ 已添加: TCP+UDP $LPORT → $BIP:$BPORT${NC}"
            ;;
        2)
            nft add rule ip "$NFT_TABLE" prerouting tcp dport "$LPORT" dnat to "$BIP:$BPORT" || { echo -e "${RED}❌ 添加 TCP 规则失败${NC}"; return; }
            echo -e "${GREEN}✅ 已添加: TCP $LPORT → $BIP:$BPORT${NC}"
            ;;
        3)
            nft add rule ip "$NFT_TABLE" prerouting udp dport "$LPORT" dnat to "$BIP:$BPORT" || { echo -e "${RED}❌ 添加 UDP 规则失败${NC}"; return; }
            echo -e "${GREEN}✅ 已添加: UDP $LPORT → $BIP:$BPORT${NC}"
            ;;
        *)
            echo -e "${RED}❌ 无效选择${NC}"; return
            ;;
    esac

    # 智能放行: 仅当系统已安装 ufw 时才执行
    if command -v ufw &>/dev/null; then
        local p
        case $proto in
            1) p="tcp udp" ;;
            2) p="tcp" ;;
            3) p="udp" ;;
        esac
        for pp in $p; do
            ufw allow "$LPORT/$pp" >/dev/null 2>&1 || true
        done
    fi

    save_rules
}

# 7. 查看规则
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

# 8. 删除线路
delete_rule() {
    list_rules
    echo ""
    read -p "👉 输入要删除的规则 handle 编号: " HANDLE
    [[ -z "$HANDLE" ]] && { echo -e "${RED}❌ handle 不能为空${NC}"; return; }

    # 检查 handle 是否属于 prerouting 链 (转发规则)
    if nft -a list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -qE "handle ${HANDLE}$"; then
        # 提取被删规则的端口和协议，用于清理 ufw
        local del_line
        del_line=$(nft -a list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -E "handle ${HANDLE}$")
        local del_port del_proto
        del_port=$(echo "$del_line" | grep -oP 'dport \K[0-9]+')
        del_proto=$(echo "$del_line" | grep -oP '^(tcp|udp)' | head -1)

        nft delete rule ip "$NFT_TABLE" prerouting handle "$HANDLE"

        # 清理 ufw 放行规则
        if command -v ufw &>/dev/null && [[ -n "$del_port" ]]; then
            if [[ "$del_proto" == "tcp" ]]; then
                ufw delete allow "$del_port/tcp" >/dev/null 2>&1 || true
            elif [[ "$del_proto" == "udp" ]]; then
                ufw delete allow "$del_port/udp" >/dev/null 2>&1 || true
            fi
        fi

        save_rules
        echo -e "${GREEN}✅ 已删除规则 handle #$HANDLE 并保存${NC}"
    # 检查 handle 是否属于 postrouting 链 (MASQUERADE)
    elif nft -a list chain ip "$NFT_TABLE" postrouting 2>/dev/null | grep -qE "handle ${HANDLE}$"; then
        echo -e "${YELLOW}⚠️ 该规则为 MASQUERADE 伪装规则，删除后可能导致回包失败${NC}"
        read -p "👉 确认删除？(y/n): " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            nft delete rule ip "$NFT_TABLE" postrouting handle "$HANDLE"
            save_rules
            echo -e "${GREEN}✅ 已删除规则 handle #$HANDLE 并保存${NC}"
        else
            echo -e "${YELLOW}已取消${NC}"
        fi
    else
        echo -e "${RED}❌ 未找到 handle #$HANDLE 对应的规则${NC}"
    fi
}

# 9. 清空重置
reset_rules() {
    echo -e "\n${RED}⚠️ 此操作将清空所有 NAT 转发规则 (MASQUERADE 保留)${NC}"
    read -p "👉 确认清空？(y/n): " c
    [[ ! "$c" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}已取消${NC}"; return; }

    nft flush chain ip "$NFT_TABLE" prerouting
    echo -e "${GREEN}✅ 已清空所有转发规则${NC}"
    save_rules
}

# === 主程序 ===
init_env

while true; do
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Debian nftables 中转管理工具 (v1.1)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "  [1] 添加转发线路"
    echo "  [2] 查看当前规则"
    echo "  [3] 删除指定线路"
    echo "  [4] 清空重置所有规则"
    echo "  [5] 退出脚本"
    echo -e "${BLUE}========================================${NC}"
    read -p "👉 请选择操作 [1-5]: " choice
    case $choice in
        1) add_rule ;;
        2) list_rules ;;
        3) delete_rule ;;
        4) reset_rules ;;
        5) echo -e "${GREEN}👋 再见${NC}"; break ;;
        *) echo -e "${RED}❌ 无效选择${NC}" ;;
    esac
done
