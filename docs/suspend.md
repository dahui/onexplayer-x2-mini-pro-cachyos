# Suspend — working

**Solved by two kernel parameters.** s2idle suspends and resumes reliably, the
controller survives, and `oxp-tdpd` reapplies its limit on wake.

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

### Getting both back

The only route is a kernel that fixes s0ix entry on Strix Halo without the
workaround. **Linux 7.2 is the next one to try** — it had not shipped in CachyOS
as of 2026-08-04, and this unit runs `7.1.6-1-cachyos-deckify`. Nothing promises
7.2 fixes this; it is worth testing because it is cheap and reversible, not
because it is expected.

Re-test after any major kernel bump:

```bash
# drop the parameter from /etc/default/limine
sudo limine-update && sudo reboot
sudo ./suspend/suspend-test.sh ladder     # then `none` for the real thing
```

If the ladder reaches `none` and survives, the IOMMU can stay on and the NPU
comes back. If it hangs, put the parameter back — you will have lost nothing but
a reboot. Note 7.2 is also what the **back paddles** are waiting on
(`hid-oxp`), so it is worth testing both at once.

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
core      rc=1      0s           <- write rejected; this level is unusable here
none      <hang>                 <- only the real s0ix entry failed
```

That is what proved the software path was sound and pointed at the hardware
transition, where the IOMMU turned out to be implicated.

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
