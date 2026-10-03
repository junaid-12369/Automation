#!/bin/bash
#================================================================
# airflow_cluster_common.sh
#
# Shared library sourced by:
#   - airflow_cluster_scheduler.sh   (control node: apiserver +
#     scheduler + dag-processor + triggerer + db migrate)
#   - airflow_cluster_worker.sh      (celery worker nodes)
#
# NOT meant to be run directly.
#
# Extends the conventions of airflow_install.sh (single-node) to a
# CeleryExecutor cluster:
#   - Metadata DB is EXTERNAL Postgres you already run (this script
#     never installs Postgres) — pass DB_HOST/DB_PORT/DB_NAME/
#     DB_USER/DB_PASSWORD.
#   - Broker is EXTERNAL Redis — pass REDIS_HOST/REDIS_PORT/
#     REDIS_DB/REDIS_PASSWORD (password optional).
#   - AIRFLOW__CORE__FERNET_KEY and AIRFLOW__WEBSERVER__SECRET_KEY
#     MUST be identical across every node in the cluster. Generate
#     them ONCE (see scheduler script's `--print-fernet-key` helper)
#     and pass the same values as FERNET_KEY / WEBSERVER_SECRET_KEY
#     to every role script on every node.
#   - AIRFLOW__CORE__DAGS_FOLDER must resolve to the SAME DAGs on
#     every node (NFS/EFS/S3-sync/git-sync/etc.) — this script does
#     NOT set up shared storage for you, it only points Airflow at
#     the path you give it via DAGS_FOLDER. Mount it identically on
#     every node before starting services.
#================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "airflow_cluster_common.sh is a library — source it from airflow_cluster_scheduler.sh or airflow_cluster_worker.sh, don't run it directly." >&2
    exit 1
fi

set -uo pipefail

AUTOMATED="${AUTOMATED:-0}"

# ---------- colors / logging ----------
C_GREEN="\033[0;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[0;31m"; C_BLUE="\033[0;34m"; C_RESET="\033[0m"

log()  { echo -e "${C_BLUE}[$(date +'%F %T')]${C_RESET} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${C_GREEN}[$(date +'%F %T')] [OK]${C_RESET} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${C_YELLOW}[$(date +'%F %T')] [WARN]${C_RESET} $*" | tee -a "$LOG_FILE"; }
die()  { echo -e "${C_RED}[$(date +'%F %T')] [ERROR]${C_RESET} $*" | tee -a "$LOG_FILE"; exit 1; }

print_banner() {
    echo
    echo "======================================================================"
    echo " $1"
    echo "======================================================================"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root (use sudo)."
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
            # Build deps for compiling Python from source + mysqlclient/psycopg2 headers
            BUILD_DEPS="build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev \
wget tar libbz2-dev liblzma-dev default-libmysqlclient-dev libpq-dev pkg-config"
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
            BUILD_DEPS="gcc gcc-c++ make zlib-devel ncurses-devel gdbm-devel \
nss-devel openssl-devel readline-devel libffi-devel sqlite-devel \
wget tar bzip2-devel xz-devel mysql-devel postgresql-devel pkgconfig"
            ;;
        *suse*|*sles*)
            OS_FAMILY="suse"
            PKG_UPDATE="zypper refresh"
            PKG_INSTALL="zypper install -y"
            BUILD_DEPS="gcc gcc-c++ make zlib-devel ncurses-devel gdbm-devel \
mozilla-nss-devel libopenssl-devel readline-devel libffi-devel sqlite3-devel \
wget tar libbz2-devel xz-devel libmysqlclient-devel postgresql-devel pkg-config"
            ;;
        *)
            die "Unsupported OS family (ID=$OS_ID ID_LIKE=$OS_LIKE). Supported: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma/Fedora/Amazon Linux, SUSE/SLES."
            ;;
    esac
    ok "Detected OS: $OS_ID (family: $OS_FAMILY)"
}

install_deps() {
    log "Installing build dependencies for family '$OS_FAMILY' ..."
    $PKG_UPDATE >> "$LOG_FILE" 2>&1
    # shellcheck disable=SC2086
    $PKG_INSTALL $BUILD_DEPS >> "$LOG_FILE" 2>&1 \
        || die "Dependency installation failed. See $LOG_FILE"
    ok "Dependencies installed."
}

# ---------- prompt helpers ----------
prompt_nonempty() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        [ -n "$val" ] || die "AUTOMATED mode: empty value not allowed for: $prompt_text"
        echo "$val"; return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"
        [ -n "$val" ] && { echo "$val"; return 0; }
        echo "  Value cannot be empty." >&2
    done
}

prompt_secret() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" min_len="${4:-8}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        [ -n "$val" ] || die "AUTOMATED mode: empty value not allowed for: $prompt_text"
        [ ${#val} -ge "$min_len" ] || die "AUTOMATED mode: $prompt_text must be at least $min_len characters."
        echo "$val"; return 0
    fi
    while true; do
        read -rsp "$prompt_text: " val
        echo >&2
        val="${val:-$default_val}"
        if [ ${#val} -ge "$min_len" ]; then echo "$val"; return 0; fi
        echo "  Value must be at least $min_len characters." >&2
    done
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

prompt_port() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
        valid_port "$val" || die "AUTOMATED mode: invalid port '$val' for: $prompt_text"
        echo "$val"; return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"
        valid_port "$val" && { echo "$val"; return 0; }
        echo "  '$val' is not a valid port (1-65535), try again." >&2
    done
}

prompt_base_dir() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    _reject_system_dir() {
        case "$1" in
            ""|"/"|"/root"|"/home"|"/etc"|"/usr"|"/var"|"/bin"|"/sbin"|"/lib"|"/boot"|"/sys"|"/proc"|"/dev") return 0 ;;
            *) return 1 ;;
        esac
    }
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"; val="${val%/}"
        _reject_system_dir "$val" && die "AUTOMATED mode: refusing to install under '$val' — this is a system directory."
        [[ "$val" == /* ]] || die "AUTOMATED mode: BASE_DIR must be an absolute path, got '$val'."
        echo "$val"; return 0
    fi
    while true; do
        read -rp "$prompt_text [$default_val]: " val
        val="${val:-$default_val}"; val="${val%/}"
        if _reject_system_dir "$val"; then
            echo "  Refusing to install under '$val' — this is a system directory. Choose a dedicated path (e.g. /opt/ausiytic)." >&2
            continue
        fi
        [[ "$val" == /* ]] || { echo "  Path must be absolute (start with /)." >&2; continue; }
        echo "$val"; return 0
    done
}

prompt_yesno() {
    local prompt_text="$1" default_val="$2" current_val="${3:-}" val
    if [ "$AUTOMATED" = "1" ]; then
        val="${current_val:-$default_val}"
    else
        read -rp "$prompt_text [$default_val] (y/n): " val
        val="${val:-$default_val}"
    fi
    val="$(echo "$val" | tr '[:upper:]' '[:lower:]')"
    case "$val" in
        y|yes|1) echo "1"; return 0 ;;
        n|no|0)  echo "0"; return 0 ;;
        *) die "Expected y/n, got '$val' for: $prompt_text" ;;
    esac
}

# ---------- OS service user ----------
ensure_service_user() {
    local svc_user="$1" base_dir="$2"
    if [ "$svc_user" = "root" ]; then
        warn "SERVICE_USER=root — Airflow will run as root. Not recommended for production; consider SERVICE_USER=airflow."
        return 0
    fi
    if id "$svc_user" >/dev/null 2>&1; then
        ok "OS user '$svc_user' already exists."
    else
        log "Creating OS user '$svc_user' (no login shell, system account)..."
        useradd --system --home-dir "$base_dir" --shell /usr/sbin/nologin "$svc_user" \
            || die "Failed to create OS user $svc_user"
        ok "OS user '$svc_user' created."
    fi
}

# ---------- build + install Python from source (idempotent) ----------
build_and_install_python() {
    local version="$1" source_dir="$2" prefix="$3"
    local bin_path="${prefix}/bin/python${version%.*}"

    if [ -x "$bin_path" ]; then
        ok "Python ${version} already installed at ${bin_path} — skipping build."
        return 0
    fi

    mkdir -p "$source_dir"
    cd "$source_dir" || die "Cannot cd into $source_dir"

    local tarball="Python-${version}.tgz"
    local url="https://www.python.org/ftp/python/${version}/${tarball}"

    if [ -f "$tarball" ]; then
        ok "Python source tarball already downloaded: $tarball"
    else
        log "Downloading Python ${version} from $url ..."
        wget -q --show-progress "$url" -O "$tarball" \
            || die "Download failed for $url. Check PYTHON_VERSION/network access."
    fi

    log "Extracting Python source..."
    tar -xzf "$tarball" || die "Extraction failed."

    local extracted_dir="Python-${version}"
    [ -d "$extracted_dir" ] || die "Extracted directory '$extracted_dir' not found — unexpected archive layout."
    cd "$extracted_dir" || die "Cannot cd into $extracted_dir"

    log "Configuring Python build (this can take a while)..."
    ./configure --enable-optimizations --prefix="$prefix" >> "$LOG_FILE" 2>&1 \
        || die "./configure failed. See $LOG_FILE"

    log "Compiling and installing Python (make altinstall) — this can take several minutes..."
    make -j"$(nproc)" altinstall >> "$LOG_FILE" 2>&1 \
        || die "make altinstall failed. See $LOG_FILE"

    [ -x "$bin_path" ] || die "Python build finished but $bin_path was not produced."
    ok "Python ${version} installed to ${prefix} ($($bin_path -V))."
}

symlink_python() {
    local prefix="$1" version="$2"
    local short_ver="${version%.*}"
    local target="/usr/bin/python"
    if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "${prefix}/bin/python${short_ver}")" ]; then
        ok "/usr/bin/python already symlinked to python${short_ver}."
    else
        ln -sfn "${prefix}/bin/python${short_ver}" "$target"
        ok "Symlinked ${target} -> ${prefix}/bin/python${short_ver}"
    fi
}

# ---------- Airflow install ----------
# Cluster nodes always need celery+postgres+redis regardless of role;
# extra role-specific / user-requested extras are merged in and deduped.
install_airflow() {
    local pybin="$1" version="$2" user_extras="$3"
    local required_extras="celery,postgres,redis"
    local merged
    merged="$(echo "${required_extras},${user_extras}" | tr ',' '\n' | sed '/^$/d' | awk '!seen[$0]++' | paste -sd, -)"

    log "Installing Apache Airflow ${version} (extras: ${merged}) — this can take a while..."
    "$pybin" -m pip install --upgrade pip >> "$LOG_FILE" 2>&1

    "$pybin" -m pip install "apache-airflow==${version}" >> "$LOG_FILE" 2>&1 \
        || die "apache-airflow==${version} install failed. See $LOG_FILE"

    IFS=',' read -ra EXTRA_LIST <<< "$merged"
    for extra in "${EXTRA_LIST[@]}"; do
        extra="$(echo "$extra" | xargs)"
        [ -z "$extra" ] && continue
        log "Installing extra: [$extra] ..."
        "$pybin" -m pip install "apache-airflow[${extra}]==${version}" >> "$LOG_FILE" 2>&1 \
            || die "apache-airflow[${extra}]==${version} install failed. See $LOG_FILE"
    done
    ok "Apache Airflow ${version} installed with extras: ${merged}."
}

setup_env_profile() {
    local airflow_home="$1" python_bin_dir="$2"
    cat > /etc/profile.d/airflow.sh <<EOF
export AIRFLOW_HOME=${airflow_home}
export PATH=${python_bin_dir}:\$PATH
EOF
    chmod 644 /etc/profile.d/airflow.sh
    ok "AIRFLOW_HOME and PATH exported system-wide via /etc/profile.d/airflow.sh"
}

# ---------- connection string builders ----------
build_sql_conn() {
    local user="$1" pass="$2" host="$3" port="$4" dbname="$5"
    printf 'postgresql+psycopg2://%s:%s@%s:%s/%s' \
        "$(urlencode "$user")" "$(urlencode "$pass")" "$host" "$port" "$dbname"
}

build_broker_url() {
    local host="$1" port="$2" db="$3" pass="${4:-}"
    if [ -n "$pass" ]; then
        printf 'redis://:%s@%s:%s/%s' "$(urlencode "$pass")" "$host" "$port" "$db"
    else
        printf 'redis://%s:%s/%s' "$host" "$port" "$db"
    fi
}

build_result_backend() {
    # db+postgresql result backend on the same metadata DB (recommended over redis for durability)
    local user="$1" pass="$2" host="$3" port="$4" dbname="$5"
    printf 'db+postgresql://%s:%s@%s:%s/%s' \
        "$(urlencode "$user")" "$(urlencode "$pass")" "$host" "$port" "$dbname"
}

urlencode() {
    local s="$1" out="" c
    for (( i=0; i<${#s}; i++ )); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%02X' "'$c"; out+="%$hex" ;;
        esac
    done
    echo "$out"
}

require_matching_secret() {
    # In AUTOMATED mode these must be explicitly supplied (never silently
    # generated) because scheduler/worker/webserver nodes must all agree.
    local varname="$1" val="$2" label="$3"
    if [ -z "$val" ]; then
        die "$varname is required and must be IDENTICAL across every node in the cluster ($label). Generate it once and pass it to every role script."
    fi
}

# ---------- systemd services ----------
# extra_env is a newline-separated list of KEY=VALUE pairs to inject as
# additional Environment= lines (e.g. AIRFLOW__DATABASE__SQL_ALCHEMY_CONN).
create_service_unit() {
    local name="$1" description="$2" svc_user="$3" airflow_home="$4" python_bin_dir="$5" exec_cmd="$6" extra_env="$7"
    local unit_file="/etc/systemd/system/${name}.service"

    log "Creating systemd unit: $unit_file"
    {
        echo "[Unit]"
        echo "Description=${description}"
        echo "Requires=network-online.target"
        echo "After=network-online.target"
        echo
        echo "[Service]"
        echo "Type=simple"
        echo "User=${svc_user}"
        echo "Group=${svc_user}"
        echo "Environment=\"AIRFLOW_HOME=${airflow_home}\""
        echo "Environment=\"PATH=${python_bin_dir}:/usr/bin:/bin\""
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local key="${line%%=*}"
            local value="${line#*=}"
            echo "Environment=\"${key}=${value}\""
        done <<< "$extra_env"
        echo "ExecStart=${exec_cmd}"
        echo "Restart=always"
        echo "RestartSec=5s"
        echo
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > "$unit_file"

    systemctl daemon-reload
    systemctl enable "${name}.service" >> "$LOG_FILE" 2>&1
    ok "systemd service '${name}' created and enabled."
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

check_tcp_reachable() {
    # Fail fast with a clear message if DB/broker aren't reachable from this
    # node, instead of installing everything and failing deep in db migrate.
    local host="$1" port="$2" label="$3"
    log "Checking connectivity to ${label} at ${host}:${port} ..."
    if (echo > "/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
        ok "${label} reachable at ${host}:${port}."
    else
        die "${label} NOT reachable at ${host}:${port}. Check network/security-group/firewall rules before continuing."
    fi
}

