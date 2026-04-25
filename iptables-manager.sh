#!/bin/bash
# ==========================================
# Debian iptables 透明中转管理脚本 (v2.1 修复版)
# 功能: 自动检测主网卡 / 添加 / 查看 / 删除 / 重置 NAT 转发
# 修复: 移除 ufw 强依赖，解决 Debian 12 包冲突问题
# 系统: Debian 10/11/12 (需 root 权限)
# ==========================================

# 强制补全标准 PATH，防止最小化系统或 curl 执行时找不到 sbin 命令
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MAIN_IFACE=""

# 1. 自动检测主出站网卡 (基于默认路由)
detect_main_iface() {
    MAIN_IFACE=$(ip -4 route show default | awk '{print $5}' | head -n 1)
    if [ -z "$MAIN_IFACE" ]; then
        echo -e "${RED}❌ 未检测到默认路由网卡，请检查网络配置${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ 检测到主出站网卡: ${YELLOW}$MAIN_IFACE${NC}"
}

# 2. 环境初始化
init_env() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}❌ 请使用 root 运行${NC}"; exit 1; fi
    if ! grep -qi debian /etc/os-release; then
        echo -e "${YELLOW}⚠️ 非 Debian 系统，可能不兼容${NC}"
        read -p "继续？(y/n): " c; [[ ! "$c" =~ ^[Yy]$ ]] && exit 1
    fi

    echo -e "\n${YELLOW}📦 检查依赖...${NC}"
    apt update -qq
    # 修复: 移除 ufw 强依赖，避免 Debian 12 包冲突 (Breaks: netfilter-persistent)
    # 云主机端口放行请以控制台安全组为准，本地 ufw 非必需
    if ! apt install -y iptables netfilter-persistent; then
        echo -e "${RED}❌ 依赖安装失败，请检查网络或软件源后重试${NC}"
        exit 1
    fi

    # 验证 iptables 命令是否可用
    if ! command -v iptables &>/dev/null; then
        echo -e "${RED}❌ iptables 命令不可用，请检查系统环境${NC}"
        exit 1
    fi

    if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        grep -qF 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        echo -e "${GREEN}✅ 已开启内核 IP 转发${NC}"
    fi

    # 检测主网卡
    detect_main_iface

    # 清理旧版无绑定网卡的 MASQUERADE 规则 (防冲突)
    iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true

    # 绑定 MASQUERADE 到主网卡 (全局仅需一条)
    if ! iptables -t nat -C POSTROUTING -o "$MAIN_IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$MAIN_IFACE" -j MASQUERADE
        echo -e "${GREEN}✅ 已绑定 MASQUERADE 到 $MAIN_IFACE${NC}"
    else
        echo -e "${GREEN}✅ MASQUERADE 已正确绑定至 $MAIN_IFACE${NC}"
    fi
}

# 3. 添加线路
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
        if ! iptables -t nat -C PREROUTING -p $p --dport "$LPORT" -j DNAT --to-destination "$BIP:$BPORT" 2>/dev/null; then
            iptables -t nat -A PREROUTING -p $p --dport "$LPORT" -j DNAT --to-destination "$BIP:$BPORT"
            # 智能放行: 仅当系统已安装 ufw 时才执行，避免报错
            if command -v ufw &>/dev/null; then
                ufw allow "$LPORT/$p" >/dev/null 2>&1 || true
            fi
            echo -e "  ${GREEN}✅ 已添加 $p: $LPORT → $BIP:$BPORT${NC}"
        else
            echo -e "  ${YELLOW}⚠️ 规则已存在: $p $LPORT${NC}"
        fi
    done
    netfilter-persistent save >/dev/null 2>&1
    echo -e "${GREEN}💾 规则已保存${NC}"
}

# 4. 查看规则
list_rules() {
    echo -e "\n${BLUE}--- 当前 NAT 转发规则 ---${NC}"
    iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E "DNAT|num"
    if [ $? -ne 0 ]; then echo -e "${YELLOW}暂无转发规则${NC}"; fi
    echo -e "\n${BLUE}--- 回包伪装规则 ---${NC}"
    iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE
}

# 5. 删除线路
delete_rule() {
    list_rules
    echo -e "\n${YELLOW}提示: 删除后行号会变化，建议删完一条后重新查看${NC}"
    read -p "👉 输入要删除的规则行号 (输入 q 取消): " NUM
    [[ "$NUM" == "q" ]] && return
    if [[ "$NUM" =~ ^[0-9]+$ ]]; then
        iptables -t nat -D PREROUTING $NUM 2>/dev/null
        if [ $? -eq 0 ]; then
            netfilter-persistent save >/dev/null 2>&1
            echo -e "${GREEN}✅ 已删除规则 #$NUM 并保存${NC}"
        else
            echo -e "${RED}❌ 删除失败，请检查行号是否正确${NC}"
        fi
    else
        echo -e "${RED}❌ 请输入有效数字${NC}"
    fi
}

# 6. 清空重置
reset_rules() {
    echo -e "\n${RED}⚠️ 警告: 这将清空所有 NAT 转发规则 (MASQUERADE 会重新绑定)${NC}"
    read -p "确定继续？(yes/no): " CONFIRM
    if [ "$CONFIRM" == "yes" ]; then
        iptables -t nat -F PREROUTING
        iptables -t nat -F POSTROUTING
        # 重新检测网卡并绑定 MASQUERADE
        detect_main_iface
        iptables -t nat -A POSTROUTING -o "$MAIN_IFACE" -j MASQUERADE
        netfilter-persistent save >/dev/null 2>&1
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
        echo -e "${GREEN}  Debian iptables 中转管理工具 (v2.1)${NC}"
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
