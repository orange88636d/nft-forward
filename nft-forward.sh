#!/usr/bin/env bash
set -u

APP_VERSION="2.5.0"

CONFIG="/etc/nft-forward.conf"
STATE_DIR="/var/lib/nft-forward"
STATE_FILE="$STATE_DIR/state.conf"
MODE_FILE="$STATE_DIR/mode"
LOCK_FILE="/run/lock/nft-forward.lock"

LOG_FILE="/var/log/nft-forward.log"
LOGROTATE_FILE="/etc/logrotate.d/nft-forward"

BACKUP_DIR="/var/backups/nft-forward"
MAX_BACKUPS=20

TABLE4="nft_forward"
TABLE6="nft_forward6"
MAP_TCP="tcp_map"
MAP_UDP="udp_map"

# 转发计数采用独立的 inet/filter 表，在 forward hook 统计双向流量。
# 独立于 nat 表，避免 DNS map 增量刷新时丢失数据。
METER_TABLE="nft_forward_meter"
TRAFFIC_SNAPSHOT="$STATE_DIR/traffic.tsv"
QUOTA_LIMIT_FILE="$STATE_DIR/quota_limit_bytes"
QUOTA_USED_FILE="$STATE_DIR/quota_used_bytes"
QUOTA_MODE_FILE="$STATE_DIR/quota_mode"
WAN_IFACE_FILE="$STATE_DIR/wan_iface"
PAUSED_FILE="$STATE_DIR/paused"
QUOTA_SERVICE="/etc/systemd/system/nft-forward-quota.service"
QUOTA_TIMER="/etc/systemd/system/nft-forward-quota.timer"
CRON_QUOTA_BEGIN="# BEGIN NFT-FORWARD-QUOTA"
CRON_QUOTA_END="# END NFT-FORWARD-QUOTA"

INSTALL_PATH="/usr/local/bin/nft-forward"

BOOT_SERVICE="/etc/systemd/system/nft-forward.service"
REFRESH_SERVICE="/etc/systemd/system/nft-forward-refresh.service"
REFRESH_TIMER="/etc/systemd/system/nft-forward-refresh.timer"
OPENRC_START="/etc/local.d/nft-forward.start"

CRON_REFRESH_BEGIN="# BEGIN NFT-FORWARD-REFRESH"
CRON_REFRESH_END="# END NFT-FORWARD-REFRESH"
CRON_BOOT_BEGIN="# BEGIN NFT-FORWARD-BOOT"
CRON_BOOT_END="# END NFT-FORWARD-BOOT"

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
LOCK_DEPTH=0

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

# ============================================================
# 基础工具
# ============================================================

die() {
    echo -e "${RED}$*${NC}" >&2
    log_msg "ERROR: $*"
    exit 1
}

has_systemd() {
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

detect_os() {
    OS_ID="unknown"
    OS_NAME="Unknown Linux"
    PKG_MANAGER=""

    if [ -f /etc/os-release ]; then
        OS_ID="$(awk -F= '$1=="ID" {
            sub(/^[^=]*=/, "");
            gsub(/^"|"$/, "");
            print;
            exit
        }' /etc/os-release)"

        OS_NAME="$(awk -F= '$1=="PRETTY_NAME" {
            sub(/^[^=]*=/, "");
            gsub(/^"|"$/, "");
            print;
            exit
        }' /etc/os-release)"

        [ -n "$OS_ID" ] || OS_ID="unknown"
        [ -n "$OS_NAME" ] || OS_NAME="Unknown Linux"
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint|kali|raspbian)
            PKG_MANAGER="apt"
            ;;
        alpine)
            PKG_MANAGER="apk"
            ;;
        centos|rhel|rocky|almalinux|fedora|ol)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro)
            PKG_MANAGER="pacman"
            ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                PKG_MANAGER="apt"
            elif command -v apk >/dev/null 2>&1; then
                PKG_MANAGER="apk"
            elif command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            elif command -v yum >/dev/null 2>&1; then
                PKG_MANAGER="yum"
            elif command -v pacman >/dev/null 2>&1; then
                PKG_MANAGER="pacman"
            fi
            ;;
    esac
}

ensure_data_files() {
    mkdir -p \
        "$(dirname "$CONFIG")" \
        "$STATE_DIR" \
        "$(dirname "$LOCK_FILE")" \
        "$(dirname "$LOG_FILE")" \
        "$BACKUP_DIR"

    touch "$CONFIG" "$STATE_FILE" "$LOG_FILE"

    chmod 600 "$CONFIG" "$STATE_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
}

log_msg() {
    local msg="$*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

write_logrotate_config() {
    mkdir -p "$(dirname "$LOGROTATE_FILE")"

    cat > "$LOGROTATE_FILE" <<EOF
$LOG_FILE {
    weekly
    size 1M
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 root root
}
EOF

    chmod 644 "$LOGROTATE_FILE"
}

backup_config() {
    local reason="${1:-manual}"
    local stamp backup

    ensure_data_files
    stamp="$(date '+%Y%m%d-%H%M%S')"
    backup="$BACKUP_DIR/nft-forward.conf.${stamp}.$$.${reason}.bak"

    cp -a "$CONFIG" "$backup" || return 1
    chmod 600 "$backup" 2>/dev/null || true

    ls -1t "$BACKUP_DIR"/nft-forward.conf.*.bak 2>/dev/null |
        tail -n +$((MAX_BACKUPS + 1)) |
        xargs -r rm -f --

    log_msg "config backup created file=$backup"
    printf '%s' "$backup"
}

lock_begin() {
    if [ "$LOCK_DEPTH" -eq 0 ]; then
        exec 9>"$LOCK_FILE"

        if ! flock -w 15 9; then
            echo -e "${RED}另一个 nft-forward 任务正在运行，请稍后重试${NC}" >&2
            return 1
        fi
    fi

    LOCK_DEPTH=$((LOCK_DEPTH + 1))
}

lock_end() {
    [ "$LOCK_DEPTH" -gt 0 ] || return 0

    LOCK_DEPTH=$((LOCK_DEPTH - 1))

    if [ "$LOCK_DEPTH" -eq 0 ]; then
        flock -u 9 2>/dev/null || true
        exec 9>&-
    fi
}

enable_forwarding() {
    if command -v sysctl >/dev/null 2>&1; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    else
        [ -w /proc/sys/net/ipv4/ip_forward ] &&
            echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

        [ -w /proc/sys/net/ipv6/conf/all/forwarding ] &&
            echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
    fi
}

# ============================================================
# 环境检测 / 依赖安装
# ============================================================

install_packages() {
    local packages=("$@")
    [ "${#packages[@]}" -gt 0 ] || return 0

    case "$PKG_MANAGER" in
        apt)
            apt-get update &&
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
    if has_systemd; then
        systemctl enable --now cron >/dev/null 2>&1 ||
        systemctl enable --now crond >/dev/null 2>&1 ||
        systemctl enable --now cronie >/dev/null 2>&1 ||
        true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 ||
        service crond start >/dev/null 2>&1 ||
        true
    fi
}

runtime_check_quiet() {
    [ "$(id -u)" -eq 0 ] || return 1
    command -v nft >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    command -v flock >/dev/null 2>&1 || return 1

    if ! command -v host >/dev/null 2>&1 &&
       ! command -v nslookup >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

preflight_check() {
    local missing=()
    local need_nft=0
    local need_dns=0
    local need_timeout=0
    local need_flock=0
    local need_logrotate=0
    local need_cron=0

    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行此脚本"

    detect_os

    echo "================================="
    echo "       运行环境检测"
    echo "================================="
    echo -e "系统: ${CYAN}${OS_NAME}${NC}"
    echo "系统 ID: $OS_ID"
    echo "包管理器: ${PKG_MANAGER:-未识别}"
    echo

    if command -v nft >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] nftables"
    else
        echo -e "[${RED}缺少${NC}] nftables"
        need_nft=1
    fi

    if has_systemd; then
        echo -e "[${GREEN}OK${NC}] systemd timer（首选调度器）"
    elif command -v crontab >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] crontab（兼容调度器）"
    else
        echo -e "[${YELLOW}缺少${NC}] crontab（无 systemd 时定时解析需要）"
        need_cron=1
    fi

    if command -v getent >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] getent（系统 DNS）"
    else
        echo -e "[${YELLOW}提示${NC}] 未发现 getent，将使用 host/nslookup"
    fi

    if command -v host >/dev/null 2>&1 ||
       command -v nslookup >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] 直连 DNS 查询工具"
    else
        echo -e "[${RED}缺少${NC}] host/nslookup（备用 DNS 查询需要）"
        need_dns=1
    fi

    if command -v timeout >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] timeout"
    else
        echo -e "[${RED}缺少${NC}] timeout"
        need_timeout=1
    fi

    if command -v flock >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] flock"
    else
        echo -e "[${RED}缺少${NC}] flock"
        need_flock=1
    fi

    if command -v sysctl >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] sysctl"
    else
        echo -e "[${YELLOW}警告${NC}] 未发现 sysctl，将尝试直接写 /proc"
    fi

    if command -v logrotate >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] logrotate"
    else
        echo -e "[${YELLOW}缺少${NC}] logrotate"
        need_logrotate=1
    fi

    if [ "$need_nft" -eq 0 ] &&
       [ "$need_dns" -eq 0 ] &&
       [ "$need_timeout" -eq 0 ] &&
       [ "$need_flock" -eq 0 ] &&
       [ "$need_logrotate" -eq 0 ] &&
       [ "$need_cron" -eq 0 ]; then

        write_logrotate_config
        echo
        echo -e "${GREEN}环境检测通过${NC}"
        sleep 1
        return 0
    fi

    [ -n "$PKG_MANAGER" ] ||
        die "无法识别包管理器，请手动安装依赖"

    case "$PKG_MANAGER" in
        apt)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_dns" -eq 1 ] && missing+=("dnsutils")
            [ "$need_timeout" -eq 1 ] && missing+=("coreutils")
            [ "$need_flock" -eq 1 ] && missing+=("util-linux")
            [ "$need_logrotate" -eq 1 ] && missing+=("logrotate")
            [ "$need_cron" -eq 1 ] && missing+=("cron")
            ;;
        apk)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_dns" -eq 1 ] && missing+=("bind-tools")
            [ "$need_timeout" -eq 1 ] && missing+=("coreutils")
            [ "$need_flock" -eq 1 ] && missing+=("util-linux")
            [ "$need_logrotate" -eq 1 ] && missing+=("logrotate")
            [ "$need_cron" -eq 1 ] && missing+=("dcron")
            ;;
        dnf|yum)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_dns" -eq 1 ] && missing+=("bind-utils")
            [ "$need_timeout" -eq 1 ] && missing+=("coreutils")
            [ "$need_flock" -eq 1 ] && missing+=("util-linux")
            [ "$need_logrotate" -eq 1 ] && missing+=("logrotate")
            [ "$need_cron" -eq 1 ] && missing+=("cronie")
            ;;
        pacman)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_dns" -eq 1 ] && missing+=("bind")
            [ "$need_timeout" -eq 1 ] && missing+=("coreutils")
            [ "$need_flock" -eq 1 ] && missing+=("util-linux")
            [ "$need_logrotate" -eq 1 ] && missing+=("logrotate")
            [ "$need_cron" -eq 1 ] && missing+=("cronie")
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
            install_packages "${missing[@]}" ||
                die "自动安装失败，请手动安装后重试"
            ;;
        *)
            die "缺少必要组件，已退出"
            ;;
    esac

    [ "$need_cron" -eq 1 ] && ensure_cron_service

    runtime_check_quiet ||
        die "依赖安装后仍有必要组件不可用"

    write_logrotate_config

    echo
    echo -e "${GREEN}依赖检查完成${NC}"
    sleep 1
}

# ============================================================
# IP / 域名校验与解析
# ============================================================

trim_target() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "$value" == \[*\] ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
    [ "$1" -ge 1 ] &&
    [ "$1" -le 65535 ]
}

valid_proto() {
    case "$1" in
        tcp|udp|both) return 0 ;;
        *) return 1 ;;
    esac
}

valid_ipv4() {
    local ip="$1"
    local a b c d extra octet

    IFS='.' read -r a b c d extra <<< "$ip"
    [ -z "${extra:-}" ] || return 1

    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

valid_ipv6() {
    local ip="$1"
    local t="__nftfw_validate_${RANDOM}_$$"

    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1

    printf 'table ip6 %s { chain c { type nat hook prerouting priority -100; tcp dport 1 dnat to [%s]:1; } }\n' \
        "$t" "$ip" |
        nft -c -f - >/dev/null 2>&1
}

valid_domain() {
    local domain="$1"
    local label

    [ -n "$domain" ] || return 1
    [ "${#domain}" -le 253 ] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+\.?$ ]] || return 1
    [[ "$domain" =~ [A-Za-z-] ]] || return 1

    domain="${domain%.}"

    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != .* ]] || return 1
    [[ "$domain" != *. ]] || return 1
    [[ "$domain" != *..* ]] || return 1

    IFS='.' read -ra labels <<< "$domain"

    for label in "${labels[@]}"; do
        [ -n "$label" ] || return 1
        [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
            return 1
    done
}

safe_target_ip() {
    local family="$1"
    local ip="$2"

    if [ "$family" = "4" ]; then
        local first="${ip%%.*}"

        [ "$ip" != "0.0.0.0" ] || return 1
        [ "$ip" != "255.255.255.255" ] || return 1

        if [ "$first" -ge 224 ] && [ "$first" -le 239 ]; then
            return 1
        fi

        return 0
    fi

    local lower="${ip,,}"

    [ "$lower" != "::" ] || return 1
    [[ "$lower" != ff* ]] || return 1

    # fe80::/10 需要 scope id，不适合作为普通转发目标。
    [[ "$lower" =~ ^fe[89ab] ]] && return 1

    return 0
}

validate_target_format() {
    local host="$1"

    [ -n "$host" ] || return 1

    [[ "$host" != *"|"* ]] || return 1
    [[ "$host" != *"/"* ]] || return 1
    [[ "$host" != *"\\"* ]] || return 1
    [[ "$host" != *";"* ]] || return 1
    [[ "$host" != *'$'* ]] || return 1
    [[ "$host" != *'`'* ]] || return 1
    [[ "$host" != *" "* ]] || return 1
    [[ "$host" != *$'\t'* ]] || return 1
    [[ "$host" != *$'\n'* ]] || return 1

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

system_query_ipv4() {
    local host="$1"
    local ip=""

    if command -v getent >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" getent ahostsv4 "$host" 2>/dev/null |
            awk '{print $1}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            head -n1
        )"
    elif command -v host >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" host -t A "$host" 2>/dev/null |
            awk '/has address/ {print $4; exit}'
        )"
    elif command -v nslookup >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" nslookup -query=A "$host" 2>/dev/null |
            awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            tail -n1
        )"
    fi

    valid_ipv4 "$ip" 2>/dev/null && printf '%s' "$ip"
}

fallback_query_ipv4() {
    local host="$1"
    local ip=""

    if command -v host >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" host -t A "$host" "$FALLBACK_DNS" 2>/dev/null |
            awk '/has address/ {print $4; exit}'
        )"
    elif command -v nslookup >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" nslookup -query=A "$host" "$FALLBACK_DNS" 2>/dev/null |
            awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            tail -n1
        )"
    fi

    valid_ipv4 "$ip" 2>/dev/null && printf '%s' "$ip"
}

system_query_ipv6() {
    local host="$1"
    local ip=""

    if command -v getent >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" getent ahostsv6 "$host" 2>/dev/null |
            awk '{print $1}' |
            grep ':' |
            head -n1
        )"
    elif command -v host >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" host -t AAAA "$host" 2>/dev/null |
            awk '/has IPv6 address/ {print $5; exit}'
        )"
    elif command -v nslookup >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" nslookup -query=AAAA "$host" 2>/dev/null |
            awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' |
            grep ':' |
            tail -n1
        )"
    fi

    valid_ipv6 "$ip" 2>/dev/null && printf '%s' "$ip"
}

fallback_query_ipv6() {
    local host="$1"
    local ip=""

    if command -v host >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" host -t AAAA "$host" "$FALLBACK_DNS" 2>/dev/null |
            awk '/has IPv6 address/ {print $5; exit}'
        )"
    elif command -v nslookup >/dev/null 2>&1; then
        ip="$(
            timeout "$DNS_TIMEOUT" nslookup -query=AAAA "$host" "$FALLBACK_DNS" 2>/dev/null |
            awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' |
            grep ':' |
            tail -n1
        )"
    fi

    valid_ipv6 "$ip" 2>/dev/null && printf '%s' "$ip"
}

resolve_ipv4_name() {
    local host="$1"
    local ip=""

    ip="$(system_query_ipv4 "$host")"

    if [ -n "$ip" ]; then
        printf '%s' "$ip"
        return 0
    fi

    echo -e "${YELLOW}系统 DNS 超时/失败，改用 ${FALLBACK_DNS} 查询 A 记录...${NC}" >&2
    ip="$(fallback_query_ipv4 "$host")"

    [ -n "$ip" ] && printf '%s' "$ip"
}

resolve_ipv6_name() {
    local host="$1"
    local ip=""

    ip="$(system_query_ipv6 "$host")"

    if [ -n "$ip" ]; then
        printf '%s' "$ip"
        return 0
    fi

    echo -e "${YELLOW}系统 DNS 超时/失败，改用 ${FALLBACK_DNS} 查询 AAAA 记录...${NC}" >&2
    ip="$(fallback_query_ipv6 "$host")"

    [ -n "$ip" ] && printf '%s' "$ip"
}

resolve_target() {
    local host="$1"
    local ip=""

    TARGET_FAMILY=""
    TARGET_IP=""
    TARGET_KIND=""

    validate_target_format "$host" || return 2

    if valid_ipv4 "$host" 2>/dev/null; then
        safe_target_ip 4 "$host" || return 3

        TARGET_FAMILY="4"
        TARGET_IP="$host"
        TARGET_KIND="IPv4"
        return 0
    fi

    if [[ "$host" == *:* ]] &&
       valid_ipv6 "$host" 2>/dev/null; then

        safe_target_ip 6 "$host" || return 3

        TARGET_FAMILY="6"
        TARGET_IP="$host"
        TARGET_KIND="IPv6"
        return 0
    fi

    # 域名优先 A；没有 A 再尝试 AAAA。
    ip="$(resolve_ipv4_name "$host")"

    if [ -n "$ip" ] &&
       safe_target_ip 4 "$ip"; then

        TARGET_FAMILY="4"
        TARGET_IP="$ip"
        TARGET_KIND="域名/IPv4"
        return 0
    fi

    ip="$(resolve_ipv6_name "$host")"

    if [ -n "$ip" ] &&
       safe_target_ip 6 "$ip"; then

        TARGET_FAMILY="6"
        TARGET_IP="$ip"
        TARGET_KIND="域名/IPv6"
        return 0
    fi

    return 1
}

is_domain() {
    valid_domain "$1" 2>/dev/null
}

# ============================================================
# 配置 / 状态
# ============================================================

next_id() {
    local max=0
    local id

    while IFS='|' read -r id _; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [ "$id" -gt "$max" ] && max="$id"
    done < "$CONFIG"

    echo $((max + 1))
}

load_state() {
    local wanted_id="$1"
    local line

    STATE_ID=""
    STATE_HOST=""
    STATE_FAMILY=""
    STATE_IP=""
    STATE_PROTO=""
    STATE_LISTEN=""
    STATE_TARGET_PORT=""

    line="$(
        awk -F'|' -v id="$wanted_id" '$1 == id {print; exit}' "$STATE_FILE" 2>/dev/null
    )"

    [ -n "$line" ] || return 1

    IFS='|' read -r \
        STATE_ID \
        STATE_HOST \
        STATE_FAMILY \
        STATE_IP \
        STATE_PROTO \
        STATE_LISTEN \
        STATE_TARGET_PORT \
        <<< "$line"

    return 0
}

state_matches_config() {
    local host="$1"
    local proto="$2"
    local listen_port="$3"
    local target_port="$4"

    [ "$STATE_HOST" = "$host" ] &&
    [ "$STATE_PROTO" = "$proto" ] &&
    [ "$STATE_LISTEN" = "$listen_port" ] &&
    [ "$STATE_TARGET_PORT" = "$target_port" ]
}

state_replace_in_file() {
    local file="$1"
    local id="$2"
    local host="$3"
    local family="$4"
    local ip="$5"
    local proto="$6"
    local listen_port="$7"
    local target_port="$8"
    local tmp

    tmp="$(mktemp)"

    awk -F'|' -v id="$id" '$1 != id' "$file" > "$tmp"

    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$id" "$host" "$family" "$ip" "$proto" "$listen_port" "$target_port" \
        >> "$tmp"

    mv "$tmp" "$file"
}

port_conflict() {
    local new_proto="$1"
    local new_port="$2"
    local ignore_id="${3:-}"
    local id proto listen_port host target_port

    CONFLICT_ID=""
    CONFLICT_PROTO=""

    while IFS='|' read -r id proto listen_port host target_port; do
        [ -n "${id:-}" ] || continue
        [ -n "$ignore_id" ] && [ "$id" = "$ignore_id" ] && continue
        [ "$listen_port" = "$new_port" ] || continue

        case "$new_proto:$proto" in
            tcp:tcp|tcp:both|udp:udp|udp:both|both:tcp|both:udp|both:both)
                CONFLICT_ID="$id"
                CONFLICT_PROTO="$proto"
                return 0
                ;;
        esac
    done < "$CONFIG"

    return 1
}

validate_config_structure() {
    local id proto listen_port host target_port
    local -A seen_tcp=()
    local -A seen_udp=()

    while IFS='|' read -r id proto listen_port host target_port; do
        [ -n "${id:-}" ] || continue

        [[ "$id" =~ ^[0-9]+$ ]] || {
            echo -e "${RED}配置错误：非法 ID=$id${NC}" >&2
            return 1
        }

        valid_proto "$proto" || {
            echo -e "${RED}配置错误：ID=$id 协议无效${NC}" >&2
            return 1
        }

        valid_port "$listen_port" || {
            echo -e "${RED}配置错误：ID=$id 监听端口无效${NC}" >&2
            return 1
        }

        valid_port "$target_port" || {
            echo -e "${RED}配置错误：ID=$id 目标端口无效${NC}" >&2
            return 1
        }

        host="$(trim_target "$host")"

        validate_target_format "$host" || {
            echo -e "${RED}配置错误：ID=$id 目标非法：$host${NC}" >&2
            return 1
        }

        case "$proto" in
            tcp)
                [ -z "${seen_tcp[$listen_port]:-}" ] || {
                    echo -e "${RED}配置冲突：TCP/$listen_port 重复${NC}" >&2
                    return 1
                }
                seen_tcp["$listen_port"]="$id"
                ;;
            udp)
                [ -z "${seen_udp[$listen_port]:-}" ] || {
                    echo -e "${RED}配置冲突：UDP/$listen_port 重复${NC}" >&2
                    return 1
                }
                seen_udp["$listen_port"]="$id"
                ;;
            both)
                [ -z "${seen_tcp[$listen_port]:-}" ] || {
                    echo -e "${RED}配置冲突：TCP/$listen_port 重复${NC}" >&2
                    return 1
                }
                [ -z "${seen_udp[$listen_port]:-}" ] || {
                    echo -e "${RED}配置冲突：UDP/$listen_port 重复${NC}" >&2
                    return 1
                }
                seen_tcp["$listen_port"]="$id"
                seen_udp["$listen_port"]="$id"
                ;;
        esac
    done < "$CONFIG"

    return 0
}

prepare_resolved_rules() {
    local resolved_file="$1"
    local new_state_file="$2"
    local verbose="${3:-1}"

    local id proto listen_port host target_port rc

    : > "$resolved_file"
    : > "$new_state_file"

    validate_config_structure || return 1

    while IFS='|' read -r id proto listen_port host target_port; do
        [ -n "${id:-}" ] || continue
        host="$(trim_target "$host")"

        if [ "$verbose" -eq 1 ]; then
            echo
            echo "ID=$id  $proto :$listen_port -> $host:$target_port"
            echo -n "目标检测: $host ... "
        fi

        resolve_target "$host"
        rc=$?

        if [ "$rc" -eq 0 ]; then
            if [ "$verbose" -eq 1 ]; then
                echo -e "${GREEN}成功${NC}"
                echo -e "解析: ${CYAN}$host -> $TARGET_IP${NC}"
            fi

            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$id" "$host" "$TARGET_FAMILY" "$TARGET_IP" \
                "$proto" "$listen_port" "$target_port" \
                >> "$new_state_file"

            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$id" "$proto" "$listen_port" "$host" "$target_port" \
                "$TARGET_FAMILY" "$TARGET_IP" \
                >> "$resolved_file"

            continue
        fi

        # 只有 DNS 临时失败才允许继续使用旧 IP。
        if [ "$rc" -eq 1 ] &&
           load_state "$id" &&
           state_matches_config "$host" "$proto" "$listen_port" "$target_port"; then

            if { [ "$STATE_FAMILY" = "4" ] &&
                 valid_ipv4 "$STATE_IP" &&
                 safe_target_ip 4 "$STATE_IP"; } ||
               { [ "$STATE_FAMILY" = "6" ] &&
                 valid_ipv6 "$STATE_IP" &&
                 safe_target_ip 6 "$STATE_IP"; }; then

                if [ "$verbose" -eq 1 ]; then
                    echo -e "${YELLOW}DNS 查询失败${NC}"
                    echo -e "保留旧 IP: ${CYAN}$STATE_IP${NC}"
                fi

                printf '%s|%s|%s|%s|%s|%s|%s\n' \
                    "$id" "$host" "$STATE_FAMILY" "$STATE_IP" \
                    "$proto" "$listen_port" "$target_port" \
                    >> "$new_state_file"

                printf '%s|%s|%s|%s|%s|%s|%s\n' \
                    "$id" "$proto" "$listen_port" "$host" "$target_port" \
                    "$STATE_FAMILY" "$STATE_IP" \
                    >> "$resolved_file"

                continue
            fi
        fi

        case "$rc" in
            2)
                echo -e "${RED}失败：目标格式非法：$host${NC}" >&2
                ;;
            3)
                echo -e "${RED}拒绝：目标属于禁止地址：$host${NC}" >&2
                ;;
            *)
                echo -e "${RED}失败：$host 无法解析，且没有可用旧 IP${NC}" >&2
                ;;
        esac

        return 1
    done < "$CONFIG"

    return 0
}

# ============================================================
# 双向转发计数 / 系统接口流量 / 转发额度
# ============================================================

numeric_or_zero() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$1" ;;
    esac
}

quota_limit() {
    numeric_or_zero "$(cat "$QUOTA_LIMIT_FILE" 2>/dev/null || true)"
}

quota_used() {
    numeric_or_zero "$(cat "$QUOTA_USED_FILE" 2>/dev/null || true)"
}

# 升级自 2.4.0 时，默认保持原有双向转发统计额度。
quota_mode() {
    case "$(cat "$QUOTA_MODE_FILE" 2>/dev/null || true)" in
        egress) printf 'egress' ;;
        *) printf 'forward' ;;
    esac
}

quota_mode_label() {
    case "$(quota_mode)" in
        egress) printf '公网出口网卡 TX（仅计发送）' ;;
        *) printf '转发双向（上传+下载）' ;;
    esac
}

# 优先使用固定网卡，缺省为系统默认 IPv4 路由的接口。
# 固定的网卡名不会随 DNS 刷新或重启悄悄改变。
wan_interface() {
    local iface
    iface="$(cat "$WAN_IFACE_FILE" 2>/dev/null || true)"
    if [ -z "$iface" ]; then
        iface="$(ip -4 route show default 2>/dev/null |
            awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
    fi
    printf '%s' "$iface"
}

valid_wan_interface() {
    local iface="$1"
    [[ "$iface" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || return 1
    [ "$iface" != lo ] || return 1
    ip link show dev "$iface" >/dev/null 2>&1
}

is_paused() {
    [ -f "$PAUSED_FILE" ]
}

human_bytes() {
    awk -v n="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", u, " "); i=1;
        while (n >= 1024 && i < 6) {n=n/1024; i++}
        printf "%.2f %s", n, u[i]
    }'
}

# 接受 500M / 1.5G / 2T 等容量；省略单位时按字节。
parse_quota_size() {
    local raw="${1^^}"
    [[ "$raw" =~ ^([0-9]+([.][0-9]{1,3})?)([KMGT]?I?B?|)$ ]] || return 1
    local number="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]}" power=0
    unit="${unit%B}"; unit="${unit%I}"
    case "$unit" in
        '' ) power=0 ;;
        K) power=1 ;;
        M) power=2 ;;
        G) power=3 ;;
        T) power=4 ;;
        *) return 1 ;;
    esac
    awk -v n="$number" -v p="$power" 'BEGIN {
        for (i=0; i<p; i++) n*=1024;
        if (n<1 || n>9000000000000000) exit 1;
        printf "%.0f", n
    }'
}

# 输出 id|packets|bytes；只使用 nft 的命名 counter 数据。
meter_read_counters() {
    nft -n list counters table inet "$METER_TABLE" 2>/dev/null |
        awk '
        $1=="counter" {name=$2}
        /packets[[:space:]]+[0-9]+[[:space:]]+bytes[[:space:]]+[0-9]+/ {
            pkt=""; b="";
            for(i=1;i<=NF;i++) {
                if($i=="packets") pkt=$(i+1);
                if($i=="bytes") b=$(i+1);
            }
            if(name=="total") print "0|"pkt"|"b;
            else if(name=="wan_tx") print "WAN|"pkt"|"b;
            else if(name ~ /^rule_[0-9]+$/) {
                sub(/^rule_/, "", name); print name"|"pkt"|"b
            }
            name=""
        }'
}

# 配额内核对象的 used 字节数（包括达到限额后被丢弃的探测包）。
meter_read_quota_used() {
    nft -n list quota inet "$METER_TABLE" cap 2>/dev/null |
        awk '
        $1=="quota" && $2=="cap" {seen=1}
        seen && /used[[:space:]]+[0-9]+/ {
            for(i=1;i<=NF;i++) if($i=="used") {print $(i+1); exit}
        }'
}

# 读取快照必须先获得原始数值，不能在 nft 查询出错时覆盖旧快照。
meter_capture() {
    local tmp data used
    nft list table inet "$METER_TABLE" >/dev/null 2>&1 || return 0
    data="$(meter_read_counters)"
    if [ -n "$data" ] && printf '%s\n' "$data" | grep -q '^0|'; then
        tmp="$(mktemp "$STATE_DIR/.traffic.XXXXXX")" || return 1
        printf '%s\n' "$data" > "$tmp"
        chmod 600 "$tmp"
        mv -f "$tmp" "$TRAFFIC_SNAPSHOT"
    fi
    if [ "$(quota_limit)" -gt 0 ]; then
        used="$(meter_read_quota_used)"
        if [[ "$used" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$used" > "$QUOTA_USED_FILE"
            chmod 600 "$QUOTA_USED_FILE"
        fi
    fi
}

meter_counter_record() {
    local wanted="$1"
    [ -r "$TRAFFIC_SNAPSHOT" ] || return 0
    awk -F'|' -v wanted="$wanted" '$1==wanted {print $2"|"$3; exit}' \
        "$TRAFFIC_SNAPSHOT" 2>/dev/null
}

# 在既有 nft transaction 后追加计数和配额表，和转发规则同时提交。
# 每次重建从快照初始化命名 counter，避免系统更新/重建后流量清零。
meter_append_ruleset() {
    local resolved="$1" file="$2"
    local id proto listen_port host target_port family ip old counters packets bytes
    local limit used action proto_one qmode wan
    limit="$(quota_limit)"
    used="$(quota_used)"
    qmode="$(quota_mode)"
    wan="$(wan_interface)"
    # 公网出站限额必须绑定明确存在的出口网卡，避免静默失去防护。
    if [ "$qmode" = egress ] && ! is_paused; then
        valid_wan_interface "$wan" || {
            echo "公网出口网卡无效：${wan:-未识别}；拒绝加载不受保护的转发规则" >&2
            return 1
        }
    fi
    if [ "$limit" -gt 0 ] && [ "$used" -gt "$limit" ]; then used="$limit"; fi

    nft list table inet "$METER_TABLE" >/dev/null 2>&1 &&
        printf 'delete table inet %s\n' "$METER_TABLE" >> "$file"
    printf 'add table inet %s\n' "$METER_TABLE" >> "$file"
    printf 'add chain inet %s forward { type filter hook forward priority -50; policy accept; }\n' "$METER_TABLE" >> "$file"

    counters="$(meter_counter_record 0)"
    IFS='|' read -r packets bytes <<< "$counters"
    packets="$(numeric_or_zero "$packets")"
    bytes="$(numeric_or_zero "$bytes")"
    printf 'add counter inet %s total { packets %s bytes %s; }\n' \
        "$METER_TABLE" "$packets" "$bytes" >> "$file"

    if [ "$limit" -gt 0 ]; then
        printf 'add quota inet %s cap { over %s bytes used %s bytes; }\n' \
            "$METER_TABLE" "$limit" "$used" >> "$file"
    fi

    # 公网出口 TX 统计采用 postrouting，IPv4/IPv6 都会在出接口时计一次。
    # 不对所有公网出口包直接 drop，否则 SSH 回包也会被阻断。
    if [ -n "$wan" ] && [[ "$wan" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]; then
        counters="$(meter_counter_record WAN)"
        IFS='|' read -r packets bytes <<< "$counters"
        printf 'add chain inet %s postrouting { type filter hook postrouting priority 150; policy accept; }\n' "$METER_TABLE" >> "$file"
        printf 'add counter inet %s wan_tx { packets %s bytes %s; }\n' \
            "$METER_TABLE" "$(numeric_or_zero "$packets")" "$(numeric_or_zero "$bytes")" >> "$file"
        if [ "$qmode" = egress ] && [ "$limit" -gt 0 ] && ! is_paused; then
            # 所有经 WAN 出口的包都消耗额度；超额时跳到本程序专用拦截链。
            # 限额的求值每包只执行一次，之后只拦截本程序的 DNAT 端口。
            # 其他本机服务（含 SSH）和不相关 DNAT 不会因此被直接丢弃。
            printf 'add chain inet %s egress_block\n' "$METER_TABLE" >> "$file"
            printf 'add rule inet %s postrouting oifname "%s" quota name "cap" jump egress_block\n' \
                "$METER_TABLE" "$wan" >> "$file"
        fi
        # 位于 jump 规则后：只统计允许离开主机的包，不含此处已丢弃的包。
        printf 'add rule inet %s postrouting oifname "%s" counter name "wan_tx"\n' \
            "$METER_TABLE" "$wan" >> "$file"
    fi

    while IFS='|' read -r id proto listen_port host target_port family ip; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        counters="$(meter_counter_record "$id")"
        IFS='|' read -r packets bytes <<< "$counters"
        packets="$(numeric_or_zero "$packets")"
        bytes="$(numeric_or_zero "$bytes")"
        printf 'add counter inet %s rule_%s { packets %s bytes %s; }\n' \
            "$METER_TABLE" "$id" "$packets" "$bytes" >> "$file"

        # ct original proto-dst 与 ct status dnat 同时成立时，
        # forward 链中原始/回复方向都按所属转发端口计数。
        for proto_one in tcp udp; do
            case "$proto:$proto_one" in
                tcp:udp|udp:tcp) continue ;;
            esac
            if is_paused; then
                printf 'add rule inet %s forward ct status dnat meta l4proto %s ct original proto-dst %s drop\n' \
                    "$METER_TABLE" "$proto_one" "$listen_port" >> "$file"
                continue
            fi
            if [ "$limit" -gt 0 ] && [ "$qmode" = egress ] && ! is_paused; then
                printf 'add rule inet %s egress_block ct status dnat meta l4proto %s ct original proto-dst %s drop\n' \
                    "$METER_TABLE" "$proto_one" "$listen_port" >> "$file"
            fi
            if [ "$limit" -gt 0 ] && [ "$qmode" = forward ]; then
                # 双向转发模式在 forward 钩子执行限额；出站模式在 postrouting 计算。
                printf 'add rule inet %s forward ct status dnat meta l4proto %s ct original proto-dst %s quota name "cap" drop\n' \
                    "$METER_TABLE" "$proto_one" "$listen_port" >> "$file"
            fi
            printf 'add rule inet %s forward ct status dnat meta l4proto %s ct original proto-dst %s counter name "rule_%s" counter name "total"\n' \
                "$METER_TABLE" "$proto_one" "$listen_port" "$id" >> "$file"
        done
    done < "$resolved"
}

# STATE_FILE 的字段顺序和完整 resolved 不一样。
meter_resolved_from_state() {
    awk -F'|' 'NF>=7 {printf "%s|%s|%s|%s|%s|%s|%s\n", $1,$5,$6,$2,$7,$3,$4}' \
        "$STATE_FILE" > "$1"
}

# 不改 NAT，只更新计数表（改变限额、初次升级启用统计时使用）。
meter_rebuild_only() {
    local resolved tx
    resolved="$(mktemp)"; tx="$(mktemp)"
    meter_resolved_from_state "$resolved"
    : > "$tx"
    if ! meter_append_ruleset "$resolved" "$tx" ||
       ! nft -c -f "$tx" >/dev/null 2>&1 || ! nft -f "$tx"; then
        rm -f "$resolved" "$tx"
        log_msg "meter rebuild failed"
        return 1
    fi
    rm -f "$resolved" "$tx"
}

# 提前存下内核计数，写暂停标记后原子移除 NAT 并改成 drop 规则。
pause_forwarding() {
    local reason="${1:-manual}" resolved tx
    lock_begin || return 1
    meter_capture
    touch "$PAUSED_FILE"
    printf '%s\n' "$reason" > "$PAUSED_FILE"
    resolved="$(mktemp)"; tx="$(mktemp)"
    meter_resolved_from_state "$resolved"
    : > "$tx"
    append_delete_existing_tables "$tx"
    if ! meter_append_ruleset "$resolved" "$tx" ||
       ! nft -c -f "$tx" >/dev/null 2>&1 || ! nft -f "$tx"; then
        echo -e "${RED}停转发失败，请检查 nftables；内核配额仍尝试阻止超额流量${NC}" >&2
        log_msg "pause forwarding failed reason=$reason"
        # 若暂停重建语法失败，尽量先移除本程序的 NAT 表（独立事务）。
        nft delete table ip "$TABLE4" >/dev/null 2>&1 || true
        nft delete table ip6 "$TABLE6" >/dev/null 2>&1 || true
        rm -f "$resolved" "$tx"
        lock_end
        return 1
    fi
    log_msg "forwarding paused reason=$reason"
    rm -f "$resolved" "$tx"
    lock_end
    echo -e "${YELLOW}转发已暂停（配置仍保留），原因: $reason${NC}"
}

resume_forwarding() {
    local limit
    lock_begin || return 1
    meter_capture
    limit="$(quota_limit)"
    # 新周期从 0 开始计算额度；历史总流量不会清零。
    printf '0\n' > "$QUOTA_USED_FILE"
    rm -f "$PAUSED_FILE"
    if ! full_rebuild 0 1; then
        touch "$PAUSED_FILE"
        echo -e "${RED}恢复失败，仍保持暂停${NC}" >&2
        lock_end
        return 1
    fi
    lock_end
    log_msg "forwarding resumed reset_quota=1 limit=$limit"
    echo -e "${GREEN}转发已恢复，额度周期重新开始，历史统计保留${NC}"
}

quota_watchdog_install() {
    local tmp
    install_current_script || return 1
    if has_systemd; then
        cat > "$QUOTA_SERVICE" <<EOF
[Unit]
Description=Check nft-forward traffic quota
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --quota-check
EOF
        cat > "$QUOTA_TIMER" <<EOF
[Unit]
Description=Check nft-forward traffic quota every 10 seconds

[Timer]
OnBootSec=10s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=nft-forward-quota.service

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now nft-forward-quota.timer >/dev/null 2>&1 || return 1
        return 0
    fi
    command -v crontab >/dev/null 2>&1 || return 1
    ensure_cron_service
    remove_cron_block "$CRON_QUOTA_BEGIN" "$CRON_QUOTA_END"
    tmp="$(mktemp)"
    get_crontab > "$tmp"
    printf '%s\n* * * * * %s --quota-check >/dev/null 2>&1\n%s\n' \
        "$CRON_QUOTA_BEGIN" "$INSTALL_PATH" "$CRON_QUOTA_END" >> "$tmp"
    if ! crontab "$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
}

quota_watchdog_disable() {
    if has_systemd; then
        systemctl disable --now nft-forward-quota.timer >/dev/null 2>&1 || true
        rm -f "$QUOTA_TIMER" "$QUOTA_SERVICE"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v crontab >/dev/null 2>&1 &&
       get_crontab | grep -qF "$CRON_QUOTA_BEGIN"; then
        remove_cron_block "$CRON_QUOTA_BEGIN" "$CRON_QUOTA_END" || true
    fi
}

quota_check() {
    local limit used qmode wan
    limit="$(quota_limit)"
    lock_begin || return 1
    if [ "$limit" -eq 0 ]; then
        meter_capture
        lock_end
        return 0
    fi
    if is_paused; then
        meter_capture
        lock_end
        return 0
    fi
    # 监控任务先保存快照；同时检查 nft 配额对象是否存在。
    if ! nft list quota inet "$METER_TABLE" cap >/dev/null 2>&1; then
        # 启动过程中 NAT 尚未加载时等待 restore 创建原子 ruleset。
        if nft list table ip "$TABLE4" >/dev/null 2>&1 ||
           nft list table ip6 "$TABLE6" >/dev/null 2>&1; then
            lock_end
            pause_forwarding "配额防护规则丢失（故障保护）"
            return $?
        fi
        lock_end
        return 0
    fi
    qmode="$(quota_mode)"
    if [ "$qmode" = egress ]; then
        wan="$(wan_interface)"
        # 仅检查配额对象不够，还要确保出口网卡的限额规则依然存在。
        if ! valid_wan_interface "$wan" ||
           ! nft -n list chain inet "$METER_TABLE" postrouting 2>/dev/null |
                grep -Fq "oifname \"$wan\" quota name \"cap\" jump egress_block" ||
           { [ -s "$CONFIG" ] &&
             ! nft -n list chain inet "$METER_TABLE" egress_block 2>/dev/null |
                  grep -Fq 'drop'; }; then
            lock_end
            pause_forwarding "出口限额规则/网卡丢失（故障保护）"
            return $?
        fi
    fi
    meter_capture
    used="$(meter_read_quota_used)"
    if ! [[ "$used" =~ ^[0-9]+$ ]]; then
        lock_end
        pause_forwarding "配额内核读数异常（故障保护）"
        return $?
    fi
    if [ "$used" -ge "$limit" ]; then
        lock_end
        pause_forwarding "流量达到额度 $(human_bytes "$limit")"
        return $?
    fi
    lock_end
}

# 只读取内核网卡收发字节：开机以来累积值，不等同于 VPS 计费值。
system_traffic_view() {
    local path iface rx tx defiface sumrx=0 sumtx=0
    defiface="$(ip -4 route show default 2>/dev/null |
        awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
    echo
    echo "===== 系统网卡流量（本次开机以来） ====="
    echo "默认 IPv4 出口网卡: ${defiface:--}"
    printf '%-17s %17s %17s\n' "设备" "接收 RX" "发送 TX"
    for path in /sys/class/net/*; do
        [ -d "$path" ] || continue
        iface="${path##*/}"
        [ "$iface" = "lo" ] && continue
        [ -r "$path/statistics/rx_bytes" ] || continue
        rx="$(cat "$path/statistics/rx_bytes")"
        tx="$(cat "$path/statistics/tx_bytes")"
        printf '%-17s %17s %17s\n' "$iface" \
            "$(human_bytes "$rx")" "$(human_bytes "$tx")"
        if [ "$iface" = "$defiface" ]; then
            sumrx="$rx"; sumtx="$tx"
        fi
    done
    if [ -n "$defiface" ]; then
        echo "出口网卡收+发: $(human_bytes "$((sumrx + sumtx))")"
    fi
    echo "说明：包含本机业务与转发流量；虚拟接口可能重复计数。"
}

forward_traffic_view() {
    local id proto port host target_port numbers packets bytes total limit used
    meter_capture
    echo
    echo "===== 转发流量（nft forward 链，双向合计） ====="
    if ! nft list table inet "$METER_TABLE" >/dev/null 2>&1; then
        echo "尚未启用内核计数表；请先建立或恢复转发规则。"
    fi
    numbers="$(meter_counter_record 0)"
    IFS='|' read -r packets total <<< "$numbers"
    total="$(numeric_or_zero "$total")"
    echo "转发累计: $(human_bytes "$total")（$total 字节）"
    printf '%-6s %-8s %-9s %16s %s\n' "ID" "协议" "端口" "双向转发" "目标"
    while IFS='|' read -r id proto port host target_port; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        numbers="$(meter_counter_record "$id")"
        IFS='|' read -r packets bytes <<< "$numbers"
        printf '%-6s %-8s %-9s %16s %s:%s\n' "$id" "$proto" "$port" \
            "$(human_bytes "$(numeric_or_zero "$bytes")")" "$host" "$target_port"
    done < "$CONFIG"
    numbers="$(meter_counter_record WAN)"
    IFS='|' read -r packets bytes <<< "$numbers"
    echo "公网出口网卡: $(wan_interface)"
    echo "公网出口 TX: $(human_bytes "$(numeric_or_zero "$bytes")")（$(numeric_or_zero "$bytes") 字节，自本版本启动统计）"
    limit="$(quota_limit)"; used="$(quota_used)"
    echo "额度模式: $(quota_mode_label)"
    if [ "$limit" -gt 0 ]; then
        echo "额度设置: $(human_bytes "$limit")"
        echo "额度消耗: $(human_bytes "$used")（含阈值后的丢弃尝试流量）"
        if [ "$used" -ge "$limit" ]; then echo "额度状态: 已到达"; fi
    else
        echo "额度设置: 未启用"
    fi
    if is_paused; then
        echo "转发状态: 已暂停（$(cat "$PAUSED_FILE")）"
    else
        echo "转发状态: 未暂停"
    fi
    echo "说明：双向转发只统计 FORWARD/DNAT；出口 TX 统计所选网卡 postrouting（含本机业务/IPv4/IPv6）。"
    echo "出口网卡数据不一定等于云服务商计费数据；网卡上的内网流量也可能被计入。"
}

traffic_menu() {
    local choice
    while true; do
        echo
        echo "========= 流量统计 ========="
        echo "1. 查看系统网卡流量"
        echo "2. 查看转发流量（分规则）"
        echo "3. 查看全部"
        echo "0. 返回"
        read -rp "请选择: " choice
        case "$choice" in
            1) system_traffic_view ;;
            2) forward_traffic_view ;;
            3) system_traffic_view; forward_traffic_view ;;
            0) return ;;
            *) echo "输入错误"; continue ;;
        esac
        read -rp "回车继续..."
    done
}

set_quota_interactive() {
    local size bytes oldlimit oldused
    echo "当前额度模式: $(quota_mode_label)"
    echo "当前额度: $(human_bytes "$(quota_limit)")（0 表示未设置）"
    if [ "$(quota_mode)" = egress ] && ! valid_wan_interface "$(wan_interface)"; then
        echo -e "${RED}当前出口网卡无效，请先使用菜单 5 配置网卡${NC}"
        return 1
    fi
    read -rp "请输入新的额度（如 500M、1.5G、100G）: " size
    if ! bytes="$(parse_quota_size "$size")"; then
        echo -e "${RED}额度格式不正确${NC}"; return 1
    fi
    lock_begin || return 1
    meter_capture
    oldlimit="$(quota_limit)"; oldused="$(quota_used)"
    printf '%s\n' "$bytes" > "$QUOTA_LIMIT_FILE"
    printf '0\n' > "$QUOTA_USED_FILE"
    # 暂停时只改变额度，不能绕过手动恢复。
    if ! meter_rebuild_only; then
        printf '%s\n' "$oldlimit" > "$QUOTA_LIMIT_FILE"
        printf '%s\n' "$oldused" > "$QUOTA_USED_FILE"
        lock_end
        echo -e "${RED}内核额度设置失败，已恢复旧配置${NC}"
        return 1
    fi
    lock_end
    if ! quota_watchdog_install; then
        # 没有监控调度器，必须回滚额度，避免以为有自动停转发。
        lock_begin || return 1
        printf '%s\n' "$oldlimit" > "$QUOTA_LIMIT_FILE"
        printf '%s\n' "$oldused" > "$QUOTA_USED_FILE"
        meter_rebuild_only || true
        lock_end
        echo -e "${RED}无法启用后台额度检查，已回滚。${NC}"
        return 1
    fi
    echo -e "${GREEN}额度已设置为 $(human_bytes "$bytes")，从现在开始计数${NC}"
    echo "当前模式: $(quota_mode_label)"
    echo "达到额度后，仅阻断 DNAT 转发包；后台任务移除 NAT 转发映射。"
    if [ "$(quota_mode)" = egress ]; then
        echo "本机其他出站不会被切断，仍可能产生计费流量。"
    fi
    log_msg "quota enabled bytes=$bytes"
}

disable_quota_interactive() {
    local oldlimit oldused
    lock_begin || return 1
    meter_capture
    oldlimit="$(quota_limit)"; oldused="$(quota_used)"
    printf '0\n' > "$QUOTA_LIMIT_FILE"
    printf '0\n' > "$QUOTA_USED_FILE"
    if ! meter_rebuild_only; then
        printf '%s\n' "$oldlimit" > "$QUOTA_LIMIT_FILE"
        printf '%s\n' "$oldused" > "$QUOTA_USED_FILE"
        lock_end
        echo -e "${RED}关闭额度失败${NC}"
        return 1
    fi
    lock_end
    echo "已关闭额度限制。后台快照任务仍保留，用于保存流量统计。"
    echo "当前处于暂停时仍需要手动恢复转发。"
    log_msg "quota disabled"
}

set_quota_mode_interactive() {
    local selected newmode newwan proposed oldmode oldwan oldused
    echo "当前额度模式: $(quota_mode_label)"
    echo "1. 双向转发流量（仅 DNAT 转发，上传+下载）"
    echo "2. 公网出口网卡 TX（本机+转发的出站，按网卡发送字节）"
    read -rp "请选择模式 [1/2]: " selected
    case "$selected" in
        1) newmode=forward; newwan="$(cat "$WAN_IFACE_FILE" 2>/dev/null || true)" ;;
        2)
            newmode=egress
            proposed="$(wan_interface)"
            echo "检测到出口网卡: ${proposed:--}"
            read -rp "请输入出口网卡（回车使用上述网卡）: " newwan
            newwan="${newwan:-$proposed}"
            if ! valid_wan_interface "$newwan"; then
                echo -e "${RED}出口网卡无效，请通过 ip -br link 确认名称${NC}"
                return 1
            fi
            echo "提示：这里监控的是 $newwan 的全部 TX，不等于阿里云 CDT 的精确计费口径。"
            ;;
        *) echo "已取消"; return 0 ;;
    esac
    echo "切换模式将重置本次额度消耗，不会清空历史流量。"
    read -rp "确认请输入 yes: " selected
    [ "$selected" = yes ] || { echo "已取消"; return 0; }
    lock_begin || return 1
    meter_capture
    oldmode="$(quota_mode)"
    oldwan="$(cat "$WAN_IFACE_FILE" 2>/dev/null || true)"
    oldused="$(quota_used)"
    printf '%s\n' "$newmode" > "$QUOTA_MODE_FILE"
    if [ "$newmode" = egress ]; then
        printf '%s\n' "$newwan" > "$WAN_IFACE_FILE"
    fi
    printf '0\n' > "$QUOTA_USED_FILE"
    if ! meter_rebuild_only; then
        printf '%s\n' "$oldmode" > "$QUOTA_MODE_FILE"
        printf '%s\n' "$oldwan" > "$WAN_IFACE_FILE"
        printf '%s\n' "$oldused" > "$QUOTA_USED_FILE"
        lock_end
        echo -e "${RED}模式切换失败，旧限额配置已恢复；原 nft 规则未修改${NC}"
        return 1
    fi
    lock_end
    if [ "$(quota_limit)" -gt 0 ]; then
        quota_watchdog_install || echo -e "${YELLOW}注意：定时检查未成功启用，请检查 systemd timer${NC}"
    fi
    echo -e "${GREEN}当前额度模式: $(quota_mode_label)，本次用量已归零${NC}"
    log_msg "quota mode changed mode=$newmode wan=$newwan"
}

quota_menu() {
    local choice confirm
    while true; do
        echo
        echo "======= 转发流量自动停止 ======="
        if is_paused; then echo "状态: 已暂停"; else echo "状态: 正常"; fi
        echo "额度统计模式: $(quota_mode_label)"
        [ "$(quota_mode)" = egress ] && echo "计费参考网卡: $(wan_interface)"
        echo "当前额度: $(human_bytes "$(quota_limit)")（0 为无限制）"
        echo "额度计数: $(human_bytes "$(quota_used)")"
        echo "1. 设置/重新设置额度"
        echo "2. 取消额度限制"
        echo "3. 立即暂停全部转发"
        echo "4. 重新开始额度周期并恢复转发"
        echo "5. 切换额度统计模式（双向转发 / 公网出口 TX）"
        echo "0. 返回"
        read -rp "请选择: " choice
        case "$choice" in
            1) set_quota_interactive ;;
            2) disable_quota_interactive ;;
            5) set_quota_mode_interactive ;;
            3) pause_forwarding "手动暂停" ;;
            4)
                read -rp "确认恢复转发并重置本次额度？输入 yes: " confirm
                [ "$confirm" = yes ] && resume_forwarding || echo "已取消"
                ;;
            0) return ;;
            *) echo "输入错误"; continue ;;
        esac
        read -rp "回车继续..."
    done
}

# ============================================================
# nftables 规则生成 / 原子应用
# ============================================================

append_delete_existing_tables() {
    local file="$1"

    nft list table ip "$TABLE4" >/dev/null 2>&1 &&
        echo "delete table ip $TABLE4" >> "$file"

    nft list table ip6 "$TABLE6" >/dev/null 2>&1 &&
        echo "delete table ip6 $TABLE6" >> "$file"
    return 0
}

generate_map_ruleset() {
    local resolved="$1"
    local file="$2"

    local has4=0
    local has6=0
    local id proto listen_port host target_port family ip

    : > "$file"
    append_delete_existing_tables "$file"

    while IFS='|' read -r id proto listen_port host target_port family ip; do
        [ -n "${id:-}" ] || continue
        [ "$family" = "4" ] && has4=1
        [ "$family" = "6" ] && has6=1
    done < "$resolved"

    if [ "$has4" -eq 1 ]; then
        cat >> "$file" <<EOF
add table ip $TABLE4
add map ip $TABLE4 $MAP_TCP { type inet_service : ipv4_addr . inet_service; }
add map ip $TABLE4 $MAP_UDP { type inet_service : ipv4_addr . inet_service; }
add chain ip $TABLE4 prerouting { type nat hook prerouting priority -100; policy accept; }
add chain ip $TABLE4 output { type nat hook output priority -100; policy accept; }
add chain ip $TABLE4 postrouting { type nat hook postrouting priority 100; policy accept; }
add rule ip $TABLE4 prerouting fib daddr type local tcp dport != 0 dnat ip addr . port to tcp dport map @$MAP_TCP
add rule ip $TABLE4 prerouting fib daddr type local udp dport != 0 dnat ip addr . port to udp dport map @$MAP_UDP
add rule ip $TABLE4 output fib daddr type local tcp dport != 0 dnat ip addr . port to tcp dport map @$MAP_TCP
add rule ip $TABLE4 output fib daddr type local udp dport != 0 dnat ip addr . port to udp dport map @$MAP_UDP
add rule ip $TABLE4 postrouting ct status dnat masquerade
EOF
    fi

    if [ "$has6" -eq 1 ]; then
        cat >> "$file" <<EOF
add table ip6 $TABLE6
add map ip6 $TABLE6 $MAP_TCP { type inet_service : ipv6_addr . inet_service; }
add map ip6 $TABLE6 $MAP_UDP { type inet_service : ipv6_addr . inet_service; }
add chain ip6 $TABLE6 prerouting { type nat hook prerouting priority -100; policy accept; }
add chain ip6 $TABLE6 output { type nat hook output priority -100; policy accept; }
add chain ip6 $TABLE6 postrouting { type nat hook postrouting priority 100; policy accept; }
add rule ip6 $TABLE6 prerouting fib daddr type local tcp dport != 0 dnat ip6 addr . port to tcp dport map @$MAP_TCP
add rule ip6 $TABLE6 prerouting fib daddr type local udp dport != 0 dnat ip6 addr . port to udp dport map @$MAP_UDP
add rule ip6 $TABLE6 output fib daddr type local tcp dport != 0 dnat ip6 addr . port to tcp dport map @$MAP_TCP
add rule ip6 $TABLE6 output fib daddr type local udp dport != 0 dnat ip6 addr . port to udp dport map @$MAP_UDP
add rule ip6 $TABLE6 postrouting ct status dnat masquerade
EOF
    fi

    while IFS='|' read -r id proto listen_port host target_port family ip; do
        [ -n "${id:-}" ] || continue

        if [ "$family" = "4" ]; then
            case "$proto" in
                tcp)
                    echo "add element ip $TABLE4 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                    ;;
                udp)
                    echo "add element ip $TABLE4 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                    ;;
                both)
                    echo "add element ip $TABLE4 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                    echo "add element ip $TABLE4 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                    ;;
            esac
        else
            case "$proto" in
                tcp)
                    echo "add element ip6 $TABLE6 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                    ;;
                udp)
                    echo "add element ip6 $TABLE6 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                    ;;
                both)
                    echo "add element ip6 $TABLE6 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                    echo "add element ip6 $TABLE6 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                    ;;
            esac
        fi
    done < "$resolved"
}

generate_legacy_ruleset() {
    local resolved="$1"
    local file="$2"

    local has4=0
    local has6=0
    local id proto listen_port host target_port family ip target

    : > "$file"
    append_delete_existing_tables "$file"

    while IFS='|' read -r id proto listen_port host target_port family ip; do
        [ -n "${id:-}" ] || continue
        [ "$family" = "4" ] && has4=1
        [ "$family" = "6" ] && has6=1
    done < "$resolved"

    if [ "$has4" -eq 1 ]; then
        cat >> "$file" <<EOF
add table ip $TABLE4
add chain ip $TABLE4 prerouting { type nat hook prerouting priority -100; policy accept; }
add chain ip $TABLE4 output { type nat hook output priority -100; policy accept; }
add chain ip $TABLE4 postrouting { type nat hook postrouting priority 100; policy accept; }
add rule ip $TABLE4 postrouting ct status dnat masquerade
EOF
    fi

    if [ "$has6" -eq 1 ]; then
        cat >> "$file" <<EOF
add table ip6 $TABLE6
add chain ip6 $TABLE6 prerouting { type nat hook prerouting priority -100; policy accept; }
add chain ip6 $TABLE6 output { type nat hook output priority -100; policy accept; }
add chain ip6 $TABLE6 postrouting { type nat hook postrouting priority 100; policy accept; }
add rule ip6 $TABLE6 postrouting ct status dnat masquerade
EOF
    fi

    while IFS='|' read -r id proto listen_port host target_port family ip; do
        [ -n "${id:-}" ] || continue

        if [ "$family" = "4" ]; then
            target="$ip:$target_port"

            case "$proto" in
                tcp)
                    echo "add rule ip $TABLE4 prerouting fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE4 output fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    ;;
                udp)
                    echo "add rule ip $TABLE4 prerouting fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE4 output fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    ;;
                both)
                    echo "add rule ip $TABLE4 prerouting fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE4 prerouting fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE4 output fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE4 output fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    ;;
            esac
        else
            target="[$ip]:$target_port"

            case "$proto" in
                tcp)
                    echo "add rule ip6 $TABLE6 prerouting fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip6 $TABLE6 output fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    ;;
                udp)
                    echo "add rule ip6 $TABLE6 prerouting fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip6 $TABLE6 output fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    ;;
                both)
                    echo "add rule ip6 $TABLE6 prerouting fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip6 $TABLE6 prerouting fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip6 $TABLE6 output fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip6 $TABLE6 output fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    ;;
            esac
        fi
    done < "$resolved"
}

full_rebuild() {
    local verbose="${1:-1}"
    local skip_capture="${2:-0}"
    local resolved new_state nftfile mode

    if is_paused; then
        [ "$verbose" -eq 0 ] || echo -e "${YELLOW}转发已暂停，不会重建；请在额度菜单中恢复${NC}"
        return 0
    fi
    lock_begin || return 1

    resolved="$(mktemp)"
    new_state="$(mktemp)"
    nftfile="$(mktemp)"
    mode="map"

    if [ "$verbose" -eq 1 ]; then
        echo
        echo "================================="
        echo "       重建 NFT 转发规则"
        echo "================================="
    fi

    if ! prepare_resolved_rules "$resolved" "$new_state" "$verbose"; then
        rm -f "$resolved" "$new_state" "$nftfile"
        lock_end
        return 1
    fi

    # DNS 查询可能耗时，待解析完再取快照可减少重建时遗漏的数据。
    if [ "$skip_capture" -eq 0 ]; then meter_capture; fi
    generate_map_ruleset "$resolved" "$nftfile"
    if ! meter_append_ruleset "$resolved" "$nftfile"; then
        rm -f "$resolved" "$new_state" "$nftfile"
        lock_end
        return 1
    fi

    if ! nft -c -f "$nftfile" >/dev/null 2>&1; then
        mode="legacy"
        generate_legacy_ruleset "$resolved" "$nftfile"
        if ! meter_append_ruleset "$resolved" "$nftfile"; then
            rm -f "$resolved" "$new_state" "$nftfile"
            lock_end
            return 1
        fi

        if ! nft -c -f "$nftfile" >/dev/null 2>&1; then
            [ "$verbose" -eq 0 ] ||
                echo -e "${RED}nft 规则校验失败，原规则保持不变${NC}"

            log_msg "ruleset validation failed"
            rm -f "$resolved" "$new_state" "$nftfile"
            lock_end
            return 1
        fi
    fi

    # nft -f 整个批次由 nf_tables transaction 提交。
    if ! nft -f "$nftfile"; then
        [ "$verbose" -eq 0 ] ||
            echo -e "${RED}nft 原子提交失败，状态缓存未更新${NC}"

        log_msg "ruleset transaction failed"
        rm -f "$resolved" "$new_state" "$nftfile"
        lock_end
        return 1
    fi

    mv "$new_state" "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    printf '%s\n' "$mode" > "$MODE_FILE"

    if [ "$verbose" -eq 1 ]; then
        echo
        if [ "$mode" = "map" ]; then
            echo -e "模式: ${GREEN}nft map 增量更新${NC}"
        else
            echo -e "模式: ${YELLOW}兼容模式${NC}"
        fi
        echo -e "${GREEN}规则已原子更新${NC}"
    fi

    log_msg "full rebuild success mode=$mode"

    rm -f "$resolved" "$nftfile"
    lock_end
    return 0
}

tables_present_for_state() {
    local need4=0
    local need6=0
    local id host family ip proto listen_port target_port

    while IFS='|' read -r id host family ip proto listen_port target_port; do
        [ -n "${id:-}" ] || continue
        [ "$family" = "4" ] && need4=1
        [ "$family" = "6" ] && need6=1
    done < "$STATE_FILE"

    if [ "$need4" -eq 1 ]; then
        nft list table ip "$TABLE4" >/dev/null 2>&1 || return 1
    fi

    if [ "$need6" -eq 1 ]; then
        nft list table ip6 "$TABLE6" >/dev/null 2>&1 || return 1
    fi

    return 0
}

append_map_delete() {
    local file="$1"
    local family="$2"
    local proto="$3"
    local port="$4"

    if [ "$family" = "4" ]; then
        case "$proto" in
            tcp)
                echo "delete element ip $TABLE4 $MAP_TCP { $port }" >> "$file"
                ;;
            udp)
                echo "delete element ip $TABLE4 $MAP_UDP { $port }" >> "$file"
                ;;
            both)
                echo "delete element ip $TABLE4 $MAP_TCP { $port }" >> "$file"
                echo "delete element ip $TABLE4 $MAP_UDP { $port }" >> "$file"
                ;;
        esac
    else
        case "$proto" in
            tcp)
                echo "delete element ip6 $TABLE6 $MAP_TCP { $port }" >> "$file"
                ;;
            udp)
                echo "delete element ip6 $TABLE6 $MAP_UDP { $port }" >> "$file"
                ;;
            both)
                echo "delete element ip6 $TABLE6 $MAP_TCP { $port }" >> "$file"
                echo "delete element ip6 $TABLE6 $MAP_UDP { $port }" >> "$file"
                ;;
        esac
    fi
}

append_map_add() {
    local file="$1"
    local family="$2"
    local proto="$3"
    local listen_port="$4"
    local ip="$5"
    local target_port="$6"

    if [ "$family" = "4" ]; then
        case "$proto" in
            tcp)
                echo "add element ip $TABLE4 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                ;;
            udp)
                echo "add element ip $TABLE4 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                ;;
            both)
                echo "add element ip $TABLE4 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                echo "add element ip $TABLE4 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                ;;
        esac
    else
        case "$proto" in
            tcp)
                echo "add element ip6 $TABLE6 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                ;;
            udp)
                echo "add element ip6 $TABLE6 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                ;;
            both)
                echo "add element ip6 $TABLE6 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                echo "add element ip6 $TABLE6 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                ;;
        esac
    fi
}

refresh_dns() {
    if is_paused; then
        [ "${1:-1}" -eq 0 ] || echo "额度或手动暂停中，跳过 DNS 刷新"
        return 0
    fi
    local verbose="${1:-1}"
    local mode batch state_tmp
    local id proto listen_port host target_port rc
    local changed=0
    local unchanged=0
    local failed=0
    local need_rebuild=0

    lock_begin || return 1
    if [ "$(quota_limit)" -gt 0 ] &&
       ! nft list quota inet "$METER_TABLE" cap >/dev/null 2>&1; then
        lock_end
        pause_forwarding "DNS 刷新检测到额度防护规则缺失"
        return 1
    fi
    meter_capture
    if [ "$(quota_limit)" -gt 0 ] && [ "$(quota_used)" -ge "$(quota_limit)" ]; then
        lock_end
        pause_forwarding "刷新前检测到额度已满"
        return 0
    fi

    validate_config_structure || {
        lock_end
        return 1
    }

    mode="$(cat "$MODE_FILE" 2>/dev/null || true)"

    if [ -s "$CONFIG" ]; then
        if [ ! -s "$STATE_FILE" ] || ! tables_present_for_state; then
            need_rebuild=1
        fi
    fi

    if [ "$need_rebuild" -eq 1 ]; then
        [ "$verbose" -eq 0 ] ||
            echo -e "${YELLOW}运行状态不完整，执行完整恢复...${NC}"

        full_rebuild "$verbose"
        local rc_rebuild=$?
        lock_end
        return "$rc_rebuild"
    fi

    batch="$(mktemp)"
    state_tmp="$(mktemp)"
    cp "$STATE_FILE" "$state_tmp"
    : > "$batch"

    if [ "$verbose" -eq 1 ]; then
        echo
        echo "================================="
        echo "          刷新域名 IP"
        echo "================================="
    fi

    while IFS='|' read -r id proto listen_port host target_port; do
        [ -n "${id:-}" ] || continue
        host="$(trim_target "$host")"

        if is_domain "$host" && [ "$verbose" -eq 1 ]; then
            echo
            echo "ID=$id  $host"
            echo -n "查询: "
        fi

        resolve_target "$host"
        rc=$?

        if ! load_state "$id"; then
            need_rebuild=1
            break
        fi

        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 1 ] &&
               state_matches_config "$host" "$proto" "$listen_port" "$target_port"; then

                failed=$((failed + 1))

                if [ "$verbose" -eq 1 ] && is_domain "$host"; then
                    echo -e "${YELLOW}失败${NC}"
                    echo -e "保留旧 IP: ${CYAN}$STATE_IP${NC}"
                fi

                log_msg "dns failed id=$id host=$host keep=$STATE_IP"
                continue
            fi

            failed=$((failed + 1))

            [ "$verbose" -eq 0 ] ||
                echo -e "${RED}目标无效，保留当前 nft 规则不动${NC}"

            continue
        fi

        if [ "$STATE_HOST" = "$host" ] &&
           [ "$STATE_FAMILY" = "$TARGET_FAMILY" ] &&
           [ "$STATE_IP" = "$TARGET_IP" ] &&
           [ "$STATE_PROTO" = "$proto" ] &&
           [ "$STATE_LISTEN" = "$listen_port" ] &&
           [ "$STATE_TARGET_PORT" = "$target_port" ]; then

            unchanged=$((unchanged + 1))

            if [ "$verbose" -eq 1 ] && is_domain "$host"; then
                echo -e "${GREEN}成功${NC}"
                echo "当前 IP: $STATE_IP"
                echo "最新 IP: $TARGET_IP"
                echo -e "状态: ${GREEN}未变化，跳过 nft 更新${NC}"
            fi

            continue
        fi

        changed=$((changed + 1))

        if [ "$verbose" -eq 1 ]; then
            is_domain "$host" && echo -e "${GREEN}成功${NC}"
            echo "旧 IP: ${STATE_IP:-无}"
            echo "新 IP: $TARGET_IP"
        fi

        # 兼容模式或地址族变化时直接完整重建。
        if [ "$mode" != "map" ] ||
           [ "$STATE_FAMILY" != "$TARGET_FAMILY" ] ||
           [ "$STATE_PROTO" != "$proto" ] ||
           [ "$STATE_LISTEN" != "$listen_port" ] ||
           [ "$STATE_TARGET_PORT" != "$target_port" ]; then

            need_rebuild=1
            break
        fi

        append_map_delete \
            "$batch" \
            "$STATE_FAMILY" \
            "$STATE_PROTO" \
            "$STATE_LISTEN"

        append_map_add \
            "$batch" \
            "$TARGET_FAMILY" \
            "$proto" \
            "$listen_port" \
            "$TARGET_IP" \
            "$target_port"

        state_replace_in_file \
            "$state_tmp" \
            "$id" \
            "$host" \
            "$TARGET_FAMILY" \
            "$TARGET_IP" \
            "$proto" \
            "$listen_port" \
            "$target_port"
    done < "$CONFIG"

    if [ "$need_rebuild" -eq 1 ]; then
        rm -f "$batch" "$state_tmp"

        [ "$verbose" -eq 0 ] ||
            echo -e "${YELLOW}配置结构变化，执行完整原子重建...${NC}"

        full_rebuild "$verbose"
        local rc_rebuild=$?
        lock_end
        return "$rc_rebuild"
    fi

    if [ "$changed" -eq 0 ]; then
        rm -f "$batch" "$state_tmp"

        if [ "$verbose" -eq 1 ]; then
            echo
            echo "================================="
            echo -e "变化: ${GREEN}0${NC}（未写入 nftables）"
            echo "未变化: $unchanged"
            echo "DNS失败并保留旧IP: $failed"
            echo "================================="
        fi

        lock_end
        return 0
    fi

    # 删除旧 map 元素 + 添加新元素在同一 nft transaction 中提交。
    if nft -c -f "$batch" >/dev/null 2>&1 &&
       nft -f "$batch"; then

        mv "$state_tmp" "$STATE_FILE"
        chmod 600 "$STATE_FILE" 2>/dev/null || true

        [ "$verbose" -eq 0 ] ||
            echo -e "${GREEN}仅更新了发生变化的 nft map 元素${NC}"

        log_msg "incremental refresh changed=$changed unchanged=$unchanged failed=$failed"
    else
        rm -f "$batch" "$state_tmp"

        [ "$verbose" -eq 0 ] ||
            echo -e "${YELLOW}增量更新失败，尝试完整恢复...${NC}"

        full_rebuild "$verbose"
        local rc_rebuild=$?
        lock_end
        return "$rc_rebuild"
    fi

    rm -f "$batch"

    if [ "$verbose" -eq 1 ]; then
        echo
        echo "================================="
        echo "刷新完成"
        echo -e "变化并更新: ${GREEN}$changed${NC}"
        echo "未变化: $unchanged"
        echo "DNS失败并保留旧IP: $failed"
        echo "================================="
    fi

    lock_end
    return 0
}

# ============================================================
# 规则管理菜单功能
# ============================================================

add_rule() {
    local listen_port p proto host target_port id backup rc

    echo
    read -rp "本机监听端口: " listen_port

    valid_port "$listen_port" || {
        echo -e "${RED}端口无效，只允许 1-65535${NC}"
        return
    }

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

    if port_conflict "$proto" "$listen_port"; then
        echo -e "${RED}端口冲突：$listen_port/$proto 已被 ID=$CONFLICT_ID 使用${NC}"
        return
    fi

    read -rp "目标域名/IP: " host
    host="$(trim_target "$host")"

    echo -n "目标检测: $host ... "
    resolve_target "$host"
    rc=$?

    case "$rc" in
        0)
            echo -e "${GREEN}成功${NC}"
            echo -e "类型: ${CYAN}$TARGET_KIND${NC}"
            echo -e "解析: ${CYAN}$host -> $TARGET_IP${NC}"
            ;;
        2)
            echo -e "${RED}失败${NC}"
            echo -e "${RED}请输入合法 IPv4、IPv6 或完整域名；5555 会被拒绝。${NC}"
            return
            ;;
        3)
            echo -e "${RED}拒绝${NC}"
            echo -e "${RED}该地址属于未指定/广播/组播/link-local 等禁止目标。${NC}"
            return
            ;;
        *)
            echo -e "${RED}失败${NC}"
            echo -e "${RED}系统 DNS 与 $FALLBACK_DNS 均未得到可用 A/AAAA。${NC}"
            return
            ;;
    esac

    read -rp "目标端口: " target_port

    valid_port "$target_port" || {
        echo -e "${RED}目标端口无效，只允许 1-65535${NC}"
        return
    }

    if [ "$TARGET_FAMILY" = "6" ]; then
        echo -e "NFT 目标: ${CYAN}[${TARGET_IP}]:${target_port}${NC}"
    else
        echo -e "NFT 目标: ${CYAN}${TARGET_IP}:${target_port}${NC}"
    fi

    lock_begin || return

    if port_conflict "$proto" "$listen_port"; then
        echo -e "${RED}端口冲突：配置已被其他任务修改${NC}"
        lock_end
        return
    fi

    id="$(next_id)"
    backup_config "before-add" >/dev/null || true

    backup="$(mktemp)"
    cp "$CONFIG" "$backup"

    printf '%s|%s|%s|%s|%s\n' \
        "$id" "$proto" "$listen_port" "$host" "$target_port" \
        >> "$CONFIG"

    if full_rebuild 0; then
        rm -f "$backup"
        lock_end

        log_msg "rule added id=$id proto=$proto listen=$listen_port target=$host:$target_port"

        echo
        echo -e "${GREEN}添加成功${NC}"
        quota_watchdog_install || echo -e "${YELLOW}流量定时快照任务未启用，请使用菜单 9 安装${NC}"
        echo "ID: $id"
        echo "$proto :$listen_port -> $host:$target_port"
        return
    fi

    cp "$backup" "$CONFIG"
    rm -f "$backup"
    full_rebuild 0 >/dev/null 2>&1 || true

    lock_end
    echo -e "${RED}添加失败，配置已回滚${NC}"
}

list_rules() {
    local id proto listen_port host target_port current

    echo
    echo "================================================================================================"
    printf "%-5s %-7s %-10s %-28s %-10s %-30s\n" \
        "ID" "协议" "监听端口" "目标" "目标端口" "当前解析IP"
    echo "================================================================================================"

    if [ ! -s "$CONFIG" ]; then
        echo "暂无规则"
    else
        while IFS='|' read -r id proto listen_port host target_port; do
            current="-"

            if load_state "$id"; then
                if [ "$STATE_FAMILY" = "6" ]; then
                    current="[$STATE_IP]"
                else
                    current="$STATE_IP"
                fi
            fi

            printf "%-5s %-7s %-10s %-28s %-10s %-30s\n" \
                "$id" "$proto" "$listen_port" "$host" "$target_port" "$current"
        done < "$CONFIG"
    fi

    echo "================================================================================================"
}

delete_rule() {
    local delete_id confirm backup

    list_rules

    echo
    echo -e "${YELLOW}提示：输入 99 删除全部规则${NC}"
    read -rp "请输入要删除的 ID: " delete_id

    if [ "$delete_id" = "99" ]; then
        echo
        echo -e "${RED}警告：这会删除全部转发规则。${NC}"
        read -rp "确认请输入 yes: " confirm

        [ "$confirm" = "yes" ] || {
            echo "已取消"
            return
        }

        lock_begin || return

        backup_config "before-delete-all" >/dev/null || true

        backup="$(mktemp)"
        cp "$CONFIG" "$backup"
        : > "$CONFIG"

        if full_rebuild 0; then
            : > "$STATE_FILE"
            rm -f "$backup"
            lock_end

            log_msg "all forwarding rules deleted"
            echo -e "${GREEN}全部规则已删除${NC}"
            return
        fi

        cp "$backup" "$CONFIG"
        rm -f "$backup"
        lock_end

        echo -e "${RED}删除失败，配置已回滚${NC}"
        return
    fi

    if ! grep -q "^${delete_id}|" "$CONFIG"; then
        echo -e "${RED}没有找到 ID: $delete_id${NC}"
        return
    fi

    lock_begin || return

    if ! grep -q "^${delete_id}|" "$CONFIG"; then
        echo -e "${RED}规则已发生变化，请重新操作${NC}"
        lock_end
        return
    fi

    backup_config "before-delete-id-${delete_id}" >/dev/null || true

    backup="$(mktemp)"
    cp "$CONFIG" "$backup"

    awk -F'|' -v id="$delete_id" '$1 != id' "$CONFIG" > "${CONFIG}.tmp"
    mv "${CONFIG}.tmp" "$CONFIG"

    if full_rebuild 0; then
        rm -f "$backup"
        lock_end

        log_msg "rule deleted id=$delete_id"
        echo -e "${GREEN}ID $delete_id 已删除${NC}"
        return
    fi

    cp "$backup" "$CONFIG"
    rm -f "$backup"
    full_rebuild 0 >/dev/null 2>&1 || true

    lock_end
    echo -e "${RED}删除失败，配置已回滚${NC}"
}

show_nft() {
    echo
    echo "===== IPv4 ====="
    nft list table ip "$TABLE4" 2>/dev/null ||
        echo "当前没有 IPv4 nft 转发规则"

    echo
    echo "===== IPv6 ====="
    nft list table ip6 "$TABLE6" 2>/dev/null ||
        echo "当前没有 IPv6 nft 转发规则"

    echo
    echo "===== 运行模式 ====="

    case "$(cat "$MODE_FILE" 2>/dev/null || true)" in
        map) echo "nft map 增量更新" ;;
        legacy) echo "兼容模式" ;;
        *) echo "尚未建立规则" ;;
    esac
}

# ============================================================
# 定时 DNS 刷新
# ============================================================

get_crontab() {
    crontab -l 2>/dev/null || true
}

remove_cron_block() {
    local begin="$1"
    local end="$2"
    local tmp

    tmp="$(mktemp)"

    get_crontab |
        awk -v begin="$begin" -v end="$end" '
            $0 == begin {skip=1; next}
            $0 == end {skip=0; next}
            !skip {print}
        ' > "$tmp"

    crontab "$tmp"
    rm -f "$tmp"
}

refresh_schedule_state() {
    REFRESH_STATE="关闭"
    REFRESH_BACKEND="-"
    REFRESH_DETAIL=""

    if has_systemd &&
       [ -f "$REFRESH_TIMER" ] &&
       systemctl is-enabled nft-forward-refresh.timer >/dev/null 2>&1; then

        REFRESH_STATE="开启"
        REFRESH_BACKEND="systemd timer"
        REFRESH_DETAIL="$(
            systemctl show nft-forward-refresh.timer \
                -p NextElapseUSecRealtime \
                --value \
                --no-pager 2>/dev/null || true
        )"
        return
    fi

    if command -v crontab >/dev/null 2>&1 &&
       get_crontab | grep -qF "$CRON_REFRESH_BEGIN"; then

        REFRESH_STATE="开启"
        REFRESH_BACKEND="cron"
        REFRESH_DETAIL="$(
            get_crontab |
            sed -n "/$CRON_REFRESH_BEGIN/,/$CRON_REFRESH_END/p" |
            grep -v '^#' |
            head -n1
        )"
    fi
}

enable_refresh_schedule() {
    local interval tmp hours

    echo
    read -rp "每隔多少分钟解析一次域名 [默认 ${DEFAULT_INTERVAL}]: " interval
    interval="${interval:-$DEFAULT_INTERVAL}"

    if ! [[ "$interval" =~ ^[0-9]+$ ]] ||
       [ "$interval" -lt 1 ] ||
       [ "$interval" -gt 1440 ]; then

        echo -e "${RED}请输入 1-1440 之间的分钟数${NC}"
        return
    fi

    install_current_script || {
        echo -e "${RED}无法安装到 $INSTALL_PATH${NC}"
        return
    }

    if has_systemd; then
        if command -v crontab >/dev/null 2>&1; then
            remove_cron_block "$CRON_REFRESH_BEGIN" "$CRON_REFRESH_END"
        fi

        cat > "$REFRESH_SERVICE" <<EOF
[Unit]
Description=nft-forward DNS refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --refresh
EOF

        cat > "$REFRESH_TIMER" <<EOF
[Unit]
Description=Periodically refresh nft-forward DNS targets

[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval}min
AccuracySec=15s
Persistent=true
Unit=nft-forward-refresh.service

[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload

        if systemctl enable --now nft-forward-refresh.timer >/dev/null; then
            log_msg "systemd timer enabled interval=${interval}min"

            echo -e "${GREEN}已开启 systemd timer：每 ${interval} 分钟检查域名 IP${NC}"
            echo "IP 未变化时不会写 nftables。"
        else
            echo -e "${RED}systemd timer 启动失败${NC}"
        fi

        return
    fi

    command -v crontab >/dev/null 2>&1 || {
        echo -e "${RED}当前系统无 systemd 且未安装 crontab${NC}"
        return
    }

    ensure_cron_service
    remove_cron_block "$CRON_REFRESH_BEGIN" "$CRON_REFRESH_END"

    tmp="$(mktemp)"
    get_crontab > "$tmp"

    {
        echo "$CRON_REFRESH_BEGIN"

        if [ "$interval" -le 59 ]; then
            echo "*/$interval * * * * $INSTALL_PATH --refresh >/dev/null 2>&1"
        else
            hours=$((interval / 60))
            [ "$hours" -lt 1 ] && hours=1
            echo "0 */$hours * * * $INSTALL_PATH --refresh >/dev/null 2>&1"
        fi

        echo "$CRON_REFRESH_END"
    } >> "$tmp"

    crontab "$tmp"
    rm -f "$tmp"

    log_msg "cron refresh enabled interval=${interval}min"
    echo -e "${GREEN}已开启 cron 定时解析${NC}"
}

disable_refresh_schedule() {
    local changed=0

    if has_systemd; then
        systemctl disable --now nft-forward-refresh.timer >/dev/null 2>&1 || true
        systemctl stop nft-forward-refresh.service >/dev/null 2>&1 || true

        if [ -f "$REFRESH_TIMER" ] ||
           [ -f "$REFRESH_SERVICE" ]; then

            rm -f "$REFRESH_TIMER" "$REFRESH_SERVICE"
            systemctl daemon-reload
            changed=1
        fi
    fi

    if command -v crontab >/dev/null 2>&1 &&
       get_crontab | grep -qF "$CRON_REFRESH_BEGIN"; then

        remove_cron_block "$CRON_REFRESH_BEGIN" "$CRON_REFRESH_END"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        log_msg "scheduled DNS refresh disabled"
        echo -e "${GREEN}定时解析已关闭${NC}"
    else
        echo "当前未开启定时解析"
    fi
}

timer_menu() {
    local choice

    while true; do
        clear

        echo "================================="
        echo "        定时域名解析"
        echo "================================="

        refresh_schedule_state

        echo "状态: $REFRESH_STATE"
        echo "调度器: $REFRESH_BACKEND"

        [ -n "$REFRESH_DETAIL" ] &&
            echo "详情: $REFRESH_DETAIL"

        echo
        echo "1. 开启/修改定时解析"
        echo "2. 关闭定时解析"
        echo "3. 立即检查一次"
        echo "0. 返回"
        echo "================================="

        read -rp "请选择: " choice

        case "$choice" in
            1)
                enable_refresh_schedule
                read -rp "回车继续..."
                ;;
            2)
                disable_refresh_schedule
                read -rp "回车继续..."
                ;;
            3)
                refresh_dns 1
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

# ============================================================
# 开机自动恢复
# ============================================================

boot_restore_state() {
    BOOT_STATE="关闭"
    BOOT_BACKEND="-"

    if has_systemd &&
       [ -f "$BOOT_SERVICE" ] &&
       systemctl is-enabled nft-forward.service >/dev/null 2>&1; then

        BOOT_STATE="开启"
        BOOT_BACKEND="systemd"
        return
    fi

    if [ -f "$OPENRC_START" ]; then
        BOOT_STATE="开启"
        BOOT_BACKEND="OpenRC local.d"
        return
    fi

    if command -v crontab >/dev/null 2>&1 &&
       get_crontab | grep -qF "$CRON_BOOT_BEGIN"; then

        BOOT_STATE="开启"
        BOOT_BACKEND="@reboot"
    fi
}

enable_boot_restore() {
    local tmp

    install_current_script || {
        echo -e "${RED}无法安装到 $INSTALL_PATH${NC}"
        return
    }

    if has_systemd; then
        cat > "$BOOT_SERVICE" <<EOF
[Unit]
Description=nft-forward restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable nft-forward.service >/dev/null

        log_msg "boot restore enabled backend=systemd"
        echo -e "${GREEN}已开启 systemd 开机自动恢复${NC}"
        return
    fi

    if command -v rc-update >/dev/null 2>&1; then
        mkdir -p /etc/local.d

        cat > "$OPENRC_START" <<EOF
#!/bin/sh
$INSTALL_PATH --restore >>$LOG_FILE 2>&1
EOF

        chmod +x "$OPENRC_START"
        rc-update add local default >/dev/null 2>&1 || true

        log_msg "boot restore enabled backend=openrc"
        echo -e "${GREEN}已开启 OpenRC 开机自动恢复${NC}"
        return
    fi

    command -v crontab >/dev/null 2>&1 || {
        echo -e "${RED}当前系统没有可用开机启动机制${NC}"
        return
    }

    remove_cron_block "$CRON_BOOT_BEGIN" "$CRON_BOOT_END"

    tmp="$(mktemp)"
    get_crontab > "$tmp"

    {
        echo "$CRON_BOOT_BEGIN"
        echo "@reboot $INSTALL_PATH --restore >/dev/null 2>&1"
        echo "$CRON_BOOT_END"
    } >> "$tmp"

    crontab "$tmp"
    rm -f "$tmp"

    log_msg "boot restore enabled backend=cron"
    echo -e "${GREEN}已开启 @reboot 自动恢复${NC}"
}

disable_boot_restore() {
    local changed=0

    if has_systemd; then
        systemctl disable --now nft-forward.service >/dev/null 2>&1 || true

        if [ -f "$BOOT_SERVICE" ]; then
            rm -f "$BOOT_SERVICE"
            systemctl daemon-reload
            changed=1
        fi
    fi

    if [ -f "$OPENRC_START" ]; then
        rm -f "$OPENRC_START"
        changed=1
    fi

    if command -v crontab >/dev/null 2>&1 &&
       get_crontab | grep -qF "$CRON_BOOT_BEGIN"; then

        remove_cron_block "$CRON_BOOT_BEGIN" "$CRON_BOOT_END"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        log_msg "boot restore disabled"
        echo -e "${GREEN}开机自动恢复已关闭${NC}"
    else
        echo "当前未开启开机自动恢复"
    fi
}

boot_menu() {
    local choice

    while true; do
        clear

        echo "================================="
        echo "        开机自动恢复"
        echo "================================="

        boot_restore_state

        echo "状态: $BOOT_STATE"
        echo "方式: $BOOT_BACKEND"

        echo
        echo "1. 开启"
        echo "2. 关闭"
        echo "3. 立即完整恢复一次"
        echo "0. 返回"
        echo "================================="

        read -rp "请选择: " choice

        case "$choice" in
            1)
                enable_boot_restore
                read -rp "回车继续..."
                ;;
            2)
                disable_boot_restore
                read -rp "回车继续..."
                ;;
            3)
                full_rebuild 1
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

# ============================================================
# 安装 / 卸载 / 日志
# ============================================================

install_current_script() {
    local current installed

    ensure_data_files
    mkdir -p "$(dirname "$INSTALL_PATH")"

    current="$(readlink -f "$SCRIPT_PATH" 2>/dev/null || printf '%s' "$SCRIPT_PATH")"
    installed="$(readlink -f "$INSTALL_PATH" 2>/dev/null || true)"

    if [ "$current" != "$installed" ]; then
        cp -f "$SCRIPT_PATH" "$INSTALL_PATH" || return 1
    fi

    chmod 755 "$INSTALL_PATH"
    write_logrotate_config

    log_msg "installed/updated binary path=$INSTALL_PATH version=$APP_VERSION"
}

install_or_update() {
    local backup=""

    ensure_data_files

    if [ -s "$CONFIG" ]; then
        backup="$(backup_config "before-install" || true)"
        [ -z "$backup" ] || echo "配置备份: $backup"
    fi

    install_current_script || {
        echo -e "${RED}安装失败${NC}"
        return 1
    }

    echo
    echo -e "${GREEN}安装/更新完成${NC}"
    echo "来源: $SCRIPT_PATH"
    echo "命令: $INSTALL_PATH"
    echo "版本: $APP_VERSION"
    echo "配置: $CONFIG"
    echo "状态: $STATE_FILE"
    echo "日志: $LOG_FILE"
    echo "备份: $BACKUP_DIR"
    echo "日志轮转: $LOGROTATE_FILE"
    if [ -s "$CONFIG" ]; then
        ensure_runtime_rules || echo -e "${YELLOW}注意：内核流量表未成功初始化，请检查 nftables${NC}"
    fi
    # 从 2.4.0 升级时旧计数表已存在，主动重建一次才能启用 WAN TX 统计。
    lock_begin && {
        meter_capture
        meter_rebuild_only || echo -e "${YELLOW}新计数表未加载；原转发规则保持不变，请检查 nftables 兼容性${NC}"
        lock_end
    }
    quota_watchdog_install || echo -e "${YELLOW}提示：流量快照/额度定时任务启用失败${NC}"
}

show_recent_log() {
    echo
    echo "日志文件: $LOG_FILE"
    echo "---------------------------------"

    if [ -s "$LOG_FILE" ]; then
        tail -n 80 "$LOG_FILE"
    else
        echo "暂无日志"
    fi
}

uninstall_script() {
    local confirm purge

    echo
    echo -e "${RED}将卸载 nft-forward 程序及自动任务。${NC}"
    echo "默认保留配置、备份和日志。"

    read -rp "确认卸载请输入 yes: " confirm

    [ "$confirm" = "yes" ] || {
        echo "已取消"
        return
    }

    # 卸载前先停止程序自己的 NAT 映射，避免留下没有监控的无限制转发。
    pause_forwarding "卸载程序" || {
        echo -e "${RED}无法安全关闭正在运行的转发，取消卸载${NC}"
        return 1
    }
    quota_watchdog_disable
    disable_refresh_schedule >/dev/null 2>&1 || true
    disable_boot_restore >/dev/null 2>&1 || true

    rm -f "$LOGROTATE_FILE"

    if [ -e "$INSTALL_PATH" ]; then
        rm -f "$INSTALL_PATH"
    fi

    echo
    read -rp "是否同时删除配置、状态、备份和日志？输入 DELETE 才会删除: " purge

    if [ "$purge" = "DELETE" ]; then
        rm -f "$CONFIG" "$LOG_FILE"
        rm -rf "$STATE_DIR" "$BACKUP_DIR"

        echo -e "${YELLOW}配置和运行数据已删除${NC}"
    else
        echo "已保留:"
        echo "  $CONFIG"
        echo "  $STATE_DIR"
        echo "  $BACKUP_DIR"
        echo "  $LOG_FILE"
    fi

    echo -e "${GREEN}卸载完成${NC}"
}

# ============================================================
# 状态概览
# ============================================================

count_config_rules() {
    awk -F'|' \
        'NF >= 5 && $1 ~ /^[0-9]+$/ {count++} END {print count+0}' \
        "$CONFIG" 2>/dev/null
}

count_state_rules() {
    awk -F'|' \
        'NF >= 7 && $1 ~ /^[0-9]+$/ {count++} END {print count+0}' \
        "$STATE_FILE" 2>/dev/null
}

nft_runtime_state() {
    IPV4_TABLE_STATE="未加载"
    IPV6_TABLE_STATE="未加载"

    nft list table ip "$TABLE4" >/dev/null 2>&1 &&
        IPV4_TABLE_STATE="已加载"

    nft list table ip6 "$TABLE6" >/dev/null 2>&1 &&
        IPV6_TABLE_STATE="已加载"
}

last_log_time() {
    if [ -s "$LOG_FILE" ]; then
        tail -n1 "$LOG_FILE" 2>/dev/null |
            awk '{print $1" "$2}'
    else
        echo "-"
    fi
}

status_overview() {
    local config_count state_count mode lastlog

    ensure_data_files

    config_count="$(count_config_rules)"
    state_count="$(count_state_rules)"
    mode="$(cat "$MODE_FILE" 2>/dev/null || true)"
    [ -n "$mode" ] || mode="未建立"

    refresh_schedule_state
    boot_restore_state
    nft_runtime_state
    lastlog="$(last_log_time)"

    echo
    echo "============================================================"
    echo "                    NFT-FORWARD 当前状态"
    echo "============================================================"

    printf "%-20s %s\n" "脚本版本:" "v$APP_VERSION"
    printf "%-20s %s\n" "配置规则数:" "$config_count"
    printf "%-20s %s\n" "状态缓存规则数:" "$state_count"
    printf "%-20s %s\n" "IPv4 nft 表:" "$IPV4_TABLE_STATE"
    printf "%-20s %s\n" "IPv6 nft 表:" "$IPV6_TABLE_STATE"

    case "$mode" in
        map)
            printf "%-20s %s\n" "NFT 模式:" "map 增量更新"
            ;;
        legacy)
            printf "%-20s %s\n" "NFT 模式:" "兼容模式"
            ;;
        *)
            printf "%-20s %s\n" "NFT 模式:" "$mode"
            ;;
    esac

    printf "%-20s %s" "定时解析:" "$REFRESH_STATE"
    [ "$REFRESH_STATE" = "开启" ] &&
        printf " (%s)" "$REFRESH_BACKEND"
    echo

    [ -n "$REFRESH_DETAIL" ] &&
        printf "%-20s %s\n" "下次/任务详情:" "$REFRESH_DETAIL"

    printf "%-20s %s" "开机自动恢复:" "$BOOT_STATE"
    [ "$BOOT_STATE" = "开启" ] &&
        printf " (%s)" "$BOOT_BACKEND"
    echo

    printf "%-20s %s\n" "额度模式:" "$(quota_mode_label)"
    [ "$(quota_mode)" = egress ] && printf "%-20s %s\n" "公网出口网卡:" "$(wan_interface)"
    printf "%-20s %s\n" "额度限额:" "$(human_bytes "$(quota_limit)")"
    printf "%-20s %s\n" "额度累计:" "$(human_bytes "$(quota_used)")"
    printf "%-20s %s\n" "最后日志时间:" "$lastlog"
    printf "%-20s %s\n" "配置文件:" "$CONFIG"
    printf "%-20s %s\n" "日志文件:" "$LOG_FILE"

    if [ "$config_count" -eq "$state_count" ]; then
        echo -e "一致性:             ${GREEN}正常${NC}"
    else
        echo -e "一致性:             ${YELLOW}配置与状态缓存数量不一致${NC}"
    fi

    if is_paused; then
        echo -e "运行状态:           ${YELLOW}已暂停（不会自动恢复）${NC}"
    elif [ "$config_count" -gt 0 ] &&
       [ "$IPV4_TABLE_STATE" = "未加载" ] &&
       [ "$IPV6_TABLE_STATE" = "未加载" ]; then

        echo -e "运行状态:           ${RED}配置存在，但内核 nft 表未加载${NC}"
    elif [ "$config_count" -eq 0 ]; then
        echo "运行状态:           暂无转发规则"
    else
        echo -e "运行状态:           ${GREEN}已运行${NC}"
    fi

    echo "============================================================"
}

menu_status_line() {
    local config_count

    config_count="$(count_config_rules)"
    refresh_schedule_state
    boot_restore_state

    printf "规则:%s | 定时解析:%s | 开机恢复:%s | 转发:%s\n" \
        "$config_count" \
        "$REFRESH_STATE" \
        "$BOOT_STATE" \
        "$(if is_paused; then echo 暂停; else echo 正常; fi)"
}

# ============================================================
# 主菜单 / CLI
# ============================================================

ensure_runtime_rules() {
    if is_paused; then
        if nft list table ip "$TABLE4" >/dev/null 2>&1 ||
           nft list table ip6 "$TABLE6" >/dev/null 2>&1; then
            pause_forwarding "再次确保暂停状态" || return 1
        fi
        return 0
    fi
    if [ ! -s "$CONFIG" ]; then
        return 0
    fi

    if [ ! -s "$STATE_FILE" ] ||
       ! tables_present_for_state; then

        echo -e "${YELLOW}检测到内核规则未恢复，正在从配置恢复...${NC}"
        full_rebuild 1 || return 1
    fi
    if ! nft list table inet "$METER_TABLE" >/dev/null 2>&1; then
        lock_begin || return 1
        meter_rebuild_only
        local meter_rc=$?
        lock_end
        [ "$meter_rc" -eq 0 ] || return "$meter_rc"
    fi
}

main_menu() {
    local choice

    while true; do
        clear

        echo "================================="
        echo "      NFT 转发管理脚本 v$APP_VERSION"
        echo "================================="
        menu_status_line
        echo "================================="
        echo "1. 添加转发"
        echo "2. 删除转发"
        echo "3. 查看转发"
        echo "4. 刷新域名 IP"
        echo "5. 查看 nftables"
        echo "6. 定时解析域名"
        echo "7. 开机自动恢复"
        echo "8. 重新检测环境"
        echo "9. 安装当前脚本到系统"
        echo "10. 查看最近日志"
        echo "11. 卸载脚本"
        echo "12. 当前状态概览"
        echo "13. 流量统计（系统/转发）"
        echo "14. 转发额度/自动停止（双向或公网出口 TX）"
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
                refresh_dns 1
                read -rp "回车继续..."
                ;;
            5)
                show_nft
                read -rp "回车继续..."
                ;;
            6)
                timer_menu
                ;;
            7)
                boot_menu
                ;;
            8)
                preflight_check
                read -rp "回车继续..."
                ;;
            9)
                install_or_update
                read -rp "回车继续..."
                ;;
            10)
                show_recent_log
                read -rp "回车继续..."
                ;;
            11)
                uninstall_script
                read -rp "回车继续..."
                ;;
            12)
                status_overview
                read -rp "回车继续..."
                ;;
            13) traffic_menu ;;
            14) quota_menu ;;
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

main() {
    local action="${1:-}"

    detect_os

    case "$action" in
        --version)
            echo "$APP_VERSION"
            exit 0
            ;;
        --status)
            [ "$(id -u)" -eq 0 ] ||
                die "请使用 root 查看完整状态"

            ensure_data_files
            status_overview
            exit 0
            ;;
        --uninstall)
            [ "$(id -u)" -eq 0 ] ||
                die "请使用 root 运行卸载"

            ensure_data_files
            uninstall_script
            exit $?
            ;;
        --refresh|--restore)
            runtime_check_quiet || {
                log_msg "$action failed: runtime dependency missing"
                exit 1
            }
            ;;
        --quota-check|--traffic|--pause|--resume)
            [ "$(id -u)" -eq 0 ] && command -v nft >/dev/null 2>&1 ||
                die "必须使用 root，且需要 nft 命令"
            ;;
        *)
            preflight_check
            ;;
    esac

    ensure_data_files
    case "$action" in
        --refresh|--restore|--install|'') enable_forwarding ;;
    esac

    case "$action" in
        --quota-check)
            quota_check
            exit $?
            ;;
        --traffic)
            system_traffic_view
            forward_traffic_view
            exit 0
            ;;
        --pause)
            pause_forwarding "命令行手动暂停"
            exit $?
            ;;
        --resume)
            resume_forwarding
            exit $?
            ;;
        --refresh)
            refresh_dns 0
            exit $?
            ;;
        --restore)
            full_rebuild 0
            exit $?
            ;;
        --install)
            install_or_update
            exit $?
            ;;
        "")
            write_logrotate_config
            ensure_runtime_rules || true
            main_menu
            ;;
        *)
            echo "用法:"
            echo "  $0"
            echo "  $0 --status"
            echo "  $0 --refresh"
            echo "  $0 --restore"
            echo "  $0 --install"
            echo "  $0 --uninstall"
            echo "  $0 --version"
            echo "  $0 --traffic"
            echo "  $0 --quota-check"
            echo "  $0 --pause"
            echo "  $0 --resume"
            exit 1
            ;;
    esac
}

main "$@"