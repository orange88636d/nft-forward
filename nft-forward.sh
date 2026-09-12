#!/usr/bin/env bash
set -u

VERSION="2.1.0"

CONFIG="/etc/nft-forward.conf"
STATE_DIR="/var/lib/nft-forward"
STATE_FILE="$STATE_DIR/state.conf"
MODE_FILE="$STATE_DIR/mode"
LOCK_FILE="/run/lock/nft-forward.lock"
LOG_FILE="/var/log/nft-forward.log"
LOGROTATE_FILE="/etc/logrotate.d/nft-forward"
BACKUP_DIR="/var/backups/nft-forward"
MAX_BACKUPS=20

REFRESH_SERVICE="/etc/systemd/system/nft-forward-refresh.service"
REFRESH_TIMER="/etc/systemd/system/nft-forward-refresh.timer"

TABLE="nft_forward"
TABLE6="nft_forward6"
MAP_TCP="tcp_map"
MAP_UDP="udp_map"

INSTALL_PATH="/usr/local/bin/nft-forward"
SYSTEMD_SERVICE="/etc/systemd/system/nft-forward.service"
OPENRC_START="/etc/local.d/nft-forward.start"

CRON_MARK_BEGIN="# BEGIN NFT-FORWARD"
CRON_MARK_END="# END NFT-FORWARD"
BOOT_CRON_BEGIN="# BEGIN NFT-FORWARD-BOOT"
BOOT_CRON_END="# END NFT-FORWARD-BOOT"

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
NONINTERACTIVE=0
LOCK_DEPTH=0

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

has_systemd() {
    [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

backup_config() {
    local reason="${1:-manual}"
    local stamp file

    ensure_data_files
    mkdir -p "$BACKUP_DIR"

    stamp="$(date '+%Y%m%d-%H%M%S')"
    file="$BACKUP_DIR/nft-forward.conf.${stamp}.$$.${reason}.bak"

    cp -a "$CONFIG" "$file" || return 1
    chmod 600 "$file" 2>/dev/null || true

    # 只保留最近 MAX_BACKUPS 份。
    ls -1t "$BACKUP_DIR"/nft-forward.conf.*.bak 2>/dev/null |
        tail -n +$((MAX_BACKUPS + 1)) |
        xargs -r rm -f --

    log_msg "config backup created: $file"
    printf '%s' "$file"
}

write_logrotate_config() {
    mkdir -p "$(dirname "$LOGROTATE_FILE")"
    cat > "$LOGROTATE_FILE" <<EOF
$LOG_FILE {
    weekly
    rotate 8
    size 1M
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

show_recent_log() {
    echo
    echo "日志文件: $LOG_FILE"
    echo "---------------------------------"
    if [ -f "$LOG_FILE" ]; then
        tail -n 80 "$LOG_FILE"
    else
        echo "暂无日志"
    fi
}

log_msg() {
    local msg="$*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    echo -e "${RED}$*${NC}" >&2
    log_msg "ERROR: $*"
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
    [ "${#packages[@]}" -gt 0 ] || return 0

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

runtime_check_quiet() {
    [ "$(id -u)" -eq 0 ] || return 1
    command -v nft >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    command -v flock >/dev/null 2>&1 || return 1

    if ! command -v host >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
        return 1
    fi

    return 0
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
    local need_dns_direct=0
    local need_timeout=0
    local need_flock=0
    local need_logrotate=0

    if command -v nft >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] nftables"
    else
        echo -e "[${RED}缺少${NC}] nftables"
        need_nft=1
    fi

    if has_systemd; then
        echo -e "[${GREEN}OK${NC}] systemd timer（首选调度器）"
        need_cron=0
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

    if command -v host >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] 直连 DNS 查询工具"
    else
        echo -e "[${RED}缺少${NC}] host/nslookup（1.1.1.1 备用查询需要）"
        need_dns_direct=1
    fi

    if command -v timeout >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] timeout"
    else
        echo -e "[${RED}缺少${NC}] timeout（DNS 防卡死需要）"
        need_timeout=1
    fi

    if command -v flock >/dev/null 2>&1; then
        echo -e "[${GREEN}OK${NC}] flock"
    else
        echo -e "[${RED}缺少${NC}] flock（防止定时任务并发修改 nft）"
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
        echo -e "[${YELLOW}缺少${NC}] logrotate（日志轮转需要）"
        need_logrotate=1
    fi

    if [ "$need_nft" -eq 0 ] &&
       [ "$need_cron" -eq 0 ] &&
       [ "$need_dns_direct" -eq 0 ] &&
       [ "$need_timeout" -eq 0 ] &&
       [ "$need_flock" -eq 0 ] &&
       [ "$need_logrotate" -eq 0 ]; then
        echo
        echo -e "${GREEN}环境检测通过${NC}"
        sleep 1
        return 0
    fi

    [ -n "$PKG_MANAGER" ] || die "无法识别包管理器，请手动安装 nftables、cron、DNS 工具、coreutils、util-linux"

    case "$PKG_MANAGER" in
        apt)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_cron" -eq 1 ] && missing+=("cron")
            [ "$need_dns_direct" -eq 1 ] && missing+=("dnsutils")
            [ "$need_timeout" -eq 1 ] && missing+=("coreutils")
            [ "$need_flock" -eq 1 ] && missing+=("util-linux")
            [ "$need_logrotate" -eq 1 ] && missing+=("logrotate")
            ;;
        apk)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_cron" -eq 1 ] && missing+=("dcron")
            [ "$need_dns_direct" -eq 1 ] && missing+=("bind-tools")
            [ "$need_timeout" -eq 1 ] && missing+=("coreutils")
            [ "$need_flock" -eq 1 ] && missing+=("util-linux")
            [ "$need_logrotate" -eq 1 ] && missing+=("logrotate")
            ;;
        dnf|yum)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_cron" -eq 1 ] && missing+=("cronie")
            [ "$need_dns_direct" -eq 1 ] && missing+=("bind-utils")
            [ "$need_timeout" -eq 1 ] && missing+=("coreutils")
            [ "$need_flock" -eq 1 ] && missing+=("util-linux")
            [ "$need_logrotate" -eq 1 ] && missing+=("logrotate")
            ;;
        pacman)
            [ "$need_nft" -eq 1 ] && missing+=("nftables")
            [ "$need_cron" -eq 1 ] && missing+=("cronie")
            [ "$need_dns_direct" -eq 1 ] && missing+=("bind")
            [ "$need_timeout" -eq 1 ] && missing+=("coreutils")
            [ "$need_flock" -eq 1 ] && missing+=("util-linux")
            [ "$need_logrotate" -eq 1 ] && missing+=("logrotate")
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

    runtime_check_quiet || die "依赖安装后仍有必要组件不可用"

    write_logrotate_config

    echo
    echo -e "${GREEN}依赖检查完成${NC}"
    sleep 1
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

ensure_data_files() {
    mkdir -p "$(dirname "$CONFIG")" "$STATE_DIR" "$(dirname "$LOCK_FILE")" "$BACKUP_DIR" "$(dirname "$LOG_FILE")"
    touch "$CONFIG" "$STATE_FILE" "$LOG_FILE"
    chmod 600 "$CONFIG" "$STATE_FILE" 2>/dev/null || true
    chmod 640 "$LOG_FILE" 2>/dev/null || true
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

trim_target() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "$value" == \[*\] ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
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
    local check_table="__nftfw_v6_${RANDOM}"

    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1

    printf 'table ip6 %s { chain c { type nat hook prerouting priority -100; tcp dport 1 dnat to [%s]:1; } }\n' \
        "$check_table" "$ip" | nft -c -f - >/dev/null 2>&1
}

valid_domain() {
    local domain="$1"
    local label

    [ -n "$domain" ] || return 1
    [ "${#domain}" -le 253 ] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+\.?$ ]] || return 1

    # 纯数字不能伪装成域名，例如 5555。
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
        local first="${ip%%.*}"
        [ "$ip" != "0.0.0.0" ] || return 1
        [ "$ip" != "255.255.255.255" ] || return 1
        [ "$first" -ge 224 ] && [ "$first" -le 239 ] && return 1
        return 0
    fi

    local lower="${ip,,}"
    [ "$lower" != "::" ] || return 1
    [[ "$lower" != ff* ]] || return 1

    # fe80::/10 需要 scope-id，不允许作为此脚本的目标。
    if [[ "$lower" =~ ^fe[89ab] ]]; then
        return 1
    fi

    return 0
}

validate_target_format() {
    local host="$1"

    [ -n "$host" ] || return 1

    [[ "$host" != *"|"* &&
       "$host" != *"/"* &&
       "$host" != *"\\"* &&
       "$host" != *";"* &&
       "$host" != *'$'* &&
       "$host" != *'`'* &&
       "$host" != *" "* &&
       "$host" != *$'\t'* &&
       "$host" != *$'\n'* ]] || return 1

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
        ip="$(timeout "$DNS_TIMEOUT" getent ahostsv4 "$host" 2>/dev/null |
            awk '{print $1}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            head -n1)"
    elif command -v host >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" host -t A "$host" 2>/dev/null |
            awk '/has address/ {print $4; exit}')"
    else
        ip="$(timeout "$DNS_TIMEOUT" nslookup -query=A "$host" 2>/dev/null |
            awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            tail -n1)"
    fi

    valid_ipv4 "$ip" 2>/dev/null && printf '%s' "$ip"
}

fallback_query_ipv4() {
    local host="$1"
    local ip=""

    if command -v host >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" host -t A "$host" "$FALLBACK_DNS" 2>/dev/null |
            awk '/has address/ {print $4; exit}')"
    elif command -v nslookup >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" nslookup -query=A "$host" "$FALLBACK_DNS" 2>/dev/null |
            awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            tail -n1)"
    fi

    valid_ipv4 "$ip" 2>/dev/null && printf '%s' "$ip"
}

system_query_ipv6() {
    local host="$1"
    local ip=""

    if command -v getent >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" getent ahostsv6 "$host" 2>/dev/null |
            awk '{print $1}' |
            grep ':' |
            head -n1)"
    elif command -v host >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" host -t AAAA "$host" 2>/dev/null |
            awk '/has IPv6 address/ {print $5; exit}')"
    else
        ip="$(timeout "$DNS_TIMEOUT" nslookup -query=AAAA "$host" 2>/dev/null |
            awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' |
            grep ':' |
            tail -n1)"
    fi

    valid_ipv6 "$ip" 2>/dev/null && printf '%s' "$ip"
}

fallback_query_ipv6() {
    local host="$1"
    local ip=""

    if command -v host >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" host -t AAAA "$host" "$FALLBACK_DNS" 2>/dev/null |
            awk '/has IPv6 address/ {print $5; exit}')"
    elif command -v nslookup >/dev/null 2>&1; then
        ip="$(timeout "$DNS_TIMEOUT" nslookup -query=AAAA "$host" "$FALLBACK_DNS" 2>/dev/null |
            awk '/^Address: / {print $2} /^Address [0-9]+: / {print $3}' |
            grep ':' |
            tail -n1)"
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

    echo -e "${YELLOW}系统 DNS 超时/失败，直接改用 ${FALLBACK_DNS} 查询 A 记录...${NC}" >&2
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

    echo -e "${YELLOW}系统 DNS 超时/失败，直接改用 ${FALLBACK_DNS} 查询 AAAA 记录...${NC}" >&2
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

    if [[ "$host" == *:* ]] && valid_ipv6 "$host" 2>/dev/null; then
        safe_target_ip 6 "$host" || return 3
        TARGET_FAMILY="6"
        TARGET_IP="$host"
        TARGET_KIND="IPv6"
        return 0
    fi

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

valid_proto() {
    case "$1" in
        tcp|udp|both) return 0 ;;
        *) return 1 ;;
    esac
}

is_domain() {
    valid_domain "$1" 2>/dev/null
}

next_id() {
    local max=0 id
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

    line="$(awk -F'|' -v id="$wanted_id" '$1 == id {print; exit}' "$STATE_FILE" 2>/dev/null)"
    [ -n "$line" ] || return 1

    IFS='|' read -r \
        STATE_ID STATE_HOST STATE_FAMILY STATE_IP STATE_PROTO STATE_LISTEN STATE_TARGET_PORT \
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
        "$id" "$host" "$family" "$ip" "$proto" "$listen_port" "$target_port" >> "$tmp"
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
        [ -n "$id" ] || continue
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
            echo -e "${RED}配置错误：ID=$id 目标不是合法 IP/域名：$host${NC}" >&2
            return 1
        }

        case "$proto" in
            tcp)
                [ -z "${seen_tcp[$listen_port]:-}" ] || {
                    echo -e "${RED}配置冲突：TCP/$listen_port 同时被 ID=${seen_tcp[$listen_port]} 和 ID=$id 使用${NC}" >&2
                    return 1
                }
                seen_tcp["$listen_port"]="$id"
                ;;
            udp)
                [ -z "${seen_udp[$listen_port]:-}" ] || {
                    echo -e "${RED}配置冲突：UDP/$listen_port 同时被 ID=${seen_udp[$listen_port]} 和 ID=$id 使用${NC}" >&2
                    return 1
                }
                seen_udp["$listen_port"]="$id"
                ;;
            both)
                [ -z "${seen_tcp[$listen_port]:-}" ] || {
                    echo -e "${RED}配置冲突：TCP/$listen_port 已被 ID=${seen_tcp[$listen_port]} 使用${NC}" >&2
                    return 1
                }
                [ -z "${seen_udp[$listen_port]:-}" ] || {
                    echo -e "${RED}配置冲突：UDP/$listen_port 已被 ID=${seen_udp[$listen_port]} 使用${NC}" >&2
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
    local output="$1"
    local new_state="$2"
    local verbose="${3:-1}"
    local id proto listen_port host target_port rc

    : > "$output"
    : > "$new_state"

    validate_config_structure || return 1

    while IFS='|' read -r id proto listen_port host target_port; do
        [ -n "${id:-}" ] || continue
        host="$(trim_target "$host")"

        [ "$verbose" -eq 0 ] || {
            echo
            echo "ID=$id  $proto :$listen_port -> $host:$target_port"
            echo -n "目标检测: $host ... "
        }

        resolve_target "$host"
        rc=$?

        if [ "$rc" -eq 0 ]; then
            [ "$verbose" -eq 0 ] || {
                echo -e "${GREEN}成功${NC}"
                echo -e "解析: ${CYAN}$host -> $TARGET_IP${NC}"
            }

            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$id" "$host" "$TARGET_FAMILY" "$TARGET_IP" "$proto" "$listen_port" "$target_port" \
                >> "$new_state"

            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$id" "$proto" "$listen_port" "$host" "$target_port" "$TARGET_FAMILY" "$TARGET_IP" \
                >> "$output"
            continue
        fi

        if [ "$rc" -eq 1 ] && load_state "$id" &&
           state_matches_config "$host" "$proto" "$listen_port" "$target_port"; then

            if { [ "$STATE_FAMILY" = "4" ] && valid_ipv4 "$STATE_IP" && safe_target_ip 4 "$STATE_IP"; } ||
               { [ "$STATE_FAMILY" = "6" ] && valid_ipv6 "$STATE_IP" && safe_target_ip 6 "$STATE_IP"; }; then

                [ "$verbose" -eq 0 ] || {
                    echo -e "${YELLOW}DNS 查询失败${NC}"
                    echo -e "保留旧 IP: ${CYAN}$STATE_IP${NC}"
                }

                printf '%s|%s|%s|%s|%s|%s|%s\n' \
                    "$id" "$host" "$STATE_FAMILY" "$STATE_IP" "$proto" "$listen_port" "$target_port" \
                    >> "$new_state"

                printf '%s|%s|%s|%s|%s|%s|%s\n' \
                    "$id" "$proto" "$listen_port" "$host" "$target_port" "$STATE_FAMILY" "$STATE_IP" \
                    >> "$output"
                continue
            fi
        fi

        case "$rc" in
            2) echo -e "${RED}失败：目标格式非法：$host${NC}" >&2 ;;
            3) echo -e "${RED}拒绝：目标属于禁止的广播/组播/未指定/link-local 地址${NC}" >&2 ;;
            *) echo -e "${RED}失败：$host 无法解析，且没有可用的旧 IP 缓存${NC}" >&2 ;;
        esac
        return 1
    done < "$CONFIG"

    return 0
}

write_delete_existing_tables() {
    local file="$1"

    if nft list table ip "$TABLE" >/dev/null 2>&1; then
        echo "delete table ip $TABLE" >> "$file"
    fi

    if nft list table ip6 "$TABLE6" >/dev/null 2>&1; then
        echo "delete table ip6 $TABLE6" >> "$file"
    fi
}

generate_map_ruleset() {
    local resolved="$1"
    local file="$2"
    local has4=0 has6=0
    local id proto listen_port host target_port family ip

    : > "$file"
    write_delete_existing_tables "$file"

    while IFS='|' read -r id proto listen_port host target_port family ip; do
        [ -n "${id:-}" ] || continue
        [ "$family" = "4" ] && has4=1
        [ "$family" = "6" ] && has6=1
    done < "$resolved"

    if [ "$has4" -eq 1 ]; then
        cat >> "$file" <<EOF
add table ip $TABLE
add map ip $TABLE $MAP_TCP { type inet_service : ipv4_addr . inet_service; }
add map ip $TABLE $MAP_UDP { type inet_service : ipv4_addr . inet_service; }
add chain ip $TABLE prerouting { type nat hook prerouting priority -100; policy accept; }
add chain ip $TABLE output { type nat hook output priority -100; policy accept; }
add chain ip $TABLE postrouting { type nat hook postrouting priority 100; policy accept; }
add rule ip $TABLE prerouting fib daddr type local dnat ip addr . port to tcp dport map @$MAP_TCP
add rule ip $TABLE prerouting fib daddr type local dnat ip addr . port to udp dport map @$MAP_UDP
add rule ip $TABLE output fib daddr type local dnat ip addr . port to tcp dport map @$MAP_TCP
add rule ip $TABLE output fib daddr type local dnat ip addr . port to udp dport map @$MAP_UDP
add rule ip $TABLE postrouting ct status dnat masquerade
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
add rule ip6 $TABLE6 prerouting fib daddr type local dnat ip6 addr . port to tcp dport map @$MAP_TCP
add rule ip6 $TABLE6 prerouting fib daddr type local dnat ip6 addr . port to udp dport map @$MAP_UDP
add rule ip6 $TABLE6 output fib daddr type local dnat ip6 addr . port to tcp dport map @$MAP_TCP
add rule ip6 $TABLE6 output fib daddr type local dnat ip6 addr . port to udp dport map @$MAP_UDP
add rule ip6 $TABLE6 postrouting ct status dnat masquerade
EOF
    fi

    while IFS='|' read -r id proto listen_port host target_port family ip; do
        [ -n "${id:-}" ] || continue

        if [ "$family" = "4" ]; then
            case "$proto" in
                tcp)
                    echo "add element ip $TABLE $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                    ;;
                udp)
                    echo "add element ip $TABLE $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                    ;;
                both)
                    echo "add element ip $TABLE $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                    echo "add element ip $TABLE $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
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
    local has4=0 has6=0
    local id proto listen_port host target_port family ip target

    : > "$file"
    write_delete_existing_tables "$file"

    while IFS='|' read -r id proto listen_port host target_port family ip; do
        [ -n "${id:-}" ] || continue
        [ "$family" = "4" ] && has4=1
        [ "$family" = "6" ] && has6=1
    done < "$resolved"

    if [ "$has4" -eq 1 ]; then
        cat >> "$file" <<EOF
add table ip $TABLE
add chain ip $TABLE prerouting { type nat hook prerouting priority -100; policy accept; }
add chain ip $TABLE output { type nat hook output priority -100; policy accept; }
add chain ip $TABLE postrouting { type nat hook postrouting priority 100; policy accept; }
add rule ip $TABLE postrouting ct status dnat masquerade
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
                    echo "add rule ip $TABLE prerouting fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE output fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    ;;
                udp)
                    echo "add rule ip $TABLE prerouting fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE output fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    ;;
                both)
                    echo "add rule ip $TABLE prerouting fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE prerouting fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE output fib daddr type local tcp dport $listen_port dnat to $target" >> "$file"
                    echo "add rule ip $TABLE output fib daddr type local udp dport $listen_port dnat to $target" >> "$file"
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
    local resolved new_state nftfile mode="map"

    lock_begin || return 1

    resolved="$(mktemp)"
    new_state="$(mktemp)"
    nftfile="$(mktemp)"

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

    generate_map_ruleset "$resolved" "$nftfile"

    if ! nft -c -f "$nftfile" >/dev/null 2>&1; then
        mode="legacy"
        generate_legacy_ruleset "$resolved" "$nftfile"

        if ! nft -c -f "$nftfile" >/dev/null 2>&1; then
            [ "$verbose" -eq 0 ] || echo -e "${RED}nftables 规则校验失败，原规则保持不变${NC}"
            log_msg "ruleset validation failed"
            rm -f "$resolved" "$new_state" "$nftfile"
            lock_end
            return 1
        fi
    fi

    if ! nft -f "$nftfile"; then
        [ "$verbose" -eq 0 ] || echo -e "${RED}nftables 应用失败，未更新状态缓存${NC}"
        log_msg "ruleset apply failed"
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
            echo -e "模式: ${YELLOW}兼容模式（旧版 nftables）${NC}"
        fi
        echo -e "${GREEN}规则已原子更新${NC}"
    fi

    log_msg "full rebuild success mode=$mode"
    rm -f "$resolved" "$nftfile"
    lock_end
    return 0
}

tables_present_for_state() {
    local need4=0 need6=0
    local id host family ip proto listen_port target_port

    while IFS='|' read -r id host family ip proto listen_port target_port; do
        [ -n "${id:-}" ] || continue
        [ "$family" = "4" ] && need4=1
        [ "$family" = "6" ] && need6=1
    done < "$STATE_FILE"

    if [ "$need4" -eq 1 ]; then
        nft list table ip "$TABLE" >/dev/null 2>&1 || return 1
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
            tcp) echo "delete element ip $TABLE $MAP_TCP { $port }" >> "$file" ;;
            udp) echo "delete element ip $TABLE $MAP_UDP { $port }" >> "$file" ;;
            both)
                echo "delete element ip $TABLE $MAP_TCP { $port }" >> "$file"
                echo "delete element ip $TABLE $MAP_UDP { $port }" >> "$file"
                ;;
        esac
    else
        case "$proto" in
            tcp) echo "delete element ip6 $TABLE6 $MAP_TCP { $port }" >> "$file" ;;
            udp) echo "delete element ip6 $TABLE6 $MAP_UDP { $port }" >> "$file" ;;
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
            tcp) echo "add element ip $TABLE $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file" ;;
            udp) echo "add element ip $TABLE $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file" ;;
            both)
                echo "add element ip $TABLE $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                echo "add element ip $TABLE $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                ;;
        esac
    else
        case "$proto" in
            tcp) echo "add element ip6 $TABLE6 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file" ;;
            udp) echo "add element ip6 $TABLE6 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file" ;;
            both)
                echo "add element ip6 $TABLE6 $MAP_TCP { $listen_port : $ip . $target_port }" >> "$file"
                echo "add element ip6 $TABLE6 $MAP_UDP { $listen_port : $ip . $target_port }" >> "$file"
                ;;
        esac
    fi
}

refresh_dns() {
    local verbose="${1:-1}"
    local mode batch state_tmp
    local id proto listen_port host target_port rc
    local changed=0 unchanged=0 failed=0 need_rebuild=0

    lock_begin || return 1

    validate_config_structure || {
        lock_end
        return 1
    }

    mode="$(cat "$MODE_FILE" 2>/dev/null || true)"

    if [ ! -s "$STATE_FILE" ] && [ -s "$CONFIG" ]; then
        need_rebuild=1
    elif ! tables_present_for_state; then
        need_rebuild=1
    fi

    if [ "$need_rebuild" -eq 1 ]; then
        [ "$verbose" -eq 0 ] || echo -e "${YELLOW}运行状态不完整，执行一次完整恢复...${NC}"
        if full_rebuild "$verbose"; then
            lock_end
            return 0
        fi
        lock_end
        return 1
    fi

    batch="$(mktemp)"
    state_tmp="$(mktemp)"
    cp "$STATE_FILE" "$state_tmp"
    : > "$batch"

    [ "$verbose" -eq 0 ] || {
        echo
        echo "================================="
        echo "          刷新域名 IP"
        echo "================================="
    }

    while IFS='|' read -r id proto listen_port host target_port; do
        [ -n "${id:-}" ] || continue
        host="$(trim_target "$host")"

        # 纯 IP 规则不需要 DNS 查询，但手工改配置后仍需检查状态是否一致。
        if ! is_domain "$host"; then
            resolve_target "$host"
            rc=$?
        else
            [ "$verbose" -eq 0 ] || {
                echo
                echo "ID=$id  $host"
                echo -n "查询: "
            }
            resolve_target "$host"
            rc=$?
        fi

        if ! load_state "$id"; then
            need_rebuild=1
            break
        fi

        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 1 ] && state_matches_config "$host" "$proto" "$listen_port" "$target_port"; then
                failed=$((failed + 1))
                [ "$verbose" -eq 0 ] || {
                    echo -e "${YELLOW}失败${NC}"
                    echo -e "保留旧 IP: ${CYAN}$STATE_IP${NC}"
                }
                log_msg "dns failed id=$id host=$host keep=$STATE_IP"
                continue
            fi

            failed=$((failed + 1))
            [ "$verbose" -eq 0 ] || echo -e "${RED}目标无效，保留当前 nft 规则不动${NC}"
            continue
        fi

        if [ "$STATE_HOST" = "$host" ] &&
           [ "$STATE_FAMILY" = "$TARGET_FAMILY" ] &&
           [ "$STATE_IP" = "$TARGET_IP" ] &&
           [ "$STATE_PROTO" = "$proto" ] &&
           [ "$STATE_LISTEN" = "$listen_port" ] &&
           [ "$STATE_TARGET_PORT" = "$target_port" ]; then

            unchanged=$((unchanged + 1))
            [ "$verbose" -eq 0 ] || {
                if is_domain "$host"; then
                    echo -e "${GREEN}成功${NC}"
                    echo "当前 IP: $STATE_IP"
                    echo "最新 IP: $TARGET_IP"
                    echo -e "状态: ${GREEN}未变化，跳过 nft 更新${NC}"
                fi
            }
            continue
        fi

        changed=$((changed + 1))

        [ "$verbose" -eq 0 ] || {
            if is_domain "$host"; then
                echo -e "${GREEN}成功${NC}"
            fi
            echo "旧: ${STATE_IP:-无}"
            echo "新: $TARGET_IP"
        }

        if [ "$mode" != "map" ]; then
            need_rebuild=1
            state_replace_in_file "$state_tmp" \
                "$id" "$host" "$TARGET_FAMILY" "$TARGET_IP" "$proto" "$listen_port" "$target_port"
            continue
        fi

        # 新地址族对应的表不存在时，完整重建以创建所需 map。
        if [ "$TARGET_FAMILY" = "4" ] && ! nft list table ip "$TABLE" >/dev/null 2>&1; then
            need_rebuild=1
            break
        fi

        if [ "$TARGET_FAMILY" = "6" ] && ! nft list table ip6 "$TABLE6" >/dev/null 2>&1; then
            need_rebuild=1
            break
        fi

        append_map_delete "$batch" "$STATE_FAMILY" "$STATE_PROTO" "$STATE_LISTEN"
        append_map_add "$batch" "$TARGET_FAMILY" "$proto" "$listen_port" "$TARGET_IP" "$target_port"

        state_replace_in_file "$state_tmp" \
            "$id" "$host" "$TARGET_FAMILY" "$TARGET_IP" "$proto" "$listen_port" "$target_port"
    done < "$CONFIG"

    if [ "$need_rebuild" -eq 1 ]; then
        rm -f "$batch" "$state_tmp"
        [ "$verbose" -eq 0 ] || echo -e "${YELLOW}配置结构发生变化，执行完整原子重建...${NC}"
        if full_rebuild "$verbose"; then
            lock_end
            return 0
        fi
        lock_end
        return 1
    fi

    if [ "$changed" -eq 0 ]; then
        rm -f "$batch" "$state_tmp"
        [ "$verbose" -eq 0 ] || {
            echo
            echo "================================="
            echo -e "变化: ${GREEN}0${NC}（未写入 nftables）"
            echo "未变化: $unchanged"
            echo "DNS失败并保留旧IP: $failed"
            echo "================================="
        }
        lock_end
        return 0
    fi

    if [ "$mode" = "map" ]; then
        if nft -c -f "$batch" >/dev/null 2>&1 && nft -f "$batch"; then
            mv "$state_tmp" "$STATE_FILE"
            chmod 600 "$STATE_FILE" 2>/dev/null || true
            [ "$verbose" -eq 0 ] || echo -e "${GREEN}仅更新了发生变化的 nft map 元素${NC}"
            log_msg "incremental refresh changed=$changed unchanged=$unchanged failed=$failed"
        else
            [ "$verbose" -eq 0 ] || echo -e "${YELLOW}增量更新失败，尝试完整恢复...${NC}"
            rm -f "$batch" "$state_tmp"
            if full_rebuild "$verbose"; then
                lock_end
                return 0
            fi
            lock_end
            return 1
        fi
    else
        rm -f "$batch" "$state_tmp"
        if full_rebuild "$verbose"; then
            lock_end
            return 0
        fi
        lock_end
        return 1
    fi

    rm -f "$batch"

    [ "$verbose" -eq 0 ] || {
        echo
        echo "================================="
        echo "刷新完成"
        echo -e "变化并更新: ${GREEN}$changed${NC}"
        echo "未变化: $unchanged"
        echo "DNS失败并保留旧IP: $failed"
        echo "================================="
    }

    lock_end
    return 0
}

add_rule() {
    local listen_port p proto host target_port id backup

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
        echo -e "${RED}端口冲突：$listen_port/$proto 与已有 ID=$CONFLICT_ID ($CONFLICT_PROTO) 冲突${NC}"
        return
    fi

    read -rp "目标域名/IP: " host
    host="$(trim_target "$host")"

    echo -n "目标检测: $host ... "
    resolve_target "$host"
    local rc=$?

    case "$rc" in
        0)
            echo -e "${GREEN}成功${NC}"
            echo -e "类型: ${CYAN}${TARGET_KIND}${NC}"
            echo -e "解析: ${CYAN}$host -> $TARGET_IP${NC}"
            ;;
        2)
            echo -e "${RED}失败${NC}"
            echo -e "${RED}请输入合法 IPv4、IPv6 或完整域名；5555 这类值会被拒绝。${NC}"
            return
            ;;
        3)
            echo -e "${RED}拒绝${NC}"
            echo -e "${RED}该地址属于未指定/广播/组播/link-local 等禁止目标。${NC}"
            return
            ;;
        *)
            echo -e "${RED}失败${NC}"
            echo -e "${RED}系统 DNS 与 $FALLBACK_DNS 均未解析出可用 A/AAAA 地址。${NC}"
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

    # 获得锁后再检查一次，防止等待锁期间配置被另一个任务改变。
    if port_conflict "$proto" "$listen_port"; then
        echo -e "${RED}端口冲突：$listen_port/$proto 与已有 ID=$CONFLICT_ID ($CONFLICT_PROTO) 冲突${NC}"
        lock_end
        return
    fi

    id="$(next_id)"
    backup_config "before-add" >/dev/null || true
    backup="$(mktemp)"
    cp "$CONFIG" "$backup"

    printf '%s|%s|%s|%s|%s\n' \
        "$id" "$proto" "$listen_port" "$host" "$target_port" >> "$CONFIG"

    if full_rebuild 0; then
        rm -f "$backup"
        lock_end
        echo
        echo -e "${GREEN}添加成功${NC}"
        echo "ID: $id"
        echo "$proto :$listen_port -> $host:$target_port"
        log_msg "rule added id=$id proto=$proto listen=$listen_port target=$host:$target_port"
        return
    fi

    cp "$backup" "$CONFIG"
    rm -f "$backup"
    full_rebuild 0 >/dev/null 2>&1 || true
    lock_end
    echo -e "${RED}添加失败，配置已回滚${NC}"
}

list_rules() {
    local id proto listen_port host target_port current="-"

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

        if [ "$confirm" != "yes" ]; then
            echo "已取消"
            return
        fi

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
    backup_config "before-delete-id-${delete_id}" >/dev/null || true
    backup="$(mktemp)"
    cp "$CONFIG" "$backup"

    # 获得锁后确认目标仍存在。
    if ! grep -q "^${delete_id}|" "$CONFIG"; then
        rm -f "$backup"
        lock_end
        echo -e "${RED}规则已发生变化，请重新操作${NC}"
        return
    fi

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
    nft list table ip "$TABLE" 2>/dev/null || echo "当前没有 IPv4 nft 转发规则"

    echo
    echo "===== IPv6 ====="
    nft list table ip6 "$TABLE6" 2>/dev/null || echo "当前没有 IPv6 nft 转发规则"

    echo
    echo "===== 运行模式 ====="
    case "$(cat "$MODE_FILE" 2>/dev/null || true)" in
        map) echo "nft map 增量更新" ;;
        legacy) echo "兼容模式" ;;
        *) echo "尚未建立规则" ;;
    esac
}

get_crontab() {
    crontab -l 2>/dev/null || true
}

remove_cron_block_by_markers() {
    local begin="$1"
    local end="$2"
    local tmp

    tmp="$(mktemp)"
    get_crontab | awk -v begin="$begin" -v end="$end" '
        $0 == begin {skip=1; next}
        $0 == end   {skip=0; next}
        !skip {print}
    ' > "$tmp"

    crontab "$tmp"
    rm -f "$tmp"
}

install_self() {
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
    log_msg "installed/updated binary: $INSTALL_PATH version=$VERSION"
}

cron_status() {
    if has_systemd && [ -f "$REFRESH_TIMER" ] &&
       systemctl is-enabled nft-forward-refresh.timer >/dev/null 2>&1; then
        echo -e "${GREEN}已开启 (systemd timer)${NC}"
        systemctl show nft-forward-refresh.timer \
            -p NextElapseUSecRealtime -p LastTriggerUSec --no-pager 2>/dev/null || true
        return
    fi

    if get_crontab | grep -qF "$CRON_MARK_BEGIN"; then
        echo -e "${GREEN}已开启 (cron 兼容模式)${NC}"
        get_crontab | sed -n "/$CRON_MARK_BEGIN/,/$CRON_MARK_END/p"
    else
        echo -e "${YELLOW}未开启${NC}"
    fi
}

enable_cron_refresh() {
    local interval tmp

    echo
    read -rp "每隔多少分钟解析一次域名 [默认 ${DEFAULT_INTERVAL}]: " interval
    interval="${interval:-$DEFAULT_INTERVAL}"

    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 1440 ]; then
        echo -e "${RED}请输入 1-1440 之间的分钟数${NC}"
        return
    fi

    install_self || {
        echo -e "${RED}无法安装到 $INSTALL_PATH${NC}"
        return
    }

    # systemd 环境优先使用 timer，不再依赖 cron。
    if has_systemd; then
        # 清理旧 cron，避免重复刷新。
        if command -v crontab >/dev/null 2>&1; then
            remove_cron_block_by_markers "$CRON_MARK_BEGIN" "$CRON_MARK_END"
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
        systemctl enable --now nft-forward-refresh.timer >/dev/null || {
            echo -e "${RED}systemd timer 启动失败${NC}"
            return
        }

        log_msg "systemd timer enabled interval=${interval}min"
        echo -e "${GREEN}已开启 systemd timer：每 ${interval} 分钟检查域名 IP${NC}"
        echo "IP 未变化时不会写 nftables。"
        return
    fi

    # Alpine / 无 systemd 环境回退 cron。
    command -v crontab >/dev/null 2>&1 || {
        echo -e "${RED}当前无 systemd 且未安装 crontab${NC}"
        return
    }

    ensure_cron_service
    remove_cron_block_by_markers "$CRON_MARK_BEGIN" "$CRON_MARK_END"

    tmp="$(mktemp)"
    get_crontab > "$tmp"

    if [ "$interval" -le 59 ]; then
        {
            echo "$CRON_MARK_BEGIN"
            echo "*/$interval * * * * $INSTALL_PATH --refresh >/dev/null 2>&1"
            echo "$CRON_MARK_END"
        } >> "$tmp"
    else
        # cron 无法自然表示任意 60-1440 分钟，兼容模式限制到整小时。
        local hours=$((interval / 60))
        [ "$hours" -lt 1 ] && hours=1
        {
            echo "$CRON_MARK_BEGIN"
            echo "0 */$hours * * * $INSTALL_PATH --refresh >/dev/null 2>&1"
            echo "$CRON_MARK_END"
        } >> "$tmp"
        echo -e "${YELLOW}cron 兼容模式按每 ${hours} 小时执行${NC}"
    fi

    crontab "$tmp"
    rm -f "$tmp"

    log_msg "cron refresh enabled interval=${interval}min"
    echo -e "${GREEN}已开启 cron 定时解析${NC}"
}

disable_cron_refresh() {
    local changed=0

    if has_systemd; then
        systemctl disable --now nft-forward-refresh.timer >/dev/null 2>&1 || true
        systemctl stop nft-forward-refresh.service >/dev/null 2>&1 || true

        if [ -f "$REFRESH_TIMER" ] || [ -f "$REFRESH_SERVICE" ]; then
            rm -f "$REFRESH_TIMER" "$REFRESH_SERVICE"
            systemctl daemon-reload
            changed=1
        fi
    fi

    if command -v crontab >/dev/null 2>&1; then
        if get_crontab | grep -qF "$CRON_MARK_BEGIN"; then
            remove_cron_block_by_markers "$CRON_MARK_BEGIN" "$CRON_MARK_END"
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        log_msg "scheduled DNS refresh disabled"
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
        if has_systemd; then
            echo "调度器: systemd timer"
        else
            echo "调度器: cron 兼容模式"
        fi
        echo
        echo "1. 开启/修改定时解析"
        echo "2. 关闭定时解析"
        echo "3. 立即检查一次"
        echo "0. 返回"
        echo "================================="
        read -rp "请选择: " choice

        case "$choice" in
            1) enable_cron_refresh; read -rp "回车继续..." ;;
            2) disable_cron_refresh; read -rp "回车继续..." ;;
            3) refresh_dns 1; read -rp "回车继续..." ;;
            0) return ;;
            *) echo "输入错误"; sleep 1 ;;
        esac
    done
}

boot_status() {
    if command -v systemctl >/dev/null 2>&1 &&
       [ -f "$SYSTEMD_SERVICE" ] &&
       systemctl is-enabled nft-forward.service >/dev/null 2>&1; then
        echo -e "${GREEN}已开启 (systemd)${NC}"
        return
    fi

    if [ -f "$OPENRC_START" ]; then
        echo -e "${GREEN}已开启 (OpenRC local.d)${NC}"
        return
    fi

    if command -v crontab >/dev/null 2>&1 &&
       get_crontab | grep -qF "$BOOT_CRON_BEGIN"; then
        echo -e "${GREEN}已开启 (@reboot)${NC}"
        return
    fi

    echo -e "${YELLOW}未开启${NC}"
}

enable_boot_restore() {
    install_self || {
        echo -e "${RED}无法安装到 $INSTALL_PATH${NC}"
        return
    }

    if command -v systemctl >/dev/null 2>&1; then
        cat > "$SYSTEMD_SERVICE" <<EOF
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
        echo -e "${GREEN}已开启 OpenRC 开机自动恢复${NC}"
        return
    fi

    if command -v crontab >/dev/null 2>&1; then
        local tmp
        remove_cron_block_by_markers "$BOOT_CRON_BEGIN" "$BOOT_CRON_END"
        tmp="$(mktemp)"
        get_crontab > "$tmp"
        {
            echo "$BOOT_CRON_BEGIN"
            echo "@reboot $INSTALL_PATH --restore >/dev/null 2>&1"
            echo "$BOOT_CRON_END"
        } >> "$tmp"
        crontab "$tmp"
        rm -f "$tmp"
        echo -e "${GREEN}已开启 @reboot 自动恢复${NC}"
        return
    fi

    echo -e "${RED}当前系统未找到可用的开机启动机制${NC}"
}

disable_boot_restore() {
    if command -v systemctl >/dev/null 2>&1 && [ -f "$SYSTEMD_SERVICE" ]; then
        systemctl disable nft-forward.service >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE"
        systemctl daemon-reload
    fi

    rm -f "$OPENRC_START"

    if command -v crontab >/dev/null 2>&1; then
        remove_cron_block_by_markers "$BOOT_CRON_BEGIN" "$BOOT_CRON_END"
    fi

    echo -e "${GREEN}开机自动恢复已关闭${NC}"
}

boot_menu() {
    while true; do
        clear
        echo "================================="
        echo "        开机自动恢复"
        echo "================================="
        echo -n "状态: "
        boot_status
        echo
        echo "1. 开启"
        echo "2. 关闭"
        echo "3. 立即完整恢复一次"
        echo "0. 返回"
        echo "================================="
        read -rp "请选择: " choice

        case "$choice" in
            1) enable_boot_restore; read -rp "回车继续..." ;;
            2) disable_boot_restore; read -rp "回车继续..." ;;
            3) full_rebuild 1; read -rp "回车继续..." ;;
            0) return ;;
            *) echo "输入错误"; sleep 1 ;;
        esac
    done
}

install_or_update() {
    local backup=""

    ensure_data_files

    if [ -s "$CONFIG" ]; then
        backup="$(backup_config "before-install" || true)"
        [ -z "$backup" ] || echo "配置备份: $backup"
    fi

    install_self || {
        echo -e "${RED}安装失败${NC}"
        return 1
    }

    echo
    echo -e "${GREEN}安装/更新完成${NC}"
    echo "命令: $INSTALL_PATH"
    echo "配置: $CONFIG"
    echo "状态: $STATE_FILE"
    echo "日志: $LOG_FILE"
    echo "备份: $BACKUP_DIR"
    echo "日志轮转: $LOGROTATE_FILE"
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

    # 移除定时 DNS 更新。
    disable_cron_refresh >/dev/null 2>&1 || true

    # 移除开机恢复。
    if has_systemd; then
        systemctl disable --now nft-forward.service >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE"
        systemctl daemon-reload
    fi

    rm -f "$OPENRC_START"

    if command -v crontab >/dev/null 2>&1; then
        remove_cron_block_by_markers "$BOOT_CRON_BEGIN" "$BOOT_CRON_END"
    fi

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
    echo "当前这次脚本进程仍可运行，退出后命令将不存在。"
}

ensure_runtime_rules() {
    if [ ! -s "$CONFIG" ]; then
        return 0
    fi

    if [ ! -s "$STATE_FILE" ] || ! tables_present_for_state; then
        echo -e "${YELLOW}检测到内核规则未恢复，正在从配置恢复...${NC}"
        full_rebuild 1 || return 1
    fi
}

menu() {
    while true; do
        clear

        echo "================================="
        echo "      NFT 转发管理脚本 v$VERSION"
        echo "================================="
        echo "1. 添加转发"
        echo "2. 删除转发"
        echo "3. 查看转发"
        echo "4. 刷新域名 IP"
        echo "5. 查看 nftables"
        echo "6. 定时解析域名"
        echo "7. 开机自动恢复"
        echo "8. 重新检测环境"
        echo "9. 安装 / 更新脚本"
        echo "10. 查看最近日志"
        echo "11. 卸载脚本"
        echo "0. 退出"
        echo "================================="

        read -rp "请选择: " choice

        case "$choice" in
            1) add_rule; read -rp "回车继续..." ;;
            2) delete_rule; read -rp "回车继续..." ;;
            3) list_rules; read -rp "回车继续..." ;;
            4) refresh_dns 1; read -rp "回车继续..." ;;
            5) show_nft; read -rp "回车继续..." ;;
            6) timer_menu ;;
            7) boot_menu ;;
            8) preflight_check; read -rp "回车继续..." ;;
            9) install_or_update; read -rp "回车继续..." ;;
            10) show_recent_log; read -rp "回车继续..." ;;
            11) uninstall_script; read -rp "回车继续..." ;;
            0) exit 0 ;;
            *) echo "输入错误"; sleep 1 ;;
        esac
    done
}

main() {
    local action="${1:-}"

    detect_os

    # 不应为了查看版本或卸载，反过来要求安装依赖。
    if [ "$action" = "--version" ]; then
        echo "$VERSION"
        exit 0
    fi

    if [ "$action" = "--uninstall" ]; then
        [ "$(id -u)" -eq 0 ] || die "请使用 root 运行卸载"
        ensure_data_files
        uninstall_script
        exit $?
    fi

    case "$action" in
        --refresh|--restore)
            NONINTERACTIVE=1
            runtime_check_quiet || {
                log_msg "$action failed: runtime dependency missing"
                exit 1
            }
            ;;
        *)
            preflight_check
            ;;
    esac

    ensure_data_files
    enable_forwarding

    case "$action" in
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
            menu
            ;;
        *)
            echo "用法: $0 [--refresh|--restore|--install|--uninstall|--version]"
            exit 1
            ;;
    esac
}

main "$@"
