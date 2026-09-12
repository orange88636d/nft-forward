#!/usr/bin/env bash
set -u

CONFIG="/etc/nft-forward.conf"
TABLE="nft_forward"
TABLE6="nft_forward6"
CRON_MARK_BEGIN="# BEGIN NFT-FORWARD"
CRON_MARK_END="# END NFT-FORWARD"
DEFAULT_INTERVAL=5
DNS_TIMEOUT=5
FALLBACK_DNS="1.1.1.1"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
NC="\033[0m"

OS_ID="unknown"
OS_NAME="Unknown Linux"
PKG_MANAGER=""
CRON_SERVICE=""

die() {
    echo -e "${RED}$*${NC}"
    exit 1
}

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-${NAME:-Unknown Linux}}"
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint|kali|raspbian)
            PKG_MANAGER="apt"
            CRON_SERVICE="cron"
            ;;
        alpine)
            PKG_MANAGER="apk"
            CRON_SERVICE="crond"
            ;;
        centos|rhel|rocky|almalinux|fedora|ol)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            CRON_SERVICE="crond"
            ;;
        arch|manjaro)
            PKG_MANAGER="pacman"
            CRON_SERVICE="cronie"
            ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                PKG_MANAGER="apt"
                CRON_SERVICE="cron"
            elif command -v apk >/dev/null 2>&1; then
                PKG_MANAGER="apk"
                CRON_SERVICE="crond"
            elif command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
                CRON_SERVICE="crond"
            elif command -v yum >/dev/null 2>&1; then
                PKG_MANAGER="yum"
                CRON_SERVICE="crond"
            elif command -v pacman >/dev/null 2>&1; then
                PKG_MANAGER="pacman"
                CRON_SERVICE="cronie"
            fi
            ;;
    esac
}

install_packages() {
    local packages=("$@")

    case "$PKG_MANAGER" in
        apt)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            ;;
        apk)
            apk add --no-cache "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        yum)
            yum install -y "${packages[@]}"
            ;;
        pacman)
            pacman -Sy --noconfirm "${packages[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_cron_service() {
    if command -v systemctl >/dev/null 2>&1; then
        case "$OS_ID" in
            debian|ubuntu|linuxmint|kali|raspbian)
                systemctl enable --now cron >/dev/null 2>&1 || true
                ;;
            *)
                systemctl enable --now crond >/dev/null 2>&1 || \
                systemctl enable --now cronie >/dev/null 2>&1 || true
                ;;
        esac
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
    fi
}

preflight_check() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行此脚本"

    detect_os

    echo "================================="
    echo "       运行环境检测"
    echo "================================="
    echo -e "系统: ${CYAN}${OS_NAME}${NC}"
    echo "系统 ID: $OS_ID"
    echo "包管理器: ${PKG_MANAGER:-未识别}"
    echo

    local missing=()
    local need_nft=0
    local need_cron=0
    local need_dns=0

    if command -v nft >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] nftables"
    else
        echo -e "[${RED}缺少${NC}] nftables"
        need_nft=1
    fi

    if command -v crontab >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] crontab"
    else
        echo -e "[${YELLOW}缺少${NC}] crontab（定时解析需要）"
        need_cron=1
    fi

    if command -v getent >/dev/null 2>&1 || \
       command -v nslookup >/dev/null 2>&1 || \
       command -v host >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] DNS 解析工具"
    else
        echo -e "[${RED}缺少${NC}] DNS 解析工具"
        need_dns=1
    fi

    if command -v sysctl >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] sysctl"
    else
        echo -e "[${YELLOW}警告${NC}] 未发现 sysctl"
    fi

    if command -v timeout >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] timeout"
    else
        echo -e "[${RED}缺少${NC}] timeout（DNS 防卡死需要）"
        case "$PKG_MANAGER" in
            apt|dnf|yum) missing+=("coreutils") ;;
            apk) missing+=("coreutils") ;;
            pacman) missing+=("coreutils") ;;
        esac
    fi

    if [ "$need_nft" -eq 0 ] && [ "$need_cron" -eq 0 ] && [ "$need_dns" -eq 0 ] && command -v timeout >/dev/null 2>&1; then
        echo
        echo -e "${GREEN}环境检测通过${NC}"
        sleep 1
        return 0
    fi

    [ -n "$PKG_MANAGER" ] || die "无法识别包管理器，请手动安装 nftables、cron/cronie/dcron 和 DNS 工具"

    case "$PKG_MANAGER" in
        apt)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_cron" -eq 1 ] && missing+=("cron")
            # getent 通常由 libc-bin 提供；多数 Debian 已自带
            [ "$need_dns" -eq 1 ] && missing+=("dnsutils")
            ;;
        apk)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_cron" -eq 1 ] && missing+=("dcron")
            # Alpine BusyBox 通常自带 nslookup；缺少时装 bind-tools
            [ "$need_dns" -eq 1 ] && missing+=("bind-tools")
            ;;
        dnf|yum)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_cron" -eq 1 ] && missing+=("cronie")
            [ "$need_dns" -eq 1 ] && missing+=("bind-utils")
            ;;
        pacman)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_cron" -eq 1 ] && missing+=("cronie")
            [ "$need_dns" -eq 1 ] && missing+=("bind")
            ;;
    esac

    echo
    echo "需要安装:"
    printf '  - %s\n' "${missing[@]}"
    echo
    read -rp "是否自动安装缺少的软件包？[Y/n]: " answer
    answer="${answer:-Y}"

    case "$answer" in
        y|Y|yes|YES)
            install_packages "${missing[@]}" || die "自动安装失败，请手动安装后重新运行"
            ;;
        *)
            die "缺少必要组件，已退出"
            ;;
    esac

    ensure_cron_service

    command -v nft >/dev/null 2>&1 || die "nftables 安装后仍不可用"
    command -v timeout >/dev/null 2>&1 || die "timeout 安装后仍不可用"
    if ! command -v getent >/dev/null 2>&1 && \
       ! command -v nslookup >/dev/null 2>&1 && \
       ! command -v host >/dev/null 2>&1; then
        die "DNS 解析工具安装后仍不可用"
    fi

    echo
    echo -e "${GREEN}依赖检查完成${NC}"
    sleep 1
}

enable_forwarding() {
    if command -v sysctl >/dev/null 2>&1; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    else
        [ -w /proc/sys/net/ipv4/ip_forward ] && \
            echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
        [ -w /proc/sys/net/ipv6/conf/all/forwarding ] && \
            echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
    fi
}

trim_target() {
    local value="$1"

    # 去除首尾空白
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    # 用户可以输入 [2001:db8::1]，内部统一保存为裸 IPv6
    if [[ "$value" == \[*\] ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

valid_ipv4() {
    local ip="$1"
    local a b c d extra

    IFS='.' read -r a b c d extra <<< "$ip"

    [ -z "${extra:-}" ] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

valid_ipv6() {
    local ip="$1"

    # 先做字符级防御，禁止 zone id、CIDR、空格和命令字符。
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1

    # 使用 nft 自身解析器做最终语法校验，避免用不完整的 IPv6 正则。
    printf 'table ip6 __nftfw_validate { chain prerouting { type nat hook prerouting priority -100; tcp dport 1 dnat to [%s]:1; } }\n' "$ip" \
        | nft -c -f - >/dev/null 2>&1
}

valid_domain() {
    local domain="$1"
    local label

    [ -n "$domain" ] || return 1
    [ "${#domain}" -le 253 ] || return 1

    # 只允许普通 ASCII/Punycode 主机名字符；拒绝 | ; $ 空格 / 等注入字符。
    [[ "$domain" =~ ^[A-Za-z0-9.-]+\.?$ ]] || return 1

    # 纯数字或纯数字+点不能当域名绕过 IP 校验，例如 5555 / 999.1。
    [[ "$domain" =~ [A-Za-z-] ]] || return 1

    domain="${domain%.}"
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

    IFS='.' read -ra labels <<< "$domain"
    for label in "${labels[@]}"; do
        [ -n "$label" ] || return 1
        [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

safe_target_ip() {
    local family="$1"
    local ip="$2"

    if [ "$family" = "4" ]; then
        # 未指定 / 广播 / 组播不应作为 DNAT 目标。
        [ "$ip" != "0.0.0.0" ] || return 1
        [ "$ip" != "255.255.255.255" ] || return 1

        local first="${ip%%.*}"
        [ "$first" -ge 224 ] && [ "$first" -le 239 ] && return 1

        return 0
    fi

    local lower="${ip,,}"

    # IPv6 未指定、组播以及需要 scope-id 的 link-local 地址禁止作为转发目标。
    [ "$lower" != "::" ] || return 1
    [[ "$lower" != ff* ]] || return 1

    # fe80::/10 => fe8x、fe9x、feax、febx
    if [[ "$lower" =~ ^fe[89abAB] ]]; then
        return 1
    fi

    return 0
}

resolve_ipv4_name() {
    local host="$1"
    local ip=""

    # 1) 先走系统 DNS，但最多等待 DNS_TIMEOUT 秒。
    if command -v getent >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" getent ahostsv4 "$host" 2>/dev/null \
            | awk '{print $1}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | head -n1)"
    fi

    if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" host -t A "$host" 2>/dev/null \
            | awk '/has address/ {print $4; exit}')"
    fi

    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" nslookup -query=A "$host" 2>/dev/null \
            | awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | tail -n1)"
    fi

    # 2) 系统 DNS 卡住/失败时，直接向 1.1.1.1 查询。
    if [ -z "$ip" ]; then
        echo -e "${YELLOW}系统 DNS 超时/失败，改用 ${FALLBACK_DNS} 查询 IPv4...${NC}" >&2

        if command -v host >/dev/null 2>&1; then
            ip="$(timeout "$DNS_TIMEOUT" host -t A "$host" "$FALLBACK_DNS" 2>/dev/null \
                | awk '/has address/ {print $4; exit}')"
        fi

        if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
            ip="$(timeout "$DNS_TIMEOUT" nslookup -query=A "$host" "$FALLBACK_DNS" 2>/dev/null \
                | awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
                | tail -n1)"
        fi
    fi

    valid_ipv4 "$ip" 2>/dev/null && printf '%s' "$ip"
}

resolve_ipv6_name() {
    local host="$1"
    local ip=""

    # 1) 先走系统 DNS，但最多等待 DNS_TIMEOUT 秒。
    if command -v getent >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" getent ahostsv6 "$host" 2>/dev/null \
            | awk '{print $1}' \
            | grep ':' \
            | head -n1)"
    fi

    if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" host -t AAAA "$host" 2>/dev/null \
            | awk '/has IPv6 address/ {print $5; exit}')"
    fi

    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" nslookup -query=AAAA "$host" 2>/dev/null \
            | awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' \
            | grep ':' \
            | tail -n1)"
    fi

    # 2) 系统 DNS 卡住/失败时，直接向 1.1.1.1 查询。
    if [ -z "$ip" ]; then
        echo -e "${YELLOW}系统 DNS 超时/失败，改用 ${FALLBACK_DNS} 查询 IPv6...${NC}" >&2

        if command -v host >/dev/null 2>&1; then
            ip="$(timeout "$DNS_TIMEOUT" host -t AAAA "$host" "$FALLBACK_DNS" 2>/dev/null \
                | awk '/has IPv6 address/ {print $5; exit}')"
        fi

        if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
            ip="$(timeout "$DNS_TIMEOUT" nslookup -query=AAAA "$host" "$FALLBACK_DNS" 2>/dev/null \
                | awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' \
                | grep ':' \
                | tail -n1)"
        fi
    fi

    valid_ipv6 "$ip" 2>/dev/null && printf '%s' "$ip"
}

validate_target_format() {
    local host="$1"

    [ -n "$host" ] || return 1

    # 配置字段分隔符和常见 shell/路径字符一律拒绝。
    [[ "$host" != *"|"* && "$host" != *"/"* && "$host" != *"\\"* &&
       "$host" != *";"* && "$host" != *'$'* && "$host" != *'`'* &&
       "$host" != *" "* && "$host" != *$'\t'* && "$host" != *$'\n'* ]] || return 1

    if [[ "$host" == *:* ]]; then
        valid_ipv6 "$host"
        return
    fi

    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        valid_ipv4 "$host"
        return
    fi

    valid_domain "$host"
}

resolve_target() {
    local host="$1"
    local ip=""

    TARGET_FAMILY=""
    TARGET_IP=""
    TARGET_KIND=""

    if ! validate_target_format "$host"; then
        return 2
    fi

    if valid_ipv4 "$host" 2>/dev/null; then
        safe_target_ip 4 "$host" || return 3
        TARGET_FAMILY="4"
        TARGET_IP="$host"
        TARGET_KIND="IPv4"
        return 0
    fi

    if [[ "$host" == *:* ]] && valid_ipv6 "$host" 2>/dev/null; then
        safe_target_ip 6 "$host" || return 3
        TARGET_FAMILY="6"
        TARGET_IP="$host"
        TARGET_KIND="IPv6"
        return 0
    fi

    # 域名默认优先 A 记录，保持原有 IPv4 行为；没有 A 再使用 AAAA。
    ip="$(resolve_ipv4_name "$host")"
    if [ -n "$ip" ] && safe_target_ip 4 "$ip"; then
        TARGET_FAMILY="4"
        TARGET_IP="$ip"
        TARGET_KIND="域名/IPv4"
        return 0
    fi

    ip="$(resolve_ipv6_name "$host")"
    if [ -n "$ip" ] && safe_target_ip 6 "$ip"; then
        TARGET_FAMILY="6"
        TARGET_IP="$ip"
        TARGET_KIND="域名/IPv6"
        return 0
    fi

    return 1
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
    echo
    echo "================================="
    echo "       刷新域名解析 / NFT 规则"
    echo "================================="

    nft delete table ip "$TABLE" 2>/dev/null || true
    nft delete table ip6 "$TABLE6" 2>/dev/null || true

    nft add table ip "$TABLE"
    nft "add chain ip $TABLE prerouting {
        type nat hook prerouting priority -100;
        policy accept;
    }"
    nft "add chain ip $TABLE output {
        type nat hook output priority -100;
        policy accept;
    }"
    nft "add chain ip $TABLE postrouting {
        type nat hook postrouting priority 100;
        policy accept;
    }"

    local ip6_ready=0
    local total=0
    local success=0
    local failed=0

    if [ ! -s "$CONFIG" ]; then
        echo -e "${YELLOW}当前没有转发规则${NC}"
    fi

    while IFS='|' read -r id proto listen_port host target_port; do
        [ -z "${id:-}" ] && continue
        total=$((total + 1))

        # 对旧配置也重新做防御性校验，不能因为写进配置文件就默认可信。
        host="$(trim_target "$host")"

        echo
        echo "ID=$id  $proto :$listen_port -> $host:$target_port"
        echo -n "目标检测: $host ... "

        resolve_target "$host"
        rc=$?

        if [ "$rc" -eq 2 ]; then
            echo -e "${RED}失败${NC}"
            echo -e "结果: ${RED}不是合法 IPv4、IPv6 或域名${NC}"
            failed=$((failed + 1))
            continue
        elif [ "$rc" -eq 3 ]; then
            echo -e "${RED}拒绝${NC}"
            echo -e "结果: ${RED}目标属于未指定/广播/组播/link-local 等防御性禁止地址${NC}"
            failed=$((failed + 1))
            continue
        elif [ "$rc" -ne 0 ]; then
            echo -e "${RED}失败${NC}"
            echo -e "结果: ${RED}域名无法解析出可用 A/AAAA 地址${NC}"
            failed=$((failed + 1))
            continue
        fi

        echo -e "${GREEN}成功${NC}"
        echo -e "类型: ${CYAN}${TARGET_KIND}${NC}"
        echo -e "结果: ${CYAN}$host -> $TARGET_IP${NC}"

        if [ "$TARGET_FAMILY" = "4" ]; then
            nft_target="${TARGET_IP}:${target_port}"
            echo -e "NFT 目标: ${CYAN}${nft_target}${NC}"

            case "$proto" in
                tcp)
                    nft add rule ip "$TABLE" prerouting \
                        tcp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip "$TABLE" output \
                        fib daddr type local tcp dport "$listen_port" dnat to "$nft_target"
                    ;;
                udp)
                    nft add rule ip "$TABLE" prerouting \
                        udp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip "$TABLE" output \
                        fib daddr type local udp dport "$listen_port" dnat to "$nft_target"
                    ;;
                both)
                    nft add rule ip "$TABLE" prerouting \
                        tcp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip "$TABLE" prerouting \
                        udp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip "$TABLE" output \
                        fib daddr type local tcp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip "$TABLE" output \
                        fib daddr type local udp dport "$listen_port" dnat to "$nft_target"
                    ;;
                *)
                    echo -e "${RED}协议无效: $proto${NC}"
                    failed=$((failed + 1))
                    continue
                    ;;
            esac
        else
            if [ "$ip6_ready" -eq 0 ]; then
                if ! nft add table ip6 "$TABLE6" 2>/dev/null; then
                    echo -e "${RED}无法创建 IPv6 NAT 表，当前系统可能未启用 IPv6 nftables${NC}"
                    failed=$((failed + 1))
                    continue
                fi

                nft "add chain ip6 $TABLE6 prerouting {
                    type nat hook prerouting priority -100;
                    policy accept;
                }"
                nft "add chain ip6 $TABLE6 output {
                    type nat hook output priority -100;
                    policy accept;
                }"
                nft "add chain ip6 $TABLE6 postrouting {
                    type nat hook postrouting priority 100;
                    policy accept;
                }"
                ip6_ready=1
            fi

            # IPv6 + port 必须使用 [IPv6]:port，防止冒号歧义。
            nft_target="[${TARGET_IP}]:${target_port}"
            echo -e "NFT 目标: ${CYAN}${nft_target}${NC}"

            case "$proto" in
                tcp)
                    nft add rule ip6 "$TABLE6" prerouting \
                        tcp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip6 "$TABLE6" output \
                        fib daddr type local tcp dport "$listen_port" dnat to "$nft_target"
                    ;;
                udp)
                    nft add rule ip6 "$TABLE6" prerouting \
                        udp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip6 "$TABLE6" output \
                        fib daddr type local udp dport "$listen_port" dnat to "$nft_target"
                    ;;
                both)
                    nft add rule ip6 "$TABLE6" prerouting \
                        tcp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip6 "$TABLE6" prerouting \
                        udp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip6 "$TABLE6" output \
                        fib daddr type local tcp dport "$listen_port" dnat to "$nft_target"
                    nft add rule ip6 "$TABLE6" output \
                        fib daddr type local udp dport "$listen_port" dnat to "$nft_target"
                    ;;
                *)
                    echo -e "${RED}协议无效: $proto${NC}"
                    failed=$((failed + 1))
                    continue
                    ;;
            esac
        fi

        success=$((success + 1))
        echo -e "NFT 规则: ${GREEN}已加载${NC}"
    done < "$CONFIG"

    nft add rule ip "$TABLE" postrouting masquerade
    if [ "$ip6_ready" -eq 1 ]; then
        nft add rule ip6 "$TABLE6" postrouting masquerade
    fi

    echo
    echo "================================="
    echo "刷新完成"
    echo "总规则: $total"
    echo -e "成功: ${GREEN}$success${NC}"
    echo -e "失败: ${RED}$failed${NC}"
    echo "================================="
}

add_rule() {
    echo
    read -rp "本机监听端口: " listen_port
    valid_port "$listen_port" || { echo -e "${RED}端口无效，只允许 1-65535${NC}"; return; }

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
        *) echo -e "${RED}协议错误${NC}"; return ;;
    esac

    read -rp "目标域名/IP: " host
    host="$(trim_target "$host")"

    echo -n "目标检测: $host ... "
    resolve_target "$host"
    rc=$?

    case "$rc" in
        0)
            echo -e "${GREEN}成功${NC}"
            echo -e "类型: ${CYAN}${TARGET_KIND}${NC}"
            echo -e "解析: ${CYAN}$host -> $TARGET_IP${NC}"
            ;;
        2)
            echo -e "${RED}失败${NC}"
            echo -e "${RED}请输入合法 IPv4、IPv6 或完整域名。像 5555 这样的值会被拒绝。${NC}"
            return
            ;;
        3)
            echo -e "${RED}拒绝${NC}"
            echo -e "${RED}该地址属于未指定/广播/组播/link-local 等不安全转发目标。${NC}"
            return
            ;;
        *)
            echo -e "${RED}失败${NC}"
            echo -e "${RED}域名无法解析出可用的 A/AAAA 地址。${NC}"
            return
            ;;
    esac

    read -rp "目标端口: " target_port
    valid_port "$target_port" || { echo -e "${RED}目标端口无效，只允许 1-65535${NC}"; return; }

    if [ "$TARGET_FAMILY" = "6" ]; then
        echo -e "NFT 目标将使用: ${CYAN}[${TARGET_IP}]:${target_port}${NC}"
    else
        echo -e "NFT 目标将使用: ${CYAN}${TARGET_IP}:${target_port}${NC}"
    fi

    # 拒绝完全相同的重复配置，避免重复 DNAT 规则造成难以排查的行为。
    if grep -Fqx "${proto}|${listen_port}|${host}|${target_port}" <(cut -d'|' -f2- "$CONFIG") 2>/dev/null; then
        echo -e "${YELLOW}完全相同的规则已经存在，未重复添加${NC}"
        return
    fi

    id="$(next_id)"
    echo "${id}|${proto}|${listen_port}|${host}|${target_port}" >> "$CONFIG"

    echo
    echo -e "${GREEN}添加成功${NC}"
    echo "ID: $id"

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
    echo "===== IPv4 ====="
    nft list table ip "$TABLE" 2>/dev/null || echo "当前没有 IPv4 nft 转发规则"

    echo
    echo "===== IPv6 ====="
    nft list table ip6 "$TABLE6" 2>/dev/null || echo "当前没有 IPv6 nft 转发规则"
}

get_crontab() {
    crontab -l 2>/dev/null || true
}

cron_status() {
    if get_crontab | grep -qF "$CRON_MARK_BEGIN"; then
        echo -e "${GREEN}已开启${NC}"
        get_crontab | sed -n "/$CRON_MARK_BEGIN/,/$CRON_MARK_END/p"
    else
        echo -e "${YELLOW}未开启${NC}"
    fi
}

remove_cron_block() {
    local tmp
    tmp="$(mktemp)"
    get_crontab | awk -v begin="$CRON_MARK_BEGIN" -v end="$CRON_MARK_END" '
        $0 == begin {skip=1; next}
        $0 == end   {skip=0; next}
        !skip {print}
    ' > "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
}

enable_cron_refresh() {
    command -v crontab >/dev/null 2>&1 || {
        echo -e "${RED}未安装 crontab，请重新运行脚本并完成环境安装${NC}"
        return
    }

    echo
    read -rp "每隔多少分钟解析一次域名 [默认 ${DEFAULT_INTERVAL}]: " interval
    interval="${interval:-$DEFAULT_INTERVAL}"

    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 59 ]; then
        echo -e "${RED}请输入 1-59 之间的分钟数${NC}"
        return
    fi

    ensure_cron_service
    remove_cron_block

    local tmp
    tmp="$(mktemp)"
    get_crontab > "$tmp"
    {
        echo "$CRON_MARK_BEGIN"
        echo "*/$interval * * * * $SCRIPT_PATH --refresh >/dev/null 2>&1"
        echo "$CRON_MARK_END"
    } >> "$tmp"
    crontab "$tmp"
    rm -f "$tmp"

    echo -e "${GREEN}已开启定时解析：每 ${interval} 分钟刷新一次${NC}"
}

disable_cron_refresh() {
    command -v crontab >/dev/null 2>&1 || {
        echo "当前系统没有 crontab"
        return
    }
    remove_cron_block
    echo -e "${GREEN}定时解析已关闭${NC}"
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
            1) enable_cron_refresh; read -rp "回车继续..." ;;
            2) disable_cron_refresh; read -rp "回车继续..." ;;
            3) reload_rules; read -rp "回车继续..." ;;
            0) return ;;
            *) echo "输入错误"; sleep 1 ;;
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
        echo "4. 刷新域名 IP"
        echo "5. 查看 nftables"
        echo "6. 定时解析域名"
        echo "0. 退出"
        echo "================================="

        read -rp "请选择: " choice

        case "$choice" in
            1) add_rule; read -rp "回车继续..." ;;
            2) delete_rule; read -rp "回车继续..." ;;
            3) list_rules; read -rp "回车继续..." ;;
            4) reload_rules; read -rp "回车继续..." ;;
            5) show_nft; read -rp "回车继续..." ;;
            6) timer_menu ;;
            0) exit 0 ;;
            *) echo "输入错误"; sleep 1 ;;
        esac
    done
}

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

preflight_check
enable_forwarding
mkdir -p "$(dirname "$CONFIG")"
touch "$CONFIG"

case "${1:-}" in
    --refresh)
        reload_rules >/dev/null 2>&1
        exit $?
        ;;
esac

reload_rules >/dev/null 2>&1 || true
menu
