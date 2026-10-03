#!/usr/bin/env bash
#############################################################################
# install_nifi2.sh
#
# Automated Apache NiFi 2.x installer - STANDALONE or 2-NODE CLUSTER.
#
#   sudo ./install_nifi2.sh      (asks: standalone or cluster)
#
# CLUSTER FLOW (run the same script on both nodes, Node 1 FIRST):
#   Node 1: asks for login user/password, generates EVERYTHING else
#           (sensitive-props key, CA + CA password, ports), installs, then
#           packs them into ONE bundle (/tmp/nifi-cluster-bundle.tgz) and
#           pushes it to Node 2 over SSH automatically.
#   Node 2: asks ONLY for its node number / addresses / base path. It picks
#           up the bundle (already pushed by Node 1, or pulled from Node 1
#           over SSH) and reads the credentials, sensitive-props key, CA
#           and CA password from it. You never type them on Node 2.
#   If SSH between the nodes is not possible, the script tells you to copy
#   that ONE file to Node 2 at the same path and re-run - nothing to type.
#
# WHAT CHANGED vs NiFi 1.x:
#   - Java 21 is required (NiFi 2.x will not start on Java 11/17).
#   - tls-toolkit was removed in 2.x, so certificates are generated with
#     openssl + keytool (PKCS12 keystore/truststore). Both nodes' certs are
#     signed by ONE shared CA, so they trust each other. IP SANs are typed
#     correctly (IP:), so the node IP/hostname you give is used directly.
#   - nifi.sensitive.props.key is required on every node and must be
#     identical across the cluster (handled via the bundle).
#   - Load-balance port (6342) added to the cluster port list.
#
# PORTS to open BETWEEN the two nodes (security group / firewall):
#   22 (SSH, only for the bundle transfer), 2181/2888/3888 (ZooKeeper),
#   11443 (cluster protocol), 6342 (load balance), 9443 (UI + replication)
#
# NOTES:
#   - Single-user login is what this script configures. It works, but for
#     production clusters use LDAP/OIDC/SAML instead.
#   - A 2-node embedded ZooKeeper has no failure tolerance (no quorum if one
#     node is down). Use 3 nodes / external ZK for real HA.
#
# Optional env overrides (all have defaults):
#   NIFI_VERSION=2.9.0  POSTGRES_JAR_VERSION=42.7.3  NIFI_XMS=1g NIFI_XMX=1g
#   NIFI_SERVICE_USER=root NIFI_SERVICE_GROUP=root
#   NIFI_HTTPS_PORT=9443 NIFI_CLUSTER_PROTOCOL_PORT=11443 NIFI_LOAD_BALANCE_PORT=6342
#   NIFI_ZK_CLIENT_PORT=2181 NIFI_ZK_PEER_PORT=2888 NIFI_ZK_ELECTION_PORT=3888
#   PEER_SSH_USER=ubuntu PEER_SSH_KEY= PEER_SSH_PORT=22 AUTO_COPY_BUNDLE=true
#   SENSITIVE_PROPS_KEY=   (Node 1 / standalone only; blank = auto-generate)
#############################################################################

set -euo pipefail

NIFI_VERSION="${NIFI_VERSION:-2.9.0}"
POSTGRES_JAR_VERSION="${POSTGRES_JAR_VERSION:-42.7.3}"
NIFI_XMS="${NIFI_XMS:-1g}"
NIFI_XMX="${NIFI_XMX:-1g}"
NIFI_SERVICE_USER="${NIFI_SERVICE_USER:-root}"
NIFI_SERVICE_GROUP="${NIFI_SERVICE_GROUP:-root}"
NIFI_HTTPS_PORT="${NIFI_HTTPS_PORT:-9443}"
NIFI_CLUSTER_PROTOCOL_PORT="${NIFI_CLUSTER_PROTOCOL_PORT:-11443}"
NIFI_LOAD_BALANCE_PORT="${NIFI_LOAD_BALANCE_PORT:-6342}"
NIFI_ZK_CLIENT_PORT="${NIFI_ZK_CLIENT_PORT:-2181}"
NIFI_ZK_PEER_PORT="${NIFI_ZK_PEER_PORT:-2888}"
NIFI_ZK_ELECTION_PORT="${NIFI_ZK_ELECTION_PORT:-3888}"
PEER_SSH_USER="${PEER_SSH_USER:-ubuntu}"
PEER_SSH_KEY="${PEER_SSH_KEY:-}"
PEER_SSH_PORT="${PEER_SSH_PORT:-22}"
AUTO_COPY_BUNDLE="${AUTO_COPY_BUNDLE:-true}"
SENSITIVE_PROPS_KEY="${SENSITIVE_PROPS_KEY:-}"

BUNDLE_DIR="/tmp/nifi-cluster-bundle"
BUNDLE_TGZ="/tmp/nifi-cluster-bundle.tgz"
LOG_FILE="/tmp/install_nifi2_$(date +%Y%m%d%H%M%S).log"

MODE=""                 # standalone | cluster
THIS_NODE_NUM=0
PEER_NODE_NUM=0
NODE1_ADDR=""; NODE2_ADDR=""; THIS_NODE_ADDR=""; PEER_NODE_ADDR=""
EXTRA_PROXY_HOST=""
NIFI_ADMIN_USER=""; NIFI_ADMIN_PASS=""
CA_KEY_PASS=""
BUNDLE_PUSHED=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo -e "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "[$(date +'%F %T')] WARNING: $*" | tee -a "$LOG_FILE"; }
die()  { echo -e "[$(date +'%F %T')] ERROR: $*" | tee -a "$LOG_FILE" >&2; exit 1; }
trap 'die "Script failed at line $LINENO. See $LOG_FILE for details."' ERR

require_root() { [ "$(id -u)" -eq 0 ] || die "Run as root (or via sudo)."; }

rand() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }

is_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

# set_prop <file> <key> <value> : replace "key=..." or append it
set_prop() {
    local file="$1" key="$2" val="$3" esc kre
    esc="$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')"
    kre="${key//./\\.}"
    if grep -q "^${kre}=" "$file"; then
        sed -i "s|^${kre}=.*|${key}=${esc}|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

build_ssh_opts() {
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -p "$PEER_SSH_PORT")
    SCP_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -P "$PEER_SSH_PORT")
    if [ -n "$PEER_SSH_KEY" ]; then
        SSH_OPTS+=(-i "$PEER_SSH_KEY"); SCP_OPTS+=(-i "$PEER_SSH_KEY")
    fi
}

# ---------------------------------------------------------------------------
# OS + prerequisites (Java 21)
# ---------------------------------------------------------------------------
detect_os() {
    [ -f /etc/os-release ] || die "Cannot detect OS: /etc/os-release not found."
    # shellcheck disable=SC1091
    . /etc/os-release
    if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; OS_FAMILY="rhel"
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"; OS_FAMILY="rhel"
    elif command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"; OS_FAMILY="debian"
    else die "Unsupported OS: no dnf/yum/apt-get found."; fi
    log "Detected OS: ${ID:-unknown} (family: $OS_FAMILY, package manager: $PKG_MGR)"
}

install_prereqs() {
    log "Installing prerequisites (wget, unzip, curl, tar, openssl, Java 21) ..."
    if [ "$OS_FAMILY" = "rhel" ]; then
        $PKG_MGR install -y wget unzip curl tar openssl >>"$LOG_FILE" 2>&1
        if ! $PKG_MGR install -y java-21-openjdk-devel >>"$LOG_FILE" 2>&1; then
            $PKG_MGR install -y java-21-amazon-corretto-devel >>"$LOG_FILE" 2>&1 \
                || die "Could not install Java 21 (tried java-21-openjdk-devel, java-21-amazon-corretto-devel). Install JDK 21 manually and re-run."
        fi
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >>"$LOG_FILE" 2>&1
        apt-get install -y wget unzip curl tar openssl iproute2 >>"$LOG_FILE" 2>&1
        apt-get install -y openjdk-21-jdk >>"$LOG_FILE" 2>&1 \
            || die "Could not install openjdk-21-jdk from your repos. Install JDK 21 manually (e.g. Temurin/Corretto) and re-run."
    fi
    log "Prerequisites installed."
}

detect_java_home() {
    local d java_bin
    JAVA_HOME=""
    for d in /usr/lib/jvm/*21* /usr/lib/jvm/*-2[2-9]*; do
        if [ -x "$d/bin/java" ] && [ -x "$d/bin/keytool" ]; then JAVA_HOME="$d"; break; fi
    done
    if [ -z "$JAVA_HOME" ]; then
        java_bin="$(readlink -f "$(command -v java)")" || die "Java not found."
        JAVA_HOME="${java_bin%/bin/java}"
    fi
    "$JAVA_HOME/bin/java" -version 2>&1 | grep -Eq 'version "(2[1-9]|[3-9][0-9])' \
        || die "NiFi 2.x needs Java 21+, but $JAVA_HOME is: $("$JAVA_HOME/bin/java" -version 2>&1 | head -n1)"
    [ -x "$JAVA_HOME/bin/keytool" ] || die "keytool not found in $JAVA_HOME (a full JDK is required)."
    log "Using JAVA_HOME=$JAVA_HOME"
}

# ---------------------------------------------------------------------------
# Network detection
# ---------------------------------------------------------------------------
get_ec2_metadata() {
    local path="$1" token
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
    HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
    IP_ADDRESS="$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)"
    [ -z "$IP_ADDRESS" ] && IP_ADDRESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "$IP_ADDRESS" ] && die "Could not auto-detect an IPv4 address."
    PRIVATE_IP="$(get_ec2_metadata local-ipv4)"; [ -z "$PRIVATE_IP" ] && PRIVATE_IP="$IP_ADDRESS"
    PUBLIC_IP="$(get_ec2_metadata public-ipv4)"
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP="$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    log "This host - Hostname: $HOST_SHORT | Private IP: $PRIVATE_IP | Public IP: ${PUBLIC_IP:-<not detected>}"
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
prompt_mode() {
    echo
    echo "Install NiFi as:"
    echo "  1) Standalone (single node)"
    echo "  2) Cluster node (2-node cluster)"
    local m; read -rp "Choose [1/2]: " m
    case "$m" in 1) MODE="standalone" ;; 2) MODE="cluster" ;; *) die "Enter 1 or 2." ;; esac
}

prompt_disk() {
    echo
    read -rp "Base path to install NiFi under (e.g. /opt/ausiytic, or / for root volume): " DISK_MOUNT
    [ -z "$DISK_MOUNT" ] && die "Base path cannot be empty."
    if [ "$DISK_MOUNT" = "/" ]; then BASE_DIR=""; else
        BASE_DIR="${DISK_MOUNT%/}"
        [ -d "$BASE_DIR" ] || die "Path '$BASE_DIR' does not exist. Create/mount it first, then re-run."
    fi
    log "NiFi will be installed under: ${BASE_DIR:-/}"
}

prompt_credentials() {
    echo
    read -rp "NiFi login username to create: " NIFI_ADMIN_USER
    [ -z "$NIFI_ADMIN_USER" ] && die "Username cannot be empty."
    local confirm
    while true; do
        read -rsp "NiFi login password (min 12 characters): " NIFI_ADMIN_PASS; echo
        if [ "${#NIFI_ADMIN_PASS}" -lt 12 ]; then echo "Must be at least 12 characters."; continue; fi
        read -rsp "Confirm password: " confirm; echo
        [ "$NIFI_ADMIN_PASS" = "$confirm" ] && break
        echo "Passwords do not match."
    done
}

prompt_standalone_addr() {
    echo
    read -rp "Hostname/IP this NiFi will be reached at (default: $PRIVATE_IP): " THIS_NODE_ADDR
    THIS_NODE_ADDR="${THIS_NODE_ADDR:-$PRIVATE_IP}"
    read -rp "Extra public IP/DNS for the UI (blank to skip): " EXTRA_PROXY_HOST
}

prompt_cluster_topology() {
    echo
    echo "=== 2-node NiFi cluster ==="
    local n; read -rp "Is this Node 1 or Node 2? [1/2]: " n
    case "$n" in 1) THIS_NODE_NUM=1; PEER_NODE_NUM=2 ;; 2) THIS_NODE_NUM=2; PEER_NODE_NUM=1 ;; *) die "Enter 1 or 2." ;; esac
    echo "Use PRIVATE addresses (an address that exists on this host's network interface)."
    read -rp "Address of THIS node that the other node will use (default: $PRIVATE_IP): " THIS_NODE_ADDR
    THIS_NODE_ADDR="${THIS_NODE_ADDR:-$PRIVATE_IP}"
    read -rp "Address of the OTHER node (Node $PEER_NODE_NUM): " PEER_NODE_ADDR
    [ -z "$PEER_NODE_ADDR" ] && die "Peer address cannot be empty."
    read -rp "Extra public IP/DNS for the UI on this node (blank to skip): " EXTRA_PROXY_HOST
    if [ "$THIS_NODE_NUM" -eq 1 ]; then NODE1_ADDR="$THIS_NODE_ADDR"; NODE2_ADDR="$PEER_NODE_ADDR"
    else NODE2_ADDR="$THIS_NODE_ADDR"; NODE1_ADDR="$PEER_NODE_ADDR"; fi
    log "This is Node $THIS_NODE_NUM ($THIS_NODE_ADDR); peer is Node $PEER_NODE_NUM ($PEER_NODE_ADDR)."
    warn "A 2-node embedded ZooKeeper ensemble has NO failure tolerance. Use 3 nodes for real HA."
}

prompt_ssh_access() {
    [ "$AUTO_COPY_BUNDLE" = "true" ] || { log "AUTO_COPY_BUNDLE=false - manual bundle copy will be required."; return; }
    echo
    if [ "$THIS_NODE_NUM" -eq 1 ]; then
        echo "=== Automatic transfer of credentials/CA to Node 2 (over SSH) ==="
        echo "Node 1 will push the cluster bundle to Node 2 (${PEER_NODE_ADDR}) so you never re-enter anything there."
    else
        echo "=== Fetching credentials/CA from Node 1 (over SSH) ==="
        echo "Only used if Node 1 has not already pushed the bundle to this host."
        echo "Needs an SSH user on Node 1 with passwordless sudo (default on EC2 'ubuntu'/'ec2-user')."
    fi
    local u k p
    read -rp "SSH username on Node ${PEER_NODE_NUM} [${PEER_SSH_USER}]: " u;   PEER_SSH_USER="${u:-$PEER_SSH_USER}"
    read -rp "Private key path (blank = default identity/agent): " k;           PEER_SSH_KEY="${k:-$PEER_SSH_KEY}"
    read -rp "SSH port [${PEER_SSH_PORT}]: " p;                                 PEER_SSH_PORT="${p:-$PEER_SSH_PORT}"
    build_ssh_opts
}

generate_shared_secrets() {
    if [ -z "$SENSITIVE_PROPS_KEY" ]; then SENSITIVE_PROPS_KEY="$(rand 32)"; fi
    [ "${#SENSITIVE_PROPS_KEY}" -ge 12 ] || die "Sensitive properties key must be >= 12 characters."
    CA_KEY_PASS="$(rand 24)"
}

# ---------------------------------------------------------------------------
# Node 2: obtain the bundle Node 1 created, then load it
# ---------------------------------------------------------------------------
acquire_and_load_bundle() {
    log "Looking for cluster bundle from Node 1 at $BUNDLE_TGZ ..."
    if [ ! -f "$BUNDLE_TGZ" ] && [ "$AUTO_COPY_BUNDLE" = "true" ]; then
        log "Not found locally - trying to pull it from Node 1 (${PEER_SSH_USER}@${PEER_NODE_ADDR}) ..."
        build_ssh_opts
        if ssh "${SSH_OPTS[@]}" "${PEER_SSH_USER}@${PEER_NODE_ADDR}" "sudo -n cat '$BUNDLE_TGZ'" > "$BUNDLE_TGZ" 2>>"$LOG_FILE" \
           && tar -tzf "$BUNDLE_TGZ" >/dev/null 2>&1; then
            chmod 600 "$BUNDLE_TGZ"; log "Bundle pulled from Node 1."
        else
            rm -f "$BUNDLE_TGZ"
            warn "Automatic pull from Node 1 failed (see $LOG_FILE)."
        fi
    fi
    [ -f "$BUNDLE_TGZ" ] || die "Cluster bundle not found. Copy this ONE file from Node 1 to this host at the same path, then re-run (nothing to type):
    scp ${PEER_SSH_USER}@${PEER_NODE_ADDR}:${BUNDLE_TGZ} ${BUNDLE_TGZ}   (or copy it however you like)"

    rm -rf "$BUNDLE_DIR"; mkdir -p "$BUNDLE_DIR"; chmod 700 "$BUNDLE_DIR"
    tar -xzf "$BUNDLE_TGZ" -C "$BUNDLE_DIR"
    [ -f "$BUNDLE_DIR/cluster.env" ] && [ -f "$BUNDLE_DIR/ca.pem" ] && [ -f "$BUNDLE_DIR/ca.key" ] \
        || die "Bundle is incomplete. Re-run the script on Node 1 to regenerate it."
    # shellcheck disable=SC1091
    . "$BUNDLE_DIR/cluster.env"
    [ "$THIS_NODE_ADDR" = "$NODE2_ADDR" ] || die "This node's address ($THIS_NODE_ADDR) differs from the Node 2 address Node 1 was configured with ($NODE2_ADDR). Re-run with the matching address."
    log "Loaded credentials, sensitive-props key, CA and ports from Node 1's bundle."
}

# ---------------------------------------------------------------------------
# Node 1: create bundle and push it to Node 2
# ---------------------------------------------------------------------------
create_bundle() {
    local old v; old="$(umask)"; umask 077
    rm -rf "$BUNDLE_DIR" "$BUNDLE_TGZ"; mkdir -p "$BUNDLE_DIR"
    {
        for v in NIFI_VERSION NIFI_HTTPS_PORT NIFI_CLUSTER_PROTOCOL_PORT NIFI_LOAD_BALANCE_PORT \
                 NIFI_ZK_CLIENT_PORT NIFI_ZK_PEER_PORT NIFI_ZK_ELECTION_PORT \
                 NODE1_ADDR NODE2_ADDR NIFI_ADMIN_USER NIFI_ADMIN_PASS SENSITIVE_PROPS_KEY CA_KEY_PASS; do
            printf '%s=%q\n' "$v" "${!v}"
        done
    } > "$BUNDLE_DIR/cluster.env"
    cp "$PKI_DIR/ca.pem" "$PKI_DIR/ca.key" "$BUNDLE_DIR/"
    tar -C "$BUNDLE_DIR" -czf "$BUNDLE_TGZ" cluster.env ca.pem ca.key
    rm -rf "$BUNDLE_DIR"
    umask "$old"
    log "Cluster bundle created at $BUNDLE_TGZ"
}

push_bundle() {
    BUNDLE_PUSHED=false
    [ "$AUTO_COPY_BUNDLE" = "true" ] || return 0
    log "Pushing bundle to Node 2 (${PEER_SSH_USER}@${PEER_NODE_ADDR}) ..."
    build_ssh_opts
    if scp "${SCP_OPTS[@]}" "$BUNDLE_TGZ" "${PEER_SSH_USER}@${PEER_NODE_ADDR}:${BUNDLE_TGZ}" >>"$LOG_FILE" 2>&1 \
       && ssh "${SSH_OPTS[@]}" "${PEER_SSH_USER}@${PEER_NODE_ADDR}" "chmod 600 '$BUNDLE_TGZ'" >>"$LOG_FILE" 2>&1; then
        BUNDLE_PUSHED=true
        log "Bundle delivered to Node 2 automatically."
    else
        warn "Automatic push failed (no SSH path / wrong key / port 22 blocked - see $LOG_FILE)."
        warn "Node 1's install is unaffected. Node 2 will also try to PULL it from Node 1 over SSH;"
        warn "otherwise copy the single file $BUNDLE_TGZ to Node 2 at the same path."
    fi
}

# ---------------------------------------------------------------------------
# Paths / dirs / download
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
    NIFI_ZK_DATA_DIR="$NIFI_DATA/zookeeper"
    PKI_DIR="$BASE_DIR/apps/nifi/pki"
    CREDS_FILE="$BASE_DIR/apps/nifi/nifi-credentials.txt"
}

create_directories() {
    log "Creating directories ..."
    local d
    for d in "$SOURCE" "$NIFI_BINARIES" "$NIFI_DATA" "$NIFI_LOG_DIR" "$NIFI_FLOWFILE_REPO" \
             "$NIFI_CONTENT_REPO" "$NIFI_DATABASE_REPO" "$NIFI_PROVENANCE_REPO" \
             "$NIFI_STATE_REPO" "$NIFI_ZK_DATA_DIR"; do
        mkdir -p "$d"
    done
    mkdir -p "$PKI_DIR"; chmod 700 "$PKI_DIR"
    if [ ! -e "$NIFI_LOG_SL" ] && [ ! -L "$NIFI_LOG_SL" ]; then ln -sn "$NIFI_LOG_DIR" "$NIFI_LOG_SL"; fi
    if [ "$MODE" = "cluster" ]; then
        echo "$THIS_NODE_NUM" > "$NIFI_ZK_DATA_DIR/myid"
        log "Wrote ZooKeeper myid=$THIS_NODE_NUM"
    fi
}

download_and_install_nifi() {
    if [ -x "$NIFI_BINARIES/bin/nifi.sh" ]; then log "NiFi already installed at $NIFI_BINARIES, skipping download."; return; fi
    local zip="nifi-${NIFI_VERSION}-bin.zip" base
    cd "$SOURCE"
    log "Downloading NiFi $NIFI_VERSION ..."
    if ! wget -q -N "https://archive.apache.org/dist/nifi/${NIFI_VERSION}/${zip}" \
       && ! wget -q -N "https://downloads.apache.org/nifi/${NIFI_VERSION}/${zip}"; then
        die "Could not download NiFi ${NIFI_VERSION}. Check the version exists (NIFI_VERSION=...) and that this host has internet access."
    fi
    # best-effort checksum verification
    for base in "https://archive.apache.org/dist/nifi/${NIFI_VERSION}/${zip}.sha256" "https://downloads.apache.org/nifi/${NIFI_VERSION}/${zip}.sha256"; do
        if wget -q -O "${zip}.sha256" "$base" 2>/dev/null; then
            local want got; want="$(awk '{print $1}' "${zip}.sha256" | head -n1)"; got="$(sha256sum "$zip" | awk '{print $1}')"
            [ "$want" = "$got" ] || die "SHA-256 mismatch for $zip (expected $want, got $got)."
            log "SHA-256 verified."; break
        fi
    done
    unzip -q -o "$zip"
    mv "nifi-${NIFI_VERSION}"/* "$NIFI_BINARIES"
    rm -rf "nifi-${NIFI_VERSION}" "$zip" "${zip}.sha256"
}

# ---------------------------------------------------------------------------
# TLS (openssl + keytool) - one shared CA for the whole cluster
# ---------------------------------------------------------------------------
build_san() {
    local items=("$HOST_SHORT" "$HOST_FQDN" "$THIS_NODE_ADDR" "$PRIVATE_IP" "${PUBLIC_IP:-}" "${EXTRA_PROXY_HOST:-}" "localhost" "127.0.0.1")
    local seen=" " out=() i
    for i in "${items[@]}"; do
        [ -z "$i" ] && continue
        case "$seen" in *" $i "*) continue ;; esac
        seen+="$i "
        if is_ip "$i"; then out+=("IP:$i"); else out+=("DNS:$i"); fi
    done
    (IFS=,; echo "${out[*]}")
}

generate_tls() {
    log "Generating TLS material ..."
    KEYSTORE_PASS="$(rand 24)"; TRUSTSTORE_PASS="$(rand 24)"
    export CA_KEY_PASS KEYSTORE_PASS TRUSTSTORE_PASS

    if [ "$MODE" = "cluster" ] && [ "$THIS_NODE_NUM" -eq 2 ]; then
        log "Reusing Node 1's shared CA from the bundle."
        cp -f "$BUNDLE_DIR/ca.pem" "$BUNDLE_DIR/ca.key" "$PKI_DIR/"
    else
        log "Creating a new root CA ..."
        openssl genrsa -aes256 -passout env:CA_KEY_PASS -out "$PKI_DIR/ca.key" 4096 >>"$LOG_FILE" 2>&1
        openssl req -x509 -new -key "$PKI_DIR/ca.key" -passin env:CA_KEY_PASS -sha256 -days 3650 \
            -subj "/CN=NiFi-CA-${HOST_SHORT}/OU=NIFI" -out "$PKI_DIR/ca.pem" >>"$LOG_FILE" 2>&1
    fi
    chmod 600 "$PKI_DIR/ca.key"

    local san ext="$PKI_DIR/node.ext"
    san="$(build_san)"
    log "Certificate SANs: $san"
    cat > "$ext" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${san}
EOF
    openssl genrsa -out "$PKI_DIR/node.key" 2048 >>"$LOG_FILE" 2>&1
    openssl req -new -key "$PKI_DIR/node.key" -subj "/CN=${THIS_NODE_ADDR}/OU=NIFI" -out "$PKI_DIR/node.csr" >>"$LOG_FILE" 2>&1
    openssl x509 -req -in "$PKI_DIR/node.csr" -CA "$PKI_DIR/ca.pem" -CAkey "$PKI_DIR/ca.key" -passin env:CA_KEY_PASS \
        -set_serial "0x$(openssl rand -hex 8)" -days 825 -sha256 -extfile "$ext" -out "$PKI_DIR/node.pem" >>"$LOG_FILE" 2>&1
    openssl pkcs12 -export -in "$PKI_DIR/node.pem" -inkey "$PKI_DIR/node.key" -certfile "$PKI_DIR/ca.pem" \
        -name nifi-key -out "$PKI_DIR/keystore.p12" -passout env:KEYSTORE_PASS >>"$LOG_FILE" 2>&1
    rm -f "$PKI_DIR/truststore.p12"
    "$JAVA_HOME/bin/keytool" -importcert -noprompt -alias nifi-ca -file "$PKI_DIR/ca.pem" \
        -keystore "$PKI_DIR/truststore.p12" -storetype PKCS12 -storepass:env TRUSTSTORE_PASS >>"$LOG_FILE" 2>&1

    cp "$PKI_DIR/keystore.p12" "$PKI_DIR/truststore.p12" "$NIFI_BINARIES/conf/"
    chmod 600 "$NIFI_BINARIES/conf/keystore.p12" "$NIFI_BINARIES/conf/truststore.p12"
    rm -f "$PKI_DIR/node.key" "$PKI_DIR/node.csr" "$PKI_DIR/node.pem" "$ext"
    # Node 2 never needs the CA private key after signing its own cert
    if [ "$MODE" = "cluster" ] && [ "$THIS_NODE_NUM" -eq 2 ]; then rm -f "$PKI_DIR/ca.key"; fi
    log "Keystore/truststore installed in $NIFI_BINARIES/conf"
}

# ---------------------------------------------------------------------------
# build nifi.web.proxy.host
# ---------------------------------------------------------------------------
build_proxy_host_value() {
    local hosts=("$THIS_NODE_ADDR")
    [ "$MODE" = "cluster" ] && hosts+=("$NODE1_ADDR" "$NODE2_ADDR")
    hosts+=("${EXTRA_PROXY_HOST:-}" "${PUBLIC_IP:-}" "$HOST_SHORT" "$HOST_FQDN" "localhost")
    local seen=" " values=() h
    for h in "${hosts[@]}"; do
        [ -z "$h" ] && continue
        case "$seen" in *" $h "*) continue ;; esac
        seen+="$h "
        values+=("${h}:${NIFI_HTTPS_PORT}" "${h}")
    done
    PROXY_HOST_VALUE="$(IFS=,; echo "${values[*]}")"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
configure_zookeeper_properties() {
    local zk="$NIFI_BINARIES/conf/zookeeper.properties"
    set_prop "$zk" dataDir "$NIFI_ZK_DATA_DIR"
    set_prop "$zk" clientPort "$NIFI_ZK_CLIENT_PORT"
    # explicit clientPortAddress is required by NiFi's embedded ZK once server.N lines exist;
    # do NOT add an inline ";clientPort" suffix to server lines (conflicts with it).
    set_prop "$zk" clientPortAddress "$THIS_NODE_ADDR"
    sed -i '/^server\./d' "$zk"
    {
        echo "server.1=${NODE1_ADDR}:${NIFI_ZK_PEER_PORT}:${NIFI_ZK_ELECTION_PORT}"
        echo "server.2=${NODE2_ADDR}:${NIFI_ZK_PEER_PORT}:${NIFI_ZK_ELECTION_PORT}"
    } >> "$zk"
}

apply_nifi_config() {
    log "Applying NiFi configuration ($MODE) ..."
    cd "$NIFI_BINARIES"
    local f; for f in conf/nifi.properties conf/state-management.xml conf/zookeeper.properties conf/bootstrap.conf bin/nifi-env.sh; do
        cp -n "$f" "${f}_bkp" 2>/dev/null || true
    done

    # nifi-env.sh : JAVA_HOME + log dir
    grep -v -E '^export (JAVA_HOME|NIFI_LOG_DIR)=' bin/nifi-env.sh > bin/nifi-env.sh.new || true
    {
        printf '\nexport JAVA_HOME=%s\n' "$JAVA_HOME"
        printf 'export NIFI_LOG_DIR=%s\n' "$NIFI_LOG_SL"
    } >> bin/nifi-env.sh.new
    mv bin/nifi-env.sh.new bin/nifi-env.sh; chmod +x bin/nifi-env.sh

    local p="conf/nifi.properties"
    set_prop "$p" nifi.flowfile.repository.directory "$NIFI_FLOWFILE_REPO"
    set_prop "$p" nifi.database.directory "$NIFI_DATABASE_REPO"
    set_prop "$p" nifi.provenance.repository.directory.default "$NIFI_PROVENANCE_REPO"
    set_prop "$p" nifi.content.repository.directory.default "$NIFI_CONTENT_REPO"

    # web / security
    set_prop "$p" nifi.web.https.port "$NIFI_HTTPS_PORT"
    set_prop "$p" nifi.web.proxy.host "$PROXY_HOST_VALUE"
    set_prop "$p" nifi.security.keystore "./conf/keystore.p12"
    set_prop "$p" nifi.security.keystoreType "PKCS12"
    set_prop "$p" nifi.security.keystorePasswd "$KEYSTORE_PASS"
    set_prop "$p" nifi.security.keyPasswd "$KEYSTORE_PASS"
    set_prop "$p" nifi.security.truststore "./conf/truststore.p12"
    set_prop "$p" nifi.security.truststoreType "PKCS12"
    set_prop "$p" nifi.security.truststorePasswd "$TRUSTSTORE_PASS"
    set_prop "$p" nifi.sensitive.props.key "$SENSITIVE_PROPS_KEY"
    set_prop "$p" nifi.remote.input.secure "true"

    if [ "$MODE" = "cluster" ]; then
        set_prop "$p" nifi.web.https.host "$THIS_NODE_ADDR"
        set_prop "$p" nifi.cluster.is.node "true"
        set_prop "$p" nifi.cluster.node.address "$THIS_NODE_ADDR"
        set_prop "$p" nifi.cluster.node.protocol.port "$NIFI_CLUSTER_PROTOCOL_PORT"
        set_prop "$p" nifi.cluster.node.protocol.threads "10"
        set_prop "$p" nifi.cluster.protocol.is.secure "true"
        set_prop "$p" nifi.cluster.flow.election.max.wait.time "5 mins"
        set_prop "$p" nifi.cluster.flow.election.max.candidates "2"
        set_prop "$p" nifi.cluster.load.balance.host "$THIS_NODE_ADDR"
        set_prop "$p" nifi.cluster.load.balance.port "$NIFI_LOAD_BALANCE_PORT"
        set_prop "$p" nifi.state.management.embedded.zookeeper.start "true"
        set_prop "$p" nifi.zookeeper.connect.string "${NODE1_ADDR}:${NIFI_ZK_CLIENT_PORT},${NODE2_ADDR}:${NIFI_ZK_CLIENT_PORT}"
        configure_zookeeper_properties
    else
        set_prop "$p" nifi.web.https.host ""          # bind all interfaces
        set_prop "$p" nifi.cluster.is.node "false"
        set_prop "$p" nifi.state.management.embedded.zookeeper.start "false"
    fi

    # state-management.xml
    sed -i "s#\./state/local#${NIFI_STATE_REPO}/local#" conf/state-management.xml
    if [ "$MODE" = "cluster" ]; then
        sed -i "s#<property name=\"Connect String\"></property>#<property name=\"Connect String\">${NODE1_ADDR}:${NIFI_ZK_CLIENT_PORT},${NODE2_ADDR}:${NIFI_ZK_CLIENT_PORT}</property>#" conf/state-management.xml
    fi

    # JVM heap
    sed -i "s|^java.arg.2=.*|java.arg.2=-Xms${NIFI_XMS}|" conf/bootstrap.conf
    sed -i "s|^java.arg.3=.*|java.arg.3=-Xmx${NIFI_XMX}|" conf/bootstrap.conf

    if [ "$NIFI_SERVICE_USER" != "root" ]; then
        chown -R "${NIFI_SERVICE_USER}:${NIFI_SERVICE_GROUP}" "$BASE_DIR/apps/nifi" "$NIFI_LOG_DIR"
    fi
    log "Configuration applied."
}

create_systemd_service() {
    log "Creating systemd service ..."
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
LimitNOFILE=50000
LimitNPROC=10000
Restart=on-failure
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nifi.service >>"$LOG_FILE" 2>&1
}

install_postgres_jar() {
    local jar="postgresql-${POSTGRES_JAR_VERSION}.jar"
    if [ -f "$NIFI_BINARIES/lib/$jar" ]; then log "PostgreSQL jar already present."; return; fi
    log "Installing PostgreSQL JDBC driver ${POSTGRES_JAR_VERSION} ..."
    wget -q -N -P "$NIFI_BINARIES/lib" "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JAR_VERSION}/${jar}" \
        || warn "Could not download the PostgreSQL JDBC jar; add it to $NIFI_BINARIES/lib manually."
}

set_single_user_credentials() {
    log "Setting NiFi single-user credentials ..."
    cd "$NIFI_BINARIES"
    JAVA_HOME="$JAVA_HOME" ./bin/nifi.sh set-single-user-credentials "$NIFI_ADMIN_USER" "$NIFI_ADMIN_PASS" >>"$LOG_FILE" 2>&1
}

save_credentials_file() {
    (
        umask 077
        cat > "$CREDS_FILE" <<EOF
Mode:                          $MODE $( [ "$MODE" = cluster ] && echo "(node $THIS_NODE_NUM)" )
NiFi version:                  $NIFI_VERSION
NiFi login username:           $NIFI_ADMIN_USER
NiFi login password:           $NIFI_ADMIN_PASS
TLS keystore password:         $KEYSTORE_PASS
TLS truststore password:       $TRUSTSTORE_PASS
CA key password:               $CA_KEY_PASS
Sensitive properties key:      $SENSITIVE_PROPS_KEY
This node address:             $THIS_NODE_ADDR
Cluster node addresses:        ${NODE1_ADDR:--} / ${NODE2_ADDR:--}
nifi.web.proxy.host:           $PROXY_HOST_VALUE
PKI directory:                 $PKI_DIR
EOF
    )
    chmod 600 "$CREDS_FILE"
    log "Credentials saved to $CREDS_FILE (root-readable only)."
}

start_nifi() {
    log "Starting NiFi ..."
    systemctl restart nifi.service
    local t=0
    while [ "$t" -lt 300 ]; do
        if ss -ltn 2>/dev/null | grep -q ":${NIFI_HTTPS_PORT} "; then log "NiFi is listening on port ${NIFI_HTTPS_PORT}."; return; fi
        sleep 5; t=$((t + 5))
    done
    warn "NiFi did not open port ${NIFI_HTTPS_PORT} within 5 minutes. Check ${NIFI_LOG_DIR}/nifi-app.log"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_root
    log "=== NiFi ${NIFI_VERSION} installation started (log: $LOG_FILE) ==="
    detect_os
    install_prereqs
    detect_java_home
    detect_network
    prompt_mode
    prompt_disk
    setup_paths
    build_ssh_opts

    if [ "$MODE" = "standalone" ]; then
        prompt_credentials
        prompt_standalone_addr
        generate_shared_secrets
    else
        prompt_cluster_topology
        if [ "$THIS_NODE_NUM" -eq 1 ]; then
            prompt_credentials
            prompt_ssh_access
            generate_shared_secrets
        else
            prompt_ssh_access
            acquire_and_load_bundle      # fails early if Node 1's bundle isn't available
        fi
    fi
    build_proxy_host_value

    create_directories
    download_and_install_nifi
    generate_tls
    apply_nifi_config
    create_systemd_service
    install_postgres_jar
    set_single_user_credentials
    save_credentials_file

    if [ "$MODE" = "cluster" ] && [ "$THIS_NODE_NUM" -eq 1 ]; then
        create_bundle
        push_bundle
    fi
    if [ "$MODE" = "cluster" ] && [ "$THIS_NODE_NUM" -eq 2 ]; then
        rm -rf "$BUNDLE_DIR" "$BUNDLE_TGZ"      # secrets no longer needed on Node 2's /tmp
    fi

    start_nifi

    echo
    log "=== NiFi installation complete ($MODE${THIS_NODE_NUM:+ node $THIS_NODE_NUM}) ==="
    log "URL:      https://${THIS_NODE_ADDR}:${NIFI_HTTPS_PORT}/nifi"
    log "Login:    $NIFI_ADMIN_USER"
    log "Secrets:  $CREDS_FILE"
    log "Log:      $LOG_FILE"
    if [ "$MODE" = "cluster" ]; then
        warn "Ports required BETWEEN nodes: 2181, 2888, 3888, ${NIFI_CLUSTER_PROTOCOL_PORT}, ${NIFI_LOAD_BALANCE_PORT}, ${NIFI_HTTPS_PORT} (+22 for bundle transfer)."
        if [ "$THIS_NODE_NUM" -eq 1 ]; then
            if [ "$BUNDLE_PUSHED" = "true" ]; then
                log "Bundle already delivered to Node 2. Now run this script on Node 2 - nothing secret to type."
            else
                warn "Bundle NOT delivered automatically. Copy $BUNDLE_TGZ to Node 2 at the same path (or let Node 2 pull it over SSH), then run the script there."
            fi
            warn "Node 1 keeps the CA key in $PKI_DIR (needed to add nodes later). Delete $BUNDLE_TGZ once Node 2 is installed."
        else
            log "Both nodes installed. Allow 1-5 minutes for election, then confirm 2 connected nodes in the UI."
        fi
    fi
}

main "$@"

