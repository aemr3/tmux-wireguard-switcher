# tmux-wireguard-switcher

Tmux plugin that lets you start, stop, and switch WireGuard tunnels from a
popup menu, plus a status-line indicator showing the active tunnel.

macOS + Homebrew + `wireguard-tools` + nerd-font terminal.

## Install

### 1. Required packages

```sh
brew install wireguard-tools
```

### 2. Privilege escalation

The popup runs `wg-quick up/down`, which needs root. Tmux popups have no
TTY, so plain `sudo` would hang on the password prompt. The plugin auto-
detects which TTY-less path to use:

- **Touch ID via sudo** if `pam_tid.so` is in your sudo PAM stack. Pops the
  Touch ID sheet (or strip on Magic Keyboards). Recommended for laptops.
- **macOS auth dialog** otherwise. Pops the system "<app> wants to make
  changes" dialog. Works on any Mac, including Mac minis without Touch ID.

To opt into the Touch ID path, install `pam-reattach` and create
`/etc/pam.d/sudo_local`:

```sh
brew install pam-reattach
```

```
auth       optional     /opt/homebrew/lib/pam/pam_reattach.so
auth       sufficient   pam_tid.so
```

`pam_reattach` is needed so the Touch ID prompt can surface from inside
tmux (tmux processes run in a different launchd bootstrap namespace by
default). The osascript fallback doesn't need `pam-reattach`.

### 3. Tunnel configs

Put your `.conf` files in `/opt/homebrew/etc/wireguard/` (mode `600`). You
can export them from the WireGuard GUI app (**File → Export Tunnels to
Zip…**) or extract from Keychain if the GUI was your only source.

### 4. Plugin

With [TPM](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'aemr3/tmux-wireguard-switcher'
```

Or manually in your `tmux.conf`:

```tmux
run '~/path/to/tmux-wireguard-switcher/tmux-wireguard-switcher.tmux'
```

### 5. Status-bar integration (optional)

```tmux
set -g status-right '#(~/path/to/tmux-wireguard-switcher/scripts/status.sh) | %H:%M '
```

Prints `󰖂 <tunnel>` when a tunnel is up, nothing otherwise.

## Usage

- `prefix + v` — open the popup
- Number keys — toggle a tunnel (up if down, switch if another is active)
- `d` — disconnect active tunnel
- `q` — close menu

## Environment overrides

| Var | Default |
| --- | --- |
| `WG_DIR` | `/opt/homebrew/etc/wireguard` |
| `WG_RUN_DIR` | `/var/run/wireguard` |
| `WG_QUICK` | `/opt/homebrew/bin/wg-quick` |
| `WG_STATUS_ICON` | `󰖂` (nerd-font `nf-md-vpn`) |

## How detection works

`wg-quick` creates `/var/run/wireguard/<tunnel>.name` files when a tunnel is
up. That directory is world-readable, so listing filenames tells us which
tunnels are active — no sudo, no `wg show` on the polling path.
