#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# ONEXPLAYER X2Mini PRO enablement, installing every package from the GitHub
# release instead of the AUR.
#
#   curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install-from-release.sh | bash
#
# WHY THIS EXISTS ALONGSIDE install.sh
#
# install.sh is the normal route and installs from the AUR. The AUR goes down --
# it was offline for an extended period after a malware incident, and a package
# set where most of it comes from a channel that is unavailable is not
# installable at all. Every package is therefore attached to each release too,
# and this script installs from there.
#
# It needs NO AUR helper. The four packages come from the release page, and
# their remaining dependencies -- steamos-manager, inputplumber, dkms, dbus --
# are all in the CachyOS repos, so plain pacman resolves the whole transaction.
#
#   ryzen-smu-x2mini-dkms    release   TDP read-back
#   oxpec-x2mini-dkms        release   fan + charge limit
#   oxp-tdpd-bin             release   TDP daemon (prebuilt -- no Go toolchain)
#   onexplayer-x2mini        release   configs; depends on the three above
#     steamos-manager        repo      TDP slider, performance profiles
#     inputplumber           repo      button mapping
#
# The packages are byte-for-byte the ones CI builds from the tagged PKGBUILDs,
# and oxp-tdpd-bin and onexplayer-x2mini are built by fetching the very release
# artifacts an AUR build would fetch. Installing this way is not a different
# install; it is the same packages over a different transport.
#
# KEEP IN STEP WITH install.sh. The hardware check, kernel-header resolution,
# service startup, kernel-parameter notice and result summary are deliberately
# identical -- the two scripts must not produce different machines. Only the
# middle differs: where the packages come from.
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
	Usage: install-from-release.sh [options]

	Installs every package from the GitHub release rather than the AUR.
	Needs no AUR helper.

	  --skip-ryzen-smu   do not install the ryzen_smu fork (loses TDP read-back)
	  --keep             leave the downloaded packages in place and print where
	  --dry-run          print what would happen, change nothing
	  --force            install even if this is not an X2Mini
	  -h, --help         this text

	Environment:
	  OXP_TAG=v0.1.0     install a specific release instead of the latest

	Piped from curl, pass arguments after --:
	  curl -fsSL .../install-from-release.sh | bash -s -- --dry-run
	EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-ryzen-smu) SKIP_RYZEN_SMU=1 ;;
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
    It calls sudo for the pacman transaction and nothing else needs privilege."

for c in curl pacman; do
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
	run pacman -S --needed --noconfirm "${pkgbase}-headers"
fi

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
[[ "$SKIP_RYZEN_SMU" == "0" ]] && PACKAGES=(ryzen-smu-x2mini-dkms "${PACKAGES[@]}")

WANT_URLS=()
for p in "${PACKAGES[@]}"; do
	u="$(asset_url_for "$p")" || die "release $REL_TAG has no $p package attached.
    Releases from before this was published attach only some of the set. Pick a
    newer one, or use the AUR route:  install.sh"
	WANT_URLS+=("$u")
	note "$(printf '%-24s %s' "$p" "${u##*/}")"
done

if [[ "$SKIP_RYZEN_SMU" == "1" ]]; then
	note "skipping ryzen-smu-x2mini-dkms (--skip-ryzen-smu)"
	note "TDP control will still work; read-back falls back to a cached value"
fi

if [[ "$DRY_RUN" == "1" ]]; then
	note "[dry-run] download the above, verify against SHA256SUMS, pacman -U"
fi

# --- download and verify ----------------------------------------------------
if [[ "$DRY_RUN" == "0" ]]; then
	say "Downloading and verifying"

	TMP="$(mktemp -d)"
	if [[ "$KEEP" == "1" ]]; then
		trap 'printf "\n    packages left in %s\n" "$TMP"' EXIT
	else
		trap 'rm -rf "$TMP"' EXIT
	fi

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

# --- clear the ryzen_smu conflict before the transaction --------------------
# ryzen-smu-x2mini-dkms conflicts with ryzen_smu-dkms-git deliberately -- that
# conflict is the whole point of the package, since an update of the upstream
# one silently reverts the PM table patch and breaks every ryzenadj-based tool.
#
# pacman asks before removing a conflicting package, and that prompt defaults to
# NO (callback.c uses noyes for ALPM_QUESTION_CONFLICT_PKG). Under --noconfirm
# the default is what it takes, so the whole transaction would abort with
# "unresolvable package conflicts detected". Remove it up front instead, where
# it can be explained.
if [[ "$SKIP_RYZEN_SMU" == "0" ]] && pacman -Qq ryzen_smu-dkms-git >/dev/null 2>&1; then
	say "Replacing ryzen_smu-dkms-git"
	note "ours carries the PM table 0x64010C patch this device needs; the two"
	note "cannot coexist, and pacman would otherwise abort on the conflict"
	run pacman -R --noconfirm ryzen_smu-dkms-git \
		|| die "could not remove ryzen_smu-dkms-git. Something may depend on it:
      pacman -Qi ryzen_smu-dkms-git"
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

if grep -q "Generic Steam Controller" /sys/class/hidraw/*/device/uevent 2>/dev/null; then
	note "virtual Steam Deck controller is up"
else
	warn "no virtual controller yet -- check 'journalctl -u inputplumber -n 50'"
fi

say "Done"
note "Reboot is not required. HDR takes effect on the next game-mode session."
