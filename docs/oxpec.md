# oxpec support for the ONEXPLAYER X2Mini PRO

**Status: built, installed via DKMS, and verified working on this machine.**

## Why

`oxpec` is the OneXPlayer EC driver. It is already built in this kernel but
would not bind:

```console
$ sudo modprobe oxpec
modprobe: ERROR: could not insert 'oxpec': No such device
```

Its DMI table matches on **board** vendor/name and had no X2 Mini entry. This
board is the same as the ONEXPLAYER APEX, which upstream already handles as
board type `oxp_fly`, so the fix is one table entry.

## What the patch does

`0001-oxpec-add-ONEXPLAYER-X2Mini-PRO.patch` adds an entry immediately before
the APEX one in `drivers/platform/x86/oxpec.c`:

```c
{
	.matches = {
		DMI_MATCH(DMI_BOARD_VENDOR, "ONE-NETBOOK"),
		DMI_EXACT_MATCH(DMI_BOARD_NAME, "ONEXPLAYER X2Mini PRO"),
	},
	.driver_data = (void *)oxp_fly,
},
```

`oxp_fly` is shared by the F1 family, AOKZOE A1X and the APEX, so it is a
well-exercised path rather than a new register map.

## What it gets you — and what it does not

Verified on this unit after loading:

| | |
|---|---|
| Fan RPM | `fan1_input` on hwmon `oxp_ec` — reads ~2600 rpm at idle |
| Fan PWM | `pwm1`, `pwm1_enable` on the same hwmon — **exercised, see below** |
| Turbo button toggle | `/sys/devices/platform/oxp-platform/tt_toggle` |
| Battery charge limit | `/sys/class/power_supply/BATT/charge_control_end_threshold` |

### Fan control, actually exercised

Swept `pwm1` in manual mode (`pwm1_enable=1`) and measured `fan1_input`, 5s
settle between steps:

| pwm1 | measured RPM |
|---:|---:|
| 255 | 6398 |
| 191 | 5404 |
| 128 | 4053 |
| 64 | 2279 |
| 0 | 0 |

Clean monotonic response across the full range, readback always matched the
written value. **Zero-RPM works** — `pwm1=0` stops the fan completely, so a
passive/silent mode is possible.

Two things a fan-curve tool needs to handle:

- **Returning to auto (`pwm1_enable=2`) is not instant.** The EC takes roughly
  10 seconds to reassert its own curve. Reading `fan1_input` immediately after
  the switch showed 0 RPM and looked like the fan had been left stopped; it
  spun back up on its own shortly after. Do not panic-write a manual value in
  that window, and do not treat a single early reading as failure.
- **`pwm1` readback is stale in auto mode.** It keeps reporting whatever was
  last written manually while the EC drives the fan independently. Trust
  `fan1_input` for the real state; `pwm1` is only meaningful when
  `pwm1_enable=1`.

Auto control was confirmed healthy afterwards — RPM varying on its own
(2613 → 2616 → 1010) at a steady 41 °C idle.

**No TDP control.** This is worth being clear about, because it is easy to
assume otherwise. `oxpec` is an EC sensors / fan / charge driver and contains no
TDP support whatsoever — confirmed by reading its source, which has zero
references to `ppt_pl*`, firmware attributes, or TDP of any kind. steamos-manager
supports exactly two TDP methods and both remain closed here:

- `amdgpu_hwmon` needs `power1_cap`, absent from this APU's hwmon
- `firmware_attribute` needs `/sys/class/firmware-attributes`, which still does
  not exist after loading oxpec

So TDP control on this machine needs a different driver than anything currently
available. That is unfinished business, not something this patch addresses.

## Install

```bash
./oxpec/install-oxpec.sh
```

Needs `dkms` and kernel headers (both already present). It stages `src/oxpec.c`
— the exact patched source verified on this machine — into
`/usr/src/oxpec-x2mini-1.0/`, builds it, installs it to `/updates/dkms/`, and
loads it.

DKMS rebuilds it automatically on kernel updates, and it archives the stock
`oxpec.ko.zst` so removal restores the original cleanly.

The module auto-loads at boot with no extra config: once patched, the DMI
modalias resolves to `oxpec`, so udev loads it during coldplug.

```console
$ sudo modprobe -R "$(cat /sys/class/dmi/id/modalias)"
oxpec
```

### Uninstall

```bash
sudo dkms remove -m oxpec-x2mini -v 1.0 --all
sudo modprobe -r oxpec
```

That restores the stock module. Nothing in the parent directory depends on
oxpec except the `[battery_charge_limit]` section of the device TOML, which goes
inert rather than breaking.

## Rebuilding the patch from upstream

`src/oxpec.c` is pinned to what was verified here. To re-derive it against a
newer kernel:

```bash
curl -sSLo oxpec.c https://raw.githubusercontent.com/torvalds/linux/master/drivers/platform/x86/oxpec.c
patch -p4 < 0001-oxpec-add-ONEXPLAYER-X2Mini-PRO.patch
```

Note `-p4` — the patch paths are `a/drivers/platform/x86/oxpec.c` and the target
is a bare `oxpec.c`. If it does not apply, the DMI table has moved; add the
entry by hand next to the APEX one.

## Notes on this install

- The module is signed with DKMS's self-generated MOK key. Secure Boot is
  disabled on this machine, so the kernel taints (`module verification failed`)
  but loads. If you ever enable Secure Boot, enrol `/var/lib/dkms/mok.pub`.
- `pwm1_enable = 2` on load, i.e. the EC is running its own fan curve. Writing
  `1` hands control to userspace via `pwm1`. Left alone here.
- The charge limit read `62%` on first probe — that is a pre-existing EC value,
  not something this install set. Verified read/write through steamos-manager
  (set to 80, read back 80, restored to 62).

## Upstreaming

The patch is formatted for `git am` and carries a `Signed-off-by`. Worth sending
to `platform-driver-x86@vger.kernel.org`, cc'ing the oxpec maintainer from
`MAINTAINERS`, so the next kernel handles this device out of the box. The
justification for reusing `oxp_fly` without a new register map is that the board
is APEX-identical — say so in the commit message, since it is the whole basis
for the change.
