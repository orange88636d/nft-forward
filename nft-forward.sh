#!/usr/bin/env bash
set -u

CONFIG="/etc/nft-forward.conf"
TABLE="nft_forward"
CRON_FILE="/etc/cron.d/nft-forward-refresh"
DEFAULT_INTERVAL=5

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行${NC}"
    exit 1
fi

if ! command -v nft >/dev/null 2>&1; then
    echo -e "${RED}没有安装 nftables${NC}"
    echo "Debian/Ubuntu:"
    echo "apt update && apt install -y nftables"
    exit 1
fi

touch "$CONFIG"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

resolve_domain() {
    local host="$1"

    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$host"
        return 0
    fi

    getent ahostsv4 "$host" 2>/dev/null \
        | awk '{print $1}' \
        | sort -u \
        | head -n1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

next_id() {
    local max=0 id
    while IFS='|' read -r id _; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [ "$id" -gt "$max" ] && max="$id"
    done < "$CONFIG"
    echo $((max + 1))
}

reload_rules() {
    nft delete table ip "$TABLE" 2>/dev/null || true
    nft add table ip "$TABLE"

    nft "add chain ip $TABLE prerouting {
        type nat hook prerouting priority dstnat;
        policy accept;
    }"

    nft "add chain ip $TABLE output {
        type nat hook output priority dstnat;
        policy accept;
    }"

    nft "add chain ip $TABLE postrouting {
        type nat hook postrouting priority srcnat;
        policy accept;
    }"

    while IFS='|' read -r id proto listen_port host target_port; do
        [ -z "${id:-}" ] && continue

        local_ip="$(resolve_domain "$host")"

        if [ -z "$local_ip" ]; then
            echo -e "${RED}[失败]${NC} ID=$id  $host 无法解析"
            continue
        fi

        echo -e "${GREEN}[加载]${NC} ID=$id  $proto :$listen_port -> $host ($local_ip):$target_port"

        case "$proto" in
            tcp)
                nft add rule ip "$TABLE" prerouting \
                    tcp dport "$listen_port" dnat to "$local_ip:$target_port"

                nft add rule ip "$TABLE" output \
                    ip daddr type local tcp dport "$listen_port" \
                    dnat to "$local_ip:$target_port"
                ;;
            udp)
                nft add rule ip "$TABLE" prerouting \
                    udp dport "$listen_port" dnat to "$local_ip:$target_port"

                nft add rule ip "$TABLE" output \
                    ip daddr type local udp dport "$listen_port" \
                    dnat to "$local_ip:$target_port"
                ;;
            both)
                nft add rule ip "$TABLE" prerouting \
                    tcp dport "$listen_port" dnat to "$local_ip:$target_port"

                nft add rule ip "$TABLE" prerouting \
                    udp dport "$listen_port" dnat to "$local_ip:$target_port"

                nft add rule ip "$TABLE" output \
                    ip daddr type local tcp dport "$listen_port" \
                    dnat to "$local_ip:$target_port"

                nft add rule ip "$TABLE" output \
                    ip daddr type local udp dport "$listen_port" \
                    dnat to "$local_ip:$target_port"
                ;;
            *)
                echo -e "${RED}[跳过]${NC} ID=$id 协议无效: $proto"
                ;;
        esac
    done < "$CONFIG"

    nft add rule ip "$TABLE" postrouting masquerade
}

add_rule() {
    echo
    read -rp "本机监听端口: " listen_port
    if ! valid_port "$listen_port"; then
        echo -e "${RED}端口无效${NC}"
        return
    fi

    echo
    echo "协议:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP + UDP"
    read -rp "请选择: " p

    case "$p" in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="both" ;;
        *)
            echo -e "${RED}协议错误${NC}"
            return
            ;;
    esac

    read -rp "目标域名/IP: " host
    read -rp "目标端口: " target_port

    if ! valid_port "$target_port"; then
        echo -e "${RED}目标端口无效${NC}"
        return
    fi

    ip="$(resolve_domain "$host")"
    if [ -z "$ip" ]; then
        echo -e "${RED}域名解析失败: $host${NC}"
        return
    fi

    id="$(next_id)"
    echo "${id}|${proto}|${listen_port}|${host}|${target_port}" >> "$CONFIG"

    echo
    echo -e "${GREEN}添加成功${NC}"
    echo "ID: $id"
    echo "$proto :$listen_port -> $host ($ip):$target_port"

    reload_rules
}

list_rules() {
    echo
    echo "======================================================================"
    printf "%-5s %-8s %-10s %-28s %-10s\n" \
        "ID" "协议" "监听端口" "目标" "目标端口"
    echo "======================================================================"

    if [ ! -s "$CONFIG" ]; then
        echo "暂无规则"
    else
        while IFS='|' read -r id proto listen_port host target_port; do
            printf "%-5s %-8s %-10s %-28s %-10s\n" \
                "$id" "$proto" "$listen_port" "$host" "$target_port"
        done < "$CONFIG"
    fi

    echo "======================================================================"
}

delete_rule() {
    list_rules
    echo
    echo -e "${YELLOW}提示：输入 99 删除全部规则${NC}"
    read -rp "请输入要删除的 ID: " delete_id

    if [ "$delete_id" = "99" ]; then
        echo
        echo -e "${RED}警告：这会删除全部转发规则。${NC}"
        read -rp "确认请输入 yes: " confirm
        if [ "$confirm" != "yes" ]; then
            echo "已取消"
            return
        fi

        : > "$CONFIG"
        reload_rules >/dev/null 2>&1
        echo -e "${GREEN}全部规则已删除${NC}"
        return
    fi

    if ! grep -q "^${delete_id}|" "$CONFIG"; then
        echo -e "${RED}没有找到 ID: $delete_id${NC}"
        return
    fi

    sed -i "/^${delete_id}|/d" "$CONFIG"
    reload_rules >/dev/null 2>&1
    echo -e "${GREEN}ID $delete_id 已删除${NC}"
}

show_nft() {
    echo
    nft list table ip "$TABLE" 2>/dev/null || echo "当前还没有 nft 规则"
}

cron_status() {
    if [ -f "$CRON_FILE" ]; then
        echo -e "${GREEN}已开启${NC}"
        echo "配置: $(grep -v '^#' "$CRON_FILE" | sed '/^[[:space:]]*$/d' | head -n1)"
    else
        echo -e "${YELLOW}未开启${NC}"
    fi
}

enable_cron_refresh() {
    echo
    read -rp "每隔多少分钟解析一次域名 [默认 ${DEFAULT_INTERVAL}]: " interval
    interval="${interval:-$DEFAULT_INTERVAL}"

    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 59 ]; then
        echo -e "${RED}请输入 1-59 之间的分钟数${NC}"
        return
    fi

    cat > "$CRON_FILE" <<EOF
# nft-forward 自动刷新域名解析
*/$interval * * * * root $SCRIPT_PATH --refresh >/dev/null 2>&1
EOF

    chmod 644 "$CRON_FILE"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true
    fi

    echo -e "${GREEN}已开启定时解析：每 ${interval} 分钟刷新一次${NC}"
}

disable_cron_refresh() {
    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        echo -e "${GREEN}定时解析已关闭${NC}"
    else
        echo "当前未开启定时解析"
    fi
}

timer_menu() {
    while true; do
        clear
        echo "================================="
        echo "        定时域名解析"
        echo "================================="
        echo -n "状态: "
        cron_status
        echo
        echo "1. 开启/修改定时解析"
        echo "2. 关闭定时解析"
        echo "3. 立即刷新一次"
        echo "0. 返回"
        echo "================================="
        read -rp "请选择: " choice

        case "$choice" in
            1)
                enable_cron_refresh
                read -rp "回车继续..."
                ;;
            2)
                disable_cron_refresh
                read -rp "回车继续..."
                ;;
            3)
                reload_rules
                echo -e "${GREEN}刷新完成${NC}"
                read -rp "回车继续..."
                ;;
            0)
                return
                ;;
            *)
                echo "输入错误"
                sleep 1
                ;;
        esac
    done
}

menu() {
    while true; do
        clear

        echo "================================="
        echo "        NFT 转发管理脚本"
        echo "================================="
        echo "1. 添加转发"
        echo "2. 删除转发"
        echo "3. 查看转发"
        echo "4. 立即刷新域名 IP"
        echo "5. 查看 nftables"
        echo "6. 定时解析域名"
        echo "0. 退出"
        echo "================================="

        read -rp "请选择: " choice

        case "$choice" in
            1)
                add_rule
                read -rp "回车继续..."
                ;;
            2)
                delete_rule
                read -rp "回车继续..."
                ;;
            3)
                list_rules
                read -rp "回车继续..."
                ;;
            4)
                reload_rules
                echo -e "${GREEN}刷新完成${NC}"
                read -rp "回车继续..."
                ;;
            5)
                show_nft
                read -rp "回车继续..."
                ;;
            6)
                timer_menu
                ;;
            0)
                exit 0
                ;;
            *)
                echo "输入错误"
                sleep 1
                ;;
        esac
    done
}

case "${1:-}" in
    --refresh)
        reload_rules >/dev/null 2>&1
        exit $?
        ;;
esac

reload_rules >/dev/null 2>&1 || true
menu
