#!/bin/bash

set -euo pipefail

CHROME_BUILD="151.0.7922"

CFT_KNOWN_GOOD_URL="https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json"

CHROME_INSTALL_DIR="/opt/google/chrome"
CHROME_BIN_LINK="/usr/local/bin/google-chrome"
CHROMEDRIVER_BIN="/usr/local/bin/chromedriver"

LOGTIME=$(date +"%F %T")
FILENAME=$(date +"%d%m%Y%H")
SCRIPT_PWD=$(pwd)
ACCESS_LOG="${SCRIPT_PWD}/chrome_install.access.${FILENAME}.log"
ERROR_LOG="${SCRIPT_PWD}/chrome_install.error.${FILENAME}.log"

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

if [[ $EUID -eq 0 ]]; then
    ESC=""
    echo "Running as root."
elif command -v sudo >/dev/null 2>&1; then
    ESC="sudo"
    echo "Using sudo for privileged commands."
else
    die "Not running as root and 'sudo' is not available. Re-run as root."
fi

ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] || die "Unsupported architecture '$ARCH' -- this script only handles x86_64."

read -rp "Enter scratch/download directory (e.g. /opt/ausiytic/softwares): " SOURCE

if [[ -z "$SOURCE" ]]; then
    die "Download directory cannot be empty."
fi
SOURCE="${SOURCE%/}"

mkdir -p "$SOURCE" || $ESC mkdir -p "$SOURCE" || die "Could not create $SOURCE"
log "Using scratch/download directory: $SOURCE"

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

command -v jq >/dev/null 2>&1 || {
    log "jq not found -- installing it (needed to parse the Chrome for Testing JSON feed)"
    case "$PKG_MGR" in
        yum|dnf) $ESC "$PKG_MGR" install -y jq >> "$ACCESS_LOG" 2>> "$ERROR_LOG" ;;
        apt)     $ESC apt-get update -y >> "$ACCESS_LOG" 2>> "$ERROR_LOG"; $ESC apt-get install -y jq >> "$ACCESS_LOG" 2>> "$ERROR_LOG" ;;
    esac
    command -v jq >/dev/null 2>&1 || die "Failed to install jq. See $ERROR_LOG"
}

command -v unzip >/dev/null 2>&1 || {
    log "unzip not found -- installing it"
    case "$PKG_MGR" in
        yum|dnf) $ESC "$PKG_MGR" install -y unzip >> "$ACCESS_LOG" 2>> "$ERROR_LOG" ;;
        apt)     $ESC apt-get install -y unzip >> "$ACCESS_LOG" 2>> "$ERROR_LOG" ;;
    esac
    command -v unzip >/dev/null 2>&1 || die "Failed to install unzip. See $ERROR_LOG"
}

case "$PKG_MGR" in
    yum|dnf)
        DEP_PACKAGES=(nss dbus-libs atk at-spi2-atk at-spi2-core cups-libs libdrm libXcomposite libXdamage libXfixes libXrandr libX11 libxkbcommon mesa-libgbm alsa-lib cairo pango liberation-fonts xdg-utils)
        ;;
    apt)
        DEP_PACKAGES=(libnss3 libdbus-1-3 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdrm2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libx11-6 libxcb1 libxext6 libxrender1 libxkbcommon0 libgbm1 libcairo2 libpango-1.0-0 libasound2t64 libasound2 fonts-liberation xdg-utils)
        ;;
esac

# Install one at a time: package names get renamed across distro releases
# (e.g. Ubuntu's libasound2 -> libasound2t64 as of 24.04+), so a single
# unknown name shouldn't cause the whole dependency set to be skipped.
# libasound2t64/libasound2 are alternates for the same lib on different
# Ubuntu releases -- once one of that pair installs, skip the other.
FAILED_DEPS=()
INSTALLED_DEPS=()
for pkg in "${DEP_PACKAGES[@]}"; do
    if [[ "$pkg" == "libasound2" ]] && printf '%s\n' "${INSTALLED_DEPS[@]}" | grep -qx "libasound2t64"; then
        continue
    fi
    case "$PKG_MGR" in
        yum|dnf) $ESC "$PKG_MGR" install -y "$pkg" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" && INSTALLED_DEPS+=("$pkg") || FAILED_DEPS+=("$pkg") ;;
        apt)     $ESC apt-get install -y "$pkg" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" && INSTALLED_DEPS+=("$pkg") || FAILED_DEPS+=("$pkg") ;;
    esac
done
# libasound2/libasound2t64 are alternates -- only warn if BOTH failed.
if printf '%s\n' "${FAILED_DEPS[@]:-}" | grep -qx "libasound2t64" && printf '%s\n' "${FAILED_DEPS[@]:-}" | grep -qx "libasound2"; then
    : # both failed, leave in FAILED_DEPS as-is for the warning below
else
    FAILED_DEPS=("${FAILED_DEPS[@]/libasound2t64/}")
    FAILED_DEPS=("${FAILED_DEPS[@]/libasound2/}")
fi
FAILED_DEPS=($(printf '%s\n' "${FAILED_DEPS[@]:-}" | sed '/^$/d'))
if [[ ${#FAILED_DEPS[@]} -gt 0 ]]; then
    warn "Could not install these Chrome runtime dependency packages: ${FAILED_DEPS[*]} -- Chrome may fail to launch. Check package names for your distro release (they get renamed across versions)."
fi

if [[ -d "$CHROME_INSTALL_DIR" ]]; then
    log "Backing up existing Chrome install: $CHROME_INSTALL_DIR -> ${CHROME_INSTALL_DIR}_bkp"
    $ESC rm -rf "${CHROME_INSTALL_DIR}_bkp"
    $ESC cp -r "$CHROME_INSTALL_DIR" "${CHROME_INSTALL_DIR}_bkp" \
        || warn "Could not back up $CHROME_INSTALL_DIR -- continuing anyway"
else
    log "No existing Chrome install found at $CHROME_INSTALL_DIR -- fresh install"
fi

if [[ -f "$CHROMEDRIVER_BIN" ]]; then
    log "Backing up existing chromedriver: $CHROMEDRIVER_BIN -> ${CHROMEDRIVER_BIN}_bkp"
    $ESC cp -f "$CHROMEDRIVER_BIN" "${CHROMEDRIVER_BIN}_bkp" \
        || warn "Could not back up $CHROMEDRIVER_BIN -- continuing anyway"
else
    log "No existing chromedriver found at $CHROMEDRIVER_BIN -- fresh install"
fi

cd "$SOURCE"

log "Looking up the newest published patch for build $CHROME_BUILD in the Chrome for Testing feed"
wget -q -O known_good_versions.json "$CFT_KNOWN_GOOD_URL" \
    || die "Failed to fetch $CFT_KNOWN_GOOD_URL"

# Pick the highest patch number under this build that has BOTH chrome and
# chromedriver linux64 downloads published -- not every patch gets published,
# so we resolve against what's actually there instead of guessing a digit.
CHROME_VERSION=$(jq -r --arg b "$CHROME_BUILD." '
    [.versions[]
     | select(.version | startswith($b))
     | select(.downloads.chrome != null)
     | select(.downloads.chromedriver != null)
     | select(any(.downloads.chrome[]?; .platform == "linux64"))
     | select(any(.downloads.chromedriver[]?; .platform == "linux64"))
     | .version]
    | sort_by(. | split(".") | map(tonumber))
    | last // empty
' known_good_versions.json)

[[ -n "$CHROME_VERSION" ]] \
    || die "No published patch for build $CHROME_BUILD (with both chrome and chromedriver linux64 downloads) was found in the Chrome for Testing known-good-versions feed."

log "Resolved build $CHROME_BUILD -> version $CHROME_VERSION"

CHROME_URL=$(jq -r --arg v "$CHROME_VERSION" \
    '.versions[] | select(.version == $v) | .downloads.chrome[]? | select(.platform == "linux64") | .url' \
    known_good_versions.json | head -1)

CHROMEDRIVER_URL=$(jq -r --arg v "$CHROME_VERSION" \
    '.versions[] | select(.version == $v) | .downloads.chromedriver[]? | select(.platform == "linux64") | .url' \
    known_good_versions.json | head -1)

[[ -n "$CHROME_URL" && "$CHROME_URL" != "null" ]] \
    || die "Chrome version $CHROME_VERSION was not found in the Chrome for Testing known-good-versions feed."
[[ -n "$CHROMEDRIVER_URL" && "$CHROMEDRIVER_URL" != "null" ]] \
    || die "ChromeDriver version $CHROME_VERSION was not found in the Chrome for Testing known-good-versions feed."

log "Resolved Chrome download: $CHROME_URL"
log "Resolved ChromeDriver download: $CHROMEDRIVER_URL"

CHROME_ZIP="chrome-linux64.zip"
wget -N -O "$CHROME_ZIP" "$CHROME_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
    || die "Failed to download Chrome from $CHROME_URL"

rm -rf "$SOURCE/chrome-linux64"
unzip -o "$CHROME_ZIP" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
    || die "Failed to unzip $CHROME_ZIP"

CHROME_SRC_DIR="$SOURCE/chrome-linux64"
[[ -d "$CHROME_SRC_DIR" ]] || die "Expected Chrome directory not found at $CHROME_SRC_DIR after unzip"

$ESC rm -rf "$CHROME_INSTALL_DIR"
$ESC mkdir -p "$(dirname "$CHROME_INSTALL_DIR")"
$ESC cp -r "$CHROME_SRC_DIR" "$CHROME_INSTALL_DIR" \
    || die "Failed to install Chrome to $CHROME_INSTALL_DIR"
$ESC chmod +x "$CHROME_INSTALL_DIR/chrome"

$ESC ln -sf "$CHROME_INSTALL_DIR/chrome" "$CHROME_BIN_LINK"

command -v google-chrome >/dev/null 2>&1 || die "google-chrome not found on PATH after install -- check that $CHROME_BIN_LINK is on PATH"

CHROME_VERSION_RAW=$(google-chrome --version)
INSTALLED_CHROME_VERSION=$(echo "$CHROME_VERSION_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[[ -n "$INSTALLED_CHROME_VERSION" ]] || die "Could not parse Chrome version out of: $CHROME_VERSION_RAW"

log "Chrome installed: $CHROME_VERSION_RAW"

CHROMEDRIVER_ZIP="chromedriver-linux64.zip"
wget -N -O "$CHROMEDRIVER_ZIP" "$CHROMEDRIVER_URL" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
    || die "Failed to download ChromeDriver from $CHROMEDRIVER_URL"

rm -rf "$SOURCE/chromedriver-linux64"
unzip -o "$CHROMEDRIVER_ZIP" >> "$ACCESS_LOG" 2>> "$ERROR_LOG" \
    || die "Failed to unzip $CHROMEDRIVER_ZIP"

CHROMEDRIVER_SRC="$SOURCE/chromedriver-linux64/chromedriver"
[[ -f "$CHROMEDRIVER_SRC" ]] || die "Expected chromedriver binary not found at $CHROMEDRIVER_SRC after unzip"

log "Installing chromedriver to $CHROMEDRIVER_BIN"
$ESC cp -f "$CHROMEDRIVER_SRC" "$CHROMEDRIVER_BIN" \
    || die "Failed to copy chromedriver to $CHROMEDRIVER_BIN"
$ESC chmod +x "$CHROMEDRIVER_BIN"

command -v chromedriver >/dev/null 2>&1 || die "chromedriver not found on PATH after install -- check that $CHROMEDRIVER_BIN is on PATH"

CHROMEDRIVER_VERSION_RAW=$(chromedriver --version)
INSTALLED_CHROMEDRIVER_VERSION=$(echo "$CHROMEDRIVER_VERSION_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[[ -n "$INSTALLED_CHROMEDRIVER_VERSION" ]] || die "Could not parse ChromeDriver version out of: $CHROMEDRIVER_VERSION_RAW"

log "ChromeDriver installed: $CHROMEDRIVER_VERSION_RAW"

if [[ "$INSTALLED_CHROME_VERSION" == "$CHROME_VERSION" && "$INSTALLED_CHROMEDRIVER_VERSION" == "$CHROME_VERSION" ]]; then
    log "SUCCESS: Chrome and ChromeDriver are both installed at the requested version ($CHROME_VERSION)."
else
    die "Version mismatch after install: requested=$CHROME_VERSION, Chrome=$INSTALLED_CHROME_VERSION, ChromeDriver=$INSTALLED_CHROMEDRIVER_VERSION. Check $ERROR_LOG."
fi

echo
echo "=================================================================="
echo " Google Chrome  : $CHROME_VERSION_RAW"
echo " ChromeDriver   : $CHROMEDRIVER_VERSION_RAW"
echo " Chrome path    : $(command -v google-chrome)"
echo " Driver path    : $CHROMEDRIVER_BIN"
echo " Backups        : ${CHROME_INSTALL_DIR}_bkp , ${CHROMEDRIVER_BIN}_bkp"
echo "=================================================================="

