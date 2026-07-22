#!/bin/sh
#
# Root-side tunnel lifecycle for the osascript (no-Touch-ID) auth path.
#
# Why this exists: osascript's "with administrator privileges" runs commands
# through the temporary system helper com.apple.security.authtrampoline. Any
# process spawned down that chain — including wireguard-go — inherits the
# helper's jetsam coalition. macOS idle-reaps authtrampoline after a few
# minutes, and the coalition teardown takes wireguard-go with it: the utun
# detaches, routes vanish, and the tunnel silently dies while its .name file
# lingers. A process's coalition is fixed at spawn and cannot be changed by
# setsid/nohup/disown, so the only escape is to let a *different* launcher
# spawn the tunnel. We use authtrampoline for one fast `launchctl bootstrap`
# call; launchd then owns wireguard-go in its own coalition, and authtrampoline
# is free to idle-die without touching the tunnel.
#
# Invoked as root via wireguard.sh's priv() wrapper:
#   wg-launchd.sh up|down <tunnel>       (from the menu action)
#   wg-launchd.sh supervise <tunnel>     (as the launchd job itself)

set -u

WG_DIR="${WG_DIR:-/opt/homebrew/etc/wireguard}"
WG_QUICK="${WG_QUICK:-/opt/homebrew/bin/wg-quick}"
WG_RUN_DIR="${WG_RUN_DIR:-/var/run/wireguard}"
WG_LOG_DIR="${WG_LOG_DIR:-/var/log/tmux-wireguard-switcher}"
WG_LOG_LEVEL="${WG_LOG_LEVEL:-debug}"

# launchd only auto-loads /Library/LaunchDaemons at boot, so bootstrapping from
# a runtime dir keeps these jobs session-only: a reboot clears them and no
# tunnel auto-connects at startup, matching the manual switcher's intent.
PLIST_DIR="${WG_PLIST_DIR:-$WG_RUN_DIR/tmux-wireguard-switcher}"
LABEL_PREFIX="com.aemr3.tmux-wireguard-switcher"

cmd="${1:-}"
tunnel="${2:-}"
if [ -z "$cmd" ] || [ -z "$tunnel" ]; then
  echo "usage: wg-launchd.sh up|down|supervise <tunnel>" >&2
  exit 2
fi

label="$LABEL_PREFIX.$tunnel"
plist="$PLIST_DIR/$label.plist"
conf="$WG_DIR/$tunnel.conf"
log="$WG_LOG_DIR/$tunnel.log"
name_file="$WG_RUN_DIR/$tunnel.name"

# Absolute path to this script, so the generated plist can point back at it.
self="$0"
case "$self" in
  /*) ;;
  *) self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")" ;;
esac

# `launchctl bootout` returns before teardown finishes, so poll until the job
# is actually gone before we bootstrap over it or tear the tunnel down (a stale
# job with KeepAlive would otherwise re-up mid-teardown). Bounded (~5s) rather
# than `bootout --wait`, which the man page warns can block indefinitely.
wait_gone() {
  i=0
  while launchctl print "system/$1" >/dev/null 2>&1 && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

case "$cmd" in
  up)
    mkdir -p "$WG_LOG_DIR" "$PLIST_DIR"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$self</string>
    <string>supervise</string>
    <string>$tunnel</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>WG_DIR</key><string>$WG_DIR</string>
    <key>WG_QUICK</key><string>$WG_QUICK</string>
    <key>WG_RUN_DIR</key><string>$WG_RUN_DIR</string>
    <key>WG_LOG_DIR</key><string>$WG_LOG_DIR</string>
    <key>WG_LOG_LEVEL</key><string>$WG_LOG_LEVEL</string>
  </dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
EOF
    chown root:wheel "$plist" 2>/dev/null || true
    chmod 644 "$plist"
    # Clear any prior instance so bootstrap can't fail on an existing label.
    launchctl bootout "system/$label" 2>/dev/null || true
    wait_gone "$label"
    launchctl bootstrap system "$plist"
    ;;

  down)
    # Remove the job first, and wait for it to actually go, so KeepAlive can't
    # re-up the tunnel mid-teardown.
    launchctl bootout "system/$label" 2>/dev/null || true
    wait_gone "$label"
    status=0
    iface="$(cat "$name_file" 2>/dev/null || true)"
    if [ -n "$iface" ] && ifconfig "$iface" >/dev/null 2>&1; then
      # Report a failed teardown rather than deleting the plist and claiming
      # success over a tunnel that may still be up.
      "$WG_QUICK" down "$conf" >>"$log" 2>&1 || status=$?
    else
      # Interface already gone (dropped on its own) — just clear the stale
      # .name so it can't wedge a later disconnect or block a switch.
      rm -f "$name_file"
    fi
    rm -f "$plist"
    exit "$status"
    ;;

  supervise)
    # Runs as the launchd job. Bring the tunnel up, then block until its
    # interface disappears; exiting lets KeepAlive re-establish it. Because
    # launchd spawned us, wireguard-go lives in launchd's coalition and is
    # immune to authtrampoline's idle-reap.
    mkdir -p "$WG_LOG_DIR"
    # Clear any half-dead state left by a previous instance before re-upping.
    "$WG_QUICK" down "$conf" >>"$log" 2>&1 || true
    if ! LOG_LEVEL="$WG_LOG_LEVEL" "$WG_QUICK" up "$conf" >>"$log" 2>&1; then
      echo "$(date '+%Y-%m-%dT%H:%M:%S') wg-quick up failed for $tunnel" >>"$log"
      exit 1
    fi
    iface="$(cat "$name_file" 2>/dev/null || true)"
    if [ -z "$iface" ]; then
      echo "$(date '+%Y-%m-%dT%H:%M:%S') no interface recorded for $tunnel" >>"$log"
      exit 1
    fi
    while ifconfig "$iface" >/dev/null 2>&1; do
      sleep 15
    done
    echo "$(date '+%Y-%m-%dT%H:%M:%S') $iface ($tunnel) gone; exiting for restart" >>"$log"
    exit 0
    ;;

  *)
    echo "usage: wg-launchd.sh up|down|supervise <tunnel>" >&2
    exit 2
    ;;
esac
