#!/bin/bash
#================================================================
# airflow_cluster_scheduler.sh
#
# Installs the CONTROL-NODE role of an Airflow CeleryExecutor
# cluster: api-server (webserver/API) + scheduler + dag-processor +
# triggerer, all talking to an EXTERNAL Postgres metadata DB and an
# EXTERNAL Redis broker. Run this on exactly ONE node (or an
# active/passive pair if you HA the scheduler yourself).
#
# Companion script: airflow_cluster_worker.sh — run on every worker
# node, pointed at the SAME DB/broker/FERNET_KEY/DAGS_FOLDER.
#
# Prerequisites this script does NOT set up for you:
#   - A running, reachable Postgres instance + empty database + user
#     with privileges on it.
#   - A running, reachable Redis instance for the Celery broker.
#   - A DAGs folder that is identical and shared across every node
#     (NFS/EFS/git-sync/etc.) — point DAGS_FOLDER at that mount.
#
# One-time step BEFORE running this on any node — generate the
# shared secrets that every node (scheduler + all workers) must use
# identically:
#   python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
#   python3 -c "import secrets; print(secrets.token_hex(16))"   # webserver secret key
#
# Non-interactive (AUTOMATED) usage:
#   AUTOMATED=1 BASE_DIR=/opt/ausiytic SERVICE_USER=airflow \
#   PYTHON_VERSION=3.10.10 AIRFLOW_VERSION=3.1.2 AIRFLOW_EXTRAS=hive \
#   DB_HOST=pg.internal DB_PORT=5432 DB_NAME=airflow DB_USER=airflow DB_PASSWORD='...' \
#   REDIS_HOST=redis.internal REDIS_PORT=6379 REDIS_DB=0 REDIS_PASSWORD='' \
#   FERNET_KEY='...' WEBSERVER_SECRET_KEY='...' JWT_ISSUER=airflow-api \
#   API_PORT=8080 DAGS_FOLDER=/mnt/shared/airflow-dags \
#   ADMIN_USERNAME=admin ADMIN_PASSWORD='ChangeMe123!' \
#   INSTALL_FLOWER=0 FLOWER_PORT=5555 \
#   sudo -E ./airflow_cluster_scheduler.sh
#================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/airflow_cluster_scheduler.$(date +%Y%m%d%H%M%S).log"
touch "$LOG_FILE"

# shellcheck source=./airflow_cluster_common.sh
source "$SCRIPT_DIR/airflow_cluster_common.sh"

AUTOMATED="${AUTOMATED:-0}"
require_root
print_banner "Apache Airflow Cluster - Control Node (apiserver/scheduler/dag-processor/triggerer)"
[ "$AUTOMATED" = "1" ] && log "Running in AUTOMATED (non-interactive) mode."

# ------------------------------------------------------------------
# 1. Input
# ------------------------------------------------------------------
BASE_DIR=$(prompt_base_dir "Base volume/mount path to install under" "/opt/ausiytic" "${BASE_DIR:-}")
SERVICE_USER=$(prompt_nonempty "OS user to run Airflow as" "airflow" "${SERVICE_USER:-}")
PYTHON_VERSION=$(prompt_nonempty "Python version to build from source" "3.10.10" "${PYTHON_VERSION:-}")
AIRFLOW_VERSION=$(prompt_nonempty "Apache Airflow version to install" "3.1.2" "${AIRFLOW_VERSION:-}")
AIRFLOW_EXTRAS=$(prompt_nonempty "EXTRA Airflow extras beyond celery,postgres,redis (comma-separated, empty for none)" "" "${AIRFLOW_EXTRAS:-}")
API_PORT=$(prompt_port "Airflow API server (webserver) port" "8080" "${API_PORT:-}")
JWT_ISSUER=$(prompt_nonempty "JWT issuer identifier for the API auth token" "airflow-api" "${JWT_ISSUER:-}")

DAGS_FOLDER=$(prompt_nonempty "Shared DAGs folder path (must be identical/mounted on every node)" "/opt/ausiytic/shared/dags" "${DAGS_FOLDER:-}")

echo "--- Metadata DB (external Postgres) ---"
DB_HOST=$(prompt_nonempty "Postgres host" "" "${DB_HOST:-}")
DB_PORT=$(prompt_port "Postgres port" "5432" "${DB_PORT:-}")
DB_NAME=$(prompt_nonempty "Postgres database name" "airflow" "${DB_NAME:-}")
DB_USER=$(prompt_nonempty "Postgres user" "airflow" "${DB_USER:-}")
DB_PASSWORD=$(prompt_secret "Postgres password" "${DB_PASSWORD:-}" "${DB_PASSWORD:-}" 1)

echo "--- Celery broker (external Redis) ---"
REDIS_HOST=$(prompt_nonempty "Redis host" "" "${REDIS_HOST:-}")
REDIS_PORT=$(prompt_port "Redis port" "6379" "${REDIS_PORT:-}")
REDIS_DB=$(prompt_nonempty "Redis DB index for the broker" "0" "${REDIS_DB:-}")
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
if [ "$AUTOMATED" != "1" ]; then
    read -rsp "Redis password (blank if none): " REDIS_PASSWORD; echo
fi

echo "--- Shared cluster secrets (MUST match every node exactly) ---"
FERNET_KEY="${FERNET_KEY:-}"
if [ "$AUTOMATED" != "1" ] && [ -z "$FERNET_KEY" ]; then
    read -rsp "FERNET_KEY (leave blank to generate a NEW one now — you'll need to copy it to every worker): " FERNET_KEY; echo
fi
if [ -z "$FERNET_KEY" ]; then
    [ "$AUTOMATED" = "1" ] && die "AUTOMATED mode: FERNET_KEY must be provided explicitly (same value on every node). Refusing to auto-generate in unattended mode."
    FERNET_KEY="$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || true)"
    [ -n "$FERNET_KEY" ] || die "Could not generate a Fernet key (python3+cryptography not available). Install python3-cryptography or pass FERNET_KEY explicitly."
    warn "Generated a NEW FERNET_KEY. COPY THIS TO EVERY WORKER NODE — it will not be shown again: ${FERNET_KEY}"
fi
require_matching_secret "FERNET_KEY" "$FERNET_KEY" "used to decrypt connections/variables — must match on every scheduler/worker/webserver node"

WEBSERVER_SECRET_KEY="${WEBSERVER_SECRET_KEY:-}"
if [ -z "$WEBSERVER_SECRET_KEY" ]; then
    [ "$AUTOMATED" = "1" ] && die "AUTOMATED mode: WEBSERVER_SECRET_KEY must be provided explicitly."
    WEBSERVER_SECRET_KEY="$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null || true)"
    [ -n "$WEBSERVER_SECRET_KEY" ] || die "Could not generate a webserver secret key. Pass WEBSERVER_SECRET_KEY explicitly."
    warn "Generated a NEW WEBSERVER_SECRET_KEY: ${WEBSERVER_SECRET_KEY}"
fi

ADMIN_USERNAME=$(prompt_nonempty "Admin username for Airflow UI" "admin" "${ADMIN_USERNAME:-}")
ADMIN_PASSWORD=$(prompt_secret "Admin password for Airflow UI (min 8 chars)" "${ADMIN_PASSWORD:-}" "${ADMIN_PASSWORD:-}" 8)

INSTALL_FLOWER=$(prompt_yesno "Install Flower (Celery monitoring UI) on this node" "0" "${INSTALL_FLOWER:-}")
FLOWER_PORT=$(prompt_port "Flower port" "5555" "${FLOWER_PORT:-}")

# ------------------------------------------------------------------
# 2. Derived paths & connection strings
# ------------------------------------------------------------------
SOURCE_DIR="${BASE_DIR}/softwares"
PYTHON_BINARIES="${BASE_DIR}/apps/python"
PYTHON_BIN_DIR="${PYTHON_BINARIES}/bin"
PYTHON_SHORT_VER="${PYTHON_VERSION%.*}"
PYTHON_EXE="${PYTHON_BIN_DIR}/python${PYTHON_SHORT_VER}"
AIRFLOW_HOME="${BASE_DIR}/apps/airflow"
AIRFLOW_EXE="${PYTHON_BIN_DIR}/airflow"
SUMMARY_FILE="${BASE_DIR}/airflow_cluster_scheduler_summary.txt"

SQL_ALCHEMY_CONN="$(build_sql_conn "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$DB_PORT" "$DB_NAME")"
BROKER_URL="$(build_broker_url "$REDIS_HOST" "$REDIS_PORT" "$REDIS_DB" "$REDIS_PASSWORD")"
RESULT_BACKEND="$(build_result_backend "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$DB_PORT" "$DB_NAME")"

COMMON_ENV="AIRFLOW__CORE__EXECUTOR=CeleryExecutor
AIRFLOW__CORE__DAGS_FOLDER=${DAGS_FOLDER}
AIRFLOW__CORE__FERNET_KEY=${FERNET_KEY}
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=${SQL_ALCHEMY_CONN}
AIRFLOW__CELERY__BROKER_URL=${BROKER_URL}
AIRFLOW__CELERY__RESULT_BACKEND=${RESULT_BACKEND}
AIRFLOW__WEBSERVER__SECRET_KEY=${WEBSERVER_SECRET_KEY}
AIRFLOW__API_AUTH__JWT_ISSUER=${JWT_ISSUER}"

# ------------------------------------------------------------------
# 3. Pre-flight connectivity
# ------------------------------------------------------------------
detect_os
install_deps
check_tcp_reachable "$DB_HOST" "$DB_PORT" "Postgres metadata DB"
check_tcp_reachable "$REDIS_HOST" "$REDIS_PORT" "Redis broker"

# ------------------------------------------------------------------
# 4. Directories, shared DAGs mount, service user
# ------------------------------------------------------------------
log "Creating directory structure under $BASE_DIR ..."
mkdir -p "$SOURCE_DIR" "$PYTHON_BINARIES" "$AIRFLOW_HOME"
if [ ! -d "$DAGS_FOLDER" ]; then
    warn "DAGS_FOLDER '${DAGS_FOLDER}' does not exist yet on this node — creating it locally."
    warn "If this is meant to be shared storage (NFS/EFS/etc.), mount it at this exact path BEFORE workers start, or DAGs written here won't be visible to workers."
    mkdir -p "$DAGS_FOLDER"
fi
ensure_service_user "$SERVICE_USER" "$BASE_DIR"
[ "$SERVICE_USER" != "root" ] && chown -R "$SERVICE_USER":"$SERVICE_USER" "$BASE_DIR" "$DAGS_FOLDER" 2>/dev/null
ok "DAGs folder ready at ${DAGS_FOLDER}."

# ------------------------------------------------------------------
# 5. Python + Airflow
# ------------------------------------------------------------------
build_and_install_python "$PYTHON_VERSION" "$SOURCE_DIR" "$PYTHON_BINARIES"
symlink_python "$PYTHON_BINARIES" "$PYTHON_VERSION"

if [ -x "$AIRFLOW_EXE" ]; then
    warn "Airflow already present at $AIRFLOW_EXE — skipping pip install."
else
    install_airflow "$PYTHON_EXE" "$AIRFLOW_VERSION" "$AIRFLOW_EXTRAS"
fi

setup_env_profile "$AIRFLOW_HOME" "$PYTHON_BIN_DIR"
[ "$SERVICE_USER" != "root" ] && chown -R "$SERVICE_USER":"$SERVICE_USER" "$PYTHON_BINARIES" "$AIRFLOW_HOME"

# ------------------------------------------------------------------
# 6. DB migrate + admin user (run ONCE, from this control node only)
# ------------------------------------------------------------------
GENERATED_PW_FILE="${AIRFLOW_HOME}/simple_auth_manager_passwords.json.generated"
if [ -f "$GENERATED_PW_FILE" ]; then
    warn "Simple auth manager password file already exists — the admin password below will NOT be applied (DB already initialized)."
fi

log "Running 'airflow db migrate' against external Postgres (admin user: ${ADMIN_USERNAME}) ..."
AIRFLOW_HOME="$AIRFLOW_HOME" \
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="$SQL_ALCHEMY_CONN" \
AIRFLOW__CORE__FERNET_KEY="$FERNET_KEY" \
_AIRFLOW_WWW_USER_USERNAME="$ADMIN_USERNAME" \
_AIRFLOW_WWW_USER_PASSWORD="$ADMIN_PASSWORD" \
"$AIRFLOW_EXE" db migrate >> "$LOG_FILE" 2>&1 \
    || die "airflow db migrate failed. See $LOG_FILE"
ok "Airflow metadata database migrated and admin user '${ADMIN_USERNAME}' registered (if this was the first migrate)."

[ "$SERVICE_USER" != "root" ] && chown -R "$SERVICE_USER":"$SERVICE_USER" "$AIRFLOW_HOME"

# ------------------------------------------------------------------
# 7. systemd services + start
# ------------------------------------------------------------------
create_service_unit "airflow-apiserver" "Airflow API Server" "$SERVICE_USER" "$AIRFLOW_HOME" "$PYTHON_BIN_DIR" \
    "${AIRFLOW_EXE} api-server --port ${API_PORT}" "$COMMON_ENV"

create_service_unit "airflow-dagprocessor" "Airflow DAG Processor" "$SERVICE_USER" "$AIRFLOW_HOME" "$PYTHON_BIN_DIR" \
    "${AIRFLOW_EXE} dag-processor" "$COMMON_ENV"

create_service_unit "airflow-scheduler" "Airflow Scheduler" "$SERVICE_USER" "$AIRFLOW_HOME" "$PYTHON_BIN_DIR" \
    "${AIRFLOW_EXE} scheduler" "$COMMON_ENV"

create_service_unit "airflow-triggerer" "Airflow Triggerer" "$SERVICE_USER" "$AIRFLOW_HOME" "$PYTHON_BIN_DIR" \
    "${AIRFLOW_EXE} triggerer" "$COMMON_ENV"

SERVICES="airflow-apiserver airflow-scheduler airflow-dagprocessor airflow-triggerer"

if [ "$INSTALL_FLOWER" = "1" ]; then
    create_service_unit "airflow-flower" "Airflow Flower (Celery monitoring)" "$SERVICE_USER" "$AIRFLOW_HOME" "$PYTHON_BIN_DIR" \
        "${AIRFLOW_EXE} celery flower --port ${FLOWER_PORT}" "$COMMON_ENV"
    SERVICES="$SERVICES airflow-flower"
fi

for svc in $SERVICES; do
    log "Starting ${svc}.service ..."
    systemctl restart "${svc}.service" || die "Failed to start ${svc}.service — check 'journalctl -u ${svc}'"
done

if ! wait_for_port "127.0.0.1" "$API_PORT"; then
    die "Airflow API server did not open port ${API_PORT} in time. Check 'journalctl -u airflow-apiserver'."
fi
ok "Airflow API server is up on port ${API_PORT}."

# ------------------------------------------------------------------
# 8. Summary
# ------------------------------------------------------------------
{
    echo "====================================================================="
    echo " Apache Airflow ${AIRFLOW_VERSION} — cluster control node"
    echo " Generated: $(date +'%F %T')"
    echo "====================================================================="
    echo "AIRFLOW_HOME             : ${AIRFLOW_HOME}"
    echo "DAGs folder (shared)     : ${DAGS_FOLDER}"
    echo "Python                   : ${PYTHON_EXE} (${PYTHON_VERSION})"
    echo "OS service user          : ${SERVICE_USER}"
    echo "Executor                 : CeleryExecutor"
    echo "Metadata DB              : postgresql://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    echo "Celery broker (Redis)    : ${REDIS_HOST}:${REDIS_PORT}/${REDIS_DB}"
    echo "Systemd services         : ${SERVICES}"
    echo "Web UI / API server      : http://$(hostname -I 2>/dev/null | awk '{print $1}'):${API_PORT}"
    echo "Admin username           : ${ADMIN_USERNAME}"
    echo "Admin password           : (set as requested — not stored in this file)"
    echo "JWT issuer (api_auth)    : ${JWT_ISSUER}"
    echo "---------------------------------------------------------------------"
    echo " Give these EXACT values to airflow_cluster_worker.sh on every worker:"
    echo "   DB_HOST=${DB_HOST} DB_PORT=${DB_PORT} DB_NAME=${DB_NAME} DB_USER=${DB_USER}"
    echo "   REDIS_HOST=${REDIS_HOST} REDIS_PORT=${REDIS_PORT} REDIS_DB=${REDIS_DB}"
    echo "   DAGS_FOLDER=${DAGS_FOLDER}  (must be the SAME shared mount on the worker)"
    echo "   FERNET_KEY=<see this node's log — not repeated here for safety>"
    echo "====================================================================="
} | tee "$SUMMARY_FILE"
[ "$SERVICE_USER" != "root" ] && chown "$SERVICE_USER":"$SERVICE_USER" "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

print_banner "AIRFLOW CLUSTER CONTROL NODE INSTALLATION COMPLETE"
echo "(Summary saved to: $SUMMARY_FILE — passwords/keys intentionally omitted from the file)"
echo "Full install log: $LOG_FILE"
echo
echo "Next: run airflow_cluster_worker.sh on each worker node with matching"
echo "DB_*, REDIS_*, FERNET_KEY, and DAGS_FOLDER values."

