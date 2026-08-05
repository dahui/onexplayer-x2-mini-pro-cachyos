#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Jeff Hagadorn <jeff@aletheia.io>
#
# One-liner installer for the ONEXPLAYER X2Mini PRO:
#
#   curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/bootstrap.sh | bash
#
# Downloads the latest release, verifies its checksum, and runs install.sh.
#
# Cloning the repository and reading install.sh first is the better path, and
# the README says so: this installs kernel modules and a root daemon. This
# script exists for people who have already decided.
#
# Options are passed through:
#   curl ... | bash -s -- --dry-run --skip-hdr

set -euo pipefail

REPO="${OXP_REPO:-dahui/onexplayer-x2-mini-pro-cachyos}"
TAG="${OXP_TAG:-latest}"
API="https://api.github.com/repos/$REPO/releases/$TAG"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for c in curl tar sha256sum; do
	command -v "$c" >/dev/null || die "$c is required but not installed"
done

[[ $EUID -eq 0 ]] && die "run this as your normal user; it will call sudo when it needs to"

say "Finding the latest release of $REPO"
# Resolve the tag first so the message names a concrete version rather than
# "latest", and so the tarball and checksum come from the same release.
if [[ "$TAG" == "latest" ]]; then
	TAG="$(curl -fsSL "$API" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
	[[ -n "$TAG" ]] || die "could not determine the latest release tag.
    The repository may have no releases yet -- clone it and run ./install.sh instead."
fi
note "release: $TAG"

BASE="https://github.com/$REPO/releases/download/$TAG"
TARBALL="onexplayer-x2-mini-pro-cachyos-${TAG#v}.tar.gz"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

say "Downloading"
note "$BASE/$TARBALL"
curl -fsSL -o "$TARBALL" "$BASE/$TARBALL" \
	|| die "download failed -- check that $TAG has a source tarball attached"

say "Verifying checksum"
if curl -fsSL -o SHA256SUMS "$BASE/SHA256SUMS" 2>/dev/null; then
	# Check only the tarball; the release also lists the binary, which we are
	# not downloading here.
	if grep -F "$TARBALL" SHA256SUMS | sha256sum -c --status -; then
		note "checksum OK"
	else
		die "CHECKSUM MISMATCH for $TARBALL.
    Do not use this download. Report it at https://github.com/$REPO/issues"
	fi
else
	# Refusing outright would strand users on releases published before
	# SHA256SUMS existed, but this must never pass silently.
	printf '\n\033[33mWARNING:\033[0m no SHA256SUMS published for %s.\n' "$TAG" >&2
	printf '    The download could not be verified. Continuing in 10s; Ctrl-C to stop.\n' >&2
	sleep 10
fi

say "Extracting"
tar xzf "$TARBALL"
DIR="$(find . -maxdepth 1 -type d -name 'onexplayer-x2-mini-pro-cachyos*' | head -1)"
[[ -n "$DIR" && -x "$DIR/install.sh" ]] || die "unexpected tarball layout: no install.sh found"

say "Running install.sh $*"
cd "$DIR"
exec ./install.sh "$@"
