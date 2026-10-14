#!/bin/bash
#================================================================
# DESCRIPTION
#   Fully automated Zookeeper 3.8.5 ENSEMBLE (cluster) installation
#   & service setup. Configures Zookeeper as a real multi-node
#   coordinator (server.1/2/3... entries), so it can be used as the
#   coordination layer for systems like Apache Druid or Patroni-
#   managed PostgreSQL.
#
#   OS-agnostic: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma, Fedora, SUSE.
#   Works whether invoked as root or as a normal user (uses sudo
#   automatically for steps that need elevated privileges).
#
#   IMPORTANT: This script must be run on EACH node that is part of
#   the ensemble. Give it the SAME list of ensemble hosts on every
#   node; each node will auto-detect its own position (myid) by
#   matching its local IP against that list (or you can set it
#   explicitly via MYID / the interactive prompt).
#
#   What it does:
#     1. Asks which disk/mount point to install on (or root volume /)
#     2. Asks for the ensemble host list + this node's ID
#     3. Detects OS/package manager and installs Java (if missing)
#     4. Downloads & extracts Apache Zookeeper 3.8.5
#     5. Creates directories, symlinks, myid, and zoo.cfg WITH
#        server.N=host:peerPort:electionPort ensemble entries
#     6. Opens client/peer/election ports on the firewall (best effort)
#     7. Creates & enables a systemd service (zookeeper.service)
#     8. Starts the service, verifies it's running, and prints the
#        client connection string for downstream systems (Druid,
#        Patroni, etc.)
#
#   Usage examples:
#     bash install_zookeeper.sh                     # fully interactive
#     bash install_zookeeper.sh /data                # disk via arg
#
#     Non-interactive (e.g. for automation across all nodes):
#     DISK_NAME=/data \
#     ZK_HOSTS="10.0.0.11,10.0.0.12,10.0.0.13" \
#     MYID=1 \
#     bash install_zookeeper.sh
#
# IMPLEMENTATION
#   Author  - EverestDx
#   Version - v4 (ensemble/cluster-aware, disk-agnostic, root/non-root, 3.8.5)
#================================================================

set -uo pipefail

#---------------------------------------------------------------
# 0. CONFIG / VARIABLES (override via environment before running)
#---------------------------------------------------------------
ZK_VERSION="${ZK_VERSION:-3.8.5}"
ZK_TARBALL="apache-zookeeper-${ZK_VERSION}-bin.tar.gz"
ZK_DOWNLOAD_URL="https://archive.apache.org/dist/zookeeper/zookeeper-${ZK_VERSION}/${ZK_TARBALL}"

APP_DIRNAME="ausiytic"     # subfolder created on the chosen disk
CLIENT_PORT="${CLIENT_PORT:-2181}"
PEER_PORT="${PEER_PORT:-2888}"
ELECTION_PORT="${ELECTION_PORT:-3888}"
TICK_TIME="${TICK_TIME:-2000}"
INIT_LIMIT="${INIT_LIMIT:-10}"
SYNC_LIMIT="${SYNC_LIMIT:-5}"

#---------------------------------------------------------------
# 1. ROOT / NON-ROOT HANDLING
#---------------------------------------------------------------
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        if ! sudo -v >/dev/null 2>&1; then
            echo "ERROR: This user does not have sudo privileges. Run as root or grant sudo access." >&2
            exit 1
        fi
    else
        echo "ERROR: Not running as root and 'sudo' is not installed/available. Run as root or install sudo." >&2
        exit 1
    fi
fi

#---------------------------------------------------------------
# 2. DISK / MOUNT POINT SELECTION
#---------------------------------------------------------------
DISK_INPUT="${1:-${DISK_NAME:-}}"

if [ -z "$DISK_INPUT" ]; then
    echo ""
    echo "Which disk/mount point should Zookeeper be installed on?"
    echo "Examples: /data   /apps   /mnt/disk1"
    read -rp "Press Enter to use the root volume (/) instead: " DISK_INPUT
    DISK_INPUT="${DISK_INPUT:-/}"
fi

if [ "$DISK_INPUT" != "/" ]; then
    DISK_INPUT="${DISK_INPUT%/}"
fi

if [ "$DISK_INPUT" = "/" ]; then
    INSTALL_ROOT="/${APP_DIRNAME}"
else
    INSTALL_ROOT="${DISK_INPUT}/${APP_DIRNAME}"
fi

SOURCE="${INSTALL_ROOT}/softwares"
ZOOKEEPER_BINARIES="${INSTALL_ROOT}/db/zookeeper/binaries"
ZOOKEEPER_DATA="${INSTALL_ROOT}/db/zookeeper/data"
ZOOKEEPER_LOG_SL="${INSTALL_ROOT}/db/zookeeper/logs"
ZOOKEEPER_LOG_DIR="${INSTALL_ROOT}/logs/zookeeper"

LOG_DIR="${INSTALL_ROOT}/logs/install"
ACCESS_LOG="${LOG_DIR}/zookeeper_install_access.log"
ERROR_LOG="${LOG_DIR}/zookeeper_install_error.log"

#---------------------------------------------------------------
# 3. HELPERS
#---------------------------------------------------------------
ensure_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        :
    elif [ -w "$(dirname "$dir")" ] 2>/dev/null; then
        mkdir -p "$dir" || { echo "Failed to create $dir" >&2; exit 1; }
    else
        $SUDO mkdir -p "$dir" || { echo "Failed to create $dir" >&2; exit 1; }
    fi
    if [ ! -w "$dir" ]; then
        $SUDO chown -R "${CURRENT_USER}:${CURRENT_GROUP}" "$dir" 2>/dev/null || true
    fi
}

ensure_dir "$LOG_DIR"
touch "$ACCESS_LOG" "$ERROR_LOG" 2>/dev/null || { $SUDO touch "$ACCESS_LOG" "$ERROR_LOG"; $SUDO chown "${CURRENT_USER}:${CURRENT_GROUP}" "$ACCESS_LOG" "$ERROR_LOG"; }

log()  { local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"; echo -e "[$ts] $*" | tee -a "$ACCESS_LOG"; }
err()  { local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"; echo -e "[$ts] ERROR: $*" | tee -a "$ERROR_LOG" >&2; }
die()  { err "$*"; exit 1; }

log "Selected install disk/mount point: ${DISK_INPUT}  ->  INSTALL_ROOT=${INSTALL_ROOT}"
log "Running as user: ${CURRENT_USER} (sudo mode: $( [ -n "$SUDO" ] && echo enabled || echo 'not needed, root' ))"

if [ "$DISK_INPUT" != "/" ] && [ ! -d "$DISK_INPUT" ]; then
    die "Disk/mount path '$DISK_INPUT' does not exist on this server. Please check and re-run with a valid path."
fi

#---------------------------------------------------------------
# 4. ENSEMBLE (CLUSTER) CONFIGURATION
#---------------------------------------------------------------
get_local_ips() {
    # Best-effort, works whether 'ip' or 'ifconfig' is available
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.'
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null
    fi
}

STANDALONE="${STANDALONE:-}"
ZK_HOSTS_RAW="${ZK_HOSTS:-}"

if [ -z "$ZK_HOSTS_RAW" ] && [ -z "$STANDALONE" ]; then
    echo ""
    echo "Enter the ensemble host list (IP or hostname of every Zookeeper node in the cluster),"
    echo "comma-separated, in the SAME order on every node. Example: 10.0.0.11,10.0.0.12,10.0.0.13"
    read -rp "Ensemble hosts (press Enter for a standalone test node, no IPs needed): " ZK_HOSTS_RAW
fi

if [ -z "$ZK_HOSTS_RAW" ]; then
    # ---- Standalone / test mode: no IPs, no ensemble entries ----
    STANDALONE="true"
    HOSTS_ARR=("localhost")
    NUM_HOSTS=1
    MYID=1
    log "No ensemble hosts given — running in STANDALONE (single-node test) mode on localhost."
else
    STANDALONE="false"
    # Parse into array, trimming whitespace
    IFS=',' read -ra HOSTS_ARR <<< "$ZK_HOSTS_RAW"
    for i in "${!HOSTS_ARR[@]}"; do
        HOSTS_ARR[$i]="$(echo "${HOSTS_ARR[$i]}" | xargs)"
    done
    NUM_HOSTS="${#HOSTS_ARR[@]}"
    log "Ensemble hosts (${NUM_HOSTS}): ${HOSTS_ARR[*]}"

    # Try to auto-detect this node's position by matching local IPs
    LOCAL_IPS="$(get_local_ips)"
    AUTO_ID=""
    for i in "${!HOSTS_ARR[@]}"; do
        for ip in $LOCAL_IPS; do
            if [ "${HOSTS_ARR[$i]}" = "$ip" ]; then
                AUTO_ID=$((i+1))
            fi
        done
    done

    MYID="${MYID:-}"
    if [ -z "$MYID" ]; then
        if [ -n "$AUTO_ID" ]; then
            read -rp "Detected this node as server.${AUTO_ID} in the ensemble. Press Enter to accept, or type a different ID (1-${NUM_HOSTS}): " MYID_INPUT
            MYID="${MYID_INPUT:-$AUTO_ID}"
        else
            read -rp "Could not auto-detect this node's position. Enter this node's ID in the ensemble (1-${NUM_HOSTS}): " MYID
        fi
    fi

    case "$MYID" in
        ''|*[!0-9]*) die "myid must be a number between 1 and ${NUM_HOSTS}." ;;
    esac
    if [ "$MYID" -lt 1 ] || [ "$MYID" -gt "$NUM_HOSTS" ]; then
        die "myid ($MYID) is out of range. Must be between 1 and ${NUM_HOSTS}."
    fi
    log "This node's myid: ${MYID} (${HOSTS_ARR[$((MYID-1))]})"
fi

#---------------------------------------------------------------
# 5. OS / PACKAGE MANAGER DETECTION
#---------------------------------------------------------------
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v yum >/dev/null 2>&1; then echo "yum"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper"
    elif command -v apk >/dev/null 2>&1; then echo "apk"
    else echo "unknown"
    fi
}

install_java() {
    if command -v java >/dev/null 2>&1; then
        log "Java already installed: $(java -version 2>&1 | head -n1)"
        return 0
    fi
    log "Java not found. Installing OpenJDK via detected package manager..."
    local pm; pm="$(detect_pkg_manager)"
    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            $SUDO apt-get update -y >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            $SUDO apt-get install -y default-jre-headless wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
                || $SUDO apt-get install -y openjdk-17-jre-headless wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            ;;
        dnf)
            $SUDO dnf install -y java-17-openjdk-headless wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
                || $SUDO dnf install -y java-11-openjdk-headless wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            ;;
        yum)
            $SUDO yum install -y java-11-openjdk-headless wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            ;;
        zypper)
            $SUDO zypper --non-interactive install java-17-openjdk-headless wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
                || $SUDO zypper --non-interactive install java-11-openjdk-headless wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            ;;
        apk)
            $SUDO apk add --no-cache openjdk17-jre-headless wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            ;;
        *)
            die "Unsupported/unknown package manager. Please install Java (OpenJDK 11+) manually and re-run."
            ;;
    esac
    command -v java >/dev/null 2>&1 || die "Java installation failed."
    log "Java installed successfully: $(java -version 2>&1 | head -n1)"
}

detect_java_home() {
    local java_bin java_real
    java_bin="$(command -v java)"
    java_real="$(readlink -f "$java_bin")"
    echo "${java_real%/bin/java}"
}

#---------------------------------------------------------------
# 6. FIREWALL (best effort, non-fatal)
#---------------------------------------------------------------
open_firewall_ports() {
    local ports=("$CLIENT_PORT")
    if [ "$STANDALONE" = "false" ]; then
        ports+=("$PEER_PORT" "$ELECTION_PORT")
    fi

    if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        log "Opening port(s) ${ports[*]}/tcp via ufw"
        for p in "${ports[@]}"; do $SUDO ufw allow "${p}/tcp" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"; done
    elif command -v firewall-cmd >/dev/null 2>&1 && $SUDO systemctl is-active --quiet firewalld 2>/dev/null; then
        log "Opening port(s) ${ports[*]}/tcp via firewalld"
        for p in "${ports[@]}"; do $SUDO firewall-cmd --permanent --add-port="${p}/tcp" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"; done
        $SUDO firewall-cmd --reload >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    else
        log "No active ufw/firewalld detected — skipping firewall changes (open port(s) ${ports[*]} manually if you use another firewall/security group)."
    fi
}

#---------------------------------------------------------------
# 7. MAIN INSTALL FLOW
#---------------------------------------------------------------
main() {
    log "===== Starting Zookeeper ${ZK_VERSION} ensemble node installation ====="

    install_java
    JAVA_HOME_DETECTED="$(detect_java_home)"
    export JAVA_HOME="$JAVA_HOME_DETECTED"
    log "Detected JAVA_HOME: $JAVA_HOME_DETECTED"

    ensure_dir "$SOURCE"
    ensure_dir "$ZOOKEEPER_BINARIES"
    ensure_dir "$ZOOKEEPER_DATA"
    ensure_dir "$ZOOKEEPER_LOG_DIR"

    cd "$SOURCE" || die "Cannot cd into $SOURCE"
    if [ -f "$ZK_TARBALL" ]; then
        log "$ZK_TARBALL already downloaded, skipping download."
    else
        log "Downloading Zookeeper ${ZK_VERSION}..."
        wget -q "$ZK_DOWNLOAD_URL" -O "$ZK_TARBALL" || die "Download failed from $ZK_DOWNLOAD_URL"
        log "Download complete."
    fi

    log "Creating symlink for Zookeeper logs"
    ln -sfn "$ZOOKEEPER_LOG_DIR" "$ZOOKEEPER_LOG_SL"

    log "Extracting Zookeeper tarball"
    tar -xzf "$ZK_TARBALL" -C "$SOURCE" || die "Extraction failed"

    EXTRACTED_DIR="${SOURCE}/apache-zookeeper-${ZK_VERSION}-bin"
    [ -d "$EXTRACTED_DIR" ] || die "Expected extracted directory not found: $EXTRACTED_DIR"

    log "Moving extracted files to binaries location: $ZOOKEEPER_BINARIES"
    cp -rf "$EXTRACTED_DIR"/* "$ZOOKEEPER_BINARIES"/ || die "Failed to move files to $ZOOKEEPER_BINARIES"

    # ---- zoo.cfg: base settings ----
    log "Configuring zoo.cfg"
    if [ ! -f "$ZOOKEEPER_BINARIES/conf/zoo.cfg" ]; then
        cp "$ZOOKEEPER_BINARIES/conf/zoo_sample.cfg" "$ZOOKEEPER_BINARIES/conf/zoo.cfg"
    fi

    set_cfg() {
        local key="$1" val="$2" file="$3"
        if grep -q "^${key}=" "$file"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$file"
        else
            echo "${key}=${val}" >> "$file"
        fi
    }

    ZCFG="$ZOOKEEPER_BINARIES/conf/zoo.cfg"
    set_cfg "dataDir" "$ZOOKEEPER_DATA" "$ZCFG"
    set_cfg "clientPort" "$CLIENT_PORT" "$ZCFG"
    set_cfg "tickTime" "$TICK_TIME" "$ZCFG"
    set_cfg "initLimit" "$INIT_LIMIT" "$ZCFG"
    set_cfg "syncLimit" "$SYNC_LIMIT" "$ZCFG"
    # Needed for external health checks (Druid/Patroni/monitoring use the 'mntr'/'ruok' 4-letter words)
    set_cfg "4lw.commands.whitelist" "mntr,conf,ruok,stat" "$ZCFG"

    # ---- zoo.cfg: ensemble server.N entries (skipped in standalone mode) ----
    sed -i '/^server\./d' "$ZCFG"
    if [ "$STANDALONE" = "false" ]; then
        log "Writing ensemble server entries to zoo.cfg"
        {
            for i in "${!HOSTS_ARR[@]}"; do
                id=$((i+1))
                echo "server.${id}=${HOSTS_ARR[$i]}:${PEER_PORT}:${ELECTION_PORT}"
            done
        } >> "$ZCFG"
    else
        log "Standalone mode: skipping ensemble server.N entries in zoo.cfg"
    fi

    if [ -f "$ZOOKEEPER_BINARIES/conf/log4j.properties" ]; then
        set_cfg "zookeeper.log.dir" "$ZOOKEEPER_LOG_SL" "$ZOOKEEPER_BINARIES/conf/log4j.properties"
    fi

    # ---- myid ----
    echo "$MYID" > "$ZOOKEEPER_DATA/myid"
    log "Set myid=$MYID at $ZOOKEEPER_DATA/myid"

    # ---- JAVA_HOME in zkEnv.sh ----
    ZKENV="$ZOOKEEPER_BINARIES/bin/zkEnv.sh"
    if [ -f "$ZKENV" ]; then
        if grep -q "^export JAVA_HOME=" "$ZKENV" 2>/dev/null; then
            sed -i "s|^export JAVA_HOME=.*|export JAVA_HOME=${JAVA_HOME_DETECTED}|" "$ZKENV"
        else
            sed -i "2i export JAVA_HOME=${JAVA_HOME_DETECTED}" "$ZKENV"
        fi
        log "JAVA_HOME set in zkEnv.sh"
    fi

    chmod +x "$ZOOKEEPER_BINARIES"/bin/*.sh

    open_firewall_ports

    # ---- systemd service ----
    log "Creating systemd service for Zookeeper"
    if [ "$STANDALONE" = "true" ]; then
        ZK_UNIT_DESC="Zookeeper Daemon (standalone test node)"
    else
        ZK_UNIT_DESC="Zookeeper Daemon (ensemble node ${MYID})"
    fi
    SERVICE_CONTENT="[Unit]
Description=${ZK_UNIT_DESC}
After=network.target

[Service]
Type=forking
Environment=JAVA_HOME=${JAVA_HOME_DETECTED}
WorkingDirectory=${ZOOKEEPER_BINARIES}
User=${CURRENT_USER}
ExecStart=${ZOOKEEPER_BINARIES}/bin/zkServer.sh start ${ZOOKEEPER_BINARIES}/conf/zoo.cfg
ExecStop=${ZOOKEEPER_BINARIES}/bin/zkServer.sh stop ${ZOOKEEPER_BINARIES}/conf/zoo.cfg
Restart=on-failure
TimeoutSec=30

[Install]
WantedBy=multi-user.target
"
    echo "$SERVICE_CONTENT" | $SUDO tee /etc/systemd/system/zookeeper.service > /dev/null \
        || die "Failed to write systemd unit file"

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable zookeeper.service >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    $SUDO systemctl restart zookeeper.service

    sleep 5
    if $SUDO systemctl is-active --quiet zookeeper.service; then
        log "Zookeeper service is active (systemd)."
    else
        err "Zookeeper service failed to start via systemd. Check: journalctl -u zookeeper -n 50"
        $SUDO systemctl status zookeeper.service --no-pager >> "$ERROR_LOG" 2>&1
        die "Installation completed but service is not running. See $ERROR_LOG"
    fi

    STATUS_OUT="$("$ZOOKEEPER_BINARIES/bin/zkServer.sh" status 2>&1)"
    log "zkServer.sh status output: ${STATUS_OUT}"

    if echo "$STATUS_OUT" | grep -qi "Mode:"; then
        log "===== Zookeeper ${ZK_VERSION} installed and RUNNING ====="
    elif [ "$STANDALONE" = "false" ]; then
        err "zkServer.sh status did not report a Mode. Once ALL ensemble nodes are running this should resolve (leader election needs a quorum). Please check again after installing the remaining nodes."
    else
        err "zkServer.sh status did not report a Mode. Check: journalctl -u zookeeper -n 50"
    fi

    echo ""
    echo "================================================================"
    if [ "$STANDALONE" = "true" ]; then
        echo " Zookeeper STANDALONE test node configured."
        echo " Install root : ${INSTALL_ROOT}"
        echo " Client port  : ${CLIENT_PORT}"
        echo ""
        echo " Quick test:"
        echo "   ${ZOOKEEPER_BINARIES}/bin/zkCli.sh -server localhost:${CLIENT_PORT}"
        echo ""
        echo " Point test clients (Druid/Patroni/etc.) at:"
        echo "   localhost:${CLIENT_PORT}"
        echo ""
        echo " Note: this is a single-node instance with no fault tolerance —"
        echo " fine for testing, but re-run with ZK_HOSTS set to a real host"
        echo " list when you're ready to build a production ensemble."
    else
        # Build the client connection string for downstream systems
        CONN_STRING=""
        for h in "${HOSTS_ARR[@]}"; do
            CONN_STRING="${CONN_STRING}${h}:${CLIENT_PORT},"
        done
        CONN_STRING="${CONN_STRING%,}"

        echo " Zookeeper ensemble node ${MYID} of ${NUM_HOSTS} configured."
        echo " Install root : ${INSTALL_ROOT}"
        echo " This node    : ${HOSTS_ARR[$((MYID-1))]}  (client:${CLIENT_PORT} peer:${PEER_PORT} election:${ELECTION_PORT})"
        echo ""
        echo " Run this SAME script (same ZK_HOSTS list) on the other $((NUM_HOSTS-1)) node(s):"
        for i in "${!HOSTS_ARR[@]}"; do
            [ $((i+1)) -eq "$MYID" ] && continue
            echo "   -> ${HOSTS_ARR[$i]}  (myid $((i+1)))"
        done
        echo ""
        echo " Once all nodes are up, point Druid / Patroni / other clients at:"
        echo "   ${CONN_STRING}"
    fi
    echo "================================================================"
}

main

