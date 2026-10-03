#!/bin/bash
#================================================================
# airflow_cluster_worker.sh
#
# Installs a WORKER-NODE role of an Airflow CeleryExecutor cluster:
# a single `airflow celery worker` process consuming from the same
# Redis broker/Postgres metadata DB as the control node. Run this on
# every worker node. Scale the cluster by running it on more nodes,
# not by editing this script.
#
# Companion script: airflow_cluster_scheduler.sh — run FIRST, on the
# control node, to migrate the DB and get FERNET_KEY / connection
# details to copy here.
#
# CRITICAL: DB_*, REDIS_*, FERNET_KEY and DAGS_FOLDER must be
# IDENTICAL to what was used on the control node. A mismatched
# FERNET_KEY will make this worker unable to decrypt connections and
# variables (tasks will fail with decryption errors); a mismatched
# DAGS_FOLDER means the worker won't find/execute the same DAG code.
#
# Non-interactive (AUTOMATED) usage:
#   AUTOMATED=1 BASE_DIR=/opt/ausiytic SERVICE_USER=airflow \
#   PYTHON_VERSION=3.10.10 AIRFLOW_VERSION=3.1.2 AIRFLOW_EXTRAS=hive \
#   DB_HOST=pg.internal DB_PORT=5432 DB_NAME=airflow DB_USER=airflow DB_PASSWORD='...' \
#   REDIS_HOST=redis.internal REDIS_PORT=6379 REDIS_DB=0 REDIS_PASSWORD='' \
#   FERNET_KEY='...' WEBSERVER_SECRET_KEY='...' \
#   DAGS_FOLDER=/mnt/shared/airflow-dags \
#   WORKER_QUEUES=default WORKER_CONCURRENCY=16 \
#   sudo -E ./airflow_cluster_worker.sh
#================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/airflow_cluster_worker.$(date +%Y%m%d%H%M%S).log"
touch "$LOG_FILE"

# shellcheck source=./airflow_cluster_common.sh
source "$SCRIPT_DIR/airflow_cluster_common.sh"

AUTOMATED="${AUTOMATED:-0}"
require_root
print_banner "Apache Airflow Cluster - Worker Node (celery worker)"
[ "$AUTOMATED" = "1" ] && log "Running in AUTOMATED (non-interactive) mode."

# ------------------------------------------------------------------
# 1. Input
# ------------------------------------------------------------------
BASE_DIR=$(prompt_base_dir "Base volume/mount path to install under" "/opt/ausiytic" "${BASE_DIR:-}")
SERVICE_USER=$(prompt_nonempty "OS user to run Airflow as" "airflow" "${SERVICE_USER:-}")
PYTHON_VERSION=$(prompt_nonempty "Python version to build from source" "3.10.10" "${PYTHON_VERSION:-}")
AIRFLOW_VERSION=$(prompt_nonempty "Apache Airflow version to install (MUST match the control node)" "3.1.2" "${AIRFLOW_VERSION:-}")
AIRFLOW_EXTRAS=$(prompt_nonempty "EXTRA Airflow extras beyond celery,postgres,redis (comma-separated, empty for none)" "" "${AIRFLOW_EXTRAS:-}")

DAGS_FOLDER=$(prompt_nonempty "Shared DAGs folder path (MUST be the same mount used on the control node)" "/opt/ausiytic/shared/dags" "${DAGS_FOLDER:-}")

echo "--- Metadata DB (same external Postgres as the control node) ---"
DB_HOST=$(prompt_nonempty "Postgres host" "" "${DB_HOST:-}")
DB_PORT=$(prompt_port "Postgres port" "5432" "${DB_PORT:-}")
DB_NAME=$(prompt_nonempty "Postgres database name" "airflow" "${DB_NAME:-}")
DB_USER=$(prompt_nonempty "Postgres user" "airflow" "${DB_USER:-}")
DB_PASSWORD=$(prompt_secret "Postgres password" "${DB_PASSWORD:-}" "${DB_PASSWORD:-}" 1)

echo "--- Celery broker (same external Redis as the control node) ---"
REDIS_HOST=$(prompt_nonempty "Redis host" "" "${REDIS_HOST:-}")
REDIS_PORT=$(prompt_port "Redis port" "6379" "${REDIS_PORT:-}")
REDIS_DB=$(prompt_nonempty "Redis DB index for the broker" "0" "${REDIS_DB:-}")
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
if [ "$AUTOMATED" != "1" ]; then
    read -rsp "Redis password (blank if none): " REDIS_PASSWORD; echo
fi

echo "--- Shared cluster secrets (copy EXACTLY from the control node) ---"
FERNET_KEY="${FERNET_KEY:-}"
if [ "$AUTOMATED" != "1" ] && [ -z "$FERNET_KEY" ]; then
    read -rsp "FERNET_KEY (from the control node's install output): " FERNET_KEY; echo
fi
require_matching_secret "FERNET_KEY" "$FERNET_KEY" "must be copied verbatim from the control node"

WEBSERVER_SECRET_KEY="${WEBSERVER_SECRET_KEY:-}"
if [ "$AUTOMATED" != "1" ] && [ -z "$WEBSERVER_SECRET_KEY" ]; then
    read -rsp "WEBSERVER_SECRET_KEY (from the control node's install output, blank to skip): " WEBSERVER_SECRET_KEY; echo
fi

WORKER_QUEUES=$(prompt_nonempty "Celery queue(s) this worker should consume (comma-separated)" "default" "${WORKER_QUEUES:-}")
WORKER_CONCURRENCY=$(prompt_nonempty "Worker concurrency (max parallel tasks on this node)" "16" "${WORKER_CONCURRENCY:-}")

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
SUMMARY_FILE="${BASE_DIR}/airflow_cluster_worker_summary.txt"
WORKER_SVC_NAME="airflow-worker-$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"

SQL_ALCHEMY_CONN="$(build_sql_conn "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$DB_PORT" "$DB_NAME")"
BROKER_URL="$(build_broker_url "$REDIS_HOST" "$REDIS_PORT" "$REDIS_DB" "$REDIS_PASSWORD")"
RESULT_BACKEND="$(build_result_backend "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$DB_PORT" "$DB_NAME")"

COMMON_ENV="AIRFLOW__CORE__EXECUTOR=CeleryExecutor
AIRFLOW__CORE__DAGS_FOLDER=${DAGS_FOLDER}
AIRFLOW__CORE__FERNET_KEY=${FERNET_KEY}
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=${SQL_ALCHEMY_CONN}
AIRFLOW__CELERY__BROKER_URL=${BROKER_URL}
AIRFLOW__CELERY__RESULT_BACKEND=${RESULT_BACKEND}
AIRFLOW__WEBSERVER__SECRET_KEY=${WEBSERVER_SECRET_KEY}"

# ------------------------------------------------------------------
# 3. Pre-flight connectivity
# ------------------------------------------------------------------
detect_os
install_deps
check_tcp_reachable "$DB_HOST" "$DB_PORT" "Postgres metadata DB"
check_tcp_reachable "$REDIS_HOST" "$REDIS_PORT" "Redis broker"

if [ ! -d "$DAGS_FOLDER" ]; then
    warn "DAGS_FOLDER '${DAGS_FOLDER}' does not exist on this node. If it's meant to be a shared mount (NFS/EFS/git-sync), mount it at this exact path NOW — the worker will not find any DAG code otherwise."
fi

# ------------------------------------------------------------------
# 4. Directories & service user
# ------------------------------------------------------------------
log "Creating directory structure under $BASE_DIR ..."
mkdir -p "$SOURCE_DIR" "$PYTHON_BINARIES" "$AIRFLOW_HOME"
ensure_service_user "$SERVICE_USER" "$BASE_DIR"
[ "$SERVICE_USER" != "root" ] && chown -R "$SERVICE_USER":"$SERVICE_USER" "$BASE_DIR"

# ------------------------------------------------------------------
# 5. Python + Airflow (no db migrate here — the control node owns that)
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

log "Verifying this worker can reach the metadata DB with 'airflow db check' ..."
AIRFLOW_HOME="$AIRFLOW_HOME" \
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="$SQL_ALCHEMY_CONN" \
AIRFLOW__CORE__FERNET_KEY="$FERNET_KEY" \
"$AIRFLOW_EXE" db check >> "$LOG_FILE" 2>&1 \
    || die "airflow db check failed — this worker cannot reach/authenticate to the metadata DB the control node uses, or FERNET_KEY is wrong. See $LOG_FILE"
ok "Metadata DB reachable and FERNET_KEY accepted."

# ------------------------------------------------------------------
# 6. systemd service + start
# ------------------------------------------------------------------
create_service_unit "$WORKER_SVC_NAME" "Airflow Celery Worker ($(hostname -s))" "$SERVICE_USER" "$AIRFLOW_HOME" "$PYTHON_BIN_DIR" \
    "${AIRFLOW_EXE} celery worker --queues ${WORKER_QUEUES} --concurrency ${WORKER_CONCURRENCY}" "$COMMON_ENV"

log "Starting ${WORKER_SVC_NAME}.service ..."
systemctl restart "${WORKER_SVC_NAME}.service" || die "Failed to start ${WORKER_SVC_NAME}.service — check 'journalctl -u ${WORKER_SVC_NAME}'"

sleep 3
if ! systemctl is-active --quiet "${WORKER_SVC_NAME}.service"; then
    die "${WORKER_SVC_NAME}.service failed to stay up. Check 'journalctl -u ${WORKER_SVC_NAME}' — common causes: FERNET_KEY mismatch, DAGS_FOLDER not mounted, broker/DB auth failure."
fi
ok "${WORKER_SVC_NAME} is running, consuming queue(s): ${WORKER_QUEUES}, concurrency ${WORKER_CONCURRENCY}."

# ------------------------------------------------------------------
# 7. Summary
# ------------------------------------------------------------------
{
    echo "====================================================================="
    echo " Apache Airflow ${AIRFLOW_VERSION} — cluster worker node ($(hostname -s))"
    echo " Generated: $(date +'%F %T')"
    echo "====================================================================="
    echo "AIRFLOW_HOME             : ${AIRFLOW_HOME}"
    echo "DAGs folder (shared)     : ${DAGS_FOLDER}"
    echo "Python                   : ${PYTHON_EXE} (${PYTHON_VERSION})"
    echo "OS service user          : ${SERVICE_USER}"
    echo "Systemd service          : ${WORKER_SVC_NAME}"
    echo "Queues consumed          : ${WORKER_QUEUES}"
    echo "Concurrency               : ${WORKER_CONCURRENCY}"
    echo "Metadata DB              : postgresql://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    echo "Celery broker (Redis)    : ${REDIS_HOST}:${REDIS_PORT}/${REDIS_DB}"
    echo "====================================================================="
} | tee "$SUMMARY_FILE"
[ "$SERVICE_USER" != "root" ] && chown "$SERVICE_USER":"$SERVICE_USER" "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

print_banner "AIRFLOW CLUSTER WORKER NODE INSTALLATION COMPLETE"
echo "(Summary saved to: $SUMMARY_FILE)"
echo "Full install log: $LOG_FILE"
echo
echo "Check task pickup from the control node's Flower UI (if installed) or:"
echo "  systemctl status ${WORKER_SVC_NAME}"
echo "  journalctl -u ${WORKER_SVC_NAME} -f"

