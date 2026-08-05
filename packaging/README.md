# Packaging

Four packages. `makepkg -si` in any of these directories installs it locally,
and `install.sh` does exactly that for the two kernel modules.

Three of the four also go to the AUR via [`aur-publish.sh`](aur-publish.sh),
driven by [`../.github/workflows/aur.yml`](../.github/workflows/aur.yml)
automatically after a successful release. The fourth deliberately does not —
see below.

## The package set

Listed in dependency order — **leaves first**, because the AUR cannot resolve a
dependency that has not been published yet.

| Package | What it ships | Distribution |
|---|---|---|
| `oxpec-x2mini-dkms` | Patched EC driver source + `dkms.conf` | AUR + release |
| `ryzen-smu-x2mini-dkms` | ryzen_smu + the PM table `0x64010C` patch | **Release only — never the AUR.** See below. |
| `oxp-tdpd-bin` | Prebuilt daemon, unit, D-Bus policy, `remotes.d` | AUR + release |
| `onexplayer-x2mini` | steamos-manager, InputPlumber, hwdb and gamescope configs | AUR + release |

Both DKMS packages are `arch=any` and ship **source only** — the user's machine
compiles the module against its own kernel. That is what makes a CI-built
`.pkg.tar.zst` portable to any Arch install, and why the release page is a
viable distribution channel rather than a second-class one.

### Dependencies pull their own weight

Neither `steamos-manager` nor `inputplumber` is installed by default on CachyOS
Handheld Edition, so both are **hard** dependencies of `onexplayer-x2mini`. That
matters more than it looks: this package ships configuration *for* each of them,
and those files are inert without the daemon that reads them. Left optional, a
fresh install would lay the configs down correctly and the buttons or the TDP
slider would simply do nothing, with no error anywhere.

Two things stay optional, for reasons rather than by omission:

- **`ryzen-smu-x2mini-dkms`** cannot be a hard dependency — it is not on the AUR
  (see below), so the reference would be unresolvable. TDP *control* works
  without it; only read-back falls back to a cached value.
- **`gamescope`** is left optional so this package does not drag a compositor
  onto a non-gaming install. The display script is inert without it, and
  harmless.

**Kernel headers are not a dependency either**, following the usual DKMS
convention — the right package depends on which kernel is installed. Both DKMS
packages instead check at install time and print the exact command, because the
failure mode is otherwise silent: no headers means the module never builds and
the feature just does not work.

Note `depends=('oxp-tdpd')` is satisfied by `oxp-tdpd-bin` through
`provides=`. AUR helpers resolve that; bare `makepkg` does not, which is
expected and fine.

### Package names differ from upstream; module names must not

`oxpec-x2mini-dkms` builds `oxpec.ko`, and `ryzen-smu-x2mini-dkms` builds
`ryzen_smu.ko`. The **module** names have to stay as they are — they bind the
hardware and are what `modprobe`, `ryzenadj` and `oxp-tdpd` look for. Only the
*package* names are namespaced, so they never collide with upstream. Do not
"fix" the mismatch.

### `ryzen-smu-x2mini-dkms` never goes to the AUR

It exists for one line: `conflicts=('ryzen_smu-dkms-git')`. Our patch used to be
applied directly to that package's `/usr/src` tree, and every package update
silently reverted it — leaving a loaded-but-unpatched `ryzen_smu`, which breaks
ryzenadj entirely with an error that reads like a permissions problem.

It is the only package here that **forks an existing AUR package**, and it is
meant to disappear once the patch reaches
[amkillam/ryzen_smu](https://github.com/amkillam/ryzen_smu). A short-lived fork
of someone else's package, sitting in a shared namespace, is precisely the thing
that quietly becomes permanent — so it is distributed on the GitHub release page
instead, where it can simply stop being built.

Users lose nothing: `install.sh` builds and installs it from the checkout, and it
is still a real pacman package, so the `conflicts` protection and clean removal
both work exactly as they would from the AUR.

`oxpec-x2mini-dkms` is a different case and is fine on the AUR — it forks
nothing, being a DKMS build of an *in-kernel* driver with one DMI ID added, which
is a routine AUR pattern.

## One-time AUR setup

1. **Create an AUR account** at <https://aur.archlinux.org>.

2. **Check the three names are free.** The AUR RPC sits behind bot protection, so
   check by hand:
   ```
   https://aur.archlinux.org/packages?K=oxp-tdpd-bin
   ```
   Repeat for `oxpec-x2mini-dkms` and `onexplayer-x2mini`. A name already taken
   by someone else means renaming here first — the push would otherwise be
   rejected. (`ryzen-smu-x2mini-dkms` does not need checking; it never goes to
   the AUR.)

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

**Automatic.** Pushing a `v*` tag runs `release.yml`, and `aur.yml` fires when
that completes successfully, publishing all three packages.

### Why the trigger is `workflow_run` and not `release: published`

The obvious trigger does not work. **GitHub does not start workflows from events
created with `GITHUB_TOKEN`**, so a release published by our own `release.yml`
never fires a `release` trigger — v0.1.0 demonstrated this by silently doing
nothing at all. `workflow_run` keys off the upstream workflow *completing*,
which is not subject to that restriction.

It checks out `workflow_run.head_sha` rather than the default branch, so the
PKGBUILDs and their local sources match the artifacts being hashed, and it only
runs when the release actually succeeded and the ref was a tag.

### Rehearsing

To rehearse — worth doing at least once — use the manual trigger with **dry run**
left on, or run it locally on any Arch box:

```bash
./packaging/aur-publish.sh --version 0.1.0 --dry-run
./packaging/aur-publish.sh --version 0.1.0 --only oxp-tdpd-bin   # one package
```

For each package the script sets `pkgver` from the tag, runs `updpkgsums`,
regenerates `.SRCINFO`, verifies the sources, then commits and pushes.

### Why this cannot run before the release exists

`oxp-tdpd-bin` and `onexplayer-x2mini` hash the release tarball and the prebuilt
binary, so `updpkgsums` downloads them. Running against an unpublished tag fails
with a plain 404:

```
-> Downloading onexplayer-x2-mini-pro-cachyos-0.1.0.tar.gz...
curl: (22) The requested URL returned error: 404
```

That is why `aur.yml` triggers on `release: published` rather than on the tag.

### `SKIP` checksums

**The AUR rejects `SKIP` for anything that is not a VCS source.** The two
release-sourced PKGBUILDs (`oxp-tdpd-bin`, `onexplayer-x2mini`) carry `SKIP` as a
placeholder because the artifacts they hash do not exist until a release is cut;
`aur-publish.sh` replaces them and refuses to push if any survive that are not
backed by a `git+` source — counted, not merely detected, so a tarball cannot
hide behind a package's unrelated git source.

The two self-contained packages already carry real checksums, because their
sources sit next to the PKGBUILD. The one permanent, legitimate `SKIP` is the
pinned upstream git source in `ryzen-smu-x2mini-dkms`.

## Release order

```
git tag v0.1.1 && git push origin v0.1.1
  └─ release.yml   oxp-tdpd (static) + both DKMS .pkg.tar.zst
                   + source tarball + SHA256SUMS
       └─ aur.yml  (workflow_run, automatic) hashes those artifacts and
                   pushes 3 packages to the AUR
                   ryzen-smu-x2mini-dkms stays on the release page
```

Nothing else is needed for a release: tag, and the rest follows.
