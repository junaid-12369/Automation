#!/usr/bin/env bash
###############################################################################
# opensearch_install.sh
#
# Fully automated OpenSearch install:
#   - Prompt for base disk/directory, cluster name (node name & IP auto-detected)
#   - Detect OS family (RHEL/CentOS/Rocky/Alma vs Debian/Ubuntu) and install
#     missing prerequisites with the right package manager
#   - Download & extract OpenSearch tarball
#   - Set up directory layout (binaries/data/logs) under the chosen disk path
#   - Configure opensearch.yml
#   - Generate Root CA / Admin / Node certificates (node cert includes BOTH
#     the hostname and the detected IP address as Subject Alternative Names,
#     so strict TLS clients connecting via IP - like OpenSearch Dashboards -
#     don't fail hostname/IP verification)
#   - Wire certs into opensearch.yml
#   - Open the HTTP port on firewalld/ufw if active
#   - Apply SELinux context/port labeling on RHEL-family systems if enforcing
#   - Create & enable systemd service
#   - Start service and verify
#
# Safe to re-run: skips steps whose output already exists.
###############################################################################

set -Eeuo pipefail

# ============================= CONFIG ======================================
OS_VERSION="2.19.3"
OS_TARBALL="opensearch-${OS_VERSION}-linux-x64.tar.gz"
OS_DOWNLOAD_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OS_VERSION}/${OS_TARBALL}"

# BASE_DISK_DIR is prompted for interactively (or passed via --base-dir).
# Everything below is derived from it once known.
DEFAULT_BASE_DISK_DIR="/opt/ausiytic"

HTTP_PORT="9200"
DISCOVERY_TYPE="single-node"
# NODE_NAME and NETWORK_HOST are auto-detected from the server in step_prompt_inputs().
# CLUSTER_NAME and BASE_DISK_DIR are prompted for interactively (or passed via flags/env).

# Change this or export OPENSEARCH_INITIAL_ADMIN_PASSWORD before running to override
OPENSEARCH_INITIAL_ADMIN_PASSWORD="${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-EdxiP@ssword!}"

SERVICE_USER="everestdx"
SERVICE_GROUP="everestdx"
SERVICE_FILE="/etc/systemd/system/opensearch.service"

# Cert subject fields
CERT_COUNTRY="IN"
CERT_STATE="Telangana"
CERT_LOCALITY="Hyderabad"
CERT_ORG="EDX"
CERT_OU="EDXUnit"
CERT_DAYS=730

LOG_FILE="/var/log/opensearch_install.log"

# ============================ LOGGING ======================================
log() {
    local msg="$1"
    # Written to stderr (not stdout) so that functions which return a value
    # via command substitution (e.g. validate_and_prepare_base_dir) never
    # get log lines mixed into their captured output.
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
# Detects the OS family so we know which package manager and nologin shell
# path to use. Works for RHEL/CentOS/Rocky/AlmaLinux/Fedora and
# Debian/Ubuntu, and degrades gracefully (warns, doesn't hard-fail) on
# anything else since the rest of the script only relies on POSIX tools.

OS_FAMILY=""     # "rhel" or "debian" or "unknown"
PKG_MANAGER=""    # dnf, yum, or apt-get
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
        log "WARNING: Unrecognized OS ID='${id}' ID_LIKE='${id_like}'. Treating as generic Linux; package auto-install will be skipped if package manager is unknown."
        OS_FAMILY="unknown"
    fi

    log "Detected OS family: ${OS_FAMILY} (${PRETTY_NAME:-unknown}), package manager: ${PKG_MANAGER:-none}, nologin shell: ${NOLOGIN_SHELL}"
}

install_packages() {
    # $@ = list of package names (already mapped to the right names for this OS)
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
# Prompts for the base disk/directory and cluster name since these vary
# per server. Node name and network host are auto-detected. Press Enter
# to accept any offered default.

is_valid_ip() {
    local ip="$1"
    local IFS='.'
    read -ra octets <<< "${ip}"
    [[ "${#octets[@]}" -eq 4 ]] || return 1
    for o in "${octets[@]}"; do
        [[ "${o}" =~ ^[0-9]+$ ]] || return 1
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

prompt_with_default() {
    # $1 = prompt text, $2 = default value  -> echoes chosen value
    local prompt_text="$1"
    local default_val="$2"
    local input_val
    read -rp "${prompt_text} [${default_val}]: " input_val
    echo "${input_val:-${default_val}}"
}

normalize_path() {
    # Strips trailing slash(es) so path joins never produce "//".
    # "/" itself is preserved as "/" rather than becoming empty.
    local p="$1"
    p="${p%/}"
    [[ -z "${p}" ]] && p="/"
    echo "${p}"
}

validate_and_prepare_base_dir() {
    # $1 = candidate path -> echoes the normalized path on success (return 0),
    # or returns 1 on failure. Caller must capture stdout to get the value.
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

    if [[ "${dir}" == "/" ]]; then
        log "WARNING: You chose the root filesystem ('/') as the install location. OpenSearch data/logs will grow on the same partition as the OS, which can fill it up and take the whole server down, not just OpenSearch."
        local root_confirm
        read -rp "Really install under '/'? [y/N]: " root_confirm
        [[ "${root_confirm}" =~ ^[Yy]$ ]] || { log "Rejected '/' - please choose a dedicated disk/mount instead."; return 1; }
    fi

    echo "${dir}"
    return 0
}

step_prompt_inputs() {
    log "STEP: Auto-detecting node name and network host, prompting for disk path and cluster name"

    local detected_hostname detected_ip
    detected_hostname="$(hostname -s 2>/dev/null || hostname)"
    detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -z "${detected_ip}" ]] && detected_ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"

    [[ -n "${detected_hostname}" ]] || fail "Could not auto-detect hostname. Aborting."
    [[ -n "${detected_ip}" ]] && is_valid_ip "${detected_ip}" || fail "Could not auto-detect a valid IPv4 address for this server. Aborting."

    NODE_NAME="${detected_hostname}"
    NETWORK_HOST="${detected_ip}"

    log "Auto-detected NODE_NAME=${NODE_NAME}, NETWORK_HOST=${NETWORK_HOST}"

    # Base disk/directory: skip prompt if already provided via --base-dir / env var
    if [[ -z "${BASE_DISK_DIR:-}" ]]; then
        echo ""
        echo "=========================================================="
        echo " Available mounted filesystems on this server:"
        df -hT 2>/dev/null | awk 'NR==1 || $2!="tmpfs"'
        echo "=========================================================="
        while true; do
            local candidate normalized
            candidate="$(prompt_with_default "Enter base disk/directory path where OpenSearch will be installed" "${DEFAULT_BASE_DISK_DIR}")"
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

    # Derive all dependent paths now that the disk is known.
    # Strip any trailing slash from BASE_DISK_DIR before joining so that
    # choosing "/" doesn't produce "//softwares/opensearch".
    local base_join="${BASE_DISK_DIR%/}"
    BASE_SOFTWARE_DIR="${base_join}/softwares/opensearch"
    APP_BASE_DIR="${base_join}/apps/opensearch"
    BINARIES_DIR="${APP_BASE_DIR}/binaries"
    DATA_DIR="${APP_BASE_DIR}/data"
    LOGS_DIR="${APP_BASE_DIR}/logs"
    CONFIG_DIR="${BINARIES_DIR}/config"

    # Warn if free space on the chosen disk looks low (OpenSearch + JVM + data)
    local avail_kb
    avail_kb="$(df -Pk "${BASE_DISK_DIR}" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "${avail_kb}" && "${avail_kb}" -lt 3145728 ]]; then
        log "WARNING: Only $((avail_kb/1024))MB free on the filesystem backing ${BASE_DISK_DIR}. OpenSearch + data may need several GB; consider a larger disk."
    fi

    # Cluster name: skip prompt if already provided via --cluster-name / env var
    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        echo ""
        echo "=========================================================="
        echo " Detected node name : ${NODE_NAME}"
        echo " Detected IP address: ${NETWORK_HOST}"
        echo " Base disk directory: ${BASE_DISK_DIR}"
        echo "=========================================================="
        CLUSTER_NAME="$(prompt_with_default "Enter cluster name" "opensearch")"
    else
        log "Using pre-set CLUSTER_NAME=${CLUSTER_NAME} (non-interactive)"
    fi

    echo ""
    log "Final config -> CLUSTER_NAME=${CLUSTER_NAME}, NODE_NAME=${NODE_NAME}, NETWORK_HOST=${NETWORK_HOST}, BASE_DISK_DIR=${BASE_DISK_DIR}"

    read -rp "Confirm and continue? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        fail "Aborted by user at input confirmation step."
    fi
}

# ============================ STEP FUNCTIONS ================================

step_prereqs() {
    log "STEP: Checking prerequisites (wget, tar, openssl, systemctl) for OS family '${OS_FAMILY}'"

    local missing=()
    for cmd in wget tar openssl systemctl curl sudo awk; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        log "Missing commands: ${missing[*]}. Attempting to install via ${PKG_MANAGER:-<none detected>}."
        local pkgs=()
        case "${OS_FAMILY}" in
            rhel)
                for c in "${missing[@]}"; do
                    case "${c}" in
                        systemctl) pkgs+=("systemd") ;;
                        awk) pkgs+=("gawk") ;;
                        *) pkgs+=("${c}") ;;
                    esac
                done
                ;;
            debian)
                for c in "${missing[@]}"; do
                    case "${c}" in
                        systemctl) pkgs+=("systemd") ;;
                        awk) pkgs+=("gawk") ;;
                        *) pkgs+=("${c}") ;;
                    esac
                done
                ;;
            *)
                fail "Missing required commands (${missing[*]}) and OS package manager could not be determined. Install them manually and re-run."
                ;;
        esac
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
}

step_system_tuning() {
    log "STEP: Applying OS-level tuning required for OpenSearch bootstrap checks"

    # vm.max_map_count - OpenSearch/Elasticsearch requires >= 262144.
    # Fresh installs on both RHEL-family and Debian-family kernels commonly
    # ship with 65530, which fails the bootstrap check as soon as
    # network.host is a real IP.
    local current_map_count
    current_map_count="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
    if [[ "${current_map_count}" -lt 262144 ]]; then
        log "vm.max_map_count is ${current_map_count}, raising to 262144"
        sysctl -w vm.max_map_count=262144 >/dev/null

        if grep -q "^vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
            sed -i "s/^vm.max_map_count.*/vm.max_map_count=262144/" /etc/sysctl.conf
        else
            echo "vm.max_map_count=262144" >> /etc/sysctl.conf
        fi
    else
        log "vm.max_map_count already ${current_map_count}, OK"
    fi

    # File descriptor / process limits for the service user via limits.d
    # (belt-and-suspenders alongside the systemd unit's Limit* directives).
    local limits_file="/etc/security/limits.d/opensearch.conf"
    cat > "${limits_file}" <<EOF
${SERVICE_USER} soft nofile 65535
${SERVICE_USER} hard nofile 65535
${SERVICE_USER} soft nproc 4096
${SERVICE_USER} hard nproc 4096
${SERVICE_USER} soft memlock unlimited
${SERVICE_USER} hard memlock unlimited
EOF
    log "Wrote ${limits_file} for ${SERVICE_USER}"

    # Warn (don't fail) on low memory - OpenSearch default heap wants ~1-2GB+ free.
    local mem_total_mb
    mem_total_mb="$(free -m | awk '/^Mem:/{print $2}')"
    if [[ -n "${mem_total_mb}" && "${mem_total_mb}" -lt 2048 ]]; then
        log "WARNING: Total system memory is ${mem_total_mb}MB. OpenSearch's default JVM heap may not fit. Consider tuning ${CONFIG_DIR}/jvm.options.d or the -Xms/-Xmx values if the service fails with an OOM-related error."
    fi
}

step_firewall() {
    log "STEP: Opening HTTP port ${HTTP_PORT} on the active firewall (if any)"

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp" >/dev/null 2>&1 \
            && firewall-cmd --reload >/dev/null 2>&1 \
            && log "firewalld: opened ${HTTP_PORT}/tcp" \
            || log "WARNING: firewalld is active but the rule could not be added. Add it manually: firewall-cmd --permanent --add-port=${HTTP_PORT}/tcp"
    elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${HTTP_PORT}/tcp" >/dev/null 2>&1 \
            && log "ufw: opened ${HTTP_PORT}/tcp" \
            || log "WARNING: ufw is active but the rule could not be added. Add it manually: ufw allow ${HTTP_PORT}/tcp"
    else
        log "No active supported firewall (firewalld/ufw) detected, or ports already unrestricted. Skipping."
    fi
}

step_selinux() {
    # Only relevant on RHEL-family systems; no-op elsewhere.
    [[ "${OS_FAMILY}" == "rhel" ]] || return 0
    command -v getenforce >/dev/null 2>&1 || return 0

    local mode
    mode="$(getenforce 2>/dev/null || echo Disabled)"
    log "STEP: SELinux is '${mode}' - applying context/port labeling if needed"

    if [[ "${mode}" == "Enforcing" || "${mode}" == "Permissive" ]]; then
        if ! command -v semanage >/dev/null 2>&1; then
            log "semanage not found; installing policycoreutils-python-utils"
            install_packages "policycoreutils-python-utils" || log "WARNING: could not install semanage tools; you may need to run 'semanage port -a -t http_port_t -p tcp ${HTTP_PORT}' manually."
        fi

        if command -v semanage >/dev/null 2>&1; then
            if semanage port -l 2>/dev/null | grep -qw "${HTTP_PORT}"; then
                log "Port ${HTTP_PORT} already has an SELinux port context."
            else
                semanage port -a -t http_port_t -p tcp "${HTTP_PORT}" 2>/dev/null \
                    || semanage port -m -t http_port_t -p tcp "${HTTP_PORT}" 2>/dev/null \
                    || log "WARNING: could not label port ${HTTP_PORT} for SELinux. If the service fails to bind, run: semanage port -a -t http_port_t -p tcp ${HTTP_PORT}"
            fi
        fi

        if command -v restorecon >/dev/null 2>&1; then
            restorecon -R "${APP_BASE_DIR}" 2>/dev/null || true
        fi
    fi
}

step_download_extract() {
    log "STEP: Download & extract OpenSearch ${OS_VERSION}"
    mkdir -p "${BASE_SOFTWARE_DIR}"
    cd "${BASE_SOFTWARE_DIR}"

    # NOTE: We check for more than just "bin/" existing here. A prior run
    # that was interrupted mid-extraction (disk full, killed, etc.) can
    # leave bin/ present but the rest of the tree incomplete, which used to
    # cause this step to be silently skipped on every re-run forever. We
    # also verify a known plugin script exists AND is executable, since a
    # tarball that extracted fine but lost its exec bits (e.g. via certain
    # transfer/copy tools) should not be treated as "good" either - it's
    # cheap to just re-run step_fix_extracted_permissions in that case
    # rather than re-downloading, so that check lives separately below.
    local marker="${BINARIES_DIR}/plugins/opensearch-security/tools/hash.sh"
    if [[ -d "${BINARIES_DIR}/bin" && -f "${marker}" ]]; then
        log "OpenSearch already appears installed at ${BINARIES_DIR}, skipping download/extract."
        return 0
    fi

    if [[ -d "${BINARIES_DIR}" ]]; then
        log "WARNING: ${BINARIES_DIR} exists but looks incomplete (missing ${marker}). Removing it and re-extracting cleanly."
        rm -rf "${BINARIES_DIR}"
    fi

    if [[ ! -f "${OS_TARBALL}" ]]; then
        log "Downloading ${OS_DOWNLOAD_URL}"
        wget -q --show-progress "${OS_DOWNLOAD_URL}" -O "${OS_TARBALL}" || fail "Download failed"
    else
        log "Tarball already present, skipping download."
    fi

    log "Extracting ${OS_TARBALL}"
    tar -xzf "${OS_TARBALL}" || fail "Extraction failed"
}

step_setup_dirs() {
    log "STEP: Creating app directories"
    mkdir -p "${BINARIES_DIR}" "${DATA_DIR}" "${LOGS_DIR}"

    local extracted_dir="${BASE_SOFTWARE_DIR}/opensearch-${OS_VERSION}"
    if [[ -d "${extracted_dir}" ]]; then
        log "Moving extracted files to ${BINARIES_DIR}"
        # Move contents (including hidden files) without clobbering if already moved
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
    # Tarballs don't always preserve exec bits depending on how they were
    # built/transferred/uploaded. If bin/* or any plugin tool script isn't
    # executable, systemd's ExecStart and later securityadmin.sh/hash.sh
    # calls fail with confusing "not found/executable" errors even though
    # the files are right there. Always (re)apply exec bits here so this
    # class of failure can't happen, whether this is a fresh extract or an
    # already-existing install being re-run.
    log "STEP: Ensuring OpenSearch binaries and plugin tool scripts are executable"

    if [[ -d "${BINARIES_DIR}/bin" ]]; then
        find "${BINARIES_DIR}/bin" -maxdepth 1 -type f -exec chmod +x {} \;
    fi

    # NOTE: deliberately NOT using a nested `find -exec sh -c '... {} ...' {} +`
    # here. GNU find's batching form (-exec ... +) only tolerates a single
    # "{}" token across all its arguments - even one embedded inside a quoted
    # sh -c script counts - so combining two finds that way fails with
    # "Only one instance of {} is supported with -exec ... +". A plain loop
    # avoids the problem entirely and is just as fast for this small tree.
    if [[ -d "${BINARIES_DIR}/plugins" ]]; then
        while IFS= read -r -d '' dir; do
            chmod +x "${dir}"/*.sh 2>/dev/null || true
            chmod +x "${dir}"/*.bat 2>/dev/null || true
        done < <(find "${BINARIES_DIR}/plugins" -type d -name tools -print0)
    fi

    if [[ -d "${BINARIES_DIR}/jdk/bin" ]]; then
        find "${BINARIES_DIR}/jdk/bin" -maxdepth 1 -type f -exec chmod +x {} \;
    fi
}

step_configure_yml() {
    log "STEP: Configuring opensearch.yml"
    local yml="${CONFIG_DIR}/opensearch.yml"
    [[ -f "${yml}" ]] || fail "opensearch.yml not found at ${yml}"

    cp -n "${yml}" "${yml}.orig" || true

    set_yaml_kv() {
        local key="$1" val="$2"
        if grep -qE "^${key}:" "${yml}"; then
            sed -i "s|^${key}:.*|${key}: ${val}|" "${yml}"
        else
            echo "${key}: ${val}" >> "${yml}"
        fi
    }

    set_yaml_kv "cluster.name" "${CLUSTER_NAME}"
    set_yaml_kv "node.name" "${NODE_NAME}"
    set_yaml_kv "path.data" "${DATA_DIR}"
    set_yaml_kv "path.logs" "${LOGS_DIR}"
    set_yaml_kv "network.host" "${NETWORK_HOST}"
    set_yaml_kv "http.port" "${HTTP_PORT}"
    set_yaml_kv "discovery.type" "${DISCOVERY_TYPE}"

    log "opensearch.yml base config applied."
}

step_wait_for_https_port() {
    local host="$1" port="$2" timeout_s="${3:-90}"
    local waited=0
    while (( waited < timeout_s )); do
        curl -sk -o /dev/null "https://${host}:${port}" 2>/dev/null && return 0
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

step_wait_for_tcp_port() {
    local host="$1" port="$2" timeout_s="${3:-60}"
    local waited=0
    while (( waited < timeout_s )); do
        if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
            exec 3>&- 3<&- 2>/dev/null
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

step_bootstrap_security() {
    log "STEP: Setting admin password and initializing the OpenSearch Security index"
    # opensearch-tar-install.sh is intentionally NOT used here: it skips its own
    # security bootstrap whenever it detects opensearch.yml already has SSL
    # configured (which it will, since certs are wired in before this step),
    # and it starts the node directly as root, which OpenSearch always refuses.
    # Instead we do the same two things it would have done, but correctly:
    # hash the password ourselves, and run securityadmin.sh as the service
    # user against the node that's already running under systemd.

    local hash_tool="${BINARIES_DIR}/plugins/opensearch-security/tools/hash.sh"
    local securityadmin_tool="${BINARIES_DIR}/plugins/opensearch-security/tools/securityadmin.sh"
    local internal_users_yml="${CONFIG_DIR}/opensearch-security/internal_users.yml"

    # Belt-and-suspenders: make sure exec bits are set even if this function
    # is reached on a re-run without going through step_setup_dirs again.
    [[ -f "${hash_tool}" ]] && chmod +x "${hash_tool}" 2>/dev/null || true
    [[ -f "${securityadmin_tool}" ]] && chmod +x "${securityadmin_tool}" 2>/dev/null || true

    [[ -x "${hash_tool}" ]] || fail "hash.sh not found/executable at ${hash_tool}"
    [[ -x "${securityadmin_tool}" ]] || fail "securityadmin.sh not found/executable at ${securityadmin_tool}"
    [[ -f "${internal_users_yml}" ]] || fail "internal_users.yml not found at ${internal_users_yml}"

    log "Generating bcrypt hash for the admin password"
    local admin_hash
    admin_hash="$(sudo -u "${SERVICE_USER}" env JAVA_HOME="${BINARIES_DIR}/jdk" "${hash_tool}" -p "${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" 2>/dev/null | tail -n1 | tr -d '\r')"
    [[ -n "${admin_hash}" ]] || fail "Could not generate a bcrypt hash for the admin password via hash.sh"

    log "Writing the new hash into internal_users.yml (admin user only)"
    awk -v newhash="${admin_hash}" '
        BEGIN { in_admin=0 }
        /^admin:[[:space:]]*$/ { in_admin=1; print; next }
        in_admin && /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ && $0 !~ /^admin:/ { in_admin=0 }
        in_admin && /^[[:space:]]+hash:/ {
            print "  hash: \"" newhash "\""
            in_admin=0
            next
        }
        { print }
    ' "${internal_users_yml}" > "${internal_users_yml}.tmp" && mv "${internal_users_yml}.tmp" "${internal_users_yml}"
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${internal_users_yml}"

    grep -q "${admin_hash}" "${internal_users_yml}" || fail "Failed to write the new admin password hash into ${internal_users_yml}"

    log "Waiting for HTTPS port ${HTTP_PORT} on ${NETWORK_HOST} to accept connections"
    step_wait_for_https_port "${NETWORK_HOST}" "${HTTP_PORT}" 90 \
        || fail "OpenSearch did not become reachable on https://${NETWORK_HOST}:${HTTP_PORT} in time. Check: journalctl -u opensearch -f"

    # NOTE: securityadmin.sh's TransportClient mode (talking to the native
    # transport port, 9300) was deprecated starting with OpenSearch 2.x - the
    # tool now speaks REST/HTTPS instead, the same as any other client. Since
    # our OpenSearch version here is 2.19.3, we must point -h/-p at the HTTP
    # port (9200), not 9300. Pointing it at 9300 makes securityadmin.sh send
    # an HTTP-formatted request at the binary transport protocol port, which
    # OpenSearch rejects with "This is not an HTTP port" - a red herring that
    # looks like a connectivity problem but is really just the wrong port.
    log "Running securityadmin.sh (as ${SERVICE_USER}) to initialize the .opendistro_security index"
    sudo -u "${SERVICE_USER}" env JAVA_HOME="${BINARIES_DIR}/jdk" "${securityadmin_tool}" \
        -cd "${CONFIG_DIR}/opensearch-security/" \
        -icl -nhnv \
        -cacert "${CONFIG_DIR}/root-ca.pem" \
        -cert "${CONFIG_DIR}/admin.pem" \
        -key "${CONFIG_DIR}/admin-key.pem" \
        -h "${NETWORK_HOST}" -p "${HTTP_PORT}" \
        2>&1 | tee -a "${LOG_FILE}"
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || fail "securityadmin.sh failed to initialize the security index. See output above and ${LOG_FILE}."

    log "Security index initialized successfully."
}

step_final_verify() {
    log "STEP: Verifying cluster health with admin credentials"
    command -v curl >/dev/null 2>&1 || return 0

    # Right after securityadmin.sh reports success, the security plugin still
    # needs a brief moment to reload its config across the cluster before it
    # will accept authenticated requests. Hitting the API immediately can
    # transiently return "OpenSearch Security not initialized." even though
    # the install itself succeeded, so retry for a short window instead of
    # treating the first response as final.
    local health waited=0 timeout_s=30
    while (( waited < timeout_s )); do
        health="$(curl -sk -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" "https://${NETWORK_HOST}:${HTTP_PORT}/_cluster/health?pretty" --max-time 10)"
        echo "${health}" | grep -q '"status"' && break
        sleep 3
        waited=$((waited + 3))
    done

    echo "${health}" | tee -a "${LOG_FILE}"

    if echo "${health}" | grep -q '"status"'; then
        log "OpenSearch responded successfully with cluster health."
    else
        log "WARNING: OpenSearch did not return the expected cluster health JSON after ${timeout_s}s. Check the response above and: journalctl -u opensearch -f"
    fi
}
step_generate_certs() {
    log "STEP: Generating Root CA / Admin / Node certificates"
    cd "${CONFIG_DIR}"

    # NOTE ON NODE CERT SANs: the node certificate's Subject Alternative
    # Name list must include every address a client might use to connect -
    # not just the hostname. This install sets network.host to the
    # server's IP (${NETWORK_HOST}), and companion tooling (e.g. OpenSearch
    # Dashboards) commonly connects via that same IP with strict TLS
    # hostname/IP verification enabled. A cert whose SAN list only contains
    # DNS:${NODE_NAME} will be correctly REJECTED by such clients with
    # "Hostname/IP does not match certificate's altnames" even though
    # everything else about the connection is fine. We include the
    # hostname, the detected IP, and 127.0.0.1/localhost so both
    # IP-based and hostname-based clients (local or remote) verify cleanly
    # without needing a manual cert regeneration after the fact.
    if [[ -f "root-ca.pem" && -f "admin.pem" && -f "node1.pem" ]]; then
        # Even on a "skip regeneration" re-run, verify the existing node
        # cert actually covers our IP - if an older cert (generated before
        # this fix) is sitting here, silently keeping it would reproduce
        # the exact TLS verification failure this fix exists to prevent.
        if command -v openssl >/dev/null 2>&1 && ! openssl x509 -in node1.pem -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:${NETWORK_HOST}"; then
            log "Existing node1.pem does not include IP:${NETWORK_HOST} in its SAN list. Regenerating node certificate only (Root CA and Admin cert are unaffected and left as-is)."
            rm -f node1.pem node1-key.pem
        else
            log "Certificates already exist and node cert already covers IP:${NETWORK_HOST}; skipping generation."
        fi
    fi

    if [[ ! -f "root-ca.pem" || ! -f "admin.pem" ]]; then
        local subj_common="/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_LOCALITY}/O=${CERT_ORG}/OU=${CERT_OU}"

        log "Generating Root CA"
        openssl genrsa -out root-ca-key.pem 2048
        openssl req -new -x509 -sha256 -key root-ca-key.pem \
            -subj "${subj_common}/CN=ROOT" -out root-ca.pem -days "${CERT_DAYS}"

        log "Generating Admin certificate"
        openssl genrsa -out admin-key-temp.pem 2048
        openssl pkcs8 -inform PEM -outform PEM -in admin-key-temp.pem -topk8 -nocrypt -v1 PBE-SHA1-3DES -out admin-key.pem
        openssl req -new -key admin-key.pem -subj "${subj_common}/CN=ADMIN" -out admin.csr
        openssl x509 -req -in admin.csr -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -sha256 -out admin.pem -days "${CERT_DAYS}"
        rm -f admin-key-temp.pem admin.csr
    fi

    if [[ ! -f "node1.pem" ]]; then
        local subj_common="/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_LOCALITY}/O=${CERT_ORG}/OU=${CERT_OU}"

        log "Generating Node certificate for ${NODE_NAME} (SANs: DNS:${NODE_NAME}, IP:${NETWORK_HOST}, IP:127.0.0.1, DNS:localhost)"
        openssl genrsa -out node1-key-temp.pem 2048
        openssl pkcs8 -inform PEM -outform PEM -in node1-key-temp.pem -topk8 -nocrypt -v1 PBE-SHA1-3DES -out node1-key.pem
        openssl req -new -key node1-key.pem -subj "${subj_common}/CN=${NODE_NAME}" -out node1.csr

        # Include hostname AND the detected IP (plus loopback) as SANs so
        # clients connecting via either form pass strict TLS verification.
        echo "subjectAltName=DNS:${NODE_NAME},IP:${NETWORK_HOST},IP:127.0.0.1,DNS:localhost" > node1.ext

        openssl x509 -req -in node1.csr -CA root-ca.pem -CAkey root-ca-key.pem -CAcreateserial -sha256 -out node1.pem -days "${CERT_DAYS}" -extfile node1.ext

        log "Cleaning up temp cert files"
        rm -f node1-key-temp.pem node1.csr node1.ext
    fi

    chmod 600 ./*-key.pem 2>/dev/null || true

    # Fail loudly here rather than let a broken cert reach securityadmin.sh
    # or Dashboards later with a confusing downstream error.
    if command -v openssl >/dev/null 2>&1; then
        openssl x509 -in node1.pem -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:${NETWORK_HOST}" \
            || fail "Node certificate does not contain IP:${NETWORK_HOST} in its SAN list after generation. Inspect ${CONFIG_DIR}/node1.ext and node1.pem manually."
    fi
}

step_wire_certs_into_yml() {
    log "STEP: Wiring certificates into opensearch.yml"
    local yml="${CONFIG_DIR}/opensearch.yml"

    # Stock opensearch.yml ships these plugins.security.ssl.* lines commented
    # out (e.g. "#plugins.security.ssl.transport.pemcert_filepath: ..."). A
    # sed pattern anchored to "^key:" silently skips commented lines, leaving
    # SSL unconfigured (fails at startup with "No SSL configuration found").
    # This setter uncomments/replaces the line if present (commented or not),
    # or appends it if the key doesn't exist in the file at all.
    set_yaml_kv_force() {
        local key="$1" val="$2"
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}:" "${yml}"; then
            sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}:.*|${key}: ${val}|" "${yml}"
        else
            echo "${key}: ${val}" >> "${yml}"
        fi
    }

    set_yaml_kv_force "plugins.security.ssl.http.enabled" "true"
    set_yaml_kv_force "plugins.security.ssl.transport.pemcert_filepath" "node1.pem"
    set_yaml_kv_force "plugins.security.ssl.transport.pemkey_filepath" "node1-key.pem"
    set_yaml_kv_force "plugins.security.ssl.transport.pemtrustedcas_filepath" "root-ca.pem"
    set_yaml_kv_force "plugins.security.ssl.http.pemcert_filepath" "node1.pem"
    set_yaml_kv_force "plugins.security.ssl.http.pemkey_filepath" "node1-key.pem"
    set_yaml_kv_force "plugins.security.ssl.http.pemtrustedcas_filepath" "root-ca.pem"

    # Remove existing admin_dn block (multi-line list, commented or not) then append clean entry
    sed -i -E "/^[[:space:]]*#?[[:space:]]*plugins.security.authcz.admin_dn:/,/^[[:space:]]*#?[[:space:]]*-/d" "${yml}"

    {
        echo "plugins.security.authcz.admin_dn:"
        echo "  - \"CN=ADMIN,OU=${CERT_OU},O=${CERT_ORG},L=${CERT_LOCALITY},ST=${CERT_STATE},C=${CERT_COUNTRY}\""
    } >> "${yml}"

    # Verify every SSL key actually landed active (uncommented) - fail loudly
    # here rather than have the service crash confusingly at startup later.
    local missing=()
    for key in \
        "plugins.security.ssl.http.enabled" \
        "plugins.security.ssl.transport.pemcert_filepath" \
        "plugins.security.ssl.transport.pemkey_filepath" \
        "plugins.security.ssl.transport.pemtrustedcas_filepath" \
        "plugins.security.ssl.http.pemcert_filepath" \
        "plugins.security.ssl.http.pemkey_filepath" \
        "plugins.security.ssl.http.pemtrustedcas_filepath"; do
        grep -qE "^${key}:" "${yml}" || missing+=("${key}")
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        fail "Failed to activate SSL settings in opensearch.yml: ${missing[*]}. Check ${yml} manually."
    fi

    log "Cert paths + admin_dn written to opensearch.yml and verified active."
}

step_fix_ownership() {
    log "STEP: Fixing ownership of app directories"
    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_BASE_DIR}"
}

step_create_service() {
    log "STEP: Creating systemd service file"
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=OpenSearch
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
RuntimeDirectory=data

WorkingDirectory=${BINARIES_DIR}
Environment="LD_LIBRARY_PATH=${BINARIES_DIR}/plugins/opensearch-knn/lib"
ExecStart=${BINARIES_DIR}/bin/opensearch -d

User=${SERVICE_USER}
Group=${SERVICE_GROUP}
StandardOutput=journal
StandardError=inherit
LimitNOFILE=65535
LimitNPROC=4096
LimitAS=infinity
LimitFSIZE=infinity
LimitMEMLOCK=infinity
TimeoutStopSec=0
KillSignal=SIGTERM
KillMode=process
SendSIGKILL=no
SuccessExitStatus=143
TimeoutStartSec=75

[Install]
WantedBy=multi-user.target
EOF

    log "Service file written to ${SERVICE_FILE}"
}

step_start_service() {
    log "STEP: Enabling and starting opensearch service"
    systemctl daemon-reload
    systemctl enable opensearch.service
    systemctl restart opensearch.service

    log "Waiting for service to come up..."
    sleep 10
    systemctl status opensearch --no-pager || true

    log "Checking that port ${HTTP_PORT} is at least accepting connections (security index isn't initialized yet - that's expected here)"
    if command -v curl >/dev/null 2>&1; then
        curl -sk "https://${NETWORK_HOST}:${HTTP_PORT}" --max-time 10 >/dev/null 2>&1 \
            && log "Port ${HTTP_PORT} is responding. Proceeding to initialize the security index." \
            || log "WARNING: port ${HTTP_PORT} did not respond yet - the next step will wait for it, but check 'journalctl -u opensearch -f' if this persists."
    fi
}

# ============================ CLI ARG PARSING ================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-dir)      BASE_DISK_DIR="$2"; shift 2 ;;
            --cluster-name)  CLUSTER_NAME="$2"; shift 2 ;;
            --http-port)     HTTP_PORT="$2"; shift 2 ;;
            -h|--help)
                cat <<EOF
Usage: sudo $0 [--base-dir /path/on/disk] [--cluster-name NAME] [--http-port PORT]

  --base-dir       Base directory/disk under which OpenSearch is installed
                    (e.g. /opt/ausiytic, /data/ausiytic). If omitted, you
                    will be prompted for it interactively.
  --cluster-name    OpenSearch cluster name. If omitted, you will be
                    prompted for it interactively.

Node name and network host/IP are always auto-detected from the server.
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
    log "===== Starting OpenSearch automated install (v${OS_VERSION}) ====="

    detect_os
    step_prompt_inputs
    step_prereqs
    step_system_tuning
    step_download_extract
    step_setup_dirs
    step_configure_yml
    step_generate_certs
    step_wire_certs_into_yml
    step_fix_ownership
    step_firewall
    step_selinux
    step_create_service
    step_start_service
    step_bootstrap_security
    step_final_verify

    log "===== OpenSearch installation complete ====="
    log "Base disk dir: ${BASE_DISK_DIR}"
    log "Node name   : ${NODE_NAME}"
    log "Network host: ${NETWORK_HOST}"
    log "HTTP port   : ${HTTP_PORT}"
    log "Admin user  : admin"
    log "Check status: systemctl status opensearch"
    log "Tail logs   : journalctl -u opensearch -f  |  tail -f ${LOGS_DIR}/*.log"
}

main "$@"

