#!/bin/zsh
# Optional: install fanctl as a root setuid helper so FanDial can change
# fan speed without showing the admin-password dialog on every adjustment.
#
#   sudo ./install-helper.sh
#
# Security note: this makes /usr/local/bin/fanctl run as root for any local
# user. fanctl only accepts fixed commands (status/set/max/auto) and clamps
# targets to the SMC's own [min, max] envelope, so the surface is tiny —
# but it's still a setuid binary; skip this if that bothers you.
#
# Remove with:  sudo rm /usr/local/bin/fanctl
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" != "0" ]; then
    echo "run as root:  sudo ./install-helper.sh" >&2
    exit 1
fi
if [ ! -x fanctl ]; then
    echo "fanctl not built — run ./build.sh first" >&2
    exit 1
fi

mkdir -p /usr/local/bin
install -o root -g wheel -m 4755 fanctl /usr/local/bin/fanctl
echo "✓ installed /usr/local/bin/fanctl (setuid root)"
echo "  FanDial will now apply changes silently. Remove with: sudo rm /usr/local/bin/fanctl"
