#!/usr/bin/env bash
#
# Emit the active WireGuard tunnel name for tmux status-right.
# Detects wg-quick tunnels via /var/run/wireguard/<name>.name
# (dir is world-readable; file contents are not — we only need the names).
# Prints nothing when no tunnel is up.

WG_RUN_DIR="${WG_RUN_DIR:-/var/run/wireguard}"
WG_STATUS_ICON="${WG_STATUS_ICON:-󰖂}"

shopt -s nullglob
names=("$WG_RUN_DIR"/*.name)
shopt -u nullglob
[ ${#names[@]} -eq 0 ] && exit 0

active=()
for f in "${names[@]}"; do
  active+=("$(basename "$f" .name)")
done

printf '%s %s' "$WG_STATUS_ICON" "$(IFS=,; echo "${active[*]}")"
