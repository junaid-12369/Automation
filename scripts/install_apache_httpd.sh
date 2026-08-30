#!/bin/bash
#================================================================
# DESCRIPTION
#   Fully automated installer for Apache HTTP Server (built with
#   HTTP/2 support via nghttp2), compiled from source and wired
#   up as a systemd service.
#
#   Versions installed:
#       nghttp2 : 1.67.1
#       httpd   : 2.4.64
#
#   Compatible with:
#       RHEL / CentOS / Rocky / AlmaLinux / Fedora / Amazon Linux (yum/dnf)
#       Debian / Ubuntu (apt-get)
#
#   Handles automatically:
#       - Root vs sudo execution
#       - Root volume ('/') as a valid base directory
#       - SELinux (Enforcing) on RHEL-family systems, which otherwise
#         blocks systemd from executing/reading files in non-standard
#         install paths.
#
#   Usage:
#       chmod +x install_apache_httpd.sh
#       sudo ./install_apache_httpd.sh
#       (or run directly as root; script will ask for the base
#        install directory, e.g. /opt/ausiytic)
#================================================================
# IMPLEMENTATION
#   Version  - v4
#     Fixes a real-world RHEL/Amazon Linux failure (203/EXEC, AVC
#     "denied execute" on apachectl/httpd) that v3 did not fully
#     resolve:
#
#       Root cause: a stale/broad local SELinux fcontext rule
#       (".../binaries(/.*)?" -> httpd_sys_content_t), left over
#       from an earlier run/test against the same install path,
#       was silently NOT removed by v3's self-heal step (its
#       `semanage fcontext -d ... || true` swallowed the failure,
#       and it matched against the full fcontext listing instead
#       of local customizations only, so it could try to "delete"
#       a built-in policy default and fail silently). The stale
#       broad rule then won out over the specific httpd_exec_t
#       rule during `restorecon`, leaving httpd/apachectl labeled
#       httpd_sys_content_t -> systemd/init_t denied execute.
#
#     Changes in v4:
#       1. Self-heal now lists ONLY local customizations
#          (`semanage fcontext -l -C`) and matches the exact path
#          column, so it never tries to delete a built-in policy
#          rule (which would fail) and reliably finds real leftovers.
#       2. Self-heal failures are now logged loudly instead of
#          being swallowed by `|| true`.
#       3. After `restorecon`, the script now also applies `chcon`
#          directly to bin/conf/modules/htdocs/logs -- this sets
#          the label deterministically and is NOT subject to
#          file_contexts pattern-precedence ambiguity the way
#          restorecon is.
#       4. Explicit verification: before starting the service, the
#          script checks the actual SELinux type on the httpd
#          binary and dies with a clear diagnostic (dumping the
#          relevant `ls -Z` / `semanage fcontext -l -C` output to
#          the error log) if it isn't httpd_exec_t, instead of
#          letting systemd fail later with an opaque 203/EXEC.
#       5. The PID file is now pre-created and chcon'd to
#          httpd_var_run_t before the first start, so
#          Type=forking's PIDFile write doesn't hit the same class
#          of labeling problem on a non-standard path.
#================================================================

set -euo pipefail

# ---------------------------------------------------------------
# 0. Versions & constants
# ---------------------------------------------------------------
NGHTTP2_VERSION="1.67.1"
HTTPD_VERSION="2.4.64"

NGHTTP2_TARBALL="nghttp2-${NGHTTP2_VERSION}.tar.gz"
NGHTTP2_URL="https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/${NGHTTP2_TARBALL}"

HTTPD_TARBALL="httpd-${HTTPD_VERSION}.tar.gz"
HTTPD_URL="https://archive.apache.org/dist/httpd/${HTTPD_TARBALL}"

LOGTIME=$(date +"%F %T")
FILENAME=$(date +"%d%m%Y%H")
SCRIPT_PWD=$(pwd)
ACCESS_LOG="${SCRIPT_PWD}/httpd_install.access.${FILENAME}.log"
ERROR_LOG="${SCRIPT_PWD}/httpd_install.error.${FILENAME}.log"

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
    if ! command -v sudo >/dev/null 2>&1; then
        die "Not running as root and 'sudo' is not installed. Re-run this script as root, or install sudo first."
    fi
    if ! sudo -n true 2>/dev/null; then
        echo "This script needs sudo privileges (for package installs & service setup)."
        echo "You may be prompted for your password."
    fi
    SUDO="sudo"
fi

# ---------------------------------------------------------------
# 2. Ask user for the base directory (varies per server)
# ---------------------------------------------------------------
read -rp "Enter base install directory (e.g. /opt/ausiytic, or / for root volume): " BASE_DIR

if [[ -z "$BASE_DIR" ]]; then
    die "Base directory cannot be empty."
fi

if [[ "$BASE_DIR" == "/" ]]; then
    BASE_DIR=""
    BASE_DIR_DISPLAY="/"
else
    BASE_DIR="${BASE_DIR%/}"
    [[ -z "$BASE_DIR" ]] && die "Base directory cannot be empty."
    BASE_DIR_DISPLAY="$BASE_DIR"
fi

echo
echo "The following directories will be created/used under: $BASE_DIR_DISPLAY"
echo "  Source          : $BASE_DIR/softwares"
echo "  nghttp2 install : $BASE_DIR/apps/nghttp2"
echo "  Apache binaries : $BASE_DIR/apps/apache/binaries"
echo "  Apache data     : $BASE_DIR/apps/apache/data"
echo "  Apache logs     : $BASE_DIR/logs/apache"
echo
if [[ "$BASE_DIR_DISPLAY" == "/" ]]; then
    echo "WARNING: You've chosen the root volume ('/'). This will create top-level"
    echo "         directories like /softwares, /apps, /logs directly under /."
fi
read -rp "Proceed with installation? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------
# 3. Derived paths
# ---------------------------------------------------------------
SOURCE="$BASE_DIR/softwares"
NGHTTP2_PREFIX="$BASE_DIR/apps/nghttp2"
APACHE_BINARIES="$BASE_DIR/apps/apache/binaries"
APACHE_DATA="$BASE_DIR/apps/apache/data"
APACHE_LOGS_SL="$BASE_DIR/apps/apache/logs"
APACHE_LOGS="$BASE_DIR/logs/apache"
APACHE_DATA_BKP="$BASE_DIR/apps/apache/apache_bkp"
APACHE_PIDFILE="${APACHE_LOGS}/httpd.pid"

mkdir -p "$SOURCE" "$APACHE_BINARIES" "$APACHE_DATA" "$APACHE_LOGS" "$APACHE_DATA_BKP"
log "Directories ensured under $BASE_DIR_DISPLAY"

if [[ -L "$APACHE_LOGS_SL" || -e "$APACHE_LOGS_SL" ]]; then
    log "$APACHE_LOGS_SL already exists, skipping symlink creation"
else
    ln -sn "$APACHE_LOGS" "$APACHE_LOGS_SL"
    log "Created symlink $APACHE_LOGS_SL -> $APACHE_LOGS"
fi

# ---------------------------------------------------------------
# 4. Detect OS / package manager and install build dependencies
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
log "Installing build dependencies (this may take a few minutes)..."

case "$PKG_MGR" in
    yum|dnf)
        $SUDO "$PKG_MGR" install -y gcc gcc-c++ make automake autoconf libtool \
            openssl-devel apr-devel apr-util-devel pcre-devel zlib-devel \
            wget tar which pkgconfig redhat-rpm-config \
            >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || die "Dependency installation failed. See $ERROR_LOG"
        ;;
    apt)
        export DEBIAN_FRONTEND=noninteractive
        $SUDO apt-get update -y >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
        $SUDO apt-get install -y gcc g++ make automake autoconf libtool \
            libssl-dev libapr1-dev libaprutil1-dev libpcre3-dev zlib1g-dev \
            wget tar pkg-config \
            >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || die "Dependency installation failed. See $ERROR_LOG"
        ;;
esac
log "Build dependencies installed"

# ---------------------------------------------------------------
# 5. Build & install nghttp2
# ---------------------------------------------------------------
if [[ -f "$NGHTTP2_PREFIX/lib/libnghttp2.so" ]]; then
    log "nghttp2 already installed at $NGHTTP2_PREFIX, skipping build"
else
    log "Downloading nghttp2 $NGHTTP2_VERSION"
    cd "$SOURCE"
    wget -N "$NGHTTP2_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || die "Failed to download nghttp2 from $NGHTTP2_URL"
    tar -xvzf "$NGHTTP2_TARBALL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"

    cd "$SOURCE/nghttp2-${NGHTTP2_VERSION}"
    log "Configuring & compiling nghttp2 (this can take several minutes)"
    ./configure --prefix="$NGHTTP2_PREFIX" --exec-prefix="$NGHTTP2_PREFIX" \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "nghttp2 configure failed. See $ERROR_LOG"
    make -j"$(nproc)" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "nghttp2 make failed. See $ERROR_LOG"
    make install >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "nghttp2 make install failed. See $ERROR_LOG"
    log "nghttp2 $NGHTTP2_VERSION installed to $NGHTTP2_PREFIX"
fi

# ---------------------------------------------------------------
# 5b. Register our custom-built nghttp2 with the dynamic linker
#
#     Compiling httpd's mod_http2 with --with-nghttp2=$NGHTTP2_PREFIX
#     only affects link-time symbol resolution. At RUNTIME, dlopen()
#     resolves mod_http2.so's dependency on libnghttp2.so purely via
#     the normal search order (LD_LIBRARY_PATH, then ld.so.cache,
#     then default system paths) -- it does NOT automatically prefer
#     the prefix used at compile time. On a base image that already
#     ships an older system libnghttp2 (very common: curl depends on
#     it), that older one wins, and mod_http2.so fails to load with
#     "undefined symbol: ..." because it expects newer API surface
#     from the nghttp2 version it was actually built against.
#
#     Fix: register our prefix with ldconfig (system-wide, persists
#     across reboots) AND export LD_LIBRARY_PATH in the systemd unit
#     (belt-and-suspenders -- LD_LIBRARY_PATH takes precedence over
#     ld.so.cache, so it wins even if some other package's postinstall
#     re-registers a conflicting cache entry later).
# ---------------------------------------------------------------
LDCONF_FILE="/etc/ld.so.conf.d/apache-custom-nghttp2.conf"
log "Registering $NGHTTP2_PREFIX/lib with the dynamic linker (ldconfig)"
echo "$NGHTTP2_PREFIX/lib" | $SUDO tee "$LDCONF_FILE" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
$SUDO ldconfig >> "$ACCESS_LOG" 2>> "$ERROR_LOG"

# ---------------------------------------------------------------
# 6. Build & install Apache httpd
#
#    IMPORTANT: mod_http2.so is linked against our custom-built
#    nghttp2, but relying on ldconfig/LD_LIBRARY_PATH for RUNTIME
#    resolution proved unreliable in practice -- an older system
#    libnghttp2 (typically pulled in by curl) can still win
#    depending on ld.so.cache scan order, causing "undefined
#    symbol" failures under systemd even after ldconfig registers
#    our path. The robust fix is to embed an RPATH directly into
#    the built objects at link time via LDFLAGS, so resolution
#    never depends on environment or cache state.
#
#    We also detect a previously-built httpd/mod_http2.so that is
#    missing this rpath (e.g. from an earlier run of this script
#    before this fix existed) and automatically force a clean
#    rebuild, so re-running the script actually fixes an existing
#    broken install instead of skipping the build step.
# ---------------------------------------------------------------
NGHTTP2_LIB="${NGHTTP2_PREFIX}/lib"

httpd_has_correct_rpath() {
    local so="$APACHE_BINARIES/modules/mod_http2.so"
    [[ -f "$so" ]] || return 1
    if command -v readelf >/dev/null 2>&1; then
        readelf -d "$so" 2>/dev/null | grep -E '\((RPATH|RUNPATH)\)' | grep -qF "$NGHTTP2_LIB"
        return $?
    elif command -v objdump >/dev/null 2>&1; then
        objdump -p "$so" 2>/dev/null | grep -E '^\s*(RPATH|RUNPATH)' | grep -qF "$NGHTTP2_LIB"
        return $?
    else
        # Can't verify -- assume it's fine rather than force endless rebuilds.
        return 0
    fi
}

if [[ -x "$APACHE_BINARIES/bin/httpd" ]] && httpd_has_correct_rpath; then
    log "Apache httpd already installed at $APACHE_BINARIES with correct nghttp2 rpath, skipping build"
else
    if [[ -x "$APACHE_BINARIES/bin/httpd" ]]; then
        log "Existing Apache httpd install is missing the nghttp2 rpath fix -- forcing a clean rebuild"
        $SUDO rm -rf "$APACHE_BINARIES"
        mkdir -p "$APACHE_BINARIES"
    fi
    log "Downloading Apache httpd $HTTPD_VERSION"
    cd "$SOURCE"
    wget -N "$HTTPD_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || die "Failed to download httpd from $HTTPD_URL"
    tar -xvf "$HTTPD_TARBALL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"

    cd "$SOURCE/httpd-${HTTPD_VERSION}"
    log "Configuring & compiling Apache httpd (this can take several minutes)"
    LDFLAGS="-Wl,-rpath,${NGHTTP2_LIB}" \
    ./configure --prefix="$APACHE_BINARIES" --exec-prefix="$APACHE_BINARIES" \
        --with-nghttp2="$NGHTTP2_PREFIX" \
        --enable-ssl --enable-proxy --enable-proxy-http --enable-http2 \
        >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "httpd configure failed. See $ERROR_LOG"
    make -j"$(nproc)" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "httpd make failed. See $ERROR_LOG"
    make install >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || die "httpd make install failed. See $ERROR_LOG"
    log "Apache httpd $HTTPD_VERSION installed to $APACHE_BINARIES"

    if ! httpd_has_correct_rpath; then
        warn "Built mod_http2.so but could not confirm the nghttp2 rpath was embedded (readelf/objdump unavailable or unexpected linker behavior) -- continuing, relying on ldconfig/LD_LIBRARY_PATH as fallback. Verification in step 7d will catch a real problem before starting the service."
    fi
fi

# ---------------------------------------------------------------
# 7. Configure httpd.conf
# ---------------------------------------------------------------
CONF_FILE="$APACHE_BINARIES/conf/httpd.conf"
[[ -f "$CONF_FILE" ]] || die "httpd.conf not found at $CONF_FILE"

log "Updating httpd.conf"

grep -q '^[[:space:]]*ServerSignature' "$CONF_FILE" \
    && sed -i 's/^[[:space:]]*ServerSignature.*/ServerSignature Off/' "$CONF_FILE" \
    || echo "ServerSignature Off" >> "$CONF_FILE"

grep -q '^[[:space:]]*ServerTokens' "$CONF_FILE" \
    && sed -i 's/^[[:space:]]*ServerTokens.*/ServerTokens Prod/' "$CONF_FILE" \
    || echo "ServerTokens Prod" >> "$CONF_FILE"

sed -i "s#^[[:space:]]*ErrorLog .*#ErrorLog \"${APACHE_LOGS_SL}/error_log\"#" "$CONF_FILE"
sed -i "s#^[[:space:]]*CustomLog .*#CustomLog \"${APACHE_LOGS_SL}/access_log\" common#" "$CONF_FILE"

sed -i '/^[[:space:]]*PidFile/d' "$CONF_FILE"
echo "PidFile \"${APACHE_PIDFILE}\"" >> "$CONF_FILE"

for MOD in \
    "LoadModule http2_module modules/mod_http2.so" \
    "LoadModule proxy_module modules/mod_proxy.so" \
    "LoadModule proxy_http_module modules/mod_proxy_http.so"
do
    MOD_NAME=$(echo "$MOD" | awk '{print $2}')
    if grep -q "^LoadModule ${MOD_NAME} " "$CONF_FILE"; then
        log "$MOD_NAME already enabled"
    elif grep -q "^#LoadModule ${MOD_NAME} " "$CONF_FILE"; then
        sed -i "s|^#LoadModule ${MOD_NAME} .*|${MOD}|" "$CONF_FILE"
        log "Uncommented $MOD_NAME"
    else
        echo "$MOD" >> "$CONF_FILE"
        log "Added $MOD_NAME"
    fi
done

log "httpd.conf updated"

# ---------------------------------------------------------------
# 7c. Config syntax check -- fail here with the FULL error instead
#     of letting systemd fail later, where journalctl often
#     truncates the message and hides which directive/line broke.
# ---------------------------------------------------------------
log "Checking httpd.conf syntax (apachectl -t)"
if ! CONF_TEST_OUTPUT=$(LD_LIBRARY_PATH="${NGHTTP2_PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$APACHE_BINARIES/bin/apachectl" -t -f "$CONF_FILE" 2>&1); then
    echo "$CONF_TEST_OUTPUT" >> "$ERROR_LOG"
    echo "$CONF_TEST_OUTPUT" >&2
    die "httpd.conf failed syntax check (see full output above / in $ERROR_LOG). Fix $CONF_FILE and re-run."
fi
log "httpd.conf syntax OK: $CONF_TEST_OUTPUT"

# ---------------------------------------------------------------
# 7b. SELinux handling (RHEL-family systems only)
# ---------------------------------------------------------------
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    log "SELinux is Enforcing -- applying SELinux file contexts for custom install paths"

    if ! command -v semanage >/dev/null 2>&1; then
        log "Installing semanage (policycoreutils-python-utils) for SELinux context management"
        $SUDO "$PKG_MGR" install -y policycoreutils-python-utils \
            >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || $SUDO "$PKG_MGR" install -y policycoreutils-python \
               >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
            || die "Could not install semanage (policycoreutils-python-utils/policycoreutils-python). See $ERROR_LOG"
    fi

    # --- Self-heal (v4) -----------------------------------------
    # List ONLY local customizations (-C). Listing everything (-l)
    # mixes in built-in policy defaults, which `semanage fcontext -d`
    # cannot remove -- attempting to delete one fails, and a bare
    # `|| true` used to hide that failure completely. Using -C and
    # matching the exact path column avoids both problems: we only
    # ever try to delete rules we (or a previous run) actually added.
    STALE_PATTERN="${APACHE_BINARIES}(/.*)?"
    if $SUDO semanage fcontext -l -C 2>/dev/null | awk '{print $1}' | grep -qxF "$STALE_PATTERN"; then
        log "Found a stale broad local SELinux context rule on the whole binaries tree -- removing it"
        if $SUDO semanage fcontext -d "$STALE_PATTERN" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"; then
            log "Stale rule removed"
        else
            warn "Failed to remove stale rule '$STALE_PATTERN' via semanage -- will rely on chcon override below"
        fi
    fi

    set_fcontext() {
        local ctx_type="$1" ctx_path="$2"
        if $SUDO semanage fcontext -l -C 2>/dev/null | awk '{print $1}' | grep -qxF "$ctx_path"; then
            $SUDO semanage fcontext -m -t "$ctx_type" "$ctx_path" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
        else
            $SUDO semanage fcontext -a -t "$ctx_type" "$ctx_path" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
        fi
    }

    # Intentionally no broad catch-all on the whole ${APACHE_BINARIES}
    # tree -- each subdirectory is labeled independently.
    set_fcontext httpd_exec_t "${APACHE_BINARIES}/bin(/.*)?"
    set_fcontext httpd_config_t "${APACHE_BINARIES}/conf(/.*)?"
    if [[ -d "${APACHE_BINARIES}/modules" ]]; then
        set_fcontext httpd_modules_t "${APACHE_BINARIES}/modules(/.*)?"
    fi
    if [[ -d "${APACHE_BINARIES}/htdocs" ]]; then
        set_fcontext httpd_sys_content_t "${APACHE_BINARIES}/htdocs(/.*)?"
    fi
    set_fcontext httpd_log_t "${APACHE_LOGS}(/.*)?"
    set_fcontext httpd_var_run_t "${APACHE_PIDFILE}"

    # nghttp2's shared library lives outside the apache tree entirely
    # (${NGHTTP2_PREFIX}/lib) and was never labeled by anything above,
    # so it sits with whatever default type it got on creation --
    # which httpd_t is NOT generally permitted to dlopen from. An
    # unconfined check (plain `ldd`, run directly as root outside
    # systemd) will resolve it fine and mask this, but the confined
    # httpd_t process under systemd gets denied and the dynamic
    # linker silently falls through to an older system libnghttp2 in
    # ld.so.cache -- producing a misleading "undefined symbol" error
    # that looks like a build problem but is actually SELinux. lib_t
    # is the standard type confined domains are permitted to dlopen
    # shared libraries from.
    set_fcontext lib_t "${NGHTTP2_LIB}(/.*)?"

    log "Applying labels via restorecon"
    $SUDO restorecon -Rv "${APACHE_BINARIES}" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    $SUDO restorecon -Rv "${APACHE_LOGS}" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
    $SUDO restorecon -Rv "${NGHTTP2_LIB}" >> "$ACCESS_LOG" 2>> "$ERROR_LOG"

    # --- Deterministic override (v4) -----------------------------
    # restorecon relies on file_contexts pattern precedence, which
    # is not guaranteed to prefer the more specific rule in every
    # policy version -- this is exactly what caused the RHEL/Amazon
    # Linux 203/EXEC failure. chcon sets the label directly with no
    # pattern ambiguity, so we apply it as a final, authoritative
    # pass right before starting the service.
    log "Forcing exact SELinux labels via chcon (defends against pattern-precedence issues)"
    $SUDO chcon -R -t httpd_exec_t "${APACHE_BINARIES}/bin" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || warn "chcon on bin/ failed -- service start may still fail, check manually"
    $SUDO chcon -R -t httpd_config_t "${APACHE_BINARIES}/conf" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    if [[ -d "${APACHE_BINARIES}/modules" ]]; then
        $SUDO chcon -R -t httpd_modules_t "${APACHE_BINARIES}/modules" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    fi
    if [[ -d "${APACHE_BINARIES}/htdocs" ]]; then
        $SUDO chcon -R -t httpd_sys_content_t "${APACHE_BINARIES}/htdocs" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    fi
    $SUDO chcon -R -t httpd_log_t "${APACHE_LOGS}" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true
    $SUDO chcon -R -t lib_t "${NGHTTP2_LIB}" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
        || warn "chcon on ${NGHTTP2_LIB} failed -- mod_http2.so may still fail to load under systemd, check manually"

    # Pre-create the PID file so its label is correct before systemd's
    # first Type=forking start writes to it (avoids the same class of
    # labeling failure on a non-standard PID path).
    $SUDO touch "${APACHE_PIDFILE}"
    $SUDO chcon -t httpd_var_run_t "${APACHE_PIDFILE}" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" || true

    # --- Verification (v4) ---------------------------------------
    # Fail fast with a clear diagnostic instead of a generic 203/EXEC
    # from systemd later.
    ACTUAL_TYPE=$($SUDO stat -c '%C' "${APACHE_BINARIES}/bin/httpd" 2>/dev/null | awk -F: '{print $3}')
    if [[ "$ACTUAL_TYPE" != "httpd_exec_t" ]]; then
        {
            echo "---- SELinux diagnostic dump ----"
            $SUDO ls -Z "${APACHE_BINARIES}/bin/httpd" "${APACHE_BINARIES}/bin/apachectl" 2>&1
            echo "-- relevant local fcontext rules --"
            $SUDO semanage fcontext -l -C 2>&1 | grep -F "${APACHE_BINARIES}" || true
        } >> "$ERROR_LOG"
        die "httpd binary is labeled '$ACTUAL_TYPE', not 'httpd_exec_t', after restorecon+chcon. See $ERROR_LOG for a diagnostic dump (ls -Z / semanage fcontext -l -C)."
    fi
    log "Verified: ${APACHE_BINARIES}/bin/httpd is correctly labeled httpd_exec_t"

    log "SELinux contexts applied and verified"
else
    log "SELinux not enforcing (or not present) -- skipping SELinux context setup"
fi

# ---------------------------------------------------------------
# 7d. Verify mod_http2.so actually resolves against OUR nghttp2 --
#     run AFTER SELinux labeling (not before), and, when SELinux is
#     enforcing, actually simulate the confined httpd_t domain via
#     `runcon` rather than just checking as an unconfined root
#     shell. An unconfined check can pass while systemd's confined
#     httpd_t start still fails -- that's exactly what happened
#     here: the rpath resolved correctly unconfined, but httpd_t
#     was denied read access to the nghttp2 library (never labeled
#     for httpd_t to use) and silently fell back to an older system
#     libnghttp2 lacking the required symbol.
# ---------------------------------------------------------------
if [[ -f "${APACHE_BINARIES}/modules/mod_http2.so" ]]; then
    RESOLVED_NGHTTP2=$(ldd "${APACHE_BINARIES}/modules/mod_http2.so" | awk '/libnghttp2/ {print $3}')
    if [[ -z "$RESOLVED_NGHTTP2" ]]; then
        warn "Could not determine which libnghttp2 mod_http2.so resolves to -- continuing, but watch for load errors."
    elif [[ "$RESOLVED_NGHTTP2" != "${NGHTTP2_LIB}/"* ]]; then
        die "mod_http2.so resolves libnghttp2 to '$RESOLVED_NGHTTP2' instead of ${NGHTTP2_LIB} -- the rpath fix did not take effect. Check 'readelf -d ${APACHE_BINARIES}/modules/mod_http2.so | grep PATH' and 'ldconfig -p | grep nghttp2'."
    else
        log "Verified (unconfined): mod_http2.so resolves libnghttp2 to $RESOLVED_NGHTTP2"
    fi

    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]] && command -v runcon >/dev/null 2>&1; then
        log "Verifying httpd_t (the confined domain systemd will actually use) can read $RESOLVED_NGHTTP2"
        # Must specify the full context (system_u:system_r:httpd_t) --
        # `runcon -t httpd_t` alone keeps the CALLING shell's role
        # (unconfined_r), and httpd_t is not a valid type under
        # unconfined_r, so it's rejected as an invalid context before
        # ever attempting the read. httpd actually runs as
        # system_u:system_r:httpd_t under systemd, so that's the
        # context we need to simulate.
        if $SUDO runcon system_u:system_r:httpd_t:s0 -- head -c1 "$RESOLVED_NGHTTP2" > /dev/null 2>>"$ERROR_LOG"; then
            log "Verified (confined as httpd_t): read access to $RESOLVED_NGHTTP2 succeeds"
        else
            {
                echo "---- ls -Z on the nghttp2 library ----"
                $SUDO ls -Z "${NGHTTP2_LIB}" 2>&1
                echo "---- relevant local fcontext rules ----"
                $SUDO semanage fcontext -l -C 2>&1 | grep -F "${NGHTTP2_LIB}" || true
                echo "---- recent AVC denials ----"
                $SUDO ausearch -m avc -ts recent 2>&1 | tail -20
            } >> "$ERROR_LOG"
            die "httpd_t cannot read $RESOLVED_NGHTTP2 (SELinux denial). This is why systemd's confined start fails even though an unconfined check succeeds. Diagnostic dumped to $ERROR_LOG."
        fi
    fi
fi

# ---------------------------------------------------------------
# 8. Create systemd service and enable/start it
# ---------------------------------------------------------------
HTTP_SERVICE="/etc/systemd/system/httpd.service"

log "Creating systemd service for Apache HTTP"
$SUDO bash -c "cat > '$HTTP_SERVICE'" <<EOF
[Unit]
Description=The Apache HTTP Server
After=network.target remote-fs.target nss-lookup.target multi-user.target

[Service]
Type=forking
Environment=LD_LIBRARY_PATH=${NGHTTP2_PREFIX}/lib
PIDFile=${APACHE_PIDFILE}
ExecStart=${APACHE_BINARIES}/bin/apachectl -f ${APACHE_BINARIES}/conf/httpd.conf -k start
ExecReload=${APACHE_BINARIES}/bin/apachectl -f ${APACHE_BINARIES}/conf/httpd.conf -k restart
ExecStop=${APACHE_BINARIES}/bin/apachectl -f ${APACHE_BINARIES}/conf/httpd.conf -k stop
KillSignal=SIGCONT
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

log "systemd service file written to $HTTP_SERVICE"

$SUDO systemctl daemon-reload
log "systemd daemon reloaded"

$SUDO systemctl enable httpd.service >> "$ACCESS_LOG" 2>> "$ERROR_LOG"
log "httpd.service enabled for boot"

if ! $SUDO systemctl restart httpd.service; then
    # Auto-capture full diagnostics instead of making the user dig
    # through journalctl by hand -- journalctl's default pager/width
    # truncates long lines (e.g. "Syntax error on line N of ..."),
    # hiding exactly the part that explains the failure.
    {
        echo "---- systemctl status httpd.service ----"
        $SUDO systemctl status httpd.service --no-pager -l 2>&1
        echo "---- journalctl -xeu httpd.service (untruncated) ----"
        $SUDO journalctl -xeu httpd.service --no-pager -n 50 -o cat 2>&1
        echo "---- tail of ${APACHE_LOGS}/error_log ----"
        $SUDO tail -n 50 "${APACHE_LOGS}/error_log" 2>&1
        echo "---- direct unconfined syntax/start check (bypasses systemd/SELinux confinement) ----"
        $SUDO "$APACHE_BINARIES/bin/apachectl" -t -f "$CONF_FILE" 2>&1
    } | tee -a "$ERROR_LOG"
    die "Failed to start httpd.service. Full diagnostics captured above and in $ERROR_LOG."
fi
log "httpd.service started"

# ---------------------------------------------------------------
# 9. Verify
# ---------------------------------------------------------------
sleep 2
if systemctl is-active --quiet httpd.service; then
    log "SUCCESS: Apache httpd is up and running."
    echo
    echo "=================================================================="
    echo " Apache httpd $HTTPD_VERSION (with nghttp2 $NGHTTP2_VERSION) is installed and running."
    echo " Binaries : $APACHE_BINARIES"
    echo " Config   : $CONF_FILE"
    echo " Logs     : $APACHE_LOGS_SL  (symlink -> $APACHE_LOGS)"
    echo " Service  : systemctl status httpd"
    echo "=================================================================="
else
    die "Apache httpd service is not active. Run 'systemctl status httpd' and check $APACHE_LOGS/error_log for details."
fi

