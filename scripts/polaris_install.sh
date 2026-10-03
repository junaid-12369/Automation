#!/bin/bash

#================================================================
# Apache Polaris 1.4.1 Installer  (S3-backed edition)
#
# Target:
#   Ubuntu / Debian
#   RHEL / Rocky / AlmaLinux / CentOS / Fedora / Amazon Linux
#
# Installs:
#   Apache Polaris : 1.4.1 binary distribution
#   Java           : 21+
#
# Creates:
#   Dedicated user : polaris
#   systemd unit   : /etc/systemd/system/polaris.service
#   env file       : <BASE_DIR>/apps/polaris/polaris.env
#
# Ports:
#   8181 - Polaris REST API
#   8182 - Management / health / metrics
#
# Changes vs the original script (found through live troubleshooting):
#
#   1. Removed POLARIS_AUTHENTICATION_ANONYMOUS_ENABLED.
#      This is not a real Polaris 1.4.1 config property - it was
#      silently ignored, so every request always required a real
#      OAuth2 bearer token anyway. Root credentials are now captured
#      automatically instead (see step 21).
#
#   2. Removed POLARIS_FEATURES_ALLOW_INSECURE_STORAGE_TYPES and
#      POLARIS_FEATURES_SUPPORTED_CATALOG_STORAGE_TYPES.
#      Setting these (via env var, application.properties, OR
#      -D system property) makes Polaris 1.4.1's bundled defaults
#      jar fail eager config validation at startup
#      ("SRCFG00050 ... does not map to any root") - this appears
#      to be a real packaging bug in this release. Since S3 storage
#      is supported out of the box with no extra flags needed, the
#      installer now provisions an S3-backed catalog instead of a
#      local FILE-backed one and never touches this property.
#
#   3. Installer now prompts for an S3 bucket name (required), plus
#      region and an IAM role ARN (auto-detected from instance
#      metadata via IMDSv2 where possible), and automatically
#      creates a working catalog against that bucket after Polaris
#      comes up.
#
#   4. Root principal credentials (client id/secret), which Polaris
#      only ever prints once per bootstrap, are now automatically
#      captured from the log and saved to a root-owned, 600-permission
#      file so they are not lost.
#
# Known limitation carried over from testing:
#   By default Polaris uses in-memory persistence unless
#   polaris.persistence.type / POLARIS_PERSISTENCE_TYPE is set to
#   relational-jdbc with a real database configured. In-memory means
#   every service restart wipes root credentials AND catalogs. This
#   script does NOT configure a persistent metastore - see the
#   printed summary at the end for next steps if you need one.
#
# Recommended:
#   Use an EC2 IAM Instance Role instead of static AWS access keys.
#================================================================

set -Eeuo pipefail

# ----------------------------------------------------------------
# 0. Versions and constants
# ----------------------------------------------------------------

POLARIS_VERSION="1.4.1"
POLARIS_BIN_TGZ="polaris-bin-${POLARIS_VERSION}.tgz"

JAVA_MAJOR="21"

SERVICE_USER="polaris"
SERVICE_GROUP="polaris"

# Polaris 1.4.1 is an older release, therefore archive.apache.org
# is preferred.
POLARIS_BIN_URLS=(
    "https://archive.apache.org/dist/polaris/${POLARIS_VERSION}/${POLARIS_BIN_TGZ}"
    "https://archive.apache.org/dist/incubator/polaris/${POLARIS_VERSION}/${POLARIS_BIN_TGZ}"
)

TEMURIN_FALLBACK_URL="https://api.adoptium.net/v3/binary/latest/${JAVA_MAJOR}/ga/linux/x64/jre/hotspot/normal/eclipse"

IMDS_URL="http://169.254.169.254/latest"

# ----------------------------------------------------------------
# 1. Logging
# ----------------------------------------------------------------

SCRIPT_PWD="$(pwd)"
FILENAME="$(date '+%d%m%Y%H%M%S')"

ACCESS_LOG="${SCRIPT_PWD}/polaris_install.access.${FILENAME}.log"
ERROR_LOG="${SCRIPT_PWD}/polaris_install.error.${FILENAME}.log"

touch "$ACCESS_LOG" "$ERROR_LOG"

log() {
    local msg="$1"
    echo "[$(date '+%F %T')] $msg" | tee -a "$ACCESS_LOG"
}

warn() {
    local msg="$1"
    echo "[$(date '+%F %T')] WARNING: $msg" \
        | tee -a "$ERROR_LOG" >&2
}

die() {
    local msg="$1"
    echo "[$(date '+%F %T')] ERROR: $msg" \
        | tee -a "$ERROR_LOG" >&2
    exit 1
}

trap 'echo "[$(date "+%F %T")] ERROR at line $LINENO. Check $ERROR_LOG" | tee -a "$ERROR_LOG" >&2' ERR

log "Starting Apache Polaris ${POLARIS_VERSION} installation."

# ----------------------------------------------------------------
# 2. Root / sudo detection
# ----------------------------------------------------------------

if [[ "$EUID" -eq 0 ]]; then
    SUDO=""
    log "Running as root."
else
    if ! command -v sudo >/dev/null 2>&1; then
        die "This script requires root privileges or sudo."
    fi

    SUDO="sudo"

    log "Running through sudo."

    $SUDO -v || die "Unable to obtain sudo privileges."
fi

# ----------------------------------------------------------------
# 3. Get base installation directory
#
#    Rejects empty input, "/", and other dangerous top-level
#    paths so a stray keystroke can't make the installer write
#    files directly under the root filesystem.
# ----------------------------------------------------------------

echo

while true; do

    read -rp "Enter base install directory [default: /opt/ausiytic]: " BASE_DIR

    BASE_DIR="${BASE_DIR:-/opt/ausiytic}"
    BASE_DIR="${BASE_DIR%/}"

    case "$BASE_DIR" in
        ""|"/"|"/etc"|"/home"|"/usr"|"/var"|"/bin"|"/sbin"|"/root"|"/opt"|"/tmp"|"/boot"|"/lib"|"/lib64"|"/proc"|"/sys"|"/dev")
            echo "Refusing unsafe base directory: '${BASE_DIR:-/}'. Choose something like /opt/ausiytic."
            continue
            ;;
    esac

    if [[ "$BASE_DIR" != /* ]]; then
        echo "Base directory must be an absolute path (e.g. /opt/ausiytic)."
        continue
    fi

    break

done

SOURCE="${BASE_DIR}/softwares"
POLARIS_HOME="${BASE_DIR}/apps/polaris/binaries"
POLARIS_CONFIG_DIR="${BASE_DIR}/apps/polaris/config"
POLARIS_LOGS="${BASE_DIR}/logs/polaris"
POLARIS_ENV_FILE="${BASE_DIR}/apps/polaris/polaris.env"
ROOT_CREDENTIALS_FILE="${BASE_DIR}/apps/polaris/ROOT_CREDENTIALS.txt"

# ----------------------------------------------------------------
# 3.5 S3 storage configuration
#
#     Polaris 1.4.1 supports S3/GCS/AZURE storage out of the box.
#     FILE storage requires a feature-flag override that crashes
#     this release's config validation at startup (see header
#     notes), so this installer always provisions an S3-backed
#     catalog instead.
# ----------------------------------------------------------------

echo
echo "=============================================================="
echo " S3 catalog storage configuration"
echo "=============================================================="

while true; do
    read -rp "Enter the S3 bucket name to use for the Polaris warehouse (required): " S3_BUCKET

    if [[ -z "$S3_BUCKET" ]]; then
        echo "Bucket name cannot be empty."
        continue
    fi

    break
done

# --- Try to auto-detect region and account/role from instance metadata (IMDSv2) ---

IMDS_TOKEN=""
DETECTED_REGION=""
DETECTED_ACCOUNT_ID=""
DETECTED_ROLE_NAME=""
DETECTED_ROLE_ARN=""

IMDS_TOKEN="$(curl -s -X PUT "${IMDS_URL}/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    --max-time 3 2>/dev/null || true)"

if [[ -n "$IMDS_TOKEN" ]]; then

    DETECTED_REGION="$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        --max-time 3 \
        "${IMDS_URL}/dynamic/instance-identity/document" 2>/dev/null \
        | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

    DETECTED_ACCOUNT_ID="$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        --max-time 3 \
        "${IMDS_URL}/dynamic/instance-identity/document" 2>/dev/null \
        | sed -n 's/.*"accountId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

    DETECTED_ROLE_NAME="$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        --max-time 3 \
        "${IMDS_URL}/meta-data/iam/security-credentials/" 2>/dev/null || true)"

    if [[ -n "$DETECTED_ROLE_NAME" ]] && [[ -n "$DETECTED_ACCOUNT_ID" ]]; then
        DETECTED_ROLE_ARN="arn:aws:iam::${DETECTED_ACCOUNT_ID}:role/${DETECTED_ROLE_NAME}"
    fi

fi

if [[ -n "$DETECTED_REGION" ]]; then
    log "Auto-detected AWS region from instance metadata: ${DETECTED_REGION}"
else
    warn "Could not auto-detect AWS region from instance metadata."
fi

if [[ -n "$DETECTED_ROLE_ARN" ]]; then
    log "Auto-detected IAM instance role: ${DETECTED_ROLE_ARN}"
else
    warn "No IAM instance role detected on this EC2 instance."
fi

echo
read -rp "AWS region [default: ${DETECTED_REGION:-us-east-1}]: " S3_REGION
S3_REGION="${S3_REGION:-${DETECTED_REGION:-us-east-1}}"

echo
while true; do

    if [[ -n "$DETECTED_ROLE_ARN" ]]; then
        read -rp "IAM role ARN for Polaris to assume for S3 access [default: ${DETECTED_ROLE_ARN}]: " S3_ROLE_ARN
        S3_ROLE_ARN="${S3_ROLE_ARN:-$DETECTED_ROLE_ARN}"
    else
        read -rp "IAM role ARN for Polaris to assume for S3 access (required, e.g. arn:aws:iam::123456789012:role/my-role): " S3_ROLE_ARN
    fi

    if [[ -z "$S3_ROLE_ARN" ]]; then
        echo "Role ARN cannot be empty - Polaris needs this to vend scoped S3 credentials via STS."
        continue
    fi

    # Must look like a real IAM role ARN, e.g.
    # arn:aws:iam::123456789012:role/my-role
    # This catches common mistakes like typing just the role NAME
    # (e.g. "admin12334") or a stray leading "/" instead of pressing
    # Enter to accept the bracketed default.
    if [[ ! "$S3_ROLE_ARN" =~ ^arn:aws:iam::[0-9]{12}:role/.+ ]]; then
        echo "That doesn't look like a valid IAM role ARN."
        echo "Expected format: arn:aws:iam::<12-digit-account-id>:role/<role-name>"
        if [[ -n "$DETECTED_ROLE_ARN" ]]; then
            echo "Press Enter with no input to accept the detected default: ${DETECTED_ROLE_ARN}"
        fi
        continue
    fi

    break

done

echo
read -rp "Catalog name to create [default: default]: " CATALOG_NAME
CATALOG_NAME="${CATALOG_NAME:-default}"

S3_WAREHOUSE_LOCATION="s3://${S3_BUCKET}/warehouse"

echo
echo "=============================================================="
echo " Apache Polaris installation"
echo "=============================================================="
echo " Version          : ${POLARIS_VERSION}"
echo " Base directory   : ${BASE_DIR}"
echo " Download dir     : ${SOURCE}"
echo " Polaris home     : ${POLARIS_HOME}"
echo " Configuration    : ${POLARIS_CONFIG_DIR}"
echo " Logs             : ${POLARIS_LOGS}"
echo " Environment file : ${POLARIS_ENV_FILE}"
echo " --------------------------------------------------------------"
echo " S3 bucket        : ${S3_BUCKET}"
echo " Warehouse path   : ${S3_WAREHOUSE_LOCATION}"
echo " AWS region       : ${S3_REGION}"
echo " IAM role ARN     : ${S3_ROLE_ARN}"
echo " Catalog name     : ${CATALOG_NAME}"
echo "=============================================================="
echo

read -rp "Proceed with installation? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# ----------------------------------------------------------------
# 4. Detect OS / package manager
# ----------------------------------------------------------------

PKG_MGR=""

if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
else
    die "No supported package manager found. Supported: apt, yum, dnf."
fi

log "Detected package manager: ${PKG_MGR}"

# ----------------------------------------------------------------
# 5. Install base dependencies
# ----------------------------------------------------------------

log "Installing required operating system packages."

case "$PKG_MGR" in

    apt)

        export DEBIAN_FRONTEND=noninteractive

        $SUDO apt-get update \
            >>"$ACCESS_LOG" 2>>"$ERROR_LOG"

        $SUDO apt-get install -y \
            tar \
            gzip \
            wget \
            curl \
            ca-certificates \
            coreutils \
            file \
            procps \
            >>"$ACCESS_LOG" 2>>"$ERROR_LOG"

        ;;

    yum|dnf)

        $SUDO "$PKG_MGR" install -y \
            tar \
            gzip \
            wget \
            curl \
            ca-certificates \
            which \
            file \
            procps-ng \
            >>"$ACCESS_LOG" 2>>"$ERROR_LOG"

        ;;

esac

log "Operating system dependencies installed."

# ----------------------------------------------------------------
# 6. Create directories
# ----------------------------------------------------------------

log "Creating Polaris directories."

$SUDO mkdir -p \
    "$SOURCE" \
    "$POLARIS_HOME" \
    "$POLARIS_CONFIG_DIR" \
    "$POLARIS_LOGS"

# ----------------------------------------------------------------
# 7. Install / verify Java 21+
# ----------------------------------------------------------------

get_java_major() {

    if ! command -v java >/dev/null 2>&1; then
        return 1
    fi

    java -version 2>&1 \
        | head -n 1 \
        | sed -E 's/.*version "?([0-9]+).*/\1/'
}

ensure_java21() {

    local current_java=""

    if command -v java >/dev/null 2>&1; then

        current_java="$(get_java_major || true)"

        if [[ "$current_java" =~ ^[0-9]+$ ]] \
            && (( current_java >= JAVA_MAJOR )); then

            log "Java ${current_java} already installed."
            return 0
        fi

        warn "Existing Java version does not satisfy Java ${JAVA_MAJOR}+ requirement."
    fi

    log "Trying to install Java ${JAVA_MAJOR} from operating system repositories."

    case "$PKG_MGR" in

        apt)

            if $SUDO apt-get install -y \
                "openjdk-${JAVA_MAJOR}-jre-headless" \
                >>"$ACCESS_LOG" 2>>"$ERROR_LOG"; then

                log "Installed OpenJDK ${JAVA_MAJOR}."
                return 0
            fi

            ;;

        yum|dnf)

            if $SUDO "$PKG_MGR" install -y \
                "java-${JAVA_MAJOR}-openjdk-headless" \
                >>"$ACCESS_LOG" 2>>"$ERROR_LOG"; then

                log "Installed OpenJDK ${JAVA_MAJOR}."
                return 0
            fi

            ;;

    esac

    # ------------------------------------------------------------
    # Fallback to Temurin
    # ------------------------------------------------------------

    warn "Java ${JAVA_MAJOR} package unavailable. Using Temurin fallback."

    local jre_dir="/opt/temurin-${JAVA_MAJOR}-jre"
    local jre_archive="${SOURCE}/temurin-${JAVA_MAJOR}-jre.tar.gz"

    if [[ ! -x "${jre_dir}/bin/java" ]]; then

        log "Downloading Temurin Java ${JAVA_MAJOR} JRE."

        rm -f "$jre_archive"

        wget \
            --timeout=60 \
            --tries=3 \
            -O "$jre_archive" \
            "$TEMURIN_FALLBACK_URL" \
            >>"$ACCESS_LOG" 2>>"$ERROR_LOG" \
            || die "Failed downloading Temurin Java ${JAVA_MAJOR}."

        [[ -s "$jre_archive" ]] \
            || die "Downloaded Temurin archive is empty."

        tar -tzf "$jre_archive" >/dev/null 2>&1 \
            || die "Downloaded Temurin archive is invalid."

        $SUDO rm -rf "$jre_dir"
        $SUDO mkdir -p "$jre_dir"

        $SUDO tar \
            -xzf "$jre_archive" \
            -C "$jre_dir" \
            --strip-components=1 \
            || die "Failed extracting Temurin Java."

    fi

    $SUDO ln -sf "${jre_dir}/bin/java" /usr/local/bin/java

    log "Temurin Java ${JAVA_MAJOR} installed."
}

ensure_java21

# ----------------------------------------------------------------
# 8. Resolve JAVA_HOME and verify
# ----------------------------------------------------------------

JAVA_BIN="$(readlink -f "$(command -v java)")"
JAVA_HOME_RESOLVED="$(dirname "$(dirname "$JAVA_BIN")")"

JAVA_VERSION="$(java -version 2>&1 | head -n 1)"

log "Java detected: ${JAVA_VERSION}"
log "JAVA_HOME=${JAVA_HOME_RESOLVED}"

JAVA_MAJOR_INSTALLED="$(get_java_major || true)"

if [[ ! "$JAVA_MAJOR_INSTALLED" =~ ^[0-9]+$ ]]; then
    die "Unable to determine installed Java version."
fi

if (( JAVA_MAJOR_INSTALLED < JAVA_MAJOR )); then
    die "Java ${JAVA_MAJOR}+ required, but Java ${JAVA_MAJOR_INSTALLED} is active."
fi

# ----------------------------------------------------------------
# 9. Create dedicated Polaris service account
# ----------------------------------------------------------------

if id "$SERVICE_USER" >/dev/null 2>&1; then

    log "Service account '${SERVICE_USER}' already exists."

else

    log "Creating service account '${SERVICE_USER}'."

    NOLOGIN_SHELL="$(command -v nologin || true)"

    if [[ -z "$NOLOGIN_SHELL" ]]; then
        NOLOGIN_SHELL="/usr/sbin/nologin"
    fi

    $SUDO useradd \
        --system \
        --no-create-home \
        --shell "$NOLOGIN_SHELL" \
        "$SERVICE_USER" \
        || die "Unable to create service account '${SERVICE_USER}'."

fi

# ----------------------------------------------------------------
# 10. Polaris download
# ----------------------------------------------------------------

VERSION_MARKER="${POLARIS_HOME}/.polaris_version"
DOWNLOAD_FILE="${SOURCE}/${POLARIS_BIN_TGZ}"

NEED_INSTALL="true"

if [[ -f "$VERSION_MARKER" ]] \
    && [[ "$(cat "$VERSION_MARKER")" == "$POLARIS_VERSION" ]] \
    && [[ -x "${POLARIS_HOME}/bin/server" ]]; then

    log "Polaris ${POLARIS_VERSION} is already installed."
    NEED_INSTALL="false"

fi

if [[ "$NEED_INSTALL" == "true" ]]; then

    log "Preparing to install Polaris ${POLARIS_VERSION}."

    # ------------------------------------------------------------
    # Preserve previous Polaris installation
    # ------------------------------------------------------------

    if [[ -d "$POLARIS_HOME" ]] \
        && [[ -n "$(ls -A "$POLARIS_HOME" 2>/dev/null)" ]]; then

        BACKUP="${POLARIS_HOME}_bkp_$(date '+%Y%m%d%H%M%S')"

        log "Backing up existing installation to ${BACKUP}."

        $SUDO cp -a "$POLARIS_HOME" "$BACKUP" \
            || warn "Could not create backup of existing Polaris installation."

        $SUDO rm -rf "${POLARIS_HOME:?}"/*

    fi

    # ------------------------------------------------------------
    # Check whether an already downloaded archive is valid
    # ------------------------------------------------------------

    ARCHIVE_VALID="false"

    if [[ -f "$DOWNLOAD_FILE" ]]; then

        log "Existing Polaris archive detected."

        if tar -tzf "$DOWNLOAD_FILE" >/dev/null 2>&1; then

            log "Existing archive is valid. Reusing it."
            ARCHIVE_VALID="true"

        else

            warn "Existing Polaris archive is incomplete or invalid. Removing it."
            rm -f "$DOWNLOAD_FILE"

        fi
    fi

    # ------------------------------------------------------------
    # Download archive
    # ------------------------------------------------------------

    if [[ "$ARCHIVE_VALID" != "true" ]]; then

        DOWNLOAD_OK=""

        for url in "${POLARIS_BIN_URLS[@]}"; do

            log "Downloading Polaris from:"
            log "${url}"

            # Use wget --continue so an interrupted 335 MB download
            # can resume instead of starting again.

            if wget \
                --continue \
                --timeout=60 \
                --tries=5 \
                --retry-connrefused \
                -O "$DOWNLOAD_FILE" \
                "$url" \
                >>"$ACCESS_LOG" 2>>"$ERROR_LOG"; then

                log "Download completed. Validating archive."

                if tar -tzf "$DOWNLOAD_FILE" >/dev/null 2>&1; then

                    DOWNLOAD_OK="$url"
                    log "Polaris archive validation successful."
                    break

                else

                    warn "Downloaded file is not a valid gzip tar archive."
                    rm -f "$DOWNLOAD_FILE"

                fi

            else

                warn "Download failed from ${url}."

            fi

        done

        [[ -n "$DOWNLOAD_OK" ]] \
            || die "Unable to download Polaris ${POLARIS_VERSION}."

    fi

    # ------------------------------------------------------------
    # Final archive validation
    # ------------------------------------------------------------

    log "Performing final validation of Polaris archive."

    [[ -s "$DOWNLOAD_FILE" ]] \
        || die "Polaris archive does not exist or is empty."

    tar -tzf "$DOWNLOAD_FILE" >/dev/null 2>&1 \
        || die "Polaris archive failed gzip/tar integrity validation."

    ARCHIVE_SIZE="$(du -h "$DOWNLOAD_FILE" | awk '{print $1}')"

    log "Archive size: ${ARCHIVE_SIZE}"

    # ------------------------------------------------------------
    # Determine archive top-level directory
    #
    # NOTE: `awk '... {print $1; exit}'` closes its stdin as soon
    # as it reads the first line, so `tar -tzf` -- which is still
    # trying to write the rest of a 335 MB listing into the pipe --
    # receives SIGPIPE and exits non-zero. Under `set -o pipefail`
    # that makes the whole command substitution register as a
    # failure even though TOP_DIR is captured correctly, which
    # trips `set -e` and kills the script via the ERR trap before
    # the die() check below ever runs. The trailing `true` forces
    # the substitution's exit status to 0 regardless of the
    # pipeline's SIGPIPE, while the real safety net (the
    # `[[ -n "$TOP_DIR" ]] || die ...` check) still catches a
    # genuinely empty result.
    # ------------------------------------------------------------

    TOP_DIR="$(
        tar -tzf "$DOWNLOAD_FILE" \
            | awk -F/ 'NF {print $1; exit}'
        true
    )"

    [[ -n "$TOP_DIR" ]] \
        || die "Unable to determine archive top-level directory."

    log "Archive directory detected: ${TOP_DIR}"

    # ------------------------------------------------------------
    # Extract
    # ------------------------------------------------------------

    EXTRACT_DIR="${SOURCE}/${TOP_DIR}"

    rm -rf "$EXTRACT_DIR"

    log "Extracting Polaris distribution."

    tar \
        -xzf "$DOWNLOAD_FILE" \
        -C "$SOURCE" \
        >>"$ACCESS_LOG" 2>>"$ERROR_LOG" \
        || die "Failed extracting Polaris archive."

    [[ -d "$EXTRACT_DIR" ]] \
        || die "Expected extracted directory ${EXTRACT_DIR} was not created."

    # ------------------------------------------------------------
    # Verify server binary exists
    # ------------------------------------------------------------

    [[ -f "${EXTRACT_DIR}/bin/server" ]] \
        || die "bin/server does not exist in Polaris binary distribution."

    # ------------------------------------------------------------
    # Install files
    # ------------------------------------------------------------

    log "Copying Polaris files to ${POLARIS_HOME}."

    $SUDO mkdir -p "$POLARIS_HOME"

    $SUDO cp -a \
        "${EXTRACT_DIR}/." \
        "${POLARIS_HOME}/"

    $SUDO chmod +x "${POLARIS_HOME}/bin/server"

    echo "$POLARIS_VERSION" \
        | $SUDO tee "$VERSION_MARKER" >/dev/null

    log "Polaris ${POLARIS_VERSION} installed."

fi

# ----------------------------------------------------------------
# 11. Ownership
# ----------------------------------------------------------------

log "Setting Polaris directory permissions."

$SUDO chown -R \
    "${SERVICE_USER}:${SERVICE_GROUP}" \
    "$POLARIS_HOME" \
    "$POLARIS_LOGS" \
    "$POLARIS_CONFIG_DIR"

# ----------------------------------------------------------------
# 12. Create Polaris environment configuration
#
#     NOTE: POLARIS_AUTHENTICATION_ANONYMOUS_ENABLED and the
#     POLARIS_FEATURES_* storage-type overrides that were here
#     previously have been removed - see header notes for why.
# ----------------------------------------------------------------

if [[ -f "$POLARIS_ENV_FILE" ]]; then

    log "Existing environment file found."
    log "Preserving: ${POLARIS_ENV_FILE}"

else

    log "Creating Polaris environment file."

    $SUDO tee "$POLARIS_ENV_FILE" >/dev/null <<EOF
#================================================================
# Apache Polaris Configuration
#================================================================

# ---------------------------------------------------------------
# Quarkus
# ---------------------------------------------------------------

QUARKUS_PROFILE=prod

# Main Polaris REST API
QUARKUS_HTTP_HOST=0.0.0.0
QUARKUS_HTTP_PORT=8181


# ---------------------------------------------------------------
# Polaris
# ---------------------------------------------------------------

POLARIS_DEFAULT_CATALOG_ENABLED=true
POLARIS_ICEBERG_REST_ENABLED=true


# ---------------------------------------------------------------
# AWS
#
# An IAM Instance Profile / IAM Role is attached to this EC2
# instance and used by Polaris to assume the per-catalog roleArn
# via STS. DO NOT configure AWS_ACCESS_KEY_ID or
# AWS_SECRET_ACCESS_KEY here.
# ---------------------------------------------------------------

AWS_DEFAULT_REGION=${S3_REGION}


# ---------------------------------------------------------------
# Observability
# ---------------------------------------------------------------

QUARKUS_MICROMETER_ENABLED=true
QUARKUS_MICROMETER_EXPORT_PROMETHEUS_ENABLED=true
QUARKUS_SMALLRYE_OPENAPI_ENABLE=true

EOF

    $SUDO chown \
        "${SERVICE_USER}:${SERVICE_GROUP}" \
        "$POLARIS_ENV_FILE"

    $SUDO chmod 600 "$POLARIS_ENV_FILE"

    log "Created Polaris environment file."

fi

# ----------------------------------------------------------------
# 13. Create systemd service
# ----------------------------------------------------------------

POLARIS_SERVICE="/etc/systemd/system/polaris.service"

log "Creating systemd service."

$SUDO tee "$POLARIS_SERVICE" >/dev/null <<EOF
[Unit]
Description=Apache Polaris Iceberg REST Catalog
Documentation=https://polaris.apache.org/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple

User=${SERVICE_USER}
Group=${SERVICE_GROUP}

WorkingDirectory=${POLARIS_HOME}

EnvironmentFile=${POLARIS_ENV_FILE}

Environment="JAVA_HOME=${JAVA_HOME_RESOLVED}"
Environment="PATH=${JAVA_HOME_RESOLVED}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"

ExecStart=${POLARIS_HOME}/bin/server

Restart=on-failure
RestartSec=10

TimeoutStartSec=120
TimeoutStopSec=30

SuccessExitStatus=143

StandardOutput=append:${POLARIS_LOGS}/polaris.log
StandardError=append:${POLARIS_LOGS}/polaris.error.log

LimitNOFILE=65536

NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

$SUDO chmod 644 "$POLARIS_SERVICE"

# ----------------------------------------------------------------
# 14. Reload systemd
# ----------------------------------------------------------------

log "Reloading systemd configuration."

$SUDO systemctl daemon-reload

log "Enabling polaris.service."

$SUDO systemctl enable polaris.service \
    >>"$ACCESS_LOG" 2>>"$ERROR_LOG"

# ----------------------------------------------------------------
# 15. Verify Polaris binary before service startup
# ----------------------------------------------------------------

if [[ ! -x "${POLARIS_HOME}/bin/server" ]]; then
    die "${POLARIS_HOME}/bin/server is missing or not executable."
fi

log "Polaris server executable verified."

# ----------------------------------------------------------------
# 16. Start Polaris
# ----------------------------------------------------------------

log "Starting Polaris service."

if ! $SUDO systemctl restart polaris.service; then

    warn "Polaris service failed to start."

    echo
    echo "================ SERVICE STATUS ================="

    $SUDO systemctl status \
        polaris.service \
        --no-pager \
        -l || true

    echo
    echo "================ JOURNAL ========================"

    $SUDO journalctl \
        -u polaris.service \
        --no-pager \
        -n 100 || true

    echo
    echo "================ POLARIS ERROR LOG ============="

    $SUDO tail \
        -n 100 \
        "${POLARIS_LOGS}/polaris.error.log" || true

    echo
    echo "================================================="

    die "Polaris failed to start. Review diagnostics above."

fi

# ----------------------------------------------------------------
# 17. Wait for startup
# ----------------------------------------------------------------

log "Waiting for Polaris to initialize."

HEALTH_OK="false"

for attempt in {1..30}; do

    if ! $SUDO systemctl is-active --quiet polaris.service; then

        warn "Polaris service stopped unexpectedly."

        break
    fi

    if curl \
        --silent \
        --fail \
        --max-time 3 \
        "http://127.0.0.1:8182/q/health" \
        >/dev/null 2>&1; then

        HEALTH_OK="true"
        break
    fi

    log "Waiting for health endpoint... (${attempt}/30)"

    sleep 2

done

# ----------------------------------------------------------------
# 18. Final service verification
# ----------------------------------------------------------------

if ! $SUDO systemctl is-active --quiet polaris.service; then

    echo
    echo "================ SERVICE STATUS ================="

    $SUDO systemctl status \
        polaris.service \
        --no-pager \
        -l || true

    echo
    echo "================ POLARIS ERROR LOG ============="

    $SUDO tail \
        -n 100 \
        "${POLARIS_LOGS}/polaris.error.log" || true

    die "Polaris service is not active."

fi

# ----------------------------------------------------------------
# 19. Check listening ports
# ----------------------------------------------------------------

PORT_8181="NOT DETECTED"
PORT_8182="NOT DETECTED"

if command -v ss >/dev/null 2>&1; then

    if ss -lnt 2>/dev/null | grep -q ':8181'; then
        PORT_8181="LISTENING"
    fi

    if ss -lnt 2>/dev/null | grep -q ':8182'; then
        PORT_8182="LISTENING"
    fi

fi

# ----------------------------------------------------------------
# 20. Capture root principal credentials
#
#     Polaris prints these to stdout (captured into polaris.log)
#     exactly once, on the bootstrap that creates the realm. If
#     this log line is ever lost, the root principal cannot be
#     recovered without wiping the metastore, so grab it now and
#     store it in a protected file.
# ----------------------------------------------------------------

ROOT_CLIENT_ID=""
ROOT_CLIENT_SECRET=""
CATALOG_CREATED="false"
CATALOG_CREATE_RESPONSE=""

log "Capturing root principal credentials."

for attempt in {1..15}; do

    ROOT_LINE="$($SUDO grep -a -i "root principal credentials" "${POLARIS_LOGS}/polaris.log" 2>/dev/null | tail -1 || true)"

    if [[ -n "$ROOT_LINE" ]]; then
        break
    fi

    sleep 1

done

if [[ -z "$ROOT_LINE" ]]; then

    warn "Could not find root principal credentials in ${POLARIS_LOGS}/polaris.log."
    warn "Skipping automatic catalog creation. You will need to bootstrap manually - see summary below."

else

    # Line looks like:
    # realm: POLARIS root principal credentials: <clientId>:<clientSecret>
    ROOT_CREDS="$(echo "$ROOT_LINE" | sed -n 's/.*credentials:[[:space:]]*\([^:]*\):\(.*\)$/\1:\2/p')"
    ROOT_CLIENT_ID="$(echo "$ROOT_CREDS" | cut -d: -f1)"
    ROOT_CLIENT_SECRET="$(echo "$ROOT_CREDS" | cut -d: -f2)"

    if [[ -z "$ROOT_CLIENT_ID" ]] || [[ -z "$ROOT_CLIENT_SECRET" ]]; then

        warn "Found a root-credentials log line but could not parse client id/secret from it:"
        warn "${ROOT_LINE}"

    else

        log "Root principal credentials captured."

        $SUDO tee "$ROOT_CREDENTIALS_FILE" >/dev/null <<EOF
# Apache Polaris root principal credentials
# Captured: $(date '+%F %T')
# WARNING: these are printed by Polaris only ONCE per realm
# bootstrap. If this file is lost and the log has rotated,
# the root principal cannot be recovered without wiping the
# metastore and re-bootstrapping.

realm=POLARIS
client_id=${ROOT_CLIENT_ID}
client_secret=${ROOT_CLIENT_SECRET}
EOF

        $SUDO chown "${SERVICE_USER}:${SERVICE_GROUP}" "$ROOT_CREDENTIALS_FILE"
        $SUDO chmod 600 "$ROOT_CREDENTIALS_FILE"

        log "Root credentials saved to ${ROOT_CREDENTIALS_FILE} (chmod 600, owned by ${SERVICE_USER})."

    fi

fi

# ----------------------------------------------------------------
# 21. Bootstrap the S3-backed catalog
# ----------------------------------------------------------------

if [[ -n "$ROOT_CLIENT_ID" ]] && [[ -n "$ROOT_CLIENT_SECRET" ]]; then

    log "Requesting OAuth2 token for catalog bootstrap."

    TOKEN_RESPONSE="$(curl -s -X POST "http://127.0.0.1:8181/api/catalog/v1/oauth/tokens" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${ROOT_CLIENT_ID}" \
        --data-urlencode "client_secret=${ROOT_CLIENT_SECRET}" \
        --data-urlencode "scope=PRINCIPAL_ROLE:ALL" || true)"

    ACCESS_TOKEN="$(echo "$TOKEN_RESPONSE" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"

    if [[ -z "$ACCESS_TOKEN" ]]; then

        warn "Failed to obtain an OAuth2 token. Response was:"
        warn "${TOKEN_RESPONSE}"
        warn "Skipping automatic catalog creation - see summary below for manual steps."

    else

        log "Creating catalog '${CATALOG_NAME}' against s3://${S3_BUCKET}."

        CATALOG_PAYLOAD=$(cat <<EOF
{
  "catalog": {
    "name": "${CATALOG_NAME}",
    "type": "INTERNAL",
    "properties": {"default-base-location": "${S3_WAREHOUSE_LOCATION}"},
    "storageConfigInfo": {
      "storageType": "S3",
      "roleArn": "${S3_ROLE_ARN}",
      "region": "${S3_REGION}"
    }
  }
}
EOF
)

        CATALOG_CREATE_RESPONSE="$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST \
            "http://127.0.0.1:8181/api/management/v1/catalogs" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${CATALOG_PAYLOAD}" || true)"

        HTTP_STATUS="$(echo "$CATALOG_CREATE_RESPONSE" | sed -n 's/.*HTTP_STATUS:\([0-9]*\)$/\1/p')"

        if [[ "$HTTP_STATUS" == "201" ]]; then
            log "Catalog '${CATALOG_NAME}' created successfully."
            CATALOG_CREATED="true"
        elif [[ "$HTTP_STATUS" == "409" ]]; then
            log "Catalog '${CATALOG_NAME}' already exists. Leaving it as-is."
            CATALOG_CREATED="true"
        else
            warn "Catalog creation returned HTTP ${HTTP_STATUS}:"
            warn "$(echo "$CATALOG_CREATE_RESPONSE" | sed 's/HTTP_STATUS:[0-9]*$//')"
            warn "You may need to create the catalog manually - see summary below."
        fi

    fi

fi

# ----------------------------------------------------------------
# 22. Installation summary
# ----------------------------------------------------------------

echo
echo "=============================================================="
echo " Apache Polaris ${POLARIS_VERSION} installation complete"
echo "=============================================================="
echo " Service status     : $(systemctl is-active polaris.service 2>/dev/null || echo unknown)"
echo " Health check        : ${HEALTH_OK}"
echo " Port 8181 (REST)    : ${PORT_8181}"
echo " Port 8182 (Mgmt)    : ${PORT_8182}"
echo " Install dir         : ${POLARIS_HOME}"
echo " Env file            : ${POLARIS_ENV_FILE}"
echo " Logs                : ${POLARIS_LOGS}"
echo " --------------------------------------------------------------"
echo " S3 bucket           : ${S3_BUCKET}"
echo " Warehouse path      : ${S3_WAREHOUSE_LOCATION}"
echo " AWS region          : ${S3_REGION}"
echo " IAM role ARN        : ${S3_ROLE_ARN}"
echo " Catalog name        : ${CATALOG_NAME}"
echo " Catalog bootstrapped: ${CATALOG_CREATED}"
echo " --------------------------------------------------------------"

if [[ -n "$ROOT_CLIENT_ID" ]]; then
    echo " Root credentials    : saved to ${ROOT_CREDENTIALS_FILE} (chmod 600)"
else
    echo " Root credentials    : NOT CAPTURED - check ${POLARIS_LOGS}/polaris.log manually"
    echo "                       for a line containing 'root principal credentials'."
fi

echo " Manage with         : systemctl {status|restart|stop} polaris"
echo "=============================================================="
echo
echo "IMPORTANT - known limitations of this deployment:"
echo
echo "1. In-memory persistence: unless polaris.persistence.type is"
echo "   set to relational-jdbc with a real database, EVERY restart"
echo "   of polaris.service wipes root credentials, catalogs, and"
echo "   grants. This script does not configure that - it must be"
echo "   set up separately (Postgres/MySQL) if you need durability"
echo "   across restarts."
echo
echo "2. Ephemeral signing key: without"
echo "   polaris.authentication.token-broker.rsa-key-pair.*-key-file"
echo "   configured, every restart also invalidates all previously"
echo "   issued bearer tokens, independent of point 1."
echo
echo "Test the catalog with:"
echo
echo "  curl -X POST http://127.0.0.1:8181/api/catalog/v1/oauth/tokens \\"
echo "    --data-urlencode grant_type=client_credentials \\"
echo "    --data-urlencode client_id=<from ${ROOT_CREDENTIALS_FILE}> \\"
echo "    --data-urlencode client_secret=<from ${ROOT_CREDENTIALS_FILE}> \\"
echo "    --data-urlencode scope=PRINCIPAL_ROLE:ALL"
echo
echo "  curl -H \"Authorization: Bearer <access_token>\" \\"
echo "    \"http://127.0.0.1:8181/api/catalog/v1/config?warehouse=${CATALOG_NAME}\""
echo

log "Apache Polaris ${POLARIS_VERSION} installation finished."

