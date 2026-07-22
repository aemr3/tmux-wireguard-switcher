#!/usr/bin/env bash

WG_DIR="${WG_DIR:-/opt/homebrew/etc/wireguard}"
WG_RUN_DIR="${WG_RUN_DIR:-/var/run/wireguard}"
WG_QUICK="${WG_QUICK:-/opt/homebrew/bin/wg-quick}"
WG_LOG_DIR="${WG_LOG_DIR:-/var/log/tmux-wireguard-switcher}"
WG_LOG_LEVEL="${WG_LOG_LEVEL:-debug}"
WG_DIR="${WG_DIR/#\~/$HOME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tmux popups have no TTY, so sudo's password prompt would hang. Two paths
# work without a TTY: Touch ID via pam_tid (if configured), or osascript's
# GUI auth dialog. Pick sudo only if all three are true:
#   1. pam_tid.so is in sudo's PAM stack
#   2. pam_reattach.so is too (so the Touch ID prompt surfaces from tmux's
#      launchd namespace)
#   3. at least one fingerprint is enrolled (otherwise pam_tid always fails
#      and sudo falls through to password — which dies without a TTY)
# Anything else falls back to osascript.
has_touchid_sudo() {
  local pam
  pam=$(cat /etc/pam.d/sudo_local /etc/pam.d/sudo 2>/dev/null)
  [ -n "$pam" ] || return 1
  grep -qE '^[[:space:]]*[^#[:space:]].*pam_reattach\.so' <<<"$pam" || return 1
  grep -qE '^[[:space:]]*[^#[:space:]].*pam_tid\.so'      <<<"$pam" || return 1
  bioutil -c 2>/dev/null | grep -qE '^User [0-9]+:[[:space:]]*[1-9]'
}

# priv "<shell command>" prints a shell command that runs the inner command
# as root with a single auth event. PRIV_METHOD records which path we took:
# the osascript path routes tunnels through launchd (see wg_up/wg_down) to
# survive authtrampoline's idle-reap; the sudo path is unaffected and runs
# wg-quick directly.
PRIV_METHOD="osascript"
if has_touchid_sudo; then
  PRIV_METHOD="sudo"
  priv() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"; s="${s//\`/\\\`}"
    printf 'sudo /bin/sh -c "%s"' "$s"
  }
else
  priv() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    local a='do shell script "'"$s"'" with administrator privileges'
    a="${a//\\/\\\\}"; a="${a//\"/\\\"}"
    a="${a//\$/\\\$}"; a="${a//\`/\\\`}"
    printf 'osascript -e "%s"' "$a"
  }
fi

# Wrap an inner command in a tmux menu action: echo the command to tmux's
# status line, then run it privileged. The status echo previews what's about
# to be authenticated since the system auth dialog can't be customised.
# Output is silenced so wg-quick's progress lines don't pop a tmux output
# window; failures still surface as a "returned <code>" status message.
menu_action() {
  local inner="$1" disp="$1"
  disp="${disp//\\/\\\\}"; disp="${disp//\"/\\\"}"
  disp="${disp//\$/\\\$}"; disp="${disp//\`/\\\`}"
  printf "run-shell -b 'tmux display-message \"%s\"; %s >/dev/null 2>&1'" "$disp" "$(priv "$inner")"
}

# On the osascript path, hand tunnel up/down to the launchd helper (which runs
# wg-quick under a launchd job so authtrampoline's idle-reap can't kill it).
# The helper needs the resolved paths, but osascript runs as root with root's
# environment, so pass them explicitly rather than relying on inheritance.
wg_launchd() {
  printf 'WG_DIR=%s WG_QUICK=%s WG_RUN_DIR=%s WG_LOG_DIR=%s WG_LOG_LEVEL=%s /bin/sh %s/wg-launchd.sh %s %s' \
    "$WG_DIR" "$WG_QUICK" "$WG_RUN_DIR" "$WG_LOG_DIR" "$WG_LOG_LEVEL" "$SCRIPT_DIR" "$1" "$2"
}

# Normal wg-quick down if the interface is live; if it's already gone (tunnel
# dropped on its own, .name left behind) just clear the stale .name file so it
# can't wedge disconnect or block a switch.
wg_down() {
  if [ "$PRIV_METHOD" = osascript ]; then
    wg_launchd down "$1"
  else
    printf 'if ifconfig "$(cat %s/%s.name 2>/dev/null)" >/dev/null 2>&1; then %s down %s; else rm -f %s/%s.name; fi' \
      "$WG_RUN_DIR" "$1" "$WG_QUICK" "$WG_DIR/$1.conf" "$WG_RUN_DIR" "$1"
  fi
}

wg_up() {
  if [ "$PRIV_METHOD" = osascript ]; then
    wg_launchd up "$1"
  else
    printf '%s up %s' "$WG_QUICK" "$WG_DIR/$1.conf"
  fi
}

shopt -s nullglob
confs=("$WG_DIR"/*.conf)
shopt -u nullglob

tunnels=()
for c in "${confs[@]}"; do
  tunnels+=("$(basename "$c" .conf)")
done

if [ ${#tunnels[@]} -eq 0 ]; then
  tmux display-menu -T "#[align=centre fg=red]WireGuard" -x C -y C \
    "No .conf files in $WG_DIR" "" "" "" "Close" q ""
  exit 0
fi

shopt -s nullglob
name_files=("$WG_RUN_DIR"/*.name)
shopt -u nullglob
active=()
for f in "${name_files[@]}"; do
  active+=("$(basename "$f" .name)")
done

is_active() {
  local t="$1"
  for a in "${active[@]}"; do [ "$a" = "$t" ] && return 0; done
  return 1
}

declare -a VAR
for i in "${!tunnels[@]}"; do
  name="${tunnels[i]}"
  key=$((i + 1))
  if is_active "$name"; then
    VAR+=("● $name  (disconnect)" "$key" "$(menu_action "$(wg_down "$name")")")
  elif [ ${#active[@]} -gt 0 ]; then
    current="${active[0]}"
    VAR+=("  $name" "$key" "$(menu_action "$(wg_down "$current"); $(wg_up "$name")")")
  else
    VAR+=("  $name" "$key" "$(menu_action "$(wg_up "$name")")")
  fi
done

if [ ${#active[@]} -gt 0 ]; then
  header="Active: $(IFS=,; echo "${active[*]}")"
  inner=""
  for a in "${active[@]}"; do inner+="$(wg_down "$a"); "; done
  inner+="true"
  disconnect_item=("Disconnect all" "d" "$(menu_action "$inner")")
else
  header="Active: none"
  disconnect_item=("-#[dim]No active tunnel" "" "")
fi

tmux display-menu \
  -T "#[align=centre fg=green]WireGuard tunnel switcher" -x C -y C \
  "#[nodim]$header" "" "" \
  "" \
  "${VAR[@]}" \
  "" \
  "${disconnect_item[@]}" \
  "Close menu" q ""
