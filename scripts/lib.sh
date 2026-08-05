# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# Shared helpers. Sourced, never executed.
#
# Every installer in this repo previously redefined say/note/install_file/$SUDO,
# which is how they drifted apart. One copy now.

# shellcheck shell=bash

[[ -n "${_OXP_LIB_SOURCED:-}" ]] && return 0
_OXP_LIB_SOURCED=1

STAMP="$(date +%Y%m%d-%H%M%S)"
DRY_RUN="${DRY_RUN:-0}"

if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Run a privileged command, or print it under --dry-run.
run() {
	if [[ "$DRY_RUN" == "1" ]]; then
		printf '    \033[2m[dry-run] %s\033[0m\n' "$*"
		return 0
	fi
	$SUDO "$@"
}

# Install a file, backing up anything it would overwrite. Only backs up when the
# content actually differs, so re-running does not litter the filesystem with
# identical copies.
install_file() {
	local src="$1" dst="$2" mode="${3:-644}"

	[[ -e "$src" ]] || die "missing source file: $src"

	if [[ "$DRY_RUN" == "1" ]]; then
		if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then
			note "unchanged  $dst"
		else
			note "would install  $dst"
		fi
		return 0
	fi

	if [[ -e "$dst" ]] && ! cmp -s "$src" "$dst"; then
		note "backing up $dst -> $dst.bak-$STAMP"
		run cp -a "$dst" "$dst.bak-$STAMP"
	fi
	run install -Dm"$mode" "$src" "$dst"
	note "installed $dst"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Confirm this is the machine these configs were built for. Everything here --
# USB paths, the capability map, the DMI match in the steamos-manager profile --
# is specific to the X2Mini PRO.
require_x2mini() {
	local product
	product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
	case "$product" in
		"ONEXPLAYER X2Mini"*) return 0 ;;
	esac
	if [[ "${FORCE:-0}" == "1" ]]; then
		warn "not an X2Mini (reports: $product) -- continuing because --force was given"
		return 0
	fi
	die "This targets the ONEXPLAYER X2Mini PRO; this machine reports: $product
    Re-run with --force to install anyway."
}

# The Arch convention: /usr/lib/modules/<ver>/pkgbase names the kernel package,
# so headers are "<pkgbase>-headers". Beats hardcoding a kernel name.
kernel_headers_pkg() {
	local base
	base="$(cat "/usr/lib/modules/$(uname -r)/pkgbase" 2>/dev/null || true)"
	[[ -n "$base" ]] && echo "${base}-headers"
}

have_kernel_headers() { [[ -d "/usr/lib/modules/$(uname -r)/build" ]]; }
