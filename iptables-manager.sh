#!/bin/bash
# ==========================================
# Debian nftables 透明中转管理脚本 (v1.0)
# 功能: 自动检测主网卡 / 添加 / 查看 / 删除 / 重置 NAT 转发
# 系统: Debian 10/11/12 (需 root 权限)
# 说明: 使用原生 nftables 语法，Debian 10+ 推荐方案
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MAIN_IFACE=""
NFT_TABLE="nat-trans"
RULES_FILE="/etc/nftables-trans.nft"

# 1. 自动检测主出站网卡 (基于默认路由)
detect_main_iface() {
    local ifaces
    ifaces=$(ip -4 route show default | awk '{print $5}' | sort -u)

    if [ -z "$ifaces" ]; then
        echo -e "${RED}❌ 未检测到默认路由网卡，请检查网络配置${NC}"
        exit 1
    fi

    local count
    count=$(echo "$ifaces" | wc -l)
    if [ "$count" -eq 1 ]; then
        MAIN_IFACE="$ifaces"
        echo -e "${GREEN}✅ 检测到主出站网卡: ${YELLOW}$MAIN_IFACE${NC}"
    else
        echo -e "${YELLOW}⚠️ 检测到多个默认路由网卡:${NC}"
        echo "$ifaces" | cat -n
        read -p "👉 请选择 [1-$count]: " choice
        MAIN_IFACE=$(echo "$ifaces" | sed -n "${choice}p")
        if [ -z "$MAIN_IFACE" ]; then
            echo -e "${RED}❌ 无效选择${NC}"; exit 1
        fi
        echo -e "${GREEN}✅ 已选择网卡: ${YELLOW}$MAIN_IFACE${NC}"
    fi
}

# 2. 初始化 nftables table 和 chain
init_nft_table() {
    # 创建 table (已存在则跳过)
    if ! nft list tables ip 2>/dev/null | grep -qw "$NFT_TABLE"; then
        nft add table ip "$NFT_TABLE"
    fi
    # 创建 prerouting chain (已存在则跳过)
    if ! nft list chain ip "$NFT_TABLE" prerouting >/dev/null 2>&1; then
        nft add chain ip "$NFT_TABLE" prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'
    fi
    # 创建 postrouting chain (已存在则跳过)
    if ! nft list chain ip "$NFT_TABLE" postrouting >/dev/null 2>&1; then
        nft add chain ip "$NFT_TABLE" postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
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
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; fi

    # 首次运行：安装脚本到系统路径，后续直接 nft-manager 即可使用
    local INSTALL_PATH="/usr/local/bin/nft-manager"
    local SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    if [[ "$SCRIPT_PATH" != "$INSTALL_PATH" ]]; then
        cp "$0" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo -e "${GREEN}✅ 脚本已安装至 $INSTALL_PATH${NC}"
        echo -e "${YELLOW}   后续可直接运行: nft-manager${NC}\n"
    fi
    if ! grep -qi debian /etc/os-release; then
        echo -e "${YELLOW}⚠️ 非 Debian 系统，可能不兼容${NC}"
        read -p "继续？(y/n): " c; [[ ! "$c" =~ ^[Yy]$ ]] && exit 1
    fi

    echo -e "\n${YELLOW}📦 检查依赖...${NC}"
    apt update -qq

    # 检测并安装缺失的依赖
    MISSING=""
    if ! command -v ip &>/dev/null; then
        MISSING="iproute2"
    fi
    [ -n "$MISSING" ] && echo -e "${YELLOW}   安装缺失依赖: $MISSING${NC}"
    if ! apt install -y $MISSING nftables; then
        echo -e "${RED}❌ 依赖安装失败，请检查网络或软件源后重试${NC}"
        exit 1
    fi

    if ! command -v nft &>/dev/null; then
        echo -e "${RED}❌ nft 命令不可用，请检查系统环境${NC}"
        exit 1
    fi

    if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        grep -qF 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        echo -e "${GREEN}✅ 已开启内核 IP 转发${NC}"
    fi

    # 检测主网卡
    detect_main_iface

    # 初始化 nftables table 和 chain
    init_nft_table

    # 绑定 MASQUERADE 到主网卡 (全局仅需一条)
    if ! nft list chain ip "$NFT_TABLE" postrouting 2>/dev/null | grep -q "oifname.*$MAIN_IFACE.*masquerade"; then
        nft add rule ip "$NFT_TABLE" postrouting oifname "$MAIN_IFACE" masquerade
        echo -e "${GREEN}✅ 已绑定 MASQUERADE 到 $MAIN_IFACE${NC}"
    else
        echo -e "${GREEN}✅ MASQUERADE 已正确绑定至 $MAIN_IFACE${NC}"
    fi

    # 设置开机自动加载规则
    setup_autoload
}

# 5. 设置开机自动加载规则
setup_autoload() {
    # Debian 通过 systemd 服务加载 nftables 规则
    # 配置 /etc/nftables.conf 引入我们的规则文件
    if [ ! -f /etc/nftables.d/trans-include.conf ]; then
        mkdir -p /etc/nftables.d
        echo "include \"$RULES_FILE\"" > /etc/nftables.d/trans-include.conf

        # 确保 /etc/nftables.conf 引入了 nftables.d 目录
        if ! grep -q '/etc/nftables.d' /etc/nftables.conf 2>/dev/null; then
            echo 'include "/etc/nftables.d/*.conf"' >> /etc/nftables.conf
        fi

        # 启用 nftables 服务开机自启
        systemctl enable nftables 2>/dev/null || true
        echo -e "${GREEN}✅ 已配置开机自动加载规则 (systemd nftables.service)${NC}"
    else
        echo -e "${GREEN}✅ 开机自动加载已配置${NC}"
    fi
}

# 6. 添加线路
add_rule() {
    echo -e "\n${BLUE}--- 新增转发线路 ---${NC}"
    read -p "👉 本地监听端口: " LPORT
    [[ -z "$LPORT" ]] && { echo -e "${RED}❌ 端口不能为空${NC}"; return; }
    read -p "👉 后端服务器 IP: " BIP
    [[ -z "$BIP" ]] && { echo -e "${RED}❌ IP 不能为空${NC}"; return; }
    read -p "👉 后端服务器端口: " BPORT
    [[ -z "$BPORT" ]] && { echo -e "${RED}❌ 端口不能为空${NC}"; return; }

    read -p "👉 协议 [1]TCP+UDP(默认) [2]仅TCP [3]仅UDP (回车默认1): " PCHOICE
    case ${PCHOICE:-1} in
        1) PROTOS="tcp udp" ;; 2) PROTOS="tcp" ;; 3) PROTOS="udp" ;; *) PROTOS="tcp udp" ;;
    esac

    for p in $PROTOS; do
        # 检查规则是否已存在
        if ! nft list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -q "${p}.*dport.*${LPORT}.*dnat to ${BIP}:${BPORT}"; then
            nft add rule ip "$NFT_TABLE" prerouting "$p" dport "$LPORT" dnat to "$BIP:$BPORT"
            # 智能放行: 仅当系统已安装 ufw 时才执行，避免报错
            if command -v ufw &>/dev/null; then
                ufw allow "$LPORT/$p" >/dev/null 2>&1 || true
            fi
            echo -e "  ${GREEN}✅ 已添加 $p: $LPORT → $BIP:$BPORT${NC}"
        else
            echo -e "  ${YELLOW}⚠️ 规则已存在: $p $LPORT${NC}"
        fi
    done
    save_rules
}

# 7. 查看规则
list_rules() {
    echo -e "\n${BLUE}--- 当前 NAT 转发规则 ---${NC}"
    PREROUTING=$(nft -a list chain ip "$NFT_TABLE" prerouting 2>/dev/null)
    if [ -z "$PREROUTING" ]; then
        echo -e "${RED}❌ 读取转发规则失败${NC}"
    else
        DNAT_RULES=$(echo "$PREROUTING" | grep "dnat to")
        if [ -z "$DNAT_RULES" ]; then
            echo -e "${YELLOW}暂无转发规则${NC}"
        else
            echo "$DNAT_RULES"
        fi
    fi
    echo -e "\n${BLUE}--- 回包伪装规则 ---${NC}"
    POSTROUTING=$(nft -a list chain ip "$NFT_TABLE" postrouting 2>/dev/null)
    if [ -z "$POSTROUTING" ]; then
        echo -e "${RED}❌ 读取伪装规则失败${NC}"
    else
        MASK_RULES=$(echo "$POSTROUTING" | grep "masquerade")
        if [ -z "$MASK_RULES" ]; then
            echo -e "${YELLOW}暂无伪装规则${NC}"
        else
            echo "$MASK_RULES"
        fi
    fi
}

# 8. 删除线路
delete_rule() {
    list_rules
    echo -e "\n${YELLOW}提示: 请输入规则对应的 handle 编号进行删除${NC}"
    read -p "👉 输入要删除的规则 handle (输入 q 取消): " HANDLE
    [[ "$HANDLE" == "q" ]] && return
    if [[ ! "$HANDLE" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ 请输入有效数字${NC}"; return
    fi

    # 检查 handle 是否属于 prerouting 链 (转发规则)
    if nft -a list chain ip "$NFT_TABLE" prerouting 2>/dev/null | grep -qE "handle ${HANDLE}$"; then
        nft delete rule ip "$NFT_TABLE" prerouting handle "$HANDLE"
        save_rules
        echo -e "${GREEN}✅ 已删除规则 handle #$HANDLE 并保存${NC}"
    # 检查 handle 是否属于 postrouting 链 (MASQUERADE)
    elif nft -a list chain ip "$NFT_TABLE" postrouting 2>/dev/null | grep -qE "handle ${HANDLE}$"; then
        echo -e "${YELLOW}⚠️ 该 handle 属于 postrouting 链 (MASQUERADE), 删除可能影响所有转发${NC}"
        read -p "仍然删除？(y/n): " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            nft delete rule ip "$NFT_TABLE" postrouting handle "$HANDLE"
            save_rules
            echo -e "${GREEN}✅ 已删除规则 handle #$HANDLE 并保存${NC}"
        else
            echo -e "${YELLOW}已取消${NC}"
        fi
    else
        echo -e "${RED}❌ 未找到 handle #$HANDLE，请检查编号是否正确${NC}"
    fi
}

# 9. 清空重置
reset_rules() {
    echo -e "\n${RED}⚠️ 警告: 这将清空所有 NAT 转发规则 (MASQUERADE 会重新绑定)${NC}"
    read -p "确定继续？(yes/no): " CONFIRM
    if [ "$CONFIRM" == "yes" ]; then
        nft flush chain ip "$NFT_TABLE" prerouting 2>/dev/null
        nft flush chain ip "$NFT_TABLE" postrouting 2>/dev/null
        # 重新绑定 MASQUERADE
        nft add rule ip "$NFT_TABLE" postrouting oifname "$MAIN_IFACE" masquerade
        save_rules
        echo -e "${GREEN}✅ 已清空转发规则并重置基础环境${NC}"
    else
        echo -e "${YELLOW}已取消操作${NC}"
    fi
}

# 主循环
main() {
    init_env
    while true; do
        echo -e "\n${GREEN}========================================${NC}"
        echo -e "${GREEN}  Debian nftables 中转管理工具 (v1.0)${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo -e "  [1] 添加转发线路"
        echo -e "  [2] 查看当前规则"
        echo -e "  [3] 删除指定线路"
        echo -e "  [4] 清空重置所有规则"
        echo -e "  [5] 退出脚本"
        echo -e "${GREEN}========================================${NC}"
        read -p "👉 请选择操作 [1-5]: " OPT
        case $OPT in
            1) add_rule ;;
            2) list_rules ;;
            3) delete_rule ;;
            4) reset_rules ;;
            5) echo -e "${GREEN}👋 再见${NC}"; exit 0 ;;
            *) echo -e "${RED}❌ 无效输入${NC}" ;;
        esac
    done
}

main
