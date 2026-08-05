# oxp-tdpd — TDP control for Steam on the X2Mini PRO

A small Go daemon that gives Steam's TDP slider something to talk to.

**Status: working end to end.** `steamosctl set-tdp-limit 30` reaches the SMU and
the PM table reads back 30.0 W.

## Why this exists

steamos-manager supports exactly two TDP methods and neither works here:

| Method | Needs | Present? |
|---|---|---|
| `amdgpu_hwmon` | `power1_cap` on the amdgpu hwmon | No — this Strix Halo APU exposes only `power1_average`/`power1_input` |
| `firmware_attribute` | `/sys/class/firmware-attributes/*/attributes/ppt_pl1_spl` | No — that class comes from vendor platform drivers, and OneXPlayer ships none |

Every handheld that works with steamos-manager out of the box has a vendor
driver providing the second one — `asus-armoury`, `msi-wmi-platform`,
`lenovo-wmi-other`, `zotac-zone-platform`. OneXPlayer has no equivalent.

steamos-manager can, however, **proxy its interfaces to an external daemon**.
That is the supported escape hatch and what this uses.

```
Steam ──D-Bus──▶ steamos-manager (user daemon)
                      │  proxies TdpLimit1 per /etc/steamos-manager/remotes.d/
                      ▼
                 oxp-tdpd (system bus, root)
                      │  MP1 mailbox via ryzen_smu sysfs
                      ▼
                 SMU  →  STAPM limit
```

## Install

```bash
./tdpd/install-tdpd.sh
```

Requires the `ryzen_smu` module (amkillam fork) and, for read-back, the PM table
patch in [`../ryzen-smu/`](../ryzen-smu/). The installer checks both and warns
rather than failing if the PM table is missing.

It builds the binary, installs the systemd unit, D-Bus policy and remotes.d
registration, then restarts steamos-manager so it notices the new remote.

## What it does

Applies a policy set in `/etc/oxp-tdpd.conf`, defaulting to `all`:

| policy | writes | slider means |
|---|---|---|
| `all` *(default)* | STAPM, fast, slow — all at the slider value | a real ceiling |
| `stapm` | STAPM only; fast/slow restored to captured firmware defaults | a target to settle towards |
| `headroom` | STAPM + slow at the slider, fast 25% above (capped at 85 W) | ceiling with burst |

### Why `all` is the default

Measured on this hardware, all-core load, same 45 W setting:

| | `stapm` | `all` |
|---|---|---|
| power | 72–79 W | 45 W flat |
| temp | 90–95 °C | 74 °C |

STAPM's time constant is minutes-scale, so at mid-range settings it does not
bound power in any window a user would notice — it held 72 W+ for the full test
and was still only creeping down. A slider labelled 45 W that draws 79 W at
95 °C is surprising in the wrong direction.

The effect is strongly value-dependent, which is what made this easy to get
wrong: at **15 W** `stapm` clamps almost immediately (15 W flat within 6 s,
46 °C) because the gap is large enough to engage hard. Testing only at 15 W
would suggest `stapm` behaves fine. It does not.

`stapm` remains available for stock burst behaviour, and is safe to switch to
because the firmware's real fast/slow are captured before anything overwrites
them.

### Firmware defaults

Captured once at first run and persisted to
`/var/lib/oxp-tdpd/firmware-defaults.json` (on this device: fast 100 W,
slow 85 W). The SMU has no "restore firmware default" message, so this record is
the only way back to stock short of a reboot.

Capture is only valid before anything writes fast/slow — true at boot, not true
for a mid-session restart, which is exactly why it is persisted rather than
re-read every start. After a firmware update, refresh it with the daemon stopped
right after a reboot:

```bash
sudo systemctl stop oxp-tdpd
sudo oxp-tdpd --recapture-defaults
sudo systemctl start oxp-tdpd
```

## Range

10–85 W, matching what OneXConsole offers.

The vendor app caps at 55 W on battery while allowing 85 W on mains. This
exposes a flat range instead, because `TdpLimitMax` is declared
`emits_changed_signal="const"` on the D-Bus side and a maximum that changed when
the charger was unplugged would violate that contract. Worth watching for
instability running near the top of the range unplugged.

## Usage

```bash
steamosctl set-tdp-limit 30        # through steamos-manager, as Steam does
steamosctl get-tdp-limit

sudo oxp-tdpd --status             # raw hardware state
sudo oxp-tdpd --set 30             # bypass the daemon, one shot
```

`--status` reads the PM table directly:

```
PM table version: 0x64010C
                      limit  current
STAPM (sustained)     30.0W     9.3W
PPT fast              53.0W     7.7W
PPT slow              47.0W     7.7W
```

## Behaviour notes

- **Read-back is real.** `TdpLimit` comes from the PM table, not a cache, so it
  stays honest if something else moves the limit. It falls back to the last
  applied value only if the table is unavailable.
- **Reapply after resume is written but UNVERIFIED.** SMU limits do not survive
  a power transition, so the daemon watches logind's `PrepareForSleep` and
  re-sends the last applied limit on wake. That code has never actually run:
  suspend hangs this machine hard — see [suspend.md](suspend.md). Do not
  assume this path works.
- **Nothing is restored on exit.** Stopping the daemon leaves the current limit
  in place; the firmware reapplies its own at boot. Resetting on shutdown would
  override a limit the user deliberately chose.

## Layout

| Path | |
|---|---|
| `main.go` | entry point, one-shot `--status` / `--set` modes |
| `internal/smu/smu.go` | ryzen_smu mailbox transport, adapted from [z13ctl](https://github.com/dahui/z13ctl) (Apache-2.0) |
| `internal/smu/pmtable.go` | PM table read and layout |
| `internal/tdp/tdp.go` | apply/read policy, message IDs, range |
| `internal/dbusiface/` | `TdpLimit1` interface and resume watcher |
| `contrib/` | systemd unit, D-Bus policy, remotes.d registration |

Only the SMU *transport* comes from z13ctl. Its TDP code drives ASUS platform
sysfs (`asus-nb-wmi`) and does not apply to this hardware; the Strix Halo message
IDs come from RyzenAdj's family dispatch instead.

## Gotchas hit while building this

- **The D-Bus policy must allow `org.freedesktop.DBus.Peer`.** zbus pings the
  remote for liveness before using it. Without that rule, steamos-manager's user
  daemon exits at startup with `AccessDenied: Sender is not authorized to send
  message`, which reads like a bug in steamos-manager rather than a policy gap.
- **It is the *user* steamos-manager daemon that proxies to us**, not the root
  one, so a root-only send policy does not work.
- **steamos-manager binds remotes at startup**, so it needs a restart after the
  registration file is installed. Both daemons — system and user.
