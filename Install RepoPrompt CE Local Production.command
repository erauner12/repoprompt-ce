#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDUCTOR="$ROOT_DIR/conductor"
INSTALL_SCRIPT="$ROOT_DIR/Scripts/install_local_production.sh"
INSTALL_MODE="coordinated"

if ! command -v python3 >/dev/null 2>&1; then
    INSTALL_MODE="direct"
    if [[ ! -x "$INSTALL_SCRIPT" ]]; then
        echo "Python 3 isn't available, and the direct installer script is missing:"
        echo "$INSTALL_SCRIPT"
        echo
        echo "Make sure this file is still in the repoprompt-ce folder and that Scripts/install_local_production.sh is executable."
        read -r -p "Press Return to close this window..." || true
        exit 1
    fi
elif [[ ! -x "$CONDUCTOR" ]]; then
    echo "Couldn't find the coordinated installer:"
    echo "$CONDUCTOR"
    echo
    echo "Make sure this file is still in the repoprompt-ce folder and that conductor is executable."
    read -r -p "Press Return to close this window..." || true
    exit 1
fi

install_app() {
    echo
    echo "Building and installing RepoPrompt CE..."
    echo "macOS may ask you to approve the dedicated local code-signing certificate."
    echo
    if [[ "$INSTALL_MODE" == "coordinated" ]]; then
        CONFIRM_LOCAL_PRODUCTION_INSTALL=1 "$CONDUCTOR" release local-install
    else
        CONFIRM_LOCAL_PRODUCTION_INSTALL=1 "$INSTALL_SCRIPT"
    fi
}

clear 2>/dev/null || true
echo "RepoPrompt CE - local self-signed production installer"
echo
echo "Project: $ROOT_DIR"
if [[ "$INSTALL_MODE" == "coordinated" ]]; then
    echo "Mode:    coordinated (build and install run through the dev daemon)"
else
    echo "Mode:    direct (python3 unavailable - running without the dev daemon)"
fi
echo
echo "This installs a release-mode RepoPrompt CE.app under /Applications using a"
echo "dedicated self-signed certificate trusted only on this Mac."
echo
echo "The installed app is local-only: it is not notarized, must not be uploaded"
echo "to GitHub Releases, and should not be copied to another Mac."
echo

if ! IFS= read -r -p "Continue with the local production install? [y/N] " choice; then
    echo
    echo "Install canceled."
    exit 0
fi

case "$choice" in
    y | Y | yes | YES | Yes)
        ;;
    *)
        echo
        echo "Install canceled."
        exit 0
        ;;
esac

cd "$ROOT_DIR" || exit 1
if install_app; then
    echo
    echo "RepoPrompt CE local production app installed successfully."
else
    status=$?
    echo
    echo "RepoPrompt CE local production install failed."
    echo "Review the output above, then run this launcher again to retry."
    read -r -p "Press Return to close this window..." || true
    exit "$status"
fi

echo
read -r -p "Press Return to close this window..." || true
