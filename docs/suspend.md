# Suspend — working

**Solved by two kernel parameters, still required on Linux 7.2.** s2idle
suspends and resumes reliably, the controller survives, and `oxp-tdpd` reapplies
its limit on wake. Verified on 7.1.6 and again on 7.2.3 (2026-09-26), where
`iommu=pt` and unloading the NPU driver were also tried and did not help (see
[Getting both back](#getting-both-back--not-on-72)).

```
amd_iommu=off mem_sleep_default=s2idle
```

Before this, the machine had **never** suspended successfully — zero
`PM: suspend entry` across every recorded boot — and two attempts hung it hard
enough to need a forced power-off. Both times the first reboot came up without
wifi and needed a second reboot; that is a consequence of the hard reset, not a
separate bug.

## Evidence it genuinely works

```
$ sudo cat /sys/kernel/debug/amd_pmc/smu_fw_info
Last S0i3 Status: Success
Time (in us) to S0i3:      674,335       <- 0.67s to enter
Time (in us) in S0i3:   29,527,618       <- 29.5s of a 30s window

$ sudo dmesg | grep -E "PM: suspend|idlemask"
PM: suspend entry (s2idle)
amd_pmc: SMU idlemask s0i3: 0x7fffb9dd
Restarting tasks: Done
PM: suspend exit
```

29.5 s of residency in a 30 s window is real low-power time, not a sequence that
merely completed.

## Applying it

This install boots **Limine**, not GRUB. Parameters live in
`/etc/default/limine`:

```
KERNEL_CMDLINE[default]+="quiet nowatchdog splash rw rootflags=subvol=/@ root=UUID=... amd_iommu=off mem_sleep_default=s2idle"
```

then:

```bash
sudo limine-update && sudo reboot
```

`/boot/limine.conf.old` is retained and snapshot entries stay in the boot menu,
so a bad command line is recoverable from the bootloader.

Credit: [srsholmes/onexplayer-apex-bazzite-fixes](https://github.com/srsholmes/onexplayer-apex-bazzite-fixes),
which documents `amd_iommu=off` as required for s2idle on the APEX — the same
system board.

## What it costs — you gain sleep, you lose the NPU

**This is a manual step and a real trade. Nothing here applies it for you, and
nothing will undo it.** Decide knowingly.

**The NPU stops working.** The XDNA AI engine requires IOMMU and refuses to
initialise without it:

```
amdxdna 0000:66:00.1: [drm] *ERROR* aie2_init: Running without IOMMU not supported
```

That error appears on **every boot** once the parameter is set — it is expected,
not a new fault. There is no local AI acceleration while `amd_iommu=off` is in
effect, and no partial mode: the IOMMU is on or off.

**DMA remapping is gone.** That is the protection against malicious DMA from
external devices, and this machine has `thunderbolt` loaded, where it actually
matters. GPU passthrough to VMs is also ruled out.

**If you use the NPU, do not apply this.** Keep the IOMMU, skip suspend, and wait
for a kernel that fixes s0ix entry. Working sleep and a working NPU are mutually
exclusive on this hardware today, and that is a property of the platform, not of
anything in this repo.

Fully reversible: remove the parameter, `sudo limine-update`, reboot. Nothing
else here depends on it.

### Getting both back — not on 7.2

**Re-tested on `7.2.3-1-cachyos-deckify` (2026-09-26): the parameter is still
required.** Every run was a real suspend with a 30 s RTC wake, launched as a
detached systemd unit over SSH, with none of this repo's modules installed:

| IOMMU | NPU driver (`amdxdna`) | Result |
|---|---|---|
| on, translated (stock) | loaded | freeze — pm_test `freezer`/`devices`/`platform` all passed first |
| on, translated | unloaded (`modprobe -r`) | freeze — fans stayed running this time |
| on, passthrough (`iommu=pt`) | loaded | freeze, twice |
| **off** (`amd_iommu=off`) | cannot load | **works** — `Last S0i3 Status: Success`, 29.49 s of 30 s in S0i3 |
| on, translated, **BIOS 0.22** | loaded | freeze — the BIOS update changed nothing here |

Each freeze left the journal ending at the harness's pre-sleep sync, with
nothing after it. The machine needed a forced power-off, and often a second
reboot to get Wi-Fi back.

What the table rules out:

- **The NPU.** `amd_iommu=off` also stops `amdxdna` from loading, so it was a
  candidate. But with the IOMMU on and the NPU driver unloaded, it still froze.
- **DMA address translation.** Passthrough keeps the IOMMU present but
  identity-maps devices, and it still froze. What `amd_iommu=off` removes beyond
  that is chiefly interrupt remapping (the `iommu=pt` boot logged
  `AMD-Vi: Interrupt remapping enabled`).
- **Strix Halo or the kernel in general.** Other Strix Halo machines suspend on
  the same kernels with the IOMMU on.

The fit is this board's firmware (measured on BIOS 0.20, 06/10/2026, and again on
0.22, 07/23/2026, with the same result): how it describes the
IOMMU or interrupt routing across the S0i3 transition. The ONEXPLAYER APEX, on
the same board, needs the same workaround. That is inference, not a trace. The
hang happens after the last point anything reaches disk, and there is no serial
console. The realistic route to having both is a later BIOS update from
OneXPlayer; 0.22 was not it. Re-test after one, or after a major kernel bump.
Be at the device when you do, and read the next section first:

```bash
# drop amd_iommu=off from /etc/default/limine
sudo limine-update && sudo reboot
sudo ./suspend/suspend-test.sh ladder     # stops at 'platform' on s2idle
sudo ./suspend/suspend-test.sh none       # the real thing
```

Without a keyboard, run both detached over SSH, as in the unattended example
below.

If `none` survives, the IOMMU can stay on and the NPU comes back. If it hangs,
put the parameter back; you will have lost nothing but a reboot.

On 7.2, also check the back paddles, Guide and Home after a real resume. If
hid-oxp re-initialises the controller after wake, that init silences them until
`oxp-x2mini-paddles.service` re-arms them ([controller.md](controller.md)), and
`journalctl -u oxp-x2mini-paddles` shows a "re-sent button map" line. On the
first test (2026-09-26) no re-init happened and every button simply kept
working.

## Two things that did NOT need fixing

**The out-of-tree modules were never the problem.** `ryzen_smu` was the prime
suspect for weeks on the theory that it shares the SMU mailbox with `amd_pmc`
and `ioremap`s the PM table. It suspends and resumes fine, as does `oxpec`. Both
were loaded through every successful test above. The module bisect this file
used to recommend would have found nothing.

**The controller survives resume.** The APEX fixes run a service that rebinds
PCI `0000:65:00.4` on wake because the gamepad disappears otherwise. That is
this device's controller hub, so it looked likely to be needed — but it is not:

```
$ ls -l /sys/bus/pci/devices/0000:65:00.4/driver
... -> xhci_hcd            # still bound after resume
```

All buttons work after wake, and InputPlumber's virtual controller is still
present. Either this model differs or the bug is fixed in 7.1.6. Do not port that
workaround without first confirming it is needed.

## How the failure was localised

`suspend/suspend-test.sh` walks `/sys/power/pm_test` shallowest-first. At every
level except `none`, the kernel runs the suspend sequence to that point, waits
5 s, and returns *without* entering the low-power state — so a driver that hangs
on the way down is caught with the machine still alive.

```
freezer   SURVIVED  rc=0  5s
devices   SURVIVED  rc=0  7s     <- all drivers suspended and resumed cleanly
platform  SURVIVED  rc=0  2s
core      rc=1      0s           <- rejected: no 'core' stage for suspend-to-idle
none      <hang>                 <- only the real s0ix entry failed
```

That is what proved the software path was sound and pointed at the hardware
transition, where the IOMMU turned out to be implicated.

The `core` rejection is the kernel's own rule, not a fault: `PM: Unsupported
test mode for suspend to idle, please choose none/freezer/devices/platform`.
s2idle is the only sleep mode here, so the ladder now stops at `platform`. The
harness also used to log a rejected stage as `SURVIVED`; it now records
`REJECTED` and stops.

```bash
sudo ./suspend/suspend-test.sh ladder      # pm_test stages, stops before real suspend
sudo ./suspend/suspend-test.sh none        # real suspend
sudo ./suspend/suspend-test.sh baseline    # same, with ryzen_smu + oxpec unloaded
```

The script `sync`s a record to `/var/log/suspend-test.log` **before** each
attempt, so a hard hang still leaves the line naming the stage that killed it.
That is the only reason the failure could be localised at all — the first
attempt left nothing behind. It also sets `console_suspend=N` and
`pm_debug_messages=1` so per-device output keeps printing through the
transition.

Unattended mode arms an RTC wake alarm, since a real suspend with nobody present
otherwise just sits there:

```bash
sudo systemd-run --unit=suspend-real --collect \
  --setenv=CONSOLE_OVERRIDE=1 --setenv=AUTO=1 --setenv=WAKE_SECS=30 \
  ./suspend/suspend-test.sh none
```

`systemd-run` detaches it from the login session, so losing SSH does not kill the
run.

### A frozen launch gets replayed: the hang guard

A detached launch survives the SSH connection dropping, but the session that
started it never receives a result when the machine freezes. On reconnecting,
that session has re-run the same launch, which froze the machine again; one BIOS
re-test turned into several forced reboots that way.

So the harness refuses to start while the log's last `ATTEMPT` has no `SURVIVED`
or `REJECTED` after it. It logs `BLOCKED: previous attempt never returned` and
exits before touching `/sys/power`. Each `ATTEMPT` line also carries the boot ID,
so a hang is visible as an attempt followed by a new boot. After reading the
result, rerun deliberately with:

```bash
sudo ACK_HANG=1 ./suspend/suspend-test.sh none
```

### The SSH guard, and why it is written the way it is

The first attempt at any of this was `rtcwake -m mem -s 15` over SSH. The machine
hung, the session died with it, and nothing was recoverable.

**Do not detect that with `$SSH_CONNECTION` / `$SSH_TTY`.** `sudo` resets the
environment, so both are empty and the check silently passes — an early version
of this script did exactly that and ran a `devices` suspend over SSH anyway. The
guard now walks the process tree for `sshd` and requires a real VT
(`/dev/tty[0-9]+`). `CONSOLE_OVERRIDE=1` bypasses it; use that only when losing
the machine is acceptable.

## Verified on resume

- **TDP is reapplied.** `oxp-tdpd`'s logind `PrepareForSleep` watcher fires on
  wake and re-sends the last limit, because SMU limits do not survive a power
  transition. This path had never executed before — no suspend had ever
  completed — and is now confirmed:
  ```
  19:45:55  oxp-tdpd: applied TDP limit watts=52 policy=all fast_w=52 slow_w=52
  ```
  matching the resume timestamp exactly.
- **Controller works.** All buttons, virtual controller still present.
- **Services survive**: `inputplumber`, `oxp-tdpd`, `steamos-manager` all active.
