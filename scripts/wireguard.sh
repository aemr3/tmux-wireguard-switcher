#!/usr/bin/env bash

WG_DIR="${WG_DIR:-/opt/homebrew/etc/wireguard}"
WG_RUN_DIR="${WG_RUN_DIR:-/var/run/wireguard}"
WG_QUICK="${WG_QUICK:-/opt/homebrew/bin/wg-quick}"
WG_DIR="${WG_DIR/#\~/$HOME}"

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
    VAR+=("● $name  (disconnect)" "$key" "run-shell -b 'sudo $WG_QUICK down $WG_DIR/$name.conf'")
  elif [ ${#active[@]} -gt 0 ]; then
    current="${active[0]}"
    VAR+=("  $name" "$key" "run-shell -b 'sudo $WG_QUICK down $WG_DIR/$current.conf && sudo $WG_QUICK up $WG_DIR/$name.conf'")
  else
    VAR+=("  $name" "$key" "run-shell -b 'sudo $WG_QUICK up $WG_DIR/$name.conf'")
  fi
done

if [ ${#active[@]} -gt 0 ]; then
  header="Active: $(IFS=,; echo "${active[*]}")"
  disconnect_cmd="run-shell -b '"
  for a in "${active[@]}"; do disconnect_cmd+="sudo $WG_QUICK down $WG_DIR/$a.conf; "; done
  disconnect_cmd+="true'"
  disconnect_item=("Disconnect all" "d" "$disconnect_cmd")
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
