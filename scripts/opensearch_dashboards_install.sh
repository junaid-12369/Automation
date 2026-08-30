#!/usr/bin/env bash
###############################################################################
# opensearch_dashboards_install.sh
#
# Fully automated OpenSearch Dashboards install:
#   - Prompt for base disk/directory, OpenSearch endpoint + credentials
#     (node name & bind IP auto-detected)
#   - Pre-flight check: verify the target OpenSearch cluster is actually
#     reachable with the given credentials BEFORE doing anything else
#   - Detect OS family (RHEL/CentOS/Rocky/Alma vs Debian/Ubuntu) and install
#     missing prerequisites with the right package manager
#   - Download & extract the OpenSearch Dashboards tarball
#   - Set up directory layout (binaries/data) under the chosen disk path
#   - Fix exec bits on bin/ (tarballs don't always preserve them)
#   - Configure opensearch_dashboards.yml (server host/port/name, OpenSearch
#     connection, and TLS trust of the OpenSearch cluster's root CA) in a
#     duplicate-key-safe way (see set_yaml_kv_force below)
#   - Open the dashboards port on firewalld/ufw if active
#   - Create & enable systemd service
#   - Start service and verify via /api/status
#
# Safe to re-run: skips steps whose output already exists.
###############################################################################

set -Eeuo pipefail

# ============================= CONFIG ======================================
OSD_VERSION="2.19.3"
OSD_TARBALL="opensearch-dashboards-${OSD_VERSION}-linux-x64.tar.gz"
OSD_DOWNLOAD_URL="https://artifacts.opensearch.org/releases/bundle/opensearch-dashboards/${OSD_VERSION}/${OSD_TARBALL}"

# BASE_DISK_DIR, OS_HOST, OS_PORT, OS_USERNAME, OS_PASSWORD, BIND_HOST are
# prompted for interactively (or passed via flags/env - see parse_args/--help).
DEFAULT_BASE_DISK_DIR="/opt/ausiytic"
DEFAULT_OS_PORT="9200"
DEFAULT_OS_USERNAME="admin"
DASHBOARDS_PORT="5601"

# Minimum free space (in KB) we require on the base disk before installing.
# Dashboards' bundled Node process needs real headroom on first boot to
# build its optimizer/bundle cache; installing onto an already-tight disk
# is what caused this script's own sed-based config edits to previously
# combine with a duplicate-key bug into a silent, hard-to-diagnose crash.
MIN_FREE_KB=2097152   # 2 GiB

# Reuse the same service user OpenSearch itself runs as by default, since
# these are commonly installed on the same host and it simplifies giving
# Dashboards read access to OpenSearch's root CA cert. Override with
# --service-user/--service-group if Dashboards should run as someone else.
SERVICE_USER="everestdx"
SERVICE_GROUP="everestdx"
SERVICE_FILE="/etc/systemd/system/opensearch-dashboards.service"

LOG_FILE="/var/log/opensearch_dashboards_install.log"

# ============================ LOGGING ======================================
log() {
    local msg="$1"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" | tee -a "${LOG_FILE}" >&2
}

fail() {
    log "ERROR: $1"
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        fail "This script must be run as root (or with sudo)."
    fi
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
        if command -v dnf >/dev/null 2>&1; then
            PKG_MANAGER="dnf"
        else
            PKG_MANAGER="yum"
        fi
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
            fail "Cannot auto-install packages (${pkgs[*]}); unsupported/unknown package manager. Please install them manually and re-run."
            ;;
    esac
}

# ============================ INTERACTIVE INPUT ==============================
prompt_with_default() {
    local prompt_text="$1" default_val="$2" input_val
    read -rp "${prompt_text} [${default_val}]: " input_val
    echo "${input_val:-${default_val}}"
}

normalize_path() {
    local p="$1"
    p="${p%/}"
    [[ -z "${p}" ]] && p="/"
    echo "${p}"
}

validate_and_prepare_base_dir() {
    # $1 = candidate path -> echoes normalized path on success (0), or 1 on failure.
    local dir
    dir="$(normalize_path "$1")"

    if [[ "${dir}" != /* ]]; then
        log "ERROR: '${dir}' is not an absolute path. It must start with /"
        return 1
    fi

    if [[ -e "${dir}" && ! -d "${dir}" ]]; then
        log "ERROR: '${dir}' already exists and is not a directory."
        return 1
    fi

    mkdir -p "${dir}" || { log "ERROR: Could not create '${dir}'. Check the disk/mount is available and you have permission."; return 1; }

    if [[ ! -w "${dir}" ]]; then
        log "ERROR: '${dir}' exists but is not writable."
        return 1
    fi

    # Hard-fail (rather than just warn) if free space is below MIN_FREE_KB.
    # This used to be a soft warning; a low-disk install previously combined
    # with an in-place sed edit to leave a half-written, duplicate-keyed
    # opensearch_dashboards.yml that crashed the service in a confusing way.
    # Since this must run unattended/non-interactively, we refuse outright
    # instead of hoping the operator notices a warning.
    local avail_kb
    avail_kb="$(df -Pk "${dir}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "${avail_kb}" && "${avail_kb}" -lt "${MIN_FREE_KB}" ]]; then
        log "ERROR: Only $((avail_kb/1024))MB free on the filesystem backing '${dir}'. At least $((MIN_FREE_KB/1024))MB is required for a safe Dashboards install (bundle cache/optimizer on first boot need headroom). Free up space or choose a different disk, then re-run."
        return 1
    fi

    if [[ "${dir}" == "/" ]]; then
        log "WARNING: You chose the root filesystem ('/') as the install location. Dashboards data/logs will grow on the same partition as the OS."
        local root_confirm
        read -rp "Really install under '/'? [y/N]: " root_confirm
        [[ "${root_confirm}" =~ ^[Yy]$ ]] || { log "Rejected '/' - please choose a dedicated disk/mount instead."; return 1; }
    fi

    echo "${dir}"
    return 0
}

find_opensearch_root_ca() {
    # Best-effort auto-detection of the root CA generated by the companion
    # opensearch_install.sh script, so Dashboards can do real TLS validation
    # against OpenSearch instead of disabling verification. Checks the most
    # likely locations first, then falls back to a bounded filesystem search.
    local candidates=(
        "/apps/opensearch/binaries/config/root-ca.pem"
        "/opt/ausiytic/apps/opensearch/binaries/config/root-ca.pem"
        "${BASE_DISK_DIR%/}/apps/opensearch/binaries/config/root-ca.pem"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -f "${c}" ]] && { echo "${c}"; return 0; }
    done

    local found
    found="$(find / -maxdepth 8 \( -path /proc -o -path /sys -o -path /dev \) -prune -o -name root-ca.pem -path '*opensearch*' -print 2>/dev/null | head -n1)"
    [[ -n "${found}" ]] && { echo "${found}"; return 0; }

    return 1
}

step_prompt_inputs() {
    log "STEP: Auto-detecting node name/bind IP, prompting for disk path and OpenSearch connection details"

    local detected_hostname detected_ip
    detected_hostname="$(hostname -s 2>/dev/null || hostname)"
    detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -z "${detected_ip}" ]] && detected_ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"

    [[ -n "${detected_hostname}" ]] || fail "Could not auto-detect hostname. Aborting."
    [[ -n "${detected_ip}" ]] || fail "Could not auto-detect a network IP for this server. Aborting."

    NODE_HOSTNAME="${detected_hostname}"
    DETECTED_IP="${detected_ip}"
    log "Auto-detected NODE_HOSTNAME=${NODE_HOSTNAME}, DETECTED_IP=${DETECTED_IP}"

    # Base disk/directory
    if [[ -z "${BASE_DISK_DIR:-}" ]]; then
        echo ""
        echo "=========================================================="
        echo " Available mounted filesystems on this server:"
        df -hT 2>/dev/null | awk 'NR==1 || $2!="tmpfs"'
        echo "=========================================================="
        while true; do
            local candidate normalized
            candidate="$(prompt_with_default "Enter base disk/directory path where Dashboards will be installed" "${DEFAULT_BASE_DISK_DIR}")"
            if normalized="$(validate_and_prepare_base_dir "${candidate}")"; then
                BASE_DISK_DIR="${normalized}"
                break
            fi
            echo "Please enter a different path."
        done
    else
        local normalized
        log "Using pre-set BASE_DISK_DIR=${BASE_DISK_DIR} (non-interactive)"
        normalized="$(validate_and_prepare_base_dir "${BASE_DISK_DIR}")" || fail "BASE_DISK_DIR '${BASE_DISK_DIR}' is not usable."
        BASE_DISK_DIR="${normalized}"
    fi

    local base_join="${BASE_DISK_DIR%/}"
    BASE_SOFTWARE_DIR="${base_join}/softwares/opensearch-dashboards"
    APP_BASE_DIR="${base_join}/apps/opensearch-dashboards"
    BINARIES_DIR="${APP_BASE_DIR}/binaries"
    DATA_DIR="${APP_BASE_DIR}/data"
    CONFIG_DIR="${BINARIES_DIR}/config"

    # OpenSearch connection details - default host to this server's own IP,
    # since Dashboards is very commonly colocated with a single-node
    # OpenSearch install (as in this environment).
    if [[ -z "${OS_HOST:-}" ]]; then
        OS_HOST="$(prompt_with_default "Enter OpenSearch host/IP to connect to" "${DETECTED_IP}")"
    fi
    if [[ -z "${OS_PORT:-}" ]]; then
        OS_PORT="$(prompt_with_default "Enter OpenSearch HTTP port" "${DEFAULT_OS_PORT}")"
    fi
    if [[ -z "${OS_USERNAME:-}" ]]; then
        OS_USERNAME="$(prompt_with_default "Enter OpenSearch admin username" "${DEFAULT_OS_USERNAME}")"
    fi
    if [[ -z "${OS_PASSWORD:-}" ]]; then
        read -rsp "Enter OpenSearch password for user '${OS_USERNAME}': " OS_PASSWORD
        echo ""
        [[ -n "${OS_PASSWORD}" ]] || fail "OpenSearch password cannot be empty."
    fi

    if [[ -z "${BIND_HOST:-}" ]]; then
        BIND_HOST="$(prompt_with_default "Enter address for Dashboards to bind/listen on (0.0.0.0 = all interfaces)" "0.0.0.0")"
    fi

    echo ""
    echo "=========================================================="
    echo " Node hostname       : ${NODE_HOSTNAME}"
    echo " Base disk directory : ${BASE_DISK_DIR}"
    echo " OpenSearch endpoint : https://${OS_HOST}:${OS_PORT}"
    echo " OpenSearch user     : ${OS_USERNAME}"
    echo " Dashboards bind     : ${BIND_HOST}:${DASHBOARDS_PORT}"
    echo "=========================================================="
    read -rp "Confirm and continue? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    [[ "${confirm}" =~ ^[Yy]$ ]] || fail "Aborted by user at input confirmation step."
}

# ============================ STEP FUNCTIONS ================================

step_prereqs() {
    log "STEP: Checking prerequisites (wget, tar, curl, systemctl) for OS family '${OS_FAMILY}'"

    local missing=()
    for cmd in wget tar curl systemctl awk; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        log "Missing commands: ${missing[*]}. Attempting to install via ${PKG_MANAGER:-<none detected>}."
        local pkgs=()
        for c in "${missing[@]}"; do
            case "${c}" in
                systemctl) pkgs+=("systemd") ;;
                awk) pkgs+=("gawk") ;;
                *) pkgs+=("${c}") ;;
            esac
        done
        install_packages "${pkgs[@]}"
        for cmd in "${missing[@]}"; do
            command -v "${cmd}" >/dev/null 2>&1 || fail "'${cmd}' still not available after install attempt. Please install it manually."
        done
    fi

    if ! getent group "${SERVICE_GROUP}" >/dev/null 2>&1; then
        log "Service group '${SERVICE_GROUP}' does not exist. Creating it."
        groupadd "${SERVICE_GROUP}" || fail "Failed to create group ${SERVICE_GROUP}"
    fi

    if ! id "${SERVICE_USER}" &>/dev/null; then
        log "Service user '${SERVICE_USER}' does not exist. Creating it."
        useradd -M -s "${NOLOGIN_SHELL}" -g "${SERVICE_GROUP}" "${SERVICE_USER}" || fail "Failed to create user ${SERVICE_USER}"
    fi

    local mem_total_mb
    mem_total_mb="$(free -m | awk '/^Mem:/{print $2}')"
    if [[ -n "${mem_total_mb}" && "${mem_total_mb}" -lt 1024 ]]; then
        log "WARNING: Total system memory is ${mem_total_mb}MB. Dashboards' bundled Node process may struggle below ~1GB free."
    fi
}

step_preflight_check_opensearch() {
    log "STEP: Verifying OpenSearch at https://${OS_HOST}:${OS_PORT} is reachable with the given credentials, before installing anything"

    local health http_code
    health="$(curl -sk -o /tmp/.osd_preflight_body -w '%{http_code}' -u "${OS_USERNAME}:${OS_PASSWORD}" "https://${OS_HOST}:${OS_PORT}/_cluster/health" --max-time 10 || true)"
    http_code="${health}"

    if [[ "${http_code}" == "200" ]]; then
        log "OpenSearch reachable and credentials valid. Cluster health: $(cat /tmp/.osd_preflight_body)"
    elif [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
        fail "OpenSearch at https://${OS_HOST}:${OS_PORT} rejected the given credentials (HTTP ${http_code}). Check OS_USERNAME/OS_PASSWORD and try again."
    else
        fail "Could not reach OpenSearch at https://${OS_HOST}:${OS_PORT} (HTTP code: '${http_code:-none}'). Check the host/port, that OpenSearch is running, and that the security group/firewall allows this connection. Aborting before making any changes."
    fi
    rm -f /tmp/.osd_preflight_body
}

step_download_extract() {
    log "STEP: Download & extract OpenSearch Dashboards ${OSD_VERSION}"
    mkdir -p "${BASE_SOFTWARE_DIR}"
    cd "${BASE_SOFTWARE_DIR}"

    local marker="${BINARIES_DIR}/bin/opensearch-dashboards"
    if [[ -f "${marker}" ]]; then
        log "OpenSearch Dashboards already appears installed at ${BINARIES_DIR}, skipping download/extract."
        return 0
    fi

    if [[ -d "${BINARIES_DIR}" ]]; then
        log "WARNING: ${BINARIES_DIR} exists but looks incomplete (missing ${marker}). Removing it and re-extracting cleanly."
        rm -rf "${BINARIES_DIR}"
    fi

    if [[ ! -f "${OSD_TARBALL}" ]]; then
        log "Downloading ${OSD_DOWNLOAD_URL}"
        wget -q --show-progress "${OSD_DOWNLOAD_URL}" -O "${OSD_TARBALL}" || fail "Download failed"
    else
        log "Tarball already present, skipping download."
    fi

    log "Extracting ${OSD_TARBALL}"
    tar -xzf "${OSD_TARBALL}" || fail "Extraction failed"
}

step_setup_dirs() {
    log "STEP: Creating app directories"
    mkdir -p "${BINARIES_DIR}" "${DATA_DIR}"

    local extracted_dir="${BASE_SOFTWARE_DIR}/opensearch-dashboards-${OSD_VERSION}"
    if [[ -d "${extracted_dir}" ]]; then
        log "Moving extracted files to ${BINARIES_DIR}"
        shopt -s dotglob nullglob
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
    # Same rationale as the OpenSearch installer: tarballs don't always
    # preserve exec bits depending on how they were built/transferred, and
    # a non-executable bin/opensearch-dashboards makes systemd's ExecStart
    # fail with a confusing "permission denied" rather than an obvious cause.
    log "STEP: Ensuring Dashboards binaries are executable"

    if [[ -d "${BINARIES_DIR}/bin" ]]; then
        find "${BINARIES_DIR}/bin" -maxdepth 1 -type f -exec chmod +x {} \;
    fi
    if [[ -d "${BINARIES_DIR}/node" ]]; then
        find "${BINARIES_DIR}/node/bin" -maxdepth 1 -type f -exec chmod +x {} \; 2>/dev/null || true
    fi
}

step_wire_opensearch_trust() {
    log "STEP: Configuring TLS trust of the OpenSearch cluster's certificate"

    local ca_dest="${CONFIG_DIR}/opensearch-root-ca.pem"
    local ca_src

    if [[ -n "${OPENSEARCH_ROOT_CA:-}" && -f "${OPENSEARCH_ROOT_CA}" ]]; then
        ca_src="${OPENSEARCH_ROOT_CA}"
    else
        ca_src="$(find_opensearch_root_ca || true)"
    fi

    if [[ -n "${ca_src}" && -f "${ca_src}" ]]; then
        log "Found OpenSearch root CA at ${ca_src}; copying into Dashboards config for TLS trust"
        cp -f "${ca_src}" "${ca_dest}"
        chmod 644 "${ca_dest}"
        SSL_VERIFICATION_MODE="full"
        SSL_CA_PATH="${ca_dest}"
    else
        log "WARNING: Could not locate the OpenSearch root CA automatically (checked common paths and did a bounded filesystem search). Falling back to opensearch.ssl.verificationMode: none - Dashboards will connect over TLS but will NOT verify OpenSearch's certificate. Pass --opensearch-root-ca /path/to/root-ca.pem to fix this properly."
        SSL_VERIFICATION_MODE="none"
        SSL_CA_PATH=""
    fi
}

step_configure_yml() {
    log "STEP: Configuring opensearch_dashboards.yml"
    local yml="${CONFIG_DIR}/opensearch_dashboards.yml"
    [[ -f "${yml}" ]] || fail "opensearch_dashboards.yml not found at ${yml}"

    # Keep exactly one pristine backup of the file as shipped, so re-runs
    # are always rewriting from the same known-good starting point instead
    # of layering edits on top of a file this script (or a prior failed
    # run) already modified.
    if [[ ! -f "${yml}.orig" ]]; then
        cp "${yml}" "${yml}.orig"
    else
        cp "${yml}.orig" "${yml}"
    fi

    # -------------------------------------------------------------------
    # set_yaml_kv_force: idempotent, DUPLICATE-SAFE key setter.
    #
    # The stock opensearch_dashboards.yml ships some keys more than once
    # in the file (e.g. once as an early commented example, again later
    # near the Security plugin section, sometimes both commented). The
    # previous version of this function used `sed -i "s|^#?key:.*|...|"`,
    # which rewrites EVERY matching line, not just one - so if a key
    # appeared twice (commented or not), both lines got uncommented and
    # set, producing two active lines for the same key. js-yaml (which
    # OpenSearch Dashboards/Node use to load this file) throws a hard
    # YAMLException on duplicate mapping keys and the service crash-loops
    # with no config change needed to trigger it - a bad, hard-to-diagnose
    # failure mode for an unattended install.
    #
    # Fix: for every key we manage, first DELETE every line in the file
    # that matches that key (commented or not, any leading whitespace),
    # then APPEND exactly one fresh, uncommented line at the end. This
    # guarantees a single active occurrence of the key regardless of how
    # many times the shipped template repeats it.
    # -------------------------------------------------------------------
    set_yaml_kv_force() {
        local key="$1" val="$2"
        local escaped_key
        # Escape regex metacharacters that can appear in our key names ('.').
        escaped_key="$(printf '%s' "${key}" | sed -E 's/[.]/\\./g')"
        # Delete every existing line for this key (commented or not).
        sed -i -E "/^[[:space:]]*#?[[:space:]]*${escaped_key}:/d" "${yml}"
        # Append exactly one fresh, active line.
        echo "${key}: ${val}" >> "${yml}"
    }

    set_yaml_kv_force "server.port" "${DASHBOARDS_PORT}"
    set_yaml_kv_force "server.host" "\"${BIND_HOST}\""
    set_yaml_kv_force "server.name" "${NODE_HOSTNAME}"
    set_yaml_kv_force "opensearch.hosts" "[\"https://${OS_HOST}:${OS_PORT}\"]"
    set_yaml_kv_force "opensearch.username" "${OS_USERNAME}"
    set_yaml_kv_force "opensearch.password" "${OS_PASSWORD}"
    set_yaml_kv_force "opensearch.ssl.verificationMode" "${SSL_VERIFICATION_MODE}"
    set_yaml_kv_force "opensearch.requestHeadersWhitelist" "[authorization, securitytenant]"

    if [[ -n "${SSL_CA_PATH}" ]]; then
        set_yaml_kv_force "opensearch.ssl.certificateAuthorities" "[\"${SSL_CA_PATH}\"]"
    fi

    # Security plugin settings - also written via the same duplicate-safe
    # setter (previously left to whatever the template happened to ship,
    # which is exactly what produced the duplicates in the first place).
    set_yaml_kv_force "opensearch_security.multitenancy.enabled" "true"
    set_yaml_kv_force "opensearch_security.multitenancy.tenants.preferred" "[Private, Global]"
    set_yaml_kv_force "opensearch_security.readonly_mode.roles" "[kibana_read_only]"
    set_yaml_kv_force "opensearch_security.cookie.secure" "false"

    # Verify the critical keys actually landed active (uncommented).
    local missing=()
    for key in "server.port" "server.host" "opensearch.hosts" "opensearch.username" "opensearch.password"; do
        grep -qE "^${key//./\\.}:" "${yml}" || missing+=("${key}")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        fail "Failed to activate config in opensearch_dashboards.yml: ${missing[*]}. Check ${yml} manually."
    fi

    # Hard duplicate-key guard: fail loudly and refuse to start the service
    # rather than let a subtle future regression reach Node's YAML loader.
    local dupes
    dupes="$(grep -oE '^[A-Za-z0-9_.]+:' "${yml}" | sort | uniq -d || true)"
    if [[ -n "${dupes}" ]]; then
        fail "Duplicate keys detected in ${yml} after configuration: $(echo "${dupes}" | tr '\n' ' '). Refusing to start Dashboards with a config that would crash on load. Inspect ${yml} manually."
    fi

    # Belt-and-suspenders: the file itself must parse as valid YAML with a
    # strict-ish check before we ever hand it to the service. python3/pyyaml
    # is present on virtually every modern distro; skip the check gracefully
    # if it isn't, rather than failing the whole install over tooling.
    if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
        python3 -c "
import sys, yaml
try:
    with open('${yml}') as f:
        yaml.safe_load(f)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" || fail "opensearch_dashboards.yml failed YAML validation after configuration. See error above and inspect ${yml} manually."
    fi

    chmod 640 "${yml}"
    log "opensearch_dashboards.yml configured, de-duplicated, and verified."
}

step_fix_ownership() {
    log "STEP: Fixing ownership of app directories"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_BASE_DIR}"
}

step_firewall() {
    log "STEP: Opening Dashboards port ${DASHBOARDS_PORT} on the active firewall (if any)"

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${DASHBOARDS_PORT}/tcp" >/dev/null 2>&1 \
            && firewall-cmd --reload >/dev/null 2>&1 \
            && log "firewalld: opened ${DASHBOARDS_PORT}/tcp" \
            || log "WARNING: firewalld is active but the rule could not be added. Add it manually: firewall-cmd --permanent --add-port=${DASHBOARDS_PORT}/tcp"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${DASHBOARDS_PORT}/tcp" >/dev/null 2>&1 \
            && log "ufw: opened ${DASHBOARDS_PORT}/tcp" \
            || log "WARNING: ufw is active but the rule could not be added. Add it manually: ufw allow ${DASHBOARDS_PORT}/tcp"
    else
        log "No active supported firewall (firewalld/ufw) detected, or ports already unrestricted. Skipping."
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

    # Fail fast and loudly if the service is already crash-looping rather
    # than silently proceeding to a final-verify step that just times out
    # after 90s with a vague warning. journalctl's tail is included in the
    # failure message so the real Node/YAML error is visible immediately
    # in the install log, without a manual follow-up command.
    if ! systemctl is-active --quiet opensearch-dashboards; then
        log "ERROR: opensearch-dashboards is not active after startup. Recent logs:"
        journalctl -u opensearch-dashboards -n 60 --no-pager | tee -a "${LOG_FILE}" >&2 || true
        fail "opensearch-dashboards failed to start. See the log lines above and ${LOG_FILE}."
    fi
}

step_final_verify() {
    log "STEP: Verifying Dashboards is responding on port ${DASHBOARDS_PORT}"
    command -v curl >/dev/null 2>&1 || return 0

    local check_host="${BIND_HOST}"
    [[ "${check_host}" == "0.0.0.0" ]] && check_host="127.0.0.1"

    local status waited=0 timeout_s=90
    while (( waited < timeout_s )); do
        if ! systemctl is-active --quiet opensearch-dashboards; then
            log "ERROR: opensearch-dashboards stopped being active while waiting for /api/status. Recent logs:"
            journalctl -u opensearch-dashboards -n 60 --no-pager | tee -a "${LOG_FILE}" >&2 || true
            fail "opensearch-dashboards crashed during startup verification. See log lines above and ${LOG_FILE}."
        fi
        status="$(curl -s "http://${check_host}:${DASHBOARDS_PORT}/api/status" --max-time 10 || true)"
        echo "${status}" | grep -q '"state"' && break
        sleep 5
        waited=$((waited + 5))
    done

    echo "${status}" | tee -a "${LOG_FILE}"

    if echo "${status}" | grep -q '"state":"green"'; then
        log "Dashboards responded successfully and reports state: green."
    elif echo "${status}" | grep -q '"state"'; then
        log "WARNING: Dashboards is responding but not reporting 'green' state. Check the response above."
    else
        log "WARNING: Dashboards did not respond as expected after ${timeout_s}s. Check: journalctl -u opensearch-dashboards -f"
    fi
}

# ============================ CLI ARG PARSING ================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-dir)            BASE_DISK_DIR="$2"; shift 2 ;;
            --opensearch-host)     OS_HOST="$2"; shift 2 ;;
            --opensearch-port)     OS_PORT="$2"; shift 2 ;;
            --opensearch-user)     OS_USERNAME="$2"; shift 2 ;;
            --opensearch-password) OS_PASSWORD="$2"; shift 2 ;;
            --opensearch-root-ca)  OPENSEARCH_ROOT_CA="$2"; shift 2 ;;
            --bind-host)           BIND_HOST="$2"; shift 2 ;;
            --service-user)        SERVICE_USER="$2"; shift 2 ;;
            --service-group)       SERVICE_GROUP="$2"; shift 2 ;;
            -h|--help)
                cat <<EOF
Usage: sudo $0 [options]

  --base-dir PATH              Base directory/disk for the install (e.g. /opt/ausiytic).
  --opensearch-host HOST       OpenSearch host/IP to connect to.
  --opensearch-port PORT       OpenSearch HTTP port (default: 9200).
  --opensearch-user USER       OpenSearch admin username (default: admin).
  --opensearch-password PASS   OpenSearch admin password. Prompted securely if omitted.
  --opensearch-root-ca PATH    Path to OpenSearch's root-ca.pem for TLS trust.
                                Auto-detected from common paths if omitted.
  --bind-host HOST             Address for Dashboards to listen on (default: 0.0.0.0).
  --service-user USER          Linux user to run the service as (default: everestdx).
  --service-group GROUP        Linux group to run the service as (default: everestdx).

Any option not passed is prompted for interactively (except --opensearch-root-ca,
which just falls back to skipping certificate verification with a warning).

For a fully unattended/automated run, pass all of: --base-dir, --opensearch-host,
--opensearch-port, --opensearch-user, --opensearch-password, --bind-host.
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

    log "===== OpenSearch Dashboards installation complete ====="
    log "Base disk dir : ${BASE_DISK_DIR}"
    log "Bind address  : ${BIND_HOST}:${DASHBOARDS_PORT}"
    log "OpenSearch    : https://${OS_HOST}:${OS_PORT} (user: ${OS_USERNAME})"
    log "Check status  : systemctl status opensearch-dashboards"
    log "Tail logs     : journalctl -u opensearch-dashboards -f"
    log "Access UI     : http://${NODE_HOSTNAME}:${DASHBOARDS_PORT}  (or http://${DETECTED_IP}:${DASHBOARDS_PORT})"
}

main "$@"

