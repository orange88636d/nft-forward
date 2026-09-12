#!/usr/bin/env bash

CONFIG="/etc/nft-forward.conf"
TABLE="nft_forward"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
NC="\033[0m"

# ==========================
# 基础检查
# ==========================

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

sysctl -w net.ipv4.ip_forward=1 >/dev/null

# ==========================
# DNS 解析
# ==========================

resolve_domain() {
    local host="$1"

    # 如果本身就是 IPv4
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$host"
        return
    fi

    getent ahostsv4 "$host" 2>/dev/null \
        | awk '{print $1}' \
        | sort -u \
        | head -n1
}

# ==========================
# 重建 nft 规则
# ==========================

reload_rules() {

    nft delete table ip "$TABLE" 2>/dev/null

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

    while IFS='|' read -r id proto listen_port host target_port
    do
        [ -z "$id" ] && continue

        ip=$(resolve_domain "$host")

        if [ -z "$ip" ]; then
            echo -e "${RED}[失败]${NC} $host 无法解析"
            continue
        fi

        echo -e "${GREEN}[加载]${NC} $id $proto :$listen_port -> $host ($ip):$target_port"

        case "$proto" in

        tcp)
            nft add rule ip "$TABLE" prerouting \
                tcp dport "$listen_port" \
                dnat to "$ip:$target_port"

            nft add rule ip "$TABLE" output \
                ip daddr type local \
                tcp dport "$listen_port" \
                dnat to "$ip:$target_port"
            ;;

        udp)
            nft add rule ip "$TABLE" prerouting \
                udp dport "$listen_port" \
                dnat to "$ip:$target_port"

            nft add rule ip "$TABLE" output \
                ip daddr type local \
                udp dport "$listen_port" \
                dnat to "$ip:$target_port"
            ;;

        both)
            nft add rule ip "$TABLE" prerouting \
                tcp dport "$listen_port" \
                dnat to "$ip:$target_port"

            nft add rule ip "$TABLE" prerouting \
                udp dport "$listen_port" \
                dnat to "$ip:$target_port"

            nft add rule ip "$TABLE" output \
                ip daddr type local \
                tcp dport "$listen_port" \
                dnat to "$ip:$target_port"

            nft add rule ip "$TABLE" output \
                ip daddr type local \
                udp dport "$listen_port" \
                dnat to "$ip:$target_port"
            ;;

        esac

    done < "$CONFIG"

    nft add rule ip "$TABLE" postrouting masquerade

    echo
    echo -e "${GREEN}规则加载完成${NC}"
}

# ==========================
# 添加规则
# ==========================

add_rule() {

    echo
    read -rp "本机监听端口: " listen_port

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
            echo "协议错误"
            return
            ;;
    esac

    read -rp "目标域名/IP: " host
    read -rp "目标端口: " target_port

    ip=$(resolve_domain "$host")

    if [ -z "$ip" ]; then
        echo -e "${RED}域名解析失败: $host${NC}"
        return
    fi

    id=$(date +%s%N | tail -c 7)

    echo "${id}|${proto}|${listen_port}|${host}|${target_port}" >> "$CONFIG"

    echo
    echo -e "${GREEN}添加成功:${NC}"
    echo "$proto :$listen_port -> $host ($ip):$target_port"

    reload_rules
}

# ==========================
# 查看规则
# ==========================

list_rules() {

    echo
    echo "=============================================================="
    printf "%-8s %-8s %-10s %-25s %-10s\n" \
        "ID" "协议" "监听端口" "目标" "目标端口"
    echo "=============================================================="

    if [ ! -s "$CONFIG" ]; then
        echo "暂无规则"
        return
    fi

    while IFS='|' read -r id proto listen_port host target_port
    do
        printf "%-8s %-8s %-10s %-25s %-10s\n" \
            "$id" "$proto" "$listen_port" "$host" "$target_port"
    done < "$CONFIG"

    echo "=============================================================="
}

# ==========================
# 删除规则
# ==========================

delete_rule() {

    list_rules

    echo
    read -rp "请输入要删除的 ID: " delete_id

    if ! grep -q "^${delete_id}|" "$CONFIG"; then
        echo -e "${RED}没有找到 ID: $delete_id${NC}"
        return
    fi

    sed -i "/^${delete_id}|/d" "$CONFIG"

    echo -e "${GREEN}删除成功${NC}"

    reload_rules
}

# ==========================
# 显示 nft
# ==========================

show_nft() {

    echo
    nft list table ip "$TABLE" 2>/dev/null || {
        echo "当前还没有 nft 规则"
    }
}

# ==========================
# 菜单
# ==========================

menu() {

    while true
    do
        clear

        echo "================================="
        echo "        NFT 转发管理脚本"
        echo "================================="
        echo "1. 添加转发"
        echo "2. 删除转发"
        echo "3. 查看转发"
        echo "4. 刷新域名 IP"
        echo "5. 查看 nftables"
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
            read -rp "回车继续..."
            ;;

        5)
            show_nft
            read -rp "回车继续..."
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

# 第一次启动时加载已有规则
reload_rules >/dev/null 2>&1

menu
