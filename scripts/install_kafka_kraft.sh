#!/bin/bash
#================================================================
# DESCRIPTION
#   Fully automated installer for Apache Kafka running in native
#   KRaft mode (NO ZooKeeper), wired up as a systemd service.
#
#   Version installed:
#       kafka   : 3.9.0 (Scala 2.13 build)
#
#   Compatible with:
#       RHEL / CentOS / Rocky / AlmaLinux / Fedora / Amazon Linux (yum/dnf)
#       Debian / Ubuntu (apt-get)
#
#   Handles automatically:
#       - Root vs sudo execution
#       - Root volume ('/') as a valid base directory
#       - Java (OpenJDK) install if missing
#       - KRaft storage formatting (idempotent -- only formats once,
#         detects an already-formatted log dir and skips it)
#       - A single-node combined broker+controller KRaft quorum
#         (the simplest topology; see NOTES at the bottom for how
#         to extend to a multi-node controller quorum)
#       - Best-effort SELinux labeling on RHEL-family systems
#       - firewalld port opening (broker + controller ports), if
#         firewalld is active
#
#   Usage:
#       chmod +x install_kafka_kraft.sh
#       sudo ./install_kafka_kraft.sh
#       (or run directly as root; script will ask for the base
#        install directory, e.g. /opt/ausiytic)
#
#   NOTE ON VERSION:
#       KAFKA_VERSION / SCALA_VERSION are declared as variables
#       right below -- bump KAFKA_VERSION if you want a newer
#       release; the download URL is derived automatically.
#       Kafka 4.0+ dropped ZooKeeper support entirely (KRaft-only)
#       and requires Java 17+; this script defaults to the 3.9.x
#       line (Java 11+ is sufficient) for the widest compatibility,
#       but works with 4.x too as long as JAVA_PKG below is bumped
#       to a 17+ package for your distro.
#================================================================
# IMPLEMENTATION NOTES (mirrors the httpd installer's approach)
#   - Idempotent at every stage: re-running after a partial/failed
#     run should pick up where it left off rather than redoing
#     completed work or corrupting an already-formatted log dir.
#   - Full stdout/stderr of every long-running step is captured to
#     dated access/error logs instead of being left to scroll past
#     or get swallowed, so a failure has a paper trail.
#   - Config generation only ever appends/replaces specific known
#     keys (idempotent sed), never blindly appends duplicates on
#     re-run.
#   - KRaft storage format is the single most dangerous idempotency
#     hazard here: running `kafka-storage.sh format` twice against
#     a log dir that already has data will refuse (and rightly so),
#     but running it against a *fresh* dir that a previous partial
#     run already formatted-and-abandoned needs to be detected, not
#     blindly re-attempted. We detect this via meta.properties.
#================================================================

set -euo pipefail

# ---------------------------------------------------------------
# 0. Versions & constants
# ---------------------------------------------------------------
KAFKA_VERSION="3.9.0"
SCALA_VERSION="2.13"

KAFKA_TARBALL="kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
KAFKA_URL="https://downloads.apache.org/kafka/${KAFKA_VERSION}/${KAFKA_TARBALL}"
# Archive mirror fallback (Apache moves old releases to the archive)
KAFKA_URL_ARCHIVE="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${KAFKA_TARBALL}"

BROKER_PORT="9092"
CONTROLLER_PORT="9093"

LOGTIME=$(date +"%F %T")
FILENAME=$(date +"%d%m%Y%H")
SCRIPT_PWD=$(pwd)
ACCESS_LOG="${SCRIPT_PWD}/kafka_install.access.${FILENAME}.log"
ERROR_LOG="${SCRIPT_PWD}/kafka_install.error.${FILENAME}.log"

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

# ---------------------------------------------------------------
# 1. Root / sudo detection
# ---------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
    echo "Running as root."
else
    if ! command -v sudo >/dev/null 2>&1; then
        die "Not running as root and 'sudo' is not installed. Re-run this script as root, or install sudo first."
    fi
    if ! sudo -n true 2>/dev/null; then
        echo "This script needs sudo privileges (for package installs & service setup)."
        echo "You may be prompted for your password."
    fi
    SUDO="sudo"
fi

# ---------------------------------------------------------------
# 2. Ask user for the base directory + KRaft identifiers
# ---------------------------------------------------------------
read -rp "Enter base install directory (e.g. /opt/ausiytic, or / for root volume): " BASE_DIR

if [[ -z "$BASE_DIR" ]]; then
    die "Base directory cannot be empty."
fi

if [[ "$BASE_DIR" == "/" ]]; then
    BASE_DIR=""
    BASE_DIR_DISPLAY="/"
else
    BASE_DIR="${BASE_DIR%/}"
    [[ -z "$BASE_DIR" ]] && die "Base directory cannot be empty."
    BASE_DIR_DISPLAY="$BASE_DIR"
fi

read -rp "Node ID for this broker/controller [1]: " NODE_ID_INPUT
NODE_ID="${NODE_ID_INPUT:-1}"

read -rp "Advertised hostname/IP clients will use to reach this broker [$(hostname -I 2>/dev/null | awk '{print $1}')]: " ADVERTISED_HOST_INPUT
DEFAULT_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
ADVERTISED_HOST="${ADVERTISED_HOST_INPUT:-${DEFAULT_HOST:-localhost}}"

echo
echo "The following directories will be created/used under: $BASE_DIR_DISPLAY"
echo "  Source          : $BASE_DIR/softwares"
echo "  Kafka binaries  : $BASE_DIR/apps/kafka/binaries"
echo "  Kafka data/logs : $BASE_DIR/apps/kafka/data"
echo "  Service logs    : $BASE_DIR/logs/kafka"
echo
echo "KRaft topology   : single-node combined broker+controller"
echo "  node.id         : $NODE_ID"
echo "  broker port     : $BROKER_PORT"
echo "  controller port : $CONTROLLER_PORT"
echo "  advertised host : $ADVERTISED_HOST"
echo
if [[ "$BASE_DIR_DISPLAY" == "/" ]]; then
    echo "WARNING: You've chosen the root volume ('/'). This will create top-level"
    echo "         directories like /softwares, /apps, /logs directly under /."
fi
read -rp "Proceed with installation? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------
# 3. Derived paths
# ---------------------------------------------------------------
SOURCE="$BASE_DIR/softwares"
KAFKA_BINARIES="$BASE_DIR/apps/kafka/binaries"
KAFKA_DATA="$BASE_DIR/apps/kafka/data"
KAFKA_METADATA_DIR="$KAFKA_DATA/kraft-combined-logs"
KAFKA_LOGS="$BASE_DIR/logs/kafka"
KAFKA_LOGS_SL="$KAFKA_BINARIES/logs"
SERVER_PROPERTIES="$KAFKA_BINARIES/config/kraft/server.properties"
CLUSTER_ID_FILE="$BASE_DIR/apps/kafka/.cluster_id"

mkdir -p "$SOURCE" "$KAFKA_BINARIES" "$KAFKA_DATA" "$KAFKA_METADATA_DIR" "$KAFKA_LOGS"
log "Directories ensured under $BASE_DIR_DISPLAY"

if [[ -L "$KAFKA_LOGS_SL" || -e "$KAFKA_LOGS_SL" ]]; then
    log "$KAFKA_LOGS_SL already exists, skipping symlink creation"
else
    ln -sn "$KAFKA_LOGS" "$KAFKA_LOGS_SL"
    log "Created symlink $KAFKA_LOGS_SL -> $KAFKA_LOGS"
fi

# ---------------------------------------------------------------
# 4. Detect OS / package manager and install dependencies (Java)
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

if command -v java >/dev/null 2>&1; then
    log "Java already present: $(java -version 2>&1 | head -n1)"
else
    log "Java not found -- installing OpenJDK (this may take a few minutes)..."
    case "$PKG_MGR" in
        yum|dnf)
            $SUDO "$PKG_MGR" install -y java-11-openjdk wget tar which \
                >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
                || die "Java installation failed. See $ERROR_LOG"
            ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            $SUDO apt-get update -y >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            $SUDO apt-get install -y openjdk-11-jre-headless wget tar \
                >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
                || die "Java installation failed. See $ERROR_LOG"
            ;;
    esac
    log "Java installed: $(java -version 2>&1 | head -n1)"
fi

JAVA_HOME_DETECTED="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
log "Using JAVA_HOME=$JAVA_HOME_DETECTED"

# ---------------------------------------------------------------
# 5. Download & extract Kafka
# ---------------------------------------------------------------
if [[ -x "$KAFKA_BINARIES/bin/kafka-server-start.sh" ]]; then
    log "Kafka already installed at $KAFKA_BINARIES, skipping download/extract"
else
    log "Downloading Kafka $KAFKA_VERSION"
    cd "$SOURCE"
    if ! wget -N "$KAFKA_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"; then
        warn "Primary download URL failed, retrying against the Apache archive mirror"
        wget -N "$KAFKA_URL_ARCHIVE" -O "$KAFKA_TARBALL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || die "Failed to download Kafka from both $KAFKA_URL and $KAFKA_URL_ARCHIVE"
    fi
    log "Extracting Kafka into $KAFKA_BINARIES"
    tar -xzf "$KAFKA_TARBALL" -C "$SOURCE" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    EXTRACTED_DIR="$SOURCE/kafka_${SCALA_VERSION}-${KAFKA_VERSION}"
    [[ -d "$EXTRACTED_DIR" ]] || die "Expected extracted directory $EXTRACTED_DIR not found after tar -xzf"
    # Copy rather than move so re-running with a fresh SOURCE tarball
    # never fights over an already-moved directory.
    cp -a "$EXTRACTED_DIR"/. "$KAFKA_BINARIES"/
    log "Kafka $KAFKA_VERSION installed to $KAFKA_BINARIES"
fi

# ---------------------------------------------------------------
# 6. Generate server.properties for KRaft (combined broker+controller)
# ---------------------------------------------------------------
[[ -f "$SERVER_PROPERTIES" ]] || die "Template kraft/server.properties not found at $SERVER_PROPERTIES -- check the Kafka distribution layout for this version."

log "Backing up original kraft/server.properties (first run only)"
[[ -f "${SERVER_PROPERTIES}.orig" ]] || cp "$SERVER_PROPERTIES" "${SERVER_PROPERTIES}.orig"

set_property() {
    local key="$1" value="$2"
    if grep -q "^[[:space:]]*${key}=" "$SERVER_PROPERTIES"; then
        sed -i "s#^[[:space:]]*${key}=.*#${key}=${value}#" "$SERVER_PROPERTIES"
    else
        echo "${key}=${value}" >> "$SERVER_PROPERTIES"
    fi
}

log "Writing KRaft server.properties"
set_property "process.roles" "broker,controller"
set_property "node.id" "$NODE_ID"
set_property "controller.quorum.voters" "${NODE_ID}@localhost:${CONTROLLER_PORT}"
set_property "listeners" "PLAINTEXT://0.0.0.0:${BROKER_PORT},CONTROLLER://0.0.0.0:${CONTROLLER_PORT}"
set_property "advertised.listeners" "PLAINTEXT://${ADVERTISED_HOST}:${BROKER_PORT}"
set_property "controller.listener.names" "CONTROLLER"
set_property "inter.broker.listener.name" "PLAINTEXT"
set_property "listener.security.protocol.map" "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT"
set_property "log.dirs" "$KAFKA_METADATA_DIR"
set_property "num.partitions" "3"
set_property "group.initial.rebalance.delay.ms" "0"

log "server.properties written to $SERVER_PROPERTIES"

# ---------------------------------------------------------------
# 7. Generate/reuse cluster ID and format KRaft storage
#
#    kafka-storage.sh format is NOT safely re-runnable against a
#    dir that already has metadata -- it will refuse, which is
#    correct, but we still need to (a) reuse the same cluster ID
#    across re-runs of this script rather than minting a new one
#    every time, and (b) detect "already formatted" ourselves so a
#    re-run doesn't even attempt it and rely on kafka-storage.sh's
#    own refusal as the only safety net.
# ---------------------------------------------------------------
export JAVA_HOME="$JAVA_HOME_DETECTED"

if [[ -f "$CLUSTER_ID_FILE" ]]; then
    CLUSTER_ID=$(cat "$CLUSTER_ID_FILE")
    log "Reusing existing cluster ID from $CLUSTER_ID_FILE: $CLUSTER_ID"
else
    CLUSTER_ID=$("$KAFKA_BINARIES/bin/kafka-storage.sh" random-uuid)
    echo "$CLUSTER_ID" > "$CLUSTER_ID_FILE"
    log "Generated new cluster ID: $CLUSTER_ID (saved to $CLUSTER_ID_FILE)"
fi

if [[ -f "$KAFKA_METADATA_DIR/meta.properties" ]]; then
    log "KRaft storage already formatted at $KAFKA_METADATA_DIR (meta.properties present), skipping format"
else
    log "Formatting KRaft storage at $KAFKA_METADATA_DIR"
    "$KAFKA_BINARIES/bin/kafka-storage.sh" format \
        -t "$CLUSTER_ID" \
        -c "$SERVER_PROPERTIES" \
        --ignore-formatted \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || die "kafka-storage.sh format failed. See $ERROR_LOG"
    log "KRaft storage formatted"
fi

# ---------------------------------------------------------------
# 7b. SELinux handling (RHEL-family systems only, best-effort)
#
#     Unlike httpd, there is no widely-shipped dedicated SELinux
#     policy module for Kafka, so there is no equivalent of
#     httpd_exec_t to target. The java binary itself keeps running
#     as whatever domain launched it (commonly unconfined_service_t
#     or init_t under systemd with the default policy), so a custom
#     install path under a non-standard base dir generally does NOT
#     hit the same class of AVC denial the httpd install does. This
#     section is intentionally conservative: it only restores
#     default contexts on the custom paths (harmless no-op if
#     nothing is blocked) and logs a clear pointer to `ausearch -m
#     avc -ts recent` if the service still fails to start below,
#     rather than guessing at specific policy types.
# ---------------------------------------------------------------
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    log "SELinux is Enforcing -- applying default contexts to custom Kafka paths (best-effort)"
    $SUDO restorecon -Rv "$KAFKA_BINARIES" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    $SUDO restorecon -Rv "$KAFKA_DATA" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    $SUDO restorecon -Rv "$KAFKA_LOGS" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    log "If the service fails to start below and journalctl shows no clear cause, run:" 
    log "  sudo ausearch -m avc -ts recent"
    log "and label the reported path/type with 'sudo semanage fcontext -a ...' + restorecon."
else
    log "SELinux not enforcing (or not present) -- skipping SELinux context setup"
fi

# ---------------------------------------------------------------
# 7c. firewalld: open broker + controller ports, if active
# ---------------------------------------------------------------
if command -v firewall-cmd >/dev/null 2>&1 && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    log "firewalld is active -- opening ports ${BROKER_PORT}/tcp and ${CONTROLLER_PORT}/tcp"
    $SUDO firewall-cmd --permanent --add-port="${BROKER_PORT}/tcp" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    $SUDO firewall-cmd --permanent --add-port="${CONTROLLER_PORT}/tcp" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    $SUDO firewall-cmd --reload >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    log "firewalld rules applied"
else
    log "firewalld not active/present -- skipping firewall configuration"
fi

# ---------------------------------------------------------------
# 8. Ownership
# ---------------------------------------------------------------
RUN_USER="$(logname 2>/dev/null || echo "$SUDO_USER")"
RUN_USER="${RUN_USER:-$(whoami)}"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"

log "Setting ownership of $BASE_DIR/apps/kafka and $KAFKA_LOGS to ${RUN_USER}:${RUN_GROUP}"
$SUDO chown -R "${RUN_USER}:${RUN_GROUP}" "$BASE_DIR/apps/kafka" "$KAFKA_LOGS" \
    || warn "chown failed -- the service will still run fine as root/whatever user starts it, but files under $BASE_DIR/apps/kafka may not be owned by $RUN_USER"

# ---------------------------------------------------------------
# 9. Create systemd service and enable/start it
# ---------------------------------------------------------------
KAFKA_SERVICE="/etc/systemd/system/kafka.service"

log "Creating systemd service for Kafka"
$SUDO bash -c "cat > '$KAFKA_SERVICE'" <<EOF
[Unit]
Description=Apache Kafka (KRaft mode, no ZooKeeper)
After=network.target remote-fs.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
Environment=JAVA_HOME=${JAVA_HOME_DETECTED}
Environment=KAFKA_HEAP_OPTS=-Xmx1G -Xms1G
ExecStart=${KAFKA_BINARIES}/bin/kafka-server-start.sh ${SERVER_PROPERTIES}
ExecStop=${KAFKA_BINARIES}/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

log "systemd service file written to $KAFKA_SERVICE"

$SUDO systemctl daemon-reload
log "systemd daemon reloaded"

$SUDO systemctl enable kafka.service >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
log "kafka.service enabled for boot"

if ! $SUDO systemctl restart kafka.service; then
    {
        echo "---- systemctl status kafka.service ----"
        $SUDO systemctl status kafka.service --no-pager -l 2>&1
        echo "---- journalctl -xeu kafka.service (untruncated) ----"
        $SUDO journalctl -xeu kafka.service --no-pager -n 80 -o cat 2>&1
    } | tee -a "$ERROR_LOG"
    die "Failed to start kafka.service. Full diagnostics captured above and in $ERROR_LOG."
fi
log "kafka.service started"

# ---------------------------------------------------------------
# 10. Verify
# ---------------------------------------------------------------
log "Waiting for the broker port to come up..."
UP=0
for i in $(seq 1 15); do
    if (exec 3<>/dev/tcp/127.0.0.1/"$BROKER_PORT") 2>/dev/null; then
        exec 3<&- 3>&-
        UP=1
        break
    fi
    sleep 2
done

if [[ "$UP" -eq 1 ]] && systemctl is-active --quiet kafka.service; then
    log "SUCCESS: Kafka (KRaft mode) is up and listening on port $BROKER_PORT."
    echo
    echo "=================================================================="
    echo " Apache Kafka $KAFKA_VERSION (KRaft mode, no ZooKeeper) is running."
    echo " Binaries      : $KAFKA_BINARIES"
    echo " Config        : $SERVER_PROPERTIES"
    echo " Metadata/logs : $KAFKA_METADATA_DIR"
    echo " Service logs  : $KAFKA_LOGS_SL  (symlink -> $KAFKA_LOGS)"
    echo " Cluster ID    : $CLUSTER_ID"
    echo " Broker        : ${ADVERTISED_HOST}:${BROKER_PORT}"
    echo " Service       : systemctl status kafka"
    echo
    echo " Quick test:"
    echo "   ${KAFKA_BINARIES}/bin/kafka-topics.sh --bootstrap-server ${ADVERTISED_HOST}:${BROKER_PORT} --create --topic test --partitions 1 --replication-factor 1"
    echo "   ${KAFKA_BINARIES}/bin/kafka-topics.sh --bootstrap-server ${ADVERTISED_HOST}:${BROKER_PORT} --list"
    echo "=================================================================="
else
    die "kafka.service is active=$(systemctl is-active kafka.service 2>&1 || true) but the broker port never came up. Check $KAFKA_LOGS/server.log and 'journalctl -u kafka'."
fi

# ---------------------------------------------------------------
# NOTES: extending beyond a single node
# ---------------------------------------------------------------
# This script sets up ONE node acting as both broker and
# controller (process.roles=broker,controller) -- the simplest
# KRaft topology and a fine default for dev/test or a small
# single-box deployment.
#
# For a real multi-node cluster you'd instead:
#   1. Run this script (or a dedicated controller-only variant with
#      process.roles=controller) on each node with a DIFFERENT
#      NODE_ID.
#   2. Set the SAME cluster ID (CLUSTER_ID_FILE contents) on every
#      node before formatting storage -- all nodes in one cluster
#      must format with the identical -t <cluster-id>.
#   3. Set controller.quorum.voters on EVERY node to the FULL list
#      of all controller nodes, e.g.:
#        controller.quorum.voters=1@host1:9093,2@host2:9093,3@host3:9093
#      (this single script only ever writes a one-voter list).
#   4. Point advertised.listeners at each node's own reachable
#      hostname/IP.

