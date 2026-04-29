#!/usr/bin/env bash

WG_DIR="${WG_DIR:-/opt/homebrew/etc/wireguard}"
WG_RUN_DIR="${WG_RUN_DIR:-/var/run/wireguard}"
WG_QUICK="${WG_QUICK:-/opt/homebrew/bin/wg-quick}"
WG_DIR="${WG_DIR/#\~/$HOME}"

# Tmux popups have no TTY, so sudo's password prompt would hang. Two paths
# work without a TTY: Touch ID via pam_tid (if configured), or osascript's
# GUI auth dialog. Detect which by looking for pam_tid in sudo's PAM stack.
has_touchid_sudo() {
  local f
  for f in /etc/pam.d/sudo_local /etc/pam.d/sudo; do
    [ -r "$f" ] || continue
    grep -qE '^[[:space:]]*[^#[:space:]].*pam_tid\.so' "$f" && return 0
  done
  return 1
}

# priv "<shell command>" prints a shell command that runs the inner command
# as root with a single auth event.
if has_touchid_sudo; then
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
menu_action() {
  local inner="$1" disp="$1"
  disp="${disp//\\/\\\\}"; disp="${disp//\"/\\\"}"
  disp="${disp//\$/\\\$}"; disp="${disp//\`/\\\`}"
  printf "run-shell -b 'tmux display-message \"%s\"; %s'" "$disp" "$(priv "$inner")"
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
    VAR+=("● $name  (disconnect)" "$key" "$(menu_action "$WG_QUICK down $WG_DIR/$name.conf")")
  elif [ ${#active[@]} -gt 0 ]; then
    current="${active[0]}"
    VAR+=("  $name" "$key" "$(menu_action "$WG_QUICK down $WG_DIR/$current.conf && $WG_QUICK up $WG_DIR/$name.conf")")
  else
    VAR+=("  $name" "$key" "$(menu_action "$WG_QUICK up $WG_DIR/$name.conf")")
  fi
done

if [ ${#active[@]} -gt 0 ]; then
  header="Active: $(IFS=,; echo "${active[*]}")"
  inner=""
  for a in "${active[@]}"; do inner+="$WG_QUICK down $WG_DIR/$a.conf; "; done
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
