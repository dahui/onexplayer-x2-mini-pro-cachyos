# Packaging

Three packages. `makepkg -si` in any of these directories installs it locally.

**The GitHub release page is the only distribution channel.** Every package is
attached to each release, and [`install.sh`](../install.sh) downloads them,
verifies them against `SHA256SUMS`, and installs them with pacman. Nothing is
published to the AUR (see [below](#aur-publishing-disabled)).

## The package set

| Package | What it ships |
|---|---|
| `oxpec-x2mini-dkms` | Patched EC driver source + `dkms.conf`, for kernels before 7.3 |
| `oxp-tdpd-bin` | Prebuilt daemon, unit, D-Bus policy, `remotes.d`, `modules-load.d` |
| `onexplayer-x2mini` | steamos-manager, InputPlumber and hwdb configs, the paddle watcher |

Plus one dependency from the AUR, which is neither ours nor in the CachyOS repos:

| | |
|---|---|
| `ryzen_smu-dkms-git` | The amkillam ryzen_smu fork. Carries this device's PM table since `b098884`, so the patched fork this repo used to ship (`ryzen-smu-x2mini-dkms`) is gone. `install.sh` installs it with an AUR helper, or builds it with makepkg if the user agrees. |

The DKMS package is `arch=any` and ships **source only**: the user's machine
compiles the module against its own kernel. That is what makes a CI-built
`.pkg.tar.zst` portable to any Arch install.

### Dependencies pull their own weight

Neither `steamos-manager` nor `inputplumber` is installed by default on CachyOS
Handheld Edition, so both are **hard** dependencies of `onexplayer-x2mini`. That
matters more than it looks: this package ships configuration *for* each of them,
and those files are inert without the daemon that reads them. Left optional, a
fresh install would lay the configs down correctly and the buttons or the TDP
slider would simply do nothing, with no error anywhere.

`ryzen_smu-dkms` is a **hard** dependency of `oxp-tdpd-bin` for the same reason:
every TDP command goes through its sysfs mailbox, not just read-back. The daemon
has no other transport. `ryzen_smu-dkms-git` satisfies it through `provides=`.
Because pacman cannot fetch that from the AUR, `install.sh` installs it before
the release packages.

**Kernel headers are not a dependency**, following the usual DKMS convention:
the right package depends on which kernel is installed. `install.sh` resolves
them, and the DKMS package checks at install time and prints the exact command,
because the failure mode is otherwise silent. Without headers the module never
builds and the feature just does not work.

`gamescope` is no longer referenced at all. HDR comes from gamescope's own
bundled display entry for this panel (see [docs/hdr.md](../docs/hdr.md)).

Note `depends=('oxp-tdpd')` is satisfied by `oxp-tdpd-bin` through `provides=`.
pacman resolves that when both are in one `pacman -U` transaction, which is how
`install.sh` installs them.

### Package names differ from upstream; module names must not

`oxpec-x2mini-dkms` builds `oxpec.ko`. The **module** name has to stay as it
is: it is what binds the hardware and what `modprobe` looks for. Only the
*package* name is namespaced, so it never collides with upstream. Do not "fix"
the mismatch.

### `oxpec-x2mini-dkms` retires itself at 7.3

The DMI entry it adds is in mainline from v7.3-rc1. `dkms.conf` restricts the
build to kernels before 7.3 with `BUILD_EXCLUSIVE_KERNEL`, so on 7.3+ DKMS skips
it and the in-tree oxpec binds. Otherwise the `/updates` copy would keep
shadowing the in-tree driver. Delete the package once 7.3 is the oldest kernel
in use.

## Publishing

**Automatic.** Pushing a `v*` tag runs `release.yml`, which builds everything and
attaches it to the release. Re-running a release without re-pushing the tag:

```bash
gh workflow run release.yml --ref vX.Y.Z
```

### `release.yml` publishes in two passes, and the order is load-bearing

`oxp-tdpd-bin` and `onexplayer-x2mini` have release artifacts in their
`source=()`, so those artifacts must already be downloadable before either can
be built. A draft release does not expose assets at the public download path, so
the release has to be genuinely published in between:

1. Build the binary, the source tarball and the self-contained DKMS package;
   publish them — **without `SHA256SUMS`**.
2. Poll until the assets are actually downloadable, build the two
   release-sourced packages against the live release, then publish those plus a
   `SHA256SUMS` covering everything.

`SHA256SUMS` is withheld until the end deliberately. A checksum file listing only
some assets is worse than no file at all: `install.sh` verifies against it,
and a missing line would have to be told apart from a real mismatch. If the job
dies between the passes the release simply has no `SHA256SUMS`, and the script
refuses to install rather than installing something unverified.

### `pkgver` is stamped from the tag

The committed PKGBUILDs carry whatever `pkgver` was last written; `release.yml`
rewrites it from the tag before building. Without that, the two release-sourced
packages would fetch the *previous* release's artifacts. v0.1.1 shipped an
`oxp-tdpd-bin` containing v0.1.0's binary exactly that way.

### `SKIP` checksums

The two release-sourced PKGBUILDs (`oxp-tdpd-bin`, `onexplayer-x2mini`) carry
`SKIP` because the artifacts they hash do not exist until a release is cut. The
self-contained `oxpec-x2mini-dkms` carries real checksums, and CI rebuilds it on
every push, so a source edit without `updpkgsums` fails there first.

## AUR publishing (disabled)

Earlier plans published these packages to the AUR too. The AUR was down for the
whole of this project's development and nothing was ever pushed, so it has been
disabled rather than half-maintained:

- `.github/workflows/aur.yml` has no automatic trigger any more and runs only
  when dispatched by hand. Its header explains how to restore the trigger.
- `aur-publish.sh` is kept for reference. It derives `pkgrel`, replaces `SKIP`
  checksums, generates `.SRCINFO`, and retries around AUR maintenance windows.
  The comments in the script cover the details.

If this is ever revived, publish leaves first (`oxpec-x2mini-dkms`,
`oxp-tdpd-bin`, then `onexplayer-x2mini`); the AUR cannot resolve a dependency
that has not been published yet.
