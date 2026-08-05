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
| Kernel tested | `7.1.6-1-cachyos-deckify` |

DMI modalias:

```
dmi:bvnAmericanMegatrendsInternational,LLC.:bvr0.20:bd06/10/2026:br0.20:efr0.13:svnONE-NETBOOK:pnONEXPLAYERX2MiniPRO:pvrStandard:rvnONE-NETBOOK:rnONEXPLAYERX2MiniPRO:rvrStandard:cvnDefaultstring:ct37:cvrDefaultstring:sku1:pfaONEXPLAYER:
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

**The panel is the same as the Lenovo Legion Go 2.** Useful for display work,
but note gamescope 3.16 has no entry for the Go 2 either — its bundled
`lenovo.legiongo*.lua` scripts cover the LCD models only and declare
`supported = false`.

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

**The firmware reports PM table version `0x64010C`, which ryzen_smu does not
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

Plus the PM table patch in §2.3. The patch lives in `ryzen-smu/` and is
`git am`-ready for upstreaming — it fixes ryzenadj for everyone on this
hardware, not just us.

**It is applied to the AUR package's source in `/usr/src`, so a package update
reverts it.** Re-run `ryzen-smu/install-patch.sh`.

### 4.2 oxpec

Ships in-kernel but will not bind: its DMI table matches on **board** name and
has no X2 Mini entry, so `modprobe oxpec` fails with `ENODEV`. Upstream maps the
APEX to board type `oxp_fly`; since the board is identical, one table entry with
the same `driver_data` is the whole fix (`oxpec/`).

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

**Two things are needed, and the second is the one that matters:**

1. gamescope must be launched with `--hdr-enabled`. There is no environment
   variable equivalent — every `GAMESCOPE_*_HDR_*` variable is an output/feedback
   atom, not an input.
2. **gamescope only advertises HDR for panels it recognises.** It keeps
   `gamescope.config.known_displays`, populated by Lua scripts in
   `/usr/share/gamescope/scripts/00-gamescope/displays/`, matched by EDID. A
   panel with no entry gets no HDR regardless of the command line. Custom
   entries go in `/etc/gamescope/scripts/`, which is scanned afterwards and
   survives package updates.

Our entry matches on EDID vendor `SDC` and product `0x4301`.

Confirmed working on Like a Dragon: Infinite Wealth:

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
| Guide / Xbox | `BTN_MODE` on the X-Box pad | untouched, works |
| OneXPlayer | `KeyLeftCtrl`+`KeyLeftMeta`+`KeyLeftAlt` | `QuickAccess` (QAM) ✅ |
| Keyboard | `KeyLeftCtrl`+`KeyLeftMeta`+`KeyO` | `Keyboard` → Steam+X ✅ |
| Home | vendor HID B2 frame, btn `0x24` | Steam+X via stock profile ✅ |
| Back paddles | **nothing on any interface** | nothing — see below |

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
bug to "fix".

**The paddles require full-intercept mode**, and it is a bad trade today:

```
enable:   B2 3F 01 03 01 02 00...00 3F B2
disable:  B2 3F 01 00 01 02 00...00 3F B2
```

It makes the paddles report `0x22`/`0x23` **and silences the X-Box gamepad
completely** — sticks, triggers, d-pad and face buttons all have to be
reconstructed from vendor HID. There is no mode giving paddles *and* XInput.
InputPlumber 0.78's `oxp_hid` handles only four button ids and no axes. The
proper fix is **`hid-oxp`, a Valve-authored driver merged for Linux 7.2**.

**Availability, as of 2026-08-04: 7.2 has not shipped in CachyOS.** This unit
runs `7.1.6-1-cachyos-deckify`, and a beta or mainline kernel is deliberately
not a prerequisite for anything in this repo — the paddles wait for 7.2 to reach
the normal repos. Check `uname -r` before assuming this section is stale.

Protocol credit: `github.com/rmckayfleming/onexplayer-apex-cachyos`.

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
3. **Home is unmappable on 0.78.0.** Any rule sourcing its capability works
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
| vendor HID | hidraw `1a86:fe00` interface 2 — Home; paddles need intercept mode |
| keyboard | `AT Translated Set 2 keyboard`, `isa0060/serio0/input0` |
| IMU | `bmi260` at `i2c-BMI0160:00` |

`HID 258a:001e` on `usb-0000:67:00.0-5` is a separate keyboard/mouse composite
and should **not** be folded into the CompositeDevice.

---

## 8. Suspend — requires two kernel parameters

**s2idle works, but only with these on the kernel command line:**

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
is not needed here — confirm before porting it.

Consequence for anything driving TDP: SMU limits do **not** survive a power
transition, so a resume hook is required. Ours (logind `PrepareForSleep`) is now
confirmed working — it re-applies the limit at the resume timestamp.

---

## 9. Kernel version dependencies

Tested on `7.1.6-1-cachyos-deckify`. **Linux 7.2 had not shipped in CachyOS as of
2026-08-04**, and a beta or mainline kernel is deliberately not a prerequisite for
any of this. Check `uname -r` before assuming the rows below are stale.

| Item | Needs | Confidence | Effect |
|---|---|---|---|
| Back paddles | 7.2 (`hid-oxp`) | **Expected** — merged for 7.2 | Valve-authored driver that manages vendor intercept mode. Today the paddles emit nothing and enabling intercept by hand silences the entire X-Box gamepad (§7), so there is no usable workaround. |
| Dropping `amd_iommu=off` | a kernel that fixes s0ix entry | **Unproven** | Would restore the NPU and DMA remapping while keeping suspend. Cheap and reversible to test: remove the parameter, reboot, run `suspend/suspend-test.sh ladder`. |
| Custom Home mapping | *not* a kernel fix | **Unlikely from 7.2** | Blocked by an InputPlumber 0.78 userspace bug (§7). `hid-oxp` might sidestep it by reporting button `0x24` differently, but nothing guarantees that. |

Independent of kernel version: the `ryzen_smu` PM table patch (§2.3) and the
`oxpec` DMI entry (§4) are ours to upstream.

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

# fan / battery
for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = oxp_ec ] && echo $h; done
cat /sys/class/power_supply/BATT/charge_control_end_threshold

# display
DISPLAY=:0 xprop -root GAMESCOPE_DISPLAY_SUPPORTS_HDR GAMESCOPE_HDR_OUTPUT_FEEDBACK
edid-decode /sys/class/drm/card1-eDP-1/edid
journalctl -t p-holo-priv-write -b               # brightness writes
```

Upstream sources used, all fetched during this work:

| | |
|---|---|
| steamos-manager | `gitlab.steamos.cloud/holo/steamos-manager` — `examples/basic_remote.rs`, `src/power.rs` |
| RyzenAdj | `github.com/FlyGoat/RyzenAdj` — `lib/api.c` family dispatch, LGPL-3.0 |
| ryzen_smu | `github.com/amkillam/ryzen_smu` — `smu.c` |
| z13ctl | `github.com/dahui/z13ctl` — `internal/cli/smu.go` mailbox transport, Apache-2.0 |
