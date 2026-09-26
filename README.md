# ONEXPLAYER X2Mini PRO on Linux

Makes the ONEXPLAYER X2Mini PRO (Strix Halo / Ryzen AI MAX+ 388) work properly
under Arch/CachyOS with Steam game mode: TDP, fan and charge control, the extra
buttons and back paddles, and suspend.

Everything here was verified on hardware. Where something is inferred rather than
measured, the docs say so.

**Wherever upstream now does the job, this repo steps aside.** Two of our fixes
are merged upstream, and HDR comes from gamescope itself:

| Fix | Upstream status |
|---|---|
| ryzen_smu PM table patch | merged as amkillam/ryzen_smu `b098884` → install `ryzen_smu-dkms-git` |
| HDR display entry | gamescope 3.16.30 ships one for this panel (it is the Legion Go 2's) |
| oxpec DMI entry | mainline `1b3c0028`, but only from **Linux 7.3** → still shipped here for 7.2 and older |

## What this fixes

| | Before | After |
|---|---|---|
| **TDP** | slider does nothing | 10–85 W through Steam's slider |
| **Fans / charge limit** | no sensors, no limit | RPM, PWM, charge threshold (kernels before 7.3) |
| **Extra buttons** | dead | OneXPlayer → QAM, Keyboard/Home → Steam+X |
| **Back paddles** | dead | L4 / R4, on Linux 7.2+ with a workaround for `hid-oxp` ([details](docs/controller.md)) |
| **Performance profiles** | absent | low-power / balanced / performance |
| **Suspend** | hard hang | s2idle works with [one kernel parameter](#suspend-and-the-kernel-parameter), still needed on 7.2 |
| **HDR** | not offered | works out of the box on gamescope 3.16.30+ (confirmed in games) |
| **Brightness** | slider does nothing | works |

Not fixed: **RGB lighting** (the controller ignores `hid-oxp`'s commands) and a
**custom Home mapping** (InputPlumber bug). See
[what's still broken](#whats-still-broken).

## Requirements

- ONEXPLAYER X2Mini PRO. The installer refuses other machines unless `--force`.
- Arch or CachyOS, and a kernel with headers available. **Linux 7.2 or later**
  for the back paddles; everything else also works on 7.1.
- An AUR helper (`paru` or `yay`) is convenient but not required. See
  [Install](#install).
- Originally verified end to end on `7.1.6-1-cachyos-deckify` with
  `steamos-manager 26.4.1` and `inputplumber 0.78.0`. On `7.2.3-1-cachyos-deckify`
  with `gamescope 3.16.30`, these have been re-verified so far: the controller,
  suspend (with the parameter), HDR in games, and brightness. The packages
  (TDP, fans, button mapping with `inputplumber 0.81.0`) have not yet been
  re-installed and re-tested on 7.2.3.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install.sh | bash
```

No clone needed. Everything it installs is a pacman package:

| | |
|---|---|
| `ryzen_smu-dkms-git` | **AUR**: the SMU driver oxp-tdpd talks through. Installed first (see below). |
| `oxpec-x2mini-dkms` | release: fan and charge limit, for kernels before 7.3 |
| `oxp-tdpd-bin` | release: the TDP daemon, prebuilt, so no Go toolchain |
| `onexplayer-x2mini` | release: the configs and the paddle watcher; pulls in the two below |
| `steamos-manager`, `inputplumber` | repos: **not installed by default** on Handheld Edition |

Our three packages come from the [releases page](../../releases) and are
checked against its `SHA256SUMS` before pacman sees them. The script never copies
configuration into place itself.

**`ryzen_smu-dkms-git` is required**, and it is the one package that is neither
ours nor in the CachyOS repos. oxp-tdpd sends every TDP command, not just
read-back, through the ryzen_smu kernel module. The script installs it with
`paru` or `yay` if you have one. Otherwise it asks whether to download the AUR
package source and build it with `makepkg`. If you decline, it stops and explains
why it is needed, rather than leaving a TDP slider that silently does nothing.
If an older install left the patched fork `ryzen-smu-x2mini-dkms` behind, the
script replaces it.

Piping a script from the internet into `bash` deserves a look first, because it
installs kernel modules and a root daemon:

```bash
curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install.sh | less
curl -fsSL https://raw.githubusercontent.com/dahui/onexplayer-x2-mini-pro-cachyos/main/install.sh | bash -s -- --dry-run
```

Flags: `--dry-run`, `--keep` (leave the downloaded packages behind), `--force`.
`OXP_TAG=v0.2.0` pins a release instead of taking the latest.

### Installing by hand instead

The script is only a convenience:

```bash
paru -S ryzen_smu-dkms-git                   # or build it from the AUR with makepkg
# download the three packages and SHA256SUMS from the releases page, then:
sha256sum -c --ignore-missing SHA256SUMS     # verify before installing
sudo pacman -U ./*.pkg.tar.zst               # one transaction, so deps resolve
sudo systemctl enable --now oxp-tdpd
sudo systemctl restart steamos-manager       # it binds remotes at startup
```

Compared with the script you lose the hardware check, the kernel-headers
resolution, and the kernel-parameter notice below.

<details>
<summary>Building from a clone (development)</summary>

To install your working tree rather than the published release:

```bash
cd packaging/<package> && makepkg -si
```

The three PKGBUILDs live in [`packaging/`](packaging/README.md). The two that
source release artifacts (`oxp-tdpd-bin`, `onexplayer-x2mini`) still pull those
from the published release named by their `pkgver`, not from your checkout.
`oxpec-x2mini-dkms` is self-contained and builds entirely from local sources.
</details>

## Suspend and the kernel parameter

**Read this before deciding.** Nothing here applies it for you: kernel parameters
belong in the bootloader config, not a package.

Without it the machine **hangs entering s0ix** and needs a forced power-off,
on Linux 7.1 and still on 7.2. There is no S3 fallback on this platform: it is
s2idle or nothing.

```
amd_iommu=off mem_sleep_default=s2idle
```

| What you lose | Detail |
|---|---|
| **The NPU** | `amdxdna` refuses to initialise without an IOMMU. No local AI acceleration, and the error appears on every boot. |
| **DMA remapping** | Protection against malicious DMA from external devices. This machine has Thunderbolt, so it is not theoretical. GPU passthrough to VMs is also ruled out. |

**Re-tested on 7.2.3: still required.** Keeping the IOMMU in passthrough mode
(`iommu=pt`) and unloading the NPU driver both still freeze; only
`amd_iommu=off` works. The evidence points at this board's firmware, since the
APEX shares the board and the fix, and a BIOS update is the realistic way out.
Details and the test harness: [docs/suspend.md](docs/suspend.md).

On Limine, add the parameters to the `KERNEL_CMDLINE[default]` line in
`/etc/default/limine`, then `sudo limine-update && sudo reboot`. It is fully
reversible. For a gaming handheld this is usually the right trade, since
working sleep matters daily and the NPU almost never does. **If you use the NPU,
do not apply it:** keep the IOMMU and skip suspend.

## What's still broken

| | Why | Fix |
|---|---|---|
| **RGB lighting** | `hid-oxp` registers `oxp:rgb:joystick_rings`, but the controller acknowledges and ignores its commands. This unit is APEX-like here, and the APEX is on the driver's skip list for exactly this reason. | Upstream: add this board to `oxp_hybrid_mcu_list` so the dud device goes away ([notes](docs/controller.md#notes-for-upstream-hid-oxp)). Real control would need a different interface. |
| **Custom Home mapping** | An InputPlumber 0.78 bug: any rule sourcing Home's capability corrupts the *next* button pressed. Not yet re-tested on 0.81. | Needs an upstream fix. Home's default Steam+X behaviour works regardless, so this is a nice-to-have. |
| **Suspend costs the NPU** | `amd_iommu=off` is still required on 7.2 (see above). | A BIOS update from OneXPlayer. Re-test after one. |

### Back paddles: working, with a workaround

Linux 7.2's `hid-oxp` binds this controller but leaves the paddles silent: its
init sends the button map, then switches the controller's mode, and on this unit
the mode switch discards the map. `onexplayer-x2mini` ships a small watcher
(`oxp-x2mini-paddles.service`, started by udev) that re-sends the map after
every such switch. The paddles then reach Steam as **L4 / R4**, and you bind
them in Steam's controller settings like on a Deck. Full measurements, and notes
for a proper upstream fix, are in [docs/controller.md](docs/controller.md).

## Verifying

```bash
steamosctl get-device-model                    # onexplayer_x2_mini_pro
steamosctl get-tdp-limit && sudo oxp-tdpd --status
systemctl is-active inputplumber oxp-tdpd steamos-manager oxp-x2mini-paddles
journalctl --user -b | grep 'known display'    # lenovo_legiongo2_oled, in game mode
```

A working end state looks like:

```
oxpec          loaded    fan RPM + PWM + charge limit
ryzen_smu      loaded    ryzen_smu-dkms-git, PM table 0x64010C
oxp-tdpd       active    10-85W through Steam's slider
inputplumber   active    oxpx2m map; OneXPlayer -> QAM, Keyboard/Home -> Steam+X
paddles        active    L4 / R4 via hid-oxp + oxp-x2mini-paddles
HDR            enabled   panel matched by gamescope's Legion Go 2 entry
```

**Do not judge the keyboard buttons from the Steam main menu.** Steam+X does not
raise the on-screen keyboard there; pressing Guide+X by hand does nothing either.
Test in a text field or Steam's controller mapping tester.

## Uninstall

Everything is a pacman package, so removal is one transaction:

```bash
sudo systemctl disable --now oxp-tdpd
sudo pacman -R onexplayer-x2mini oxp-tdpd-bin oxpec-x2mini-dkms
sudo systemctl restart steamos-manager
```

Do not delete the files by hand. pacman owns them, and removing them behind its
back leaves its database claiming they are still installed. The DKMS module is
deregistered automatically by Arch's `71-dkms-remove` hook, and the package's
scriptlet refreshes udev and the hwdb.

`ryzen_smu-dkms-git`, `steamos-manager` and `inputplumber` are left in place,
since they are ordinary packages you may want anyway. Add them to the command if
you installed them only for this. `/etc/oxp-tdpd.conf` is in `backup=()`, so an
edited copy is preserved as `.pacsave` rather than deleted.

The kernel parameters, if you added them, are the one thing nothing here touches.
Remove them from your bootloader config yourself.

If InputPlumber leaves the gamepad unusable after stopping (it `chmod 000`s its
source devices and does not reliably restore them):

```bash
sudo udevadm trigger --subsystem-match=input --action=add
```

## Documentation

[CLAUDE.md](CLAUDE.md) is the hardware reference: SMU protocol, message IDs, PM
table layout, and measured behaviour. Start there for porting work.

| | |
|---|---|
| [docs/controller.md](docs/controller.md) | hid-oxp on 7.2: paddles, the watcher, RGB, upstream notes |
| [docs/findings.md](docs/findings.md) | What was broken and why, with evidence (7.1 snapshot) |
| [docs/tdp.md](docs/tdp.md) | Why no stock TDP method works here |
| [docs/tdpd.md](docs/tdpd.md) | The daemon: design, config, policies |
| [docs/suspend.md](docs/suspend.md) | Suspend, the IOMMU trade, and the test harness |
| [docs/hdr.md](docs/hdr.md) | HDR (now upstream) and the brightness investigation |
| [docs/ryzen-smu.md](docs/ryzen-smu.md) | The PM table patch, now upstream |
| [docs/oxpec.md](docs/oxpec.md) | The EC driver patch, upstream from 7.3 |

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
— both for the APEX, which shares this board. The paddle and RGB behaviour on 7.2
was worked out against `hid-oxp` (Derek J. Clark) in mainline.
