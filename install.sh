#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# ONEXPLAYER X2Mini PRO enablement -- the only command you need to run.
#
# Installs, in an order that matters:
#   oxpec       fan RPM/PWM + battery charge limit (patched EC driver)
#   ryzen_smu   PM table 0x64010C, without which ryzenadj breaks outright
#   oxp-tdpd    gives Steam's TDP slider a backend (10-85 W)
#   input       InputPlumber profile + capability map + steamos-manager config
#   HDR         gamescope display script + --hdr-enabled
#
# Deliberately does NOT touch the kernel command line. Suspend needs
# amd_iommu=off, which costs the NPU, so that stays a conscious choice -- this
# script only tells you what to add.
#
# Idempotent. Backs up anything it replaces to <file>.bak-<timestamp>.
#
# See README.md, and docs/ for why any of it is necessary.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SRC/scripts/lib.sh"

SKIP_HDR=0
SKIP_INPUT=0
SKIP_DEPS=0
FORCE="${FORCE:-0}"

usage() {
	cat <<-EOF
	Usage: $0 [options]

	  --skip-hdr      leave gamescope/HDR alone
	  --skip-input    leave InputPlumber and the button mapping alone
	  --no-deps       do not install packages with paru
	  --dry-run       print what would happen, change nothing
	  --force         install even if this is not an X2Mini
	  -h, --help      this text
	EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-hdr)   SKIP_HDR=1 ;;
		--skip-input) SKIP_INPUT=1 ;;
		--no-deps)    SKIP_DEPS=1 ;;
		--dry-run)    DRY_RUN=1 ;;
		--force)      FORCE=1 ;;
		-h|--help)    usage; exit 0 ;;
		*)            echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
	shift
done
export DRY_RUN FORCE

[[ "$DRY_RUN" == "1" ]] && say "DRY RUN -- nothing will be changed"

require_x2mini

# --- dependencies -----------------------------------------------------------
install_deps() {
	say "Dependencies"

	if ! have paru; then
		die "paru not found, and it is needed for the AUR packages.
    Install it first, or re-run with --no-deps and handle dependencies yourself:
      https://github.com/Morganamilo/paru"
	fi

	local want=(dkms inputplumber steamos-manager)

	# DKMS needs headers matching the *running* kernel. Derive rather than
	# hardcode, so this works on any CachyOS/Arch kernel flavour.
	local hdrs
	hdrs="$(kernel_headers_pkg || true)"
	if have_kernel_headers; then
		note "kernel headers present for $(uname -r)"
	elif [[ -n "$hdrs" ]]; then
		note "kernel headers missing, will install $hdrs"
		want+=("$hdrs")
	else
		warn "cannot determine the kernel headers package; DKMS builds may fail"
	fi

	# Only needed for install-hdr.sh's EDID sanity check, which degrades
	# gracefully without it.
	[[ "$SKIP_HDR" == "1" ]] || want+=(edid-decode)

	note "installing: ${want[*]}"
	if [[ "$DRY_RUN" == "1" ]]; then
		printf '    \033[2m[dry-run] paru -S --needed %s\033[0m\n' "${want[*]}"
	else
		paru -S --needed --noconfirm "${want[@]}"
	fi
}

[[ "$SKIP_DEPS" == "1" ]] && say "Skipping dependencies (--no-deps)" || install_deps

# --- kernel modules ---------------------------------------------------------
# Installed as real pacman packages, not staged into /usr/src by hand. That
# matters for ryzen-smu-x2mini-dkms in particular: it carries
# conflicts=('ryzen_smu-dkms-git'), which is what stops a ryzen_smu-dkms-git
# update replacing /usr/src wholesale and silently dropping our PM table patch --
# leaving a loaded-but-unpatched module that breaks ryzenadj with an error
# reading like a permissions problem.
#
# Both are arch=any and ship source only; DKMS compiles them against the running
# kernel and rebuilds on kernel updates.
install_kernel_modules() {
	say "Kernel modules"

	for pkg in oxpec-x2mini-dkms ryzen-smu-x2mini-dkms; do
		if [[ "$DRY_RUN" == "1" ]]; then
			note "[dry-run] would build and install $pkg"
			continue
		fi

		note "building $pkg"
		# makepkg refuses to run as root; if this script was invoked with sudo,
		# drop back to the invoking user to build, then install as root.
		if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
			runuser -u "$SUDO_USER" -- \
				bash -c "cd '$SRC/packaging/$pkg' && makepkg -f --noconfirm" \
				|| die "$pkg failed to build"
			$SUDO pacman -U --noconfirm --needed "$SRC/packaging/$pkg"/*.pkg.tar.zst
		elif [[ $EUID -eq 0 ]]; then
			die "run this as your normal user, not root -- makepkg refuses to build as root"
		else
			( cd "$SRC/packaging/$pkg" && makepkg -si --noconfirm ) \
				|| die "$pkg failed to build or install"
		fi
		note "installed $pkg"
	done

	# Load them now rather than waiting for a reboot.
	run modprobe -r oxpec 2>/dev/null || true
	run modprobe oxpec 2>/dev/null || warn "oxpec did not load -- check 'dmesg | grep oxpec'"
	run modprobe ryzen_smu 2>/dev/null || warn "ryzen_smu did not load"
}
install_kernel_modules

# --- TDP daemon -------------------------------------------------------------
say "TDP daemon"
if [[ "$DRY_RUN" == "1" ]]; then
	note "[dry-run] would install oxp-tdpd"
else
	"$SRC/tdpd/install-tdpd.sh"
fi

# --- input stack ------------------------------------------------------------
HWDB_LIVE=/etc/udev/hwdb.d/61-inputplumber-onexplayer-x2mini.hwdb

if [[ "$SKIP_INPUT" == "0" ]]; then
	say "Input stack"

	install_file "$SRC/etc/udev/hwdb.d/61-inputplumber-onexplayer-x2mini.hwdb" "$HWDB_LIVE"
	run rm -f "$HWDB_LIVE.disabled"

	# Map before profile: the profile references the map by id, and InputPlumber
	# refuses to build the composite device if that id does not resolve.
	install_file "$SRC/etc/inputplumber/capability_maps.d/onexplayer_x2mini.yaml" \
	             /etc/inputplumber/capability_maps.d/onexplayer_x2mini.yaml
	install_file "$SRC/etc/inputplumber/devices.d/50-onexplayer_x2_mini.yaml" \
	             /etc/inputplumber/devices.d/50-onexplayer_x2_mini.yaml
else
	say "Skipping input stack (--skip-input)"
	if [[ -e "$HWDB_LIVE" ]]; then
		run mv "$HWDB_LIVE" "$HWDB_LIVE.disabled"
		note "parked $HWDB_LIVE -> .disabled"
	fi
fi

# --- steamos-manager profile ------------------------------------------------
say "steamos-manager device profile"
install_file "$SRC/usr/share/steamos-manager/devices/onexplayer-x2-mini.toml" \
             /usr/share/steamos-manager/devices/onexplayer-x2-mini.toml

# --- udev / hwdb ------------------------------------------------------------
say "Refreshing udev"
run systemd-hwdb update
# udevd caches the compiled hwdb; without this it keeps applying the old data.
run udevadm control --reload

if [[ "$SKIP_INPUT" == "0" && "$DRY_RUN" == "0" ]]; then
	hwdb_out="$(systemd-hwdb query "$(cat /sys/class/dmi/id/modalias)" 2>/dev/null || true)"
	[[ "$hwdb_out" == *USE_INPUTPLUMBER=1* ]] \
		|| die "hwdb did not pick up USE_INPUTPLUMBER=1 -- check the .hwdb syntax"
	note "USE_INPUTPLUMBER=1 resolves"

	run udevadm trigger --subsystem-match=dmi --action=add
	sleep 3
	run systemctl enable inputplumber-suspend.service
elif [[ "$SKIP_INPUT" == "1" && "$DRY_RUN" == "0" ]]; then
	# A Before=sleep.target oneshot aimed at a D-Bus name nobody owns.
	if systemctl is-enabled --quiet inputplumber-suspend.service 2>/dev/null; then
		run systemctl disable --now inputplumber-suspend.service
	fi
	if systemctl is-active --quiet inputplumber 2>/dev/null; then
		run systemctl stop inputplumber
		# InputPlumber chmods its source devices to 000 to hide them and does not
		# reliably restore them, which leaves the gamepad unusable.
		note "restoring /dev/input permissions"
		run udevadm trigger --subsystem-match=input --action=add
		run udevadm settle
	fi
fi

# --- HDR --------------------------------------------------------------------
if [[ "$SKIP_HDR" == "0" ]]; then
	say "HDR"
	if [[ "$DRY_RUN" == "1" ]]; then
		note "[dry-run] would run hdr/install-hdr.sh"
	else
		"$SRC/hdr/install-hdr.sh"
	fi
else
	say "Skipping HDR (--skip-hdr)"
fi

# --- steamos-manager --------------------------------------------------------
# New D-Bus interfaces are only registered at startup, so a reload is not enough.
say "Restarting steamos-manager"
run systemctl restart steamos-manager
if [[ "$DRY_RUN" == "0" ]] && systemctl --user is-active --quiet steamos-manager 2>/dev/null; then
	systemctl --user restart steamos-manager
	note "restarted user daemon too"
fi
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
note "Reboot is not required, but log out and back in for HDR to take effect."
