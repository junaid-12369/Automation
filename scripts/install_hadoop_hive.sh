#!/bin/bash
#================================================================
# DESCRIPTION
#   Fully automated installer for Apache Hadoop (client libraries
#   + CLI) and Apache Hive Metastore, wired up as a systemd service.
#   Automates the manual runbook: directories, downloads, AWS S3
#   jars, hive-env.sh, hive-site.xml (PostgreSQL metastore),
#   schematool -initSchema and the hive.service unit.
#
#   Versions installed:
#       hadoop : 3.4.1
#       hive   : 3.1.3
#       pgjdbc : 42.7.4  (replaces the old driver bundled with Hive)
#
#   Compatible with:
#       RHEL / CentOS / Rocky / AlmaLinux / Fedora / Amazon Linux (yum/dnf)
#       Debian / Ubuntu (apt-get)
#
#   Handles automatically:
#       - Root vs sudo (or dzdo) execution
#       - Java 8 detection/installation (Hive 3.1.3 needs Java 8).
#         JAVA_HOME is set ONLY in hadoop-env.sh, hive-env.sh and the
#         systemd unit -- never globally -- so other apps on the same
#         box (e.g. Spark on Java 17) are not affected.
#       - Hadoop/Hive compatibility fixes (Guava clash, PostgreSQL
#         JDBC driver that supports SCRAM-SHA-256 auth)
#       - Idempotent re-runs (skips what is already installed)
#       - SELinux (Enforcing) labels on RHEL-family systems
#
#   Notes:
#       - Hadoop is installed as a CLIENT (libs + hadoop/hdfs CLI +
#         S3A support). No HDFS/YARN daemons are started; Hive
#         Metastore is the only service created (hive.service).
#       - The PostgreSQL database for the metastore must already
#         exist and be reachable (script does NOT create it).
#
#   Usage:
#       chmod +x install_hadoop_hive.sh
#       ./install_hadoop_hive.sh          # interactive prompts
#
#   Optional non-interactive use (any of these can be pre-set):
#       BASE_DIR, SVC_USER, HIVE_DB_HOST, HIVE_DB_PORT, HIVE_DB_NAME,
#       HIVE_DB_USER, HIVE_DB_PASSWORD, HIVE_METASTORE_PORT,
#       HIVE_WAREHOUSE_DIR, JAVA_HOME_OVERRIDE, ASSUME_YES=y
#================================================================
# IMPLEMENTATION
#   Version  - v1
#================================================================

set -euo pipefail

# ---------------------------------------------------------------
# 0. Versions & constants
# ---------------------------------------------------------------
HADOOP_VERSION="3.4.1"
HIVE_VERSION="3.1.3"
PG_JDBC_VERSION="42.7.4"
SERVICE_NAME="hive"

HADOOP_TARBALL="hadoop-${HADOOP_VERSION}.tar.gz"
HADOOP_URL="https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_TARBALL}"

HIVE_TARBALL="apache-hive-${HIVE_VERSION}-bin.tar.gz"
HIVE_URL="https://archive.apache.org/dist/hive/hive-${HIVE_VERSION}/${HIVE_TARBALL}"

PG_JDBC_JAR="postgresql-${PG_JDBC_VERSION}.jar"
PG_JDBC_URL="https://repo1.maven.org/maven2/org/postgresql/postgresql/${PG_JDBC_VERSION}/${PG_JDBC_JAR}"

FILENAME=$(date +"%d%m%Y%H")
SCRIPT_PWD=$(pwd)
ACCESS_LOG="${SCRIPT_PWD}/hadoop_hive_install.access.${FILENAME}.log"
ERROR_LOG="${SCRIPT_PWD}/hadoop_hive_install.error.${FILENAME}.log"
SCHEMATOOL_LOG="${SCRIPT_PWD}/hive_schematool.${FILENAME}.log"

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
ask SVC_USER "OS user that will run the Hive service" "${SUDO_USER:-$(id -un)}"
id "$SVC_USER" >/dev/null 2>&1 || die "User '$SVC_USER' does not exist."
SVC_GROUP=$(id -gn "$SVC_USER")

HIVE_DB_HOST="${HIVE_DB_HOST:-}"
HIVE_DB_PORT="${HIVE_DB_PORT:-}"
HIVE_DB_NAME="${HIVE_DB_NAME:-}"
HIVE_DB_USER="${HIVE_DB_USER:-}"
HIVE_METASTORE_PORT="${HIVE_METASTORE_PORT:-}"
HIVE_WAREHOUSE_DIR="${HIVE_WAREHOUSE_DIR:-}"

ask HIVE_DB_HOST "PostgreSQL host/IP for the Hive metastore"
ask HIVE_DB_PORT "PostgreSQL port" "5432"
ask HIVE_DB_NAME "PostgreSQL database name" "hive"
ask HIVE_DB_USER "PostgreSQL user"
if [[ -z "${HIVE_DB_PASSWORD:-}" ]]; then
    read -rsp "PostgreSQL password for '$HIVE_DB_USER': " HIVE_DB_PASSWORD
    echo
fi
[[ -n "$HIVE_DB_PASSWORD" ]] || die "PostgreSQL password cannot be empty."
ask HIVE_METASTORE_PORT "Hive metastore (thrift) port" "9083"
[[ "$HIVE_METASTORE_PORT" =~ ^[0-9]+$ ]] || die "Metastore port must be numeric."
[[ "$HIVE_DB_PORT" =~ ^[0-9]+$ ]] || die "PostgreSQL port must be numeric."

# Paths
SOFTWARES="$BASE_DIR/softwares"
HADOOP_SRC="$SOFTWARES/hadoop"
HIVE_SRC="$SOFTWARES/hive"

HADOOP_BINARIES="$BASE_DIR/apps/hadoop/binaries"
HADOOP_DATA="$BASE_DIR/apps/hadoop/data"
HADOOP_LOGS_SL="$BASE_DIR/apps/hadoop/logs"
HADOOP_LOGS="$BASE_DIR/logs/hadoop"

HIVE_BINARIES="$BASE_DIR/apps/hive/binaries"
HIVE_DATA="$BASE_DIR/apps/hive/data"
HIVE_LOGS_SL="$BASE_DIR/apps/hive/logs"
HIVE_LOGS="$BASE_DIR/logs/hive"

ask HIVE_WAREHOUSE_DIR "Hive warehouse dir (e.g. s3a://bucket/warehouse or a local path)" "file://${HIVE_DATA}/warehouse"

echo
echo "Installation summary"
echo "  Hadoop ${HADOOP_VERSION}   : $HADOOP_BINARIES"
echo "  Hive   ${HIVE_VERSION}    : $HIVE_BINARIES"
echo "  Logs             : $HADOOP_LOGS , $HIVE_LOGS"
echo "  Service user     : $SVC_USER:$SVC_GROUP  (service: ${SERVICE_NAME}.service)"
echo "  Metastore DB     : jdbc:postgresql://${HIVE_DB_HOST}:${HIVE_DB_PORT}/${HIVE_DB_NAME} (user: ${HIVE_DB_USER})"
echo "  Metastore port   : $HIVE_METASTORE_PORT"
echo "  Warehouse dir    : $HIVE_WAREHOUSE_DIR"
echo
if [[ "${ASSUME_YES:-}" =~ ^[Yy]$ ]]; then
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

OUR_DIRS=("$HADOOP_SRC" "$HIVE_SRC" "$HADOOP_BINARIES" "$HADOOP_DATA" "$HADOOP_LOGS"
          "$HIVE_BINARIES" "$HIVE_DATA" "$HIVE_LOGS")
$SUDO mkdir -p "${OUR_DIRS[@]}" || die "Could not create directories under $BASE_DIR"
# Give the invoking user write access while installing; ownership is
# handed to the service user near the end.
$SUDO chown -R "$ME:$MY_GROUP" "$HADOOP_SRC" "$HIVE_SRC" \
    "$BASE_DIR/apps/hadoop" "$BASE_DIR/apps/hive" "$HADOOP_LOGS" "$HIVE_LOGS"
log "Directories ensured under $BASE_DIR"

link_logs() {   # link_logs <symlink> <target>
    if [[ -L "$1" || -e "$1" ]]; then
        log "$1 already exists, skipping symlink creation"
    else
        ln -sn "$2" "$1"
        log "Created symlink $1 -> $2"
    fi
}
link_logs "$HADOOP_LOGS_SL" "$HADOOP_LOGS"
link_logs "$HIVE_LOGS_SL" "$HIVE_LOGS"

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

case "$PKG_MGR" in
    yum|dnf)
        $SUDO "$PKG_MGR" install -y wget tar which >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || die "Dependency installation failed. See $ERROR_LOG"
        ;;
    apt)
        export DEBIAN_FRONTEND=noninteractive
        $SUDO apt-get update -y >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || warn "apt-get update failed, continuing"
        $SUDO apt-get install -y wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || die "Dependency installation failed. See $ERROR_LOG"
        ;;
esac
log "Base dependencies installed"

# ---------------------------------------------------------------
# 5. Java 8  (Hive 3.1.3 does not run on Java 11/17/21)
#    Never trust `command -v java` -- it may point at a newer JDK.
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
            $SUDO apt-get install -y openjdk-8-jdk-headless >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
            ;;
        yum|dnf)
            $SUDO "$PKG_MGR" install -y java-1.8.0-openjdk-headless >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
                || $SUDO "$PKG_MGR" install -y java-1.8.0-amazon-corretto >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
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
    tgz="$SOFTWARES/temurin8.tar.gz"
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

# ---------------------------------------------------------------
# 6. Helpers: download + checksum
# ---------------------------------------------------------------
verify_checksum() {   # verify_checksum <file> <checksum-url> <sha256|sha512>
    local file="$1" url="$2" algo="$3" tmp expected actual
    tmp=$(mktemp)
    if ! wget -q -O "$tmp" "$url" 2>> "$ERROR_LOG"; then
        rm -f "$tmp"
        warn "Could not fetch checksum from $url -- skipping verification of $(basename "$file")"
        return 0
    fi
    expected=$(grep -oiE '[a-f0-9]{64,128}' "$tmp" | head -n1 | tr 'A-F' 'a-f' || true)
    rm -f "$tmp"
    if [[ -z "$expected" ]]; then
        warn "No checksum found in $url -- skipping verification of $(basename "$file")"
        return 0
    fi
    actual=$("${algo}sum" "$file" | awk '{print $1}')
    [[ "$expected" == "$actual" ]] \
        || die "Checksum mismatch for $(basename "$file"). Delete it from $(dirname "$file") and re-run."
    log "Checksum OK for $(basename "$file")"
}

dir_is_empty() { [[ -z "$(ls -A "$1" 2>/dev/null)" ]]; }

# ---------------------------------------------------------------
# 7. Hadoop
# ---------------------------------------------------------------
HADOOP_MARKER="$HADOOP_BINARIES/share/hadoop/common/hadoop-common-${HADOOP_VERSION}.jar"

if [[ -f "$HADOOP_MARKER" ]]; then
    log "Hadoop $HADOOP_VERSION already installed at $HADOOP_BINARIES, skipping"
else
    dir_is_empty "$HADOOP_BINARIES" \
        || die "$HADOOP_BINARIES is not empty and does not contain Hadoop $HADOOP_VERSION. Move it aside and re-run."
    log "Downloading Hadoop $HADOOP_VERSION (large download, please wait)"
    wget -N -P "$HADOOP_SRC" "$HADOOP_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || die "Failed to download Hadoop from $HADOOP_URL"
    verify_checksum "$HADOOP_SRC/$HADOOP_TARBALL" "${HADOOP_URL}.sha512" sha512
    log "Extracting Hadoop into $HADOOP_BINARIES"
    tar -xzf "$HADOOP_SRC/$HADOOP_TARBALL" -C "$HADOOP_BINARIES" --strip-components=1 \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "Hadoop extraction failed. See $ERROR_LOG"
    [[ -f "$HADOOP_MARKER" ]] || die "Hadoop extraction finished but $HADOOP_MARKER is missing."
    log "Hadoop $HADOOP_VERSION installed to $HADOOP_BINARIES"
fi

# ---------------------------------------------------------------
# 8. Hive
# ---------------------------------------------------------------
HIVE_MARKER="$HIVE_BINARIES/lib/hive-metastore-${HIVE_VERSION}.jar"

if [[ -f "$HIVE_MARKER" ]]; then
    log "Hive $HIVE_VERSION already installed at $HIVE_BINARIES, skipping extraction"
else
    dir_is_empty "$HIVE_BINARIES" \
        || die "$HIVE_BINARIES is not empty and does not contain Hive $HIVE_VERSION. Move it aside and re-run."
    log "Downloading Hive $HIVE_VERSION"
    wget -N -P "$HIVE_SRC" "$HIVE_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || die "Failed to download Hive from $HIVE_URL"
    verify_checksum "$HIVE_SRC/$HIVE_TARBALL" "${HIVE_URL}.sha256" sha256
    log "Extracting Hive into $HIVE_BINARIES"
    tar -xzf "$HIVE_SRC/$HIVE_TARBALL" -C "$HIVE_BINARIES" --strip-components=1 \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "Hive extraction failed. See $ERROR_LOG"
    [[ -f "$HIVE_MARKER" ]] || die "Hive extraction finished but $HIVE_MARKER is missing."
    log "Hive $HIVE_VERSION installed to $HIVE_BINARIES"
fi

HIVE_LIB="$HIVE_BINARIES/lib"

# ---------------------------------------------------------------
# 8a. Jars: PostgreSQL JDBC, AWS S3 (from Hadoop tools/lib), Guava fix
# ---------------------------------------------------------------
# PostgreSQL JDBC: Hive 3.1.3 bundles a 2016 driver that cannot do
# SCRAM-SHA-256 (default on modern PostgreSQL). Replace it.
for old in "$HIVE_LIB"/postgresql-*.jar; do
    [[ -e "$old" ]] || continue
    if [[ "$(basename "$old")" != "$PG_JDBC_JAR" ]]; then
        log "Removing old JDBC driver $(basename "$old")"
        rm -f "$old"
    fi
done
if [[ ! -f "$HIVE_LIB/$PG_JDBC_JAR" ]]; then
    log "Downloading PostgreSQL JDBC driver $PG_JDBC_VERSION"
    wget -N -P "$HIVE_LIB" "$PG_JDBC_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || die "Failed to download $PG_JDBC_URL"
fi

# AWS S3 support: Hadoop 3.4.x uses AWS SDK v2 (bundle-2.x.jar), NOT the
# aws-java-sdk-* v1 jars that hadoop-aws 3.3.6 needed. Copy the exact
# matching pair shipped inside the Hadoop tarball.
S3_JARS=()
for pat in 'hadoop-aws-*.jar' 'bundle-*.jar'; do
    src=$(find "$HADOOP_BINARIES/share/hadoop/tools/lib" -maxdepth 1 -name "$pat" 2>/dev/null | head -n1 || true)
    if [[ -n "$src" ]]; then
        cp -f "$src" "$HIVE_LIB/"
        S3_JARS+=("$HIVE_LIB/$(basename "$src")")
        log "Copied $(basename "$src") into Hive lib"
    else
        warn "Could not find $pat in Hadoop tools/lib -- S3A access from Hive may not work"
    fi
done

# Guava: Hive 3.1.3 ships guava-19, which breaks against Hadoop 3.4.x
# (NoSuchMethodError: Preconditions.checkArgument). Use Hadoop's Guava.
HADOOP_GUAVA=$(find "$HADOOP_BINARIES/share/hadoop/common/lib" -maxdepth 1 -name 'guava-*.jar' 2>/dev/null | head -n1 || true)
HADOOP_FAILUREACCESS=$(find "$HADOOP_BINARIES/share/hadoop/common/lib" -maxdepth 1 -name 'failureaccess-*.jar' 2>/dev/null | head -n1 || true)
if [[ -n "$HADOOP_GUAVA" ]]; then
    rm -f "$HIVE_LIB"/guava-*.jar
    cp -f "$HADOOP_GUAVA" "$HIVE_LIB/"
    [[ -n "$HADOOP_FAILUREACCESS" ]] && cp -f "$HADOOP_FAILUREACCESS" "$HIVE_LIB/"
    log "Replaced Hive's Guava with $(basename "$HADOOP_GUAVA") from Hadoop"
else
    warn "No Guava jar found in Hadoop -- removing Hive's guava so Hadoop's classpath version is used"
    rm -f "$HIVE_LIB"/guava-*.jar
fi

# ---------------------------------------------------------------
# 9. Configuration
# ---------------------------------------------------------------
upsert_block() {   # upsert_block <file> <tag> <content>
    local file="$1" tag="$2" content="$3"
    sed -i "/^# >>> ${tag} >>>\$/,/^# <<< ${tag} <<<\$/d" "$file"
    {
        echo "# >>> ${tag} >>>"
        echo "$content"
        echo "# <<< ${tag} <<<"
    } >> "$file"
}

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

TAG="install_hadoop_hive.sh"
HADOOP_CONF="$HADOOP_BINARIES/etc/hadoop"
HIVE_CONF="$HIVE_BINARIES/conf"

# --- hadoop-env.sh ---
[[ -f "$HADOOP_CONF/hadoop-env.sh" ]] || die "hadoop-env.sh not found at $HADOOP_CONF"
upsert_block "$HADOOP_CONF/hadoop-env.sh" "$TAG" "export JAVA_HOME=${JAVA_HOME_DIR}
export HADOOP_LOG_DIR=${HADOOP_LOGS}
export HADOOP_OPTIONAL_TOOLS=\"hadoop-aws\""
log "hadoop-env.sh updated"

# --- hive-env.sh ---
[[ -f "$HIVE_CONF/hive-env.sh" ]] || cp "$HIVE_CONF/hive-env.sh.template" "$HIVE_CONF/hive-env.sh"
AUX_JARS=$(IFS=:; echo "${S3_JARS[*]:-}")
upsert_block "$HIVE_CONF/hive-env.sh" "$TAG" "export JAVA_HOME=${JAVA_HOME_DIR}
export HADOOP_HOME=${HADOOP_BINARIES}
export HIVE_CONF_DIR=${HIVE_CONF}
export HIVE_AUX_JARS_PATH=${AUX_JARS}"
log "hive-env.sh updated"

# --- hive-log4j2.properties (write hive.log to the logs dir) ---
[[ -f "$HIVE_CONF/hive-log4j2.properties" ]] || cp "$HIVE_CONF/hive-log4j2.properties.template" "$HIVE_CONF/hive-log4j2.properties"
sed -i "s|^property.hive.log.dir *=.*|property.hive.log.dir = ${HIVE_LOGS}|" "$HIVE_CONF/hive-log4j2.properties"
log "hive-log4j2.properties updated (logs -> $HIVE_LOGS)"

# --- hive-site.xml ---
# Written from scratch instead of editing hive-default.xml.template by
# line number: the template contains an invalid character (&#8;) at the
# 'hive.txn.xlock.iow' description that breaks XML parsing.
if [[ -f "$HIVE_CONF/hive-site.xml" && ! -f "$HIVE_CONF/hive-site.xml.orig" ]]; then
    cp "$HIVE_CONF/hive-site.xml" "$HIVE_CONF/hive-site.xml.orig"
    log "Existing hive-site.xml backed up to hive-site.xml.orig"
fi
JDBC_URL=$(xml_escape "jdbc:postgresql://${HIVE_DB_HOST}:${HIVE_DB_PORT}/${HIVE_DB_NAME}")
X_USER=$(xml_escape "$HIVE_DB_USER")
X_PASS=$(xml_escape "$HIVE_DB_PASSWORD")
X_WH=$(xml_escape "$HIVE_WAREHOUSE_DIR")
cat > "$HIVE_CONF/hive-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>${JDBC_URL}</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>org.postgresql.Driver</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionUserName</name>
    <value>${X_USER}</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionPassword</name>
    <value>${X_PASS}</value>
  </property>
  <property>
    <name>hive.metastore.uris</name>
    <value>thrift://localhost:${HIVE_METASTORE_PORT}</value>
  </property>
  <property>
    <name>hive.metastore.warehouse.dir</name>
    <value>${X_WH}</value>
  </property>
  <property>
    <name>hive.metastore.schema.verification</name>
    <value>true</value>
  </property>
  <property>
    <name>hive.metastore.event.db.notification.api.auth</name>
    <value>false</value>
  </property>
</configuration>
EOF
chmod 600 "$HIVE_CONF/hive-site.xml"
log "hive-site.xml written (mode 600)"

# Local warehouse directory, if a local path was chosen
WH_LOCAL=""
case "$HIVE_WAREHOUSE_DIR" in
    file://*) WH_LOCAL="${HIVE_WAREHOUSE_DIR#file://}" ;;
    /*)       WH_LOCAL="$HIVE_WAREHOUSE_DIR" ;;
esac
if [[ -n "$WH_LOCAL" ]]; then
    $SUDO mkdir -p "$WH_LOCAL"
    log "Ensured local warehouse dir $WH_LOCAL"
fi

# --- Shell environment (no global JAVA_HOME on purpose) ---
PROFILE_FILE="/etc/profile.d/hadoop-hive.sh"
$SUDO tee "$PROFILE_FILE" > /dev/null <<EOF
export HADOOP_HOME=${HADOOP_BINARIES}
export HIVE_HOME=${HIVE_BINARIES}
export PATH=\$PATH:\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\${HIVE_HOME}/bin
EOF
log "Wrote $PROFILE_FILE (HADOOP_HOME, HIVE_HOME, PATH)"

# ---------------------------------------------------------------
# 10. Ownership (+ SELinux on RHEL-family)
# ---------------------------------------------------------------
$SUDO chown -R "$SVC_USER:$SVC_GROUP" "$BASE_DIR/apps/hadoop" "$BASE_DIR/apps/hive" "$HADOOP_LOGS" "$HIVE_LOGS"
[[ -n "$WH_LOCAL" ]] && $SUDO chown -R "$SVC_USER:$SVC_GROUP" "$WH_LOCAL"
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
        SE_DIRS=("$HADOOP_BINARIES/bin" "$HADOOP_BINARIES/sbin" "$HADOOP_BINARIES/libexec" "$HIVE_BINARIES/bin")
        [[ "$JAVA_HOME_DIR" == "$BASE_DIR"/* ]] && SE_DIRS+=("$JAVA_HOME_DIR/bin")
        for d in "${SE_DIRS[@]}"; do
            set_fcontext bin_t "${d}(/.*)?" || warn "semanage failed for $d"
            $SUDO restorecon -R "$d" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || warn "restorecon failed for $d"
        done
        log "SELinux bin_t labels applied"
    fi
fi

# ---------------------------------------------------------------
# 11. Initialise the metastore schema (as the service user)
# ---------------------------------------------------------------
run_as_svc() {
    if [[ "$ME" == "$SVC_USER" ]]; then
        "$@"
    elif [[ $EUID -eq 0 ]]; then
        runuser -u "$SVC_USER" -- "$@"
    else
        $SUDO -u "$SVC_USER" "$@"
    fi
}

SVC_ENV=(env
    "JAVA_HOME=${JAVA_HOME_DIR}"
    "HADOOP_HOME=${HADOOP_BINARIES}"
    "HADOOP_CONF_DIR=${HADOOP_CONF}"
    "HIVE_HOME=${HIVE_BINARIES}"
    "HIVE_CONF_DIR=${HIVE_CONF}"
    "PATH=${JAVA_HOME_DIR}/bin:${HADOOP_BINARIES}/bin:${HIVE_BINARIES}/bin:${PATH}")

log "Checking metastore schema state (schematool -info)"
if (cd "$HIVE_DATA" && run_as_svc "${SVC_ENV[@]}" "$HIVE_BINARIES/bin/schematool" -dbType postgres -info) \
        >> "$SCHEMATOOL_LOG" 2>&1; then
    log "Metastore schema already initialised in ${HIVE_DB_NAME}, skipping initSchema"
else
    log "Initialising metastore schema (schematool -initSchema)"
    if ! (cd "$HIVE_DATA" && run_as_svc "${SVC_ENV[@]}" "$HIVE_BINARIES/bin/schematool" -dbType postgres -initSchema) \
            >> "$SCHEMATOOL_LOG" 2>&1; then
        {
            echo "---- tail of $SCHEMATOOL_LOG ----"
            tail -n 40 "$SCHEMATOOL_LOG"
        } | tee -a "$ERROR_LOG" >&2
        die "schematool -initSchema failed. Check that database '${HIVE_DB_NAME}' exists on ${HIVE_DB_HOST}:${HIVE_DB_PORT}, that '${HIVE_DB_USER}' can create tables in it, and that pg_hba.conf allows this host. Full output: $SCHEMATOOL_LOG"
    fi
    log "Metastore schema initialised"
fi

# ---------------------------------------------------------------
# 12. systemd service
# ---------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
log "Creating systemd service ${SERVICE_NAME}.service"
$SUDO tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Apache Hive Metastore
After=network.target multi-user.target

[Service]
User=${SVC_USER}
Group=${SVC_GROUP}
Type=simple
Environment=JAVA_HOME=${JAVA_HOME_DIR}
Environment=HADOOP_HOME=${HADOOP_BINARIES}
Environment=HADOOP_CONF_DIR=${HADOOP_CONF}
Environment=HIVE_HOME=${HIVE_BINARIES}
Environment=HIVE_CONF_DIR=${HIVE_CONF}
Environment=PATH=${JAVA_HOME_DIR}/bin:${HADOOP_BINARIES}/bin:${HADOOP_BINARIES}/sbin:${HIVE_BINARIES}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${HIVE_BINARIES}/bin/hive --service metastore -p ${HIVE_METASTORE_PORT}
WorkingDirectory=${HIVE_DATA}
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
log "systemd service file written to $SERVICE_FILE"

$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}.service" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
log "${SERVICE_NAME}.service enabled for boot"

if ! $SUDO systemctl restart "${SERVICE_NAME}.service"; then
    {
        echo "---- systemctl status ${SERVICE_NAME}.service ----"
        $SUDO systemctl status "${SERVICE_NAME}.service" --no-pager -l 2>&1
        echo "---- journalctl -xeu ${SERVICE_NAME}.service ----"
        $SUDO journalctl -xeu "${SERVICE_NAME}.service" --no-pager -n 50 -o cat 2>&1
        echo "---- tail of ${HIVE_LOGS}/hive.log ----"
        tail -n 50 "${HIVE_LOGS}/hive.log" 2>&1 || true
    } | tee -a "$ERROR_LOG"
    die "Failed to start ${SERVICE_NAME}.service. Diagnostics captured above and in $ERROR_LOG."
fi
log "${SERVICE_NAME}.service started"

# ---------------------------------------------------------------
# 13. Verify (metastore needs a little while to open its port)
# ---------------------------------------------------------------
log "Waiting for the metastore to listen on port ${HIVE_METASTORE_PORT} (up to 90s)"
UP="no"
for _ in $(seq 1 45); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${HIVE_METASTORE_PORT}") 2>/dev/null; then
        UP="yes"
        break
    fi
    sleep 2
done

if [[ "$UP" == "yes" ]] && $SUDO systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    log "SUCCESS: Hive Metastore is up and listening on ${HIVE_METASTORE_PORT}."
    echo
    echo "=================================================================="
    echo " Hadoop ${HADOOP_VERSION} + Hive ${HIVE_VERSION} installed; metastore is running."
    echo " Hadoop     : $HADOOP_BINARIES"
    echo " Hive       : $HIVE_BINARIES"
    echo " Config     : $HIVE_CONF/hive-site.xml"
    echo " Logs       : $HIVE_LOGS  (symlink $HIVE_LOGS_SL)"
    echo " Metastore  : thrift://$(hostname -f 2>/dev/null || hostname):${HIVE_METASTORE_PORT}"
    echo " Service    : systemctl status ${SERVICE_NAME}"
    echo " New shells : source $PROFILE_FILE   (adds hadoop/hive to PATH)"
    echo "=================================================================="
else
    {
        $SUDO systemctl status "${SERVICE_NAME}.service" --no-pager -l 2>&1 || true
        tail -n 50 "${HIVE_LOGS}/hive.log" 2>&1 || true
    } | tee -a "$ERROR_LOG"
    die "Metastore did not come up on port ${HIVE_METASTORE_PORT}. See $ERROR_LOG and ${HIVE_LOGS}/hive.log."
fi

