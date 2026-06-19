#!/bin/bash

# 颜色变量
gl_kjlan='\033[96m'
gl_bai='\033[0m'

# 判断命令是否存在
has() { command -v "$1" >/dev/null 2>&1; }

# 通用 GET 请求，优先 curl，回退 wget
http_get() {
    local url="$1" timeout="${2:-5}"
    if has curl; then
        curl -sL --max-time "$timeout" "$url" 2>/dev/null
    elif has wget; then
        wget -qO- --timeout="$timeout" "$url" 2>/dev/null
    fi
}

# 获取 IP 地址
ip_address() {
    get_public_ip() {
        http_get "https://ipinfo.io/ip" 3 | tr -d '\n'
    }

    get_local_ip() {
        # 方法1：从路由表取
        local ip
        ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src /{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
        [[ -n "$ip" ]] && { echo "$ip"; return; }

        # 方法2：从 /proc/net/dev + /proc/net/route 推断
        local iface
        iface=$(awk 'NR>1 && $2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null | tr -d ':')
        if [[ -n "$iface" ]]; then
            ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
            [[ -n "$ip" ]] && { echo "$ip"; return; }
        fi

        # 方法3：hostname
        if has hostname; then
            hostname -I 2>/dev/null | awk '{print $1}'
        fi
    }

    # 只请求一次 ipinfo.io/json: ip/isp 供此函数判断, country/city 供 linux_info 复用
    ipinfo=$(http_get "https://ipinfo.io/json" 5)
    public_ip=$(echo "$ipinfo" | awk -F'"' '/"ip":/{print $4; exit}')
    [[ -z "$public_ip" ]] && public_ip=$(get_public_ip)   # json 失败时回退单独取 ip
    isp_info=$(echo "$ipinfo" | awk -F'"' '/"org":/{print $4; exit}')

    if echo "$isp_info" | grep -Eiq 'CHINANET|mobile|unicom|telecom'; then
        ipv4_address=$(get_local_ip)
    else
        ipv4_address="$public_ip"
    fi

    ipv6_address=$(http_get "https://v6.ipinfo.io/ip" 2 | tr -d '\n')
}

# 计算总接收/发送流量（基于 /proc/net/dev，统计 eth/ens/enp/eno 物理接口）
output_status() {
    output=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
        $1 ~ /^(eth|ens|enp|eno)[0-9]+/ {
            rx_total += $2
            tx_total += $10
        }
        END {
            rx_units = "Bytes";
            tx_units = "Bytes";
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "K"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "M"; }
            if (rx_total > 1024) { rx_total /= 1024; rx_units = "G"; }

            if (tx_total > 1024) { tx_total /= 1024; tx_units = "K"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "M"; }
            if (tx_total > 1024) { tx_total /= 1024; tx_units = "G"; }

            printf("%.2f%s %.2f%s\n", rx_total, rx_units, tx_total, tx_units);
        }' /proc/net/dev)

    rx=$(echo "$output" | awk '{print $1}')
    tx=$(echo "$output" | awk '{print $2}')
}

# 获取时区
current_timezone() {
    if [[ -f /etc/alpine-release ]] || grep -q 'Alpine' /etc/issue 2>/dev/null; then
        date +"%Z %z"
    elif has timedatectl; then
        timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}'
    else
        date +"%Z %z"
    fi
}

# 从 /proc/net/tcp(udp) 统计连接数（不依赖 ss）
count_connections() {
    local proto="$1"
    local f="/proc/net/${proto}"
    [[ -f "$f" ]] || { echo 0; return; }
    awk 'NR>1 {count++} END{print count+0}' "$f"
}

# 读取 sysctl 值，无 sysctl 命令时直接读 /proc/sys
read_sysctl() {
    local key="$1"
    # 把 "a.b.c" 转成 "a/b/c": 用 ${key//./\/} (注意不是 /., 旧写法多塞了点导致路径失效)
    local path="/proc/sys/${key//./\/}"
    if has sysctl; then
        sysctl -n "$key" 2>/dev/null
    elif [[ -f "$path" ]]; then
        cat "$path" 2>/dev/null
    fi
}

# 系统信息查询主函数
linux_info() {
    clear
    echo -e "${gl_kjlan}正在查询系统信息……${gl_bai}"

    ip_address

    local cpu_info
    if has lscpu; then
        cpu_info=$(lscpu | awk -F': +' '/Model name:/ {print $2; exit}')
    else
        cpu_info=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)
    fi

    local cpu_usage_percent
    cpu_usage_percent=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else {d=t-t1; if (d>0) printf "%.0f\n", (($2+$4-u1) * 100 / d); else print 0}}' \
        <(grep '^cpu ' /proc/stat) <(sleep 1; grep '^cpu ' /proc/stat))

    local cpu_cores=$(nproc)

    local cpu_freq
    cpu_freq=$(awk '/^cpu MHz/{printf "%.1f GHz\n", $4/1000; exit}' /proc/cpuinfo)

    local mem_info=$(free -b | awk 'NR==2{printf "%.2f/%.2fM (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')

    local disk_info
    # 参考 kejilion: 按挂载点 "/" 匹配(而非设备名 /dev/sd*), ZFS/Incus/overlay 均可识别
    # 从右往左取列以兼容 BusyBox 长设备名折行: 已用=$(NF-3) 总量=$(NF-4) 使用率=$(NF-1)
    disk_info=$(df -h 2>/dev/null | awk '$NF=="/"{printf "%s/%s (%s)", $(NF-3), $(NF-4), $(NF-1)}')
    [[ -z "$disk_info" ]] && disk_info="未知"

    local country city isp_info
    if [[ -n "$ipinfo" ]]; then      # 复用 ip_address() 已取的全局 ipinfo, 不再重复请求
        country=$(echo "$ipinfo" | awk -F'"' '/"country":/ {print $4; exit}')
        city=$(echo "$ipinfo" | awk -F'"' '/"city":/ {print $4; exit}')
        isp_info=$(echo "$ipinfo" | awk -F'"' '/"org":/ {print $4; exit}')
    fi

    local load=$(awk '{print $1, $2, $3}' /proc/loadavg)
    local dns_addresses=$(awk '/^nameserver/{printf "%s ", $2} END {print ""}' /etc/resolv.conf)

    local cpu_arch=$(uname -m)
    local hostname=$(uname -n)
    local kernel_version=$(uname -r)

    local congestion_algorithm=$(read_sysctl "net.ipv4.tcp_congestion_control")
    local queue_algorithm=$(read_sysctl "net.core.default_qdisc")

    local os_info=$(grep PRETTY_NAME /etc/os-release | cut -d '=' -f2 | tr -d '"')

    output_status

    local current_time=$(date "+%Y-%m-%d %I:%M %p")

    local swap_info=$(free -m | awk '/^Swap:/{used=$3; total=$2; if (total == 0) {percentage=0} else {percentage=used*100/total}; printf "%dM/%dM (%d%%)", used, total, percentage}')

    local runtime=$(awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}' /proc/uptime)

    local timezone=$(current_timezone)

    local tcp_count udp_count
    if has ss; then
        tcp_count=$(ss -tH | wc -l)
        udp_count=$(ss -uH | wc -l)
    else
        tcp_count=$(count_connections "tcp")
        udp_count=$(count_connections "udp")
    fi

    clear
    echo -e "系统信息查询"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}主机名:         ${gl_bai}$hostname"
    echo -e "${gl_kjlan}系统版本:       ${gl_bai}$os_info"
    echo -e "${gl_kjlan}Linux版本:      ${gl_bai}$kernel_version"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}CPU架构:        ${gl_bai}$cpu_arch"
    echo -e "${gl_kjlan}CPU型号:        ${gl_bai}${cpu_info:-未知}"
    echo -e "${gl_kjlan}CPU核心数:      ${gl_bai}$cpu_cores"
    echo -e "${gl_kjlan}CPU频率:        ${gl_bai}${cpu_freq:-未知}"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}CPU占用:        ${gl_bai}${cpu_usage_percent}%"
    echo -e "${gl_kjlan}系统负载:       ${gl_bai}$load"
    echo -e "${gl_kjlan}TCP|UDP连接数:  ${gl_bai}$tcp_count|$udp_count"
    echo -e "${gl_kjlan}物理内存:       ${gl_bai}$mem_info"
    echo -e "${gl_kjlan}虚拟内存:       ${gl_bai}$swap_info"
    echo -e "${gl_kjlan}硬盘占用:       ${gl_bai}$disk_info"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}总接收:         ${gl_bai}${rx:-0B}"
    echo -e "${gl_kjlan}总发送:         ${gl_bai}${tx:-0B}"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}网络算法:       ${gl_bai}${congestion_algorithm:-未知} ${queue_algorithm}"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}运营商:         ${gl_bai}${isp_info:-未知}"
    if [ -n "$ipv4_address" ]; then
        echo -e "${gl_kjlan}IPv4地址:       ${gl_bai}$ipv4_address"
    fi
    if [ -n "$ipv6_address" ]; then
        echo -e "${gl_kjlan}IPv6地址:       ${gl_bai}$ipv6_address"
    fi
    echo -e "${gl_kjlan}DNS地址:        ${gl_bai}$dns_addresses"
    echo -e "${gl_kjlan}地理位置:       ${gl_bai}${country:-未知} ${city}"
    echo -e "${gl_kjlan}系统时间:       ${gl_bai}$timezone $current_time"
    echo -e "${gl_kjlan}-------------"
    echo -e "${gl_kjlan}运行时长:       ${gl_bai}$runtime"
    echo
}

# 运行
linux_info
