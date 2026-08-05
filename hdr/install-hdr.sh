#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# Enable HDR in Steam game mode on the ONEXPLAYER X2Mini PRO.
#
# The panel and the kernel are both ready: the EDID advertises BT2020RGB +
# SMPTE ST2084 at 1107 nits, and the eDP-1 connector exposes HDR_OUTPUT_METADATA
# and Colorspace. The only missing piece is that gamescope is never launched
# with --hdr-enabled -- the stock session script does not pass it, and gamescope
# has no environment variable equivalent, so the flag has to go on the command
# line.
#
# Rather than edit the packaged /usr/lib/steamos/gamescope-session (which a
# gamescope-session-cachyos update would overwrite), this derives a patched copy
# and points a systemd drop-in at it. Re-run after a session package update so
# the copy picks up upstream changes.
#
# Uninstall:
#   sudo rm -rf /etc/systemd/user/gamescope-session.service.d/10-x2mini-hdr.conf
#   sudo rm -f /usr/local/lib/steamos/gamescope-session-hdr
#   systemctl --user daemon-reload

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOCK=/usr/lib/steamos/gamescope-session
PATCHED=/usr/local/lib/steamos/gamescope-session-hdr
DROPIN_DIR=/etc/systemd/user/gamescope-session.service.d
DROPIN="$DROPIN_DIR/10-x2mini-hdr.conf"

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

[[ -r "$STOCK" ]] || { echo "missing $STOCK -- is gamescope-session installed?" >&2; exit 1; }

# --- sanity: does the display actually support HDR? ------------------------
say "Checking display HDR capability"
# NB: capture to a variable rather than piping into `grep -q`. Under
# `set -o pipefail`, grep -q exits at the first match, the producer takes
# SIGPIPE, and the pipeline reports 141 -- a race that fails intermittently.
if command -v edid-decode >/dev/null && [[ -r /sys/class/drm/card1-eDP-1/edid ]]; then
	edid_out="$(edid-decode /sys/class/drm/card1-eDP-1/edid 2>/dev/null || true)"
	if [[ "$edid_out" == *"SMPTE ST2084"* ]]; then
		note "panel advertises SMPTE ST2084 (PQ) - good"
	else
		note "WARNING: panel EDID does not advertise ST2084; HDR may not engage"
	fi
fi

modetest_out="$($SUDO modetest -M amdgpu -c 2>/dev/null || true)"
if [[ "$modetest_out" == *"HDR_OUTPUT_METADATA"* ]]; then
	note "connector exposes HDR_OUTPUT_METADATA - good"
else
	note "WARNING: no HDR_OUTPUT_METADATA property on any connector"
fi

# --- display script ---------------------------------------------------------
# gamescope only advertises HDR for panels present in its known_displays table.
# --hdr-enabled alone is not sufficient; without a matching entry Steam shows no
# HDR toggle at all. /etc/gamescope/scripts is scanned after gamescope's own
# bundled directory, so this survives package updates.
say "Installing display script"
$SUDO install -Dm644 "$SRC/scripts/onexplayer.x2mini.oled.lua" \
	/etc/gamescope/scripts/onexplayer.x2mini.oled.lua
note "/etc/gamescope/scripts/onexplayer.x2mini.oled.lua"

# --- derive the patched session script -------------------------------------
say "Deriving patched session script"

if grep -q -- "--hdr-enabled" "$STOCK"; then
	note "upstream now passes --hdr-enabled itself; no patch needed"
	note "removing our override so the packaged script is used directly"
	$SUDO rm -f "$DROPIN" "$PATCHED"
	systemctl --user daemon-reload 2>/dev/null || true
	exit 0
fi

$SUDO mkdir -p "$(dirname "$PATCHED")"

# Two edits:
#   1. --hdr-enabled as the first gamescope argument.
#   2. The two STEAM_GAMESCOPE_*HDR*_DEFAULT exports that tell Steam to default
#      HDR on. Upstream gates these on board_name = "Galileo" (Steam Deck OLED),
#      so they never apply here despite this being a comparable HDR OLED panel.
#      Without them Steam treats HDR as available-but-off.
$SUDO awk '
	/^exec gamescope \\$/ {
		print "# Added for the X2Mini PRO: upstream sets these for Galileo only."
		print "export STEAM_GAMESCOPE_FORCE_HDR_DEFAULT=1"
		print "export STEAM_GAMESCOPE_FORCE_OUTPUT_TO_HDR10PQ_DEFAULT=1"
		print ""
		print
		print "\t--hdr-enabled \\"
		next
	}
	{print}
' "$STOCK" | $SUDO tee "$PATCHED" >/dev/null
$SUDO chmod 755 "$PATCHED"

grep -q -- "--hdr-enabled" "$PATCHED" || {
	echo "patch did not apply -- the 'exec gamescope \\' line may have changed" >&2
	echo "inspect $STOCK and add --hdr-enabled by hand" >&2
	exit 1
}
bash -n "$PATCHED" || { echo "patched script has a syntax error, aborting" >&2; exit 1; }
note "wrote $PATCHED"

# --- systemd drop-in --------------------------------------------------------
say "Installing systemd drop-in"
$SUDO mkdir -p "$DROPIN_DIR"
$SUDO tee "$DROPIN" >/dev/null <<EOF
# Point the gamescope session at a copy patched to pass --hdr-enabled.
# Installed by onexplayer-x2-mini; see docs/hdr.md in that repo for why.
[Service]
ExecStart=
ExecStart=$PATCHED
EOF
note "wrote $DROPIN"

systemctl --user daemon-reload 2>/dev/null || true

say "Done"
note "Takes effect on the next session restart:"
note "  systemctl --user restart gamescope-session.target"
note "  (the .service sets RefuseManualStart=yes; restart the target)"
note ""
note "Then: Settings > Display for the HDR toggle -- not the Quick Access menu."
note "HDR now defaults to ON, matching Steam Deck OLED behaviour."
note "Re-run this after a gamescope-session-cachyos update."
