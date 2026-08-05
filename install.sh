#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# ONEXPLAYER X2Mini PRO enablement.
#
#   curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install.sh | bash
#
# Standalone on purpose -- no clone required. Everything it installs is either
# an AUR package or a prebuilt package attached to a GitHub release, so there is
# nothing in the repository this needs. It never copies configuration into place
# itself: those files are owned by onexplayer-x2mini, and writing them
# separately would leave pacman reporting them as modified and give the two
# install paths room to drift.
#
#   onexplayer-x2mini        AUR      configs; pulls in everything below
#     steamos-manager        repo     TDP slider, performance profiles
#     inputplumber           repo     button mapping
#     oxp-tdpd-bin           AUR      TDP daemon (prebuilt -- no Go toolchain)
#     oxpec-x2mini-dkms      AUR      fan + charge limit
#   ryzen-smu-x2mini-dkms    release  TDP read-back
#
# ryzen-smu-x2mini-dkms is the one exception to "everything is on the AUR". It
# forks an existing AUR package and is meant to disappear once its patch is
# upstreamed, so it is published on the releases page instead -- see
# packaging/README.md. It is downloaded and checksum-verified below.
#
# The kernel command line is left alone on purpose: suspend needs
# amd_iommu=off, which costs the NPU, so that stays a conscious choice. This
# script only tells you what to add.

set -euo pipefail

REPO="${OXP_REPO:-dahui/onexplayer-x2-mini-pro-cachyos}"
TAG="${OXP_TAG:-latest}"

SKIP_RYZEN_SMU=0
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

run() {
	if [[ "$DRY_RUN" == "1" ]]; then
		printf '    \033[2m[dry-run] %s\033[0m\n' "$*"
		return 0
	fi
	$SUDO "$@"
}

usage() {
	cat <<-EOF
	Usage: install.sh [options]

	  --skip-ryzen-smu   do not install the ryzen_smu fork (loses TDP read-back)
	  --dry-run          print what would happen, change nothing
	  --force            install even if this is not an X2Mini
	  -h, --help         this text

	Environment:
	  OXP_TAG=v0.1.0     install a specific release instead of the latest

	Piped from curl, pass arguments after --:
	  curl -fsSL .../install.sh | bash -s -- --dry-run
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

[[ "$DRY_RUN" == "1" ]] && say "DRY RUN -- nothing will be changed"

# --- right machine? ---------------------------------------------------------
PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
case "$PRODUCT" in
	"ONEXPLAYER X2Mini"*) ;;
	*)
		if [[ "$FORCE" == "1" ]]; then
			warn "not an X2Mini (reports: $PRODUCT) -- continuing because --force was given"
		else
			die "This targets the ONEXPLAYER X2Mini PRO; this machine reports: $PRODUCT
    Re-run with --force to install anyway."
		fi
		;;
esac

[[ $EUID -eq 0 ]] && die "run this as your normal user, not root.
    paru refuses to build as root, and will call sudo when it needs to."

for c in curl paru; do
	have "$c" || die "$c is required but not installed."
done

# --- kernel headers ---------------------------------------------------------
# DKMS needs headers matching the *running* kernel. The packages cannot depend
# on them -- the right one varies by kernel -- so resolve it here, deriving the
# name from /usr/lib/modules/<ver>/pkgbase rather than hardcoding a flavour.
say "Kernel headers"
if [[ -d "/usr/lib/modules/$(uname -r)/build" ]]; then
	note "present for $(uname -r)"
else
	pkgbase="$(cat "/usr/lib/modules/$(uname -r)/pkgbase" 2>/dev/null || true)"
	[[ -n "$pkgbase" ]] || die "no kernel headers for $(uname -r), and the package
    name could not be derived. Install your kernel's -headers package."
	note "missing -- installing ${pkgbase}-headers"
	if [[ "$DRY_RUN" == "1" ]]; then
		note "[dry-run] paru -S --needed ${pkgbase}-headers"
	else
		paru -S --needed --noconfirm "${pkgbase}-headers"
	fi
fi

# --- the ryzen_smu fork, from the release page ------------------------------
# Installed before the meta package so that if ryzen_smu-dkms-git is already
# present, the conflict is resolved up front rather than midway through a larger
# transaction.
install_ryzen_smu() {
	say "ryzen-smu-x2mini-dkms (from the releases page)"

	local api="https://api.github.com/repos/$REPO/releases/latest"
	[[ "$TAG" != "latest" ]] && api="https://api.github.com/repos/$REPO/releases/tags/$TAG"

	local rel tag url pkg base
	rel="$(curl -fsSL "$api")" || die "could not query release '$TAG' of $REPO.
    The repository may have no releases yet."
	tag="$(printf '%s' "$rel" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"

	# Take the asset URL the release actually advertises rather than
	# reconstructing the filename. pkgrel is not always 1 -- a rebuild at the
	# same pkgver bumps it to -2- -- and a guessed filename would simply 404.
	url="$(printf '%s' "$rel" \
		| grep -oE '"browser_download_url": *"[^"]*ryzen-smu-x2mini-dkms[^"]*\.pkg\.tar\.zst"' \
		| sed 's/.*"\(https[^"]*\)"/\1/' | head -1)"
	[[ -n "$url" ]] || die "release $tag has no ryzen-smu-x2mini-dkms package attached.
    Build it from a clone instead: packaging/ryzen-smu-x2mini-dkms"

	pkg="$(basename "$url")"
	base="https://github.com/$REPO/releases/download/$tag"

	if [[ "$DRY_RUN" == "1" ]]; then
		note "$tag -> $pkg"
		note "[dry-run] download, verify against SHA256SUMS, pacman -U"
		return 0
	fi

	local tmp
	tmp="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand tmp now, not at trap time
	trap "rm -rf '$tmp'" RETURN

	note "$tag"
	curl -fsSL -o "$tmp/$pkg" "$url" \
		|| die "could not download $pkg from release $tag"

	# The package is installed with pacman -U straight off the internet, so the
	# checksum is not optional.
	if curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" 2>/dev/null; then
		( cd "$tmp" && grep -F "$pkg" SHA256SUMS | sha256sum -c --status - ) \
			|| die "CHECKSUM MISMATCH for $pkg.
    Do not use this download. Report it at https://github.com/$REPO/issues"
		note "checksum verified"
	else
		die "no SHA256SUMS published for $tag, so $pkg cannot be verified.
    Refusing to install an unverified kernel module.
    Build it yourself instead: packaging/ryzen-smu-x2mini-dkms"
	fi

	note "this replaces ryzen_smu-dkms-git if present -- that is intended,"
	note "it is what stops a package update reverting the PM table patch"
	$SUDO pacman -U --noconfirm --needed "$tmp/$pkg" \
		|| die "pacman failed to install $pkg"
}

if [[ "$SKIP_RYZEN_SMU" == "0" ]]; then
	install_ryzen_smu
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
    If onexplayer-x2mini is not found it may not be published yet; you can build
    everything from a clone instead:
      git clone https://github.com/$REPO.git
      cd packaging/onexplayer-x2mini && makepkg -si"
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
	note "    Details and the tradeoff in full: https://github.com/$REPO/blob/main/docs/suspend.md"
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
