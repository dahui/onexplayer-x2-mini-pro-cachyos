# Packaging

Four packages. `makepkg -si` in any of these directories installs it locally;
[`aur-publish.sh`](aur-publish.sh) pushes them to the AUR, and
[`../.github/workflows/aur.yml`](../.github/workflows/aur.yml) runs that
automatically when a release is published.

## The package set

Listed in dependency order — **leaves first**, because the AUR cannot resolve a
dependency that has not been published yet.

| Package | What it ships | Notes |
|---|---|---|
| `oxpec-x2mini-dkms` | Patched EC driver source + `dkms.conf` | Fan RPM/PWM and the battery charge limit. Builds `oxpec.ko`. |
| `ryzen-smu-x2mini-dkms` | ryzen_smu + the PM table `0x64010C` patch | **Temporary.** See below. |
| `oxp-tdpd-bin` | Prebuilt daemon, unit, D-Bus policy, `remotes.d` | The release binary, so no Go toolchain. |
| `onexplayer-x2mini` | steamos-manager, InputPlumber, hwdb and gamescope configs | The entry point: pulls in the rest. |

`onexplayer-x2mini` hard-depends on `steamos-manager`, `oxp-tdpd` and
`oxpec-x2mini-dkms`, and *opt*-depends on `inputplumber`,
`ryzen-smu-x2mini-dkms` and `gamescope`. So the meta package still installs if
someone skips the ryzen_smu fork — they lose TDP read-back, not TDP control.

Note `depends=('oxp-tdpd')` is satisfied by `oxp-tdpd-bin` through
`provides=`. AUR helpers resolve that; bare `makepkg` does not, which is
expected and fine.

### Package names differ from upstream; module names must not

`oxpec-x2mini-dkms` builds `oxpec.ko`, and `ryzen-smu-x2mini-dkms` builds
`ryzen_smu.ko`. The **module** names have to stay as they are — they bind the
hardware and are what `modprobe`, `ryzenadj` and `oxp-tdpd` look for. Only the
*package* names are namespaced, so they never collide with upstream. Do not
"fix" the mismatch.

### `ryzen-smu-x2mini-dkms` is meant to be deleted

It exists for one line: `conflicts=('ryzen_smu-dkms-git')`. Our patch used to be
applied directly to that package's `/usr/src` tree, and every package update
silently reverted it — leaving a loaded-but-unpatched `ryzen_smu`, which breaks
ryzenadj entirely with an error that reads like a permissions problem.

Publishing a fork of someone else's package is only justified while that is
true. **Once the patch is upstreamed to
[amkillam/ryzen_smu](https://github.com/amkillam/ryzen_smu), delete this package
from the AUR** and move `ryzen_smu-dkms-git` back to a plain dependency.

## One-time AUR setup

1. **Create an AUR account** at <https://aur.archlinux.org>.

2. **Check the four names are free.** The AUR RPC sits behind bot protection, so
   check by hand:
   ```
   https://aur.archlinux.org/packages?K=oxp-tdpd-bin
   ```
   Repeat for each. A name already taken by someone else means renaming here
   first — the push would otherwise be rejected.

3. **Generate a dedicated CI key.** Not your personal SSH key:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/aur-ci -C "aur-ci onexplayer-x2mini" -N ""
   ```

4. **Add the public half** (`~/.ssh/aur-ci.pub`) to your AUR account under
   *My Account → SSH Public Key*.

5. **Add the private half** as a GitHub repository secret named
   `AUR_SSH_PRIVATE_KEY` (Settings → Secrets and variables → Actions). Paste the
   whole file including the trailing newline.

6. **Optionally** set repository *variables* `AUR_USERNAME` and `AUR_EMAIL` for
   the commit author. They default to the maintainer line in the PKGBUILDs.

You do not need to create the AUR repositories by hand — the AUR creates one on
the first push of a valid `PKGBUILD` + `.SRCINFO`, which the script handles.

## Publishing

Automatic on release publish. To rehearse first — and you should, at least
once — use the workflow's manual trigger with **dry run** left on, or run it
locally on any Arch box:

```bash
./packaging/aur-publish.sh --version 0.1.0 --dry-run
./packaging/aur-publish.sh --version 0.1.0 --only oxp-tdpd-bin   # one package
```

For each package the script sets `pkgver` from the tag, runs `updpkgsums`,
regenerates `.SRCINFO`, verifies the sources, then commits and pushes.

### Why this cannot run before the release exists

The PKGBUILDs hash the release tarball and the prebuilt binary, so `updpkgsums`
downloads them. Running it against an unpublished tag fails with a plain 404:

```
-> Downloading onexplayer-x2-mini-pro-cachyos-0.1.0.tar.gz...
curl: (22) The requested URL returned error: 404
```

That is why `aur.yml` triggers on `release: published` rather than on the tag.

### `SKIP` checksums

The committed PKGBUILDs carry `sha256sums=('SKIP')` as placeholders. **The AUR
rejects `SKIP` for anything that is not a VCS source**, so `aur-publish.sh`
replaces them with real hashes and refuses to push if any survive that are not
backed by a `git+` source. The one legitimate `SKIP` is the pinned upstream git
source in `ryzen-smu-x2mini-dkms`.

This does mean a local `makepkg -si` straight from a clone verifies nothing.
After the first release, commit the real sums so the local path is checked too:

```bash
cd packaging/oxpec-x2mini-dkms && updpkgsums
```

## Release order

```
git tag v0.1.0 && git push --tags
  └─ release.yml   builds oxp-tdpd (static), publishes tarball + SHA256SUMS
       └─ aur.yml  hashes those artifacts, pushes four packages to the AUR
```
