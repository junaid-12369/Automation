#!/bin/bash
#================================================================
# DESCRIPTION
#   Single-shot Redis installer/configurator/service-enabler.
#   Consolidates env.sh + install.sh + manual redis.conf edits +
#   systemd unit creation into one idempotent script.
#
# Usage
#   sudo ./redis_install.sh
#
# IMPLEMENTATION
#   Author  - EverestDx (consolidated)
#   Version - v2
#================================================================

set -euo pipefail

#------------------------------------------------------------
# CONFIGURABLE VARIABLES (from env.sh)
#------------------------------------------------------------
REDIS_VERSION="6.2.20"
SOURCE=/opt/ausiytic/softwares/redis
REDIS_BINARIES=/opt/ausiytic/db/redis/binaries
REDIS_DATA=/opt/ausiytic/db/redis/data
REDIS_LOGS_SL=/opt/ausiytic/db/redis/logs
REDIS_LOGS_DIR=/opt/ausiytic/logs/redis
REDIS_CONF="$REDIS_DATA/redis.conf"
REDIS_PORT=6379
REDIS_PIDFILE="$REDIS_LOGS_DIR/redis_${REDIS_PORT}.pid"

# Service run-as account. The original doc used a personal account
# (ganesh.devarapalli) — change back if that's intentional, but a
# dedicated service account is safer for repeatable deploys.
REDIS_SERVICE_USER="redis"
REDIS_SERVICE_GROUP="redis"

# !! Rotate this before use — it appeared in a shared/plaintext doc !!
REDIS_PASSWORD="ifHgEBehMLlZRpgP2zSozSOtaC"

SCRIPT_PWD="$(pwd)"
LOGTIME="$(date +"%F %T")"
FILENAME="$(date +"%d%m%Y%H")"
ACCESS_LOG="$SCRIPT_PWD/redisinstall.access.$FILENAME.log"
ERROR_LOG="$SCRIPT_PWD/redisinstall.error.$FILENAME.log"

log() {
    echo -e "[$(date +"%F %T")] $1" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    echo "$1"
}

#------------------------------------------------------------
# PRE-CHECKS
#------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run as root (sudo ./redis_install.sh)." >&2
    exit 1
fi

log "Starting Redis install (version $REDIS_VERSION)"

log "Checking/installing prerequisites (gcc, make, wget, tar)"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    apt-get install -y gcc make wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
elif command -v yum >/dev/null 2>&1; then
    yum install -y gcc make wget tar >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
else
    log "WARNING: No apt-get or yum found. Ensure gcc/make/wget/tar are installed manually."
fi

#------------------------------------------------------------
# CREATE SERVICE USER/GROUP
#------------------------------------------------------------
if ! getent group "$REDIS_SERVICE_GROUP" >/dev/null 2>&1; then
    log "Creating group $REDIS_SERVICE_GROUP"
    groupadd --system "$REDIS_SERVICE_GROUP"
fi

if ! id "$REDIS_SERVICE_USER" >/dev/null 2>&1; then
    log "Creating user $REDIS_SERVICE_USER"
    useradd --system --gid "$REDIS_SERVICE_GROUP" --shell /usr/sbin/nologin \
        --home-dir "$REDIS_DATA" --no-create-home "$REDIS_SERVICE_USER"
fi

#------------------------------------------------------------
# CREATE REQUIRED FOLDERS
#------------------------------------------------------------
log "Checking required folders"
for dir in "$SOURCE" "$REDIS_BINARIES" "$REDIS_DATA" "$REDIS_LOGS_DIR"; do
    if [ -d "$dir" ]; then
        log "$dir already exists"
    else
        mkdir -p "$dir"
        log "Created $dir"
    fi
done

log "Creating symlink for log folders"
ln -sfn "$REDIS_LOGS_DIR" "$REDIS_LOGS_SL"

#------------------------------------------------------------
# DOWNLOAD, BUILD, INSTALL
#------------------------------------------------------------
cd "$SOURCE"

if [ ! -f "redis-${REDIS_VERSION}.tar.gz" ]; then
    log "Downloading redis-${REDIS_VERSION}.tar.gz"
    wget -q "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz"
else
    log "redis-${REDIS_VERSION}.tar.gz already downloaded"
fi

log "Extracting Redis source"
tar -xzf "redis-${REDIS_VERSION}.tar.gz"
cd "redis-${REDIS_VERSION}"

log "Building Redis (make)"
if ! PREFIX="$REDIS_BINARIES" make >> "$ACCESS_LOG" 2>> "$ERROR_LOG"; then
    log "make failed, retrying after make distclean"
    make distclean >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    PREFIX="$REDIS_BINARIES" make >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
fi

log "Installing Redis binaries to $REDIS_BINARIES"
PREFIX="$REDIS_BINARIES" make install >> "$ACCESS_LOG" 2>> "$ERROR_LOG"

#------------------------------------------------------------
# CONFIGURE redis.conf
#------------------------------------------------------------
log "Configuring redis.conf"

if [ ! -f "$REDIS_CONF" ]; then
    cp redis.conf "$REDIS_CONF"
fi

# bind: comment out so Redis listens on all interfaces (matches "comment the line bind ip")
sed -i 's/^bind /# bind /' "$REDIS_CONF"

# supervised systemd
if grep -q "^supervised " "$REDIS_CONF"; then
    sed -i 's/^supervised .*/supervised systemd/' "$REDIS_CONF"
else
    echo "supervised systemd" >> "$REDIS_CONF"
fi

# dir
if grep -q "^dir " "$REDIS_CONF"; then
    sed -i "s|^dir .*|dir $REDIS_DATA|" "$REDIS_CONF"
else
    echo "dir $REDIS_DATA" >> "$REDIS_CONF"
fi

# pidfile
if grep -q "^pidfile " "$REDIS_CONF"; then
    sed -i "s|^pidfile .*|pidfile $REDIS_PIDFILE|" "$REDIS_CONF"
else
    echo "pidfile $REDIS_PIDFILE" >> "$REDIS_CONF"
fi

# databases
if grep -q "^databases " "$REDIS_CONF"; then
    sed -i 's/^databases .*/databases 32/' "$REDIS_CONF"
else
    echo "databases 32" >> "$REDIS_CONF"
fi

# requirepass: keep disabled per the documented fix, use ACL instead below.
sed -i 's/^requirepass /# requirepass /' "$REDIS_CONF"

# ACL: give default user the password via ACL (persists in config, unlike a CLI-only ACL SETUSER)
if grep -q "^user default " "$REDIS_CONF"; then
    sed -i "s|^user default .*|user default on >${REDIS_PASSWORD} ~* +@all|" "$REDIS_CONF"
else
    echo "user default on >${REDIS_PASSWORD} ~* +@all" >> "$REDIS_CONF"
fi

chown -R "$REDIS_SERVICE_USER":"$REDIS_SERVICE_GROUP" "$REDIS_DATA" "$REDIS_LOGS_DIR" "$REDIS_BINARIES"

#------------------------------------------------------------
# SYSTEMD SERVICE
#------------------------------------------------------------
log "Creating systemd service file"

cat > /etc/systemd/system/redis.service <<EOF
[Unit]
Description=Redis In-Memory Data Store
After=network.target multi-user.target

[Service]
User=${REDIS_SERVICE_USER}
Group=${REDIS_SERVICE_GROUP}
ExecStart=${REDIS_BINARIES}/bin/redis-server ${REDIS_CONF}
ExecStop=${REDIS_BINARIES}/bin/redis-cli -a ${REDIS_PASSWORD} shutdown
Restart=always

[Install]
WantedBy=multi-user.target
EOF

log "Reloading systemd and enabling redis service"
systemctl daemon-reload
systemctl enable redis
systemctl restart redis

sleep 2

log "Checking service status"
if systemctl is-active --quiet redis; then
    log "Redis service is running"
else
    log "ERROR: Redis service failed to start. Check: systemctl status redis / journalctl -u redis"
    exit 1
fi

echo ""
echo "=================================================================="
echo " Redis ${REDIS_VERSION} installed and running."
echo " Config:   $REDIS_CONF"
echo " Binaries: $REDIS_BINARIES"
echo " Test with: ${REDIS_BINARIES}/bin/redis-cli -a '${REDIS_PASSWORD}' ping"
echo " Logs (this run): $ACCESS_LOG / $ERROR_LOG"
echo "=================================================================="

