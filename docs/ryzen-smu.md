# ryzen_smu PM table support for the X2Mini PRO

**Status: upstream. Install `ryzen_smu-dkms-git` from the AUR; no patch needed.**

The patch below was merged verbatim as
[amkillam/ryzen_smu@b098884](https://github.com/amkillam/ryzen_smu/commit/b0988849ddfd6701c67b8b485d79dbdb02c2bd3a)
("smu: add Strix Halo PM table version 0x64010C", 2026-08-15). The AUR package
`ryzen_smu-dkms-git` builds amkillam HEAD, so it includes the patch, and also
[`d298366`](https://github.com/amkillam/ryzen_smu/commit/d2983668300dd2a598e5a7dc40e71ce0678cc270),
which fixes the build on Linux 7.2 (`cpuid_eax` undefined).

This repo's patched fork, `ryzen-smu-x2mini-dkms`, is therefore gone. It pinned a
commit from before the 7.2 fix, so on 7.2 it was not just redundant but **failed
to build** (upstream issue #51). `install.sh` removes it if present and installs
`ryzen_smu-dkms-git` instead.

**ryzen_smu is a hard requirement for oxp-tdpd**, for writes as well as
read-back. The daemon's only transport is the module's sysfs mailbox.
The table further down is about *ryzenadj*, which has other paths; it does not
apply to oxp-tdpd.

```bash
paru -S ryzen_smu-dkms-git      # or let install.sh do it
```

The module autoloads through its PCI table (root complex `1022:1507`), and
`oxp-tdpd-bin` also lists it in `modules-load.d`, so it is loaded before the
daemon starts.

The rest of this page is the original investigation, kept because the
validation method applies again if a firmware update changes the table version.

## Why

The X2Mini PRO's firmware reports PM table version `0x64010C`, which the
amkillam ryzen_smu fork does not know. The driver loads and the SMU mailbox
works, but PM table probing fails:

```
ryzen_smu: Family Codename: Strix Halo
ryzen_smu: SMU v10.100.6.0
ryzen_smu: Unknown PM table version: 0x0064010C
ryzen_smu: Failed to probe the PM table -- disabling feature (249)
```

so `pm_table`, `pm_table_size` and `pm_table_version` are never exposed. Two
things break as a result:

- **No TDP read-back.** Limits can be written but not read, so `oxp-tdpd` would
  have to report a cached value rather than real hardware state.
- **ryzenadj does not work at all** — it fails at init with the rather unhelpful
  `Unable to get os_access Obj, check permission`, which looks like a
  permissions problem and is not. Note this is specifically the *unpatched
  module loaded* case; see below, because it is worse than not having the module
  at all.

## Did ryzenadj need the patch? (historical)

Short answer: **only for read-back — but leaving the module unpatched is worse
than not installing it.** Writing TDP limits never touches the PM table.

| `ryzen_smu` state | TDP writes | PM table read-back |
|---|---|---|
| not loaded | **work** | no — `/dev/mem` blocked |
| loaded, **unpatched** | **fail** | no |
| loaded, patched | work | yes |

The middle row is the trap. ryzenadj decides to use the kernel module on the
strength of `drv_version` alone (needs ≥ 0.1.7; this fork reports `0.1.7`), then
`init_os_access_obj_kmod()` opens `pm_table_size` and `pm_table`
*unconditionally* and returns `NULL` if either is missing
(`lib/linux/osdep_linux_smu_kernel_module.c:36-51`). That propagates up through
`init_ryzenadj()` as the "check permission" message above, and ryzenadj exits
**before applying anything**. So installing `ryzen_smu-dkms-git` without this
patch silently breaks every ryzenadj-based tool on the machine, where not
installing it at all would have left them working.

### Why writes do not need it

Setters go straight to the SMU mailbox over PCI config space (`_do_adjust` →
`smu_service_req`). `init_table()` is only reached lazily from *getters*
(`lib/api.c:346`). Demonstrated by unloading the module entirely:

```console
$ sudo modprobe -r ryzen_smu
$ sudo ryzenadj --stapm-limit=22000 --fast-limit=22000 --slow-limit=22000
no compatible ryzen_smu kernel module found, fallback to /dev/mem
Successfully set stapm_limit to 22000
Successfully set fast_limit to 22000
Successfully set slow_limit to 22000

$ sudo modprobe ryzen_smu && sudo ryzenadj --info
STAPM LIMIT  22.000   PPT LIMIT FAST  22.000   PPT LIMIT SLOW  22.000
```

The write stuck with no module loaded. Reading in that same state fails, and
ryzenadj says so plainly:

```
Unable to get memory access
Unable to init power metric table: -5, this does not affect adjustments
because it is only needed for monitoring.
```

### Why the `/dev/mem` fallback cannot substitute

```console
$ zcat /proc/config.gz | grep STRICT_DEVMEM
CONFIG_STRICT_DEVMEM=y
CONFIG_IO_STRICT_DEVMEM=y
$ cat /proc/cmdline    # no iomem=relaxed
```

Mapping the PM table's physical address is refused. Booting with
`iomem=relaxed` is the usual workaround and would in principle let ryzenadj read
the table without the module — untested here, and it weakens kernel memory
protection for every process, so the patch is the better trade.

Worth knowing for read-back generally: RyzenAdj upstream has no `0x64010c` case
either (only `0x64020c` → `0xE50`), falling back to a deliberately oversized
`0x1000` sentinel. But when the module is present it treats the module's
reported size as authoritative (`lib/api.c:315-320`), so patching `ryzen_smu` is
what fixes ryzenadj here rather than any change to ryzenadj itself.

### SimpleDeckyTDP and friends

Relevant because it is the low-effort alternative to this whole stack for anyone
who just wants a working TDP slider and already runs Decky.

`set_tdp()` shells out to ryzenadj (`py_modules/ryzenadj.py`) with
`--stapm-limit --fast-limit --slow-limit` plus three `*-temp 95` arguments —
writes only, the same three limits `oxp-tdpd`'s default `all` policy sets. It
never reads the table, so **it does not need this patch** — but it does need the
module either patched or absent, per the table above.

Three caveats before recommending it to anyone:

- **The slider tops out at 15 W out of the box.** `get_default_tdp_range()`
  returns `None` unless Lenovo WMI is present, so the frontend keeps its
  `maxTdp: 15` / `minTdp: 3` defaults. Raising it in "TDP Range" gets you 40 W;
  past that needs the "(DANGER) Force Override Max TDP limit" option, which
  lifts the ceiling to 120 W with nothing enforcing the vendor's real limit.
- **This CPU misses the Strix Halo detection.** `is_amd_strix_halo()` matches the
  literal string `AI MAX+ 395 w/ Radeon 8060S`; this chip reports
  `AMD RYZEN AI MAX+ 388 w/ Radeon 8060S`, so the override that would otherwise
  default *on* stays off. A one-line upstream fix — match on `AI MAX+`, or add
  388.
- **It knows nothing about OneXPlayer.** Zero references in the tree: no device
  quirks, no vendor TDP range, no fan or charge integration.

**Do not run it alongside `oxp-tdpd`.** Both write the same three SMU limits with
no coordination, and SimpleDeckyTDP reapplies on resume and on game launch, so it
will silently stomp Steam's slider. Pick one.

*Checked against RyzenAdj `5775fc3` and SimpleDeckyTDP `984d07d` (v1.0.5).*

## The fix

The unsupported version differs from the already-supported `0x64020C` only in
the middle byte, and takes the same `0xE50` size. One case in the Strix Halo
switch in `smu.c`.

The size was not guessed blindly — it was verified. Distinct limits were written
through the MP1 mailbox and read back from the table:

| Written (mW, via MP1 msg) | Read back (PM table offset) |
|---|---|
| stapm 31000 (`0x14`) | `0x0` → 31.000002 |
| fast 53000 (`0x15`) | `0x8` → 53.000004 |
| slow 47000 (`0x16`) | `0x10` → 47.000004 |

All three land exactly where RyzenAdj's documented layout says they should, and
`ryzenadj -i` independently reports the same values once the patch is in.

## Upstreaming — done

Merged as `b098884`. If a firmware update changes the table version again, the
symptom is the same `Unknown PM table version` line in `dmesg`. Adding the new
version alongside `0x64010C` with the same size is very likely all that is
needed. Verify with the write-then-read-back method above before trusting it,
and send it upstream the same way.

## Verifying by hand

```bash
sudo dmesg | grep ryzen_smu
cat /sys/kernel/ryzen_smu_drv/codename        # 26 = Strix Halo
sudo od -A n -t f4 -N 24 -w24 /sys/kernel/ryzen_smu_drv/pm_table
sudo ryzenadj -i
sudo oxp-tdpd --status
```
