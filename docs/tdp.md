# TDP on the ONEXPLAYER X2Mini PRO

Short answer to "can ryzen_smu help": **not on its own — steamos-manager has no
way to talk to it.** But there is a supported extension point that makes a
ryzenadj-backed solution work, and that is the realistic path. Details below.

## What steamos-manager actually supports

Exactly two TDP methods, both confirmed by reading the binary:

| Method | Reads/writes | Available here? |
|---|---|---|
| `amdgpu_hwmon` | `power1_cap` / `power2_cap` on the amdgpu hwmon | **No** |
| `firmware_attribute` | `/sys/class/firmware-attributes/*/attributes/ppt_pl1_spl`, `ppt_pl2_sppt`, `ppt_pl3_fppt` (with `current_value`, `min_value`, `max_value`) | **No** |

And it has no notion of ryzen_smu, ryzenadj, or `/dev/mem`:

```console
$ strings /usr/lib/steamos-manager | grep -E "ryzen|smu_|/dev/mem"
             # nothing
```

So even a perfectly working ryzen_smu would sit there unused — there is no
backend that would read from it.

### Why neither method works

**`amdgpu_hwmon`:** this is Strix Halo (`AMD RYZEN AI MAX+ 388`, Radeon 8060S,
PCI `1002:1586`). Its amdgpu hwmon exposes power *reporting* but no cap:

```console
$ ls /sys/class/hwmon/hwmon4/    # name = amdgpu
freq1_input  freq1_label  in0_input  in0_label  in1_input  in1_label
name  power1_average  power1_input  power1_label  temp1_input  temp1_label
```

No `power1_cap`, `power1_cap_min`, or `power1_cap_max`. On this APU the package
power limit is not plumbed through amdgpu at all.

**`firmware_attribute`:** `/sys/class/firmware-attributes` does not exist,
before or after loading oxpec. That class is created by *vendor* platform
drivers, and this is the crux of the problem — every other handheld that works
with steamos-manager has one, and OneXPlayer does not:

```console
$ # which shipped modules expose ppt_pl1_spl?
asus-armoury.ko          # ROG Ally / Ally X
asus-wmi.ko
msi-wmi-platform.ko      # MSI Claw
zotac-zone-platform.ko   # Zotac Zone
lenovo/lenovo-wmi-other.ko   # Legion Go / Go S
```

That is the whole list. There is no `onexplayer-*` or `oxp-*` entry, and
`oxpec` — the OneXPlayer driver we patched in for fan and charge control —
contains no TDP code whatsoever (zero references to `ppt_pl*` or firmware
attributes anywhere in its source).

## So where does ryzen_smu fit

`ryzen_smu` is an out-of-tree DKMS module that exposes the AMD SMU mailbox at
`/sys/kernel/ryzen_smu_drv/`. It is a transport, not a policy interface — it
does not create `power1_cap` or firmware attributes, so it cannot satisfy either
of steamos-manager's methods. Userspace tools like `ryzenadj` use it (or
`/dev/mem`) to poke SMU registers directly.

Neither `ryzen_smu` nor `ryzenadj` is currently installed here.

**Strix Halo support is confirmed.** Both `ryzenadj` and `ryzen_smu` are known
working on Strix Halo silicon — verified in practice on an ASUS ROG Flow Z13
(GZ302EA), which carries the same Ryzen AI MAX+ family. The SMU register offsets
for this family are correct in ryzenadj, so the transport is sound.

Note the Flow Z13 does not *need* ryzenadj for Steam integration — ASUS ships
`asus-armoury`, so it gets `firmware_attribute` natively. The X2 Mini differs
only in having no vendor driver, which is precisely the gap the shim below
fills.

One thing worth knowing: writing SMU mailboxes directly bypasses whatever the EC
and `amd-pmf` believe the limits are. That is how every handheld TDP tool works
today, but the interaction with `platform_profile` is worth watching — if both
are driving power at once, last writer wins.

## The actual integration path: RemoteInterface1

steamos-manager has a documented-by-implementation extension mechanism that
solves exactly this. It can **proxy its D-Bus interfaces to an external
daemon**, including `TdpLimit1`:

```console
$ strings /usr/lib/steamos-manager | grep RemoteInterface
com.steampowered.SteamOSManager1.RemoteInterface1
<interface name="com.steampowered.SteamOSManager1.RemoteInterface1">
<property name="RemoteInterfaces" type="...
struct RemoteInterface1Config with 11 elements
```

The eleven proxiable interfaces include:

```
BatteryChargeLimit1  CpuBoost1  FactoryReset1  FanControl1
GpuPerformanceLevel1  PerformanceProfile1  TdpLimit1
UpdateBios1  UpdateDock1  ...
```

It reads registrations from:

```
/usr/share/steamos-manager/remotes.d/
/etc/steamos-manager/remotes.d/          <-- both exist, both empty here
```

and has a dedicated error path for when a TDP request arrives with nothing
registered: `"No remote TDP manager"`.

The `TdpLimit1` interface it expects is small:

```
property TdpLimit
property TdpLimitMax
property TdpLimitMin
```

**So the shape of a working solution is:** a small root daemon that implements
`com.steampowered.SteamOSManager1.TdpLimit1` on the system bus, backed by
ryzenadj (via ryzen_smu or `/dev/mem`), registered through a TOML in
`/etc/steamos-manager/remotes.d/`. Steam's TDP slider then drives it through
steamos-manager with no changes to Steam or steamos-manager at all.

This is almost certainly what the mechanism exists for — it is how a vendor or
distro adds TDP support for hardware Valve does not ship.

Note `remotes.d` ships empty with no example, and `RemoteInterfaceConfig` has
2 fields (most likely a bus name and an object path). Confirming the exact TOML
schema means either reading the steamos-manager source or trial and error
against the daemon's parse errors.

## Recommended order of work

Step zero — "does ryzenadj work on this silicon" — is already answered (see
above), so the work starts at the integration.

1. **Pin down the `remotes.d` TOML schema.** Read the steamos-manager source
   for `RemoteInterfaceConfig`, or iterate against its parse errors.
2. **Get ryzenadj onto this machine and confirm it moves real power.** Set a
   limit, then watch `power1_average` on the amdgpu hwmon under sustained load
   to prove the limit binds rather than being silently accepted.
3. **Write the shim daemon.** Implement the three `TdpLimit1` properties over
   ryzenadj, register it, and the Steam slider should light up.
4. **Consider upstreaming a real driver.** The clean long-term answer is an
   OneXPlayer platform driver exposing `ppt_pl1_spl` and friends via
   firmware-attributes, the same way `lenovo-wmi-other` and `asus-armoury` do.
   Then `firmware_attribute` works natively and the shim can be retired. Given
   the board is APEX-identical, such a driver would cover several OXP models at
   once.

## The cheap partial win you already have

`[performance_profile]` is wired up and working — `amd-pmf` exposes
`low-power` / `balanced` / `performance` and steamos-manager drives it:

```console
$ steamosctl get-available-performance-profiles
low-power, balanced, performance
$ steamosctl set-performance-profile performance   # verified, writes through
```

That is coarse platform-level power management rather than a TDP slider in
watts, but it is real and it works today. Worth setting per-game via Steam's
per-title profiles while the TDP path gets sorted out.
