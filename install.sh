#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# ONEXPLAYER X2Mini PRO enablement -- installs packages, nothing by hand.
#
# Everything ships as a pacman package, so this script installs those and gets
# out of the way. It deliberately does NOT copy configuration into place itself:
# those files are owned by onexplayer-x2mini, and writing them separately would
# leave pacman reporting them as modified and the two paths free to drift.
#
#   onexplayer-x2mini        AUR   configs; pulls in everything below
#     steamos-manager        repo  TDP slider, performance profiles
#     inputplumber           repo  button mapping
#     oxp-tdpd-bin           AUR   TDP daemon (prebuilt -- no Go toolchain)
#     oxpec-x2mini-dkms      AUR   fan + charge limit
#   ryzen-smu-x2mini-dkms    local TDP read-back; built from packaging/
#
# ryzen-smu-x2mini-dkms is the one exception. It forks an existing AUR package
# and is meant to disappear once its patch is upstreamed, so it is not published
# to the AUR -- see packaging/README.md. It is built from this checkout instead.
#
# The kernel command line is left alone on purpose: suspend needs
# amd_iommu=off, which costs the NPU, so that stays a conscious choice. This
# script only tells you what to add.
#
# See README.md, and docs/ for why any of it is necessary.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SRC/scripts/lib.sh"

SKIP_RYZEN_SMU=0
FORCE="${FORCE:-0}"

usage() {
	cat <<-EOF
	Usage: $0 [options]

	  --skip-ryzen-smu   do not build the ryzen_smu fork (loses TDP read-back)
	  --dry-run          print what would happen, change nothing
	  --force            install even if this is not an X2Mini
	  -h, --help         this text

	To install a single component, or to install your working tree rather than
	the released version, use makepkg directly:

	  cd packaging/<package> && makepkg -si
	EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-ryzen-smu) SKIP_RYZEN_SMU=1 ;;
		--dry-run)        DRY_RUN=1 ;;
		--force)          FORCE=1 ;;
		-h|--help)        usage; exit 0 ;;
		*)                echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
	shift
done
export DRY_RUN FORCE

[[ "$DRY_RUN" == "1" ]] && say "DRY RUN -- nothing will be changed"

require_x2mini

[[ $EUID -eq 0 ]] && die "run this as your normal user, not root.
    makepkg refuses to build as root, and paru will call sudo when it needs to."

have paru || die "paru not found, and the packages live in the AUR.
    Install it first: https://github.com/Morganamilo/paru"

# --- kernel headers ---------------------------------------------------------
# DKMS needs headers matching the *running* kernel. The packages cannot depend
# on them -- the right one varies by kernel -- so resolve it here, deriving the
# name rather than hardcoding a CachyOS flavour.
say "Kernel headers"
if have_kernel_headers; then
	note "present for $(uname -r)"
else
	hdrs="$(kernel_headers_pkg || true)"
	[[ -n "$hdrs" ]] || die "no kernel headers for $(uname -r), and the package
    name could not be derived. Install your kernel's -headers package."
	note "missing -- installing $hdrs"
	if [[ "$DRY_RUN" == "1" ]]; then
		note "[dry-run] paru -S --needed $hdrs"
	else
		paru -S --needed --noconfirm "$hdrs"
	fi
fi

# --- the ryzen_smu fork, built locally --------------------------------------
# Not on the AUR by design. Build it before the meta package so that if the user
# already has ryzen_smu-dkms-git installed, the conflict is resolved up front
# rather than midway through a larger transaction.
if [[ "$SKIP_RYZEN_SMU" == "0" ]]; then
	say "ryzen-smu-x2mini-dkms (from this checkout)"
	if [[ "$DRY_RUN" == "1" ]]; then
		note "[dry-run] cd packaging/ryzen-smu-x2mini-dkms && makepkg -si"
	else
		note "this replaces ryzen_smu-dkms-git if present -- that is intended,"
		note "it is what stops a package update reverting the PM table patch"
		( cd "$SRC/packaging/ryzen-smu-x2mini-dkms" && makepkg -si --needed --noconfirm ) \
			|| die "ryzen-smu-x2mini-dkms failed to build or install"
	fi
else
	say "Skipping ryzen-smu-x2mini-dkms (--skip-ryzen-smu)"
	note "TDP control will still work; read-back falls back to a cached value"
fi

# --- everything else --------------------------------------------------------
say "onexplayer-x2mini and its dependencies"
if [[ "$DRY_RUN" == "1" ]]; then
	note "[dry-run] paru -S --needed onexplayer-x2mini"
	note "          (pulls steamos-manager, inputplumber, oxp-tdpd-bin, oxpec-x2mini-dkms)"
else
	paru -S --needed --noconfirm onexplayer-x2mini || die "package install failed.
    If onexplayer-x2mini is not found, it may not be published yet --
    build from this checkout instead:  cd packaging/onexplayer-x2mini && makepkg -si"
fi

# --- services ---------------------------------------------------------------
# The packages install units and refresh udev/hwdb in their scriptlets, but
# deliberately do not start anything. Do that here, since this script is the
# "and now it works" entry point.
say "Starting services"
run systemctl daemon-reload
run systemctl enable --now oxp-tdpd
# steamos-manager binds remote D-Bus interfaces at startup, so it has to be
# restarted to notice a newly registered TdpLimit1 provider -- both daemons.
run systemctl restart steamos-manager
if [[ "$DRY_RUN" == "0" ]] && systemctl --user is-active --quiet steamos-manager 2>/dev/null; then
	systemctl --user restart steamos-manager
	note "restarted user daemon too"
fi
run modprobe -r oxpec 2>/dev/null || true
run modprobe oxpec 2>/dev/null || warn "oxpec did not load -- check 'dmesg | grep oxpec'"
[[ "$DRY_RUN" == "0" ]] && sleep 3
# --- kernel parameters: tell, never touch -----------------------------------
say "Suspend kernel parameters"
if grep -q 'amd_iommu=off' /proc/cmdline 2>/dev/null; then
	note "amd_iommu=off is set -- suspend should work"
else
	cat <<-'EOF'
	    NOT SET. Without amd_iommu=off this machine HANGS entering s0ix and
	    needs a forced power-off. There is no S3 fallback on this platform.

	        amd_iommu=off mem_sleep_default=s2idle

	    The cost: the NPU stops working entirely (amdxdna requires IOMMU) and
	    DMA remapping is gone, which matters if you use Thunderbolt. If you
	    need the NPU, do not set this and do not suspend.

	    This script will not edit your bootloader. Add it yourself:
	EOF
	if [[ -f /etc/default/limine ]]; then
		note "    Limine: /etc/default/limine  ->  sudo limine-update"
	elif [[ -f /etc/default/grub ]]; then
		note "    GRUB: /etc/default/grub  ->  sudo grub-mkconfig -o /boot/grub/grub.cfg"
	elif [[ -d /boot/loader/entries ]]; then
		note "    systemd-boot: /boot/loader/entries/*.conf"
	else
		note "    (bootloader not recognised -- see docs/suspend.md)"
	fi
	note "    Details and the tradeoff in full: docs/suspend.md"
fi

# --- result -----------------------------------------------------------------
[[ "$DRY_RUN" == "1" ]] && { say "Dry run complete"; exit 0; }

say "Result"
printf '%-16s %s\n' "inputplumber:"    "$(systemctl is-active inputplumber 2>/dev/null || echo inactive)"
printf '%-16s %s\n' "oxp-tdpd:"        "$(systemctl is-active oxp-tdpd 2>/dev/null || echo inactive)"
printf '%-16s %s\n' "steamos-manager:" "$(systemctl is-active steamos-manager 2>/dev/null || echo inactive)"
echo
steamosctl get-device-model 2>&1 || true

if systemctl is-active --quiet oxp-tdpd 2>/dev/null; then
	note "TDP: $(steamosctl get-tdp-limit 2>&1 | sed 's/.*: //')W via oxp-tdpd"
else
	warn "oxp-tdpd is not running -- Steam's TDP slider will not work"
fi

CCT=/sys/class/power_supply/BATT/charge_control_end_threshold
if [[ -r "$CCT" ]]; then
	lvl=$(cat "$CCT")
	# oxpec reports 0 when the EC has no threshold set: "charge to full", not 0%.
	if [[ "$lvl" == "0" || "$lvl" == "100" ]]; then
		note "charge limit: none set (charges to full)"
	else
		note "charge limit: ${lvl}%"
	fi
else
	warn "charge limit inert -- the patched oxpec driver did not load, see docs/oxpec.md"
fi

if [[ "$SKIP_INPUT" == "0" ]]; then
	if grep -q "Generic Steam Controller" /sys/class/hidraw/*/device/uevent 2>/dev/null; then
		note "virtual Steam Deck controller is up"
	else
		warn "no virtual controller yet -- check 'journalctl -u inputplumber -n 50'"
	fi
fi

say "Done"
note "Reboot is not required. HDR takes effect on the next game-mode session."
