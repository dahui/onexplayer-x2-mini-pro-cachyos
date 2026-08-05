#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# Apply the PM table 0x64010C patch to the installed ryzen_smu DKMS source and
# rebuild. Without it the driver refuses to expose pm_table on this firmware,
# which costs us TDP read-back and breaks ryzenadj entirely.
#
# This patches the AUR package's source tree in /usr/src, so a
# ryzen_smu-dkms-git update will revert it -- re-run this afterwards. The real
# fix is upstreaming 0001-ryzen_smu-add-pm-table-0x64010C.patch.
#
# Idempotent: detects an already-patched tree and does nothing.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$SRC/0001-ryzen_smu-add-pm-table-0x64010C.patch"

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# --- locate the DKMS source tree -------------------------------------------
mapfile -t trees < <(find /usr/src -maxdepth 1 -type d -name 'ryzen_smu-*' 2>/dev/null | sort)
if (( ${#trees[@]} == 0 )); then
	echo "No ryzen_smu DKMS source in /usr/src." >&2
	echo "Install the amkillam fork first: paru -S ryzen_smu-dkms-git" >&2
	exit 1
fi
if (( ${#trees[@]} > 1 )); then
	note "multiple ryzen_smu trees found; using the newest"
fi
TREE="${trees[-1]}"
VER="$(basename "$TREE" | sed 's/^ryzen_smu-//')"
note "source tree: $TREE (version $VER)"

# --- apply ------------------------------------------------------------------
say "Applying patch"
if grep -q "0x64010C" "$TREE/smu.c"; then
	note "already patched, nothing to do"
else
	# --forward so a partial re-run doesn't half-apply; keep a backup.
	$SUDO cp -n "$TREE/smu.c" "$TREE/smu.c.preptach" 2>/dev/null || true
	$SUDO patch -p1 -d "$TREE" --forward < "$PATCH"
	note "patched $TREE/smu.c"
fi

# --- rebuild ----------------------------------------------------------------
say "Rebuilding via DKMS"
$SUDO dkms remove "ryzen_smu/$VER" --all >/dev/null 2>&1 || true
$SUDO dkms install "ryzen_smu/$VER" 2>&1 | grep -viE "deprecated" | tail -3

say "Reloading"
$SUDO modprobe -r ryzen_smu 2>/dev/null || true
$SUDO modprobe ryzen_smu

# --- verify -----------------------------------------------------------------
say "Result"
note "codename: $(cat /sys/kernel/ryzen_smu_drv/codename 2>/dev/null || echo '?')  (26 = Strix Halo)"

if [[ -e /sys/kernel/ryzen_smu_drv/pm_table ]]; then
	ver=$($SUDO xxd -e -g4 -l4 /sys/kernel/ryzen_smu_drv/pm_table_version 2>/dev/null | awk '{print $2}')
	size=$($SUDO xxd -e -g4 -l4 /sys/kernel/ryzen_smu_drv/pm_table_size 2>/dev/null | awk '{print $2}')
	note "pm_table exposed: version=0x$ver size=0x$size"
	note "limits now readable:"
	# -w24 keeps all six floats on one line; od's default 16-byte width would
	# wrap after four and break the field positions.
	$SUDO od -A n -t f4 -N 24 -w24 /sys/kernel/ryzen_smu_drv/pm_table 2>/dev/null \
		| awk '{printf "      stapm=%.1fW fast=%.1fW slow=%.1fW\n", $1, $3, $5}'
else
	echo "pm_table still missing -- check 'dmesg | grep ryzen_smu' for the" >&2
	echo "reported table version; it may differ from 0x64010C on your firmware." >&2
	exit 1
fi

say "Done"
