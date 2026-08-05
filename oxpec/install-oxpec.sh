#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# Build and install the patched oxpec driver via DKMS so it survives kernel
# updates. Gives the ONEXPLAYER X2Mini PRO fan monitoring, PWM control, the
# turbo-button toggle, and a battery charge limit.
#
# It does NOT give TDP control -- oxpec has no TDP support at all. See docs/oxpec.md.
#
# Uninstall:  sudo dkms remove -m oxpec-x2mini -v 1.0 --all
#             (that restores the stock oxpec.ko DKMS archived on install)

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER=1.0
NAME=oxpec-x2mini
SRCDIR="/usr/src/$NAME-$VER"

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# --- preflight -------------------------------------------------------------
BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
case "$BOARD" in
	"ONEXPLAYER X2Mini"*) ;;
	*)
		echo "Expected an ONEXPLAYER X2Mini board; this reports: $BOARD" >&2
		echo "The patch hardcodes the board name -- edit src/oxpec.c first." >&2
		[[ "${FORCE:-0}" == "1" ]] || exit 1
		;;
esac

command -v dkms >/dev/null || { echo "dkms not installed: pacman -S dkms" >&2; exit 1; }
[[ -d /usr/lib/modules/$(uname -r)/build ]] || {
	echo "kernel headers missing for $(uname -r)" >&2; exit 1; }

# --- stage source ----------------------------------------------------------
say "Staging patched source into $SRCDIR"
$SUDO rm -rf "$SRCDIR"
$SUDO mkdir -p "$SRCDIR"
# dkms.conf is a real file rather than generated here, so this script and
# packaging/oxpec-x2mini-dkms/PKGBUILD stage byte-identical sources.
$SUDO cp "$SRC/src/oxpec.c" "$SRC/src/Makefile" "$SRC/src/dkms.conf" "$SRCDIR/"
note "staged"

# --- build + install -------------------------------------------------------
say "Building"
$SUDO dkms remove -m "$NAME" -v "$VER" --all >/dev/null 2>&1 || true
$SUDO dkms add    -m "$NAME" -v "$VER" 2>&1 | grep -v Deprecated || true
$SUDO dkms build  -m "$NAME" -v "$VER" 2>&1 | tail -2
$SUDO dkms install -m "$NAME" -v "$VER" --force 2>&1 | grep -viE "deprecated" | tail -3

# --- load ------------------------------------------------------------------
say "Loading"
$SUDO modprobe -r oxpec 2>/dev/null || true
$SUDO modprobe oxpec

note "loaded from: $($SUDO modinfo -F filename oxpec)"

# --- verify ----------------------------------------------------------------
say "Result"
HW=""
for h in /sys/class/hwmon/hwmon*; do
	[[ "$(cat "$h/name" 2>/dev/null)" == "oxp_ec" ]] && HW="$h"
done

if [[ -n "$HW" ]]; then
	note "EC hwmon:    $HW (oxp_ec)"
	note "  fan1_input   = $(cat "$HW/fan1_input" 2>/dev/null || echo n/a) rpm"
	note "  pwm1         = $(cat "$HW/pwm1" 2>/dev/null || echo n/a)"
	note "  pwm1_enable  = $(cat "$HW/pwm1_enable" 2>/dev/null || echo n/a)"
else
	note "WARNING: no oxp_ec hwmon -- driver did not bind. Check 'dmesg | tail'."
fi

CCT=/sys/class/power_supply/BATT/charge_control_end_threshold
[[ -r "$CCT" ]] && note "charge limit: $(cat "$CCT")%" \
                || note "WARNING: no charge_control_end_threshold"

TT=/sys/devices/platform/oxp-platform/tt_toggle
[[ -r "$TT" ]] && note "tt_toggle:    $(cat "$TT")"

say "Done"
note "Auto-loads at boot: the DMI modalias now resolves to oxpec."
note "Enable the charge limit in the Steam UI by (re)installing the device"
note "config -- ../install.sh -- which declares [battery_charge_limit]."
