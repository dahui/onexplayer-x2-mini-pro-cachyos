# ONEXPLAYER X2Mini PRO on Linux

Makes the ONEXPLAYER X2Mini PRO (Strix Halo / Ryzen AI MAX+ 388) work properly
under Arch/CachyOS with Steam game mode — TDP, HDR, fan and charge control, the
extra buttons, and suspend.

Everything here was verified on hardware. Where something is inferred rather than
measured, the docs say so.

## What this fixes

| | Before | After |
|---|---|---|
| **TDP** | slider does nothing | 10–85 W through Steam's slider |
| **Suspend** | hard hang, forced power-off | s2idle works ([one kernel parameter](#suspend-needs-a-kernel-parameter-and-it-costs-the-npu)) |
| **HDR** | not offered | enabled, confirmed in-game (one Lua file) |
| **Fans / charge limit** | no sensors, no limit | RPM, PWM, charge threshold |
| **Brightness** | slider does nothing | works |
| **Extra buttons** | dead | OneXPlayer → QAM, Keyboard/Home → Steam+X |
| **Performance profiles** | absent | low-power / balanced / performance |

Not fixed yet: the **back paddles** and **RGB lighting** — both wait on Linux
7.2's `hid-oxp` driver and are not available on any kernel CachyOS ships today —
plus a **custom Home mapping** (InputPlumber bug). See
[what's still broken](#whats-still-broken).

## Requirements

- ONEXPLAYER X2Mini PRO. The installer refuses other machines unless `--force`.
- Arch or CachyOS, and a kernel with headers available.
- `paru` for the AUR route. Not needed for the
  [release route](#if-the-aur-is-down), which uses pacman alone.
- Tested on `7.1.6-1-cachyos-deckify`, `steamos-manager 26.4.1`,
  `inputplumber 0.78.0`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install.sh | bash
```

No clone needed. Everything it installs is a pacman package — an AUR one, or a
checksum-verified package from the [releases page](../../releases) — so the
script installs those and gets out of the way. It never copies configuration
into place itself, which is what keeps the script and a plain `paru` install
from drifting apart.

| | |
|---|---|
| `onexplayer-x2mini` | AUR — the configs; pulls in everything below |
| `steamos-manager`, `inputplumber` | repos — **not installed by default** on Handheld Edition |
| `oxp-tdpd-bin` | AUR — the TDP daemon, prebuilt, so no Go toolchain |
| `oxpec-x2mini-dkms` | AUR — fan and charge limit |
| `ryzen-smu-x2mini-dkms` | downloaded from the releases page, checksum-verified — [not on the AUR by design](packaging/README.md) |

Piping a script from the internet into `bash` deserves a look first — it
installs kernel modules and a root daemon:

```bash
curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install.sh | less
curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install.sh | bash -s -- --dry-run
```

Flags: `--dry-run`, `--skip-ryzen-smu`, `--force`. `OXP_TAG=v0.1.0` pins a
release instead of taking the latest.

### If the AUR is down

The AUR has extended outages — it was offline for a long stretch after a malware
incident. Every package is therefore attached to each
[release](../../releases) as well, and this installs from there with **plain
pacman and no AUR helper**:

```bash
curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install-from-release.sh | bash
```

Same packages, different transport. CI builds them from the same tagged
PKGBUILDs the AUR serves — `oxp-tdpd-bin` and `onexplayer-x2mini` are built by
fetching the very release artifacts an AUR build would fetch — so the machine
ends up identical either way. Everything is checksum-verified against
`SHA256SUMS`. It takes the same flags, plus `--keep` to leave the downloaded
packages behind.

The only dependencies not on the release page are `steamos-manager`,
`inputplumber`, `dkms` and `dbus`, and all four are in the CachyOS repos.

### Installing by hand instead

The scripts are only a convenience. Everything they install is a package, and
both channels carry the same ones — pick either.

**From the AUR:**

```bash
paru -S onexplayer-x2mini        # configs, TDP daemon, oxpec, and their deps
```

That covers everything except `ryzen-smu-x2mini-dkms`, which is published on the
[releases page](../../releases) rather than the AUR — it forks an existing AUR
package and is meant to disappear once its patch is upstreamed. Download that one
and `pacman -U` it alongside.

**From the releases page**, needing no AUR helper. Download all four packages and
`SHA256SUMS`, then hand pacman every file in a single transaction — that is what
lets it resolve the dependencies between them and pull `steamos-manager` and
`inputplumber` from the repos:

```bash
sha256sum -c --ignore-missing SHA256SUMS    # verify before installing
sudo pacman -U ./*.pkg.tar.zst
```

Either route, finish by starting the daemon:

```bash
sudo systemctl enable --now oxp-tdpd
sudo systemctl restart steamos-manager      # it binds remotes at startup
```

Two things worth knowing whichever way you go:

- **`ryzen-smu-x2mini-dkms` conflicts with `ryzen_smu-dkms-git` by design.** That
  conflict is the entire point of the package: it stops a routine update of the
  latter silently reverting the PM table patch and breaking ryzenadj. If you have
  `ryzen_smu-dkms-git` installed, remove it first — pacman's conflict prompt
  defaults to *no*, so a `--noconfirm` transaction aborts rather than replacing
  it. Skipping the fork entirely still leaves TDP *control* working; only
  read-back falls back to a cached value.
- Compared with the scripts you lose the hardware check, the kernel-headers
  resolution, the checksum verification, and the kernel-parameter notice below.

<details>
<summary>Building from a clone (development)</summary>

To install your working tree rather than the published release:

```bash
cd packaging/<package> && makepkg -si
```

Four PKGBUILDs live in [`packaging/`](packaging/README.md). Note the two that
source release artifacts (`oxp-tdpd-bin`, `onexplayer-x2mini`) still pull those
from the last published release, not from your checkout; the two DKMS packages
are self-contained and build entirely from local sources.
</details>

## Suspend needs a kernel parameter, and it costs the NPU

**Read this before deciding.** Nothing here applies it for you — kernel
parameters belong in the bootloader config, not a package.

Without it the machine **hangs entering s0ix** and needs a forced power-off.
There is no S3 fallback on this platform: it is s2idle or nothing.

```
amd_iommu=off mem_sleep_default=s2idle
```

| What you lose | Detail |
|---|---|
| **The NPU** | `amdxdna` refuses to initialise without an IOMMU. No local AI acceleration, and the error appears on every boot. |
| **DMA remapping** | Protection against malicious DMA from external devices. This machine has Thunderbolt, so it is not theoretical. GPU passthrough to VMs is also ruled out. |

For a gaming handheld this is usually the right trade — working sleep matters
daily, the NPU almost never does. **If you use the NPU, do not apply this:** keep
the IOMMU, skip suspend, and wait for a kernel that fixes s0ix entry.

Fully reversible. On this install (Limine), add the parameters to the
`KERNEL_CMDLINE[default]` line in `/etc/default/limine`, then
`sudo limine-update && sudo reboot`. Details, evidence and the test harness in
[docs/suspend.md](docs/suspend.md).

## What's still broken

| | Why | Fix |
|---|---|---|
| **Back paddles** | Emit nothing until the controller enters "full intercept" mode, which silences the entire X-Box gamepad — there is no mode giving both. | Linux 7.2's `hid-oxp`. **Not yet in CachyOS** — see below. |
| **RGB lighting** | No control at all. Nothing in this repo touches it, and there is no LED device to write to. | Also Linux 7.2's `hid-oxp` — see below. |
| **Custom Home mapping** | An InputPlumber 0.78 bug: any rule sourcing Home's capability corrupts the *next* button pressed. | Needs an upstream fix. Home's default Steam+X behaviour works regardless, so this is a nice-to-have. |
| **`amd_iommu=off`** | See above. | Worth re-testing on 7.2 — if s0ix entry is fixed, the NPU comes back. |

### Paddles and RGB are waiting on Linux 7.2

Both need `hid-oxp`, a Valve-authored HID driver. It is **already in mainline**,
and its device table matches this controller (`1a86:fe00`) — so no patch from us
is needed. It simply has not reached CachyOS yet, and running a beta or mainline
kernel is deliberately not a prerequisite for anything here.

**Until 7.2 arrives, neither works. Nothing you install from this repo changes
that**, so please do not go looking for a setting.

When it does land, expect the paddles to start working. RGB is **less certain**:
`hid-oxp` keeps a list of devices whose lighting it deliberately skips, and the
ONEXPLAYER APEX — which shares this machine's system board — is on it, while the
X2Mini PRO is not on the list either way. Whether that turns out to be right is
untested. If RGB does not appear on 7.2, that is a known possibility rather than
a broken install; the detail is in [CLAUDE.md](CLAUDE.md) §7.

## Verifying

```bash
steamosctl get-device-model                    # onexplayer_x2_mini_pro
steamosctl get-tdp-limit && sudo oxp-tdpd --status
systemctl is-active inputplumber oxp-tdpd steamos-manager
DISPLAY=:0 xprop -root GAMESCOPE_DISPLAY_SUPPORTS_HDR   # 1, in game mode
```

A working end state looks like:

```
oxpec        loaded    fan RPM + PWM + charge limit
ryzen_smu    loaded    patched for PM table 0x64010C
oxp-tdpd     active    10-85W through Steam's slider
inputplumber active    oxpx2m map; OneXPlayer -> QAM, Keyboard/Home -> Steam+X
HDR          enabled   AMS881KB01-0 OLED matched by gamescope
suspend      working   s2idle, with amd_iommu=off
```

**Do not judge the keyboard buttons from the Steam main menu.** Steam+X does not
raise the on-screen keyboard there — pressing Guide+X by hand does nothing either.
Test in a text field or Steam's controller mapping tester.

## Uninstall

Everything is a pacman package, so removal is one transaction:

```bash
sudo systemctl disable --now oxp-tdpd
sudo pacman -R onexplayer-x2mini oxp-tdpd-bin oxpec-x2mini-dkms ryzen-smu-x2mini-dkms
sudo systemd-hwdb update && sudo udevadm control --reload
sudo systemctl restart steamos-manager
```

Do not delete the files by hand — pacman owns them, and removing them behind its
back leaves its database claiming they are still installed. Both DKMS modules are
deregistered automatically by Arch's `71-dkms-remove` hook; no `dkms remove` is
needed.

`steamos-manager` and `inputplumber` are left in place, since they are ordinary
packages you may want anyway. Add them to the command if you installed them only
for this. `/etc/oxp-tdpd.conf` is in `backup=()`, so an edited copy is preserved
as `.pacsave` rather than deleted.

The kernel parameters, if you added them, are the one thing nothing here touches
— remove them from your bootloader config yourself.

If InputPlumber leaves the gamepad unusable after stopping — it `chmod 000`s its
source devices and does not reliably restore them:

```bash
sudo udevadm trigger --subsystem-match=input --action=add
```

## Documentation

[CLAUDE.md](CLAUDE.md) is the hardware reference: SMU protocol, message IDs, PM
table layout, and measured behaviour. Start there for porting work.

| | |
|---|---|
| [docs/findings.md](docs/findings.md) | What was broken and why, with evidence |
| [docs/tdp.md](docs/tdp.md) | Why no stock TDP method works here |
| [docs/tdpd.md](docs/tdpd.md) | The daemon: design, config, policies |
| [docs/suspend.md](docs/suspend.md) | Suspend, the IOMMU trade, and the test harness |
| [docs/hdr.md](docs/hdr.md) | HDR and the brightness investigation |
| [docs/ryzen-smu.md](docs/ryzen-smu.md) | PM table patch — **and whether you need it** |
| [docs/oxpec.md](docs/oxpec.md) | The EC driver patch |

The docs deliberately record what *didn't* work as well as what did. Several
dead ends here look correct on paper and cost real debugging time.

## Credits and licensing

GPL-2.0. Two parts have their own history:

- `packaging/oxpec-x2mini-dkms/oxpec.c` is a derived work of the OneXPlayer EC driver by
  **Joaquín I. Aramendía**, GPL-2.0-or-later, and keeps its own SPDX header.
- `tdpd/internal/smu/` originated in [z13ctl](https://github.com/dahui/z13ctl)
  (Apache-2.0, same author) and is relicensed GPL-2.0 here.

The suspend fix came from
[srsholmes/onexplayer-apex-bazzite-fixes](https://github.com/srsholmes/onexplayer-apex-bazzite-fixes),
and the vendor HID protocol from
[rmckayfleming/onexplayer-apex-cachyos](https://github.com/rmckayfleming/onexplayer-apex-cachyos)
— both for the APEX, which shares this board.
