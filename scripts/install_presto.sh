#!/bin/bash
#================================================================
# DESCRIPTION
#   Fully automated installer for Presto (PrestoDB, the
#   com.facebook.presto distribution) as a single-node
#   coordinator + worker, wired up as a systemd service.
#   Automates the manual runbook: directories, download, etc/
#   configuration (config.properties, jvm.config, log.properties,
#   node.properties, optional password-authenticator.properties),
#   the hive + jmx catalogs and the presto.service unit.
#
#   Version installed:
#       presto : 0.294   (override: PRESTO_VERSION=0.29x)
#       NOTE: 0.294 is the last line that runs on Java 8.
#             Presto 0.295 and newer REQUIRE Java 17 (see section 5).
#
#   Default HTTP port: 8585  (8080 is rejected on purpose: it is
#   used by Spark master / NiFi / other services on the same hosts)
#
#   Compatible with:
#       RHEL / CentOS / Rocky / AlmaLinux / Fedora / Amazon Linux (yum/dnf)
#       Debian / Ubuntu (apt-get)
#
#   Handles automatically:
#       - Root vs sudo (or dzdo) execution
#       - Java 8 detection/installation (Presto 0.294 needs Java 8).
#         JAVA_HOME is set ONLY in the systemd unit -- never globally.
#       - Python for the Presto launcher script (installs it if missing;
#         on Ubuntu 24.04 there is no 'python' command by default)
#       - Validation of heap / query-memory settings before they can
#         stop Presto from starting
#       - Validation that the HTTP port is not 8080 and is free
#       - Hive catalog -> existing Hive Metastore (thrift)
#       - The "Storage schema reading not supported" metastore error:
#         adds metastore.storage.schema.reader.impl to the local
#         hive-site.xml up front (and restarts hive.service)
#       - S3 access through the instance role by default; static keys
#         only if you pass them explicitly (never hard-code keys)
#       - Idempotent re-runs (node.id and keystore are kept stable)
#       - SELinux (Enforcing) labels on RHEL-family systems
#       - Optional presto CLI (bin/presto) for testing
#
#   Notes:
#       - A Hive Metastore must already be reachable at the URI you
#         give (default thrift://localhost:9083, i.e. the one created
#         by install_hadoop_hive.sh on the same host).
#       - Presto has no HDFS: tables must live in S3 or in a local
#         path the presto service user can read.
#       - Password authentication is OPT-IN. Presto only accepts it
#         over HTTPS, so enabling it also creates a self-signed
#         keystore and an HTTPS listener (default 8443). The plain HTTP
#         port stays open for internal use: restrict it with your
#         security group / firewall.
#       - Upgrading an existing 0.283 install: the script will NOT
#         overwrite an existing install in <BASE_DIR>/apps/presto/binaries.
#         Stop presto, move that directory aside (keep etc/ if you want
#         your old config), and re-run.
#
#   Usage:
#       chmod +x install_presto.sh
#       ./install_presto.sh               # interactive prompts
#
#   Optional non-interactive use (any of these can be pre-set):
#       BASE_DIR, SVC_USER, PRESTO_DISCOVERY_HOST, PRESTO_HTTP_PORT,
#       PRESTO_HEAP, PRESTO_QUERY_MAX_MEMORY,
#       PRESTO_QUERY_MAX_MEMORY_PER_NODE, HIVE_METASTORE_URI,
#       ENABLE_PASSWORD_AUTH, PRESTO_HTTPS_PORT, PRESTO_AUTH_USER,
#       PRESTO_AUTH_PASSWORD, PRESTO_NODE_ENV, PRESTO_S3_ACCESS_KEY,
#       PRESTO_S3_SECRET_KEY, PATCH_HIVE_SITE=y|n, HIVE_SITE_XML,
#       INSTALL_CLI=y|n, JAVA_HOME_OVERRIDE, PRESTO_VERSION,
#       PRESTO_URL (internal mirror), SKIP_DISK_CHECK=y, ASSUME_YES=y
#================================================================
# IMPLEMENTATION
#   Version  - v2  (Presto 0.294, default port 8585)
#================================================================

set -euo pipefail

# ---------------------------------------------------------------
# 0. Versions & constants
# ---------------------------------------------------------------
PRESTO_VERSION="${PRESTO_VERSION:-0.294}"
DEFAULT_HTTP_PORT="8585"
SERVICE_NAME="presto"
HIVE_SERVICE_NAME="hive"

MAVEN_BASE="${MAVEN_BASE:-https://repo1.maven.org/maven2}"
PRESTO_TARBALL="presto-server-${PRESTO_VERSION}.tar.gz"
PRESTO_URL="${PRESTO_URL:-${MAVEN_BASE}/com/facebook/presto/presto-server/${PRESTO_VERSION}/${PRESTO_TARBALL}}"
PRESTO_CLI_JAR="presto-cli-${PRESTO_VERSION}-executable.jar"
PRESTO_CLI_URL="${MAVEN_BASE}/com/facebook/presto/presto-cli/${PRESTO_VERSION}/${PRESTO_CLI_JAR}"

FILENAME=$(date +"%d%m%Y%H")
SCRIPT_PWD=$(pwd)
ACCESS_LOG="${SCRIPT_PWD}/presto_install.access.${FILENAME}.log"
ERROR_LOG="${SCRIPT_PWD}/presto_install.error.${FILENAME}.log"

log() {
    echo -e "[$(date +"%F %T")] $1" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    echo -e "[$(date +"%F %T")] $1"
}

warn() {
    echo -e "[$(date +"%F %T")] WARNING: $1" >> "$ERROR_LOG"
    echo -e "[$(date +"%F %T")] WARNING: $1" >&2
}

die() {
    echo -e "[$(date +"%F %T")] ERROR: $1" >> "$ERROR_LOG"
    echo -e "[$(date +"%F %T")] ERROR: $1" >&2
    exit 1
}

is_yes() { [[ "${1:-}" =~ ^[Yy] ]]; }

port_in_use() {   # port_in_use <port>
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Presto 0.295+ needs Java 17 (this script provisions Java 8 only).
if [[ "$PRESTO_VERSION" =~ ^0\.([0-9]+) ]] && (( BASH_REMATCH[1] >= 295 )); then
    die "Presto ${PRESTO_VERSION} requires Java 17, but this script installs Java 8 (valid up to 0.294). Use PRESTO_VERSION=0.294 or adapt section 5 and jvm.config for Java 17."
fi

# ---------------------------------------------------------------
# 1. Root / sudo detection
# ---------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
    echo "Running as root."
else
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    elif command -v dzdo >/dev/null 2>&1; then
        SUDO="dzdo"
    else
        die "Not running as root and neither 'sudo' nor 'dzdo' is available. Re-run as root."
    fi
    if [[ "$SUDO" == "sudo" ]] && ! sudo -n true 2>/dev/null; then
        echo "This script needs sudo privileges (package installs, service setup)."
        echo "You may be prompted for your password."
    fi
fi

# ---------------------------------------------------------------
# 2. Prompts (each can be pre-set via environment variable)
# ---------------------------------------------------------------
ask() {   # ask VAR "Prompt" [default]
    local __var="$1" __prompt="$2" __def="${3:-}" __in=""
    if [[ -n "${!__var:-}" ]]; then
        return 0
    fi
    if [[ -n "$__def" ]]; then
        read -rp "$__prompt [$__def]: " __in
        __in="${__in:-$__def}"
    else
        read -rp "$__prompt: " __in
    fi
    [[ -n "$__in" ]] || die "$__var cannot be empty."
    printf -v "$__var" '%s' "$__in"
}

to_mb() {   # to_mb 1G | 512M | 256MB | 2GB  -> integer MB ; fails on anything else
    local v="${1^^}" n u
    [[ "$v" =~ ^([0-9]+)(K|M|G|T)B?$ ]] || return 1
    n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
    case "$u" in
        K) echo $(( n / 1024 )) ;;
        M) echo "$n" ;;
        G) echo $(( n * 1024 )) ;;
        T) echo $(( n * 1024 * 1024 )) ;;
    esac
}

BASE_DIR="${BASE_DIR:-}"
ask BASE_DIR "Enter base install directory (e.g. /opt/ausiytic or /data)"
BASE_DIR="${BASE_DIR%/}"

case "$BASE_DIR" in
    ""|/etc|/usr|/bin|/sbin|/lib|/lib64|/var|/boot|/dev|/proc|/sys|/root|/home|/tmp)
        die "Refusing to use '${BASE_DIR:-/}' as the base directory. Use a dedicated path such as /opt/ausiytic or /data."
        ;;
esac
[[ "$BASE_DIR" == /* ]] || die "Base directory must be an absolute path."

SVC_USER="${SVC_USER:-}"
ask SVC_USER "OS user that will run the Presto service" "${SUDO_USER:-$(id -un)}"
id "$SVC_USER" >/dev/null 2>&1 || die "User '$SVC_USER' does not exist."
SVC_GROUP=$(id -gn "$SVC_USER")

DEFAULT_HOST=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
DEFAULT_HOST="${DEFAULT_HOST:-$(hostname)}"

PRESTO_DISCOVERY_HOST="${PRESTO_DISCOVERY_HOST:-}"
PRESTO_HTTP_PORT="${PRESTO_HTTP_PORT:-}"
PRESTO_HEAP="${PRESTO_HEAP:-}"
PRESTO_QUERY_MAX_MEMORY="${PRESTO_QUERY_MAX_MEMORY:-}"
HIVE_METASTORE_URI="${HIVE_METASTORE_URI:-}"
ENABLE_PASSWORD_AUTH="${ENABLE_PASSWORD_AUTH:-}"

ask PRESTO_DISCOVERY_HOST "Coordinator host/IP for discovery.uri (this node's address)" "$DEFAULT_HOST"
ask PRESTO_HTTP_PORT "Presto HTTP port (not 8080)" "$DEFAULT_HTTP_PORT"
ask PRESTO_HEAP "JVM max heap -Xmx (e.g. 1G, 4G)" "1G"
ask PRESTO_QUERY_MAX_MEMORY "query.max-memory (e.g. 256MB, 2GB)" "256MB"
PRESTO_QUERY_MAX_MEMORY_PER_NODE="${PRESTO_QUERY_MAX_MEMORY_PER_NODE:-$PRESTO_QUERY_MAX_MEMORY}"
ask HIVE_METASTORE_URI "Hive metastore thrift URI" "thrift://localhost:9083"
ask ENABLE_PASSWORD_AUTH "Enable password authentication over HTTPS? (y/n)" "n"

PRESTO_NODE_ENV="${PRESTO_NODE_ENV:-development}"
PATCH_HIVE_SITE="${PATCH_HIVE_SITE:-y}"
INSTALL_CLI="${INSTALL_CLI:-y}"

PRESTO_HTTPS_PORT="${PRESTO_HTTPS_PORT:-8443}"
PRESTO_AUTH_USER="${PRESTO_AUTH_USER:-}"
PRESTO_AUTH_PASSWORD="${PRESTO_AUTH_PASSWORD:-}"
if is_yes "$ENABLE_PASSWORD_AUTH"; then
    ask PRESTO_AUTH_USER "Presto login user" "admin"
    if [[ -z "$PRESTO_AUTH_PASSWORD" ]]; then
        read -rsp "Password for Presto user '$PRESTO_AUTH_USER' (min 8 chars): " PRESTO_AUTH_PASSWORD
        echo
    fi
    [[ "${#PRESTO_AUTH_PASSWORD}" -ge 8 ]] || die "Presto login password must be at least 8 characters."
    [[ "$PRESTO_HTTPS_PORT" =~ ^[0-9]+$ ]] || die "HTTPS port must be numeric."
    [[ "$PRESTO_HTTPS_PORT" != "$PRESTO_HTTP_PORT" ]] || die "HTTPS port and HTTP port must differ."
    [[ "$PRESTO_AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Presto login user may only contain letters, digits, . _ -"
fi

# --- validation (so a typo cannot stop Presto from starting) ---
[[ "$PRESTO_HTTP_PORT" =~ ^[0-9]+$ ]] || die "HTTP port must be numeric."
(( PRESTO_HTTP_PORT >= 1024 && PRESTO_HTTP_PORT <= 65535 )) || die "HTTP port must be between 1024 and 65535."
[[ "$PRESTO_HTTP_PORT" != "8080" ]] || die "Port 8080 is not allowed for Presto here (it clashes with Spark/NiFi/other services). Choose another, e.g. ${DEFAULT_HTTP_PORT}."
[[ "$PRESTO_DISCOVERY_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die "Coordinator host/IP '$PRESTO_DISCOVERY_HOST' is not a valid hostname or IP."
[[ "$PRESTO_NODE_ENV" =~ ^[a-z][a-z0-9_]*$ ]] || die "PRESTO_NODE_ENV must match [a-z][a-z0-9_]* (e.g. development, production)."
[[ "$HIVE_METASTORE_URI" =~ ^thrift://[^[:space:]]+$ ]] || die "Hive metastore URI must look like thrift://host:9083"

HEAP_MB=$(to_mb "$PRESTO_HEAP") || die "PRESTO_HEAP '$PRESTO_HEAP' is not valid (use a unit, e.g. 1G or 2048M)."
QMAX_MB=$(to_mb "$PRESTO_QUERY_MAX_MEMORY") || die "query.max-memory '$PRESTO_QUERY_MAX_MEMORY' is not valid (e.g. 256MB, 2GB)."
QNODE_MB=$(to_mb "$PRESTO_QUERY_MAX_MEMORY_PER_NODE") || die "query.max-memory-per-node '$PRESTO_QUERY_MAX_MEMORY_PER_NODE' is not valid (e.g. 256MB, 2GB)."
# Presto refuses to start unless query.max-memory-per-node + heap headroom (default 30%) fits in the heap.
(( QNODE_MB * 10 <= HEAP_MB * 7 )) \
    || die "query.max-memory-per-node (${PRESTO_QUERY_MAX_MEMORY_PER_NODE}) + Presto's default 30% heap headroom does not fit in -Xmx${PRESTO_HEAP}. Raise PRESTO_HEAP or lower the query memory (per-node must be <= 70% of the heap)."
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "${MEM_MB:-0}" -gt 0 ]] && (( HEAP_MB * 100 > MEM_MB * 70 )); then
    warn "-Xmx${PRESTO_HEAP} is more than 70% of this host's ${MEM_MB} MB RAM. Other services (Hive, NiFi, PostgreSQL) share it; the OS may swap or OOM-kill processes."
fi

# Fail early if another process (not our own presto.service) already holds the port(s).
if ! systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    if port_in_use "$PRESTO_HTTP_PORT"; then
        die "Port ${PRESTO_HTTP_PORT} is already in use by another process. Pick another PRESTO_HTTP_PORT or stop that process."
    fi
    if is_yes "$ENABLE_PASSWORD_AUTH" && port_in_use "$PRESTO_HTTPS_PORT"; then
        die "HTTPS port ${PRESTO_HTTPS_PORT} is already in use by another process. Pick another PRESTO_HTTPS_PORT."
    fi
fi

# Paths
SOFTWARES="$BASE_DIR/softwares"
PRESTO_SRC="$SOFTWARES/presto"

PRESTO_HOME_DIR="$BASE_DIR/apps/presto"
PRESTO_BINARIES="$PRESTO_HOME_DIR/binaries"
PRESTO_DATA="$PRESTO_HOME_DIR/data"
PRESTO_LOGS_SL="$PRESTO_HOME_DIR/logs"
PRESTO_LOGS="$BASE_DIR/logs/presto"
PRESTO_ETC="$PRESTO_BINARIES/etc"
PRESTO_CATALOG="$PRESTO_ETC/catalog"

HIVE_SITE="${HIVE_SITE_XML:-$BASE_DIR/apps/hive/binaries/conf/hive-site.xml}"

echo
echo "Installation summary"
echo "  Presto ${PRESTO_VERSION}        : $PRESTO_BINARIES"
echo "  Data / Logs        : $PRESTO_DATA , $PRESTO_LOGS"
echo "  Service user       : $SVC_USER:$SVC_GROUP  (service: ${SERVICE_NAME}.service)"
echo "  Coordinator + worker on http://${PRESTO_DISCOVERY_HOST}:${PRESTO_HTTP_PORT}"
echo "  Memory             : -Xmx${PRESTO_HEAP}, query.max-memory=${PRESTO_QUERY_MAX_MEMORY}, per-node=${PRESTO_QUERY_MAX_MEMORY_PER_NODE}"
echo "  Hive catalog       : ${HIVE_METASTORE_URI}"
if is_yes "$ENABLE_PASSWORD_AUTH"; then
    echo "  Authentication     : PASSWORD over HTTPS on ${PRESTO_HTTPS_PORT} (user: ${PRESTO_AUTH_USER}, self-signed certificate)"
else
    echo "  Authentication     : none (plain HTTP)"
fi
if is_yes "$PATCH_HIVE_SITE"; then
    echo "  Metastore fix      : add metastore.storage.schema.reader.impl to a LOCAL hive-site.xml and restart hive.service"
fi
echo
if is_yes "${ASSUME_YES:-}"; then
    CONFIRM="y"
else
    read -rp "Proceed with installation? [y/N]: " CONFIRM
fi
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------
# 3. Directories
# ---------------------------------------------------------------
ME="$(id -un)"
MY_GROUP="$(id -gn)"

OUR_DIRS=("$PRESTO_SRC" "$PRESTO_BINARIES" "$PRESTO_DATA" "$PRESTO_LOGS" "$PRESTO_DATA/var")
$SUDO mkdir -p "${OUR_DIRS[@]}" || die "Could not create directories under $BASE_DIR"
# The invoking user writes while installing; ownership moves to the service user near the end.
$SUDO chown -R "$ME:$MY_GROUP" "$PRESTO_SRC" "$PRESTO_HOME_DIR" "$PRESTO_LOGS"
log "Directories ensured under $BASE_DIR"

link_path() {   # link_path <symlink> <target>
    if [[ -L "$1" || -e "$1" ]]; then
        log "$1 already exists, skipping symlink creation"
    else
        ln -sn "$2" "$1"
        log "Created symlink $1 -> $2"
    fi
}
link_path "$PRESTO_LOGS_SL" "$PRESTO_LOGS"
# Presto's launcher writes server.log / launcher.log / http-request.log under <data-dir>/var/log
link_path "$PRESTO_DATA/var/log" "$PRESTO_LOGS"

# ---------------------------------------------------------------
# 4. Package manager & base dependencies
# ---------------------------------------------------------------
PKG_MGR=""
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
else
    die "No supported package manager found (need yum/dnf or apt-get)."
fi
log "Detected package manager: $PKG_MGR"

pkg_install() {   # pkg_install <packages...>  (returns non-zero on failure)
    case "$PKG_MGR" in
        yum|dnf) $SUDO "$PKG_MGR" install -y "$@" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" ;;
        apt)     $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
                     apt-get -o DPkg::Lock::Timeout=300 install -y "$@" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" ;;
    esac
}

if [[ "$PKG_MGR" == "apt" ]]; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -y \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || warn "apt-get update failed, continuing"
    pkg_install wget tar curl || die "Dependency installation failed. See $ERROR_LOG"
else
    pkg_install wget tar which curl || die "Dependency installation failed. See $ERROR_LOG"
fi
pkg_install jq || warn "Could not install jq -- the SQL smoke test at the end will be skipped"
log "Base dependencies installed"

# ---------------------------------------------------------------
# 5. Java 8  (Presto 0.294 needs Java 8, 8u151 or newer)
#    Never trust `command -v java` -- it may point at a newer JDK.
#    (Presto 0.295+ needs Java 17 -- not handled by this script.)
# ---------------------------------------------------------------
java_is_8() {
    local home="$1" ver
    [[ -x "$home/bin/java" ]] || return 1
    ver=$("$home/bin/java" -version 2>&1 | head -n1 || true)
    [[ "$ver" == *'"1.8.'* ]]
}

find_java8() {
    local d
    for d in "${JAVA_HOME_OVERRIDE:-}" "$BASE_DIR/apps/java" "$BASE_DIR/apps/java8" /usr/lib/jvm/*; do
        [[ -n "$d" && -d "$d" ]] || continue
        d=$(readlink -f "$d")
        if java_is_8 "$d"; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

install_java8_pkg() {
    case "$PKG_MGR" in
        apt)
            pkg_install openjdk-8-jdk-headless
            ;;
        yum|dnf)
            pkg_install java-1.8.0-openjdk-headless || pkg_install java-1.8.0-amazon-corretto
            ;;
    esac
}

install_java8_temurin() {
    local arch tgz
    case "$(uname -m)" in
        x86_64)        arch="x64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) return 1 ;;
    esac
    tgz="$PRESTO_SRC/temurin8.tar.gz"
    $SUDO mkdir -p "$BASE_DIR/apps/java8"
    wget -O "$tgz" "https://api.adoptium.net/v3/binary/latest/8/ga/linux/${arch}/jdk/hotspot/normal/eclipse" \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || return 1
    $SUDO tar -xzf "$tgz" -C "$BASE_DIR/apps/java8" --strip-components=1 >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
}

if [[ -n "${JAVA_HOME_OVERRIDE:-}" ]] && ! java_is_8 "$JAVA_HOME_OVERRIDE"; then
    die "JAVA_HOME_OVERRIDE ($JAVA_HOME_OVERRIDE) is not a Java 8 installation."
fi

if JAVA_HOME_DIR=$(find_java8); then
    log "Using existing Java 8 at $JAVA_HOME_DIR"
else
    log "Java 8 not found -- installing via package manager"
    install_java8_pkg || warn "Package install of Java 8 failed, will try Temurin 8 tarball"
    if ! JAVA_HOME_DIR=$(find_java8); then
        log "Downloading Temurin 8 into $BASE_DIR/apps/java8"
        install_java8_temurin || die "Could not install Java 8 (package + Temurin fallback both failed). Install Java 8 manually and re-run with JAVA_HOME_OVERRIDE=/path/to/jdk8. See $ERROR_LOG"
        JAVA_HOME_DIR=$(find_java8) || die "Java 8 install finished but no Java 8 could be detected."
    fi
    log "Java 8 ready at $JAVA_HOME_DIR"
fi
JAVA_UPDATE=$("$JAVA_HOME_DIR/bin/java" -version 2>&1 | sed -n 's/.*"1\.8\.0_\([0-9]*\).*/\1/p' | head -n1 || true)
if [[ -n "$JAVA_UPDATE" ]] && [[ "$JAVA_UPDATE" -lt 151 ]]; then
    warn "Java 8 update $JAVA_UPDATE found; Presto needs 8u151 or newer."
fi

# ---------------------------------------------------------------
# 6. Helpers: download + checksum
# ---------------------------------------------------------------
verify_checksum() {   # verify_checksum <file> <url-of-file>   (Maven Central publishes .sha512/.sha256/.sha1)
    local file="$1" url="$2" algo len tmp expected actual
    for algo in sha512 sha256 sha1; do
        case "$algo" in sha512) len=128 ;; sha256) len=64 ;; sha1) len=40 ;; esac
        tmp=$(mktemp)
        if wget -q -O "$tmp" "${url}.${algo}" 2>/dev/null; then
            expected=$(grep -oiE "[a-f0-9]{${len}}" "$tmp" | head -n1 | tr 'A-F' 'a-f' || true)
            rm -f "$tmp"
            if [[ -n "$expected" ]]; then
                actual=$("${algo}sum" "$file" | awk '{print $1}')
                [[ "$expected" == "$actual" ]] \
                    || die "Checksum ($algo) mismatch for $(basename "$file"). Delete it from $(dirname "$file") and re-run."
                log "Checksum ($algo) OK for $(basename "$file")"
                return 0
            fi
        else
            rm -f "$tmp"
        fi
    done
    warn "No usable checksum published for $(basename "$file") -- relying on the archive integrity test only"
    return 0
}

dir_is_empty() { [[ -z "$(ls -A "$1" 2>/dev/null)" ]]; }

write_conf() {   # write_conf <file> <mode>   (content on stdin; original kept once as <file>.orig)
    local f="$1" mode="${2:-644}"
    if [[ -f "$f" && ! -f "$f.orig" ]]; then
        cp -p "$f" "$f.orig"
    fi
    cat > "$f"
    chmod "$mode" "$f"
}

# ---------------------------------------------------------------
# 7. Presto server
# ---------------------------------------------------------------
if [[ -f "$PRESTO_BINARIES/bin/launcher" && -d "$PRESTO_BINARIES/plugin" ]]; then
    log "Presto already installed at $PRESTO_BINARIES, skipping download/extraction"
    INSTALLED_VER=$(ls "$PRESTO_BINARIES/plugin/hive-hadoop2/" 2>/dev/null | sed -n 's/^presto-hive-\([0-9][0-9.]*\)\.jar$/\1/p' | head -n1 || true)
    if [[ -n "$INSTALLED_VER" && "$INSTALLED_VER" != "$PRESTO_VERSION" ]]; then
        warn "The existing install at $PRESTO_BINARIES looks like Presto ${INSTALLED_VER}, not ${PRESTO_VERSION}. To upgrade: stop presto, move $PRESTO_BINARIES aside (copy its etc/ if needed) and re-run."
    fi
else
    dir_is_empty "$PRESTO_BINARIES" \
        || die "$PRESTO_BINARIES is not empty and does not contain a Presto install. Move it aside and re-run."
    if ! is_yes "${SKIP_DISK_CHECK:-}"; then
        FREE_MB=$(df -Pm "$PRESTO_SRC" | awk 'NR==2{print $4}')
        [[ "${FREE_MB:-0}" -ge 2500 ]] \
            || die "Only ${FREE_MB:-0} MB free on $PRESTO_SRC; need about 2500 MB (tarball + extracted files). Free space or re-run with SKIP_DISK_CHECK=y."
    fi
    log "Downloading Presto $PRESTO_VERSION (large download, please wait)"
    wget -c --tries=3 --timeout=60 -P "$PRESTO_SRC" "$PRESTO_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || die "Failed to download Presto from $PRESTO_URL. Re-run to resume, or set PRESTO_URL to a reachable mirror. See $ERROR_LOG"
    verify_checksum "$PRESTO_SRC/$PRESTO_TARBALL" "$PRESTO_URL"
    gzip -t "$PRESTO_SRC/$PRESTO_TARBALL" 2>> "$ERROR_LOG" \
        || die "$PRESTO_SRC/$PRESTO_TARBALL is not a valid gzip archive (truncated download?). Delete it and re-run."
    log "Extracting Presto into $PRESTO_BINARIES"
    tar -xzf "$PRESTO_SRC/$PRESTO_TARBALL" -C "$PRESTO_BINARIES" --strip-components=1 \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "Presto extraction failed. See $ERROR_LOG"
    [[ -f "$PRESTO_BINARIES/bin/launcher" && -d "$PRESTO_BINARIES/plugin" ]] \
        || die "Presto extraction finished but bin/launcher or plugin/ is missing under $PRESTO_BINARIES."
    log "Presto $PRESTO_VERSION installed to $PRESTO_BINARIES"
fi
chmod +x "$PRESTO_BINARIES/bin/launcher" 2>/dev/null || true

# Optional CLI (handy for testing: bin/presto --server localhost:<port>)
if is_yes "$INSTALL_CLI"; then
    if [[ -x "$PRESTO_BINARIES/bin/presto" ]]; then
        log "presto CLI already present"
    elif wget -q --tries=3 --timeout=60 -O "$PRESTO_BINARIES/bin/presto" "$PRESTO_CLI_URL" 2>> "$ERROR_LOG"; then
        chmod +x "$PRESTO_BINARIES/bin/presto"
        log "Installed presto CLI at $PRESTO_BINARIES/bin/presto"
    else
        rm -f "$PRESTO_BINARIES/bin/presto"
        warn "Could not download the presto CLI from $PRESTO_CLI_URL (server install is unaffected)"
    fi
fi

# ---------------------------------------------------------------
# 7a. Python for the launcher (bin/launcher.py)
#     On Ubuntu 22.04/24.04 and RHEL 8+ there is no plain 'python'.
# ---------------------------------------------------------------
ensure_python() {
    local f line interp=""
    for f in "$PRESTO_BINARIES/bin/launcher.py" "$PRESTO_BINARIES/bin/launcher"; do
        [[ -f "$f" ]] || continue
        line=$(head -n1 "$f" || true)
        if [[ "$line" =~ ^#!.*env[[:space:]]+(python[0-9.]*) ]]; then
            interp="${BASH_REMATCH[1]}"; break
        elif [[ "$line" =~ ^#!/.*/(python[0-9.]*)([[:space:]]|$) ]]; then
            interp="${BASH_REMATCH[1]}"; break
        fi
    done
    if [[ -z "$interp" ]]; then
        log "Launcher does not declare a Python interpreter, skipping Python check"
    elif command -v "$interp" >/dev/null 2>&1; then
        log "Launcher interpreter '$interp' found"
    else
        log "Launcher needs '$interp' which is not installed -- installing Python"
        case "$interp" in
            python)
                if [[ "$PKG_MGR" == "apt" ]]; then
                    pkg_install python-is-python3 || pkg_install python3 || true
                else
                    pkg_install python3 || true
                    command -v python >/dev/null 2>&1 || pkg_install python-unversioned-command || true
                    if ! command -v python >/dev/null 2>&1 && [[ -x /usr/bin/python3 ]]; then
                        $SUDO ln -s /usr/bin/python3 /usr/bin/python || true
                    fi
                fi
                ;;
            python3)
                pkg_install python3 || true
                ;;
            *)
                die "Presto's launcher needs '$interp', which this script cannot install. Install it and re-run."
                ;;
        esac
        command -v "$interp" >/dev/null 2>&1 || die "Could not provide '$interp' for the Presto launcher. Install it manually and re-run. See $ERROR_LOG"
        log "Installed '$interp'"
    fi
    local out
    out=$("$PRESTO_BINARIES/bin/launcher" --help 2>&1 || true)
    grep -qi 'usage' <<< "$out" \
        || die "The Presto launcher does not run on this host's Python. Output: $(echo "$out" | head -n 5 | tr '\n' ' ')"
}
ensure_python

# ---------------------------------------------------------------
# 8. Configuration (etc/)
# ---------------------------------------------------------------
mkdir -p "$PRESTO_ETC" "$PRESTO_CATALOG"

# node.id must stay the same across re-runs
NODE_ID=""
if [[ -f "$PRESTO_ETC/node.properties" ]]; then
    NODE_ID=$(sed -n 's/^node\.id=//p' "$PRESTO_ETC/node.properties" | head -n1 || true)
fi
if [[ -z "$NODE_ID" ]]; then
    NODE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
fi

# --- optional password authentication (needs HTTPS) ---
CONFIG_EXTRA=""
if is_yes "$ENABLE_PASSWORD_AUTH"; then
    KEYSTORE="$PRESTO_ETC/presto.jks"
    PASSWORD_FILE="$PRESTO_DATA/database.db"
    KS_PASS=""
    if [[ -f "$PRESTO_ETC/config.properties" ]]; then
        KS_PASS=$(sed -n 's/^http-server\.https\.keystore\.key=//p' "$PRESTO_ETC/config.properties" | head -n1 || true)
    fi
    if [[ -z "$KS_PASS" || ! -f "$KEYSTORE" ]]; then
        [[ -x "$JAVA_HOME_DIR/bin/keytool" ]] || die "keytool not found in $JAVA_HOME_DIR/bin (a full JDK is required for password authentication)."
        KS_PASS=$(openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-24 || true)
        [[ "${#KS_PASS}" -eq 24 ]] || KS_PASS=$(head -c 200 /dev/urandom | tr -dc 'A-Za-z0-9' | cut -c1-24)
        SAN="dns:localhost,ip:127.0.0.1,dns:$(hostname -f 2>/dev/null || hostname)"
        if [[ "$PRESTO_DISCOVERY_HOST" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then SAN+=",ip:${PRESTO_DISCOVERY_HOST}"; else SAN+=",dns:${PRESTO_DISCOVERY_HOST}"; fi
        rm -f "$KEYSTORE"
        "$JAVA_HOME_DIR/bin/keytool" -genkeypair -alias presto -keyalg RSA -keysize 2048 -validity 825 \
            -dname "CN=${PRESTO_DISCOVERY_HOST}" -ext "SAN=${SAN}" -storetype JKS \
            -keystore "$KEYSTORE" -storepass "$KS_PASS" -keypass "$KS_PASS" \
            >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "Could not create the HTTPS keystore. See $ERROR_LOG"
        chmod 600 "$KEYSTORE"
        log "Self-signed HTTPS keystore created at $KEYSTORE"
    fi

    command -v htpasswd >/dev/null 2>&1 || {
        if [[ "$PKG_MGR" == "apt" ]]; then pkg_install apache2-utils; else pkg_install httpd-tools; fi \
            || die "Could not install htpasswd (apache2-utils / httpd-tools), needed to create the password file."
    }
    HT_FLAGS=(-B -i -C 10)
    [[ -f "$PASSWORD_FILE" ]] || HT_FLAGS+=(-c)
    printf '%s' "$PRESTO_AUTH_PASSWORD" | htpasswd "${HT_FLAGS[@]}" "$PASSWORD_FILE" "$PRESTO_AUTH_USER" \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "htpasswd failed. See $ERROR_LOG"
    chmod 600 "$PASSWORD_FILE"
    log "Password file $PASSWORD_FILE updated (user $PRESTO_AUTH_USER, bcrypt)"

    CONFIG_EXTRA=$'\n'"http-server.authentication.type=PASSWORD
http-server.https.enabled=true
http-server.https.port=${PRESTO_HTTPS_PORT}
http-server.https.keystore.path=${KEYSTORE}
http-server.https.keystore.key=${KS_PASS}"

    write_conf "$PRESTO_ETC/password-authenticator.properties" 644 <<EOF
password-authenticator.name=file
file.password-file=${PASSWORD_FILE}
EOF
    log "password-authenticator.properties written"
fi

write_conf "$PRESTO_ETC/config.properties" 600 <<EOF
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=${PRESTO_HTTP_PORT}
query.max-memory=${PRESTO_QUERY_MAX_MEMORY}
query.max-memory-per-node=${PRESTO_QUERY_MAX_MEMORY_PER_NODE}
discovery-server.enabled=true
discovery.uri=http://${PRESTO_DISCOVERY_HOST}:${PRESTO_HTTP_PORT}${CONFIG_EXTRA}
EOF
log "config.properties written"

write_conf "$PRESTO_ETC/jvm.config" 644 <<EOF
-server
-Xmx${PRESTO_HEAP}
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
-XX:+UseGCOverheadLimit
-XX:+ExplicitGCInvokesConcurrent
-XX:+HeapDumpOnOutOfMemoryError
-XX:+ExitOnOutOfMemoryError
-Djdk.attach.allowAttachSelf=true
EOF
log "jvm.config written"

write_conf "$PRESTO_ETC/log.properties" 644 <<EOF
com.facebook.presto=INFO
EOF
log "log.properties written"

write_conf "$PRESTO_ETC/node.properties" 644 <<EOF
node.environment=${PRESTO_NODE_ENV}
node.id=${NODE_ID}
node.data-dir=${PRESTO_DATA}
EOF
log "node.properties written (node.id=$NODE_ID)"

# --- catalogs ---
if [[ -n "${PRESTO_S3_ACCESS_KEY:-}" && -n "${PRESTO_S3_SECRET_KEY:-}" ]]; then
    S3_LINES="hive.s3.aws-access-key=${PRESTO_S3_ACCESS_KEY}
hive.s3.aws-secret-key=${PRESTO_S3_SECRET_KEY}"
    S3_NOTE="static AWS keys (from PRESTO_S3_ACCESS_KEY / PRESTO_S3_SECRET_KEY)"
else
    S3_LINES="hive.s3.use-instance-credentials=true"
    S3_NOTE="the EC2 instance role"
fi
write_conf "$PRESTO_CATALOG/hive.properties" 600 <<EOF
connector.name=hive-hadoop2
hive.allow-drop-table=true
hive.metastore.uri=${HIVE_METASTORE_URI}
${S3_LINES}
EOF
log "catalog hive.properties written (S3 access via $S3_NOTE)"

write_conf "$PRESTO_CATALOG/jmx.properties" 644 <<EOF
connector.name=jmx
EOF
log "catalog jmx.properties written"

# --- shell environment (no global JAVA_HOME on purpose) ---
PROFILE_FILE="/etc/profile.d/presto.sh"
$SUDO tee "$PROFILE_FILE" > /dev/null <<EOF
export PRESTO_HOME=${PRESTO_BINARIES}
export PATH=\$PATH:\${PRESTO_HOME}/bin
EOF
log "Wrote $PROFILE_FILE (PRESTO_HOME, PATH)"

# ---------------------------------------------------------------
# 9. Hive Metastore: "Storage schema reading not supported"
#    Presto's Hive connector triggers this error on a Hive 3 metastore
#    unless metastore.storage.schema.reader.impl is set. The property
#    belongs in the hive-site.xml of the METASTORE, so it is only
#    applied when the metastore runs on this host.
# ---------------------------------------------------------------
metastore_is_local() {
    local h="${HIVE_METASTORE_URI#thrift://}"
    h="${h%%[:,/]*}"
    [[ "$h" == "localhost" || "$h" == "127.0.0.1" ]] && return 0
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -qxF "$h" && return 0
    [[ "$h" == "$(hostname)" || "$h" == "$(hostname -f 2>/dev/null || true)" ]] && return 0
    return 1
}

wait_for_port() {   # wait_for_port <port> <max-seconds>
    local port="$1" max="$2" t=0
    while [[ "$t" -lt "$max" ]]; do
        if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then return 0; fi
        sleep 2; t=$((t + 2))
    done
    return 1
}

patch_hive_site() {
    local mport
    if ! is_yes "$PATCH_HIVE_SITE"; then
        log "Skipping hive-site.xml patch (PATCH_HIVE_SITE=$PATCH_HIVE_SITE)"
        return 0
    fi
    if ! metastore_is_local; then
        log "Metastore is not on this host; add metastore.storage.schema.reader.impl to ITS hive-site.xml if you see 'Storage schema reading not supported'"
        return 0
    fi
    if [[ ! -f "$HIVE_SITE" ]]; then
        warn "$HIVE_SITE not found. If Presto later reports 'Storage schema reading not supported', add metastore.storage.schema.reader.impl=org.apache.hadoop.hive.metastore.SerDeStorageSchemaReader to the metastore's hive-site.xml (or set HIVE_SITE_XML and re-run)."
        return 0
    fi
    if grep -q 'metastore.storage.schema.reader.impl' "$HIVE_SITE"; then
        log "hive-site.xml already sets metastore.storage.schema.reader.impl"
        return 0
    fi
    grep -q '</configuration>' "$HIVE_SITE" || { warn "$HIVE_SITE has no </configuration> tag; not patching"; return 0; }

    $SUDO cp -p "$HIVE_SITE" "${HIVE_SITE}.pre-presto"
    $SUDO sed -i 's#</configuration>#  <property>\n    <name>metastore.storage.schema.reader.impl</name>\n    <value>org.apache.hadoop.hive.metastore.SerDeStorageSchemaReader</value>\n  </property>\n</configuration>#' "$HIVE_SITE"
    log "Added metastore.storage.schema.reader.impl to $HIVE_SITE (backup: ${HIVE_SITE}.pre-presto)"

    if $SUDO systemctl is-active --quiet "${HIVE_SERVICE_NAME}.service" 2>/dev/null; then
        mport="${HIVE_METASTORE_URI##*:}"; mport="${mport%%[,/]*}"
        [[ "$mport" =~ ^[0-9]+$ ]] || mport=9083
        log "Restarting ${HIVE_SERVICE_NAME}.service so the metastore picks up the change"
        $SUDO systemctl restart "${HIVE_SERVICE_NAME}.service" || true
        if ! wait_for_port "$mport" 90; then
            warn "Metastore did not come back on port $mport after the change -- restoring the previous hive-site.xml"
            $SUDO cp -p "${HIVE_SITE}.pre-presto" "$HIVE_SITE"
            $SUDO systemctl restart "${HIVE_SERVICE_NAME}.service" || true
            die "Hive Metastore failed to restart with the patched hive-site.xml; the original was restored. See journalctl -u ${HIVE_SERVICE_NAME}."
        fi
        log "Metastore is back up on port $mport"
    else
        log "${HIVE_SERVICE_NAME}.service is not running; the change takes effect the next time the metastore starts"
    fi
}
patch_hive_site

# ---------------------------------------------------------------
# 10. Ownership (+ SELinux on RHEL-family)
# ---------------------------------------------------------------
$SUDO chown -R "$SVC_USER:$SVC_GROUP" "$PRESTO_HOME_DIR" "$PRESTO_LOGS"
log "Ownership set to $SVC_USER:$SVC_GROUP"

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    log "SELinux is Enforcing -- labeling executables so systemd may run them from $BASE_DIR"
    if ! command -v semanage >/dev/null 2>&1; then
        $SUDO "$PKG_MGR" install -y policycoreutils-python-utils >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || warn "Could not install semanage; skipping SELinux labeling"
    fi
    if command -v semanage >/dev/null 2>&1; then
        set_fcontext() {
            local ctx_type="$1" ctx_path="$2"
            if $SUDO semanage fcontext -l -C 2>/dev/null | awk '{print $1}' | grep -qxF "$ctx_path"; then
                $SUDO semanage fcontext -m -t "$ctx_type" "$ctx_path" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            else
                $SUDO semanage fcontext -a -t "$ctx_type" "$ctx_path" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            fi
        }
        SE_DIRS=("$PRESTO_BINARIES/bin")
        [[ "$JAVA_HOME_DIR" == "$BASE_DIR"/* ]] && SE_DIRS+=("$JAVA_HOME_DIR/bin")
        for d in "${SE_DIRS[@]}"; do
            set_fcontext bin_t "${d}(/.*)?" || warn "semanage failed for $d"
            $SUDO restorecon -R "$d" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || warn "restorecon failed for $d"
        done
        log "SELinux bin_t labels applied"
    fi
fi

# ---------------------------------------------------------------
# 11. systemd service
# ---------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
log "Creating systemd service ${SERVICE_NAME}.service"
$SUDO tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Presto server
After=network.target multi-user.target

[Service]
Type=forking
User=${SVC_USER}
Group=${SVC_GROUP}
Environment=JAVA_HOME=${JAVA_HOME_DIR}
Environment=PATH=${JAVA_HOME_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=${PRESTO_BINARIES}
PIDFile=${PRESTO_DATA}/var/run/launcher.pid
ExecStart=${PRESTO_BINARIES}/bin/launcher start
ExecStop=${PRESTO_BINARIES}/bin/launcher stop
Restart=on-failure
RestartSec=10
LimitNOFILE=131072
TimeoutStartSec=120
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
log "systemd service file written to $SERVICE_FILE"

$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}.service" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
log "${SERVICE_NAME}.service enabled for boot"

# Something else already on the port (and not us) would make Presto fail to bind.
if ! $SUDO systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    if port_in_use "$PRESTO_HTTP_PORT"; then
        die "Port ${PRESTO_HTTP_PORT} is already in use by another process. Pick another PRESTO_HTTP_PORT or stop that process."
    fi
fi

presto_diagnostics() {
    {
        echo "---- systemctl status ${SERVICE_NAME}.service ----"
        $SUDO systemctl status "${SERVICE_NAME}.service" --no-pager -l 2>&1 || true
        echo "---- journalctl -xeu ${SERVICE_NAME}.service ----"
        $SUDO journalctl -xeu "${SERVICE_NAME}.service" --no-pager -n 50 -o cat 2>&1 || true
        echo "---- tail of ${PRESTO_LOGS}/server.log ----"
        tail -n 60 "${PRESTO_LOGS}/server.log" 2>&1 || true
        echo "---- tail of ${PRESTO_LOGS}/launcher.log ----"
        tail -n 20 "${PRESTO_LOGS}/launcher.log" 2>&1 || true
    } | tee -a "$ERROR_LOG"
}

if ! $SUDO systemctl restart "${SERVICE_NAME}.service"; then
    presto_diagnostics
    die "Failed to start ${SERVICE_NAME}.service. Diagnostics captured above and in $ERROR_LOG."
fi
log "${SERVICE_NAME}.service started"

# ---------------------------------------------------------------
# 12. Verify: port -> /v1/info "starting":false -> SQL smoke test
# ---------------------------------------------------------------
log "Waiting for Presto to listen on port ${PRESTO_HTTP_PORT} (up to 120s)"
if ! wait_for_port "$PRESTO_HTTP_PORT" 120; then
    presto_diagnostics
    die "Presto did not open port ${PRESTO_HTTP_PORT}. See $ERROR_LOG and ${PRESTO_LOGS}/server.log."
fi

log "Waiting for Presto to finish starting (up to 120s)"
READY="no"
for _ in $(seq 1 60); do
    INFO=$(curl -s --max-time 5 "http://127.0.0.1:${PRESTO_HTTP_PORT}/v1/info" || true)
    if [[ "$INFO" == *'"starting":false'* ]]; then
        READY="yes"
        break
    fi
    sleep 2
done
if [[ "$READY" != "yes" ]] || ! $SUDO systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    presto_diagnostics
    die "Presto is not ready (/v1/info never reported starting=false). See $ERROR_LOG and ${PRESTO_LOGS}/server.log."
fi
log "Presto reports ready: $INFO"

presto_sql() {   # presto_sql "<SQL>"  -> one comma-joined row per line; non-zero on error
    local base="http://127.0.0.1:${PRESTO_HTTP_PORT}" resp next err r rows="" i
    resp=$(curl -s --max-time 30 -X POST -H "X-Presto-User: presto-install" --data "$1" "$base/v1/statement") || return 1
    for i in $(seq 1 120); do
        [[ -n "$resp" ]] || return 1
        err=$(jq -r '.error.message // empty' <<< "$resp" 2>/dev/null) || return 1
        if [[ -n "$err" ]]; then echo "$err" >&2; return 1; fi
        r=$(jq -r '.data[]? | map(tostring) | join(",")' <<< "$resp" 2>/dev/null) || return 1
        if [[ -n "$r" ]]; then rows+="$r"$'\n'; fi
        next=$(jq -r '.nextUri // empty' <<< "$resp" 2>/dev/null) || return 1
        [[ -z "$next" ]] && break
        sleep 1
        resp=$(curl -s --max-time 30 -H "X-Presto-User: presto-install" "$next") || return 1
    done
    printf '%s' "$rows"
}

if command -v jq >/dev/null 2>&1; then
    if CATS=$(presto_sql "SHOW CATALOGS" 2>> "$ERROR_LOG"); then
        if grep -qx 'hive' <<< "$CATS" && grep -qx 'jmx' <<< "$CATS"; then
            log "SQL smoke test OK: catalogs = $(echo "$CATS" | tr '\n' ' ')"
        else
            warn "Presto is up but the catalogs list is unexpected: $(echo "$CATS" | tr '\n' ' ') -- check ${PRESTO_CATALOG}/ and server.log"
        fi
        if SCHEMAS=$(presto_sql "SHOW SCHEMAS FROM hive" 2>> "$ERROR_LOG"); then
            log "Hive metastore reachable from Presto: schemas = $(echo "$SCHEMAS" | tr '\n' ' ')"
        else
            warn "Presto is up, but 'SHOW SCHEMAS FROM hive' failed (is the metastore at ${HIVE_METASTORE_URI} running?). Details: $(tail -n 2 "$ERROR_LOG" | tr '\n' ' ')"
        fi
    else
        warn "Presto is ready but the SQL smoke test failed: $(tail -n 2 "$ERROR_LOG" | tr '\n' ' ')"
    fi
else
    warn "jq not installed -- skipping the SQL smoke test"
fi

echo
echo "=================================================================="
echo " Presto ${PRESTO_VERSION} installed; server is running."
echo " Presto     : $PRESTO_BINARIES"
echo " Config     : $PRESTO_ETC  (catalogs in $PRESTO_CATALOG)"
echo " Logs       : $PRESTO_LOGS  (symlink $PRESTO_LOGS_SL)"
echo " Web UI     : http://${PRESTO_DISCOVERY_HOST}:${PRESTO_HTTP_PORT}"
if is_yes "$ENABLE_PASSWORD_AUTH"; then
echo " Secure UI  : https://${PRESTO_DISCOVERY_HOST}:${PRESTO_HTTPS_PORT}  (user ${PRESTO_AUTH_USER}; self-signed cert)"
echo " NOTE       : the plain HTTP port ${PRESTO_HTTP_PORT} stays open for internal use -- restrict it in your firewall"
fi
echo " Service    : systemctl status ${SERVICE_NAME}"
echo " Test       : ${PRESTO_BINARIES}/bin/presto --server localhost:${PRESTO_HTTP_PORT} --catalog hive --schema default"
echo " New shells : source $PROFILE_FILE   (adds presto/launcher to PATH)"
echo "=================================================================="

