#!/usr/bin/env bash
#================================================================
# DESCRIPTION
#   Unified Apache Druid installer. ONE script, TWO modes:
#
#     standalone : single server, all services on one box
#                  (Druid's micro-quickstart layout, bundled ZooKeeper,
#                   Derby or PostgreSQL metadata, local/S3/Azure storage)
#     cluster    : 3-node cluster with an EXTERNAL ZooKeeper ensemble
#                  (see install_zookeeper.sh) and SHARED PostgreSQL.
#                  Run the same script on each node with a different role:
#                      master -> Coordinator + Overlord
#                      data   -> Historical + MiddleManager (+ peons)
#                      query  -> Broker + Router
#
#   Basic authentication (druid-basic-security) is enabled in both modes.
#   JVM heap / direct-memory sizes are asked as prompts (or passed as env
#   vars); processing buffers are derived from the direct memory you give,
#   so a smaller box never ends up with an impossible JVM configuration.
#
# USAGE   (save this file to disk first - do not pipe it into bash)
#   bash install_druid.sh                           # fully interactive
#   bash install_druid.sh standalone                # or --mode=standalone
#   bash install_druid.sh cluster master            # or --mode=cluster --role=master
#   bash install_druid.sh --reconfigure             # re-prompt (old answers become defaults)
#
#   Non-interactive example (any value below skips its prompt):
#     INSTALL_MODE=cluster NODE_ROLE=data DISK_NAME=/data \
#     ZK_HOSTS="10.0.0.11,10.0.0.12,10.0.0.13" NODE_IP=10.0.0.22 \
#     META_DB_HOST=10.0.0.5 META_DB_PASS='...' STORAGE_TYPE=s3 S3_BUCKET=my-bucket \
#     ADMIN_INIT_PASSWORD='same-on-all-nodes' INTERNAL_CLIENT_PASSWORD='same-on-all-nodes' \
#     HEAP_HIST=2g DIRECT_HIST=2g HEAP_MM=256m HEAP_PEON=1g DIRECT_PEON=512m \
#     bash install_druid.sh
#
#   Memory env vars (all optional, sizes like 512m / 4g):
#     HEAP_COORD                       Coordinator+Overlord heap
#     HEAP_BROKER   DIRECT_BROKER      Broker heap / direct memory
#     HEAP_HIST     DIRECT_HIST        Historical heap / direct memory
#     HEAP_MM                          MiddleManager heap
#     HEAP_PEON     DIRECT_PEON        per-task (peon) heap / direct memory
#     HEAP_ROUTER   DIRECT_ROUTER      Router heap / direct memory
#     WORKER_CAPACITY                  peon slots per MiddleManager (default 2 standalone / 3 cluster)
#     SEGMENT_CACHE_MAX_SIZE           Historical segment cache (default 50g)
#
#   Other env vars: DRUID_VERSION, DRUID_SERVICE_USER, APP_DIRNAME
#   (default db/druid), EXTRA_EXTENSIONS (comma separated), ZK_CLIENT_PORT,
#   SKIP_CHECKSUM=yes (skip tarball SHA-512 verification),
#   DRUID_DOWNLOAD_URL (use ONLY this URL for the tarball, e.g. an internal
#   mirror or S3 pre-signed URL; skips the default mirror list).
#
# DOWNLOAD
#   The tarball is fetched from, in order:
#     1. https://dlcdn.apache.org/druid/<ver>/        (Apache CDN - fast, current releases only)
#     2. https://archive.apache.org/dist/druid/<ver>/ (all releases - often slow)
#   The first source that responds is used; an interrupted download is
#   resumed (wget -c) from the .part file. If you place the finished
#   apache-druid-<ver>-bin.tar.gz in <install_root>/softwares/ beforehand
#   (e.g. copied with scp from another node) the download is skipped.
#   The SHA-512 is always taken from Apache's official sites
#   (downloads.apache.org, then archive.apache.org), never from a mirror.
#
# CLUSTER - VALUES THAT MUST BE IDENTICAL ON ALL 3 NODES
#   ZK_HOSTS, the PostgreSQL metadata store, deep storage, and BOTH
#   passwords (ADMIN_INIT_PASSWORD / INTERNAL_CLIENT_PASSWORD). Start the
#   master node first - it bootstraps the metadata tables and auth store.
#
# AUTH NOTE
#   The initial admin / internal-client passwords only SEED the metadata
#   store on first start. Changing them later (e.g. via --reconfigure)
#   does NOT change the stored credentials - rotate them through the
#   Coordinator's basic-security API, or the escalator will get 401s.
#
# IDEMPOTENCY
#   Answers are cached per mode/role in /etc/druid-install/state-*.env
#   (mode 600) and re-used on re-runs. A healthy, already-running service
#   is left untouched. --reconfigure forces fresh prompts (previous
#   answers are offered as defaults) and re-applies all configuration.
#
# UPGRADES
#   Bump DRUID_VERSION and re-run. The service is stopped, lib/ and
#   extensions/ are wiped before the new binaries are copied (no mixed
#   jars), and configuration is re-applied.
#   Java: Druid 36 supports 17 and 21. Upstream plans to drop 17 in a
#   later release - when bumping beyond 36, re-check JAVA_CANDIDATES.
#
# IMPLEMENTATION
#   Author  - EverestDx
#   Version - v9 (unified standalone + cluster, heap prompts, hardening,
#                 fast mirror download with fallback + resume)
#     Config is applied by patching Druid's SHIPPED templates
#     (runtime.properties / jvm.config) with a literal-safe upsert, so
#     passwords containing | & \ etc. cannot corrupt a config line.
#     Backslashes are additionally escaped for Java .properties parsing.
#================================================================

set -Eeuo pipefail

#----------------------------------------------------------------
# 0. CONSTANTS / DEFAULTS
#----------------------------------------------------------------
DRUID_VERSION="${DRUID_VERSION:-36.0.0}"
DRUID_TARBALL="apache-druid-${DRUID_VERSION}-bin.tar.gz"

# Tarball sources, tried in order (dlcdn = fast CDN, archive = permanent but slow).
# DRUID_DOWNLOAD_URL (env) overrides the whole list.
DRUID_MIRROR_URLS=(
    "https://dlcdn.apache.org/druid/${DRUID_VERSION}/${DRUID_TARBALL}"
    "https://archive.apache.org/dist/druid/${DRUID_VERSION}/${DRUID_TARBALL}"
)
# Checksums come from Apache's official hosts only (not from a mirror).
DRUID_CHECKSUM_URLS=(
    "https://downloads.apache.org/druid/${DRUID_VERSION}/${DRUID_TARBALL}.sha512"
    "https://archive.apache.org/dist/druid/${DRUID_VERSION}/${DRUID_TARBALL}.sha512"
)
DRUID_DOWNLOAD_URL="${DRUID_DOWNLOAD_URL:-}"

ZK_CLIENT_PORT="${ZK_CLIENT_PORT:-2181}"
APP_DIRNAME="${APP_DIRNAME:-db/druid}"
JAVA_ALIAS_DIRNAME="${JAVA_ALIAS_DIRNAME:-apps/java}"
JAVA_CANDIDATES=(17 21)      # Druid 36 supports Java 17 and 21 (17 preferred)
SKIP_CHECKSUM="${SKIP_CHECKSUM:-no}"
STATE_DIR="/etc/druid-install"
RAM_WARN_PCT=80              # warn when JVM memory exceeds this % of RAM (leave room for page cache)

# Everything that gets cached in the state file.
STATE_VARS=(
    INSTALL_MODE NODE_ROLE BASE_PATH DRUID_SERVICE_USER
    ZK_HOSTS_RAW NODE_IP ZK_SASL_ENABLED ZK_SASL_USERNAME ZK_SASL_PASSWORD
    METADATA_TYPE META_DB_HOST META_DB_PORT META_DB_NAME META_DB_USER META_DB_PASS META_DB_URI
    STORAGE_TYPE S3_BUCKET S3_BASE_KEY AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER AZURE_STORAGE_KEY
    ADMIN_INIT_PASSWORD INTERNAL_CLIENT_PASSWORD
    HEAP_COORD HEAP_BROKER DIRECT_BROKER HEAP_HIST DIRECT_HIST
    HEAP_MM HEAP_PEON DIRECT_PEON HEAP_ROUTER DIRECT_ROUTER
    WORKER_CAPACITY SEGMENT_CACHE_MAX_SIZE EXTRA_EXTENSIONS INSTALLED_DRUID_VERSION
)

FORCE_RECONFIGURE="no"
STATE_EXISTS="no"
NEED_INSTALL="yes"
APT_UPDATED="no"
ACCESS_LOG=""
ERROR_LOG=""
HAS_COORD=0; HAS_BROKER=0; HAS_HIST=0; HAS_MM=0; HAS_ROUTER=0
ZK_CONN=""
declare -A PREV=()

#----------------------------------------------------------------
# 1. LOGGING / SMALL HELPERS
#----------------------------------------------------------------
log()  { local m; m="[$(date '+%F %T')] [INFO] $*"
         echo "$m"
         if [ -n "$ACCESS_LOG" ]; then echo "$m" >> "$ACCESS_LOG"; fi; }
warn() { local m; m="[$(date '+%F %T')] [WARN] $*"
         echo "$m" >&2
         if [ -n "$ERROR_LOG" ]; then echo "$m" >> "$ERROR_LOG"; fi; }
err()  { local m; m="[$(date '+%F %T')] [ERROR] $*"
         echo "$m" >&2
         if [ -n "$ERROR_LOG" ]; then echo "$m" >> "$ERROR_LOG"; fi; }
die()  { err "$*"; exit 1; }

# Run a command with stdout/stderr appended to the install logs.
run_logged() { "$@" >> "${ACCESS_LOG:-/dev/null}" 2>> "${ERROR_LOG:-/dev/null}"; }

usage() { sed -n '2,/^#====/p' "$0" | sed 's/^# \{0,1\}//' | head -n 100; }

# "512m" / "4g" -> MiB
to_mb() {
    local v="${1,,}"
    case "$v" in
        *g) echo $(( ${v%g} * 1024 )) ;;
        *m) echo $(( ${v%m} )) ;;
        *)  echo 0 ;;
    esac
}
valid_size() { [[ "${1,,}" =~ ^[1-9][0-9]*[mg]$ ]]; }

# Literal-safe "replace the line starting with PREFIX, or append LINE".
# Values travel through the environment, so | & \ and friends are safe.
upsert_line() {
    local file="$1" prefix="$2" line="$3" tmp
    [ -f "$file" ] || die "Expected Druid config file not found: $file"
    tmp="$(mktemp)"
    P="$prefix" L="$line" awk '
        BEGIN { p = ENVIRON["P"]; l = ENVIRON["L"]; n = length(p) }
        substr($0, 1, n) == p { if (!done) { print l; done = 1 } ; next }
        { print }
        END { if (!done) print l }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}
set_cfg()      { upsert_line "$3" "$1=" "$1=$2"; }   # key value file
set_jvm_opt()  { upsert_line "$1" "$2" "$3"; }        # file prefix full-line

# Java .properties treats "\" as an escape character -> double it.
prop_escape() { local s="$1"; printf '%s' "${s//\\/\\\\}"; }

# Reject secrets that cannot be stored safely on one config line.
check_secret() {   # name value
    if [[ "$2" == *$'\n'* || "$2" == *$'\r'* ]]; then
        die "$1 must not contain line breaks."
    fi
}

gen_password() { openssl rand -base64 12 2>/dev/null || date +%s%N | sha256sum | head -c16; }

apt_update_once() {
    export DEBIAN_FRONTEND=noninteractive
    if [ "$APT_UPDATED" == "no" ]; then
        log "Refreshing apt package lists..."
        run_logged apt-get update -y
        APT_UPDATED="yes"
    fi
}

#----------------------------------------------------------------
# 2. ARGUMENTS / ROOT / MODE
#----------------------------------------------------------------
parse_args() {
    INSTALL_MODE="${INSTALL_MODE:-}"
    NODE_ROLE="${NODE_ROLE:-}"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --reconfigure)      FORCE_RECONFIGURE="yes" ;;
            --mode=*)           INSTALL_MODE="${arg#--mode=}" ;;
            --role=*)           NODE_ROLE="${arg#--role=}" ;;
            standalone|cluster) INSTALL_MODE="$arg" ;;
            master|data|query)  NODE_ROLE="$arg" ;;
            -h|--help)          usage; exit 0 ;;
            *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
        esac
    done
}

elevate_if_needed() {
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "This script needs root and 'sudo' is not installed. Re-run as root." >&2
            exit 1
        fi
        if [ ! -f "$0" ]; then
            echo "Cannot re-run via sudo because the script is not a regular file (piped / process substitution)." >&2
            echo "Save it to disk (e.g. install_druid.sh) and run it again: bash install_druid.sh" >&2
            exit 1
        fi
        echo "Not running as root - re-executing with sudo (env vars are preserved with -E)..."
        exec sudo -E -H bash "$0" "$@"
    fi
}

init_vars() {
    local v
    for v in "${STATE_VARS[@]}"; do printf -v "$v" '%s' "${!v:-}"; done
}

resolve_mode() {
    local ans="" r
    if [ -z "$INSTALL_MODE" ]; then
        [ -t 0 ] || die "INSTALL_MODE not set (standalone|cluster) and there is no interactive terminal."
        echo ""
        echo "Select install mode:"
        echo "  1) standalone - single server, everything on this box"
        echo "  2) cluster    - one node of a 3-node cluster (external ZooKeeper + shared PostgreSQL)"
        read -rp "Enter 1/2 or standalone/cluster: " ans
        INSTALL_MODE="$ans"
    fi
    case "${INSTALL_MODE,,}" in
        1|standalone) INSTALL_MODE="standalone" ;;
        2|cluster)    INSTALL_MODE="cluster" ;;
        *) die "Invalid mode '${INSTALL_MODE}' (use standalone or cluster)." ;;
    esac

    if [ "$INSTALL_MODE" == "cluster" ]; then
        if [ -z "$NODE_ROLE" ]; then
            [ -t 0 ] || die "NODE_ROLE not set (master|data|query) and there is no interactive terminal."
            echo ""
            echo "Which role is this node?"
            echo "  1) master - Coordinator + Overlord"
            echo "  2) data   - Historical + MiddleManager"
            echo "  3) query  - Broker + Router"
            read -rp "Enter 1/2/3 or master/data/query: " r
            NODE_ROLE="$r"
        fi
        case "${NODE_ROLE,,}" in
            1|master) NODE_ROLE="master" ;;
            2|data)   NODE_ROLE="data" ;;
            3|query)  NODE_ROLE="query" ;;
            *) die "NODE_ROLE must be master, data or query (got '${NODE_ROLE}')." ;;
        esac
    else
        NODE_ROLE=""
    fi
}

# Which services run here, how the systemd unit is called, etc.
set_mode_vars() {
    HAS_COORD=0; HAS_BROKER=0; HAS_HIST=0; HAS_MM=0; HAS_ROUTER=0
    if [ "$INSTALL_MODE" == "standalone" ]; then
        SERVICE_NAME="druid"
        EXEC_BIN="start-micro-quickstart"
        HEALTH_PORT=8888
        CONF_SUBDIR="single-server/micro-quickstart"
        FIREWALL_PORTS=(8081 8082 8083 8088 8090 8091 8888)
        HAS_COORD=1; HAS_BROKER=1; HAS_HIST=1; HAS_MM=1; HAS_ROUTER=1
    else
        CONF_SUBDIR="cluster"
        case "$NODE_ROLE" in
            master)
                SERVICE_NAME="druid-master"; EXEC_BIN="start-cluster-master-no-zk-server"; HEALTH_PORT=8081
                FIREWALL_PORTS=(8081 8090); HAS_COORD=1 ;;
            data)
                SERVICE_NAME="druid-data"; EXEC_BIN="start-cluster-data-server"; HEALTH_PORT=8083
                FIREWALL_PORTS=(8083 8091 8100 8101 8102 8103 8104 8105); HAS_HIST=1; HAS_MM=1 ;;
            query)
                SERVICE_NAME="druid-query"; EXEC_BIN="start-cluster-query-server"; HEALTH_PORT=8888
                FIREWALL_PORTS=(8082 8888); HAS_BROKER=1; HAS_ROUTER=1 ;;
        esac
    fi
}

apply_defaults() {
    if [ "$INSTALL_MODE" == "standalone" ]; then
        : "${DRUID_SERVICE_USER:=edxiuser}"
        : "${WORKER_CAPACITY:=2}"
    else
        : "${DRUID_SERVICE_USER:=vantagex}"
        : "${WORKER_CAPACITY:=3}"
    fi
    : "${SEGMENT_CACHE_MAX_SIZE:=50g}"
    [[ "$WORKER_CAPACITY" =~ ^[1-9][0-9]*$ ]] || die "WORKER_CAPACITY must be a positive integer (got '$WORKER_CAPACITY')."
    valid_size "$SEGMENT_CACHE_MAX_SIZE" || die "SEGMENT_CACHE_MAX_SIZE must look like 50g or 500m (got '$SEGMENT_CACHE_MAX_SIZE')."
}

#----------------------------------------------------------------
# 3. STATE FILE (idempotency)
#----------------------------------------------------------------
load_state() {
    STATE_EXISTS="no"
    [ -f "$STATE_FILE" ] || return 0
    if [ "$FORCE_RECONFIGURE" == "yes" ]; then
        log "--reconfigure passed - re-prompting. Previous answers from $STATE_FILE are offered as defaults."
        local snippet v
        snippet="$( set +eu; . "$STATE_FILE" >/dev/null 2>&1
                    for v in "${STATE_VARS[@]}"; do printf 'PREV[%s]=%q\n' "$v" "${!v-}"; done )" || snippet=""
        eval "$snippet"
        return 0
    fi
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    STATE_EXISTS="yes"
    log "Loaded saved configuration from $STATE_FILE (not re-prompting). Pass --reconfigure to change it."
}

persist_state() {
    local v
    INSTALLED_DRUID_VERSION="$DRUID_VERSION"
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    (
        umask 077
        {
            echo "# Auto-generated by install_druid.sh - DO NOT EDIT BY HAND."
            echo "# Re-used on later runs. Delete this file or use --reconfigure to change answers."
            for v in "${STATE_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v:-}"; done
        } > "$STATE_FILE"
    )
    chmod 600 "$STATE_FILE"
    log "Saved configuration to $STATE_FILE (mode 600)"
}

#----------------------------------------------------------------
# 4. PROMPTS
#----------------------------------------------------------------
# ask VAR "prompt" "default" [secret]
#   * non-empty env var  -> prompt skipped
#   * no terminal        -> default used
ask() {
    local var="$1" prompt="$2" def="${3:-}" secret="${4:-no}" input="" cur
    cur="${!var:-}"
    if [ -n "$cur" ]; then
        log "${prompt}: using value provided via environment"
        return 0
    fi
    def="${PREV[$var]:-$def}"
    if [ ! -t 0 ]; then printf -v "$var" '%s' "$def"; return 0; fi
    if [ "$secret" == "yes" ]; then
        read -rsp "${prompt} [${def:+default set, }Enter to accept]: " input; echo ""
    else
        read -rp "${prompt} [default: ${def:-none, Enter to skip}]: " input
    fi
    printf -v "$var" '%s' "${input:-$def}"
}

# ask_size VAR "label" "default"   (validates 512m / 4g style values)
ask_size() {
    local var="$1" label="$2" def="$3" cur val
    cur="${!var:-}"
    if [ -z "$cur" ]; then
        def="${PREV[$var]:-$def}"
        val="$def"
        if [ -t 0 ]; then
            while true; do
                read -rp "${label} [default: ${def}]: " val
                val="${val:-$def}"
                if valid_size "$val"; then break; fi
                echo "  Invalid size '${val}'. Use a number followed by m or g, e.g. 512m or 4g."
            done
        fi
        cur="$val"
    fi
    valid_size "$cur" || die "Invalid size for ${var}: '${cur}' (use e.g. 512m or 4g)."
    printf -v "$var" '%s' "${cur,,}"
}

prompt_volume() {
    local raw="${DISK_NAME:-}" from_env="no" trimmed msg
    if [ -n "$raw" ]; then from_env="yes"; fi
    while true; do
        if [ -z "$raw" ]; then
            [ -t 0 ] || die "DISK_NAME not set and there is no interactive terminal."
            echo ""
            read -rp "Install location: a bare volume name (nested under /opt, e.g. 'ausiytic'), a full path (e.g. '/data'), or 'root' for /opt on the root volume: " raw
        fi
        if [ -z "$raw" ]; then echo "Input cannot be empty."; continue; fi

        trimmed="${raw%/}"
        if [ -z "$trimmed" ] || [ "$trimmed" == "root" ] || [ "$trimmed" == "/opt" ]; then
            BASE_PATH="/opt"
            mkdir -p "$BASE_PATH"
            warn "Using the root volume (BASE_PATH=/opt). A dedicated data volume is preferred for production."
            return 0
        fi
        if [[ "$trimmed" == /* ]]; then
            BASE_PATH="$trimmed"
        else
            BASE_PATH="/opt/${trimmed#opt/}"
        fi
        if [ -d "$BASE_PATH" ]; then
            log "Using BASE_PATH=$BASE_PATH"
            return 0
        fi
        msg="Path '$BASE_PATH' does not exist. Create/mount it first (or enter 'root')."
        if [ "$from_env" == "yes" ]; then die "$msg"; fi
        echo "$msg"
        raw=""
    done
}

build_zk_conn() {
    local h arr=()
    IFS=',' read -ra arr <<< "$ZK_HOSTS_RAW"
    ZK_CONN=""
    for h in "${arr[@]}"; do
        h="$(echo "$h" | xargs)"
        if [[ "$h" != *:* ]]; then h="${h}:${ZK_CLIENT_PORT}"; fi
        ZK_CONN="${ZK_CONN}${h},"
    done
    ZK_CONN="${ZK_CONN%,}"
}

prompt_zk() {
    local h hp pp arr=()
    if [ -z "$ZK_HOSTS_RAW" ]; then ZK_HOSTS_RAW="${ZK_HOSTS:-}"; fi
    if [ -z "$ZK_HOSTS_RAW" ]; then
        [ -t 0 ] || die "ZK_HOSTS not set and there is no interactive terminal."
        echo ""
        echo "Enter the ZooKeeper ENSEMBLE host list (same list/order on all nodes), comma-separated."
        echo "Example: 10.0.0.11,10.0.0.12,10.0.0.13"
        read -rp "ZooKeeper hosts [default: ${PREV[ZK_HOSTS_RAW]:-none}]: " ZK_HOSTS_RAW
        ZK_HOSTS_RAW="${ZK_HOSTS_RAW:-${PREV[ZK_HOSTS_RAW]:-}}"
    fi
    [ -n "$ZK_HOSTS_RAW" ] || die "A ZooKeeper ensemble host list is required in cluster mode."
    build_zk_conn
    log "ZooKeeper ensemble: ${ZK_CONN}"

    IFS=',' read -ra arr <<< "$ZK_CONN"
    for h in "${arr[@]}"; do
        hp="${h%%:*}"; pp="${h##*:}"
        if ! timeout 3 bash -c "cat < /dev/null > /dev/tcp/${hp}/${pp}" 2>/dev/null; then
            warn "Could not reach ZooKeeper ${hp}:${pp} right now. Continuing, but the node will not come up until it is reachable."
        fi
    done
}

prompt_node_ip() {
    local detected
    detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    ask NODE_IP "IP/hostname other nodes use to reach THIS node" "${detected:-127.0.0.1}"
    log "This node's advertised address: ${NODE_IP}"
}

prompt_zk_sasl() {
    local a=""
    if [ -z "$ZK_SASL_ENABLED" ]; then
        if [ -t 0 ]; then
            read -rp "Does the ZooKeeper ensemble require SASL/JAAS client auth? (y/N): " a
        fi
        case "${a:-n}" in y|Y|yes|YES) ZK_SASL_ENABLED="yes" ;; *) ZK_SASL_ENABLED="no" ;; esac
    fi
    if [ "$ZK_SASL_ENABLED" == "yes" ]; then
        ask ZK_SASL_USERNAME "ZooKeeper client SASL username" "druid"
        ask ZK_SASL_PASSWORD "ZooKeeper client SASL password" "" yes
        [ -n "$ZK_SASL_PASSWORD" ] || die "ZK SASL was enabled but no password was given."
        if [[ "$ZK_SASL_PASSWORD" == *\"* || "$ZK_SASL_PASSWORD" == *\\* || "$ZK_SASL_USERNAME" == *\"* || "$ZK_SASL_USERNAME" == *\\* ]]; then
            die "ZooKeeper SASL username/password must not contain double quotes or backslashes (JAAS file limitation)."
        fi
        check_secret ZK_SASL_PASSWORD "$ZK_SASL_PASSWORD"
    fi
}

prompt_metadata() {
    echo ""
    echo "=== Metadata store ==="
    if [ "$INSTALL_MODE" == "cluster" ]; then
        echo "Cluster mode needs ONE shared PostgreSQL reachable from all 3 nodes."
    else
        echo "Press Enter on the host to use the built-in Derby store (fine for standalone/testing)."
    fi
    ask META_DB_HOST "PostgreSQL host/IP" ""
    if [ -n "$META_DB_HOST" ]; then
        METADATA_TYPE="postgresql"
        ask META_DB_PORT "PostgreSQL port" "5432"
        ask META_DB_NAME "PostgreSQL database name" "druid"
        ask META_DB_USER "PostgreSQL username" "druid"
        ask META_DB_PASS "PostgreSQL password" "" yes
        check_secret META_DB_PASS "$META_DB_PASS"
        META_DB_URI="jdbc:postgresql://${META_DB_HOST}:${META_DB_PORT}/${META_DB_NAME}"
        log "Metadata store: PostgreSQL @ ${META_DB_HOST}:${META_DB_PORT}/${META_DB_NAME}"
    else
        [ "$INSTALL_MODE" == "standalone" ] || die "Cluster mode requires a shared PostgreSQL metadata store (Derby is single-node only)."
        METADATA_TYPE="derby"
        log "Metadata store: Derby (embedded, local)"
    fi
}

prompt_storage() {
    local def choice=""
    echo ""
    echo "=== Deep storage ==="
    if [ -z "$STORAGE_TYPE" ]; then
        if [ "$INSTALL_MODE" == "cluster" ]; then
            echo "Must be shared/remote storage reachable from all nodes."
            def=1
        else
            def=3
        fi
        case "${PREV[STORAGE_TYPE]:-}" in s3) def=1 ;; azure) def=2 ;; local) def=3 ;; esac
        if [ -t 0 ]; then
            echo "1) s3     2) azure     3) local disk$( [ "$INSTALL_MODE" == cluster ] && echo ' (only valid on a shared/NFS mount!)')"
            read -rp "Choose deep storage [1/2/3, default ${def}]: " choice
        fi
        case "${choice:-$def}" in
            1|s3)    STORAGE_TYPE="s3" ;;
            2|azure) STORAGE_TYPE="azure" ;;
            3|local) STORAGE_TYPE="local" ;;
            *) die "Invalid deep storage choice." ;;
        esac
    fi
    case "$STORAGE_TYPE" in
        s3)
            ask S3_BUCKET "S3 bucket name" ""
            ask S3_BASE_KEY "S3 base key/prefix" "druid/segments"
            [ -n "$S3_BUCKET" ] || die "S3 bucket is required for s3 deep storage."
            log "Deep storage: S3 bucket=${S3_BUCKET} prefix=${S3_BASE_KEY} (uses instance role / AWS env credentials)" ;;
        azure)
            ask AZURE_STORAGE_ACCOUNT "Azure storage account" ""
            ask AZURE_STORAGE_CONTAINER "Azure storage container" "druid"
            ask AZURE_STORAGE_KEY "Azure storage key" "" yes
            [ -n "$AZURE_STORAGE_ACCOUNT" ] || die "Azure storage account is required for azure deep storage."
            check_secret AZURE_STORAGE_KEY "$AZURE_STORAGE_KEY"
            log "Deep storage: Azure Blob account=${AZURE_STORAGE_ACCOUNT} container=${AZURE_STORAGE_CONTAINER}" ;;
        local)
            if [ "$INSTALL_MODE" == "cluster" ]; then
                warn "Local deep storage in a cluster only works if this path is the SAME shared/NFS mount on all nodes."
            else
                log "Deep storage: local disk"
            fi ;;
        *) die "Invalid STORAGE_TYPE '${STORAGE_TYPE}' (use s3, azure or local)." ;;
    esac
}

prompt_security() {
    echo ""
    echo "=== Security (basic auth) ==="
    if [ "$INSTALL_MODE" == "cluster" ]; then
        warn "These two passwords MUST be identical on all 3 nodes. Pass them as ADMIN_INIT_PASSWORD / INTERNAL_CLIENT_PASSWORD env vars, or type the same value on every node."
        if [ ! -t 0 ] && { [ -z "$ADMIN_INIT_PASSWORD" ] || [ -z "$INTERNAL_CLIENT_PASSWORD" ]; }; then
            die "Non-interactive cluster install needs ADMIN_INIT_PASSWORD and INTERNAL_CLIENT_PASSWORD set (they must match on every node)."
        fi
    else
        echo "Press Enter to auto-generate random passwords (stored in the state file)."
    fi
    ask ADMIN_INIT_PASSWORD "Druid console admin password" "$(gen_password)" yes
    ask INTERNAL_CLIENT_PASSWORD "Druid internal client password" "$(gen_password)" yes
    [ -n "$ADMIN_INIT_PASSWORD" ] && [ -n "$INTERNAL_CLIENT_PASSWORD" ] || die "Passwords cannot be empty."
    check_secret ADMIN_INIT_PASSWORD "$ADMIN_INIT_PASSWORD"
    check_secret INTERNAL_CLIENT_PASSWORD "$INTERNAL_CLIENT_PASSWORD"
}

# --- JVM memory ----------------------------------------------------
prompt_heap() {
    local ram cores
    local D_COORD D_BROKER_H D_BROKER_D D_HIST_H D_HIST_D D_MM D_PEON_H D_PEON_D D_ROUTER_H D_ROUTER_D
    ram="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
    cores="$(nproc 2>/dev/null || echo 1)"

    # Lean defaults: standalone fits ~8 GB RAM, a cluster node fits ~16 GB.
    if [ "$INSTALL_MODE" == "standalone" ]; then
        D_COORD=256m; D_BROKER_H=512m; D_BROKER_D=512m; D_HIST_H=1g;   D_HIST_D=1g
        D_MM=128m;    D_PEON_H=512m;   D_PEON_D=512m;   D_ROUTER_H=256m; D_ROUTER_D=128m
    else
        D_COORD=1g;   D_BROKER_H=1g;   D_BROKER_D=1g;   D_HIST_H=2g;   D_HIST_D=2g
        D_MM=256m;    D_PEON_H=1g;     D_PEON_D=512m;   D_ROUTER_H=256m; D_ROUTER_D=128m
    fi

    echo ""
    echo "=== JVM memory sizing ==="
    echo "This node has ${ram} MiB RAM and ${cores} CPU core(s). Enter sizes like 512m or 4g;"
    echo "press Enter to accept a default. Heap is used for both -Xms and -Xmx."
    echo "Direct memory feeds the processing buffers (derived automatically)."
    echo "Leave free RAM beyond these sizes: Historicals read segments through the OS page cache."
    if [ "$HAS_COORD" -eq 1 ]; then
        ask_size HEAP_COORD    "Coordinator+Overlord heap" "$D_COORD"
    fi
    if [ "$HAS_BROKER" -eq 1 ]; then
        ask_size HEAP_BROKER   "Broker heap" "$D_BROKER_H"
        ask_size DIRECT_BROKER "Broker direct memory" "$D_BROKER_D"
    fi
    if [ "$HAS_HIST" -eq 1 ]; then
        ask_size HEAP_HIST     "Historical heap" "$D_HIST_H"
        ask_size DIRECT_HIST   "Historical direct memory" "$D_HIST_D"
    fi
    if [ "$HAS_MM" -eq 1 ]; then
        ask_size HEAP_MM       "MiddleManager heap" "$D_MM"
        ask_size HEAP_PEON     "Per-task (peon) heap   [x${WORKER_CAPACITY} task slots]" "$D_PEON_H"
        ask_size DIRECT_PEON   "Per-task (peon) direct memory" "$D_PEON_D"
    fi
    if [ "$HAS_ROUTER" -eq 1 ]; then
        ask_size HEAP_ROUTER   "Router heap" "$D_ROUTER_H"
        ask_size DIRECT_ROUTER "Router direct memory" "$D_ROUTER_D"
    fi
    memory_check
}

# Sanity-check the requested sizes against this machine's RAM.
memory_check() {
    local ram total=0 ans=""
    ram="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
    if [ "$HAS_COORD"  -eq 1 ]; then total=$(( total + $(to_mb "$HEAP_COORD") )); fi
    if [ "$HAS_BROKER" -eq 1 ]; then total=$(( total + $(to_mb "$HEAP_BROKER") + $(to_mb "$DIRECT_BROKER") )); fi
    if [ "$HAS_HIST"   -eq 1 ]; then total=$(( total + $(to_mb "$HEAP_HIST") + $(to_mb "$DIRECT_HIST") )); fi
    if [ "$HAS_ROUTER" -eq 1 ]; then total=$(( total + $(to_mb "$HEAP_ROUTER") + $(to_mb "$DIRECT_ROUTER") )); fi
    if [ "$HAS_MM" -eq 1 ]; then
        total=$(( total + $(to_mb "$HEAP_MM") + WORKER_CAPACITY * ( $(to_mb "$HEAP_PEON") + $(to_mb "$DIRECT_PEON") ) ))
    fi
    if [ "$INSTALL_MODE" == "standalone" ]; then total=$(( total + 256 )); fi   # bundled ZooKeeper
    total=$(( total * 105 / 100 ))                                              # JVM overhead
    log "Estimated JVM memory for this node: ${total} MiB of ${ram} MiB RAM (task slots counted at capacity ${WORKER_CAPACITY})"
    if [ "$total" -gt $(( ram * RAM_WARN_PCT / 100 )) ]; then
        warn "Requested sizes use more than ${RAM_WARN_PCT}% of this node's RAM - little is left for the OS page cache and the OS may OOM-kill Druid processes."
        if [ -t 0 ]; then
            read -rp "Continue anyway? [y/N]: " ans
            case "${ans:-n}" in
                y|Y|yes|YES) ;;
                *) die "Aborted. Re-run with smaller heap/direct sizes (or lower WORKER_CAPACITY)." ;;
            esac
        fi
    fi
}

prompt_all() {
    if [ "$INSTALL_MODE" == "cluster" ]; then
        prompt_zk
        prompt_node_ip
        prompt_zk_sasl
    fi
    prompt_metadata
    prompt_storage
    prompt_security
    prompt_heap
    log "Configuration collected."
}

#----------------------------------------------------------------
# 5. PATHS / LOGGING
#----------------------------------------------------------------
compute_paths() {
    INSTALL_ROOT="${BASE_PATH}/${APP_DIRNAME}"
    JAVA_ALIAS="${BASE_PATH}/${JAVA_ALIAS_DIRNAME}"
    SOURCE="${INSTALL_ROOT}/softwares"
    DRUID_BINARIES="${INSTALL_ROOT}/binaries"
    DRUID_DATA="${INSTALL_ROOT}/data"
    DRUID_LOG_DIR="${INSTALL_ROOT}/logs"
    LOG_DIR="${INSTALL_ROOT}/logs/install"
    CONF_ROOT="${DRUID_BINARIES}/conf/druid/${CONF_SUBDIR}"
    JAAS_FILE="${DRUID_BINARIES}/conf/zk/client_jaas.conf"
}

setup_logging() {
    compute_paths
    mkdir -p "$LOG_DIR"
    ACCESS_LOG="${LOG_DIR}/druid_install.access.log"
    ERROR_LOG="${LOG_DIR}/druid_install.error.log"
    touch "$ACCESS_LOG" "$ERROR_LOG"
    log "===== Druid install: mode=${INSTALL_MODE}${NODE_ROLE:+ role=${NODE_ROLE}} install_root=${INSTALL_ROOT} ====="
}

setup_paths() {
    local d
    for d in "$SOURCE" "$DRUID_BINARIES" "$DRUID_DATA" "$DRUID_LOG_DIR" "$(dirname "$JAVA_ALIAS")"; do
        mkdir -p "$d"
    done
}

#----------------------------------------------------------------
# 6. OS / JAVA / SERVICE USER
#----------------------------------------------------------------
detect_os() {
    local id like ver
    [ -f /etc/os-release ] || die "Cannot detect OS - /etc/os-release not found."
    id="$(. /etc/os-release; echo "${ID:-}")"
    like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
    ver="$(. /etc/os-release; echo "${VERSION_ID:-unknown}")"
    case "$id" in
        ubuntu|debian) PKG_FAMILY="debian" ;;
        rhel|centos|rocky|almalinux|amzn|fedora) PKG_FAMILY="rhel" ;;
        *)
            if   [[ "$like" == *debian* ]]; then PKG_FAMILY="debian"
            elif [[ "$like" == *rhel* || "$like" == *fedora* ]]; then PKG_FAMILY="rhel"
            else die "Unsupported OS: ${id}"; fi ;;
    esac
    if [ "$PKG_FAMILY" == "rhel" ]; then
        if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
    fi
    log "Detected OS family: ${PKG_FAMILY} (${id} ${ver})"
}

ensure_base_tools() {
    local t missing=0
    for t in wget tar curl perl sha512sum; do
        if ! command -v "$t" >/dev/null 2>&1; then missing=1; fi
    done
    # bin/supervise needs perl's FindBin (absent on minimal RHEL 10 images)
    if ! perl -MFindBin -e1 >/dev/null 2>&1; then missing=1; fi
    if [ "$missing" -eq 0 ]; then return 0; fi

    log "Installing base tools (wget tar curl perl coreutils)..."
    if [ "$PKG_FAMILY" == "debian" ]; then
        apt_update_once
        run_logged apt-get install -y wget tar curl perl coreutils
    else
        run_logged "$PKG_MGR" install -y wget tar curl perl perl-FindBin coreutils
    fi
}

java_major() { "$1" -version 2>&1 | head -n1 | grep -oP '"\K[0-9]+' || true; }

# Echo the home of a Java in JAVA_CANDIDATES (default java first, then /usr/lib/jvm/*).
find_compatible_java_home() {
    local v j d m
    if command -v java >/dev/null 2>&1; then
        j="$(readlink -f "$(command -v java)")"
        m="$(java_major "$j")"
        for v in "${JAVA_CANDIDATES[@]}"; do
            if [ "$m" == "$v" ]; then echo "${j%/bin/java}"; return 0; fi
        done
    fi
    for v in "${JAVA_CANDIDATES[@]}"; do
        for d in /usr/lib/jvm/*; do
            if [ -x "$d/bin/java" ] && [ "$(java_major "$d/bin/java")" == "$v" ]; then
                readlink -f "$d"; return 0
            fi
        done
    done
    return 1
}

install_java_debian() {
    local v
    apt_update_once
    for v in "${JAVA_CANDIDATES[@]}"; do
        if apt-cache show "openjdk-${v}-jdk" >/dev/null 2>&1; then
            log "Installing openjdk-${v}-jdk"
            run_logged apt-get install -y "openjdk-${v}-jdk"
            return 0
        fi
    done
    die "None of the supported Java versions (${JAVA_CANDIDATES[*]}) are available via apt."
}

install_java_rhel() {
    local v pkg
    for v in "${JAVA_CANDIDATES[@]}"; do
        pkg="java-${v}-openjdk"
        if "$PKG_MGR" list --available "$pkg" >/dev/null 2>&1; then
            log "Installing native ${pkg}"
            run_logged "$PKG_MGR" install -y "$pkg" "${pkg}-devel"
            return 0
        fi
    done
    warn "No native java-{${JAVA_CANDIDATES[*]}}-openjdk package - falling back to Eclipse Temurin."
    run_logged rpm --import https://packages.adoptium.net/artifactory/api/gpg/key/public
    cat > /etc/yum.repos.d/adoptium.repo <<'EOF'
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/rhel/$releasever/$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF
    for v in "${JAVA_CANDIDATES[@]}"; do
        if run_logged "$PKG_MGR" install -y "temurin-${v}-jdk"; then
            log "Installed Temurin ${v} JDK"
            return 0
        fi
        warn "temurin-${v}-jdk not available for this OS release, trying next candidate"
    done
    die "Could not install any supported Java version (${JAVA_CANDIDATES[*]})."
}

install_java() {
    if JAVA_HOME_DETECTED="$(find_compatible_java_home)"; then
        log "Compatible Java found: ${JAVA_HOME_DETECTED} (major $(java_major "${JAVA_HOME_DETECTED}/bin/java"))"
    else
        if [ "$PKG_FAMILY" == "debian" ]; then install_java_debian; else install_java_rhel; fi
        JAVA_HOME_DETECTED="$(find_compatible_java_home)" || die "Java installed but no supported version (${JAVA_CANDIDATES[*]}) was found."
        log "Java installed: ${JAVA_HOME_DETECTED}"
    fi
    ln -sfn "$JAVA_HOME_DETECTED" "$JAVA_ALIAS"
    log "JAVA_HOME alias: ${JAVA_ALIAS} -> ${JAVA_HOME_DETECTED}"
}

create_service_user() {
    if id "$DRUID_SERVICE_USER" >/dev/null 2>&1; then
        log "Service user $DRUID_SERVICE_USER already exists"
    else
        useradd -r -m -s /sbin/nologin "$DRUID_SERVICE_USER" 2>/dev/null \
            || useradd -r -m -s /usr/sbin/nologin "$DRUID_SERVICE_USER"
        log "Created service user $DRUID_SERVICE_USER"
    fi
}

#----------------------------------------------------------------
# 7. EXTENSIONS / DOWNLOAD / PRUNE
#----------------------------------------------------------------
build_required_extensions() {
    local e x seen
    local extra=()
    if [ "$INSTALL_MODE" == "standalone" ]; then
        REQUIRED_EXTENSIONS=(druid-basic-security druid-datasketches druid-kafka-indexing-service druid-parquet-extensions druid-hdfs-storage)
    else
        case "$NODE_ROLE" in
            data) REQUIRED_EXTENSIONS=(druid-basic-security druid-datasketches druid-kafka-indexing-service druid-parquet-extensions druid-hdfs-storage) ;;
            *)    REQUIRED_EXTENSIONS=(druid-basic-security druid-datasketches) ;;
        esac
    fi
    if [ "$STORAGE_TYPE" == "s3" ];         then REQUIRED_EXTENSIONS+=(druid-s3-extensions); fi
    if [ "$STORAGE_TYPE" == "azure" ];      then REQUIRED_EXTENSIONS+=(druid-azure-extensions); fi
    if [ "$METADATA_TYPE" == "postgresql" ]; then REQUIRED_EXTENSIONS+=(postgresql-metadata-storage); fi
    if [ -n "$EXTRA_EXTENSIONS" ]; then
        IFS=',' read -ra extra <<< "$EXTRA_EXTENSIONS"
        for e in "${extra[@]}"; do
            e="$(echo "$e" | xargs)"
            if [ -n "$e" ]; then REQUIRED_EXTENSIONS+=("$e"); fi
        done
    fi
    # de-duplicate, keep order
    local uniq=()
    for e in "${REQUIRED_EXTENSIONS[@]}"; do
        seen=0
        for x in "${uniq[@]:-}"; do if [ "$x" == "$e" ]; then seen=1; fi; done
        if [ "$seen" -eq 0 ]; then uniq+=("$e"); fi
    done
    REQUIRED_EXTENSIONS=("${uniq[@]}")
    LOAD_LIST_JSON="[$(printf '"%s",' "${REQUIRED_EXTENSIONS[@]}" | sed 's/,$//')]"
    log "Extensions to load: ${REQUIRED_EXTENSIONS[*]}"
}

# Best-effort SHA-512 verification of the downloaded tarball.
# The expected hash is fetched from Apache's official hosts (never a mirror).
verify_checksum() {
    local sumfile="${DRUID_TARBALL}.sha512" expected="" actual url
    if [ "$SKIP_CHECKSUM" == "yes" ]; then
        warn "SKIP_CHECKSUM=yes - tarball checksum NOT verified."
        return 0
    fi
    for url in "${DRUID_CHECKSUM_URLS[@]}"; do
        if wget -q --timeout=20 --tries=2 "$url" -O "$sumfile"; then
            expected="$(tr -d ' \t\r\n' < "$sumfile" | grep -oiE '[0-9a-f]{128}' | head -n1 || true)"
            rm -f "$sumfile"
            if [ -n "$expected" ]; then
                log "Fetched SHA-512 from ${url}"
                break
            fi
            warn "Could not parse a SHA-512 from ${url}"
        else
            rm -f "$sumfile"
            warn "Could not fetch ${url}"
        fi
    done
    if [ -z "$expected" ]; then
        warn "No published SHA-512 could be obtained - skipping checksum verification."
        return 0
    fi
    actual="$(sha512sum "$DRUID_TARBALL" | awk '{print $1}')"
    if [ "${expected,,}" != "${actual,,}" ]; then
        rm -f "$DRUID_TARBALL"
        die "SHA-512 mismatch for ${DRUID_TARBALL} (corrupt or tampered download). Removed it - re-run to download again."
    fi
    log "Tarball SHA-512 verified"
}

# Download the tarball into the current directory (SOURCE).
# Tries each source in order; a source that does not have the file (e.g. dlcdn
# after a newer release) or fails is skipped. An interrupted download is
# resumed from the .part file on the next source / next run.
download_tarball() {
    local part="${DRUID_TARBALL}.part" url ok=0
    local urls=()
    if [ -n "$DRUID_DOWNLOAD_URL" ]; then
        urls=("$DRUID_DOWNLOAD_URL")
    else
        urls=("${DRUID_MIRROR_URLS[@]}")
    fi

    for url in "${urls[@]}"; do
        if ! wget -q --spider --timeout=15 --tries=2 "$url" 2>/dev/null; then
            warn "Source not available, skipping: ${url}"
            continue
        fi
        log "Downloading Druid ${DRUID_VERSION} from ${url} (resumes if interrupted)"
        if wget -q --show-progress -c --tries=5 --timeout=30 --read-timeout=30 -O "$part" "$url"; then
            ok=1
            break
        fi
        warn "Download from ${url} failed - trying next source (partial file kept for resume)."
    done

    if [ "$ok" -ne 1 ]; then
        die "Download failed from all sources: ${urls[*]}. Re-run to resume, or place ${DRUID_TARBALL} in ${SOURCE} manually (e.g. scp from another node)."
    fi
    mv -f "$part" "$DRUID_TARBALL"
}

download_and_install_druid() {
    cd "$SOURCE"
    if [ -f "$DRUID_TARBALL" ]; then
        log "Tarball already present in ${SOURCE}, skipping download"
    else
        download_tarball
    fi
    verify_checksum

    log "Extracting..."
    rm -rf "apache-druid-${DRUID_VERSION}"
    tar -xzf "$DRUID_TARBALL" || die "Extraction failed"

    # Stop a running instance before swapping binaries.
    if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        log "Stopping ${SERVICE_NAME}.service before replacing binaries"
        systemctl stop "${SERVICE_NAME}.service"
    fi

    # Wipe jars so an upgrade never leaves a mix of old and new libraries.
    log "Copying binaries to $DRUID_BINARIES (clean lib/ and extensions/)"
    rm -rf "${DRUID_BINARIES}/lib" "${DRUID_BINARIES}/extensions"
    cp -rf "apache-druid-${DRUID_VERSION}"/* "$DRUID_BINARIES"/

    if [ -x "${DRUID_BINARIES}/bin/verify-java" ]; then
        JAVA_HOME="$JAVA_HOME_DETECTED" "${DRUID_BINARIES}/bin/verify-java" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || die "bin/verify-java reported an incompatible Java version (see $ERROR_LOG)."
    fi
}

# Druid scans every directory under extensions/ at startup regardless of
# loadList (slow, CPU heavy), so physically remove what we don't use.
prune_extensions() {
    local ext_dir="${DRUID_BINARIES}/extensions" dir name req keep removed=0
    if [ ! -d "$ext_dir" ]; then warn "Extensions dir not found, skipping prune"; return 0; fi
    for dir in "$ext_dir"/*/; do
        name="$(basename "$dir")"; keep="no"
        for req in "${REQUIRED_EXTENSIONS[@]}"; do
            if [ "$name" == "$req" ]; then keep="yes"; break; fi
        done
        if [ "$keep" == "no" ]; then rm -rf "$dir"; removed=$((removed + 1)); fi
    done
    log "Pruned ${removed} unused extension directories"
}

#----------------------------------------------------------------
# 8. CONFIGURATION (patches Druid's shipped templates)
#----------------------------------------------------------------
svc_conf_dir() {   # coordinator-overlord | broker | historical | middleManager | router
    if [ "$INSTALL_MODE" == "standalone" ]; then echo "${CONF_ROOT}/$1"; else echo "${CONF_ROOT}/${NODE_ROLE}/$1"; fi
}

write_common_config() {
    local COMMON="${CONF_ROOT}/_common/common.runtime.properties"
    [ -f "$COMMON" ] || die "Expected shipped template not found: $COMMON"
    log "Writing common.runtime.properties"

    if [ "$INSTALL_MODE" == "cluster" ]; then
        set_cfg druid.zk.service.host "$ZK_CONN" "$COMMON"
        set_cfg druid.zk.paths.base "/druid" "$COMMON"
        set_cfg druid.host "$NODE_IP" "$COMMON"
    fi
    set_cfg druid.extensions.loadList "$LOAD_LIST_JSON" "$COMMON"

    if [ "$METADATA_TYPE" == "postgresql" ]; then
        set_cfg druid.metadata.storage.type "postgresql" "$COMMON"
        set_cfg druid.metadata.storage.connector.connectURI "$META_DB_URI" "$COMMON"
        set_cfg druid.metadata.storage.connector.user "$META_DB_USER" "$COMMON"
        set_cfg druid.metadata.storage.connector.password "$(prop_escape "$META_DB_PASS")" "$COMMON"
    else
        set_cfg druid.metadata.storage.type "derby" "$COMMON"
        set_cfg druid.metadata.storage.connector.connectURI "jdbc:derby://localhost:1527/${DRUID_DATA}/metadata.db;create=true" "$COMMON"
        set_cfg druid.metadata.storage.connector.host "localhost" "$COMMON"
        set_cfg druid.metadata.storage.connector.port "1527" "$COMMON"
    fi

    case "$STORAGE_TYPE" in
        s3)
            set_cfg druid.storage.type "s3" "$COMMON"
            set_cfg druid.storage.bucket "$S3_BUCKET" "$COMMON"
            set_cfg druid.storage.baseKey "$S3_BASE_KEY" "$COMMON"
            set_cfg druid.indexer.logs.type "s3" "$COMMON"
            set_cfg druid.indexer.logs.s3Bucket "$S3_BUCKET" "$COMMON"
            set_cfg druid.indexer.logs.s3Prefix "indexing-logs" "$COMMON" ;;
        azure)
            set_cfg druid.storage.type "azure" "$COMMON"
            set_cfg druid.azure.account "$AZURE_STORAGE_ACCOUNT" "$COMMON"
            set_cfg druid.azure.container "$AZURE_STORAGE_CONTAINER" "$COMMON"
            set_cfg druid.azure.key "$(prop_escape "$AZURE_STORAGE_KEY")" "$COMMON"
            set_cfg druid.indexer.logs.type "azure" "$COMMON"
            set_cfg druid.indexer.logs.container "$AZURE_STORAGE_CONTAINER" "$COMMON"
            set_cfg druid.indexer.logs.prefix "indexlogs" "$COMMON" ;;
        local)
            mkdir -p "${DRUID_DATA}/segments" "${DRUID_DATA}/indexing-logs"
            set_cfg druid.storage.type "local" "$COMMON"
            set_cfg druid.storage.storageDirectory "${DRUID_DATA}/segments" "$COMMON"
            set_cfg druid.indexer.logs.type "file" "$COMMON"
            set_cfg druid.indexer.logs.directory "${DRUID_DATA}/indexing-logs" "$COMMON" ;;
    esac

    # --- basic authentication (same block on every node) ---
    local A="druid.auth.authenticator.MyBasicMetadataAuthenticator"
    set_cfg druid.auth.authenticatorChain '["MyBasicMetadataAuthenticator"]' "$COMMON"
    set_cfg "${A}.type" "basic" "$COMMON"
    set_cfg "${A}.initialAdminPassword" "$(prop_escape "$ADMIN_INIT_PASSWORD")" "$COMMON"
    set_cfg "${A}.initialInternalClientPassword" "$(prop_escape "$INTERNAL_CLIENT_PASSWORD")" "$COMMON"
    set_cfg "${A}.credentialsValidator.type" "metadata" "$COMMON"
    set_cfg "${A}.skipOnFailure" "false" "$COMMON"
    set_cfg "${A}.authorizerName" "MyBasicMetadataAuthorizer" "$COMMON"
    set_cfg druid.escalator.type "basic" "$COMMON"
    set_cfg druid.escalator.internalClientUsername "druid_system" "$COMMON"
    set_cfg druid.escalator.internalClientPassword "$(prop_escape "$INTERNAL_CLIENT_PASSWORD")" "$COMMON"
    set_cfg druid.escalator.authorizerName "MyBasicMetadataAuthorizer" "$COMMON"
    set_cfg druid.auth.authorizers '["MyBasicMetadataAuthorizer"]' "$COMMON"
    set_cfg druid.auth.authorizer.MyBasicMetadataAuthorizer.type "basic" "$COMMON"

    set_cfg druid.server.hiddenProperties '["druid.s3.accessKey","druid.s3.secretKey","druid.metadata.storage.connector.password","druid.azure.key","password","key","token","pwd"]' "$COMMON"

    if ! grep -qF "druid.extensions.loadList=${LOAD_LIST_JSON}" "$COMMON"; then
        die "Verification failed: loadList in $COMMON does not match the expected value."
    fi
    log "Verified common.runtime.properties"
}

# apply_jvm <service-dir-name> <heap> [direct]
apply_jvm() {
    local f; f="$(svc_conf_dir "$1")/jvm.config"
    set_jvm_opt "$f" "-Xms" "-Xms$2"
    set_jvm_opt "$f" "-Xmx" "-Xmx$2"
    if [ -n "${3:-}" ]; then set_jvm_opt "$f" "-XX:MaxDirectMemorySize=" "-XX:MaxDirectMemorySize=$3"; fi
    log "  $1: heap=$2${3:+ direct=$3}"
}

# derive_processing <name> <direct> <threads> <merge-buffers> <max-buffer-MiB>
# -> sets P_BUF (MiB), P_THREADS, P_MERGE so that
#    (threads + merge + 1) * buffer fits inside the direct memory (10% headroom).
derive_processing() {
    local name="$1" direct="$2" threads="$3" merge="$4" cap="$5" dmb b
    dmb="$(to_mb "$direct")"
    b=$(( dmb * 90 / 100 / (threads + merge + 1) ))
    if [ "$b" -lt 16 ]; then
        warn "${name}: ${direct} direct memory is small for ${threads} threads + ${merge} merge buffers - reducing to 1 thread / 2 merge buffers."
        threads=1; merge=2
        b=$(( dmb * 90 / 100 / (threads + merge + 1) ))
        if [ "$b" -lt 16 ]; then
            die "${name}: direct memory ${direct} is too small for Druid processing buffers. Increase it (>= 128m recommended)."
        fi
    fi
    if [ "$b" -gt "$cap" ]; then b="$cap"; fi
    P_BUF="$b"; P_THREADS="$threads"; P_MERGE="$merge"
}

set_processing() {   # file [prefix]
    local f="$1" p="${2:-druid.processing}"
    set_cfg "${p}.buffer.sizeBytes" "${P_BUF}MiB" "$f"
    set_cfg "${p}.numMergeBuffers" "$P_MERGE" "$f"
    set_cfg "${p}.numThreads" "$P_THREADS" "$f"
    log "    processing: buffer=${P_BUF}MiB threads=${P_THREADS} mergeBuffers=${P_MERGE}"
}

default_peon_opts() {   # heap direct
    printf '["-server","-Xms%s","-Xmx%s","-XX:MaxDirectMemorySize=%s","-Duser.timezone=UTC","-Dfile.encoding=UTF-8","-XX:+ExitOnOutOfMemoryError","-Djava.util.logging.manager=org.apache.logging.log4j.jul.LogManager","--add-exports=java.base/jdk.internal.ref=ALL-UNNAMED","--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED","--add-opens=java.base/java.lang=ALL-UNNAMED","--add-opens=java.base/java.io=ALL-UNNAMED","--add-opens=java.base/java.nio=ALL-UNNAMED","--add-opens=java.base/jdk.internal.ref=ALL-UNNAMED","--add-opens=java.base/sun.nio.ch=ALL-UNNAMED"]' "$1" "$1" "$2"
}

# Patch only the memory flags inside the shipped javaOptsArray (keeps its other flags).
patch_peon_java_opts() {   # file heap direct
    local f="$1" h="$2" d="$3" line
    sed -i -E "/^druid\.indexer\.runner\.javaOptsArray=/{s/-Xms[0-9]+[mMgG]/-Xms${h}/;s/-Xmx[0-9]+[mMgG]/-Xmx${h}/;s/-XX:MaxDirectMemorySize=[0-9]+[mMgG]/-XX:MaxDirectMemorySize=${d}/}" "$f"
    line="$(grep -E '^druid\.indexer\.runner\.javaOptsArray=' "$f" || true)"
    if [[ "$line" != *"-Xms${h}"* || "$line" != *"-Xmx${h}"* || "$line" != *"-XX:MaxDirectMemorySize=${d}"* ]]; then
        warn "Shipped javaOptsArray not in the expected format - writing a complete one."
        set_cfg druid.indexer.runner.javaOptsArray "$(default_peon_opts "$h" "$d")" "$f"
    fi
    if [ "$ZK_SASL_ENABLED" == "yes" ]; then
        sed -i -E "/^druid\.indexer\.runner\.javaOptsArray=/ s|\"-server\"|\"-server\",\"-Djava.security.auth.login.config=${JAAS_FILE}\"|" "$f"
    fi
}

apply_memory_config() {
    local cores f max_hist_threads proc_merge ht
    cores="$(nproc 2>/dev/null || echo 1)"
    if [ "$INSTALL_MODE" == "standalone" ]; then max_hist_threads=4;  proc_merge=2
    else                                         max_hist_threads=15; proc_merge=4; fi
    ht=$(( cores - 1 ))
    if [ "$ht" -lt 1 ]; then ht=1; fi
    if [ "$ht" -gt "$max_hist_threads" ]; then ht="$max_hist_threads"; fi

    log "Applying JVM memory configuration"
    if [ "$HAS_COORD" -eq 1 ]; then
        apply_jvm coordinator-overlord "$HEAP_COORD"
    fi
    if [ "$HAS_BROKER" -eq 1 ]; then
        apply_jvm broker "$HEAP_BROKER" "$DIRECT_BROKER"
        derive_processing broker "$DIRECT_BROKER" 1 "$proc_merge" 500
        set_processing "$(svc_conf_dir broker)/runtime.properties"
    fi
    if [ "$HAS_HIST" -eq 1 ]; then
        f="$(svc_conf_dir historical)/runtime.properties"
        mkdir -p "${DRUID_DATA}/segment-cache"
        apply_jvm historical "$HEAP_HIST" "$DIRECT_HIST"
        derive_processing historical "$DIRECT_HIST" "$ht" "$proc_merge" 500
        set_processing "$f"
        set_cfg druid.segmentCache.locations "[{\"path\":\"${DRUID_DATA}/segment-cache\",\"maxSize\":\"${SEGMENT_CACHE_MAX_SIZE}\"}]" "$f"
        set_cfg druid.server.maxSize "$SEGMENT_CACHE_MAX_SIZE" "$f"
    fi
    if [ "$HAS_MM" -eq 1 ]; then
        f="$(svc_conf_dir middleManager)/runtime.properties"
        mkdir -p "${DRUID_DATA}/task" "${DRUID_DATA}/hadoop-tmp"
        apply_jvm middleManager "$HEAP_MM"
        set_cfg druid.worker.capacity "$WORKER_CAPACITY" "$f"
        set_cfg druid.worker.baseTaskDirs "[\"${DRUID_DATA}/task\"]" "$f"
        set_cfg druid.indexer.task.hadoopWorkingPath "${DRUID_DATA}/hadoop-tmp" "$f"
        set_cfg druid.export.storage.baseDir "$DRUID_BINARIES" "$f"
        derive_processing peon "$DIRECT_PEON" 1 2 100
        set_processing "$f" "druid.indexer.fork.property.druid.processing"
        patch_peon_java_opts "$f" "$HEAP_PEON" "$DIRECT_PEON"
        log "  peon: heap=${HEAP_PEON} direct=${DIRECT_PEON} x${WORKER_CAPACITY} slots"
    fi
    if [ "$HAS_ROUTER" -eq 1 ]; then
        apply_jvm router "$HEAP_ROUTER" "$DIRECT_ROUTER"
    fi
}

write_zk_jaas() {
    if [ "$INSTALL_MODE" != "cluster" ] || [ "$ZK_SASL_ENABLED" != "yes" ]; then return 0; fi
    local f svc
    mkdir -p "$(dirname "$JAAS_FILE")"
    ( umask 077
      cat > "$JAAS_FILE" <<EOF
Client {
    org.apache.zookeeper.server.auth.DigestLoginModule required
    username="${ZK_SASL_USERNAME}"
    password="${ZK_SASL_PASSWORD}";
};
EOF
    )
    chmod 640 "$JAAS_FILE"
    for svc in coordinator-overlord broker historical middleManager router; do
        f="$(svc_conf_dir "$svc")/jvm.config"
        if [ -f "$f" ]; then set_jvm_opt "$f" "-Djava.security.auth.login.config=" "-Djava.security.auth.login.config=${JAAS_FILE}"; fi
    done
    log "Wrote ZooKeeper client JAAS config ($JAAS_FILE) and referenced it from the service jvm.config files"
}

# Config files contain DB / admin / escalator passwords: owner (service user) only.
secure_permissions() {
    chown -R "${DRUID_SERVICE_USER}:${DRUID_SERVICE_USER}" "$INSTALL_ROOT"
    if [ -d "${DRUID_BINARIES}/conf" ]; then
        chmod -R o-rwx "${DRUID_BINARIES}/conf"
        log "Restricted ${DRUID_BINARIES}/conf to the service user/group (no world access)"
    fi
}

#----------------------------------------------------------------
# 9. SYSTEMD / FIREWALL / START
#----------------------------------------------------------------
create_systemd_service() {
    local unit="/etc/systemd/system/${SERVICE_NAME}.service" skip=""
    if [ "$INSTALL_MODE" == "cluster" ]; then skip="Environment=DRUID_SKIP_PORT_CHECK=1"; fi
    log "Creating systemd unit ${unit}"
    cat > "$unit" <<EOF
[Unit]
Description=Apache Druid (${INSTALL_MODE}${NODE_ROLE:+ - ${NODE_ROLE}})
After=network.target

[Service]
Type=simple
User=${DRUID_SERVICE_USER}
WorkingDirectory=${DRUID_BINARIES}
Environment=DRUID_LOG_DIR=${DRUID_LOG_DIR}
Environment=JAVA_HOME=${JAVA_ALIAS}
${skip}
ExecStart=${DRUID_BINARIES}/bin/${EXEC_BIN}
Restart=on-failure
RestartSec=10
TimeoutStopSec=90
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    run_logged systemctl enable "${SERVICE_NAME}.service"
}

open_firewall_ports() {
    local p
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in "${FIREWALL_PORTS[@]}"; do run_logged ufw allow "${p}/tcp" || true; done
        log "Opened ports ${FIREWALL_PORTS[*]} via ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        for p in "${FIREWALL_PORTS[@]}"; do run_logged firewall-cmd --permanent --add-port="${p}/tcp" || true; done
        run_logged firewall-cmd --reload || true
        log "Opened ports ${FIREWALL_PORTS[*]} via firewalld"
    else
        log "No active ufw/firewalld - open ${FIREWALL_PORTS[*]}/tcp in your firewall/security group if needed."
    fi
}

start_and_verify() {
    local url="http://localhost:${HEALTH_PORT}/status/health" i code ok=0
    code="$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [ "$NEED_INSTALL" == "no" ] && systemctl is-active --quiet "${SERVICE_NAME}.service" && [ "$code" == "200" ]; then
        log "${SERVICE_NAME}.service is already active and healthy - no restart needed"
    else
        log "Starting ${SERVICE_NAME}.service"
        systemctl restart "${SERVICE_NAME}.service"
        log "Waiting for ${url} (up to ~5 min)..."
        for ((i = 1; i <= 30; i++)); do
            code="$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
            if [ "$code" == "200" ]; then ok=1; break; fi
            sleep 10
        done
        if [ "$ok" -ne 1 ]; then
            systemctl status "${SERVICE_NAME}.service" --no-pager >> "$ERROR_LOG" 2>&1 || true
            die "${SERVICE_NAME} did not become healthy in time. Check: journalctl -u ${SERVICE_NAME} -f   (log: $ERROR_LOG)"
        fi
    fi
    systemctl is-active --quiet "${SERVICE_NAME}.service" || die "${SERVICE_NAME}.service is not active after startup."
    log "${SERVICE_NAME}.service is active and enabled: $(systemctl is-enabled "${SERVICE_NAME}.service")"
}

print_summary() {
    local ip="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}' || true)}"
    echo ""
    echo "================================================================"
    echo " Druid ${DRUID_VERSION} - ${INSTALL_MODE}${NODE_ROLE:+ / ${NODE_ROLE}} node configured"
    echo " Install root : ${INSTALL_ROOT}"
    echo " Service      : ${SERVICE_NAME}.service  (user: ${DRUID_SERVICE_USER})"
    if [ "$INSTALL_MODE" == "cluster" ]; then echo " ZooKeeper    : ${ZK_CONN}"; fi
    case "${NODE_ROLE:-standalone}" in
        standalone) echo " Console      : http://${ip}:8888" ;;
        master)     echo " Coordinator  : http://${ip}:8081" ;;
        data)       echo " Historical   : ${ip}:8083   MiddleManager: ${ip}:8091" ;;
        query)      echo " Console      : http://${ip}:8888   Broker: ${ip}:8082" ;;
    esac
    echo " Login        : user 'admin' / the admin password (see ${STATE_FILE}, root only)"
    if [ "$INSTALL_MODE" == "cluster" ]; then
        echo ""
        echo " Next: run this SAME script on the other nodes with their own role, the"
        echo " SAME ZK_HOSTS / metadata store / deep storage / passwords. Start master first."
    fi
    echo " To change heap sizes later: re-run with --reconfigure"
    echo "================================================================"
    echo "Access log: $ACCESS_LOG"
    echo "Error log : $ERROR_LOG"
}

#----------------------------------------------------------------
# MAIN
#----------------------------------------------------------------
main() {
    trap 'rc=$?; err "Script aborted at line $LINENO (exit code $rc)"; exit $rc' ERR

    parse_args "$@"
    elevate_if_needed "$@"
    init_vars
    resolve_mode
    set_mode_vars
    STATE_FILE="${STATE_DIR}/state-${INSTALL_MODE}${NODE_ROLE:+-${NODE_ROLE}}.env"
    load_state
    apply_defaults

    if [ "$STATE_EXISTS" == "no" ]; then
        prompt_volume
        setup_logging
        prompt_all
    else
        setup_logging
        log "Re-using saved configuration (volume ${BASE_PATH}, metadata/storage/credentials/memory) - not re-prompting."
        if [ "$INSTALL_MODE" == "cluster" ]; then build_zk_conn; fi
    fi

    detect_os
    ensure_base_tools
    setup_paths
    install_java
    create_service_user
    build_required_extensions

    NEED_INSTALL="yes"
    if [ "$STATE_EXISTS" == "yes" ] \
        && [ "$INSTALLED_DRUID_VERSION" == "$DRUID_VERSION" ] \
        && [ -d "$CONF_ROOT" ]; then
        NEED_INSTALL="no"
        log "Druid ${DRUID_VERSION} already installed at ${DRUID_BINARIES} - skipping download/configuration. Use --reconfigure to re-apply, or bump DRUID_VERSION to upgrade."
    fi

    if [ "$NEED_INSTALL" == "yes" ]; then
        download_and_install_druid
        prune_extensions
        write_common_config
        apply_memory_config
        write_zk_jaas
    fi
    secure_permissions

    create_systemd_service
    open_firewall_ports
    persist_state
    start_and_verify
    print_summary
}

if [ "${BASH_SOURCE[0]}" == "$0" ]; then
    main "$@"
fi

