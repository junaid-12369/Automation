#!/usr/bin/env bash
#############################################################################
# install_nifi.sh
#
# Fully automated Apache NiFi installation script.
# - Works on RHEL/CentOS/Rocky/Alma (yum/dnf) and Ubuntu/Debian (apt)
# - Prompts for the disk/mount point to install under (accepts "/" too)
# - Installs prerequisites (java, wget, unzip, curl)
# - Downloads + installs NiFi, configures repository paths, JVM heap
# - Creates and enables a systemd service for NiFi
# - Downloads the NiFi Toolkit and generates TLS certs (keystore/truststore)
# - Prompts whether nifi.web.proxy.host should register the public IP,
#   private IP, both, or a custom hostname/DNS name - then writes it into
#   nifi.properties automatically (fixes the "invalid host header" error)
# - Re-applies repo/JVM/proxy-host config after the toolkit overwrites
#   nifi.properties
# - Downloads and installs the PostgreSQL JDBC driver
# - Sets the single-user login username/password
# - Starts NiFi and prints the login URL
#
# Usage:
#   sudo ./install_nifi.sh
#
# Optional overrides (env vars), all have sensible defaults:
#   NIFI_VERSION=1.28.1
#   TOOLKIT_VERSION=1.28.1
#   POSTGRES_JAR_VERSION=42.7.3
#   NIFI_XMS=2g
#   NIFI_XMX=2g
#   NIFI_SERVICE_USER=root
#   NIFI_SERVICE_GROUP=root
#   NIFI_HTTPS_PORT=9443
#############################################################################

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults / overridable variables
# ---------------------------------------------------------------------------
NIFI_VERSION="${NIFI_VERSION:-1.28.1}"
TOOLKIT_VERSION="${TOOLKIT_VERSION:-1.28.1}"
POSTGRES_JAR_VERSION="${POSTGRES_JAR_VERSION:-42.7.3}"
NIFI_XMS="${NIFI_XMS:-2g}"
NIFI_XMX="${NIFI_XMX:-2g}"
NIFI_SERVICE_USER="${NIFI_SERVICE_USER:-root}"
NIFI_SERVICE_GROUP="${NIFI_SERVICE_GROUP:-root}"
NIFI_HTTPS_PORT="${NIFI_HTTPS_PORT:-9443}"

LOG_FILE="/tmp/install_nifi_$(date +%Y%m%d%H%M%S).log"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo -e "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"; }
die()  { echo -e "[$(date +'%F %T')] ERROR: $*" | tee -a "$LOG_FILE" >&2; exit 1; }

trap 'die "Script failed at line $LINENO. See $LOG_FILE for details."' ERR

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (or via sudo)."
    fi
}

# ---------------------------------------------------------------------------
# OS / package manager detection
# ---------------------------------------------------------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID,,}"
        OS_ID_LIKE="${ID_LIKE,,:-}"
    else
        die "Cannot detect OS: /etc/os-release not found."
    fi

    if command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
        OS_FAMILY="rhel"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
        OS_FAMILY="rhel"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt-get"
        OS_FAMILY="debian"
    else
        die "Unsupported OS: no dnf/yum/apt-get found."
    fi

    log "Detected OS: $OS_ID (family: $OS_FAMILY, package manager: $PKG_MGR)"
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
install_prereqs() {
    log "Installing prerequisites (wget, unzip, curl, tar, java) ..."
    if [ "$OS_FAMILY" = "rhel" ]; then
        $PKG_MGR install -y wget unzip curl tar java-11-openjdk java-11-openjdk-devel >>"$LOG_FILE" 2>&1
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >>"$LOG_FILE" 2>&1
        apt-get install -y wget unzip curl tar openjdk-11-jdk >>"$LOG_FILE" 2>&1
    fi
    log "Prerequisites installed."
}

detect_java_home() {
    local java_bin
    java_bin="$(readlink -f "$(command -v java)")" || die "Java not found after install."
    JAVA_HOME="${java_bin%/bin/java}"
    log "Using JAVA_HOME=$JAVA_HOME"
}

# ---------------------------------------------------------------------------
# Disk / base directory prompt
# ---------------------------------------------------------------------------
prompt_disk() {
    echo
    read -rp "Enter the base path to install NiFi under (e.g. /opt/ausiytic, /data/ausiytic, or / for root volume): " DISK_MOUNT
    [ -z "$DISK_MOUNT" ] && die "Base path cannot be empty."

    # Use exactly what was entered - no directory name is appended.
    # "/" is a special case: strip it to "" so paths become /softwares, /apps
    # instead of //softwares, //apps.
    if [ "$DISK_MOUNT" = "/" ]; then
        BASE_DIR=""
    else
        BASE_DIR="${DISK_MOUNT%/}"
        [ -d "$BASE_DIR" ] || die "Path '$BASE_DIR' does not exist on this server. Create/mount it first, then re-run."
    fi
    log "NiFi will be installed under: ${BASE_DIR:-/} (software -> ${BASE_DIR}/softwares, apps -> ${BASE_DIR}/apps)"
}

# ---------------------------------------------------------------------------
# Credentials prompt
# ---------------------------------------------------------------------------
prompt_credentials() {
    echo
    read -rp "Enter NiFi login username to create: " NIFI_ADMIN_USER
    [ -z "$NIFI_ADMIN_USER" ] && die "Username cannot be empty."

    while true; do
        read -rsp "Enter NiFi login password (min 12 characters): " NIFI_ADMIN_PASS
        echo
        if [ "${#NIFI_ADMIN_PASS}" -lt 12 ]; then
            echo "Password must be at least 12 characters. Try again."
            continue
        fi
        read -rsp "Confirm password: " NIFI_ADMIN_PASS_CONFIRM
        echo
        if [ "$NIFI_ADMIN_PASS" != "$NIFI_ADMIN_PASS_CONFIRM" ]; then
            echo "Passwords do not match. Try again."
            continue
        fi
        break
    done
}

# ---------------------------------------------------------------------------
# Network info (private IP + public IP)
# ---------------------------------------------------------------------------
get_ec2_metadata() {
    # IMDSv2 with IMDSv1 fallback; silent/short-timeout so it's harmless off-EC2
    local path="$1"
    local token
    token=$(curl -s --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
    if [ -n "$token" ]; then
        curl -s --max-time 2 -H "X-aws-ec2-metadata-token: $token" \
            "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null || true
    else
        curl -s --max-time 2 "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null || true
    fi
}

detect_network() {
    HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"

    IP_ADDRESS="$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)"
    [ -z "$IP_ADDRESS" ] && IP_ADDRESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "$IP_ADDRESS" ] && die "Could not auto-detect an IPv4 address."

    # Prefer EC2 metadata for private/public IP (accurate behind ENIs/NAT),
    # fall back to what we already detected / a public IP lookup service.
    PRIVATE_IP="$(get_ec2_metadata "local-ipv4")"
    [ -z "$PRIVATE_IP" ] && PRIVATE_IP="$IP_ADDRESS"

    PUBLIC_IP="$(get_ec2_metadata "public-ipv4")"
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP="$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
    fi

    log "Hostname: $HOST_SHORT | Private IP: $PRIVATE_IP | Public IP: ${PUBLIC_IP:-<not detected>}"
}

# ---------------------------------------------------------------------------
# nifi.web.proxy.host prompt
#
# NiFi rejects any Host header that isn't in nifi.web.proxy.host, which is
# empty by default. This asks the operator which address(es) clients will
# use to reach the UI and builds the correct "host:port,host" value so the
# "System Error - invalid host header" page never comes up after install.
# ---------------------------------------------------------------------------
prompt_proxy_host() {
    echo
    echo "NiFi only accepts requests whose Host header is listed in nifi.web.proxy.host."
    echo "Which address(es) will be used to reach the NiFi UI?"
    echo "  1) Public IP   (${PUBLIC_IP:-not detected})   - accessing over the internet"
    echo "  2) Private IP  (${PRIVATE_IP:-not detected})  - accessing only within the VPC/LAN"
    echo "  3) Both public and private"
    echo "  4) Custom hostname/DNS name (e.g. a load balancer or Route53 record)"
    local choice
    read -rp "Enter choice [1-4] (default: 1): " choice
    choice="${choice:-1}"

    PROXY_HOSTS=()
    case "$choice" in
        1)
            [ -z "$PUBLIC_IP" ] && die "Public IP could not be detected. Re-run and choose option 4 with a custom hostname."
            PROXY_HOSTS+=("$PUBLIC_IP")
            ;;
        2)
            PROXY_HOSTS+=("$PRIVATE_IP")
            ;;
        3)
            [ -n "$PUBLIC_IP" ] && PROXY_HOSTS+=("$PUBLIC_IP")
            PROXY_HOSTS+=("$PRIVATE_IP")
            ;;
        4)
            local custom_host
            read -rp "Enter the custom hostname/DNS name: " custom_host
            [ -z "$custom_host" ] && die "Custom hostname cannot be empty."
            PROXY_HOSTS+=("$custom_host")
            ;;
        *)
            die "Invalid choice: $choice"
            ;;
    esac

    local values=()
    for h in "${PROXY_HOSTS[@]}"; do
        values+=("${h}:${NIFI_HTTPS_PORT}")
        values+=("${h}")
    done
    PROXY_HOST_VALUE=$(IFS=,; echo "${values[*]}")
    log "nifi.web.proxy.host will be set to: $PROXY_HOST_VALUE"
}

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
setup_paths() {
    SOURCE="$BASE_DIR/softwares"
    NIFI_LOG_DIR="$BASE_DIR/logs/nifi"
    NIFI_LOG_SL="$BASE_DIR/apps/nifi/logs"
    NIFI_BINARIES="$BASE_DIR/apps/nifi/binaries"
    NIFI_DATA="$BASE_DIR/apps/nifi/data"
    NIFI_FLOWFILE_REPO="$NIFI_DATA/flowfile_repository"
    NIFI_CONTENT_REPO="$NIFI_DATA/content_repository"
    NIFI_DATABASE_REPO="$NIFI_DATA/database_repository"
    NIFI_PROVENANCE_REPO="$NIFI_DATA/provenance_repository"
    NIFI_STATE_REPO="$NIFI_DATA/state"
    NIFI_TOOLKIT_HOME="$SOURCE/nifi-toolkit-${TOOLKIT_VERSION}"
    CREDS_FILE="$BASE_DIR/apps/nifi/nifi-credentials.txt"
}

create_directories() {
    log "Creating required directories ..."
    for d in "$SOURCE" "$NIFI_BINARIES" "$NIFI_DATA" "$NIFI_LOG_DIR" \
             "$NIFI_FLOWFILE_REPO" "$NIFI_CONTENT_REPO" "$NIFI_DATABASE_REPO" \
             "$NIFI_PROVENANCE_REPO" "$NIFI_STATE_REPO"; do
        if [ -d "$d" ]; then
            log "$d already exists"
        else
            mkdir -p "$d"
            log "Created $d"
        fi
    done

    if [ -L "$NIFI_LOG_SL" ] || [ -e "$NIFI_LOG_SL" ]; then
        log "$NIFI_LOG_SL already exists, skipping symlink creation"
    else
        ln -sn "$NIFI_LOG_DIR" "$NIFI_LOG_SL"
        log "Created log symlink $NIFI_LOG_SL -> $NIFI_LOG_DIR"
    fi
}

# ---------------------------------------------------------------------------
# NiFi download + install
# ---------------------------------------------------------------------------
download_and_install_nifi() {
    if [ -x "$NIFI_BINARIES/bin/nifi.sh" ]; then
        log "NiFi already installed at $NIFI_BINARIES, skipping download."
        return
    fi

    log "Downloading NiFi $NIFI_VERSION ..."
    cd "$SOURCE"
    wget -N "https://archive.apache.org/dist/nifi/${NIFI_VERSION}/nifi-${NIFI_VERSION}-bin.zip"

    log "Unzipping NiFi ..."
    unzip -q -o "nifi-${NIFI_VERSION}-bin.zip"

    log "Moving NiFi files to $NIFI_BINARIES ..."
    mv "nifi-${NIFI_VERSION}"/* "$NIFI_BINARIES"
    rm -rf "nifi-${NIFI_VERSION}" "nifi-${NIFI_VERSION}-bin.zip"
}

# ---------------------------------------------------------------------------
# Apply repository / JVM / log-dir / proxy-host configuration to
# nifi.properties etc.
# (This is called twice: once after install, and again after the toolkit
#  overwrites nifi.properties, so the customizations are never lost.)
# ---------------------------------------------------------------------------
apply_nifi_config() {
    log "Applying repository, log-dir, JVM heap and proxy-host configuration ..."

    # nifi-env.sh: JAVA_HOME + log dir
    if ! grep -q "^export JAVA_HOME=" "$NIFI_BINARIES/bin/nifi-env.sh"; then
        printf '\nexport JAVA_HOME=%s\n' "$JAVA_HOME" >> "$NIFI_BINARIES/bin/nifi-env.sh"
    else
        sed -i "s#^export JAVA_HOME=.*#export JAVA_HOME=$JAVA_HOME#" "$NIFI_BINARIES/bin/nifi-env.sh"
    fi
    if grep -q "NIFI_LOG_DIR=" "$NIFI_BINARIES/bin/nifi-env.sh"; then
        sed -i "/NIFI_LOG_DIR=/c\\NIFI_LOG_DIR=\"\$(setOrDefault \"\$NIFI_LOG_DIR\" \"$NIFI_LOG_SL\")\"" "$NIFI_BINARIES/bin/nifi-env.sh"
    fi

    # nifi.properties: repository directories
    sed -i "/^nifi.flowfile.repository.directory=/c\\nifi.flowfile.repository.directory=$NIFI_FLOWFILE_REPO" "$NIFI_BINARIES/conf/nifi.properties"
    sed -i "/^nifi.database.directory=/c\\nifi.database.directory=$NIFI_DATABASE_REPO" "$NIFI_BINARIES/conf/nifi.properties"
    sed -i "/^nifi.provenance.repository.directory.default=/c\\nifi.provenance.repository.directory.default=$NIFI_PROVENANCE_REPO" "$NIFI_BINARIES/conf/nifi.properties"
    sed -i "/^nifi.content.repository.directory.default=/c\\nifi.content.repository.directory.default=$NIFI_CONTENT_REPO" "$NIFI_BINARIES/conf/nifi.properties"

    # nifi.properties: proxy host allowlist (fixes "invalid host header" errors)
    if grep -q "^nifi.web.proxy.host=" "$NIFI_BINARIES/conf/nifi.properties"; then
        sed -i "s|^nifi.web.proxy.host=.*|nifi.web.proxy.host=${PROXY_HOST_VALUE}|" "$NIFI_BINARIES/conf/nifi.properties"
    else
        echo "nifi.web.proxy.host=${PROXY_HOST_VALUE}" >> "$NIFI_BINARIES/conf/nifi.properties"
    fi

    # nifi.properties: https port (in case default differs from override)
    sed -i "/^nifi.web.https.port=/c\\nifi.web.https.port=${NIFI_HTTPS_PORT}" "$NIFI_BINARIES/conf/nifi.properties"

    # state-management.xml: local state dir
    sed -i "s#\./state/local#$NIFI_STATE_REPO/local#" "$NIFI_BINARIES/conf/state-management.xml"

    # bootstrap.conf: JVM heap
    sed -i "/^java.arg.2=/c\\java.arg.2=-Xms${NIFI_XMS}" "$NIFI_BINARIES/conf/bootstrap.conf"
    sed -i "/^java.arg.3=/c\\java.arg.3=-Xmx${NIFI_XMX}" "$NIFI_BINARIES/conf/bootstrap.conf"

    log "Configuration applied. nifi.web.proxy.host=${PROXY_HOST_VALUE}"
}

configure_nifi_first_pass() {
    cd "$NIFI_BINARIES"
    cp -n conf/nifi.properties conf/nifi.properties_bkp || true
    cp -n conf/state-management.xml conf/state-management.xml_bkp || true
    cp -n bin/nifi-env.sh bin/nifi-env.sh_bkp || true
    apply_nifi_config
}

# ---------------------------------------------------------------------------
# systemd service
# ---------------------------------------------------------------------------
create_systemd_service() {
    log "Creating systemd service for NiFi ..."

    cat > /etc/systemd/system/nifi.service <<EOF
[Unit]
Description=Apache NiFi
After=network.target multi-user.target

[Service]
Type=forking
User=${NIFI_SERVICE_USER}
Group=${NIFI_SERVICE_GROUP}
ExecStart=${NIFI_BINARIES}/bin/nifi.sh start
ExecStop=${NIFI_BINARIES}/bin/nifi.sh stop
ExecReload=${NIFI_BINARIES}/bin/nifi.sh restart
Restart=on-failure
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable nifi.service
    log "nifi.service created and enabled for boot."
}

# ---------------------------------------------------------------------------
# NiFi Toolkit: TLS cert generation
# ---------------------------------------------------------------------------
install_toolkit_and_generate_certs() {
    log "Downloading NiFi Toolkit $TOOLKIT_VERSION ..."
    cd "$SOURCE"
    if [ ! -d "$NIFI_TOOLKIT_HOME" ]; then
        wget -N "https://archive.apache.org/dist/nifi/${TOOLKIT_VERSION}/nifi-toolkit-${TOOLKIT_VERSION}-bin.zip"
        unzip -q -o "nifi-toolkit-${TOOLKIT_VERSION}-bin.zip"
    else
        log "Toolkit already present at $NIFI_TOOLKIT_HOME"
    fi

    # Generate strong random passwords for keystore/truststore/CA key
    KEYSTORE_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    TRUSTSTORE_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    CA_KEY_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"

    cd "$NIFI_TOOLKIT_HOME/bin"
    rm -rf "./${HOST_SHORT}"   # ensure idempotent re-run

    log "Generating TLS certificates via NiFi Toolkit ..."
    # Include the detected private/public IPs (and hostname) as SANs so the
    # cert itself is valid for whichever address the operator chose above.
    local san_list="${HOST_SHORT},${PRIVATE_IP},localhost"
    [ -n "${PUBLIC_IP:-}" ] && san_list="${san_list},${PUBLIC_IP}"

    ./tls-toolkit.sh standalone \
        -C "CN=${HOST_SHORT}, OU=NIFI" \
        -n "${HOST_SHORT}" \
        -o . \
        -K "$CA_KEY_PASS" \
        -P "$KEYSTORE_PASS" \
        -S "$TRUSTSTORE_PASS" \
        --subjectAlternativeNames "${san_list}"

    log "Copying keystore/truststore/nifi.properties into NiFi conf ..."
    cp "./${HOST_SHORT}/keystore.jks" "$NIFI_BINARIES/conf/keystore.jks"
    cp "./${HOST_SHORT}/truststore.jks" "$NIFI_BINARIES/conf/truststore.jks"
    cp "./${HOST_SHORT}/nifi.properties" "$NIFI_BINARIES/conf/nifi.properties"

    # The toolkit's nifi.properties overwrites our repo/log/proxy-host
    # customizations - re-apply them now that the file has been replaced.
    apply_nifi_config

    # Persist the generated passwords securely for future reference.
    umask 077
    cat > "$CREDS_FILE" <<EOF
NiFi TLS Keystore password:   $KEYSTORE_PASS
NiFi TLS Truststore password: $TRUSTSTORE_PASS
NiFi CA key password:         $CA_KEY_PASS
NiFi login username:          $NIFI_ADMIN_USER
NiFi login password:          $NIFI_ADMIN_PASS
nifi.web.proxy.host:          $PROXY_HOST_VALUE
EOF
    chmod 600 "$CREDS_FILE"
    log "Certificate/login credentials saved to $CREDS_FILE (root-readable only)."
}

# ---------------------------------------------------------------------------
# PostgreSQL JDBC driver
# ---------------------------------------------------------------------------
install_postgres_jar() {
    log "Installing PostgreSQL JDBC driver $POSTGRES_JAR_VERSION ..."
    local jar_name="postgresql-${POSTGRES_JAR_VERSION}.jar"
    if [ -f "$NIFI_BINARIES/lib/$jar_name" ]; then
        log "PostgreSQL jar already present, skipping."
        return
    fi
    wget -N -P "$NIFI_BINARIES/lib" \
        "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JAR_VERSION}/${jar_name}"
    log "PostgreSQL jar installed at $NIFI_BINARIES/lib/$jar_name"
}

# ---------------------------------------------------------------------------
# Single-user credentials
# ---------------------------------------------------------------------------
set_single_user_credentials() {
    log "Setting NiFi single-user login credentials ..."
    cd "$NIFI_BINARIES"
    ./bin/nifi.sh set-single-user-credentials "$NIFI_ADMIN_USER" "$NIFI_ADMIN_PASS" >>"$LOG_FILE" 2>&1
    log "NiFi login credentials configured."
}

# ---------------------------------------------------------------------------
# Start service
# ---------------------------------------------------------------------------
start_nifi() {
    log "Starting NiFi service ..."
    systemctl restart nifi.service
    sleep 5
    systemctl status nifi.service --no-pager || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_root
    log "=== NiFi automated installation started (log: $LOG_FILE) ==="

    detect_os
    prompt_disk
    prompt_credentials
    detect_network
    prompt_proxy_host
    setup_paths

    install_prereqs
    detect_java_home
    create_directories
    download_and_install_nifi
    configure_nifi_first_pass
    create_systemd_service
    install_toolkit_and_generate_certs
    install_postgres_jar
    set_single_user_credentials
    start_nifi

    echo
    log "=== NiFi installation complete ==="
    log "Access NiFi at: https://$( [ ${#PROXY_HOSTS[@]} -gt 0 ] && echo "${PROXY_HOSTS[0]}" || echo "$IP_ADDRESS" ):$(grep -oP '(?<=nifi.web.https.port=).*' "$NIFI_BINARIES/conf/nifi.properties")/nifi"
    log "Login username: $NIFI_ADMIN_USER"
    log "nifi.web.proxy.host configured as: $PROXY_HOST_VALUE"
    log "Credentials/cert passwords saved at: $CREDS_FILE"
    log "Full install log: $LOG_FILE"
}

main "$@"

