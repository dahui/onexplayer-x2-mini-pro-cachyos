#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# ONEXPLAYER X2Mini PRO enablement.
#
#   curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install.sh | bash
#
# Standalone on purpose -- no clone required. Everything it installs is a pacman
# package: ours come from the GitHub release page, checksum-verified, and the
# rest from the repos or the AUR. It never copies configuration into place
# itself: those files are owned by onexplayer-x2mini, and writing them
# separately would leave pacman reporting them as modified.
#
#   ryzen_smu-dkms-git       AUR       SMU mailbox for oxp-tdpd (see below)
#   oxpec-x2mini-dkms        release   fan + charge limit (kernels before 7.3)
#   oxp-tdpd-bin             release   TDP daemon (prebuilt -- no Go toolchain)
#   onexplayer-x2mini        release   configs + paddle watcher
#     steamos-manager        repo      TDP slider, performance profiles
#     inputplumber           repo      button mapping
#
# ryzen_smu-dkms-git is the one package that is neither ours nor in the
# CachyOS repos. It is a hard requirement -- oxp-tdpd sends every TDP command
# through its sysfs mailbox -- so it is installed first: with an AUR helper if
# there is one, otherwise by building the AUR package locally if the user
# agrees. This machine's PM table version is supported upstream since
# amkillam/ryzen_smu@b098884, so no patched fork is needed any more.
#
# The kernel command line is left alone on purpose: suspend has needed
# amd_iommu=off, which costs the NPU, so that stays a conscious choice. This
# script only tells you what to add.

set -euo pipefail

REPO="${OXP_REPO:-dahui/onexplayer-x2-mini-pro-cachyos}"
TAG="${OXP_TAG:-latest}"

RYZEN_SMU_PKG=ryzen_smu-dkms-git
RYZEN_SMU_UPSTREAM=https://github.com/amkillam/ryzen_smu

FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"
KEEP=0

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

	Installs the ONEXPLAYER X2Mini PRO packages from the GitHub release with
	pacman, plus ryzen_smu-dkms-git from the AUR.

	  --keep             leave the downloaded packages in place and print where
	  --dry-run          print what would happen, change nothing
	  --force            install even if this is not an X2Mini
	  -h, --help         this text

	Environment:
	  OXP_TAG=v0.2.0     install a specific release instead of the latest

	Piped from curl, pass arguments after --:
	  curl -fsSL .../install.sh | bash -s -- --dry-run
	EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--keep)           KEEP=1 ;;
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
    It calls sudo for pacman, and AUR helpers and makepkg refuse to run as root."

for c in curl pacman; do
	have "$c" || die "$c is required but not installed."
done

# Scratch space for downloads and a possible local ryzen_smu build.
TMP=""
if [[ "$DRY_RUN" == "0" ]]; then
	TMP="$(mktemp -d)"
	if [[ "$KEEP" == "1" ]]; then
		trap 'printf "\n    packages left in %s\n" "$TMP"' EXIT
	else
		trap 'rm -rf "$TMP"' EXIT
	fi
fi

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
	run pacman -S --needed --noconfirm "${pkgbase}-headers"
fi

# --- ryzen_smu, from the AUR ------------------------------------------------
# Needed before the release packages: oxp-tdpd-bin depends on ryzen_smu-dkms,
# and plain pacman cannot pull that from the AUR.

ryzen_smu_required() {
	die "ryzen_smu is required, and was not installed.

    oxp-tdpd sends every TDP command -- not just read-back -- through the
    ryzen_smu kernel module's SMU mailbox (/sys/kernel/ryzen_smu_drv). Without
    it Steam's TDP slider does nothing, and oxp-tdpd.service is skipped at boot.

    It is packaged in the AUR as $RYZEN_SMU_PKG: the amkillam fork, which
    supports this machine's Strix Halo firmware. Install it with any AUR
    helper, or build it with makepkg, then re-run this script:

        paru -S $RYZEN_SMU_PKG

    Upstream: $RYZEN_SMU_UPSTREAM
    AUR:      https://aur.archlinux.org/packages/$RYZEN_SMU_PKG"
}

# Yes/no on the terminal. stdin is the script itself when piped from curl, so
# read /dev/tty. Returns 0 yes, 1 no, 2 when there is no terminal to ask on.
ask_yes_no() {
	local ans
	{ exec 3<>/dev/tty; } 2>/dev/null || return 2
	printf '    %s [y/N] ' "$1" >&3
	read -r ans <&3 || { exec 3>&-; return 2; }
	exec 3>&-
	[[ "$ans" == [yY]* ]]
}

build_ryzen_smu() {
	have git || die "git is needed to fetch the package source:  sudo pacman -S git"
	pacman -Qq base-devel >/dev/null 2>&1 \
		|| die "base-devel is needed to build packages:  sudo pacman -S --needed base-devel"

	local dir="$TMP/$RYZEN_SMU_PKG"
	# The AUR's own git, falling back to its official GitHub mirror, which stays
	# up when aur.archlinux.org does not.
	if git clone -q --depth 1 "https://aur.archlinux.org/$RYZEN_SMU_PKG.git" "$dir" 2>/dev/null \
	   && [[ -f "$dir/PKGBUILD" ]]; then
		note "fetched from aur.archlinux.org"
	else
		rm -rf "$dir"
		git clone -q --depth 1 --single-branch --branch "$RYZEN_SMU_PKG" \
			https://github.com/archlinux/aur.git "$dir" \
			|| die "could not fetch $RYZEN_SMU_PKG from the AUR or its GitHub mirror."
		note "fetched from the AUR's GitHub mirror"
	fi

	# makepkg -s installs build dependencies with sudo; -i installs the result.
	( cd "$dir" && makepkg -si --needed --noconfirm ) \
		|| die "building $RYZEN_SMU_PKG failed. The PKGBUILD is in $dir."
}

ensure_ryzen_smu() {
	say "ryzen_smu ($RYZEN_SMU_PKG, AUR)"

	# Earlier versions of this project shipped a patched fork. It provides
	# ryzen_smu-dkms too, so it would satisfy the check below -- but it pins a
	# commit that no longer builds on Linux 7.2, and it conflicts with the real
	# package. Replace it. -dd because oxp-tdpd-bin depends on the provision and
	# it is reinstated immediately below.
	if pacman -Qq ryzen-smu-x2mini-dkms >/dev/null 2>&1; then
		note "removing ryzen-smu-x2mini-dkms, the old patched fork -- its patch"
		note "is upstream now, and it does not build on Linux 7.2"
		run pacman -Rdd --noconfirm ryzen-smu-x2mini-dkms \
			|| die "could not remove ryzen-smu-x2mini-dkms"
	elif pacman -T ryzen_smu-dkms >/dev/null 2>&1; then
		note "already installed: $(pacman -Qq "$RYZEN_SMU_PKG" 2>/dev/null || echo ryzen_smu-dkms)"
		return 0
	fi

	local helper=""
	for h in paru yay; do
		if have "$h"; then helper="$h"; break; fi
	done

	if [[ -n "$helper" ]]; then
		note "installing with $helper"
		if [[ "$DRY_RUN" == "1" ]]; then
			note "[dry-run] $helper -S --needed $RYZEN_SMU_PKG"
			return 0
		fi
		"$helper" -S --needed --noconfirm "$RYZEN_SMU_PKG" \
			|| die "$helper could not install $RYZEN_SMU_PKG.
    If the AUR is unreachable, re-run once it is back; see $RYZEN_SMU_UPSTREAM"
		return 0
	fi

	note "no AUR helper found (looked for paru and yay)."
	note "It can be built here instead: this downloads the AUR package source"
	note "(PKGBUILD from aur.archlinux.org/$RYZEN_SMU_PKG) and runs makepkg -si."
	if [[ "$DRY_RUN" == "1" ]]; then
		note "[dry-run] would ask whether to build $RYZEN_SMU_PKG locally"
		return 0
	fi

	local rc=0
	ask_yes_no "Download and build $RYZEN_SMU_PKG now?" || rc=$?
	case "$rc" in
		0) build_ryzen_smu ;;
		2) note "no terminal to ask on"; ryzen_smu_required ;;
		*) ryzen_smu_required ;;
	esac
}

ensure_ryzen_smu

# --- work out what the release offers ---------------------------------------
say "Release"

API="https://api.github.com/repos/$REPO/releases/latest"
[[ "$TAG" != "latest" ]] && API="https://api.github.com/repos/$REPO/releases/tags/$TAG"

REL="$(curl -fsSL "$API")" || die "could not query release '$TAG' of $REPO.
    The repository may have no releases yet."
REL_TAG="$(printf '%s' "$REL" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$REL_TAG" ]] || die "could not read a tag name out of the release metadata."
note "$REL_TAG"

# Every asset URL the release advertises. Matching on the basename below rather
# than substring-matching the whole URL matters: the repository is called
# onexplayer-x2-mini-pro-cachyos and appears in every URL, so a substring test
# for a package name would match the wrong things.
ASSET_URLS="$(printf '%s' "$REL" \
	| grep -oE '"browser_download_url": *"[^"]*"' \
	| sed 's/.*"\(https[^"]*\)"/\1/')"

# Echo the asset URL for a package, matching <pkgname>-<pkgver>-<pkgrel>-<arch>.
#
# The [0-9] after the name is load-bearing: pacman package names are not
# prefix-free. A bare "<want>-*" glob resolves oxp-tdpd to oxp-tdpd-bin, so
# asking for one package could quietly install a different one. Requiring a
# digit next means only the real pkgver field can follow the name.
asset_url_for() {
	local want="$1" u
	while read -r u; do
		[[ -z "$u" ]] && continue
		case "${u##*/}" in
			"$want"-[0-9]*.pkg.tar.zst) printf '%s\n' "$u"; return 0 ;;
		esac
	done <<-EOF
	$ASSET_URLS
	EOF
	return 1
}

PACKAGES=(oxpec-x2mini-dkms oxp-tdpd-bin onexplayer-x2mini)

WANT_URLS=()
for p in "${PACKAGES[@]}"; do
	u="$(asset_url_for "$p")" || die "release $REL_TAG has no $p package attached.
    Pick a newer release with OXP_TAG, or build it from a clone:
      cd packaging/$p && makepkg -si"
	WANT_URLS+=("$u")
	note "$(printf '%-24s %s' "$p" "${u##*/}")"
done

if [[ "$DRY_RUN" == "1" ]]; then
	note "[dry-run] download the above, verify against SHA256SUMS, pacman -U"
fi

# --- download and verify ----------------------------------------------------
if [[ "$DRY_RUN" == "0" ]]; then
	say "Downloading and verifying"

	for u in "${WANT_URLS[@]}"; do
		curl -fsSL --retry 3 -o "$TMP/${u##*/}" "$u" \
			|| die "could not download ${u##*/} from release $REL_TAG"
	done

	# These are installed with pacman -U straight off the internet, so the
	# checksum is not optional. A release whose SHA256SUMS is missing is a
	# half-published one -- CI uploads it only after every artifact is up --
	# and refusing is the right response to that, not a reason to proceed.
	SUMS="https://github.com/$REPO/releases/download/$REL_TAG/SHA256SUMS"
	curl -fsSL -o "$TMP/SHA256SUMS" "$SUMS" 2>/dev/null \
		|| die "no SHA256SUMS published for $REL_TAG, so these packages cannot be
    verified. Refusing to install unverified kernel modules and a root daemon.
    Report it at https://github.com/$REPO/issues"

	for u in "${WANT_URLS[@]}"; do
		f="${u##*/}"
		# Require a line for this exact file. Without the emptiness check a
		# missing entry would hand sha256sum -c nothing to do; it exits non-zero
		# on empty input today, but relying on that to enforce coverage is a
		# thin thread to hang a signature check on.
		line="$(grep -F "  $f" "$TMP/SHA256SUMS" || true)"
		[[ -n "$line" ]] || die "SHA256SUMS for $REL_TAG has no entry for $f.
    Do not use this download. Report it at https://github.com/$REPO/issues"
		( cd "$TMP" && printf '%s\n' "$line" | sha256sum -c --status - ) \
			|| die "CHECKSUM MISMATCH for $f.
    Do not use this download. Report it at https://github.com/$REPO/issues"
		note "verified $f"
	done
fi

# --- install ----------------------------------------------------------------
# One transaction, so pacman resolves the dependencies between these packages
# (onexplayer-x2mini needs oxp-tdpd, provided by oxp-tdpd-bin) alongside the
# repo ones it pulls in itself.
say "Installing"
if [[ "$DRY_RUN" == "1" ]]; then
	note "[dry-run] sudo pacman -U --needed ${PACKAGES[*]}"
	note "          (pulls steamos-manager, inputplumber, dkms, dbus from the repos)"
else
	files=()
	for u in "${WANT_URLS[@]}"; do files+=("$TMP/${u##*/}"); done
	$SUDO pacman -U --needed --noconfirm "${files[@]}" \
		|| die "pacman failed to install the packages.
    If it reports missing dependencies, steamos-manager and inputplumber come
    from the CachyOS repos -- check they are enabled in /etc/pacman.conf."
fi

# --- services ---------------------------------------------------------------
# The packages install units and refresh udev/hwdb in their scriptlets, but
# deliberately do not start anything. Do that here, since this script is the
# "and now it works" entry point.
say "Starting services"
run systemctl daemon-reload
# The modules were just built by DKMS; nothing has loaded them yet this boot.
run modprobe ryzen_smu 2>/dev/null || warn "ryzen_smu did not load -- check 'dkms status' and 'dmesg | grep ryzen_smu'"
run modprobe -r oxpec 2>/dev/null || true
run modprobe oxpec 2>/dev/null || warn "oxpec did not load -- check 'dmesg | grep oxpec'"
run systemctl enable oxp-tdpd
# restart, not `enable --now`: that is a no-op on an already-running service,
# which would silently keep the previous binary on a reinstall.
run systemctl restart oxp-tdpd
# steamos-manager binds remote D-Bus interfaces at startup, so it has to be
# restarted to notice a newly registered TdpLimit1 provider -- both daemons.
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
	    needs a forced power-off -- still true on Linux 7.2 (iommu=pt does not
	    help). There is no S3 fallback. To use suspend, add:

	        amd_iommu=off mem_sleep_default=s2idle

	    The cost: the NPU stops working entirely (amdxdna requires IOMMU) and
	    DMA remapping is gone, which matters if you use Thunderbolt.

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
for u in inputplumber oxp-tdpd steamos-manager oxp-x2mini-paddles; do
	printf '%-20s %s\n' "$u:" "$(systemctl is-active "$u" 2>/dev/null || true)"
done
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

if grep -q "Generic Steam Controller" /sys/class/hidraw/*/device/uevent 2>/dev/null; then
	note "virtual Steam Deck controller is up"
else
	warn "no virtual controller yet -- check 'journalctl -u inputplumber -n 50'"
fi

say "Done"
note "Reboot is not required."
