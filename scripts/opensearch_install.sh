#!/bin/bash
#================================================================
# opensearch_install.sh
# Fully automated installation of OpenSearch 3.3.2 (tarball, bundled JDK)
# in either STANDALONE (single-node) or CLUSTER (multi-node) mode,
# in ONE run per server:
#
#   * TLS (transport + HTTP) with a private CA generated for you
#   * Security plugin initialised with generated passwords for:
#       admin, kibanaserver, a READ-ONLY user and a WRITE user
#       (plus the read_only_role / write_role and their role mappings)
#   * systemd service, sysctl / limits tuning, heap sizing
#   * Idempotent: safe to re-run
#
# Interactive usage:
#   sudo ./opensearch_install.sh
#
# Non-interactive (AUTOMATED) usage - STANDALONE:
#   AUTOMATED=1 MODE=standalone THIS_NODE_IP=10.0.0.20 sudo -E ./opensearch_install.sh
#
# Non-interactive (AUTOMATED) usage - CLUSTER (1 dedicated manager + 2 data nodes):
#   The FIRST IP in NODE_IPS is the "generating" node: it creates the CA, the
#   passwords and one certificate bundle per node (and pushes them to the
#   other nodes when TRANSFER_TO_PEERS=Y). Run it there first:
#
#   AUTOMATED=1 MODE=cluster THIS_NODE_IP=10.0.0.20 \
#   NODE_IPS=10.0.0.20,10.0.0.21,10.0.0.22 \
#   NODE_NAMES=opensearch-cluster_manager,opensearch-d1,opensearch-d2 \
#   CLUSTER_MANAGER_IPS=10.0.0.20 NODE_ROLES=cluster_manager \
#   HTTP_PORT=8101 TRANSPORT_PORT=8102 \
#   BASE_DIR=/vantagex3/ausiytic OS_ROOT=/vantagex3/ausiytic/apps/opensearch \
#   SERVICE_USER=vantagex \
#   TRANSFER_TO_PEERS=Y SSH_USER=ubuntu SSH_KEY=/home/ubuntu/.ssh/id_rsa \
#   sudo -E ./opensearch_install.sh
#
#   Then on every other node (its bundle is already in /tmp, or set CERT_BUNDLE),
#   same variables, but its own THIS_NODE_IP and NO NODE_ROLES / TRANSFER_* / SSH_*:
#
#   AUTOMATED=1 MODE=cluster THIS_NODE_IP=10.0.0.21 \
#   NODE_IPS=10.0.0.20,10.0.0.21,10.0.0.22 \
#   NODE_NAMES=opensearch-cluster_manager,opensearch-d1,opensearch-d2 \
#   CLUSTER_MANAGER_IPS=10.0.0.20 HTTP_PORT=8101 TRANSPORT_PORT=8102 \
#   BASE_DIR=/vantagex3/ausiytic OS_ROOT=/vantagex3/ausiytic/apps/opensearch \
#   SERVICE_USER=vantagex sudo -E ./opensearch_install.sh
#
# Cluster-wide variables (MUST be identical on every node):
#   MODE  NODE_IPS  NODE_NAMES  CLUSTER_MANAGER_IPS  CLUSTER_NAME
#   OS_VERSION  HTTP_PORT  TRANSPORT_PORT
#   NODE_IPS and NODE_NAMES are matched by position: keep the same order everywhere.
#
# Optional variables (all have defaults):
#   OS_VERSION (3.3.2)      BASE_DIR (/opt/ausiytic)     SERVICE_USER (opensearch)
#   HTTP_PORT (9200)        TRANSPORT_PORT (9300)        CLUSTER_NAME (ausiytic-opensearch)
#   BASE_DIR     base path. The script checks that $BASE_DIR/softwares and $BASE_DIR/apps
#                exist and CREATES them if missing (no searching for existing installs).
#   OS_ROOT      install root            (default $BASE_DIR/apps/opensearch)
#   OS_HOME / OS_DATA / OS_LOGS          (default $OS_ROOT/binaries | data | logs)
#   SOURCE_DIR   tarball download dir    (default $BASE_DIR/softwares)
#   NODE_NAME    node name, STANDALONE only (default os-node-1)
#   NODE_NAMES   node names, CLUSTER: one per IP in NODE_IPS (default os-node-1,os-node-2,...)
#   NODE_ROLES   roles of THIS node (default: cluster_manager,data,ingest for IPs listed in
#                CLUSTER_MANAGER_IPS, data,ingest for all others). Use NODE_ROLES=cluster_manager
#                for a dedicated manager.
#   CLUSTER_MANAGER_IPS (default = all NODE_IPS)
#   HEAP_SIZE    JVM heap, Xms=Xmx, e.g. 4g or 3888m (asked for; default 50% of this server's RAM, max 31g).
#                Per node: it may differ between nodes that have different amounts of RAM.
#   READ_USER (readuser)    WRITE_USER (writeuser)       passwords: ADMIN_PASSWORD,
#   KIBANASERVER_PASSWORD, READ_USER_PASSWORD, WRITE_USER_PASSWORD (default: generated)
#   CERT_EXTRA_DNS  extra DNS names added to every node certificate (comma-separated)
#   DOWNLOAD_URL / TARBALL_PATH (offline installs)       OS_SHA512 (optional checksum)
#   HEALTH_WAIT_SECS (180; 0 = do not wait for the node/cluster to come up)
#   REGENERATE_BUNDLES=Y  (generating node) re-issue bundles, e.g. after adding nodes
#   GENERATE_BUNDLES=Y    allow a non-first node to create its own CA (normally a mistake)
#   TRANSFER_TO_PEERS (first node) copy each peer's bundle to <peer>:/tmp automatically.
#                Interactive: asked for. AUTOMATED: defaults to Y when SSH_KEY or SSH_PASSWORD is set.
#   SSH_USER (default: the sudo-invoking user)  SSH_KEY (default: auto-detect ~/.ssh/id_*, or ssh-agent
#                when run with sudo -E)  SSH_PASSWORD (needs sshpass, installed automatically)  SSH_PORT (22)
#
# In AUTOMATED mode it never silently accepts an invalid/unsafe value
# (bad IP, system directory, ...) - it dies with a clear message instead
# of hanging on a prompt that will never be answered.
#================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/opensearch_install.$(date +%Y%m%d%H%M%S).log"
touch "$LOG_FILE"

AUTOMATED="${AUTOMATED:-0}"

# ---------- colors / logging ----------
C_GREEN="\033[0;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[0;31m"; C_BLUE="\033[0;34m"; C_RESET="\033[0m"

log()  { echo -e "${C_BLUE}[$(date +'%F %T')]${C_RESET} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${C_GREEN}[$(date +'%F %T')] [OK]${C_RESET} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${C_YELLOW}[$(date +'%F %T')] [WARN]${C_RESET} $*" | tee -a "$LOG_FILE"; }
# die writes to STDERR on purpose: it is also called inside $(...) helpers whose stdout is captured.
die()  { echo -e "${C_RED}[$(date +'%F %T')] [ERROR]${C_RESET} $*" | tee -a "$LOG_FILE" >&2; exit 1; }

print_banner() {
    echo
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root (use sudo)."
}

# ---------- OS detection ----------
detect_os() {
    [ -f /etc/os-release ] || die "Cannot detect OS: /etc/os-release not found. Unsupported system."
    . /etc/os-release
    OS_ID="${ID}"
    OS_LIKE="${ID_LIKE:-}"

    case "$OS_ID $OS_LIKE" in
        *debian*|*ubuntu*)
            OS_FAMILY="debian"
            PKG_UPDATE="apt-get update -y"
            PKG_INSTALL="apt-get install -y"
            ;;
        *rhel*|*centos*|*fedora*|*rocky*|*almalinux*|*amzn*)
            OS_FAMILY="rhel"
            if command -v dnf >/dev/null 2>&1; then
                PKG_UPDATE="dnf makecache -y"
                PKG_INSTALL="dnf install -y"
            else
                PKG_UPDATE="yum makecache -y"
                PKG_INSTALL="yum install -y"
            fi
            ;;
        *suse*|*sles*)
            OS_FAMILY="suse"
            PKG_UPDATE="zypper refresh"
            PKG_INSTALL="zypper install -y"
            ;;
        *)
            die "Unsupported OS family (ID=$OS_ID ID_LIKE=$OS_LIKE). Supported: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma/Fedora/Amazon Linux, SUSE/SLES."
            ;;
    esac
    ok "Detected OS: $OS_ID (family: $OS_FAMILY)"
}

# OpenSearch bundles its own JDK, so only basic tooling is required.
install_base_deps() {
    log "Installing prerequisite packages (curl, wget, tar, openssl, ...)..."
    $PKG_UPDATE >> "$LOG_FILE" 2>&1
    case "$OS_FAMILY" in
        debian) $PKG_INSTALL curl wget tar gzip openssl iproute2 procps ca-certificates >> "$LOG_FILE" 2>&1 ;;
        rhel)   $PKG_INSTALL curl wget tar gzip openssl iproute procps-ng ca-certificates >> "$LOG_FILE" 2>&1 ;;
        suse)   $PKG_INSTALL curl wget tar gzip openssl iproute2 procps ca-certificates >> "$LOG_FILE" 2>&1 ;;
    esac || die "Prerequisite installation failed. See $LOG_FILE"
    ok "Prerequisites installed."
}

# ---------- helpers ----------
gen_secret() {
    # 24 chars, alphanumeric only (safe in YAML / JSON / shell / URLs without escaping)
    openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24
}

gen_password() {
    # Alphanumeric + guaranteed upper/lower/digit so it satisfies typical password policies
    echo "$(gen_secret)Aa1"
}

detect_primary_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -n1)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

valid_ip() {
    local ip="$1" octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    for octet in ${ip//./ }; do
        [ "$((10#$octet))" -le 255 ] || return 1
    done
    return 0
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# prompt_nonempty TEXT DEFAULT [CURRENT_VALUE]
prompt_nonempty() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        [ -n "$val" ] || die "AUTOMATED mode: empty value not allowed for: $prompt_text"
        echo "$val"; return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"
        [ -n "$val" ] && { echo "$val"; return 0; }
        echo "  Value cannot be empty." >&2
    done
}

# prompt_ip TEXT DEFAULT [CURRENT_VALUE]
prompt_ip() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        valid_ip "$val" || die "AUTOMATED mode: invalid IPv4 value '$val' for: $prompt_text"
        echo "$val"; return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"
        valid_ip "$val" && { echo "$val"; return 0; }
        echo "  '$val' is not a valid IPv4 address, try again." >&2
    done
}

# prompt_port TEXT DEFAULT [CURRENT_VALUE]
prompt_port() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        valid_port "$val" || die "AUTOMATED mode: invalid port '$val' for: $prompt_text"
        echo "$val"; return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"
        valid_port "$val" && { echo "$val"; return 0; }
        echo "  '$val' is not a valid port, try again." >&2
    done
}

# prompt_ip_list TEXT DEFAULT [CURRENT_VALUE]  -> comma-separated, validated, de-spaced
prompt_ip_list() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val ip bad
    local -a _arr
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"; val="${val// /}"
        [ -n "$val" ] || die "AUTOMATED mode: empty IP list for: $prompt_text"
        IFS=',' read -ra _arr <<< "$val"
        for ip in "${_arr[@]}"; do valid_ip "$ip" || die "AUTOMATED mode: invalid IPv4 '$ip' in: $prompt_text"; done
        echo "$val"; return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"; val="${val// /}"
        bad=0
        IFS=',' read -ra _arr <<< "$val"
        for ip in "${_arr[@]}"; do valid_ip "$ip" || { echo "  '$ip' is not a valid IPv4 address." >&2; bad=1; }; done
        [ -n "$val" ] && [ "$bad" -eq 0 ] && { echo "$val"; return 0; }
    done
}

# prompt_name_list TEXT DEFAULT CURRENT_VALUE EXPECTED_COUNT -> comma-separated unique node names
prompt_name_list() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" count="$4" val n bad
    local -a _arr
    while true; do
        if [ "$AUTOMATED" = "1" ]; then
            val="${current_val:-$default_val}"
        else
            read -rp "$prompt_text [$default_val]: " val
            val="${val:-$default_val}"
        fi
        val="${val// /}"
        IFS=',' read -ra _arr <<< "$val"
        bad=""
        if [ "${#_arr[@]}" -ne "$count" ]; then
            bad="expected ${count} names (one per IP in NODE_IPS, same order) but got ${#_arr[@]}"
        else
            for n in "${_arr[@]}"; do
                valid_name "$n" || { bad="invalid node name '$n' (letters, digits, '.', '_' and '-' only)"; break; }
            done
        fi
        if [ -z "$bad" ] && [ "$(printf '%s\n' "${_arr[@]}" | sort -u | wc -l)" -ne "$count" ]; then
            bad="node names must be unique"
        fi
        if [ -z "$bad" ]; then echo "$val"; return 0; fi
        [ "$AUTOMATED" = "1" ] && die "AUTOMATED mode: NODE_NAMES: $bad"
        echo "  $bad" >&2
    done
}

# prompt_mode CURRENT_VALUE
prompt_mode() {
    local current_val="${1:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-standalone}"
        case "$val" in standalone|cluster) echo "$val"; return 0;; esac
        die "AUTOMATED mode: MODE must be 'standalone' or 'cluster', got '$val'."
    fi
    while true; do
        read -rp "Installation mode (standalone/cluster) [standalone]: " val
        val="${val:-standalone}"
        case "$val" in standalone|cluster) echo "$val"; return 0;; esac
        echo "  Enter 'standalone' or 'cluster'." >&2
    done
}

# prompt_base_dir TEXT DEFAULT [CURRENT_VALUE]  (rejects '/', empty, system dirs)
prompt_base_dir() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"; val="${val%/}"
        case "$val" in
            ""|"/"|"/root"|"/home"|"/etc"|"/usr"|"/var"|"/bin"|"/sbin"|"/lib"|"/boot"|"/sys"|"/proc"|"/dev")
                die "AUTOMATED mode: refusing to install under '$val' — this is a system directory." ;;
        esac
        [[ "$val" == /* ]] || die "AUTOMATED mode: path must be absolute, got '$val'."
        echo "$val"; return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"; val="${val%/}"
        case "$val" in
            ""|"/"|"/root"|"/home"|"/etc"|"/usr"|"/var"|"/bin"|"/sbin"|"/lib"|"/boot"|"/sys"|"/proc"|"/dev")
                echo "  Refusing to install under '$val' — this is a system directory. Choose a dedicated path (e.g. /opt/ausiytic)." >&2
                continue ;;
        esac
        [[ "$val" == /* ]] || { echo "  Path must be absolute (start with /)." >&2; continue; }
        echo "$val"; return 0
    done
}

# check_path NAME VALUE  (non-interactive validation for env-only path overrides)
check_path() {
    local name="$1" val="${2%/}"
    case "$val" in
        ""|"/"|"/root"|"/home"|"/etc"|"/usr"|"/var"|"/bin"|"/sbin"|"/lib"|"/boot"|"/sys"|"/proc"|"/dev")
            die "${name}: refusing system directory '${val}'." ;;
    esac
    [[ "$val" == /* ]] || die "${name} must be an absolute path, got '${val}'."
    echo "$val"
}

# ensure_base_layout BASE  -> checks <BASE>/softwares and <BASE>/apps, creates whichever is missing
ensure_base_layout() {
    local base="${1%/}" d
    for d in "$base" "$base/softwares" "$base/apps"; do
        if [ -d "$d" ]; then
            ok "Directory present: $d"
        else
            mkdir -p "$d" || die "Could not create directory $d (check the mount and permissions)."
            ok "Directory created: $d"
        fi
    done
    [ -w "$base" ] || die "Base directory $base is not writable."
}

ensure_service_user() {
    local svc_user="$1" home_dir="$2"
    if id "$svc_user" >/dev/null 2>&1; then
        ok "OS user '$svc_user' already exists."
    else
        log "Creating OS user '$svc_user'..."
        useradd --system --home-dir "$home_dir" --shell /bin/bash "$svc_user" \
            || die "Failed to create OS user $svc_user"
        ok "OS user '$svc_user' created."
    fi
}

# index_of_ip IP  (1-based position within NODE_IPS_ARR)
index_of_ip() {
    local target="$1" i=1 ip
    for ip in "${NODE_IPS_ARR[@]}"; do
        [ "$ip" = "$target" ] && { echo "$i"; return 0; }
        i=$((i+1))
    done
    return 1
}

calc_heap() {
    local kb mb half
    kb=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
    mb=$((kb / 1024)); half=$((mb / 2))
    [ "$half" -gt 31744 ] && half=31744     # stay under compressed-oops threshold
    [ "$half" -lt 512 ] && half=512
    echo "${half}m"
}

#================================================================
# 0. Pre-flight
#================================================================
require_root
print_banner "OpenSearch 3.3.2 - Installation (standalone / cluster)"
[ "$AUTOMATED" = "1" ] && log "Running in AUTOMATED (non-interactive) mode."

#================================================================
# 1. Input (interactive or env-var driven)
#================================================================
MODE=$(prompt_mode "${MODE:-}") || exit 1
OS_VERSION=$(prompt_nonempty "OpenSearch version to install" "3.3.2" "${OS_VERSION:-}") || exit 1
[[ "$OS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "OS_VERSION must look like 3.3.2, got '$OS_VERSION'."
BASE_DIR=$(prompt_base_dir "Base volume/mount path to install under (e.g. /opt/mydata)" "/opt/ausiytic" "${BASE_DIR:-}") || exit 1
ensure_base_layout "$BASE_DIR"      # create <BASE_DIR>/softwares and <BASE_DIR>/apps if missing
OS_ROOT=$(prompt_base_dir "OpenSearch install root (binaries/data/logs go under it)" "${BASE_DIR}/apps/opensearch" "${OS_ROOT:-}") || exit 1
OS_HOME=$(check_path OS_HOME "${OS_HOME:-${OS_ROOT}/binaries}") || exit 1
OS_DATA=$(check_path OS_DATA "${OS_DATA:-${OS_ROOT}/data}") || exit 1
OS_LOGS=$(check_path OS_LOGS "${OS_LOGS:-${OS_ROOT}/logs}") || exit 1
SOURCE_DIR=$(check_path SOURCE_DIR "${SOURCE_DIR:-${BASE_DIR}/softwares}") || exit 1
CRED_FILE=$(check_path CRED_FILE "${CRED_FILE:-${OS_ROOT}/opensearch_credentials.txt}") || exit 1
{ [ "$OS_HOME" != "$OS_DATA" ] && [ "$OS_HOME" != "$OS_LOGS" ] && [ "$OS_DATA" != "$OS_LOGS" ]; } \
    || die "OS_HOME, OS_DATA and OS_LOGS must be three different directories."

SERVICE_USER=$(prompt_nonempty "OS user to run OpenSearch as (must not be root)" "opensearch" "${SERVICE_USER:-}") || exit 1
[ "$SERVICE_USER" != "root" ] || die "OpenSearch refuses to run as root. Choose another SERVICE_USER."
HTTP_PORT=$(prompt_port "HTTP (REST) port" "9200" "${HTTP_PORT:-}") || exit 1
TRANSPORT_PORT=$(prompt_port "Transport (node-to-node) port" "9300" "${TRANSPORT_PORT:-}") || exit 1
[ "$HTTP_PORT" != "$TRANSPORT_PORT" ] || die "HTTP_PORT and TRANSPORT_PORT must differ."

DETECTED_IP=$(detect_primary_ip)
[ -z "$DETECTED_IP" ] && DETECTED_IP="127.0.0.1"
THIS_NODE_IP=$(prompt_ip "This server's IP address" "$DETECTED_IP" "${THIS_NODE_IP:-}") || exit 1
CLUSTER_NAME=$(prompt_nonempty "Cluster name" "ausiytic-opensearch" "${CLUSTER_NAME:-}") || exit 1

if [ "$MODE" = "cluster" ]; then
    NODE_IPS=$(prompt_ip_list "IPs of ALL cluster nodes, comma-separated (include this server; first one generates certificates)" "$THIS_NODE_IP" "${NODE_IPS:-}") || exit 1
    IFS=',' read -ra NODE_IPS_ARR <<< "$NODE_IPS"
    [ "$(printf '%s\n' "${NODE_IPS_ARR[@]}" | sort -u | wc -l)" -eq "${#NODE_IPS_ARR[@]}" ] || die "NODE_IPS contains duplicates: $NODE_IPS"
    NODE_INDEX=$(index_of_ip "$THIS_NODE_IP") || die "This server's IP ($THIS_NODE_IP) is not in NODE_IPS ($NODE_IPS)."

    DEFAULT_NAMES=""
    for ((i=1; i<=${#NODE_IPS_ARR[@]}; i++)); do DEFAULT_NAMES+="os-node-${i},"; done
    DEFAULT_NAMES="${DEFAULT_NAMES%,}"
    if [ -n "${NODE_NAME:-}" ] && [ -z "${NODE_NAMES:-}" ]; then
        warn "NODE_NAME is ignored in cluster mode; use NODE_NAMES (one per IP in NODE_IPS, same order, same on all nodes)."
    fi
    NODE_NAMES=$(prompt_name_list "Node names, comma-separated, one per IP in the SAME ORDER as the IP list" "$DEFAULT_NAMES" "${NODE_NAMES:-}" "${#NODE_IPS_ARR[@]}") || exit 1
    IFS=',' read -ra NODE_NAMES_ARR <<< "$NODE_NAMES"
    NODE_NAME="${NODE_NAMES_ARR[$((NODE_INDEX-1))]}"

    CLUSTER_MANAGER_IPS=$(prompt_ip_list "IPs of cluster-manager-eligible nodes (subset of the list above)" "$NODE_IPS" "${CLUSTER_MANAGER_IPS:-}") || exit 1
    IFS=',' read -ra MANAGER_IPS_ARR <<< "$CLUSTER_MANAGER_IPS"
    for mip in "${MANAGER_IPS_ARR[@]}"; do
        index_of_ip "$mip" >/dev/null || die "Manager IP '$mip' is not part of NODE_IPS ($NODE_IPS)."
    done
    if [ "${#MANAGER_IPS_ARR[@]}" -lt 3 ]; then
        warn "Only ${#MANAGER_IPS_ARR[@]} cluster-manager-eligible node(s): if one fails the cluster cannot elect a manager. 3 are recommended."
    elif [ $(( ${#MANAGER_IPS_ARR[@]} % 2 )) -eq 0 ]; then
        warn "An even number (${#MANAGER_IPS_ARR[@]}) of cluster-manager-eligible nodes gives no extra fault tolerance. Use an odd number."
    fi

    THIS_IS_MANAGER=0
    printf '%s\n' "${MANAGER_IPS_ARR[@]}" | grep -qx "$THIS_NODE_IP" && THIS_IS_MANAGER=1
    if [ "$THIS_IS_MANAGER" -eq 1 ]; then DEFAULT_ROLES="cluster_manager,data,ingest"; else DEFAULT_ROLES="data,ingest"; fi
    NODE_ROLES=$(prompt_nonempty "Roles for THIS node (comma-separated)" "$DEFAULT_ROLES" "${NODE_ROLES:-}") || exit 1
    NODE_ROLES="${NODE_ROLES// /}"
    [[ "$NODE_ROLES" =~ ^[a-z_]+(,[a-z_]+)*$ ]] || die "Invalid NODE_ROLES '$NODE_ROLES' (comma-separated lowercase role names)."
    HAS_MGR_ROLE=0
    [[ ",${NODE_ROLES}," == *",cluster_manager,"* ]] && HAS_MGR_ROLE=1
    if [ "$HAS_MGR_ROLE" -ne "$THIS_IS_MANAGER" ]; then
        warn "NODE_ROLES ($NODE_ROLES) and CLUSTER_MANAGER_IPS ($CLUSTER_MANAGER_IPS) disagree about whether $THIS_NODE_IP is cluster-manager-eligible. Make them consistent on every node."
    fi
else
    NODE_IPS="$THIS_NODE_IP"
    IFS=',' read -ra NODE_IPS_ARR <<< "$NODE_IPS"
    NODE_INDEX=1
    CLUSTER_MANAGER_IPS="$THIS_NODE_IP"
    IFS=',' read -ra MANAGER_IPS_ARR <<< "$CLUSTER_MANAGER_IPS"
    NODE_NAME=$(prompt_nonempty "Node name" "os-node-1" "${NODE_NAME:-}") || exit 1
    valid_name "$NODE_NAME" || die "Invalid NODE_NAME '$NODE_NAME' (letters, digits, '.', '_' and '-' only)."
    NODE_NAMES="$NODE_NAME"
    NODE_NAMES_ARR=("$NODE_NAME")
    NODE_ROLES="cluster_manager,data,ingest"
fi

READ_USER="${READ_USER:-readuser}"
WRITE_USER="${WRITE_USER:-writeuser}"
for u in "$READ_USER" "$WRITE_USER"; do
    valid_name "$u" || die "Invalid user name '$u' (letters, digits, '.', '_' and '-' only)."
    case "$u" in admin|kibanaserver) die "User name '$u' is reserved." ;; esac
done
[ "$READ_USER" != "$WRITE_USER" ] || die "READ_USER and WRITE_USER must be different."

heap_to_mb() { case "$1" in *g) echo $(( ${1%g} * 1024 )) ;; *m) echo "${1%m}" ;; esac; }

while true; do
    HEAP_SIZE=$(prompt_nonempty "JVM heap size, Xms=Xmx (e.g. 4g or 3888m; recommended 50% of RAM, max 31g)" "${HEAP_SIZE:-$(calc_heap)}" "${HEAP_SIZE:-}") || exit 1
    HEAP_SIZE="${HEAP_SIZE,,}"; HEAP_SIZE="${HEAP_SIZE// /}"
    [[ "$HEAP_SIZE" =~ ^[1-9][0-9]*[mg]$ ]] && break
    [ "$AUTOMATED" = "1" ] && die "AUTOMATED mode: HEAP_SIZE '$HEAP_SIZE' is invalid (use a number followed by m or g, e.g. 4g or 3888m)."
    echo "  '$HEAP_SIZE' is invalid. Use a number followed by m or g, e.g. 4g or 3888m." >&2
    HEAP_SIZE=""
done
HEAP_MB=$(heap_to_mb "$HEAP_SIZE")
TOTAL_MB=$(( $(awk '/^MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
[ "$HEAP_MB" -lt "$TOTAL_MB" ] || die "HEAP_SIZE ${HEAP_SIZE} is not smaller than this server's RAM (${TOTAL_MB}m)."
[ "$HEAP_MB" -le 31744 ] || warn "HEAP_SIZE ${HEAP_SIZE} is above ~31g: the JVM loses compressed object pointers and wastes memory. 31g or less is recommended."
[ $((HEAP_MB * 2)) -le "$TOTAL_MB" ] || warn "HEAP_SIZE ${HEAP_SIZE} is more than 50% of RAM (${TOTAL_MB}m); OpenSearch needs the rest for the OS file cache."
[ "$HEAP_MB" -ge 512 ] || warn "HEAP_SIZE ${HEAP_SIZE} is very small (< 512m)."
HEALTH_WAIT_SECS="${HEALTH_WAIT_SECS:-${CLUSTER_WAIT_SECS:-180}}"
SSH_KEY="${SSH_KEY:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_PORT="${SSH_PORT:-22}"
DEFAULT_SSH_USER="${SUDO_USER:-root}"
INVOKER_HOME=$(getent passwd "$DEFAULT_SSH_USER" | cut -d: -f6)
INVOKER_HOME="${INVOKER_HOME:-/root}"

# Bundle transfer: only the FIRST node of a cluster generates bundles and pushes them to the others.
if [ "$MODE" = "cluster" ] && [ "$NODE_INDEX" -eq 1 ] && [ "${#NODE_IPS_ARR[@]}" -gt 1 ]; then
    if [ "$AUTOMATED" = "1" ]; then
        if [ -z "${TRANSFER_TO_PEERS:-}" ]; then
            if [ -n "${SSH_KEY}${SSH_PASSWORD}" ]; then TRANSFER_TO_PEERS="Y"; else TRANSFER_TO_PEERS="N"; fi
        fi
        SSH_USER="${SSH_USER:-$DEFAULT_SSH_USER}"
    else
        echo
        read -rp "Copy the certificate bundles to the other nodes automatically over SSH? [Y/n]: " TRANSFER_TO_PEERS
        TRANSFER_TO_PEERS="${TRANSFER_TO_PEERS:-Y}"
        if [[ "$TRANSFER_TO_PEERS" =~ ^[Yy]$ ]]; then
            read -rp "SSH user on the other nodes [$DEFAULT_SSH_USER]: " SSH_USER
            SSH_USER="${SSH_USER:-$DEFAULT_SSH_USER}"
            read -rp "Path to the SSH private key (blank = auto-detect / ssh-agent / password): " SSH_KEY
            SSH_KEY="${SSH_KEY/#\~/$INVOKER_HOME}"
            if [ -z "$SSH_KEY" ]; then
                read -rsp "SSH password for ${SSH_USER} on the other nodes (blank = none): " SSH_PASSWORD
                echo
            fi
        fi
    fi
else
    TRANSFER_TO_PEERS="${TRANSFER_TO_PEERS:-N}"
    SSH_USER="${SSH_USER:-root}"
fi
CERT_ORG="${CERT_ORG:-ausiytic}"
CERT_EXTRA_DNS="${CERT_EXTRA_DNS:-}"

#================================================================
# 2. Derived paths
#================================================================
OS_CONF="${OS_HOME}/config"
CA_DIR="${OS_ROOT}/certs-ca"           # CA private key lives ONLY on the generating node
BUNDLE_DIR="${OS_ROOT}/bundles"        # per-node bundles generated here
CONF_BACKUP_DIR="${OS_ROOT}/conf_backups"
NODE_BUNDLE_DEFAULT="/tmp/opensearch_bundle_${THIS_NODE_IP}.tar.gz"
case "$(uname -m)" in
    x86_64|amd64)  OS_ARCH="x64" ;;
    aarch64|arm64) OS_ARCH="arm64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

#================================================================
# 3. OS + dependencies + kernel/limits tuning
#================================================================
detect_os
install_base_deps

log "Applying kernel settings (vm.max_map_count) ..."
cat > /etc/sysctl.d/99-opensearch.conf <<EOF
vm.max_map_count=262144
EOF
sysctl -w vm.max_map_count=262144 >> "$LOG_FILE" 2>&1 || warn "Could not set vm.max_map_count at runtime (container?). Set it on the host."

log "Applying ulimits for ${SERVICE_USER} ..."
cat > /etc/security/limits.d/99-opensearch.conf <<EOF
${SERVICE_USER} soft nofile 65535
${SERVICE_USER} hard nofile 65535
${SERVICE_USER} soft nproc  4096
${SERVICE_USER} hard nproc  4096
${SERVICE_USER} soft memlock unlimited
${SERVICE_USER} hard memlock unlimited
EOF
ok "System tuning applied."

#================================================================
# 4. Directories & service user
#================================================================
log "Creating directory structure under $OS_ROOT ..."
mkdir -p "$SOURCE_DIR" "$OS_ROOT" "$OS_HOME" "$OS_DATA" "$OS_LOGS" "$CONF_BACKUP_DIR"
ensure_service_user "$SERVICE_USER" "$OS_ROOT"
chown "$SERVICE_USER":"$SERVICE_USER" "$OS_ROOT"

#================================================================
# 5. Download + extract OpenSearch
#================================================================
if [ -x "${OS_HOME}/bin/opensearch" ]; then
    EXISTING_VER=$(cat "${OS_HOME}/.installed_version" 2>/dev/null || echo "unknown")
    warn "OpenSearch binaries already present at $OS_HOME (version: $EXISTING_VER) — skipping download/extract."
    if [ "$EXISTING_VER" != "unknown" ] && [ "$EXISTING_VER" != "$OS_VERSION" ]; then
        warn "Requested version $OS_VERSION differs from installed $EXISTING_VER. This script does not upgrade in place."
    fi
else
    TARBALL="opensearch-${OS_VERSION}-linux-${OS_ARCH}.tar.gz"
    DOWNLOAD_URL="${DOWNLOAD_URL:-https://artifacts.opensearch.org/releases/bundle/opensearch/${OS_VERSION}/${TARBALL}}"
    if [ -n "${TARBALL_PATH:-}" ]; then
        [ -f "$TARBALL_PATH" ] || die "TARBALL_PATH '$TARBALL_PATH' does not exist."
        cp -f "$TARBALL_PATH" "${SOURCE_DIR}/${TARBALL}"
        ok "Using local tarball $TARBALL_PATH"
    elif [ -f "${SOURCE_DIR}/${TARBALL}" ]; then
        ok "Source tarball already downloaded: ${SOURCE_DIR}/${TARBALL}"
    else
        log "Downloading OpenSearch ${OS_VERSION} from ${DOWNLOAD_URL} ..."
        wget -q --show-progress "$DOWNLOAD_URL" -O "${SOURCE_DIR}/${TARBALL}" \
            || { rm -f "${SOURCE_DIR}/${TARBALL}"; die "Download failed for $DOWNLOAD_URL. Check version number / network access."; }
    fi
    if [ -n "${OS_SHA512:-}" ]; then
        log "Verifying SHA-512 checksum ..."
        echo "${OS_SHA512}  ${SOURCE_DIR}/${TARBALL}" | sha512sum -c - >> "$LOG_FILE" 2>&1 \
            || die "Checksum mismatch for ${TARBALL}."
        ok "Checksum verified."
    fi
    log "Extracting to $OS_HOME ..."
    tar -xzf "${SOURCE_DIR}/${TARBALL}" -C "$OS_HOME" --strip-components=1 >> "$LOG_FILE" 2>&1 \
        || die "Extraction failed. See $LOG_FILE"
    [ -x "${OS_HOME}/bin/opensearch" ] || die "Extraction finished but ${OS_HOME}/bin/opensearch is missing."
    echo "$OS_VERSION" > "${OS_HOME}/.installed_version"
    ok "OpenSearch ${OS_VERSION} extracted."
fi

#================================================================
# 6. TLS certificates + shared secrets (per-node bundles)
#================================================================
mk_cert_ext() {
    # mk_cert_ext FILE IP NAME
    local f="$1" ip="$2" name="$3" i=3 d
    local -a _d
    cat > "$f" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt
[alt]
IP.1=${ip}
IP.2=127.0.0.1
DNS.1=localhost
DNS.2=${name}
EOF
    if [ -n "$CERT_EXTRA_DNS" ]; then
        IFS=',' read -ra _d <<< "${CERT_EXTRA_DNS// /}"
        for d in "${_d[@]}"; do
            [ -n "$d" ] || continue
            echo "DNS.${i}=${d}" >> "$f"; i=$((i+1))
        done
    fi
    echo "RID.1=1.2.3.4.5.5" >> "$f"
}

# issue_cert NAME OUTDIR [IP]   (writes OUTDIR/NAME.pem and NAME-key.pem in PKCS#8)
issue_cert() {
    local name="$1" outdir="$2" ip="${3:-}" tmp
    tmp=$(mktemp -d)
    openssl genrsa -out "${tmp}/k.pem" 2048 >> "$LOG_FILE" 2>&1 || die "openssl genrsa failed for $name"
    openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in "${tmp}/k.pem" -out "${outdir}/${name}-key.pem" >> "$LOG_FILE" 2>&1 \
        || die "PKCS#8 conversion failed for $name"
    openssl req -new -key "${outdir}/${name}-key.pem" -out "${tmp}/r.csr" \
        -subj "/C=IN/O=${CERT_ORG}/OU=${CERT_ORG}/CN=${name}" >> "$LOG_FILE" 2>&1 || die "CSR failed for $name"
    if [ -n "$ip" ]; then
        mk_cert_ext "${tmp}/ext.cnf" "$ip" "$name"
        openssl x509 -req -in "${tmp}/r.csr" -CA "${CA_DIR}/root-ca.pem" -CAkey "${CA_DIR}/root-ca-key.pem" \
            -CAcreateserial -CAserial "${CA_DIR}/ca.srl" -sha256 -days 1825 -extfile "${tmp}/ext.cnf" \
            -out "${outdir}/${name}.pem" >> "$LOG_FILE" 2>&1 || die "Signing failed for $name"
    else
        openssl x509 -req -in "${tmp}/r.csr" -CA "${CA_DIR}/root-ca.pem" -CAkey "${CA_DIR}/root-ca-key.pem" \
            -CAcreateserial -CAserial "${CA_DIR}/ca.srl" -sha256 -days 1825 \
            -out "${outdir}/${name}.pem" >> "$LOG_FILE" 2>&1 || die "Signing failed for $name"
    fi
    rm -rf "$tmp"
}

# Values saved by a previous run (so re-runs never desync the security index)
read_cred() { [ -f "$CRED_FILE" ] && grep -m1 "^$1=" "$CRED_FILE" | cut -d= -f2-; }

generate_bundles() {
    log "Generating private CA and per-node certificate bundles ..."
    mkdir -p "$CA_DIR" "$BUNDLE_DIR"
    chmod 700 "$CA_DIR" "$BUNDLE_DIR"
    if [ ! -f "${CA_DIR}/root-ca.pem" ]; then
        openssl genrsa -out "${CA_DIR}/root-ca-key.pem" 4096 >> "$LOG_FILE" 2>&1 || die "CA key generation failed"
        openssl req -new -x509 -sha256 -days 3650 -key "${CA_DIR}/root-ca-key.pem" \
            -subj "/C=IN/O=${CERT_ORG}/OU=${CERT_ORG}/CN=${CERT_ORG}-opensearch-root-ca" \
            -out "${CA_DIR}/root-ca.pem" >> "$LOG_FILE" 2>&1 || die "CA certificate generation failed"
        chmod 600 "${CA_DIR}/root-ca-key.pem"
        ok "Root CA created in $CA_DIR (keep root-ca-key.pem private; it is needed to add nodes later)."
    else
        ok "Reusing existing root CA in $CA_DIR"
    fi

    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(read_cred ADMIN_PASSWORD)}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen_password)}"
    KIBANASERVER_PASSWORD="${KIBANASERVER_PASSWORD:-$(read_cred KIBANASERVER_PASSWORD)}"
    KIBANASERVER_PASSWORD="${KIBANASERVER_PASSWORD:-$(gen_password)}"
    READ_USER_PASSWORD="${READ_USER_PASSWORD:-$(read_cred READ_USER_PASSWORD)}"
    READ_USER_PASSWORD="${READ_USER_PASSWORD:-$(gen_password)}"
    WRITE_USER_PASSWORD="${WRITE_USER_PASSWORD:-$(read_cred WRITE_USER_PASSWORD)}"
    WRITE_USER_PASSWORD="${WRITE_USER_PASSWORD:-$(gen_password)}"

    local admin_tmp ip idx stage
    admin_tmp=$(mktemp -d)
    issue_cert "admin" "$admin_tmp"
    for ip in "${NODE_IPS_ARR[@]}"; do
        idx=$(index_of_ip "$ip")
        stage=$(mktemp -d)
        # certificate identity (CN=os-node-N) is independent of the node.name you chose
        issue_cert "os-node-${idx}" "$stage" "$ip"
        cp "${CA_DIR}/root-ca.pem" "${stage}/root-ca.pem"
        mv "${stage}/os-node-${idx}.pem"     "${stage}/node.pem"
        mv "${stage}/os-node-${idx}-key.pem" "${stage}/node-key.pem"
        cp "${admin_tmp}/admin.pem" "${admin_tmp}/admin-key.pem" "$stage/"
        cat > "${stage}/secrets.env" <<EOF
ADMIN_PASSWORD=${ADMIN_PASSWORD}
KIBANASERVER_PASSWORD=${KIBANASERVER_PASSWORD}
READ_USER=${READ_USER}
READ_USER_PASSWORD=${READ_USER_PASSWORD}
WRITE_USER=${WRITE_USER}
WRITE_USER_PASSWORD=${WRITE_USER_PASSWORD}
EOF
        tar -czf "${BUNDLE_DIR}/opensearch_bundle_${ip}.tar.gz" -C "$stage" . || die "Failed to create bundle for $ip"
        chmod 600 "${BUNDLE_DIR}/opensearch_bundle_${ip}.tar.gz"
        rm -rf "$stage"
        ok "Bundle created for ${ip} (certificate os-node-${idx})"
    done
    rm -rf "$admin_tmp"
}

# Locate an existing bundle for THIS node (explicit CERT_BUNDLE, or the default /tmp drop location)
FOUND_BUNDLE=""
if [ -n "${CERT_BUNDLE:-}" ]; then
    [ -f "$CERT_BUNDLE" ] || die "CERT_BUNDLE '$CERT_BUNDLE' does not exist."
    FOUND_BUNDLE="$CERT_BUNDLE"
elif [ -f "$NODE_BUNDLE_DEFAULT" ]; then
    FOUND_BUNDLE="$NODE_BUNDLE_DEFAULT"
elif [ -f "${BUNDLE_DIR}/opensearch_bundle_${THIS_NODE_IP}.tar.gz" ] && [ -f "${CA_DIR}/root-ca.pem" ]; then
    FOUND_BUNDLE="${BUNDLE_DIR}/opensearch_bundle_${THIS_NODE_IP}.tar.gz"
fi

if [ -n "$FOUND_BUNDLE" ] && [ "${REGENERATE_BUNDLES:-N}" != "Y" ]; then
    ok "Using certificate bundle: $FOUND_BUNDLE"
else
    # Only the first node of a cluster may create the CA; any other node doing so would end up
    # with a different CA and could never join the cluster.
    if [ "$MODE" = "cluster" ] && [ "$NODE_INDEX" -ne 1 ] && [ "${GENERATE_BUNDLES:-N}" != "Y" ]; then
        die "No certificate bundle found for ${THIS_NODE_IP} (looked for $NODE_BUNDLE_DEFAULT). Run this script on the FIRST node (${NODE_IPS_ARR[0]}) first and copy the bundle here, or set CERT_BUNDLE=/path/to/bundle.tar.gz."
    fi
    generate_bundles
    FOUND_BUNDLE="${BUNDLE_DIR}/opensearch_bundle_${THIS_NODE_IP}.tar.gz"
fi

# Install this node's certs into config/certs and read shared secrets
CERT_TARGET="${OS_CONF}/certs"
mkdir -p "$CERT_TARGET"
tar -xzf "$FOUND_BUNDLE" -C "$CERT_TARGET" || die "Failed to extract $FOUND_BUNDLE"
for f in root-ca.pem node.pem node-key.pem admin.pem admin-key.pem secrets.env; do
    [ -f "${CERT_TARGET}/${f}" ] || die "Bundle is missing ${f}. Regenerate bundles on the first node (REGENERATE_BUNDLES=Y)."
done
secret_get() { grep -m1 "^$1=" "${CERT_TARGET}/secrets.env" | cut -d= -f2-; }
ADMIN_PASSWORD=$(secret_get ADMIN_PASSWORD)
KIBANASERVER_PASSWORD=$(secret_get KIBANASERVER_PASSWORD)
READ_USER=$(secret_get READ_USER)
READ_USER_PASSWORD=$(secret_get READ_USER_PASSWORD)
WRITE_USER=$(secret_get WRITE_USER)
WRITE_USER_PASSWORD=$(secret_get WRITE_USER_PASSWORD)
for v in ADMIN_PASSWORD KIBANASERVER_PASSWORD READ_USER READ_USER_PASSWORD WRITE_USER WRITE_USER_PASSWORD; do
    [ -n "${!v}" ] || die "$v missing from the bundle (bundle made by an older script version?). Regenerate on the first node with REGENERATE_BUNDLES=Y."
done
# secrets.env is not needed at runtime: keep it out of the config dir
rm -f "${CERT_TARGET}/secrets.env"
ok "Certificates installed to $CERT_TARGET"

#================================================================
# 7. Configure opensearch.yml / jvm.options
#================================================================
cp -n "${OS_CONF}/opensearch.yml" "${CONF_BACKUP_DIR}/opensearch.yml.orig" 2>/dev/null || true
cp -n "${OS_CONF}/jvm.options"    "${CONF_BACKUP_DIR}/jvm.options.orig"    2>/dev/null || true
for f in internal_users.yml roles.yml roles_mapping.yml; do
    cp -n "${OS_CONF}/opensearch-security/${f}" "${CONF_BACKUP_DIR}/${f}.orig" 2>/dev/null || true
done

log "Writing opensearch.yml (mode: ${MODE}, node: ${NODE_NAME}, roles: ${NODE_ROLES}) ..."

yaml_list() {   # yaml_list a b c  ->  ["a","b","c"]
    local out="" x
    for x in "$@"; do out="${out}\"${x}\","; done
    echo "[${out%,}]"
}
yaml_roles() { local -a _r; IFS=',' read -ra _r <<< "$1"; yaml_list "${_r[@]}"; }

if [ "$MODE" = "cluster" ]; then
    SEED_HOSTS=$(yaml_list "${NODE_IPS_ARR[@]/%/:${TRANSPORT_PORT}}")
    MGR_NAMES=()
    for mip in "${MANAGER_IPS_ARR[@]}"; do
        MGR_NAMES+=("${NODE_NAMES_ARR[$(( $(index_of_ip "$mip") - 1 ))]}")
    done
    INITIAL_MGRS=$(yaml_list "${MGR_NAMES[@]}")
    DISCOVERY_BLOCK="discovery.seed_hosts: ${SEED_HOSTS}"
    if [[ ",${NODE_ROLES}," == *",cluster_manager,"* ]]; then
        DISCOVERY_BLOCK="${DISCOVERY_BLOCK}
cluster.initial_cluster_manager_nodes: ${INITIAL_MGRS}"
    fi
else
    DISCOVERY_BLOCK="discovery.type: single-node"
fi

cat > "${OS_CONF}/opensearch.yml" <<EOF
# Generated by opensearch_install.sh on $(date +%F) - mode: ${MODE}
cluster.name: ${CLUSTER_NAME}
node.name: ${NODE_NAME}
node.roles: $(yaml_roles "$NODE_ROLES")

path.data: ${OS_DATA}
path.logs: ${OS_LOGS}

network.host: ["${THIS_NODE_IP}", "_local_"]
network.publish_host: ${THIS_NODE_IP}
http.port: ${HTTP_PORT}
transport.port: ${TRANSPORT_PORT}

${DISCOVERY_BLOCK}

bootstrap.memory_lock: true
action.destructive_requires_name: true

######## Security plugin ########
plugins.security.ssl.transport.pemcert_filepath: certs/node.pem
plugins.security.ssl.transport.pemkey_filepath: certs/node-key.pem
plugins.security.ssl.transport.pemtrustedcas_filepath: certs/root-ca.pem
plugins.security.ssl.transport.enforce_hostname_verification: false
plugins.security.ssl.http.enabled: true
plugins.security.ssl.http.pemcert_filepath: certs/node.pem
plugins.security.ssl.http.pemkey_filepath: certs/node-key.pem
plugins.security.ssl.http.pemtrustedcas_filepath: certs/root-ca.pem
plugins.security.allow_unsafe_democertificates: false
plugins.security.allow_default_init_securityindex: true
plugins.security.authcz.admin_dn:
  - "CN=admin,OU=${CERT_ORG},O=${CERT_ORG},C=IN"
plugins.security.nodes_dn:
  - "CN=os-node-*,OU=${CERT_ORG},O=${CERT_ORG},C=IN"
plugins.security.audit.type: internal_opensearch
plugins.security.enable_snapshot_restore_privilege: true
plugins.security.check_snapshot_restore_write_privileges: true
plugins.security.restapi.roles_enabled: ["all_access", "security_rest_api_access"]
plugins.security.system_indices.enabled: true
plugins.security.system_indices.indices: [".plugins-ml-config", ".plugins-ml-connector", ".plugins-ml-model-group", ".plugins-ml-model", ".plugins-ml-task", ".plugins-ml-conversation-meta", ".plugins-ml-conversation-interactions", ".plugins-ml-memory-meta", ".plugins-ml-memory-message", ".ml-metadata-index", ".ml-config", ".ml_commons_encryption_master_key", ".opendistro-alerting-config", ".opendistro-alerting-alert*", ".opendistro-anomaly-results*", ".opendistro-anomaly-detector*", ".opendistro-anomaly-checkpoints", ".opendistro-anomaly-detection-state", ".opendistro-reports-*", ".opensearch-notifications-*", ".opensearch-notebooks", ".opensearch-observability", ".ql-datasources", ".opendistro-asynchronous-search-response*", ".replication-metadata-store", ".opensearch-knn-models", ".geospatial-ip2geo-data*", ".plugins-flow-framework-config", ".plugins-flow-framework-templates", ".plugins-flow-framework-state"]
EOF

log "Setting JVM heap to ${HEAP_SIZE} ..."
sed -i -E "s/^-Xms.*/-Xms${HEAP_SIZE}/; s/^-Xmx.*/-Xmx${HEAP_SIZE}/" "${OS_CONF}/jvm.options"

#================================================================
# 8. Security config: users (admin, kibanaserver, read, write) + roles + mappings
#    Written BEFORE first start so the security index is created with them.
#================================================================
log "Generating password hashes for the security plugin ..."
HASH_TOOL="${OS_HOME}/plugins/opensearch-security/tools/hash.sh"
[ -f "$HASH_TOOL" ] || die "Security plugin hash tool not found at $HASH_TOOL"
chmod +x "${OS_HOME}"/plugins/opensearch-security/tools/*.sh 2>/dev/null || true

make_hash() {
    local h
    h=$(OPENSEARCH_JAVA_HOME="${OS_HOME}/jdk" JAVA_HOME="${OS_HOME}/jdk" OPENSEARCH_HOME="$OS_HOME" \
        bash "$HASH_TOOL" -p "$1" 2>>"$LOG_FILE" | tail -n1)
    [[ "$h" == \$2* ]] || die "Failed to generate password hash (got: '${h:0:6}...'). See $LOG_FILE"
    echo "$h"
}
ADMIN_HASH=$(make_hash "$ADMIN_PASSWORD") || exit 1
KIBANA_HASH=$(make_hash "$KIBANASERVER_PASSWORD") || exit 1
READ_HASH=$(make_hash "$READ_USER_PASSWORD") || exit 1
WRITE_HASH=$(make_hash "$WRITE_USER_PASSWORD") || exit 1

SEC_DIR="${OS_CONF}/opensearch-security"
cat > "${SEC_DIR}/internal_users.yml" <<EOF
---
# Generated by opensearch_install.sh - only the users below exist.
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "${ADMIN_HASH}"
  reserved: true
  backend_roles:
    - "admin"
  description: "Admin user"

kibanaserver:
  hash: "${KIBANA_HASH}"
  reserved: true
  description: "OpenSearch Dashboards server user"

${READ_USER}:
  hash: "${READ_HASH}"
  reserved: false
  backend_roles:
    - "read_only_role"
  description: "Read-only user"

${WRITE_USER}:
  hash: "${WRITE_HASH}"
  reserved: false
  backend_roles:
    - "write_role"
  description: "Write user"
EOF

# roles.yml / roles_mapping.yml keep the built-in entries; ours are appended once.
append_once() {   # append_once FILE KEY  (block on stdin)
    local file="$1" key="$2" block
    block=$(cat)
    if grep -qE "^${key}:" "$file"; then
        log "$(basename "$file"): '${key}' already defined — leaving as is."
    else
        printf '\n%s\n' "$block" >> "$file"
    fi
}

append_once "${SEC_DIR}/roles.yml" "read_only_role" <<EOF
read_only_role:
  reserved: false
  description: "Read-only access to all indices (opensearch_install.sh)"
  cluster_permissions: []
  index_permissions:
    - index_patterns:
        - "*"
      allowed_actions:
        - "read"
EOF
append_once "${SEC_DIR}/roles.yml" "write_role" <<EOF
write_role:
  reserved: false
  description: "Read/index/create/update on all indices (opensearch_install.sh)"
  cluster_permissions: []
  index_permissions:
    - index_patterns:
        - "*"
      allowed_actions:
        - "read"
        - "index"
        - "create"
        - "update"
EOF
append_once "${SEC_DIR}/roles_mapping.yml" "read_only_role" <<EOF
read_only_role:
  reserved: false
  users:
    - "${READ_USER}"
  description: "Maps ${READ_USER} to read_only_role"
EOF
append_once "${SEC_DIR}/roles_mapping.yml" "write_role" <<EOF
write_role:
  reserved: false
  users:
    - "${WRITE_USER}"
  description: "Maps ${WRITE_USER} to write_role"
EOF
ok "Security users, roles and mappings configured (admin, kibanaserver, ${READ_USER}, ${WRITE_USER})."

#================================================================
# 9. Ownership + systemd service
#================================================================
chown -R "$SERVICE_USER":"$SERVICE_USER" "$OS_HOME" "$OS_DATA" "$OS_LOGS" "$CONF_BACKUP_DIR"
chmod 700 "$CERT_TARGET"
chmod 600 "${CERT_TARGET}"/*.pem
chmod 600 "${SEC_DIR}/internal_users.yml"
[ -d "$CA_DIR" ] && chmod 700 "$CA_DIR"        # stays root-owned: the service never needs the CA key
[ -d "$BUNDLE_DIR" ] && chmod 700 "$BUNDLE_DIR"

log "Creating systemd unit: /etc/systemd/system/opensearch.service"
cat > /etc/systemd/system/opensearch.service <<EOF
[Unit]
Description=OpenSearch ${OS_VERSION} (${NODE_NAME}, ${MODE})
Documentation=https://opensearch.org/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=OPENSEARCH_HOME=${OS_HOME}
Environment=OPENSEARCH_PATH_CONF=${OS_CONF}
Environment=OPENSEARCH_JAVA_HOME=${OS_HOME}/jdk
WorkingDirectory=${OS_HOME}
ExecStart=${OS_HOME}/bin/opensearch
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
LimitNPROC=4096
LimitMEMLOCK=infinity
LimitAS=infinity
LimitFSIZE=infinity
TimeoutStartSec=300
TimeoutStopSec=120
KillMode=process
KillSignal=SIGTERM
SendSIGKILL=no
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable opensearch.service >> "$LOG_FILE" 2>&1
ok "systemd service 'opensearch' created and enabled."

#================================================================
# 10. Distribute bundles to peers (cluster mode, generating node only)
#================================================================
if [ "$MODE" = "cluster" ] && [ -d "$BUNDLE_DIR" ]; then
    SCP_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -P "$SSH_PORT")
    if [ -z "$SSH_KEY" ] && [ -z "$SSH_PASSWORD" ]; then
        # sudo changes HOME to root's, so look in the invoking user's ~/.ssh for a usable key
        for k in id_ed25519 id_rsa id_ecdsa; do
            [ -r "${INVOKER_HOME}/.ssh/${k}" ] && { SSH_KEY="${INVOKER_HOME}/.ssh/${k}"; break; }
        done
        [ -n "$SSH_KEY" ] && log "Using SSH key ${SSH_KEY} for the bundle transfer."
    fi
    if [ -n "$SSH_KEY" ]; then
        [ -r "$SSH_KEY" ] || die "SSH_KEY '$SSH_KEY' is not readable."
        SCP_OPTS+=(-i "$SSH_KEY")
    fi
    [ -z "$SSH_PASSWORD" ] && SCP_OPTS+=(-o BatchMode=yes)    # never hang on a password prompt
    SCP_CMD=(scp)
    if [ -n "$SSH_PASSWORD" ]; then
        command -v sshpass >/dev/null 2>&1 || $PKG_INSTALL sshpass >> "$LOG_FILE" 2>&1
        command -v sshpass >/dev/null 2>&1 && SCP_CMD=(sshpass -e scp) && export SSHPASS="$SSH_PASSWORD"
    fi
    for ip in "${NODE_IPS_ARR[@]}"; do
        [ "$ip" = "$THIS_NODE_IP" ] && continue
        b="${BUNDLE_DIR}/opensearch_bundle_${ip}.tar.gz"
        [ -f "$b" ] || continue
        if [[ "$TRANSFER_TO_PEERS" =~ ^[Yy]$ ]]; then
            if "${SCP_CMD[@]}" "${SCP_OPTS[@]}" "$b" "${SSH_USER}@${ip}:/tmp/opensearch_bundle_${ip}.tar.gz" >> "$LOG_FILE" 2>&1; then
                ok "Bundle copied to ${ip}:/tmp/opensearch_bundle_${ip}.tar.gz"
            else
                warn "Could not copy bundle to ${ip}. Copy manually: scp ${b} ${SSH_USER}@${ip}:/tmp/"
            fi
        else
            warn "Peer ${ip}: copy its bundle before installing there: scp ${b} <user>@${ip}:/tmp/   (or set TRANSFER_TO_PEERS=Y)"
        fi
    done
    unset SSHPASS
fi

#================================================================
# 11. Start + health check + make sure users/roles exist
#================================================================
log "Starting OpenSearch service ..."
systemctl restart opensearch.service || die "Failed to start opensearch.service — check 'journalctl -u opensearch'"

# Credentials go through a curl config on a pipe so they never show up in 'ps'.
os_curl() {
    curl -s --max-time 10 --cacert "${CERT_TARGET}/root-ca.pem" \
        -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASSWORD") \
        "https://${THIS_NODE_IP}:${HTTP_PORT}$1" 2>/dev/null
}

# sec_api METHOD PATH JSON -> prints the HTTP status code
sec_api() {
    printf '%s' "$3" | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X "$1" \
        --cacert "${CERT_TARGET}/root-ca.pem" \
        -K <(printf 'user = "admin:%s"\n' "$ADMIN_PASSWORD") \
        -H 'Content-Type: application/json' --data-binary @- \
        "https://${THIS_NODE_IP}:${HTTP_PORT}$2" 2>/dev/null
}

put_obj() {   # put_obj DESCRIPTION PATH JSON
    local code
    code=$(sec_api PUT "$2" "$3")
    case "$code" in
        200|201) ok "Security: $1 ready." ;;
        *) warn "Security: $1 returned HTTP ${code:-none}. Check admin credentials / cluster state and re-run." ; return 1 ;;
    esac
}

# Idempotent PUTs. The users/roles are already in the security config files above (applied
# when the security index is first created); this step covers a security index that already
# existed (re-runs) and keeps passwords in sync with the credentials file.
ensure_security_objects() {
    local rc=0
    log "Making sure the read/write roles and users exist (idempotent) ..."
    put_obj "role read_only_role"  "/_plugins/_security/api/roles/read_only_role" \
        '{"cluster_permissions":[],"index_permissions":[{"index_patterns":["*"],"allowed_actions":["read"]}]}' || rc=1
    put_obj "role write_role"      "/_plugins/_security/api/roles/write_role" \
        '{"cluster_permissions":[],"index_permissions":[{"index_patterns":["*"],"allowed_actions":["read","index","create","update"]}]}' || rc=1
    put_obj "user ${READ_USER}"    "/_plugins/_security/api/internalusers/${READ_USER}" \
        "{\"password\":\"${READ_USER_PASSWORD}\",\"backend_roles\":[\"read_only_role\"]}" || rc=1
    put_obj "user ${WRITE_USER}"   "/_plugins/_security/api/internalusers/${WRITE_USER}" \
        "{\"password\":\"${WRITE_USER_PASSWORD}\",\"backend_roles\":[\"write_role\"]}" || rc=1
    put_obj "mapping read_only_role -> ${READ_USER}" "/_plugins/_security/api/rolesmapping/read_only_role" \
        "{\"users\":[\"${READ_USER}\"]}" || rc=1
    put_obj "mapping write_role -> ${WRITE_USER}"    "/_plugins/_security/api/rolesmapping/write_role" \
        "{\"users\":[\"${WRITE_USER}\"]}" || rc=1
    return $rc
}

EXPECTED_NODES="${#NODE_IPS_ARR[@]}"
API_UP=0
CLUSTER_READY=0
if [ "$HEALTH_WAIT_SECS" -gt 0 ]; then
    log "Waiting up to ${HEALTH_WAIT_SECS}s for OpenSearch to become healthy (expecting ${EXPECTED_NODES} node(s)) ..."
    elapsed=0
    while [ "$elapsed" -lt "$HEALTH_WAIT_SECS" ]; do
        H=$(os_curl "/_cluster/health")
        if echo "$H" | grep -Eq '"status":"(green|yellow)"'; then
            API_UP=1
            N=$(echo "$H" | grep -oE '"number_of_nodes":[0-9]+' | cut -d: -f2)
            if [ "${N:-0}" -ge "$EXPECTED_NODES" ]; then CLUSTER_READY=1; break; fi
        fi
        sleep 5; elapsed=$((elapsed+5))
    done
    if [ "$CLUSTER_READY" -eq 1 ]; then
        ok "OpenSearch is up: ${EXPECTED_NODES}/${EXPECTED_NODES} node(s) joined."
    elif [ "$API_UP" -eq 1 ]; then
        warn "This node is up but the cluster is not complete yet (expected ${EXPECTED_NODES} nodes). Normal if the other nodes are not installed yet."
    elif [ "$MODE" = "standalone" ]; then
        die "OpenSearch did not become healthy in time. Check ${OS_LOGS}/${CLUSTER_NAME}.log and 'journalctl -u opensearch'."
    else
        warn "This node did not answer on https://${THIS_NODE_IP}:${HTTP_PORT} in time. It may be waiting for the other nodes / a cluster-manager. Check ${OS_LOGS}/${CLUSTER_NAME}.log"
    fi
    if [ "$API_UP" -eq 1 ]; then
        ensure_security_objects || warn "Some security objects could not be confirmed; see warnings above."
    else
        warn "Skipped the security API check (node not reachable). The users/roles are in the security config and are created when the security index is first initialised."
    fi
else
    log "HEALTH_WAIT_SECS=0 — skipping health wait and security API check."
fi

#================================================================
# 12. Credentials file + summary
#================================================================
cat > "$CRED_FILE" <<EOF
=====================================================================
 OpenSearch ${OS_VERSION} (${MODE}) — Connection details for ${NODE_NAME}
 Generated: $(date +'%F %T')
=====================================================================
# Lines of the form KEY=value are re-read by this script on re-runs.
Cluster name            : ${CLUSTER_NAME}
Mode                    : ${MODE}
Node name / roles       : ${NODE_NAME} / ${NODE_ROLES}
Node IP                 : ${THIS_NODE_IP}
All nodes (IP order)    : ${NODE_IPS}
All node names          : ${NODE_NAMES}
HTTP URL                : https://${THIS_NODE_IP}:${HTTP_PORT}
Transport port          : ${TRANSPORT_PORT}
Install root            : ${OS_ROOT}
Binaries / config       : ${OS_HOME} / ${OS_CONF}
Data directory          : ${OS_DATA}
Log directory           : ${OS_LOGS}
CA certificate          : ${CERT_TARGET}/root-ca.pem
OS service user         : ${SERVICE_USER}
Systemd service         : opensearch.service
JVM heap                : ${HEAP_SIZE}

ADMIN_USER=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}
KIBANASERVER_USER=kibanaserver
KIBANASERVER_PASSWORD=${KIBANASERVER_PASSWORD}
READ_USER=${READ_USER}
READ_USER_PASSWORD=${READ_USER_PASSWORD}
WRITE_USER=${WRITE_USER}
WRITE_USER_PASSWORD=${WRITE_USER_PASSWORD}

Roles: read_only_role (read on *) -> ${READ_USER};  write_role (read, index, create, update on *) -> ${WRITE_USER}

Test:
  curl --cacert ${CERT_TARGET}/root-ca.pem -u admin:'<password>' https://${THIS_NODE_IP}:${HTTP_PORT}
  curl --cacert ${CERT_TARGET}/root-ca.pem -u admin:'<password>' 'https://${THIS_NODE_IP}:${HTTP_PORT}/_cat/nodes?v'
  curl --cacert ${CERT_TARGET}/root-ca.pem -u ${READ_USER}:'<password>' 'https://${THIS_NODE_IP}:${HTTP_PORT}/_cat/indices?v'

Re-apply security config changes (after editing opensearch-security/*.yml):
  OPENSEARCH_JAVA_HOME=${OS_HOME}/jdk ${OS_HOME}/plugins/opensearch-security/tools/securityadmin.sh \\
    -cd ${OS_CONF}/opensearch-security -icl -nhnv \\
    -cacert ${CERT_TARGET}/root-ca.pem -cert ${CERT_TARGET}/admin.pem -key ${CERT_TARGET}/admin-key.pem \\
    -h ${THIS_NODE_IP} -p ${TRANSPORT_PORT}

Firewall: open ${HTTP_PORT}/tcp to clients and ${TRANSPORT_PORT}/tcp between cluster nodes.
=====================================================================
EOF
chmod 600 "$CRED_FILE"
chown "$SERVICE_USER":"$SERVICE_USER" "$CRED_FILE"

print_banner "OPENSEARCH ${MODE^^} INSTALLATION COMPLETE (${NODE_NAME})"
cat "$CRED_FILE"
echo
echo "(Also saved to: $CRED_FILE — readable only by root/${SERVICE_USER})"
if [ "$MODE" = "cluster" ] && [ -d "$BUNDLE_DIR" ]; then
    echo "Per-node bundles (contain all passwords + node keys): ${BUNDLE_DIR}  — delete them once copied."
    echo "Next: run this script on each remaining node with the same NODE_IPS / NODE_NAMES and its own THIS_NODE_IP."
fi
echo "Full install log: $LOG_FILE"
