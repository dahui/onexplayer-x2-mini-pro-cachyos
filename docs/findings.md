# ONEXPLAYER X2Mini PRO — SteamOS Manager / InputPlumber findings

Investigated 2026-08-04 on the unit itself.

## The machine

| | |
|---|---|
| `sys_vendor` | `ONE-NETBOOK` |
| `product_name` | `ONEXPLAYER X2Mini PRO` |
| `board_vendor` | `ONE-NETBOOK` |
| `board_name` | `ONEXPLAYER X2Mini PRO` |
| Kernel | `7.1.6-1-cachyos-deckify` |
| inputplumber | `0.78.0-1.1` |
| steamos-manager | `26.4.1-1` |

DMI modalias:

```
dmi:bvnAmericanMegatrendsInternational,LLC.:bvr0.20:bd06/10/2026:br0.20:efr0.13:svnONE-NETBOOK:pnONEXPLAYERX2MiniPRO:pvrStandard:rvnONE-NETBOOK:rnONEXPLAYERX2MiniPRO:rvrStandard:cvnDefaultstring:ct37:cvrDefaultstring:sku1:pfaONEXPLAYER:
```

**This board is the same as the ONEXPLAYER APEX**, so the platform/EC side is
aligned to the APEX rather than invented from scratch. That was independently
corroborated during the investigation — see below.

**The controllers are *not* the same as the APEX.** The board identity justifies
reusing the APEX's EC driver and USB topology; it does *not* justify assuming
the button mapping transfers. The `oxp8` capability map is currently in use as
the best available starting point, but it is unverified on this hardware and
should be treated as a placeholder — see "Still worth checking by hand".

## Root cause: InputPlumber was never starting

This was the whole problem. The steamos-manager TOML was fine; it had been
matching correctly the entire time (`steamosctl get-device-model` already
returned `onexplayer_x2_mini_pro`). The failure was one layer down.

`inputplumber.service` ships **`disabled` on purpose**. It is started on demand
by udev:

```
/usr/lib/udev/rules.d/90-inputplumber-autostart.rules
  ENV{USE_INPUTPLUMBER}=="1", TAG+="uaccess", TAG+="systemd", \
      ENV{SYSTEMD_WANTS}+="inputplumber.service"
```

`USE_INPUTPLUMBER=1` comes from the hwdb, keyed on the DMI modalias:

```
/usr/lib/udev/hwdb.d/60-inputplumber-autostart.hwdb
```

That file covers the X1, G1, F1, APEX and older OXP models, but has **no X2 Mini
entry**. The nearest match, `dmi:*svnONE-NETBOOK:pnONEXPLAYER:*`, requires a
colon immediately after `ONEXPLAYER`, so `pnONEXPLAYERX2MiniPRO:` does not
match it.

Confirmed before the fix:

```console
$ systemd-hwdb query "$(cat /sys/class/dmi/id/modalias)"
             # (no output)
$ systemctl is-active inputplumber
inactive
```

The consequence showed up in the steamos-manager log:

```
INFO steamos_manager: Starting inputplumber
INFO steamos_manager::inputplumber: Can't query initial InputPlumber devices:
     org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable
```

So the `[inputplumber] target_devices` block in the device TOML had nothing on
the other end of the bus.

**Fix:** `etc/udev/hwdb.d/61-inputplumber-onexplayer-x2mini.hwdb`.

## Second gap: no CompositeDevice config

Even once started, InputPlumber had no device profile matching this machine —
`/usr/share/inputplumber/devices/` has `50-onexplayer_apex.yaml`,
`50-onexplayer_x1.yaml` etc., but nothing for the X2 Mini. Without one it would
never claim the pad, the OXP button controller, or the IMU, so no `deck-uhid`
target would ever be created for steamos-manager to drive.

**Fix:** `etc/inputplumber/devices.d/50-onexplayer_x2_mini.yaml`, copied from the
APEX profile with the X2 Mini DMI matches substituted.

### The board-identity claim checks out

The APEX profile's USB topology matches this unit exactly. Both the pad and the
button controller sit behind the built-in `1a86:8091` hub on `0000:65:00.4`:

| Source | This unit | `50-onexplayer_apex.yaml` |
|---|---|---|
| `Microsoft X-Box 360 pad` | `usb-0000:65:00.4-1.3/input0` | same ("Original Firmware") |
| `HID 1a86:fe00` | `usb-0000:65:00.4-1.2/input0` | same |
| paddles (hidraw) | `1a86:fe00` iface 2 | same |
| IMU | `bmi260` @ `i2c-BMI0160:00` | same |

InputPlumber's own hidraw probe agrees, logging `Detected OXP X1 HID controller`.

The APEX profile's alternate `usb-0000:c5:00.4-*` paths ("Updated Firmware") are
carried over as-is — harmless if absent, and they cover a future BIOS update.

Note the scope of what this table establishes: the *enumeration* matches — same
hub, same addresses, same vendor/product IDs. It does not establish that the
controllers behave identically, and they do not.

### Capability map is a placeholder

Currently **`oxp8`** (`onexplayer_type8.yaml`, "OneXPlayer Type 8"), the APEX
map. **This is unverified on this hardware and known to be suspect** — the X2
Mini's controllers differ from the APEX's, so the button chords may well differ
too.

It is the best available starting point rather than a confirmed fit, for two
reasons: the shared board means the button controller sits at the same USB
address and speaks through the same `HID 1a86:fe00` interface, and `oxp8`'s own
header comments record that several chords (Orange long-press, Turbo+Orange,
KB+Orange) were never verified even on the APEX they were written for.

Expect this to need real work. See "Still worth checking by hand".

## Third gap: config claimed a GPU feature this APU lacks

The original TOML declared:

```toml
[gpu_power_profile]
driver = "amdgpu"
```

That method needs `pp_power_profile_mode`, which does not exist on this APU:

```console
$ ls /sys/class/drm/card1/device/pp_*
pp_cur_state  pp_dpm_dcefclk  pp_dpm_fclk  pp_dpm_mclk  pp_dpm_pcie
pp_dpm_sclk   pp_dpm_socclk   pp_force_state  pp_num_states  pp_od_clk_voltage
```

Removed. `[gpu_performance]` was kept — `power_dpm_force_performance_level` is
present and works.

## Fourth gap: amd-pmf performance profiles were unused

Available but not declared:

```console
$ cat /sys/class/platform-profile/platform-profile-0/{name,choices}
amd-pmf
low-power balanced performance
```

Added as `[performance_profile]`. Verified writing through end to end.

## Fifth gap: suspend hook was disabled

`inputplumber-suspend.service` (`WantedBy=sleep.target`) calls `HookSleep` /
`HookWake` on the InputPlumber bus so the virtual controller is torn down and
rebuilt across suspend. It was `disabled`, which breaks the controller after a
sleep cycle. Enabled.

## Fan + charge control: fixed via a patched oxpec. TDP: still unavailable.

steamos-manager supports exactly two TDP methods, and **both are closed on this
machine as shipped**:

| Method | Requires | Present? |
|---|---|---|
| `amdgpu_hwmon` | `power1_cap` on the amdgpu hwmon | No — only `power1_average`, `power1_input` |
| `firmware_attribute` | `/sys/class/firmware-attributes/*/attributes/ppt_pl1_spl` | No — the class does not exist |

Both would be provided by **`oxpec`**, the OneXPlayer EC driver, which *does*
ship in this kernel:

```
/usr/lib/modules/7.1.6-1-cachyos-deckify/kernel/drivers/platform/x86/oxpec.ko.zst
```

but refuses to bind:

```console
$ sudo modprobe oxpec
modprobe: ERROR: could not insert 'oxpec': No such device
```

Because its DMI table has no X2 Mini entry. It matches on **board** vendor/name:

```
alias: dmi*:rvn*ONE-NETBOOK*:rn*ONEXPLAYERAPEX*:
```

and this board reports `ONEXPLAYER X2Mini PRO`.

This is the one place the board-identity point pays off directly. Upstream maps
the APEX to board type `oxp_fly`:

```c
{
	.matches = {
		DMI_MATCH(DMI_BOARD_VENDOR, "ONE-NETBOOK"),
		DMI_EXACT_MATCH(DMI_BOARD_NAME, "ONEXPLAYER APEX"),
	},
	.driver_data = (void *)oxp_fly,
},
```

`oxp_fly` is a well-exercised path — the F1 family, A1X and APEX all use it.

**This was done and it works.** One DMI entry pointing at `oxp_fly`, built and
installed via DKMS (see `oxpec/`). The driver binds cleanly:

```
oxpec: loading out-of-tree module taints kernel.
ACPI: battery: new hook: OneXPlayer Battery
```

and produces:

| | |
|---|---|
| Fan RPM | `fan1_input` on new hwmon `oxp_ec` — ~2600 rpm |
| Fan PWM | `pwm1` = 193, `pwm1_enable` = 2 (EC-managed curve) |
| Turbo toggle | `/sys/devices/platform/oxp-platform/tt_toggle` = 1 |
| Charge limit | `charge_control_end_threshold` = 62 |

The charge limit was wired into the device TOML as
`[battery_charge_limit] method = "acpi_sb"` and verified through the daemon:
`steamosctl set-max-charge-level 80` → reads back 80 → restored to 62.

It auto-loads at boot with no extra config, since the patched module's DMI
modalias now resolves to `oxpec`.

### TDP is still unavailable, and oxpec was never going to fix it

An earlier draft of this document assumed oxpec would supply TDP. **That was
wrong.** Reading the driver source settles it: `oxpec.c` contains zero
references to `ppt_pl*`, firmware attributes, or TDP in any form. It is an EC
sensors / fan / charge driver only.

`/sys/class/firmware-attributes` still does not exist after loading it, so the
`firmware_attribute` method remains closed, and `power1_cap` is still absent, so
`amdgpu_hwmon` remains closed too. Both of steamos-manager's TDP methods have
nothing to bind to.

TDP control on this machine would need a driver that does not currently exist
for it. That is open work, not something the oxpec patch addresses.

`[fan_speed]` is also left unset: oxpec gives fan RPM and PWM, but not the
writable fan *target* attribute that section expects. `pwm1` is available for
external fan-curve tooling.

## Also noted, not acted on

- `HID 258a:001e` on `usb-0000:67:00.0-5` is a separate keyboard/mouse/consumer
  composite. Deliberately **not** folded into the CompositeDevice — it should
  stay an ordinary keyboard.
- `Error setting wifi backend: Wi-Fi backend not found in config` in the
  steamos-manager log is unrelated to input; it wants a `[wifi_backend]` in
  `/etc/steamos-manager/config.toml` and only matters if you use the Steam UI
  Wi-Fi debug tooling.
- `SetManualGpuClock: Invalid argument (os error 22)` — Steam probing manual GPU
  clocks. `pp_od_clk_voltage` exists but rejects the writes; not investigated.

## Verified end state

```
inputplumber:                active (udev-activated)
inputplumber-suspend:        enabled
steamos-manager (system):    active
steamos-manager (user):      active

oxpec (DKMS):                loaded, auto-loads at boot

Model: onexplayer_x2_mini_pro
Variant: X2Mini PRO
Perf profile: balanced        (low-power / balanced / performance, writes OK)
GPU perf level: auto
Max charge level: 62          (writes OK)
Fan: 2579 rpm, pwm1=193, pwm1_enable=2

CompositeDevice0 sources: hidraw4, event2, event5, event12, iio:device0
Target devices: deck-uhid, keyboard, mouse
Virtual pad: hidraw6 "Generic Steam Controller"
```

## Open work

1. **Button mapping — the real outstanding item.** The controllers differ from
   the APEX, so `oxp8` is a placeholder, not a fit. Walk the buttons with
   `sudo evtest` on the `HID 1a86:fe00` node (`event5`) and on the paddle
   hidraw, record what each physical button actually emits, and write a proper
   capability map. Drop it in `/etc/inputplumber/capability_maps.d/` under a new
   `id:` and point `capability_map_id:` at it — no need to touch the packaged
   maps. `onexplayer_type8.yaml` is a reasonable skeleton to start from, and its
   comments show the expected shape for chorded keys and paddle remapping.

   Worth capturing per button: Turbo, KB, Orange (short *and* long press), the
   two back paddles, and any combination chords. The oxp8 map expects several of
   these as multi-key keyboard chords rather than gamepad buttons.

2. **TDP.** No driver currently exposes it on this machine — see above. If OXP
   TDP support lands in `oxp-platform` / a firmware-attributes driver, add
   `[tdp_limit]` with `method = "firmware_attribute"` and set `range` from the
   real `min_value`/`max_value`, not a guess.

3. **Gyro orientation.** No `mount_matrix` is set (the APEX profile has none
   either). If the gyro reads inverted or axis-swapped in game, add one — see
   `50-onexplayer_x1.yaml` for the shape.
