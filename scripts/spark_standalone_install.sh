#!/bin/bash
#================================================================
# spark_standalone_install.sh
# Fully automated installation of Apache Spark in STANDALONE
# single-node mode: both the MASTER and the WORKER daemon run
# on this same box (a one-node standalone cluster). Same
# conventions as spark_install.sh (idempotent, interactive OR
# fully non-interactive, systemd services, structured logging,
# safe defaults).
#
# Interactive usage:
#   sudo ./spark_standalone_install.sh
#
# Non-interactive (AUTOMATED) usage:
#   AUTOMATED=1 SPARK_VERSION=4.0.3 HADOOP_VARIANT=hadoop3 \
#   BASE_DIR=/opt/ausiytic SERVICE_USER=spark \
#   MASTER_PORT=7077 MASTER_UI_PORT=8080 WORKER_UI_PORT=8081 \
#   WORKER_CORES=0 WORKER_MEMORY=0 \
#   sudo -E ./spark_standalone_install.sh
#
# WORKER_CORES=0 / WORKER_MEMORY=0 mean "let Spark auto-detect"
# (all cores, all RAM minus 1GB). Set explicit values (e.g.
# WORKER_CORES=4, WORKER_MEMORY=8g) to cap resource usage.
#
# In AUTOMATED mode every variable below falls back to its
# documented default if not exported, EXCEPT it will never
# silently accept an invalid/unsafe value — it dies with a
# clear message instead of hanging on a prompt that will
# never be answered.
#================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/spark_standalone_install.$(date +%Y%m%d%H%M%S).log"
touch "$LOG_FILE"

AUTOMATED="${AUTOMATED:-0}"

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
            JAVA_PKG="openjdk-17-jdk-headless"
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
            JAVA_PKG="java-17-openjdk-headless"
            ;;
        *suse*|*sles*)
            OS_FAMILY="suse"
            PKG_UPDATE="zypper refresh"
            PKG_INSTALL="zypper install -y"
            JAVA_PKG="java-17-openjdk-headless"
            ;;
        *)
            die "Unsupported OS family (ID=$OS_ID ID_LIKE=$OS_LIKE). Supported: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma/Fedora/Amazon Linux, SUSE/SLES."
            ;;
    esac
    ok "Detected OS: $OS_ID (family: $OS_FAMILY)"
}

install_deps() {
    log "Installing dependencies (Java, wget, tar) for family '$OS_FAMILY' ..."
    $PKG_UPDATE >> "$LOG_FILE" 2>&1
    $PKG_INSTALL "$JAVA_PKG" wget tar >> "$LOG_FILE" 2>&1 \
        || die "Dependency installation failed. See $LOG_FILE"
    ok "Dependencies installed."
}

# ---------- prompt helpers ----------
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

# ---------- resource value: "0" (auto) or a positive integer/size string ----------
prompt_resource() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        echo "$val"
        return 0
    fi
    read -rp "$prompt_text [$default_val] (0 = auto-detect): " val
    val="${val:-$default_val}"
    echo "$val"
}

valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    for octet in ${ip//./ }; do
        [ "$octet" -le 255 ] || return 1
    done
    return 0
}

detect_primary_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP '(?<=src\s)\d+(\.\d+){3}' | head -n1)
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

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

# ---------- safe base-dir prompt (rejects '/', empty, and other dangerous roots) ----------
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
        log "Creating OS user '$svc_user' (no login shell, system account)..."
        useradd --system --home-dir "$base_dir" --shell /usr/sbin/nologin "$svc_user" \
            || die "Failed to create OS user $svc_user"
        ok "OS user '$svc_user' created."
    fi
}

# ---------- download + extract Spark binaries ----------
download_and_install_spark() {
    local version="$1" hadoop_variant="$2" source_dir="$3" prefix="$4"

    mkdir -p "$source_dir"
    cd "$source_dir" || die "Cannot cd into $source_dir"

    local tarball="spark-${version}-bin-${hadoop_variant}.tgz"
    local url="https://dlcdn.apache.org/spark/spark-${version}/${tarball}"
    local archive_url="https://archive.apache.org/dist/spark/spark-${version}/${tarball}"

    if [ -f "$tarball" ]; then
        ok "Spark tarball already downloaded: $tarball"
    else
        log "Downloading Spark ${version} (${hadoop_variant}) from $url ..."
        if ! wget -q --show-progress "$url" -O "$tarball"; then
            warn "Download from dlcdn.apache.org failed, retrying via archive.apache.org ..."
            wget -q --show-progress "$archive_url" -O "$tarball" \
                || die "Download failed for both $url and $archive_url. Check SPARK_VERSION/HADOOP_VARIANT/network access."
        fi
    fi

    log "Extracting Spark archive..."
    tar -xzf "$tarball" || die "Extraction failed."

    local extracted_dir="spark-${version}-bin-${hadoop_variant}"
    [ -d "$extracted_dir" ] || die "Extracted directory '$extracted_dir' not found — unexpected archive layout."

    log "Installing Spark to $prefix ..."
    mkdir -p "$prefix"
    cp -r "${extracted_dir}"/* "$prefix"/ || die "Copy to $prefix failed."

    ok "Spark ${version} (${hadoop_variant}) installed to $prefix"
}

setup_env_profile() {
    local spark_home="$1"
    cat > /etc/profile.d/spark.sh <<EOF
export SPARK_HOME=${spark_home}
export PATH=\$SPARK_HOME/bin:\$SPARK_HOME/sbin:\$PATH
EOF
    chmod 644 /etc/profile.d/spark.sh
    ok "SPARK_HOME and PATH exported system-wide via /etc/profile.d/spark.sh"
}

configure_spark_env() {
    local spark_home="$1" data_dir="$2" logs_dir="$3" master_ip="$4" \
          worker_cores="$5" worker_memory="$6"
    local env_file="${spark_home}/conf/spark-env.sh"

    if [ ! -f "$env_file" ]; then
        cp "${spark_home}/conf/spark-env.sh.template" "$env_file" \
            || die "spark-env.sh.template not found — unexpected Spark package layout."
    fi

    set_env_var() {
        local key="$1" value="$2"
        if grep -q "^${key}=" "$env_file"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
        else
            echo "${key}=${value}" >> "$env_file"
        fi
    }

    unset_env_var() {
        local key="$1"
        sed -i "/^${key}=/d" "$env_file"
    }

    local java_home
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

    set_env_var "JAVA_HOME" "${java_home}"
    set_env_var "SPARK_LOG_DIR" "${logs_dir}"
    set_env_var "SPARK_MASTER_HOST" "${master_ip}"
    set_env_var "SPARK_WORKER_DIR" "${data_dir}"

    # 0 (or unset) means "let Spark auto-detect all cores / all RAM minus 1GB"
    if [ -n "$worker_cores" ] && [ "$worker_cores" != "0" ]; then
        set_env_var "SPARK_WORKER_CORES" "${worker_cores}"
    else
        unset_env_var "SPARK_WORKER_CORES"
    fi
    if [ -n "$worker_memory" ] && [ "$worker_memory" != "0" ]; then
        set_env_var "SPARK_WORKER_MEMORY" "${worker_memory}"
    else
        unset_env_var "SPARK_WORKER_MEMORY"
    fi

    ok "spark-env.sh configured (JAVA_HOME=${java_home})."
}

# ---------- systemd services ----------
create_master_service() {
    local svc_user="$1" spark_home="$2" master_port="$3" ui_port="$4"
    local unit_file="/etc/systemd/system/spark-master.service"

    log "Creating systemd unit: $unit_file"
    cat > "$unit_file" <<EOF
[Unit]
Description=Apache Spark Master (standalone, single node)
After=network.target

[Service]
Type=forking
User=${svc_user}
Group=${svc_user}
Environment=SPARK_HOME=${spark_home}
Environment=SPARK_MASTER_PORT=${master_port}
Environment=SPARK_MASTER_WEBUI_PORT=${ui_port}
ExecStart=${spark_home}/sbin/start-master.sh
ExecStop=${spark_home}/sbin/stop-master.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable spark-master.service >> "$LOG_FILE" 2>&1
    ok "systemd service 'spark-master' created and enabled."
}

create_worker_service() {
    local svc_user="$1" spark_home="$2" master_ip="$3" master_port="$4" ui_port="$5"
    local unit_file="/etc/systemd/system/spark-worker.service"

    log "Creating systemd unit: $unit_file"
    cat > "$unit_file" <<EOF
[Unit]
Description=Apache Spark Worker (standalone, single node)
After=network.target spark-master.service
Requires=spark-master.service

[Service]
Type=forking
User=${svc_user}
Group=${svc_user}
Environment=SPARK_HOME=${spark_home}
Environment=SPARK_WORKER_WEBUI_PORT=${ui_port}
ExecStart=${spark_home}/sbin/start-worker.sh spark://${master_ip}:${master_port}
ExecStop=${spark_home}/sbin/stop-worker.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable spark-worker.service >> "$LOG_FILE" 2>&1
    ok "systemd service 'spark-worker' created and enabled."
}

wait_for_port() {
    local host="$1" port="$2" tries=30
    while [ $tries -gt 0 ]; do
        if (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
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

# ------------------------------------------------------------------
# 1. Interactive input (or env-var driven, see AUTOMATED above)
# ------------------------------------------------------------------
require_root
print_banner "Apache Spark - Standalone (single-node) Installation"
[ "$AUTOMATED" = "1" ] && log "Running in AUTOMATED (non-interactive) mode."

DEFAULT_SPARK_VERSION="4.0.3"
SPARK_VERSION=$(prompt_nonempty "Apache Spark version to install" "$DEFAULT_SPARK_VERSION" "${SPARK_VERSION:-}")

DEFAULT_HADOOP_VARIANT="hadoop3"
HADOOP_VARIANT=$(prompt_nonempty "Hadoop variant suffix (as published on dlcdn.apache.org)" "$DEFAULT_HADOOP_VARIANT" "${HADOOP_VARIANT:-}")

DEFAULT_BASE_DIR="/opt/ausiytic"
BASE_DIR=$(prompt_base_dir "Base volume/mount path to install under (e.g. /opt/mydata)" "$DEFAULT_BASE_DIR" "${BASE_DIR:-}")

DEFAULT_SVC_USER="spark"
SERVICE_USER=$(prompt_nonempty "OS user to run Spark as" "$DEFAULT_SVC_USER" "${SERVICE_USER:-}")

DETECTED_IP=$(detect_primary_ip)
[ -z "$DETECTED_IP" ] && DETECTED_IP="127.0.0.1"

MASTER_IP=$(prompt_ip "This node's IP address (master advertises here, worker connects here)" "$DETECTED_IP" "${MASTER_IP:-}")

DEFAULT_MASTER_PORT="7077"
MASTER_PORT=$(prompt_nonempty "Spark master RPC port" "$DEFAULT_MASTER_PORT" "${MASTER_PORT:-}")

DEFAULT_MASTER_UI_PORT="8080"
MASTER_UI_PORT=$(prompt_nonempty "Spark master web UI port" "$DEFAULT_MASTER_UI_PORT" "${MASTER_UI_PORT:-}")

DEFAULT_WORKER_UI_PORT="8081"
WORKER_UI_PORT=$(prompt_nonempty "Spark worker web UI port" "$DEFAULT_WORKER_UI_PORT" "${WORKER_UI_PORT:-}")

DEFAULT_WORKER_CORES="0"
WORKER_CORES=$(prompt_resource "Cores to give the worker" "$DEFAULT_WORKER_CORES" "${WORKER_CORES:-}")

DEFAULT_WORKER_MEMORY="0"
WORKER_MEMORY=$(prompt_resource "Memory to give the worker (e.g. 8g)" "$DEFAULT_WORKER_MEMORY" "${WORKER_MEMORY:-}")

# ------------------------------------------------------------------
# 2. Derived paths
# ------------------------------------------------------------------
SOURCE_DIR="${BASE_DIR}/softwares"
SPARK_HOME="${BASE_DIR}/apps/spark/binaries"
SPARK_DATA="${BASE_DIR}/apps/spark/data"
SPARK_LOGS="${BASE_DIR}/logs/spark"
SPARK_LOGS_SL="${BASE_DIR}/apps/spark/logs"
CRED_FILE="${BASE_DIR}/spark_standalone_summary.txt"

# ------------------------------------------------------------------
# 3. OS + dependencies
# ------------------------------------------------------------------
detect_os
install_deps

# ------------------------------------------------------------------
# 4. Directories & service user
# ------------------------------------------------------------------
log "Creating directory structure under $BASE_DIR ..."
mkdir -p "$SOURCE_DIR" "$SPARK_DATA" "$SPARK_LOGS"
ln -sfn "$SPARK_LOGS" "$SPARK_LOGS_SL"

ensure_service_user "$SERVICE_USER" "$BASE_DIR"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$BASE_DIR"

# ------------------------------------------------------------------
# 5. Download & install Spark (idempotent)
# ------------------------------------------------------------------
if [ -x "${SPARK_HOME}/bin/spark-submit" ]; then
    warn "Spark binaries already present at $SPARK_HOME/bin/spark-submit — skipping download/install."
else
    download_and_install_spark "$SPARK_VERSION" "$HADOOP_VARIANT" "$SOURCE_DIR" "$SPARK_HOME"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$SPARK_HOME"
fi

setup_env_profile "$SPARK_HOME"

# ------------------------------------------------------------------
# 6. Configure spark-env.sh
# ------------------------------------------------------------------
configure_spark_env "$SPARK_HOME" "$SPARK_DATA" "$SPARK_LOGS_SL" "$MASTER_IP" "$WORKER_CORES" "$WORKER_MEMORY"
chown -R "$SERVICE_USER":"$SERVICE_USER" "$SPARK_HOME" "$SPARK_DATA" "$SPARK_LOGS"

# ------------------------------------------------------------------
# 7. systemd services (master, then worker on top of it) + start
# ------------------------------------------------------------------
create_master_service "$SERVICE_USER" "$SPARK_HOME" "$MASTER_PORT" "$MASTER_UI_PORT"
log "Starting spark-master service..."
systemctl restart spark-master.service || die "Failed to start spark-master.service — check 'journalctl -u spark-master'"

if ! wait_for_port "$MASTER_IP" "$MASTER_PORT"; then
    die "Spark master did not open port ${MASTER_PORT} in time. Check ${SPARK_LOGS} and 'journalctl -u spark-master'."
fi
ok "Spark master is up — RPC on ${MASTER_IP}:${MASTER_PORT}, web UI on :${MASTER_UI_PORT}."

create_worker_service "$SERVICE_USER" "$SPARK_HOME" "$MASTER_IP" "$MASTER_PORT" "$WORKER_UI_PORT"
log "Starting spark-worker service..."
systemctl restart spark-worker.service || die "Failed to start spark-worker.service — check 'journalctl -u spark-worker'"
ok "Spark worker started, registering with local master at spark://${MASTER_IP}:${MASTER_PORT}."

# ------------------------------------------------------------------
# 8. Summary
# ------------------------------------------------------------------
{
    echo "====================================================================="
    echo " Apache Spark ${SPARK_VERSION} (${HADOOP_VARIANT}) — STANDALONE (single node: master + worker)"
    echo " Generated: $(date +'%F %T')"
    echo "====================================================================="
    echo "SPARK_HOME              : ${SPARK_HOME}"
    echo "Data dir                : ${SPARK_DATA}"
    echo "Log dir                 : ${SPARK_LOGS}"
    echo "OS service user         : ${SERVICE_USER}"
    echo "Systemd services        : spark-master.service, spark-worker.service"
    echo "Master RPC              : spark://${MASTER_IP}:${MASTER_PORT}"
    echo "Master web UI           : http://${MASTER_IP}:${MASTER_UI_PORT}"
    echo "Worker web UI           : http://${MASTER_IP}:${WORKER_UI_PORT}"
    echo "Worker cores            : ${WORKER_CORES} (0 = auto-detect, all cores)"
    echo "Worker memory           : ${WORKER_MEMORY} (0 = auto-detect, RAM minus 1GB)"
    echo "====================================================================="
} | tee "$CRED_FILE"
chown "$SERVICE_USER":"$SERVICE_USER" "$CRED_FILE"

print_banner "SPARK STANDALONE INSTALLATION COMPLETE"
echo "(Summary also saved to: $CRED_FILE)"
echo "Full install log: $LOG_FILE"
echo
echo "Try it out:"
echo "  su - ${SERVICE_USER} -s /bin/bash -c '${SPARK_HOME}/bin/spark-submit --master spark://${MASTER_IP}:${MASTER_PORT} --class org.apache.spark.examples.SparkPi ${SPARK_HOME}/examples/jars/spark-examples_*.jar 10'"

