#!/bin/bash
#================================================================
# pg_install_master.sh
# Fully automated installation of a PostgreSQL 17.6 MASTER
# (primary) node, built from source, with streaming replication
# pre-configured for one or more replicas.
#
# Interactive usage:
#   sudo ./pg_install_master.sh
#
# Non-interactive (AUTOMATED) usage:
#   AUTOMATED=1 PG_VERSION=17.6 BASE_DIR=/opt/ausiytic PG_PORT=5432 \
#   SERVICE_USER=postgres MASTER_IP=10.0.0.10 REPLICA_IPS_RAW=10.0.0.11,10.0.0.12 \
#   OPEN_CLIENT_ACCESS=N APP_DB=appdb sudo -E ./pg_install_master.sh
#
# In AUTOMATED mode every variable below falls back to its documented
# default if not exported, EXCEPT it will never silently accept an
# invalid/unsafe value (e.g. a bad IP or a system directory) — it dies
# with a clear message instead of hanging on a prompt that will never
# be answered.
#================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/pg_install_master.$(date +%Y%m%d%H%M%S).log"
touch "$LOG_FILE"

AUTOMATED="${AUTOMATED:-0}"

# ---------- inlined pg_common.sh (functions shared by master/replica) ----------
#================================================================
# Shared helper functions for PostgreSQL 17.6 cluster automation
# (inlined below — originally pg_common.sh).
#================================================================

# ---------- colors / logging ----------
C_GREEN="\033[0;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[0;31m"; C_BLUE="\033[0;34m"; C_RESET="\033[0m"

log()  { echo -e "${C_BLUE}[$(date +'%F %T')]${C_RESET} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${C_GREEN}[$(date +'%F %T')] [OK]${C_RESET} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${C_YELLOW}[$(date +'%F %T')] [WARN]${C_RESET} $*" | tee -a "$LOG_FILE"; }
die()  { echo -e "${C_RED}[$(date +'%F %T')] [ERROR]${C_RESET} $*" | tee -a "$LOG_FILE"; exit 1; }

# ---------- pre-flight ----------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (use sudo)."
    fi
}

# ---------- OS detection ----------
# Sets: OS_ID, OS_FAMILY (debian|rhel|suse), PKG_INSTALL, PKG_UPDATE
detect_os() {
    if [ ! -f /etc/os-release ]; then
        die "Cannot detect OS: /etc/os-release not found. Unsupported system."
    fi
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

# ---------- build dependencies ----------
install_build_deps() {
    log "Installing build dependencies for family '$OS_FAMILY' (this can take a few minutes)..."
    case "$OS_FAMILY" in
        debian)
            $PKG_UPDATE >> "$LOG_FILE" 2>&1
            $PKG_INSTALL build-essential gcc make wget tar bison flex \
                libreadline-dev zlib1g-dev libssl-dev libxml2-dev libxslt1-dev \
                libperl-dev python3-dev tcl-dev uuid-dev liblz4-dev libzstd-dev \
                pkg-config locales >> "$LOG_FILE" 2>&1 \
                || die "Dependency installation failed. See $LOG_FILE"
            ;;
        rhel)
            $PKG_UPDATE >> "$LOG_FILE" 2>&1
            $PKG_INSTALL gcc gcc-c++ make wget tar bison flex \
                readline-devel zlib-devel openssl-devel libxml2-devel libxslt-devel \
                perl-devel python3-devel tcl-devel libuuid-devel lz4-devel libzstd-devel \
                pkgconfig glibc-langpack-en >> "$LOG_FILE" 2>&1 \
                || die "Dependency installation failed. See $LOG_FILE"
            ;;
        suse)
            $PKG_UPDATE >> "$LOG_FILE" 2>&1
            $PKG_INSTALL gcc gcc-c++ make wget tar bison flex \
                readline-devel zlib-devel libopenssl-devel libxml2-devel libxslt-devel \
                perl python3-devel tcl-devel libuuid-devel liblz4-devel libzstd-devel \
                pkg-config glibc-locale >> "$LOG_FILE" 2>&1 \
                || die "Dependency installation failed. See $LOG_FILE"
            ;;
    esac
    ok "Build dependencies installed."
}

# ---------- credential generation ----------
gen_secret() {
    # 24 chars, alphanumeric only (safe to embed in conninfo strings / .pgpass / URLs without escaping)
    openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24
}

# ---------- networking helpers ----------
detect_primary_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -n1)
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    for octet in ${ip//./ }; do
        [ "$octet" -le 255 ] || return 1
    done
    return 0
}

# prompt_ip TEXT DEFAULT [CURRENT_VALUE]
# In AUTOMATED mode: uses CURRENT_VALUE (or DEFAULT), validates, dies if bad.
prompt_ip() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        valid_ip "$val" || die "AUTOMATED mode: invalid IPv4 value '$val' for: $prompt_text"
        echo "$val"
        return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"
        if valid_ip "$val"; then
            echo "$val"
            return 0
        fi
        echo "  '$val' is not a valid IPv4 address, try again." >&2
    done
}

# prompt_nonempty TEXT DEFAULT [CURRENT_VALUE]
prompt_nonempty() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        [ -n "$val" ] || die "AUTOMATED mode: empty value not allowed for: $prompt_text"
        echo "$val"
        return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"
        if [ -n "$val" ]; then
            echo "$val"
            return 0
        fi
        echo "  Value cannot be empty." >&2
    done
}

# ---------- safe base-dir prompt (rejects '/', empty, and other dangerous roots) ----------
# prompt_base_dir TEXT DEFAULT [CURRENT_VALUE]
prompt_base_dir() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        val="${val%/}"
        case "$val" in
            ""|"/"|"/root"|"/home"|"/etc"|"/usr"|"/var"|"/bin"|"/sbin"|"/lib"|"/boot"|"/sys"|"/proc"|"/dev")
                die "AUTOMATED mode: refusing to install under '$val' — this is a system directory."
                ;;
        esac
        [[ "$val" == /* ]] || die "AUTOMATED mode: BASE_DIR must be an absolute path, got '$val'."
        echo "$val"
        return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"
        # strip trailing slash(es) so "/opt/ausiytic/" and "/opt/ausiytic" match the same checks
        val="${val%/}"
        case "$val" in
            ""|"/"|"/root"|"/home"|"/etc"|"/usr"|"/var"|"/bin"|"/sbin"|"/lib"|"/boot"|"/sys"|"/proc"|"/dev")
                echo "  Refusing to install under '$val' — this is a system directory. Choose a dedicated path (e.g. /opt/ausiytic)." >&2
                continue
                ;;
        esac
        if [[ "$val" != /* ]]; then
            echo "  Path must be absolute (start with /)." >&2
            continue
        fi
        echo "$val"
        return 0
    done
}

# ---------- OS service user ----------
ensure_service_user() {
    local svc_user="$1" base_dir="$2"
    if id "$svc_user" >/dev/null 2>&1; then
        ok "OS user '$svc_user' already exists."
    else
        log "Creating OS user '$svc_user'..."
        useradd --system --home-dir "$base_dir" --shell /bin/bash "$svc_user" \
            || die "Failed to create OS user $svc_user"
        ok "OS user '$svc_user' created."
    fi
}

# ---------- download + build + install postgres from source ----------
# Populates: PG_BINARIES (install prefix)
build_and_install_postgres() {
    local pg_version="$1" source_dir="$2" prefix="$3" svc_user="$4"

    mkdir -p "$source_dir"
    cd "$source_dir" || die "Cannot cd into $source_dir"

    local tarball="postgresql-${pg_version}.tar.gz"
    local url="https://ftp.postgresql.org/pub/source/v${pg_version}/${tarball}"

    if [ -f "$tarball" ]; then
        ok "Source tarball already downloaded: $tarball"
    else
        log "Downloading PostgreSQL $pg_version from $url ..."
        wget -q --show-progress "$url" -O "$tarball" || die "Download failed for $url. Check version number / network access."
    fi

    log "Extracting source..."
    tar -xzf "$tarball" || die "Extraction failed."

    cd "postgresql-${pg_version}" || die "Extracted source directory not found."

    log "Configuring build (prefix=$prefix)..."
    ./configure --prefix="$prefix" --exec-prefix="$prefix" \
        --with-openssl --with-libxml --with-libxslt --with-uuid=e2fs --with-lz4 --with-zstd \
        >> "$LOG_FILE" 2>&1 || die "./configure failed. See $LOG_FILE"

    log "Compiling (make -j$(nproc))... this may take several minutes."
    make -j"$(nproc)" >> "$LOG_FILE" 2>&1 || die "make failed. See $LOG_FILE"

    log "Installing binaries to $prefix ..."
    make install >> "$LOG_FILE" 2>&1 || die "make install failed. See $LOG_FILE"

    ok "PostgreSQL $pg_version compiled and installed to $prefix"
}

# ---------- expose client binaries (psql, pg_dump, etc.) on PATH ----------
setup_cli_symlinks() {
    local prefix="$1"
    local bin_target="/usr/local/bin"
    local tool
    for tool in psql pg_dump pg_dumpall pg_restore pg_basebackup pg_isready createdb dropdb createuser pg_ctl; do
        if [ -x "${prefix}/bin/${tool}" ]; then
            ln -sf "${prefix}/bin/${tool}" "${bin_target}/${tool}"
        fi
    done
    ok "Symlinked psql and client tools into ${bin_target} (now on PATH)."
}

# ---------- systemd service ----------
create_systemd_service() {
    local svc_user="$1" binaries="$2" datadir="$3" service_name="${4:-postgresql}"
    local unit_file="/etc/systemd/system/${service_name}.service"

    log "Creating systemd unit: $unit_file"
    cat > "$unit_file" <<EOF
[Unit]
Description=PostgreSQL database server (${service_name})
After=network.target

[Service]
Type=forking
User=${svc_user}
Group=${svc_user}
Environment=PGDATA=${datadir}
OOMScoreAdjust=-1000
ExecStart=${binaries}/bin/pg_ctl start -D \${PGDATA} -s -w -t 300
ExecStop=${binaries}/bin/pg_ctl stop -D \${PGDATA} -s -m fast
ExecReload=${binaries}/bin/pg_ctl reload -D \${PGDATA} -s
TimeoutSec=310
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}.service" >> "$LOG_FILE" 2>&1
    ok "systemd service '${service_name}' created and enabled."
}

wait_for_postgres_ready() {
    local binaries="$1" datadir="$2" tries=30
    while [ $tries -gt 0 ]; do
        if "$binaries/bin/pg_isready" -q -h /tmp -p "$PG_PORT" 2>/dev/null || \
           "$binaries/bin/pg_ctl" status -D "$datadir" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        tries=$((tries - 1))
    done
    return 1
}

print_banner() {
    echo
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
}
# ---------- end inlined pg_common.sh ----------

require_root
print_banner "PostgreSQL 17.6 - MASTER Installation"
[ "$AUTOMATED" = "1" ] && log "Running in AUTOMATED (non-interactive) mode."

# ------------------------------------------------------------------
# 1. Interactive input (or env-var driven, see AUTOMATED above)
# ------------------------------------------------------------------
DEFAULT_PG_VERSION="17.6"
PG_VERSION=$(prompt_nonempty "PostgreSQL version to install" "$DEFAULT_PG_VERSION" "${PG_VERSION:-}")

DEFAULT_BASE_DIR="/opt/ausiytic"
BASE_DIR=$(prompt_base_dir "Base volume/mount path to install under (e.g. /opt/mydata)" "$DEFAULT_BASE_DIR" "${BASE_DIR:-}")

DEFAULT_PORT="5432"
PG_PORT=$(prompt_nonempty "PostgreSQL port" "$DEFAULT_PORT" "${PG_PORT:-}")

DEFAULT_SVC_USER="postgres"
SERVICE_USER=$(prompt_nonempty "OS user to run PostgreSQL as" "$DEFAULT_SVC_USER" "${SERVICE_USER:-}")

DETECTED_IP=$(detect_primary_ip)
[ -z "$DETECTED_IP" ] && DETECTED_IP="0.0.0.0"
MASTER_IP=$(prompt_ip "This MASTER server's IP address (used in listen_addresses)" "$DETECTED_IP" "${MASTER_IP:-}")

if [ "$AUTOMATED" = "1" ]; then
    REPLICA_IPS_RAW="${REPLICA_IPS_RAW:-}"
    REPLICA_IPS_RAW="${REPLICA_IPS_RAW// /}"
    OPEN_CLIENT_ACCESS="${OPEN_CLIENT_ACCESS:-N}"
else
    echo
    echo "Enter the IP address(es) of REPLICA servers that will connect to this master."
    echo "You can add more later by editing pg_hba.conf; enter at least one now if known."
    read -rp "Replica IP(s), comma-separated (leave blank to configure later): " REPLICA_IPS_RAW
    REPLICA_IPS_RAW="${REPLICA_IPS_RAW// /}"

    echo
    read -rp "Allow application clients from any IP (0.0.0.0/0) with password auth? [y/N]: " OPEN_CLIENT_ACCESS
    OPEN_CLIENT_ACCESS="${OPEN_CLIENT_ACCESS:-N}"
fi

APP_DB=$(prompt_nonempty "Initial application database name to create" "appdb" "${APP_DB:-}")

# ------------------------------------------------------------------
# 2. Derived paths
# ------------------------------------------------------------------
SOURCE_DIR="${BASE_DIR}/softwares"
PG_BINARIES="${BASE_DIR}/db/postgresql/binaries"
PG_DATA="${BASE_DIR}/db/postgresql/data"
PG_ARCHIVE="${PG_DATA}/archive"
PG_LOGS="${BASE_DIR}/db/postgresql/logs"
PG_LOGS_SL="${BASE_DIR}/db/postgresql/logs_link"
CRED_FILE="${BASE_DIR}/postgresql_master_credentials.txt"

REPL_USER="replicator"
REPL_PASSWORD=$(gen_secret)
PG_SUPERUSER="postgres"
PG_SUPERUSER_PASSWORD=$(gen_secret)
APP_USER="appuser"
APP_USER_PASSWORD=$(gen_secret)

# ------------------------------------------------------------------
# 3. OS + dependencies
# ------------------------------------------------------------------
detect_os
install_build_deps

# ------------------------------------------------------------------
# 4. Directories & service user
# ------------------------------------------------------------------
log "Creating directory structure under $BASE_DIR ..."
mkdir -p "$SOURCE_DIR" "$PG_BINARIES" "$PG_DATA" "$PG_LOGS"
ln -sfn "$PG_LOGS" "$PG_LOGS_SL"

ensure_service_user "$SERVICE_USER" "$BASE_DIR"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$BASE_DIR"

# ------------------------------------------------------------------
# 5. Build & install PostgreSQL
# ------------------------------------------------------------------
if [ -x "${PG_BINARIES}/bin/postgres" ]; then
    warn "PostgreSQL binaries already present at $PG_BINARIES/bin/postgres — skipping build."
else
    build_and_install_postgres "$PG_VERSION" "$SOURCE_DIR" "$PG_BINARIES" "$SERVICE_USER"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$PG_BINARIES"
fi
setup_cli_symlinks "$PG_BINARIES"

# ------------------------------------------------------------------
# 6. initdb (idempotent)
# ------------------------------------------------------------------
if [ -s "${PG_DATA}/PG_VERSION" ]; then
    warn "Data directory $PG_DATA already initialized — skipping initdb."
else
    log "Running initdb as $SERVICE_USER ..."
    PWFILE=$(mktemp)
    echo "$PG_SUPERUSER_PASSWORD" > "$PWFILE"
    chown "$SERVICE_USER":"$SERVICE_USER" "$PWFILE"
    chmod 600 "$PWFILE"

    su - "$SERVICE_USER" -c "LC_ALL=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 '${PG_BINARIES}/bin/initdb' -D '${PG_DATA}' -U '${PG_SUPERUSER}' --pwfile='${PWFILE}' --auth=md5 --auth-host=md5 --auth-local=md5" \
        >> "$LOG_FILE" 2>&1 || die "initdb failed. See $LOG_FILE"
    rm -f "$PWFILE"
    ok "initdb completed."
fi

mkdir -p "$PG_ARCHIVE"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$PG_ARCHIVE" "$PG_DATA"

# ------------------------------------------------------------------
# 7. Configure postgresql.conf
# ------------------------------------------------------------------
PGCONF="${PG_DATA}/postgresql.conf"
HBACONF="${PG_DATA}/pg_hba.conf"
# Config backups are kept OUTSIDE PGDATA so pg_basebackup never has to read
# them (avoids permission errors from root-owned files inside the data dir).
CONF_BACKUP_DIR="${BASE_DIR}/db/postgresql/conf_backups"

log "Backing up original conf files to $CONF_BACKUP_DIR ..."
mkdir -p "$CONF_BACKUP_DIR"
cp -n "$PGCONF" "${CONF_BACKUP_DIR}/postgresql.conf.orig" 2>/dev/null || true
cp -n "$HBACONF" "${CONF_BACKUP_DIR}/pg_hba.conf.orig" 2>/dev/null || true
chown -R "$SERVICE_USER":"$SERVICE_USER" "$CONF_BACKUP_DIR"
# Remove any stray *.orig files a previous script version may have left
# inside PGDATA — these break pg_basebackup if root-owned.
rm -f "${PGCONF}.orig" "${HBACONF}.orig"

log "Applying master configuration to postgresql.conf ..."
set_conf() {
    local key="$1" value="$2" file="$3"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$file"
    else
        echo "${key} = ${value}" >> "$file"
    fi
}

set_conf "listen_addresses" "'${MASTER_IP},localhost'" "$PGCONF"
set_conf "port" "${PG_PORT}" "$PGCONF"
set_conf "max_connections" "300" "$PGCONF"
set_conf "shared_buffers" "1GB" "$PGCONF"
set_conf "work_mem" "64MB" "$PGCONF"
set_conf "dynamic_shared_memory_type" "posix" "$PGCONF"
set_conf "wal_level" "replica" "$PGCONF"
set_conf "wal_compression" "on" "$PGCONF"
set_conf "max_wal_senders" "10" "$PGCONF"
set_conf "max_replication_slots" "10" "$PGCONF"
set_conf "wal_keep_size" "2048" "$PGCONF"
set_conf "hot_standby" "on" "$PGCONF"
set_conf "archive_mode" "on" "$PGCONF"
set_conf "archive_command" "'test ! -f ${PG_ARCHIVE}/%f && cp %p ${PG_ARCHIVE}/%f'" "$PGCONF"
set_conf "log_destination" "'stderr'" "$PGCONF"
set_conf "logging_collector" "on" "$PGCONF"
set_conf "log_directory" "'${PG_LOGS_SL}'" "$PGCONF"
set_conf "log_filename" "'postgresql-%Y-%m-%d_%H%M%S.log'" "$PGCONF"
set_conf "log_file_mode" "0600" "$PGCONF"
set_conf "log_rotation_age" "1d" "$PGCONF"
set_conf "log_rotation_size" "100MB" "$PGCONF"
set_conf "log_min_messages" "warning" "$PGCONF"
set_conf "log_min_error_statement" "error" "$PGCONF"
set_conf "log_lock_waits" "on" "$PGCONF"
set_conf "autovacuum" "on" "$PGCONF"
set_conf "autovacuum_max_workers" "3" "$PGCONF"

# ------------------------------------------------------------------
# 8. Configure pg_hba.conf
# ------------------------------------------------------------------
log "Applying pg_hba.conf rules ..."
{
    echo ""
    echo "# --- added by pg_install_master.sh on $(date +%F) ---"
    echo "host    all             all             127.0.0.1/32            md5"
} >> "$HBACONF"

if [ -n "$REPLICA_IPS_RAW" ]; then
    IFS=',' read -ra REPLICA_IP_ARR <<< "$REPLICA_IPS_RAW"
    for rip in "${REPLICA_IP_ARR[@]}"; do
        if valid_ip "$rip"; then
            echo "host    replication     ${REPL_USER}         ${rip}/32              md5" >> "$HBACONF"
            echo "host    all             all             ${rip}/32              md5" >> "$HBACONF"
        else
            warn "Skipping invalid replica IP: $rip"
        fi
    done
else
    warn "No replica IPs supplied — you will need to add 'host replication ${REPL_USER} <replica-ip>/32 md5' to $HBACONF manually before running the replica installer."
fi

if [[ "$OPEN_CLIENT_ACCESS" =~ ^[Yy]$ ]]; then
    echo "host    all             all             0.0.0.0/0               md5" >> "$HBACONF"
    warn "Opened client access to 0.0.0.0/0 (password required). Restrict this in production."
fi

chown "$SERVICE_USER":"$SERVICE_USER" "$PGCONF" "$HBACONF"

# ------------------------------------------------------------------
# 9. systemd service
# ------------------------------------------------------------------
create_systemd_service "$SERVICE_USER" "$PG_BINARIES" "$PG_DATA" "postgresql"

log "Starting PostgreSQL service..."
systemctl restart postgresql.service || die "Failed to start postgresql.service — check 'journalctl -u postgresql'"

if ! wait_for_postgres_ready "$PG_BINARIES" "$PG_DATA"; then
    die "PostgreSQL did not become ready in time. Check $PG_LOGS and 'journalctl -u postgresql'."
fi
ok "PostgreSQL service is up and running on port ${PG_PORT}."

# ------------------------------------------------------------------
# 10. Reset superuser password (in case pwfile path wasn't used, e.g. pre-existing cluster)
# ------------------------------------------------------------------
export PGPASSWORD="$PG_SUPERUSER_PASSWORD"
PSQL="${PG_BINARIES}/bin/psql"

su - "$SERVICE_USER" -c "PGPASSWORD='${PG_SUPERUSER_PASSWORD}' '${PSQL}' -p ${PG_PORT} -U ${PG_SUPERUSER} -h localhost -d postgres -c \"ALTER USER ${PG_SUPERUSER} WITH ENCRYPTED PASSWORD '${PG_SUPERUSER_PASSWORD}';\"" \
    >> "$LOG_FILE" 2>&1

# ------------------------------------------------------------------
# 11. Create replication role
# ------------------------------------------------------------------
log "Creating replication role '${REPL_USER}' ..."
su - "$SERVICE_USER" -c "PGPASSWORD='${PG_SUPERUSER_PASSWORD}' '${PSQL}' -p ${PG_PORT} -U ${PG_SUPERUSER} -h localhost -d postgres -c \"DO \\\$\\\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${REPL_USER}') THEN CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN ENCRYPTED PASSWORD '${REPL_PASSWORD}'; END IF; END \\\$\\\$;\"" \
    >> "$LOG_FILE" 2>&1 || die "Failed to create replication role. See $LOG_FILE"
ok "Replication role '${REPL_USER}' ready."

# ------------------------------------------------------------------
# 12. Create physical replication slots (one per replica IP given)
# ------------------------------------------------------------------
SLOT_NAMES=()
if [ -n "$REPLICA_IPS_RAW" ]; then
    IFS=',' read -ra REPLICA_IP_ARR <<< "$REPLICA_IPS_RAW"
    idx=1
    for rip in "${REPLICA_IP_ARR[@]}"; do
        valid_ip "$rip" || continue
        slot="replica_slot_${idx}"
        SLOT_NAMES+=("$slot")
        su - "$SERVICE_USER" -c "PGPASSWORD='${PG_SUPERUSER_PASSWORD}' '${PSQL}' -p ${PG_PORT} -U ${PG_SUPERUSER} -h localhost -d postgres -c \"SELECT pg_create_physical_replication_slot('${slot}') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='${slot}');\"" \
            >> "$LOG_FILE" 2>&1
        ok "Created replication slot '${slot}' for replica ${rip}"
        idx=$((idx+1))
    done
else
    slot="replica_slot_1"
    SLOT_NAMES+=("$slot")
    su - "$SERVICE_USER" -c "PGPASSWORD='${PG_SUPERUSER_PASSWORD}' '${PSQL}' -p ${PG_PORT} -U ${PG_SUPERUSER} -h localhost -d postgres -c \"SELECT pg_create_physical_replication_slot('${slot}') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='${slot}');\"" \
        >> "$LOG_FILE" 2>&1
    ok "Created default replication slot '${slot}' (assign it when you run the replica installer)."
fi

# ------------------------------------------------------------------
# 13. Create application database + app user
# ------------------------------------------------------------------
log "Creating application database '${APP_DB}' and user '${APP_USER}' ..."
su - "$SERVICE_USER" -c "PGPASSWORD='${PG_SUPERUSER_PASSWORD}' '${PSQL}' -p ${PG_PORT} -U ${PG_SUPERUSER} -h localhost -d postgres -c \"DO \\\$\\\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${APP_USER}') THEN CREATE ROLE ${APP_USER} WITH LOGIN ENCRYPTED PASSWORD '${APP_USER_PASSWORD}'; END IF; END \\\$\\\$;\"" \
    >> "$LOG_FILE" 2>&1
su - "$SERVICE_USER" -c "PGPASSWORD='${PG_SUPERUSER_PASSWORD}' '${PSQL}' -p ${PG_PORT} -U ${PG_SUPERUSER} -h localhost -d postgres -tc \"SELECT 1 FROM pg_database WHERE datname='${APP_DB}'\" | grep -q 1 || PGPASSWORD='${PG_SUPERUSER_PASSWORD}' '${PSQL}' -p ${PG_PORT} -U ${PG_SUPERUSER} -h localhost -d postgres -c \"CREATE DATABASE ${APP_DB} OWNER ${APP_USER};\"" \
    >> "$LOG_FILE" 2>&1
ok "Application database ready."

# ------------------------------------------------------------------
# 14. Reload config, persist credentials, print summary
# ------------------------------------------------------------------
systemctl reload postgresql.service 2>/dev/null || su - "$SERVICE_USER" -c "'${PG_BINARIES}/bin/pg_ctl' reload -D '${PG_DATA}'" >> "$LOG_FILE" 2>&1

cat > "$CRED_FILE" <<EOF
=====================================================================
 PostgreSQL ${PG_VERSION} MASTER — Connection details
 Generated: $(date +'%F %T')
=====================================================================
Host (this master)     : ${MASTER_IP}
Port                    : ${PG_PORT}
Data directory          : ${PG_DATA}
Binaries                : ${PG_BINARIES}
Log directory           : ${PG_LOGS}
OS service user         : ${SERVICE_USER}
Systemd service         : postgresql.service

--- Superuser ---
Username                : ${PG_SUPERUSER}
Password                : ${PG_SUPERUSER_PASSWORD}

--- Application database ---
Database                : ${APP_DB}
Username                : ${APP_USER}
Password                : ${APP_USER_PASSWORD}
Connect string           : postgresql://${APP_USER}:${APP_USER_PASSWORD}@${MASTER_IP}:${PG_PORT}/${APP_DB}

--- Replication ---
Replication username    : ${REPL_USER}
Replication password    : ${REPL_PASSWORD}
Replication slot(s)     : ${SLOT_NAMES[*]}
Replica IP(s) allowed    : ${REPLICA_IPS_RAW:-<none configured yet - edit pg_hba.conf>}

Use these REPLICATION credentials and a slot name above when running
pg_install_replica.sh on each replica server.
=====================================================================
EOF
chmod 600 "$CRED_FILE"
chown "$SERVICE_USER":"$SERVICE_USER" "$CRED_FILE"

print_banner "MASTER INSTALLATION COMPLETE"
cat "$CRED_FILE"
echo
echo "(Also saved to: $CRED_FILE — readable only by root/${SERVICE_USER})"
echo "Full install log: $LOG_FILE"

