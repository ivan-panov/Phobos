#!/usr/bin/env bash
# Compatibility wrapper with a clearer name. The original script name is kept
# because older installs may call it directly. This kill-switch is applied on
# VPS1 and blocks direct wg0 -> VPS1 WAN forwarding, leaving only the path
# VPS1 -> Xray -> VPS2 Remnawave.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
exec "$SCRIPT_DIR/phobos-vps2-killswitch.sh" "$@"
