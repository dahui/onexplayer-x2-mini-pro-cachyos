#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# Build and install oxp-tdpd, the TDP backend that steamos-manager proxies
# Steam's TDP slider to. See docs/tdpd.md for why this exists.
#
# Uninstall:
#   sudo systemctl disable --now oxp-tdpd
#   sudo rm -f /usr/bin/oxp-tdpd \
#              /etc/systemd/system/oxp-tdpd.service \
#              /etc/steamos-manager/remotes.d/oxp-tdpd.toml \
#              /usr/share/dbus-1/system.d/io.aletheia.OxpTdp1.conf
#   sudo systemctl daemon-reload && sudo systemctl restart steamos-manager

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# --- preflight -------------------------------------------------------------
say "Preflight"

command -v go >/dev/null || { echo "go toolchain not found" >&2; exit 1; }

if [[ ! -e /sys/kernel/ryzen_smu_drv/mp1_smu_cmd ]]; then
	echo "ryzen_smu is not loaded." >&2
	echo "Install the amkillam fork (the leogx9r one lacks Strix Halo support):" >&2
	echo "  paru -S ryzen_smu-dkms-git && sudo modprobe ryzen_smu" >&2
	exit 1
fi
note "ryzen_smu present"

if [[ -e /sys/kernel/ryzen_smu_drv/pm_table ]]; then
	note "PM table available - read-back will report real hardware state"
else
	note "WARNING: no PM table. Read-back will fall back to the last applied value."
	note "         See ../ryzen-smu/ for the patch adding this firmware's table version."
fi

# --- build -----------------------------------------------------------------
say "Building"
( cd "$SRC" && go build -trimpath -ldflags=-s -o "$SRC/oxp-tdpd" . )
note "built $SRC/oxp-tdpd"

# --- install ---------------------------------------------------------------
say "Installing"
# /usr/bin, not /usr/local/bin: the packaged path (packaging/oxp-tdpd-bin) must
# match, or a user who installs both ends up with two binaries and a unit
# pointing at whichever was written last.
$SUDO install -Dm755 "$SRC/oxp-tdpd" /usr/bin/oxp-tdpd
note "/usr/bin/oxp-tdpd"

# Clear the pre-0.1.0 location so a stale copy cannot shadow the new one.
if [[ -e /usr/local/bin/oxp-tdpd ]]; then
	$SUDO rm -f /usr/local/bin/oxp-tdpd
	note "removed stale /usr/local/bin/oxp-tdpd"
fi

$SUDO install -Dm644 "$SRC/contrib/io.aletheia.OxpTdp1.conf" \
	/usr/share/dbus-1/system.d/io.aletheia.OxpTdp1.conf
note "/usr/share/dbus-1/system.d/io.aletheia.OxpTdp1.conf"

$SUDO install -Dm644 "$SRC/contrib/oxp-tdpd.service" \
	/etc/systemd/system/oxp-tdpd.service
note "/etc/systemd/system/oxp-tdpd.service"

# Never clobber an edited config.
if [[ -e /etc/oxp-tdpd.conf ]]; then
	note "/etc/oxp-tdpd.conf exists, leaving it alone"
else
	$SUDO install -Dm644 "$SRC/contrib/oxp-tdpd.conf" /etc/oxp-tdpd.conf
	note "/etc/oxp-tdpd.conf"
fi

$SUDO install -Dm644 "$SRC/contrib/remotes.d/oxp-tdpd.toml" \
	/etc/steamos-manager/remotes.d/oxp-tdpd.toml
note "/etc/steamos-manager/remotes.d/oxp-tdpd.toml"

# --- start -----------------------------------------------------------------
say "Starting"
$SUDO systemctl daemon-reload
$SUDO systemctl enable oxp-tdpd
# restart, not `enable --now`: that is a no-op when the service is already
# running, which silently leaves the previous binary in place on a reinstall.
$SUDO systemctl restart oxp-tdpd
sleep 2

if ! systemctl is-active --quiet oxp-tdpd; then
	echo "oxp-tdpd failed to start:" >&2
	journalctl -u oxp-tdpd -n 20 --no-pager >&2
	exit 1
fi
note "oxp-tdpd active"

# steamos-manager binds the remote at startup, so it needs a restart to notice
# a newly installed registration.
say "Restarting steamos-manager to pick up the registration"
$SUDO systemctl restart steamos-manager
if systemctl --user is-active --quiet steamos-manager 2>/dev/null; then
	systemctl --user restart steamos-manager
fi
sleep 3

# --- verify ----------------------------------------------------------------
say "Result"
note "daemon:  $(systemctl is-active oxp-tdpd)"

if out=$(steamosctl get-tdp-limit 2>&1); then
	note "steamosctl get-tdp-limit -> $out"
else
	note "WARNING: steamosctl get-tdp-limit failed: $out"
	note "         check 'journalctl -u steamos-manager -n 30'"
fi

for prop in TdpLimit TdpLimitMin TdpLimitMax; do
	v=$($SUDO busctl --system get-property io.aletheia.OxpTdp1 /io/aletheia/OxpTdp1 \
		com.steampowered.SteamOSManager1.TdpLimit1 "$prop" 2>/dev/null || echo "?")
	note "$prop = $v"
done

say "Done"
note "Set a limit with: steamosctl set-tdp-limit <watts>"
note "Inspect hardware state with: sudo oxp-tdpd --status"
