# ONEXPLAYER X2Mini PRO — hardware reference

Working notes for this device, written to be portable: the intent is that
adapting z13ctl (or anything else) to this handheld should not require
re-deriving any of it.

Everything here was verified on hardware. Where something is inferred rather
than measured it says so.

---

## 1. Device identity

| | |
|---|---|
| `sys_vendor` / `board_vendor` | `ONE-NETBOOK` |
| `product_name` / `board_name` | `ONEXPLAYER X2Mini PRO` |
| SoC | AMD Ryzen AI MAX+ 388 (Strix Halo), Radeon 8060S |
| CPUID | family `0x1A` (26), model `0x70` (112), stepping 0 |
| GPU PCI ID | `1002:1586` |
| Panel | Samsung `AMS881KB01-0` OLED, 1920x1200@144, 12 bpc |
| Kernel tested | `7.1.6-1-cachyos-deckify`; everything re-verified on `7.2.3-1-cachyos-deckify` with the v0.2.0 release (2026-09-26) |

DMI modalias:

BIOS 0.22 (07/23/2026) since 2026-09-26; everything before that date was measured
on 0.20 (06/10/2026). EC `0.13`, SMU `10.100.6.0` and PM table `0x64010C` did not
change with it.

```
dmi:bvnAmericanMegatrendsInternational,LLC.:bvr0.22:bd07/23/2026:br0.22:efr0.13:svnONE-NETBOOK:pnONEXPLAYERX2MiniPRO:pvrStandard:rvnONE-NETBOOK:rnONEXPLAYERX2MiniPRO:rvrStandard:cvnDefaultstring:ct37:cvrDefaultstring:sku1:pfaONEXPLAYER:
```

### Two identity claims that matter, and their limits

**The system board is the same as the ONEXPLAYER APEX.** This holds for the
platform/EC side and is independently corroborated: the shipping
`50-onexplayer_apex.yaml` InputPlumber profile lists byte-identical USB phys
paths to what this unit enumerates, and `oxpec` works with the APEX's board type
(`oxp_fly`) unchanged.

**The controllers are NOT the same as the APEX.** Board identity justifies
reusing the EC driver and USB topology; it does not transfer the button mapping.
The button controller differs from the APEX despite the shared board — see §7.

**The panel is the same as the Lenovo Legion Go 2.** That now pays off
directly: gamescope 3.16.30 ships `lenovo.legiongo2.oled.lua`, which matches this
panel's EDID and gives it HDR with no help from us (§5). Earlier 3.16 releases
had no Go 2 entry.

---

## 2. TDP via the SMU — the important section

No stock mechanism works on this device:

| Method | Requires | Status |
|---|---|---|
| `amdgpu_hwmon` | `power1_cap` on the amdgpu hwmon | **absent** — this APU exposes only `power1_average`, `power1_input` |
| `firmware_attribute` | `/sys/class/firmware-attributes/*/attributes/ppt_pl1_spl` | **absent** — that class comes from vendor platform drivers |

Only these shipped modules create `ppt_pl1_spl` firmware attributes:
`asus-armoury`, `asus-wmi`, `msi-wmi-platform`, `zotac-zone-platform`,
`lenovo/lenovo-wmi-other`. **There is no OneXPlayer equivalent.** `oxpec` does
not do TDP at all — its source has zero references to `ppt_pl*` or firmware
attributes; it is an EC sensors/fan/charge driver only.

So TDP has to go through the SMU mailbox directly.

### 2.1 Mailbox transport (ryzen_smu sysfs)

`/sys/kernel/ryzen_smu_drv/` — all binary little-endian u32, not text.

```
mp1_smu_cmd     MP1 mailbox: write cmd id, read back response code
rsmu_cmd        RSMU/PSMU mailbox
smu_args        6 x u32 argument block (24 bytes), shared across mailboxes
pm_table        metrics table (see §2.3)
pm_table_size
pm_table_version
codename        26 = CODENAME_STRIXHALO
mp1_if_version  4
version         10.100.6.0
```

Protocol per command:

1. write 24 bytes (6 × u32 LE) to `smu_args`
2. write 4 bytes (u32 LE command id) to the mailbox file
3. read 4 bytes (u32 LE response code) back from the mailbox file
4. read 24 bytes from `smu_args` for response arguments

Response codes: `0x01` OK, `0xFC` busy, `0xFD` rejected, `0xFE` unknown command,
`0xFF` failed.

**Serialise all commands.** The driver shares one argument buffer across
mailboxes, so concurrent commands corrupt each other's arguments.

**Writes must be a single full-size `write()`.** A short write to these binary
sysfs attributes fails with `ENOSPC`. This bites when piping into `dd` — a pipe
can short-read, so use `iflag=fullblock`:

```bash
args_le | dd of=$D/smu_args bs=24 count=1 iflag=fullblock
```

### 2.2 Strix Halo SMU message IDs

From RyzenAdj's family dispatch (`lib/api.c`, family `0x1A` model `112` →
`FAM_STRIXHALO`). **MP1 mailbox, arguments in milliwatts.**

| Limit | MP1 msg | Fallback |
|---|---|---|
| STAPM (sustained) | `0x14` | PSMU `0x31` |
| PPT fast | `0x15` | — |
| PPT slow | `0x16` | — |

PM table access uses the **PSMU** mailbox: `0x6` version/size, `0x66` table
address (64-bit on Strix Halo: `arg1 << 32 | arg0`), `0x65` transfer to DRAM.
In practice the ryzen_smu driver handles all of that behind the `pm_table` file.

Verified: writing 31000/53000/47000 mW via `0x14`/`0x15`/`0x16` produced
`0x01` OK and read back as 31.0/53.0/47.0 W.

### 2.3 PM table — this firmware needed reverse engineering

**Now upstream:** merged verbatim as amkillam/ryzen_smu `b098884`
(2026-08-15), so `ryzen_smu-dkms-git` handles this firmware as-is. The rest of
this section is how it was found and validated, which applies again if a
firmware update changes the version.

**The firmware reports PM table version `0x64010C`, which ryzen_smu did not
know.** Without a patch:

```
ryzen_smu: Family Codename: Strix Halo
ryzen_smu: Unknown PM table version: 0x0064010C
ryzen_smu: Failed to probe the PM table -- disabling feature (249)
```

`pm_table`, `pm_table_size` and `pm_table_version` are then never created, which
costs TDP read-back **and breaks ryzenadj outright** — it fails at init with
`Unable to get os_access Obj, check permission`, which looks like a permissions
problem and is not.

**The fix:** the version differs from the already-supported `0x64020C` only in
the middle byte, and takes the same size, `0xE50`. One case in `smu.c`:

```c
case 0x64010C:                        /* X2Mini PRO, SMU v10.100.6.0 */
    g_smu.pm_dram_map_size = 0xE50;
    break;
```

**How the size was validated** (worth repeating for any future firmware whose
version changes again): write three *distinct* limits through the mailbox, then
read the table back and check they land where the documented layout says.

```
written  stapm 31000 mW (0x14)   ->  offset 0x0  reads 31.000002
         fast  53000 mW (0x15)   ->  offset 0x8  reads 53.000004
         slow  47000 mW (0x16)   ->  offset 0x10 reads 47.000004
```

Distinct values matter — identical ones cannot disambiguate offsets.
`ryzenadj -i` then agreed independently, which is a good second opinion.

### 2.4 PM table layout

`float32` LE, **watts** (in contrast to the mailbox arguments, which are integer
milliwatts). The leading offsets are stable across table versions:

| offset | field |
|---|---|
| `0x0` | STAPM limit |
| `0x4` | STAPM current value |
| `0x8` | PPT fast limit |
| `0xC` | PPT fast current value |
| `0x10` | PPT slow limit |
| `0x14` | PPT slow current value |

Fields further in (`StapmTimeConst`, `PPT LIMIT APU`, `TDC LIMIT VDD`) read
`nan` on this firmware — RyzenAdj's offsets for those do not match this table
version. Do not rely on them.

Sanity-check reads: a NaN or wildly out-of-range STAPM limit means the layout
does not match, not that the hardware is idle.

```bash
sudo od -A n -t f4 -N 24 -w24 /sys/kernel/ryzen_smu_drv/pm_table
```

### 2.5 Firmware default limits

Captured on a clean boot before anything wrote them:

| | |
|---|---|
| PPT fast | **100 W** |
| PPT slow | **85 W** |
| STAPM | 85 W (already set by Steam at boot; the true firmware value may differ) |

**There is no "restore firmware default" SMU message.** Once fast/slow are
written the originals are unrecoverable except by reboot. Anything that writes
them should capture the originals first and persist them — re-reading at each
start is wrong, because a mid-session restart reads back whatever was last set,
not the firmware's.

### 2.6 Policy behaviour — measured, not assumed

All-core load, same 45 W request:

| | STAPM only | all three equal |
|---|---|---|
| power | 72–79 W | 45 W flat |
| temp | 90–95 °C | 74 °C |

**STAPM's time constant is minutes-scale, so it does not bound mid-range
settings in any window a user notices.** It held 72 W+ for a full 48 s test and
was still only creeping down.

The effect is strongly value-dependent, which makes it easy to misjudge:

| request | STAPM-only behaviour |
|---|---|
| 15 W | clamps hard — 15 W flat within 6 s, 46 °C |
| 45 W | 72–79 W at 95 °C, barely converging |

Testing only at 15 W suggests STAPM-only is fine. It is not. Set all three if
the slider should mean a ceiling.

Range exposed: **10–85 W**, matching the OneXConsole vendor app. That app also
caps at **55 W on battery** while allowing 85 W on mains — not currently
implemented, since `TdpLimitMax` is declared `emits_changed_signal="const"` on
the D-Bus side and a maximum that moved with the charger would break that
contract.

---

## 3. steamos-manager integration

steamos-manager can proxy its D-Bus interfaces to an external daemon. This is
the supported way to add TDP for hardware Valve does not ship.

**Registration** — `/etc/steamos-manager/remotes.d/<name>.toml`, format from
upstream's own `steamos-manager/examples/basic_remote.rs`:

```toml
[TdpLimit1]
bus_name = "io.aletheia.OxpTdp1"
object_path = "/io/aletheia/OxpTdp1"
```

**Interface** `com.steampowered.SteamOSManager1.TdpLimit1` on the **system bus**:

| property | type | access | units |
|---|---|---|---|
| `TdpLimit` | `u` | read-write | **watts** |
| `TdpLimitMin` | `u` | read, `const` | watts |
| `TdpLimitMax` | `u` | read, `const` | watts |

Units confirmed from `AmdgpuHwmonTdpLimitManager::get_tdp_limit`, which reads
`power1_cap` and divides by 1,000,000.

**Dispatch:** `tdp_limit_manager()` (`power.rs`) falls through to
`RemoteInterfaceLimitManager` when the device config has **no** `[tdp_limit]`
section at all. Setting `method = "remote_interface"` explicitly is equivalent
and self-documenting. Valid `method` values are `amdgpu_hwmon`,
`firmware_attribute`, `remote_interface` (serde snake_case).

Remotes are picked up dynamically (upstream test `remote_tdp_limit1_autoadd`),
so startup ordering does not matter — but steamos-manager binds registrations at
startup, so it needs a restart after a registration file is *installed*.

### Gotchas that cost real time here

- **The D-Bus policy must allow `org.freedesktop.DBus.Peer`.** zbus pings the
  remote for liveness before using it. Without that rule steamos-manager's user
  daemon exits at startup with `AccessDenied: Sender is not authorized to send
  message`, which reads like a bug in steamos-manager rather than a policy gap.
- **It is the *user* steamos-manager daemon that proxies**, not the root one, so
  a root-only send policy does not work.
- **Both daemons need restarting** after installing a registration — system and
  `--user`.
- `systemctl enable --now` is a **no-op on an already-running service**, so a
  reinstall silently keeps the old binary. Use `restart`.

---

## 4. Kernel modules

### 4.1 ryzen_smu

Must be the **amkillam fork** (`ryzen_smu-dkms-git`). The widely-packaged
leogx9r fork has no Strix Halo support and returns `0xFE UnknownCmd` for
everything. Detection lands at `smu.c`:

```c
case 0x70: /* Strix Halo (AI MAX+ 395) */
    g_smu.codename = CODENAME_STRIXHALO;
```

The PM table patch in §2.3 is upstream (`b098884`), and HEAD also carries
`d298366`, the Linux 7.2 build fix (`cpuid_eax` moved to `asm/cpuid/api.h`).
Install `ryzen_smu-dkms-git` (AUR; `provides=('ryzen_smu' 'ryzen_smu-dkms')`).
It is not in the CachyOS repos.

**The patched fork this repo shipped, `ryzen-smu-x2mini-dkms`, is gone.** It
pinned `1be4fb1`, from before the 7.2 fix, so on 7.2 it **fails to build**
(`modpost: "cpuid_eax" undefined`, upstream issue #51). `install.sh` removes it
if present.

**oxp-tdpd hard-requires it.** Its only SMU transport is this module's sysfs
mailbox, for writes as well as read-back, so `oxp-tdpd-bin` has
`depends=('ryzen_smu-dkms')`. An earlier claim that "TDP control works without
it" was about ryzenadj, not oxp-tdpd. The module autoloads through its PCI table
(`drv.c`, root complex `1022:1507`). `oxp-tdpd-bin` also lists it in
`modules-load.d` and orders the unit after `systemd-modules-load.service`,
because the unit's `ConditionPathExists` is evaluated once, and a late udev load
would skip the daemon for the whole boot.

### 4.2 oxpec

Ships in-kernel but will not bind before 7.3: its DMI table matches on **board**
name and has no X2 Mini entry, so `modprobe oxpec` fails with `ENODEV`. Upstream
maps the APEX to board type `oxp_fly`; since the board is identical, one table
entry with the same `driver_data` is the whole fix.

**Upstream from 7.3:** merged as mainline `1b3c0028`, first in v7.3-rc1, and not
backported to 7.2.y. Until then `packaging/oxpec-x2mini-dkms/` ships v7.2's
`oxpec.c` plus exactly that hunk (every API matches the 7.2.3 headers). Its
`dkms.conf` sets `BUILD_EXCLUSIVE_KERNEL` to kernels before 7.3, so from 7.3 the
DKMS copy is not built and does not shadow the in-tree driver from `/updates`.

Provides:

| | |
|---|---|
| fan RPM | `fan1_input` on hwmon `oxp_ec` |
| fan PWM | `pwm1`, `pwm1_enable` |
| turbo toggle | `/sys/devices/platform/oxp-platform/tt_toggle` |
| charge limit | `/sys/class/power_supply/BATT/charge_control_end_threshold` |

**Fan control, measured** (`pwm1_enable=1` for manual):

| pwm1 | RPM |
|---:|---:|
| 255 | 6398 |
| 191 | 5404 |
| 128 | 4053 |
| 64 | 2279 |
| 0 | 0 |

Monotonic across the range, and **zero-RPM works** — `pwm1=0` stops the fan
entirely, so a passive mode is possible.

Two things a fan-curve tool must handle:

- **Returning to auto (`pwm1_enable=2`) takes ~10 s** before the EC reasserts
  its curve. An immediate read shows 0 RPM and looks like the fan was left
  stopped; it spins back up on its own. Do not panic-write a manual value in
  that window.
- **`pwm1` readback is stale in auto mode** — it keeps reporting the last
  manually written value while the EC drives the fan independently. Trust
  `fan1_input`; `pwm1` is only meaningful when `pwm1_enable=1`.

Charge limit reads `0` when the EC has no threshold set, meaning "charge to
full", not a 0% limit. A hard power cycle resets it.

---

## 5. Display / HDR

The panel advertises HDR correctly (BT2020RGB, SMPTE ST2084, 1107 cd/m² peak,
476 cd/m² frame-average, 0.001 cd/m² min, Organic LED, 12 bpc) and the eDP-1
connector exposes `HDR_OUTPUT_METADATA`, `Colorspace` and `max bpc` (range 8–16,
so no bit-depth clamp).

**Exactly one thing is needed: a display-script entry.** gamescope only
advertises HDR for panels it recognises. It keeps
`gamescope.config.known_displays`, populated by Lua scripts in
`/usr/share/gamescope/scripts/00-gamescope/displays/`, matched by EDID. A panel
with no entry gets no HDR. Custom entries go in `/etc/gamescope/scripts/`, which
is scanned afterwards and survives package updates.

**That entry is now upstream.** gamescope 3.16.30's bundled
`lenovo.legiongo2.oled.lua` matches EDID vendor `SDC`, product `0x4301` (this
panel) at priority 5000. Verified on a fresh install with nothing of ours
present: `drm: Got known display: lenovo_legiongo2_oled (Lenovo Legion Go 2
OLED)`. It reads luminance and colorimetry from the EDID, and it sets
`software_backlight` because the panel ignores hardware backlight in PQ mode.
It also adds 48–144 Hz dynamic refresh; its 144 Hz vfp of 56 matches this
panel's EDID timing.

Our own script (`oxp_x2mini_oled`, same match, same priority) was **removed**. A
tie at 5000 against the same EDID left the winner to chance. Do not re-add a
custom entry unless it scores higher and there is a measured reason.
**Confirmed in games on 7.2.3 with the upstream entry:** a title created an
`HDR10_ST2084` swapchain, gamescope logged `xwm: HDR output enabled
(hdr_content_driven)`, and all three atoms read 1. `content_driven` means the
output switches to PQ only while HDR content is on screen and back to SDR after,
so an `HDR output disabled` line on leaving a game is expected. SDR brightness
still works through `holo-priv-write`, and the brightness slider also works
while HDR is active (PQ mode, through the entry's `software_backlight`;
confirmed 2026-09-26).

**`--hdr-enabled` is NOT required**, despite most guides implying otherwise, and
an earlier version of this document wrongly called it necessary. Verified with
the stock session script and no flag: all three atoms read 1 and HDR engaged in
a real title. The flag only pre-sets `cv_hdr_enabled` (default false,
`steamcompmgr.cpp:460`) at startup; Steam sets the same convar at runtime via
the `GAMESCOPE_DISPLAY_HDR_ENABLED` atom (`:5892`). That is why the Steam Deck
OLED works with an unmodified session script — the same script that ships here.

**`hdr.force_enabled` is a no-op.** `DRMBackend.cpp:2334` reads only
`supported`, `eotf`, and the three luminance values; the string is not in the
binary. Several bundled entries set it anyway. Do not copy it.

Confirmed working on Like a Dragon: Infinite Wealth (with our former entry):

```
drm: Got known display: oxp_x2mini_oled (AMS881KB01-0 OLED)
GAMESCOPE_DISPLAY_SUPPORTS_HDR   = 1
GAMESCOPE_DISPLAY_HDR_ENABLED    = 1
GAMESCOPE_HDR_OUTPUT_FEEDBACK    = 1   <- output actually engaged
```

**`HDR_OUTPUT_METADATA` reading empty is normal** with no HDR content on screen
— gamescope only switches the output to HDR10 PQ when it is needed.
`GAMESCOPE_HDR_OUTPUT_FEEDBACK` is the atom that confirms engagement.

Other notes:

- The Steam toggle is under **Settings → Display**, not the Quick Access menu.
- `STEAM_GAMESCOPE_FORCE_HDR_DEFAULT` and
  `STEAM_GAMESCOPE_FORCE_OUTPUT_TO_HDR10PQ_DEFAULT` are gated on
  `board_name = "Galileo"` upstream, so they never apply here.
- `gamescope-session.service` sets `RefuseManualStart=yes` — restart
  `gamescope-session.target` instead.

### Brightness

Works. `/sys/class/backlight/amdgpu_bl1`, max 472000.

Nothing in gamescope or steamos-manager writes the backlight — neither contains
a `/sys/class/backlight` reference. The actual mechanism is
`/usr/bin/holo-polkit-helpers/holo-priv-write` from `jupiter-hw-support`, a
polkit helper with a path allowlist. It permits backlight unconditionally,
writes the value, then `chgrp`s to uid 1000 and `chmod g+w` — after which Steam
writes the device directly. It logs every attempt under tag `p-holo-priv-write`,
which makes it easy to confirm.

Note the same helper gates `power*_cap`, `power_dpm_force_performance_level` and
`pp_od_clk_voltage` behind `/usr/lib/hwsupport/valve-hardware`, which returns
non-zero here — so Steam's *direct* writes to those are refused on this device.

---

## 6. Other working interfaces

- `[performance_profile]` via **amd-pmf**:
  `/sys/class/platform-profile/platform-profile-0`, name `amd-pmf`, choices
  `low-power balanced performance`. Works and is complementary to TDP.
- `[gpu_performance]` via `power_dpm_force_performance_level` — present.
- `[gpu_power_profile]` — **not usable**, this APU has no
  `pp_power_profile_mode`. Declaring it only produces D-Bus errors.

---

## 7. InputPlumber and the button controller

**Enabled**, using capability map `oxpx2m` (`etc/inputplumber/capability_maps.d/`),
captured on this unit. Its file header carries the full write-up; the essentials:

### What each button emits

Measured by reading every evdev node and all three `1a86:fe00` hidraw interfaces
simultaneously, with the Guide button as a separator marker — necessary because
buttons that emit *nothing* otherwise shift the sequence and mislabel their
neighbours.

| Button | Emits | Mapped to |
|---|---|---|
| Guide / Xbox | `BTN_MODE` on the X-Box pad | no rule ✅ — on 7.2 only with the watcher's page 3, see below |
| OneXPlayer | `KeyLeftCtrl`+`KeyLeftMeta`+`KeyLeftAlt` | `QuickAccess` (QAM) ✅ |
| Keyboard | `KeyLeftCtrl`+`KeyLeftMeta`+`KeyO` | `Keyboard` → Steam+X ✅ |
| Home | vendor HID B2 frame, btn `0x24` | Steam+X via stock profile ✅ |
| Back paddles | 7.1: **nothing on any interface**. 7.2: B2 `0x22` (L) / `0x23` (R), with the watcher | `LeftPaddle1`/`RightPaddle1` (L4/R4) via `oxp_hid` ✅ — see below |

**The chords are fixed-length pulses.** The firmware taps the final key of each
chord for ~10 ms regardless of how long the button is physically held —
measured: `KeyO` down at 31.50 s, up at 31.51 s. The capability-map rule is
satisfied only while *all* its keys are held, so the mapped output is a ~10 ms
pulse. Visible in Steam's mapping tester as a brief flash. Holding the button
longer does not lengthen it; on the Keyboard button that path triggers mouse
mode instead.

The two chords match the APEX's `oxp8` map ("KB short", "Turbo") as expected from
the shared board. This unit has no Turbo and no Orange button, so `oxp8`'s
`Meta+G` / `Meta+D` / `Meta+Sysrq` entries match nothing here.

**Firmware-consumed long presses.** The Keyboard button's long press toggles the
controller into mouse mode entirely inside the firmware — the host sees nothing,
so it cannot be bound. Symptom if it fires by accident: interface 1 starts
emitting report-ID `02` mouse deltas at ~1 kHz. The OneXPlayer button's long
press just holds the same chord, so it has no separate signal either.

### Vendor HID protocol (1a86:fe00 interface 2)

64-byte frames: `[cid, 0x3F, idx] + payload + zero padding + [0x3F, cid]`.
Button reports use cid `0xB2`, with **byte 6 = button id** and **byte 12 = state**
(`01` press, `02` release). Layout from InputPlumber's `oxp_hid/hid_report.rs`.

Button ids: `0x21` Guide, `0x22`/`0x23` the paddles, `0x24` the button this model
places at Home. InputPlumber's enum calls `0x24` `Keyboard` because it was
written for the OXP X1 — a misnomer here, confirmed by marker bracketing, not a
bug to "fix". Those ids are what 7.1's full-intercept frames reported. In the
**B4 button map** Guide's slot is `0x25` (mapped to gamepad code `0x21`) and
Home's is `0x24`.

**On 7.1 the paddles required full-intercept mode**, a bad trade:

```
enable:   B2 3F 01 03 01 02 00...00 3F B2
disable:  B2 3F 01 00 01 02 00...00 3F B2
```

It makes the paddles report `0x22`/`0x23` **and silences the X-Box gamepad
completely** — sticks, triggers, d-pad and face buttons all have to be
reconstructed from vendor HID. There is no mode giving paddles *and* XInput.
On Linux 7.2 they work without that trade, through hid-oxp's button map plus
a workaround for its init order. See the next section.

Protocol credit: `github.com/rmckayfleming/onexplayer-apex-cachyos`.

### hid-oxp (Linux 7.2): what it fixes, what it does not

`drivers/hid/hid-oxp.c` shipped in 7.2 (maintainer Derek J. Clark,
`linux-input@vger.kernel.org`) and binds this controller on
`7.2.3-1-cachyos-deckify`. Full measurements are in `docs/controller.md`. Every
claim below comes from raw HID reports in
`/sys/kernel/debug/hid/0003:1A86:FE00.*/events`, bracketed with known-good
buttons.

**The evdev nodes InputPlumber matches are unchanged.** The interface-0 keyboard
keeps name `HID 1a86:fe00` and phys `…-1.2/input0`, and hid-oxp registers no
input device of its own. Interface 1 collapses from Mouse/Consumer/System
Control nodes into one `HID 1a86:fe00` on `input1`; the config pins `input0`,
so this is harmless.

**Paddles: the init order is wrong for this board.** At bind and after resume,
`oxp_mcu_init_fn` sends the button map (`B4`; M1/M2 = `KEY_F16`/`KEY_F17`
*inside the MCU*), then cycles the mode debug→xinput (`B2 03…`, `B2 00…`), then
sets rumble (`B3`). On this unit the switch to xinput discards the map:

| state | paddles |
|---|---|
| after hid-oxp's init at boot | nothing |
| map re-sent (write `button_m1` with its own value) | B2 `0x22` left, `0x23` right |
| hid-oxp's init runs again | nothing |
| debug→xinput via sysfs with `paddle-watch` running | B2 `0x22`/`0x23`, X-Box pad live |

`0x22` is the **left** paddle here; on the APEX it is the right one, and `oxp8`
swaps them. No F16/F17 ever appears on the keyboard interface: the mapped code
only rides inside the B2 frame (byte 9 = `0x69`/`0x6a`). So the paddles reach
InputPlumber solely through the hidraw `oxp_hid` source, as `LeftPaddle1` and
`RightPaddle1`, and deck-uhid passes them through as L4/R4 with no
capability-map rule.

**The workaround**, shipped in `onexplayer-x2mini`: `paddle-watch`
(`oxp-x2mini-paddles.service`, started by a udev rule on hid-oxp bind) reads the
vendor hidraw node. When it sees the MCU confirm a switch to xinput
(`b2 3f 01 00 01`, the last step of every init), it re-sends the map by
rewriting `button_m1` with its current value. Any button write re-sends the
whole map, so sysfs remaps survive. It then sends a third map page restoring
Guide and Home (next paragraph). Across a real resume (2026-09-26) every button
kept working and the watcher had nothing to do (§8).

**Guide and Home: hid-oxp's map switches them off.** The map has 18 slots and
none for Guide or Home. Once it takes effect, both stop reporting on every
interface (usbmon: no Guide bit on the X-Box pad, no `0x24` frame). The fix is
the page HHD sends to the X2 series (`hhd-dev/hhd`, `hid_v1.py`,
`INITIALIZE_X2`), always *after* pages 1 and 2, since sending those resets
Guide and Home again:

```
B4 3F 01 | 02 38 02 03 01 | 24 02 02 05 00 00 | 25 01 21 00 00 00 | 00… | 3F B4
```

Verified 2026-09-26 at the deck-uhid output: Guide, both paddles, Home,
Keyboard and OneXPlayer all reach Steam together. Two traps:

- hid-oxp's table calls gamepad code `0x22` `BTN_GUIDE`. **Guide is `0x21`**;
  mapping it to `0x22` leaves Guide dead.
- **Page 3 is stored in the MCU and survives a full power-off.** A wrong value
  stays until this page is sent again. Debug-mode frames do not read back the
  stored mapping (normal-mode B2 frames do, in bytes 7–9), so do not derive
  values from them.

After writing any `button_*` attribute by hand, restart
`oxp-x2mini-paddles`; the watcher only reacts to mode switches.

**Do not remap M1/M2 in hid-oxp sysfs.** That remap happens inside the
controller, and moves the paddles out of the vendor frames InputPlumber reads.
Remap in Steam.

**It already binds this controller — no patch needed.** Its device table matches
`USB_VENDOR_ID_WCH` (`0x1a86`) / `USB_DEVICE_ID_ONEXPLAYER_GEN2` (`0xfe00`),
which is exactly the interface reverse-engineered above.

**Its constants confirm what was derived by hand**, and name the rest:

| hid-oxp | value | matches |
|---|---|---|
| `GEN2_MESSAGE_ID` | `0x3f` | the `[cid, 0x3F, idx] … [0x3F, cid]` framing |
| `OXP_FID_GEN2_TOGGLE_MODE` | `0xb2` | button reports / full-intercept mode |
| `OXP_FID_GEN2_RUMBLE_SET` | `0xb3` | — |
| `OXP_FID_GEN2_KEY_STATE` | `0xb4` | — |
| `OXP_FID_GEN2_STATUS_EVENT` | `0xb8` | **RGB**, both read and write |

RGB writes are `oxp_gen_2_property_out(0xb8, {OXP_SET_PROPERTY, 0x00, 0x02,
enabled, speed, brightness}, 6)`. State is read back from inbound `0xb8` frames
as `struct oxp_gen_2_rgb_report`: `enabled, speed, brightness, red, green, blue`
at bytes 6–11, `effect` at byte 15. **On this unit none of it takes effect**
(next section).

**Rumble** needs nothing: deck-uhid → force feedback on the X-Box pad (xpad), as
before. hid-oxp adds `rumble_intensity` (0–5), re-applied after every mode
switch.

**Possible false reset detection.** hid-oxp re-runs its init on any inbound `B8`
frame with `data[3] == 0xFE` (meant as the MCU's post-resume reset), and
`0xFE` is also the monocolor command byte. During testing a monocolor write was
followed ~3 s later by an unprompted re-init. The watcher covers that too.

### RGB: the open question, answered — this board belongs on the skip list

`hid-oxp` keeps `oxp_hybrid_mcu_list` — currently the APEX, G1 A and G1 i. Devices
on it **skip RGB LED registration** on the GEN2 usage page:

```c
if (up == GEN2_USAGE_PAGE && oxp_hybrid_mcu_device())
	goto skip_rgb;
```

It is not fatal — it gates only the RGB class device, so the paddles work either
way. But this machine is not on that list, so 7.2 will try to register RGB here.

**Tested on 7.2.3: RGB does not work over the `0xb8` path.** 7.2 registers
`oxp:rgb:joystick_rings`, but:

- `effect=green_breathing`: the MCU acknowledges (`b8 3f 01 0e …`), its status
  frame still reports effect `09` (cyberpunk), and the rings did not change.
- `effect=monocolor` + `multi_intensity=255 0 0`: no change either.

So the board should be on `oxp_hybrid_mcu_list`, like the APEX it shares a
board with. As things stand, 7.2 registers an LED device here that does nothing.
That is one of the hid-oxp changes noted in `docs/controller.md`, alongside the
paddle init order and the Guide/Home page; none has been sent yet.

### Three traps that each cost a debugging round

1. **`gamepad:Keyboard` works, but Steam+X does not open the keyboard from the
   main menu.** The stock profile expands that capability into Guide+North
   (Steam+X) and `handle_event` emits it as a real chord — reversed on release
   with an 80ms-per-event delay (`composite_device/mod.rs:905-935`). This chain
   genuinely functions: **Steam's controller mapping tester shows Steam+X when
   Home is pressed.** The reason nothing visibly happens is Steam's own
   behaviour — pressing Guide+X *by hand on the physical controller* also fails
   to raise the keyboard from the main menu. Do not debug the chain over this;
   test inside a text field, or use the mapping tester, before concluding
   anything is broken. (Separately, if the event ever reached the target
   un-expanded it would be dropped: `steam_deck_uhid.rs` has no arm for
   `Keyboard`. The profile intercepts it first, so that path is not normally
   reached.)

   Both the Keyboard button and Home resolve to Steam+X and are therefore
   indistinguishable downstream. If two distinct functions are ever needed,
   retarget the Keyboard rule to a free paddle slot (`RightPaddle2`/R5, leaving
   the Paddle1 slots for the real paddles under `hid-oxp`) and bind that in
   Steam — a bound paddle also fires in contexts where Steam+X does not.
2. **A capability used as a rule *source* must not be any rule's *target*.**
   Sources enter `translatable_capabilities`, and translated events are
   re-enqueued (`composite_device/mod.rs:729,735`), so the second rule's output
   re-enters translation and fires the first. Symptom: two buttons do the same
   thing.
3. **Home is unmappable on 0.78.0** (not yet re-tested on 0.81.0). Any rule sourcing its capability works
   alone then corrupts the *next* press: Home alone → 1 screenshot; Home then
   OneXPlayer → 2 screenshots and no QAM. The signature is Home's release
   failing to clear the capability from `translatable_active_inputs`. The
   bookkeeping reads correctly, so it appears to be an upstream bug — but it
   cannot be traced from outside, because the emit-queue and active-input logs
   are `log::trace!` and `Cargo.toml` sets `release_max_level_debug`, compiling
   them out. `LOG_LEVEL=trace` yields zero TRACE lines; confirming needs a debug
   build.

Debug logging (temporary, evaporates on reboot):

```bash
sudo mkdir -p /run/systemd/system/inputplumber.service.d
printf '[Service]\nEnvironment=LOG_LEVEL=debug\n' | \
  sudo tee /run/systemd/system/inputplumber.service.d/debug.conf
sudo systemctl daemon-reload && sudo systemctl restart inputplumber
```

Mechanics worth knowing:

- The service ships `disabled` and is **udev-activated**: `USE_INPUTPLUMBER=1`
  from the hwdb triggers `90-inputplumber-autostart.rules`. The stock hwdb has
  no X2 Mini entry, which is why nothing worked originally. Ours is installed at
  `/etc/udev/hwdb.d/61-inputplumber-onexplayer-x2mini.hwdb`.
- Config override dirs are `/etc/inputplumber/devices.d/` and
  `/etc/inputplumber/capability_maps.d/` (note the `.d`).
- `deck-uhid` is a valid target device even though the bundled JSON schema omits
  it — the schema is out of date, the binary supports it.
- **Stopping InputPlumber can leave the gamepad unusable.** It `chmod 000`s its
  source devices to hide them and does not reliably restore them on stop.
  Recover with `sudo udevadm trigger --subsystem-match=input --action=add`.
- **`inputplumber-suspend.service` must not stay enabled** when InputPlumber is
  stopped — it is a `Before=sleep.target` oneshot calling a D-Bus name nobody
  owns.
- `systemd-hwdb update` alone is not enough; udevd caches the compiled hwdb, so
  `udevadm control --reload` is needed too.

Hardware topology (identical to the APEX's "Original Firmware" paths):

| source | path |
|---|---|
| gamepad | `Microsoft X-Box 360 pad`, `usb-0000:65:00.4-1.3/input0` |
| OXP buttons | `HID 1a86:fe00`, `usb-0000:65:00.4-1.2/input0` |
| vendor HID | hidraw `1a86:fe00` interface 2 — Home, and on 7.2 the paddles |
| keyboard | `AT Translated Set 2 keyboard`, `isa0060/serio0/input0` |
| IMU | `bmi260` at `i2c-BMI0160:00` |

`HID 258a:001e` on `usb-0000:67:00.0-5` is a separate keyboard/mouse composite
and should **not** be folded into the CompositeDevice.

---

## 8. Suspend — requires two kernel parameters (7.1 and 7.2)

**s2idle works, but only with these on the kernel command line.** Verified on
7.1.6, and again on 7.2.3 (2026-09-26):

```
amd_iommu=off mem_sleep_default=s2idle
```

Without them the machine hangs hard entering s0ix and needs a forced power-off.
There is no S3 on this platform (`ACPI: PM: (supports S0 S4 S5)`), so it is
s2idle or nothing. Full write-up in `docs/suspend.md`.

Verified genuinely entering the low-power state, not merely completing:

```
Last S0i3 Status: Success
Time (in us) to S0i3:      674,335
Time (in us) in S0i3:   29,527,618      (29.5s of a 30s window)
amd_pmc: SMU idlemask s0i3: 0x7fffb9dd
```

**The cost — working sleep and a working NPU are mutually exclusive today.**
`amd_iommu=off` disables the IOMMU entirely, and the XDNA AI engine requires it:

```
amdxdna 0000:66:00.1: [drm] *ERROR* aie2_init: Running without IOMMU not supported
```

That error then appears on every boot; it is expected, not a regression. DMA
remapping is also gone, which matters on a machine with `thunderbolt` loaded, and
GPU passthrough is ruled out. There is no partial mode.

**Re-tested on 7.2.3: nothing short of `amd_iommu=off` works.** Every run was a
real suspend with a 30 s RTC wake:

| IOMMU | `amdxdna` | result |
|---|---|---|
| translated (stock) | loaded | freeze (pm_test ladder passed first) |
| translated | unloaded | freeze, fans left running |
| passthrough (`iommu=pt`) | loaded | freeze ×2 |
| off | cannot load | works, 29.49 s of 30 s in S0i3 |

That rules out the NPU (the first suspect, since `amd_iommu=off` also disables
it) and DMA translation (passthrough still freezes). What remains is what only
`amd_iommu=off` removes, chiefly interrupt remapping, and the likeliest source
is this board's firmware. The APEX, on the same board, needs the same fix, and
other Strix Halo machines suspend with the IOMMU on. That is inferred, not
traced: nothing reaches disk after the pre-sleep sync.

**BIOS 0.22 (07/23/2026) does not fix it.** Re-tested 2026-09-26 without
`amd_iommu=off`: the NPU loaded, and a real suspend froze exactly as on 0.20.
A later BIOS is still the realistic route to having both.

**Testing without a keyboard:** the harness refuses SSH sessions, but a
detached `systemd-run … CONSOLE_OVERRIDE=1 AUTO=1 WAKE_SECS=30 … none` survives
the connection dropping, and `/var/log/suspend-test.log` plus the persistent
journal carry the evidence.

**A frozen launch gets replayed.** When the machine hangs, the remote session
never receives the launch's result, and on reconnecting it has re-run the same
command, freezing the machine again. One BIOS re-test cost several forced
reboots that way. The harness now refuses to start while the log's last
`ATTEMPT` has no `SURVIVED`/`REJECTED` after it, logging `BLOCKED` instead;
`ACK_HANG=1` overrides it deliberately. Do not work around that guard, and do not
launch a real suspend without `amd_iommu=off` unless the user is at the device
and has asked for it.

This is a manual bootloader edit — nothing installs or reverts it automatically,
so anyone adapting this work should be told the trade explicitly rather than
finding a dead NPU later. Anyone who needs the NPU should keep the IOMMU and
forgo suspend. Re-testing after a major kernel bump is the only route to both.

**The out-of-tree modules were never at fault.** `ryzen_smu` was the prime
suspect for weeks (it shares the SMU mailbox with `amd_pmc` and `ioremap`s the PM
table). It suspends and resumes fine, as does `oxpec`; both were loaded through
every successful test. A `/sys/power/pm_test` ladder proved the whole software
path sound — `freezer`, `devices` and `platform` all passed, and only the real
s0ix entry hung. Do not repeat that bisect.

**The controller survives resume.** PCI `0000:65:00.4` stays bound to `xhci_hcd`
across the transition and all buttons work, so the APEX's resume-rebind service
is not needed here — confirm before porting it. On 7.2 hid-oxp *can*
re-initialise the MCU after resume (on the MCU's reset notice), which would
silence the paddles, Guide and Home until `paddle-watch` re-arms them (§7). On
the first real resume with the full package (2026-09-26: 23.6 s in S0i3, TDP
re-applied at 35 W) it did not: the map survived, every button worked, and the
watcher logged nothing.

Consequence for anything driving TDP: SMU limits do **not** survive a power
transition, so a resume hook is required. Ours (logind `PrepareForSleep`) is now
confirmed working — it re-applies the limit at the resume timestamp.

---

## 9. Kernel version dependencies

**Linux 7.2 is in CachyOS** (`7.2.3-1-cachyos-deckify`, running on this unit
since 2026-09-26). Status of everything that depended on a kernel version:

| Item | Needs | Status |
|---|---|---|
| Back paddles | 7.2 (`hid-oxp`) + `paddle-watch` | **Working** — hid-oxp alone leaves them silent on this board (init order, §7); the watcher re-arms them. The real fix is in hid-oxp. |
| Guide, Home with the paddles armed | `paddle-watch` (page 3) | **Working** — hid-oxp's map disables both; the watcher restores them after every map (§7). |
| RGB | an hid-oxp change | **Not working** — the controller ignores the `0xb8` RGB path; the board belongs on `oxp_hybrid_mcu_list` (§7). |
| Rumble | nothing | Works via xpad force feedback; hid-oxp adds a strength setting. |
| oxpec DMI entry | 7.3 | Upstream (`1b3c0028`, v7.3-rc1). The DKMS package covers 7.2 and older, and skips itself on 7.3+ (§4.2). |
| ryzen_smu PM table | none (out-of-tree) | Upstream (`b098884`). `ryzen_smu-dkms-git` builds on 7.2 only from `d298366` onward (§4.1). |
| Dropping `amd_iommu=off` | a firmware (or kernel) fix | **Still required on 7.2.3, BIOS 0.22.** Stock, NPU unloaded and `iommu=pt` all freeze; only `amd_iommu=off` reaches S0i3 (§8). |
| Custom Home mapping | an InputPlumber fix | Blocked on 0.78 (§7). Not re-tested on 0.81.0; hid-oxp does not change how `0x24` is reported. |

Still ours to upstream: the hid-oxp changes in `docs/controller.md` (paddle
init order; page 3 for Guide/Home and the `BTN_GUIDE` code; RGB skip list). Both kernel patches we did send are merged.

---

## 10. Quick reference

```bash
# TDP
steamosctl get-tdp-limit / set-tdp-limit <w>     # through steamos-manager
sudo oxp-tdpd --status                           # raw SMU limits
sudo ryzenadj -i                                 # second opinion
/etc/oxp-tdpd.conf                               # policy: all | stapm | headroom
/var/lib/oxp-tdpd/firmware-defaults.json         # captured fast/slow

# SMU
cat /sys/kernel/ryzen_smu_drv/codename           # 26 = Strix Halo
sudo od -A n -t f4 -N 24 -w24 /sys/kernel/ryzen_smu_drv/pm_table

# controller (hid-oxp, 7.2)
systemctl status oxp-x2mini-paddles              # paddle + Guide/Home re-arm watcher
D=$(dirname /sys/bus/hid/drivers/hid-oxp/*/button_m1); cat $D/gamepad_mode $D/button_m1
sudo cat /sys/kernel/debug/hid/0003:1A86:FE00.*/events   # raw reports, under any grab

# fan / battery
for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = oxp_ec ] && echo $h; done
cat /sys/class/power_supply/BATT/charge_control_end_threshold

# display
journalctl --user -b | grep 'known display'      # lenovo_legiongo2_oled
DISPLAY=:0 xprop -root GAMESCOPE_DISPLAY_SUPPORTS_HDR GAMESCOPE_HDR_OUTPUT_FEEDBACK
edid-decode /sys/class/drm/card1-eDP-1/edid
journalctl -t p-holo-priv-write -b               # brightness writes
```

Upstream sources used, all fetched during this work:

| | |
|---|---|
| steamos-manager | `gitlab.steamos.cloud/holo/steamos-manager` — `examples/basic_remote.rs`, `src/power.rs` |
| RyzenAdj | `github.com/FlyGoat/RyzenAdj` — `lib/api.c` family dispatch, LGPL-3.0 |
| ryzen_smu | `github.com/amkillam/ryzen_smu` — `smu.c`, `drv.c` |
| hid-oxp | `torvalds/linux` v7.2 — `drivers/hid/hid-oxp.c` |
| InputPlumber | `github.com/ShadowBlip/InputPlumber` v0.81.0 — `oxp_hid`, `steam_deck_uhid.rs` |
| gamescope | `/usr/share/gamescope/scripts/00-gamescope/displays/lenovo.legiongo2.oled.lua` (3.16.30) |
| z13ctl | `github.com/dahui/z13ctl` — `internal/cli/smu.go` mailbox transport, Apache-2.0 |
