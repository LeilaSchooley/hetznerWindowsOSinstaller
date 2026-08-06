#!/bin/bash
###############################################################################
# Bootstrap Loader - Windows Server 2025 Hetzner Installer
#
# ONE-LINER FOR USERS:
#   wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash
#
# Or with custom password:
#   wget -qO- https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install.sh | bash -s -- --password "MyPass123"
#
# This bootstrap script:
#   1. Downloads the main installer to /root/
#   2. Makes it executable
#   3. Launches it with any arguments passed through
#
# The user only needs PuTTY SSH — no SCP, no file uploads.
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Windows Server 2025 - Hetzner Automated Installer        ║"
echo "║   Bootstrap Loader                                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Configuration ───────────────────────────────────────────────
# Installer source URL.
# Options:
#   - GitHub contents API: https://api.github.com/repos/YOU/REPO/contents/install-windows.sh?ref=main
#   - GitHub raw URL fallback: https://raw.githubusercontent.com/YOU/REPO/main/install-windows.sh
#   - Any direct URL: https://your-domain.com/install-windows.sh
INSTALLER_API_URL="https://api.github.com/repos/LeilaSchooley/hetznerWindowsOSinstaller/contents/install-windows.sh?ref=main"
INSTALLER_RAW_URL="https://raw.githubusercontent.com/LeilaSchooley/hetznerWindowsOSinstaller/main/install-windows.sh"
# ─────────────────────────────────────────────────────────────────

INSTALL_DIR="/root"
INSTALLER_PATH="${INSTALL_DIR}/install-windows.sh"

# Check we're root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root."
    exit 1
fi

echo -e "${GREEN}[1/3]${NC} Downloading installer..."
download_via_github_api() {
    python3 - "$INSTALLER_PATH" "$INSTALLER_API_URL" <<'PY'
import base64
import json
import sys
import urllib.request

output_path, api_url = sys.argv[1], sys.argv[2]
request = urllib.request.Request(api_url, headers={"User-Agent": "hetzner-windows-installer-bootstrap"})
with urllib.request.urlopen(request, timeout=30) as response:
    payload = json.load(response)

content = payload.get("content", "")
if not content:
    raise SystemExit("Missing content in GitHub API response")

decoded = base64.b64decode(content)
with open(output_path, "wb") as handle:
    handle.write(decoded)
PY
}

download_via_raw_url() {
    if command -v wget &>/dev/null; then
        wget -q -O "$INSTALLER_PATH" "$INSTALLER_RAW_URL"
        return
    fi

    if command -v curl &>/dev/null; then
        curl -fsSL -o "$INSTALLER_PATH" "$INSTALLER_RAW_URL"
        return
    fi

    echo -e "${RED}[ERROR]${NC} Neither wget nor curl found."
    exit 1
}

if command -v python3 &>/dev/null; then
    if ! download_via_github_api; then
        echo -e "${CYAN}[INFO]${NC} GitHub API download failed, falling back to raw URL..."
        download_via_raw_url
    fi
else
    download_via_raw_url
fi

if [ ! -s "$INSTALLER_PATH" ]; then
    echo -e "${RED}[ERROR]${NC} Download failed or file is empty."
    exit 1
fi

echo -e "${GREEN}[2/3]${NC} Setting permissions..."
chmod +x "$INSTALLER_PATH"

echo -e "${GREEN}[3/3]${NC} Launching installer..."
echo ""

# Warn if --interactive is used with piped stdin (reads will fail)
for arg in "$@"; do
    if [ "$arg" = "--interactive" ] || [ "$arg" = "-i" ]; then
        if [ ! -t 0 ]; then
            echo -e "${RED}[ERROR]${NC} --interactive requires a terminal. Download first, then run:"
            echo -e "  bash $INSTALLER_PATH --interactive"
            exit 1
        fi
    fi
done

# Pass through any command-line arguments
exec bash "$INSTALLER_PATH" "$@"
