#!/usr/bin/env bash
###############################################################################
# opensearch_dashboards_install.sh   (v3.3.0 edition)
#
# Automated OpenSearch Dashboards install (default version 3.3.0).
#
#   - Takes everything from flags / env vars; prompts only for what is missing
#     (so it works by hand AND unattended from Jenkins)
#   - Pre-flight: checks OpenSearch is reachable with the given credentials
#   - Detects RHEL-like vs Debian-like OS, installs missing prerequisites
#   - Downloads + extracts the Dashboards tarball, lays out binaries/data
#   - Writes opensearch_dashboards.yml duplicate-key-safe (values are YAML-quoted,
#     so passwords with  # : { }  etc. are safe)
#   - Trusts OpenSearch's root CA (auto-detects the CA made by opensearch_install.sh,
#     or use --opensearch-root-ca), else falls back to verificationMode: none
#   - Opens the port on firewalld/ufw if active, creates + starts a systemd service
#   - Verifies the UI answers on /api/status
#
# Jenkins usage (what the pipeline already does):
#   --base-dir D --opensearch-host H --opensearch-port P --opensearch-user admin
#   --opensearch-password "$OS_ADMIN_PASSWORD" --bind-host 0.0.0.0
#   [--opensearch-root-ca /tmp/opensearch-root-ca.pem]     and 'Y' on stdin
#   (The password can also come from the env var OS_ADMIN_PASSWORD or OS_PASSWORD,
#    so you may drop the --opensearch-password flag if you prefer.)
#
# Safe to re-run: skips steps whose output already exists.
###############################################################################

set -Eeuo pipefail

# ============================= CONFIG ======================================
OSD_VERSION="${OSD_VERSION:-3.3.0}"          # env var or --version overrides
DEFAULT_BASE_DISK_DIR="/opt/ausiytic"
DEFAULT_OS_PORT="9200"
DEFAULT_OS_USERNAME="admin"
DASHBOARDS_PORT="5601"
MIN_FREE_KB=2097152                           # 2 GiB free required on the base disk

SERVICE_USER="${SERVICE_USER:-opensearch-dashboards}"
SERVICE_GROUP="${SERVICE_GROUP:-${SERVICE_USER}}"
SERVICE_FILE="/etc/systemd/system/opensearch-dashboards.service"
LOG_FILE="/var/log/opensearch_dashboards_install.log"

# 'certificate' = verify the CA chain but not the hostname/IP (safe default when
# connecting by IP). Use 'full' if your OpenSearch cert has SANs for the host you use.
SSL_MODE_WITH_CA="${OSD_SSL_MODE:-certificate}"
ASSUME_YES="${ASSUME_YES:-0}"
[[ "${AUTOMATED:-0}" == "1" ]] && ASSUME_YES=1

# Pick up values passed through the environment (flags below override them)
BASE_DISK_DIR="${BASE_DISK_DIR:-}"
OS_HOST="${OS_HOST:-}"
OS_PORT="${OS_PORT:-}"
OS_USERNAME="${OS_USERNAME:-}"
OS_PASSWORD="${OS_PASSWORD:-${OS_ADMIN_PASSWORD:-}}"
BIND_HOST="${BIND_HOST:-}"
OPENSEARCH_ROOT_CA="${OPENSEARCH_ROOT_CA:-}"

# ============================ LOGGING ======================================
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}" >&2
}
fail() {
    log "ERROR: $1"
    exit 1
}
require_root() {
    [[ "${EUID}" -eq 0 ]] || fail "This script must be run as root (or with sudo)."
}

# ============================ OS DETECTION ==================================
OS_FAMILY=""
PKG_MANAGER=""
NOLOGIN_SHELL="/sbin/nologin"

detect_os() {
    log "STEP: Detecting operating system"
    if [[ ! -f /etc/os-release ]]; then
        log "WARNING: /etc/os-release not found. Proceeding with best-effort defaults."
        OS_FAMILY="unknown"
        return 0
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    local id="${ID:-}" id_like="${ID_LIKE:-}"

    if [[ "${id}" =~ ^(rhel|centos|rocky|almalinux|fedora|ol)$ ]] || [[ "${id_like}" == *rhel* ]] || [[ "${id_like}" == *fedora* ]]; then
        OS_FAMILY="rhel"
        if command -v dnf >/dev/null 2>&1; then PKG_MANAGER="dnf"; else PKG_MANAGER="yum"; fi
        NOLOGIN_SHELL="$(command -v nologin || echo /sbin/nologin)"
    elif [[ "${id}" =~ ^(ubuntu|debian)$ ]] || [[ "${id_like}" == *debian* ]]; then
        OS_FAMILY="debian"
        PKG_MANAGER="apt-get"
        NOLOGIN_SHELL="$(command -v nologin || echo /usr/sbin/nologin)"
    else
        log "WARNING: Unrecognized OS ID='${id}' ID_LIKE='${id_like}'. Treating as generic Linux."
        OS_FAMILY="unknown"
    fi
    log "Detected OS family: ${OS_FAMILY} (${PRETTY_NAME:-unknown}), package manager: ${PKG_MANAGER:-none}"
}

install_packages() {
    local pkgs=("$@")
    [[ "${#pkgs[@]}" -eq 0 ]] && return 0
    case "${PKG_MANAGER}" in
        dnf|yum)
            "${PKG_MANAGER}" install -y "${pkgs[@]}" || fail "Failed to install packages via ${PKG_MANAGER}: ${pkgs[*]}"
            ;;
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || log "WARNING: apt-get update failed, continuing with existing cache."
            apt-get install -y "${pkgs[@]}" || fail "Failed to install packages via apt-get: ${pkgs[*]}"
            ;;
        *)
            fail "Cannot auto-install packages (${pkgs[*]}); unsupported package manager. Install them manually and re-run."
            ;;
    esac
}

# ============================ INPUT HANDLING ================================
prompt_with_default() {
    local prompt_text="$1" default_val="$2" input_val=""
    read -rp "${prompt_text} [${default_val}]: " input_val || true     # EOF (no stdin) -> default
    echo "${input_val:-${default_val}}"
}

normalize_path() {
    local p="$1"
    p="${p%/}"
    [[ -z "${p}" ]] && p="/"
    echo "${p}"
}

validate_and_prepare_base_dir() {
    local dir
    dir="$(normalize_path "$1")"

    [[ "${dir}" == /* ]] || { log "ERROR: '${dir}' is not an absolute path. It must start with /"; return 1; }
    if [[ -e "${dir}" && ! -d "${dir}" ]]; then
        log "ERROR: '${dir}' already exists and is not a directory."; return 1
    fi
    mkdir -p "${dir}" || { log "ERROR: Could not create '${dir}'. Check the disk/mount and permissions."; return 1; }
    [[ -w "${dir}" ]] || { log "ERROR: '${dir}' exists but is not writable."; return 1; }

    local avail_kb
    avail_kb="$(df -Pk "${dir}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "${avail_kb}" && "${avail_kb}" -lt "${MIN_FREE_KB}" ]]; then
        log "ERROR: Only $((avail_kb/1024))MB free under '${dir}'; at least $((MIN_FREE_KB/1024))MB is required. Free up space or choose another disk."
        return 1
    fi

    if [[ "${dir}" == "/" && "${ASSUME_YES}" != "1" ]]; then
        log "WARNING: root filesystem ('/') chosen; Dashboards data/logs will share the OS partition."
        local root_confirm=""
        read -rp "Really install under '/'? [y/N]: " root_confirm || true
        [[ "${root_confirm}" =~ ^[Yy]$ ]] || { log "Rejected '/'."; return 1; }
    fi
    echo "${dir}"
}

find_opensearch_root_ca() {
    # Best-effort lookup of the root CA made by opensearch_install.sh
    local candidates=(
        "/data/opensearch/search/opensearch/binaries/config/certs/root-ca.pem"
        "${BASE_DISK_DIR%/}/search/opensearch/binaries/config/certs/root-ca.pem"
        "/opt/ausiytic/search/opensearch/binaries/config/certs/root-ca.pem"
        "${BASE_DISK_DIR%/}/apps/opensearch/binaries/config/root-ca.pem"
        "/opt/ausiytic/apps/opensearch/binaries/config/root-ca.pem"
        "/apps/opensearch/binaries/config/root-ca.pem"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -f "${c}" ]] && { echo "${c}"; return 0; }
    done
    local found
    found="$(find / -maxdepth 9 \( -path /proc -o -path /sys -o -path /dev \) -prune -o -name root-ca.pem -path '*opensearch*' -print 2>/dev/null | head -n1 || true)"
    [[ -n "${found}" ]] && { echo "${found}"; return 0; }
    return 1
}

step_prompt_inputs() {
    log "STEP: Auto-detecting node name/bind IP; collecting disk path and OpenSearch connection details"

    local detected_hostname detected_ip
    detected_hostname="$(hostname -s 2>/dev/null || hostname)"
    detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -z "${detected_ip}" ]] && detected_ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
    [[ -n "${detected_hostname}" ]] || fail "Could not auto-detect hostname."
    [[ -n "${detected_ip}" ]] || fail "Could not auto-detect a network IP for this server."

    NODE_HOSTNAME="${detected_hostname}"
    DETECTED_IP="${detected_ip}"
    log "Auto-detected NODE_HOSTNAME=${NODE_HOSTNAME}, DETECTED_IP=${DETECTED_IP}"

    # ---- base directory ----
    if [[ -z "${BASE_DISK_DIR}" ]]; then
        echo ""
        echo "=========================================================="
        echo " Available mounted filesystems on this server:"
        df -hT 2>/dev/null | awk 'NR==1 || $2!="tmpfs"'
        echo "=========================================================="
        if [[ "${ASSUME_YES}" == "1" ]]; then
            BASE_DISK_DIR="$(validate_and_prepare_base_dir "${DEFAULT_BASE_DISK_DIR}")" || fail "Default base dir '${DEFAULT_BASE_DISK_DIR}' is not usable."
        else
            while true; do
                local candidate normalized
                candidate="$(prompt_with_default "Enter base disk/directory path where Dashboards will be installed" "${DEFAULT_BASE_DISK_DIR}")"
                if normalized="$(validate_and_prepare_base_dir "${candidate}")"; then
                    BASE_DISK_DIR="${normalized}"
                    break
                fi
                echo "Please enter a different path."
            done
        fi
    else
        local normalized
        log "Using pre-set base dir: ${BASE_DISK_DIR}"
        normalized="$(validate_and_prepare_base_dir "${BASE_DISK_DIR}")" || fail "Base dir '${BASE_DISK_DIR}' is not usable."
        BASE_DISK_DIR="${normalized}"
    fi

    local base_join="${BASE_DISK_DIR%/}"
    BASE_SOFTWARE_DIR="${base_join}/softwares/opensearch-dashboards"
    APP_BASE_DIR="${base_join}/apps/opensearch-dashboards"
    BINARIES_DIR="${APP_BASE_DIR}/binaries"
    DATA_DIR="${APP_BASE_DIR}/data"
    CONFIG_DIR="${BINARIES_DIR}/config"

    # ---- OpenSearch connection ----
    [[ -n "${OS_HOST}" ]]     || OS_HOST="$(prompt_with_default "Enter OpenSearch host/IP to connect to" "${DETECTED_IP}")"
    [[ -n "${OS_PORT}" ]]     || OS_PORT="$(prompt_with_default "Enter OpenSearch HTTP port" "${DEFAULT_OS_PORT}")"
    [[ -n "${OS_USERNAME}" ]] || OS_USERNAME="$(prompt_with_default "Enter OpenSearch admin username" "${DEFAULT_OS_USERNAME}")"
    if [[ -z "${OS_PASSWORD}" ]]; then
        read -rsp "Enter OpenSearch password for user '${OS_USERNAME}': " OS_PASSWORD || true
        echo ""
        [[ -n "${OS_PASSWORD}" ]] || fail "OpenSearch password cannot be empty."
    fi
    [[ -n "${BIND_HOST}" ]] || BIND_HOST="$(prompt_with_default "Address for Dashboards to listen on (0.0.0.0 = all interfaces)" "0.0.0.0")"

    echo ""
    echo "=========================================================="
    echo " Dashboards version  : ${OSD_VERSION}"
    echo " Node hostname       : ${NODE_HOSTNAME}"
    echo " Base disk directory : ${BASE_DISK_DIR}"
    echo " OpenSearch endpoint : https://${OS_HOST}:${OS_PORT}"
    echo " OpenSearch user     : ${OS_USERNAME}"
    echo " Dashboards bind     : ${BIND_HOST}:${DASHBOARDS_PORT}"
    echo " Service user        : ${SERVICE_USER}"
    echo "=========================================================="
    if [[ "${ASSUME_YES}" != "1" ]]; then
        local confirm=""
        read -rp "Confirm and continue? [Y/n]: " confirm || true       # EOF -> treated as Y
        confirm="${confirm:-Y}"
        [[ "${confirm}" =~ ^[Yy]$ ]] || fail "Aborted by user at input confirmation step."
    fi
}

# ============================ STEP FUNCTIONS ================================
step_prereqs() {
    log "STEP: Checking prerequisites (wget, tar, curl, systemctl, awk) for OS family '${OS_FAMILY}'"
    local missing=() cmd
    for cmd in wget tar curl systemctl awk; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        log "Missing commands: ${missing[*]}. Installing via ${PKG_MANAGER:-<none detected>}."
        local pkgs=() c
        for c in "${missing[@]}"; do
            case "${c}" in
                systemctl) pkgs+=("systemd") ;;
                awk) pkgs+=("gawk") ;;
                *) pkgs+=("${c}") ;;
            esac
        done
        install_packages "${pkgs[@]}"
        for cmd in "${missing[@]}"; do
            command -v "${cmd}" >/dev/null 2>&1 || fail "'${cmd}' still not available after install attempt."
        done
    fi

    getent group "${SERVICE_GROUP}" >/dev/null 2>&1 || {
        log "Creating group '${SERVICE_GROUP}'"
        groupadd --system "${SERVICE_GROUP}" || fail "Failed to create group ${SERVICE_GROUP}"
    }
    id "${SERVICE_USER}" &>/dev/null || {
        log "Creating user '${SERVICE_USER}'"
        useradd --system -M -s "${NOLOGIN_SHELL}" -g "${SERVICE_GROUP}" "${SERVICE_USER}" || fail "Failed to create user ${SERVICE_USER}"
    }

    local mem_total_mb
    mem_total_mb="$(free -m | awk '/^Mem:/{print $2}')"
    if [[ -n "${mem_total_mb}" && "${mem_total_mb}" -lt 1536 ]]; then
        log "WARNING: Total memory is ${mem_total_mb}MB. Dashboards 3.x may be slow or get OOM-killed below ~1.5GB."
    fi
}

step_preflight_check_opensearch() {
    log "STEP: Verifying OpenSearch at https://${OS_HOST}:${OS_PORT} is reachable with the given credentials"
    local http_code body="/tmp/.osd_preflight_body"
    http_code="$(curl -sk -o "${body}" -w '%{http_code}' -u "${OS_USERNAME}:${OS_PASSWORD}" \
                 "https://${OS_HOST}:${OS_PORT}/_cluster/health" --max-time 10 || true)"
    if [[ "${http_code}" == "200" ]]; then
        log "OpenSearch reachable, credentials valid. Cluster health: $(cat "${body}")"
    elif [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
        rm -f "${body}"
        fail "OpenSearch rejected the credentials (HTTP ${http_code}). Check the OpenSearch admin password."
    else
        rm -f "${body}"
        fail "Could not reach OpenSearch at https://${OS_HOST}:${OS_PORT} (HTTP code: '${http_code:-none}'). Check host/port, that OpenSearch is running, and the security group/firewall. Nothing was changed."
    fi
    rm -f "${body}"
}

step_download_extract() {
    log "STEP: Download & extract OpenSearch Dashboards ${OSD_VERSION}"
    mkdir -p "${BASE_SOFTWARE_DIR}"
    cd "${BASE_SOFTWARE_DIR}"

    local marker="${BINARIES_DIR}/bin/opensearch-dashboards"
    if [[ -f "${marker}" ]]; then
        log "Dashboards already installed at ${BINARIES_DIR}, skipping download/extract."
        return 0
    fi
    if [[ -d "${BINARIES_DIR}" ]]; then
        log "WARNING: ${BINARIES_DIR} exists but is incomplete (missing ${marker}). Removing and re-extracting."
        rm -rf "${BINARIES_DIR}"
    fi

    if [[ ! -f "${OSD_TARBALL}" ]]; then
        log "Downloading ${OSD_DOWNLOAD_URL}"
        wget -q "${OSD_DOWNLOAD_URL}" -O "${OSD_TARBALL}" || { rm -f "${OSD_TARBALL}"; fail "Download failed (check the version ${OSD_VERSION} exists and the server has internet access)."; }
    else
        log "Tarball already present, skipping download."
    fi

    log "Extracting ${OSD_TARBALL}"
    tar -xzf "${OSD_TARBALL}" || { rm -f "${OSD_TARBALL}"; fail "Extraction failed (corrupt download removed; re-run)."; }
}

step_setup_dirs() {
    log "STEP: Creating app directories"
    mkdir -p "${BINARIES_DIR}" "${DATA_DIR}"

    local extracted_dir="${BASE_SOFTWARE_DIR}/opensearch-dashboards-${OSD_VERSION}"
    if [[ -d "${extracted_dir}" ]]; then
        log "Moving extracted files to ${BINARIES_DIR}"
        shopt -s dotglob nullglob
        local f
        for f in "${extracted_dir}"/*; do
            mv -n "${f}" "${BINARIES_DIR}/"
        done
        shopt -u dotglob nullglob
        rmdir "${extracted_dir}" 2>/dev/null || true
    else
        log "Extracted source dir not found (already moved?), continuing."
    fi
    step_fix_extracted_permissions
}

step_fix_extracted_permissions() {
    log "STEP: Ensuring Dashboards binaries are executable"
    [[ -d "${BINARIES_DIR}/bin" ]] && find "${BINARIES_DIR}/bin" -maxdepth 1 -type f -exec chmod +x {} \;
    [[ -d "${BINARIES_DIR}/node/bin" ]] && find "${BINARIES_DIR}/node/bin" -maxdepth 1 -type f -exec chmod +x {} \; 2>/dev/null
    return 0
}

step_wire_opensearch_trust() {
    log "STEP: Configuring TLS trust of the OpenSearch certificate"
    local ca_dest="${CONFIG_DIR}/opensearch-root-ca.pem" ca_src=""

    if [[ -n "${OPENSEARCH_ROOT_CA}" && -f "${OPENSEARCH_ROOT_CA}" ]]; then
        ca_src="${OPENSEARCH_ROOT_CA}"
    else
        [[ -n "${OPENSEARCH_ROOT_CA}" ]] && log "WARNING: --opensearch-root-ca '${OPENSEARCH_ROOT_CA}' not found; trying auto-detection."
        ca_src="$(find_opensearch_root_ca || true)"
    fi

    if [[ -n "${ca_src}" && -f "${ca_src}" ]]; then
        log "Using OpenSearch root CA ${ca_src} (verificationMode: ${SSL_MODE_WITH_CA})"
        cp -f "${ca_src}" "${ca_dest}"
        chmod 644 "${ca_dest}"
        SSL_VERIFICATION_MODE="${SSL_MODE_WITH_CA}"
        SSL_CA_PATH="${ca_dest}"
    else
        log "WARNING: OpenSearch root CA not found. Falling back to opensearch.ssl.verificationMode: none (TLS used, certificate NOT verified). Pass --opensearch-root-ca /path/root-ca.pem to fix."
        SSL_VERIFICATION_MODE="none"
        SSL_CA_PATH=""
    fi
}

# Quote a string as a YAML double-quoted scalar (safe for passwords with # : { } etc.)
yaml_dq() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "${s}"
}

step_configure_yml() {
    log "STEP: Configuring opensearch_dashboards.yml"
    local yml="${CONFIG_DIR}/opensearch_dashboards.yml"
    [[ -f "${yml}" ]] || fail "opensearch_dashboards.yml not found at ${yml}"

    # keep one pristine copy; always rewrite from it so re-runs never stack edits
    if [[ ! -f "${yml}.orig" ]]; then cp "${yml}" "${yml}.orig"; else cp "${yml}.orig" "${yml}"; fi

    # Delete EVERY line for the key (commented or not), then append exactly one active line.
    set_yaml_kv_force() {
        local key="$1" val="$2" escaped_key
        escaped_key="$(printf '%s' "${key}" | sed -E 's/[.]/\\./g')"
        sed -i -E "/^[[:space:]]*#?[[:space:]]*${escaped_key}:/d" "${yml}"
        printf '%s: %s\n' "${key}" "${val}" >> "${yml}"
    }

    set_yaml_kv_force "server.port" "${DASHBOARDS_PORT}"
    set_yaml_kv_force "server.host" "$(yaml_dq "${BIND_HOST}")"
    set_yaml_kv_force "server.name" "$(yaml_dq "${NODE_HOSTNAME}")"
    set_yaml_kv_force "opensearch.hosts" "[$(yaml_dq "https://${OS_HOST}:${OS_PORT}")]"
    set_yaml_kv_force "opensearch.username" "$(yaml_dq "${OS_USERNAME}")"
    set_yaml_kv_force "opensearch.password" "$(yaml_dq "${OS_PASSWORD}")"
    set_yaml_kv_force "opensearch.ssl.verificationMode" "${SSL_VERIFICATION_MODE}"
    set_yaml_kv_force "opensearch.requestHeadersAllowlist" "[authorization, securitytenant]"
    if [[ -n "${SSL_CA_PATH}" ]]; then
        set_yaml_kv_force "opensearch.ssl.certificateAuthorities" "[$(yaml_dq "${SSL_CA_PATH}")]"
    fi

    # Security plugin settings
    set_yaml_kv_force "opensearch_security.multitenancy.enabled" "true"
    set_yaml_kv_force "opensearch_security.multitenancy.tenants.preferred" "[Private, Global]"
    set_yaml_kv_force "opensearch_security.readonly_mode.roles" "[kibana_read_only]"
    set_yaml_kv_force "opensearch_security.cookie.secure" "false"       # Dashboards itself is served over plain http

    # critical keys active?
    local missing=() key
    for key in "server.port" "server.host" "opensearch.hosts" "opensearch.username" "opensearch.password"; do
        grep -qE "^${key//./\\.}:" "${yml}" || missing+=("${key}")
    done
    [[ "${#missing[@]}" -eq 0 ]] || fail "Failed to activate config keys: ${missing[*]}. Check ${yml}."

    # duplicate-key guard
    local dupes
    dupes="$(grep -oE '^[A-Za-z0-9_.]+:' "${yml}" | sort | uniq -d || true)"
    [[ -z "${dupes}" ]] || fail "Duplicate keys in ${yml}: $(echo "${dupes}" | tr '\n' ' '). Refusing to start."

    # YAML syntax check (skipped quietly if python3/pyyaml are missing)
    if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
        python3 - "${yml}" <<'PY' || fail "opensearch_dashboards.yml failed YAML validation. Inspect ${yml}."
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        yaml.safe_load(f)
except Exception as e:
    print(e, file=sys.stderr)
    sys.exit(1)
PY
    fi

    chmod 640 "${yml}"
    log "opensearch_dashboards.yml configured, de-duplicated and verified."
}

step_fix_ownership() {
    log "STEP: Fixing ownership of app directories"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_BASE_DIR}"
}

step_firewall() {
    log "STEP: Opening port ${DASHBOARDS_PORT} on the active firewall (if any)"
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${DASHBOARDS_PORT}/tcp" >/dev/null 2>&1 \
            && firewall-cmd --reload >/dev/null 2>&1 \
            && log "firewalld: opened ${DASHBOARDS_PORT}/tcp" \
            || log "WARNING: could not add firewalld rule. Run: firewall-cmd --permanent --add-port=${DASHBOARDS_PORT}/tcp"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${DASHBOARDS_PORT}/tcp" >/dev/null 2>&1 \
            && log "ufw: opened ${DASHBOARDS_PORT}/tcp" \
            || log "WARNING: could not add ufw rule. Run: ufw allow ${DASHBOARDS_PORT}/tcp"
    else
        log "No active firewalld/ufw detected. Skipping. (On AWS also open ${DASHBOARDS_PORT} in the security group.)"
    fi
}

step_create_service() {
    log "STEP: Creating systemd service file"
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=OpenSearch Dashboards
Documentation=https://opensearch.org/docs/latest/dashboards/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${BINARIES_DIR}
Environment=OPENSEARCH_DASHBOARDS_HOME=${BINARIES_DIR}
Environment=OPENSEARCH_DASHBOARDS_PATH_CONF=${CONFIG_DIR}
ExecStart=${BINARIES_DIR}/bin/opensearch-dashboards
LimitNOFILE=65536
StandardOutput=journal
StandardError=inherit
Restart=always
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
    log "Service file written to ${SERVICE_FILE}"
}

step_start_service() {
    log "STEP: Enabling and starting opensearch-dashboards service"
    systemctl daemon-reload
    systemctl enable opensearch-dashboards.service
    systemctl restart opensearch-dashboards.service

    log "Waiting for service to come up..."
    sleep 10
    systemctl status opensearch-dashboards --no-pager || true

    if ! systemctl is-active --quiet opensearch-dashboards; then
        log "ERROR: opensearch-dashboards is not active after startup. Recent logs:"
        journalctl -u opensearch-dashboards -n 60 --no-pager | tee -a "${LOG_FILE}" >&2 || true
        fail "opensearch-dashboards failed to start. See the log lines above and ${LOG_FILE}."
    fi
}

step_final_verify() {
    log "STEP: Verifying Dashboards is responding on port ${DASHBOARDS_PORT}"
    local check_host="${BIND_HOST}"
    [[ "${check_host}" == "0.0.0.0" ]] && check_host="127.0.0.1"

    local code="" body="" waited=0 timeout_s=120
    while (( waited < timeout_s )); do
        if ! systemctl is-active --quiet opensearch-dashboards; then
            log "ERROR: opensearch-dashboards stopped while waiting for /api/status. Recent logs:"
            journalctl -u opensearch-dashboards -n 60 --no-pager | tee -a "${LOG_FILE}" >&2 || true
            fail "opensearch-dashboards crashed during startup verification. See ${LOG_FILE}."
        fi
        code="$(curl -s -o /tmp/.osd_status_body -w '%{http_code}' "http://${check_host}:${DASHBOARDS_PORT}/api/status" --max-time 10 || true)"
        body="$(cat /tmp/.osd_status_body 2>/dev/null || true)"
        # 200 = status JSON, 401/302 = UI is up but wants a login (security plugin) -> also fine
        [[ "${code}" == "200" || "${code}" == "401" || "${code}" == "302" ]] && break
        sleep 5
        waited=$((waited + 5))
    done
    rm -f /tmp/.osd_status_body

    if [[ "${code}" == "200" ]] && echo "${body}" | grep -q '"state":"green"'; then
        log "Dashboards is up and reports state: green."
    elif [[ "${code}" == "200" || "${code}" == "401" || "${code}" == "302" ]]; then
        log "Dashboards is responding (HTTP ${code}) but did not report 'green' on /api/status. Open the UI and check it logs in."
    else
        log "WARNING: Dashboards did not answer within ${timeout_s}s (last HTTP code: '${code:-none}'). Check: journalctl -u opensearch-dashboards -f"
    fi
}

# ============================ CLI ARG PARSING ================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)             OSD_VERSION="$2"; shift 2 ;;
            --base-dir)            BASE_DISK_DIR="$2"; shift 2 ;;
            --opensearch-host)     OS_HOST="$2"; shift 2 ;;
            --opensearch-port)     OS_PORT="$2"; shift 2 ;;
            --opensearch-user)     OS_USERNAME="$2"; shift 2 ;;
            --opensearch-password) OS_PASSWORD="$2"; shift 2 ;;
            --opensearch-root-ca)  OPENSEARCH_ROOT_CA="$2"; shift 2 ;;
            --bind-host)           BIND_HOST="$2"; shift 2 ;;
            --service-user)        SERVICE_USER="$2"; SERVICE_GROUP="${SERVICE_GROUP_SET:-$2}"; shift 2 ;;
            --service-group)       SERVICE_GROUP="$2"; SERVICE_GROUP_SET="$2"; shift 2 ;;
            --ssl-mode)            SSL_MODE_WITH_CA="$2"; shift 2 ;;
            -y|--yes)              ASSUME_YES=1; shift ;;
            -h|--help)
                cat <<EOF
Usage: sudo $0 [options]

  --version VER                Dashboards version (default: ${OSD_VERSION}; or env OSD_VERSION).
  --base-dir PATH              Base directory/disk (default: ${DEFAULT_BASE_DISK_DIR}).
  --opensearch-host HOST       OpenSearch host/IP.
  --opensearch-port PORT       OpenSearch HTTP port (default: ${DEFAULT_OS_PORT}).
  --opensearch-user USER       OpenSearch user (default: ${DEFAULT_OS_USERNAME}).
  --opensearch-password PASS   Password (or env OS_ADMIN_PASSWORD / OS_PASSWORD). Prompted if omitted.
  --opensearch-root-ca PATH    OpenSearch root-ca.pem for TLS trust (auto-detected if omitted).
  --ssl-mode MODE              certificate (default) | full. Used when a root CA is found.
  --bind-host HOST             Listen address (default: 0.0.0.0).
  --service-user USER          Linux user for the service (default: ${SERVICE_USER}; created if missing).
  --service-group GROUP        Linux group for the service (default: same as user).
  -y, --yes                    Do not ask for confirmation (also implied by env AUTOMATED=1).

Anything not given is prompted for. A prompt that hits end-of-input uses its default.
EOF
                exit 0
                ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
}

# ================================ MAIN ======================================
main() {
    parse_args "$@"
    require_root
    touch "${LOG_FILE}"

    OSD_TARBALL="opensearch-dashboards-${OSD_VERSION}-linux-x64.tar.gz"
    OSD_DOWNLOAD_URL="https://artifacts.opensearch.org/releases/bundle/opensearch-dashboards/${OSD_VERSION}/${OSD_TARBALL}"

    log "===== Starting OpenSearch Dashboards automated install (v${OSD_VERSION}) ====="

    detect_os
    step_prompt_inputs
    step_prereqs
    step_preflight_check_opensearch
    step_download_extract
    step_setup_dirs
    step_wire_opensearch_trust
    step_configure_yml
    step_fix_ownership
    step_firewall
    step_create_service
    step_start_service
    step_final_verify

    log "===== OpenSearch Dashboards ${OSD_VERSION} installation complete ====="
    log "Base disk dir : ${BASE_DISK_DIR}"
    log "Bind address  : ${BIND_HOST}:${DASHBOARDS_PORT}"
    log "OpenSearch    : https://${OS_HOST}:${OS_PORT} (user: ${OS_USERNAME})"
    log "Check status  : systemctl status opensearch-dashboards"
    log "Tail logs     : journalctl -u opensearch-dashboards -f"
    log "Access UI     : http://${DETECTED_IP}:${DASHBOARDS_PORT}"
}

main "$@"
