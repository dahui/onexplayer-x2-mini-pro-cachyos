#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# Publish packages to the AUR.
#
# Run by .github/workflows/aur.yml after a release is published, and usable by
# hand for a dry run:
#
#   ./packaging/aur-publish.sh --version 0.1.0 --dry-run
#   ./packaging/aur-publish.sh --version 0.1.0 --only oxp-tdpd-bin
#
# Requires an Arch environment: makepkg, updpkgsums and makepkg --printsrcinfo
# do not exist elsewhere. makepkg also refuses to run as root, so CI builds
# under an unprivileged user.
#
# ORDER MATTERS. onexplayer-x2mini depends on the others, and the AUR cannot
# resolve a dependency that is not yet published -- so the leaves go first.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=""
DRY_RUN=0
ONLY=""

# Dependency order, leaves first.
#
# ryzen-smu-x2mini-dkms is deliberately ABSENT. It forks an existing AUR package
# (ryzen_smu-dkms-git) and exists only until our patch is upstreamed. Putting a
# short-lived fork of someone else's package into the AUR namespace is exactly
# the thing that quietly becomes permanent, so it ships as a prebuilt package on
# the GitHub release instead and install.sh builds it from the checkout.
PACKAGES=(
	oxpec-x2mini-dkms
	oxp-tdpd-bin
	onexplayer-x2mini
)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSION="$2"; shift 2 ;;
		--only)    ONLY="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '4,20p' "$0"; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
done

[[ -n "$VERSION" ]] || die "--version is required (e.g. --version 0.1.0)"
VERSION="${VERSION#v}"

command -v makepkg    >/dev/null || die "makepkg not found -- this must run on Arch"
command -v updpkgsums >/dev/null || die "updpkgsums not found -- install pacman-contrib"
[[ $EUID -ne 0 ]] || die "makepkg refuses to run as root; use an unprivileged user"

# --- fail early, and legibly, if the AUR cannot be reached -------------------
# Without this the first sign of trouble is `git clone` failing inside the loop,
# which this script cannot distinguish from "this package has no repo yet" -- so
# it prints "creating one" and then dies at the push. That is exactly what
# happened on the first v0.1.0 attempt, during an AUR maintenance window: a
# misleading message followed by a bare "Could not read from remote repository".
#
# Skipped for --dry-run, which never touches the AUR and should work without a
# key present.
preflight_aur() {
	local out
	say "Checking AUR reachability"
	out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
	           -o ConnectTimeout=15 aur@aur.archlinux.org help 2>&1 || true)"

	case "$out" in
		*maintenance*)
			die "the AUR is down for maintenance. Nothing was pushed.

    $out

    Re-run this when it is back up." ;;
		*"Permission denied"*)
			die "the AUR rejected our SSH key.

    Check the public half is on the AUR account (My Account -> SSH Public Key)
    and that AUR_SSH_PRIVATE_KEY holds the matching private half, complete with
    its trailing newline." ;;
		*"Could not resolve"*|*"Connection timed out"*|*"Network is unreachable"*|*"Connection refused"*)
			die "cannot reach aur.archlinux.org.

    $out" ;;
	esac
	note "reachable and authenticated"
}

[[ "$DRY_RUN" == "1" ]] || preflight_aur

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for pkg in "${PACKAGES[@]}"; do
	[[ -n "$ONLY" && "$ONLY" != "$pkg" ]] && continue

	say "$pkg"
	[[ -d "$SRC/$pkg" ]] || die "no such package directory: $SRC/$pkg"

	stage="$WORK/$pkg"
	mkdir -p "$stage"
	cp "$SRC/$pkg"/* "$stage/"
	cd "$stage"

	# Keep pkgver in step with the tag rather than trusting whatever is
	# committed -- the two drift the moment anyone forgets.
	sed -i "s|^pkgver=.*|pkgver=$VERSION|" PKGBUILD
	note "pkgver=$VERSION"

	# Real checksums. AUR rejects SKIP for anything that is not a VCS source,
	# and updpkgsums leaves genuine VCS sources as SKIP by itself. This is why
	# publishing must happen AFTER the release artifacts are uploaded: it
	# downloads them to hash them.
	note "computing checksums (downloads the release artifacts)"
	updpkgsums 2>&1 | sed 's/^/      /'

	# AUR rejects SKIP for anything that is not a VCS source. Count rather than
	# just checking for presence: ryzen-smu-x2mini-dkms has both a tarball and a
	# pinned git source, so "has a git+ source somewhere" would wave through a
	# tarball whose checksum never got computed.
	skips=$(grep -coE "'SKIP'" PKGBUILD || true)
	vcs=$(grep -cE "^[[:space:]]*[\"']?[a-zA-Z_-]*::(git|hg|svn|bzr)\+|(git|hg|svn|bzr)\+https?://" PKGBUILD || true)
	if (( skips > vcs )); then
		die "$pkg: $skips SKIP checksum(s) but only $vcs VCS source(s).
    updpkgsums did not replace them all, and the AUR will reject this."
	fi
	note "checksums: $skips SKIP (VCS sources: $vcs)"

	makepkg --printsrcinfo > .SRCINFO
	note "wrote .SRCINFO"

	# Catches a malformed PKGBUILD before it reaches the AUR. Does not build.
	makepkg --verifysource --noconfirm >/dev/null 2>&1 \
		|| die "$pkg: source verification failed"
	note "sources verify"

	if [[ "$DRY_RUN" == "1" ]]; then
		note "[dry-run] would push to ssh://aur@aur.archlinux.org/$pkg.git"
		grep -E "^(pkgname|pkgver|pkgrel)" PKGBUILD | sed 's/^/      /'
		continue
	fi

	# The AUR creates the repository on first push of a valid PKGBUILD +
	# .SRCINFO, so a clone failing here is normal for a brand-new package.
	# preflight_aur has already established that the AUR is up and our key
	# works, so a failure at this point really does mean "no such package".
	aur="$WORK/aur-$pkg"
	if git clone -q "ssh://aur@aur.archlinux.org/$pkg.git" "$aur" 2>/dev/null; then
		note "cloned existing AUR repo"
	else
		note "no AUR repo for $pkg yet -- first push will create it"
		git init -q "$aur"
		git -C "$aur" remote add origin "ssh://aur@aur.archlinux.org/$pkg.git"
	fi

	# Copy what the AUR repo has to carry: the PKGBUILD, .SRCINFO, any install
	# scriptlet, and any *local* sources the PKGBUILD names. oxpec-x2mini-dkms
	# sources oxpec.c/Makefile/dkms.conf from alongside the PKGBUILD rather than
	# from a tarball, and without them the AUR repo would not build.
	# Never the built packages, pkg/ or src/ trees.
	cp PKGBUILD .SRCINFO "$aur/"
	for extra in "$SRC/$pkg"/*.install "$SRC/$pkg"/*.patch \
	             "$SRC/$pkg"/*.c "$SRC/$pkg"/Makefile "$SRC/$pkg"/dkms.conf; do
		[[ -e "$extra" ]] && cp "$extra" "$aur/"
	done

	cd "$aur"
	git add -A
	if git diff --cached --quiet; then
		note "no changes -- already published at $VERSION"
		continue
	fi

	git -c user.name="${AUR_USERNAME:-Jeff Hagadorn}" \
	    -c user.email="${AUR_EMAIL:-jeff@aletheia.io}" \
	    commit -q -m "Update to $VERSION"
	git push -q origin HEAD:master
	note "pushed $pkg $VERSION"
done

say "Done"
