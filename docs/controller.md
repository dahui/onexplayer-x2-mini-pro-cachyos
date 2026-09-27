# The controller on Linux 7.2: hid-oxp, the back paddles, Guide, RGB

Linux 7.2 ships `hid-oxp`, a driver for the OneXPlayer vendor controller interface
(`1a86:fe00`). It binds this unit's controller out of the box. It was expected to
fix the back paddles and add RGB control. On this machine, measured on
`7.2.3-1-cachyos-deckify`:

| | Result |
|---|---|
| **Back paddles** | Work, **with a workaround** shipped in `onexplayer-x2mini`. hid-oxp's own init leaves them silent. |
| **Guide, Home** | Work, with the same workaround. hid-oxp's button map switches them off once it takes effect. |
| **RGB** | **Does not work.** hid-oxp registers `oxp:rgb:joystick_rings`, but the controller ignores every write. |
| **Rumble** | Works as before: Steam → InputPlumber (deck-uhid) → xpad force feedback. hid-oxp adds a strength setting. |
| Everything else | Unchanged from 7.1: the OneXPlayer and Keyboard chords, and the X-Box pad. |

Every result below comes from raw HID reports read through
`/sys/kernel/debug/hid/0003:1A86:FE00.*/events`. That view sits underneath any
driver or grab, so "nothing arrived" really means the controller sent nothing.
Captures were bracketed with buttons already known to work (A, Home, the chords),
so an empty capture could not be confused with a broken one. The Guide work
used `usbmon` on bus 1 instead, which also covers the X-Box pad (xpad is not a
HID device), together with the raw output of InputPlumber's virtual Steam Deck
controller, so each press could be followed from the controller to Steam.

## Back paddles

### What hid-oxp does, and why it is not enough here

At bind, and again whenever the MCU reports a reset (the driver's comment puts
this ~6 s after resume), `oxp_mcu_init_fn` does this:

1. sends the button map (`B4` frames; the paddles are M1/M2, mapped to
   `KEY_F16`/`KEY_F17`)
2. switches the gamepad mode to debug (`B2 03 01 02`)
3. switches back to xinput (`B2 00 01 02`)
4. sets rumble strength (`B3`)

On the APEX, the map followed by the mode cycle is what arms the paddles. On this
unit, the switch back to xinput **discards** the map:

| State | Paddles |
|---|---|
| after hid-oxp's init at boot | nothing on any interface |
| button map re-sent afterwards | `b2 3f 01 01 1f 80 22 …` (left) / `… 23 …` (right) |
| hid-oxp's init runs again | nothing |
| map re-sent again | reporting again |
| debug → xinput via sysfs, with the watcher running | reporting, and the X-Box pad stays live |

When armed, each press is one frame with byte 12 = `01` and one with `02` for the
release. Byte 9 carries the mapped code (`0x69` = F16, `0x6a` = F17), but **no
F16/F17 key appears on the keyboard interface**. The paddles exist only as vendor
frames, which is exactly what InputPlumber's `oxp_hid` source reads: `0x22` →
LeftPaddle1 (L4), `0x23` → RightPaddle1 (R4). Unlike the APEX, where `0x22` is
the right paddle, they are not swapped here.

### The workaround: `oxp-x2mini-paddles.service`

`/usr/lib/onexplayer-x2mini/paddle-watch` reads the vendor hidraw node, read-only,
alongside InputPlumber. The MCU confirms every mode switch with a
`b2 3f 01 <mode> 01` frame, and switching to xinput (`00`) is the last step of
every hid-oxp init. When the watcher sees that, it re-sends the map, then the
Guide/Home page described in the next section:

```bash
v=$(cat .../button_m1); echo "$v" > .../button_m1   # any button write re-sends the whole map
```

The rewrite preserves the current value, so custom remaps made through
hid-oxp's `button_*` attributes survive. The unit is static: a udev rule
(`70-onexplayer-x2mini-paddles.rules`) starts it whenever hid-oxp binds the
interface exposing `button_m1`, at boot and on hotplug. It exits when the hidraw
node disappears and systemd restarts it against the new one.

```bash
systemctl status oxp-x2mini-paddles
journalctl -u oxp-x2mini-paddles     # "re-sent button map and Guide/Home page (...)" per init
```

The watcher reacts only to mode switches. After writing a `button_*` attribute
by hand, run `sudo systemctl restart oxp-x2mini-paddles` to restore Guide and
Home.

Across a real suspend and resume (s2idle, 23.6 s in S0i3, 2026-09-26) every
button kept working, the paddles, Guide and Home included. The watcher logged
nothing: hid-oxp did not re-run its init on that resume, so the controller
simply kept its map. When the init does run (it is scheduled from the MCU's
reset notice), it ends with the same switch to xinput as at bind, which the
watcher catches; a hid-oxp rebind exercised exactly that path.

## Guide and Home: the map switches them off

hid-oxp's button map has 18 slots on two pages: A to Start, then Select, the
sticks' clicks, the d-pad and M1/M2 (the paddles). Guide and Home are not in
it. On this unit, once that map takes effect, they stop reporting entirely:
usbmon showed no Guide bit on the X-Box pad and no Home frame on the vendor
interface. So arming the paddles, as above, disabled Guide and Home.

The missing entries are a third page, which the X2 series needs and hid-oxp
never sends. HHD sends it (`hhd-dev/hhd`, `device/oxp/hid_v1.py`,
`INITIALIZE_X2`, after the two map pages):

```
B4 3F 01 | 02 38 02 03 01 | 24 02 02 05 00 00 | 25 01 21 00 00 00 | 00… | 3F B4
                  page 3    Home -> kbd 02 05   Guide -> gamepad 0x21
```

The watcher sends exactly this page about a second after each map (hid-oxp
writes its pages from a work queue, 200 ms apart). Order matters: sending
pages 1 and 2 turns Guide and Home off again, so page 3 always comes last.
Measured with every button, 2026-09-26: Guide, both paddles, Home, Keyboard and
OneXPlayer all reached Steam, at boot (hid-oxp rebind) and after a
debug → xinput switch.

Things learned the hard way, for anyone touching this page:

- **Guide is MCU button `0x25`, and its gamepad code is `0x21`.** hid-oxp's
  mapping table names gamepad code `0x22` `BTN_GUIDE` and skips `0x21`. Mapping
  Guide to `0x22` leaves it dead.
- **Normal-mode B2 frames carry the button's current mapping** in bytes 7–9
  (the paddles report `02 01 69`, their F16 mapping). Debug-mode frames do not:
  they reported Guide as `25 01 21` and Home as `24 02 02 05`, HHD's values,
  even while Home's stored mapping was different. Treat them as a hint only.
- **Page 3 is stored in the MCU.** A wrong value survived a full power-off. If
  Guide or Home is ever dead at the USB level with the map applied, sending
  this page again restores them.
- Home with its first-boot value (`24 02 01 0d`, as read from its frames) also
  set the Guide bit on the X-Box pad. HHD's value does not.

### Why the init re-ran during testing

While testing RGB, hid-oxp's init ran again about 3 s after a `monocolor` write,
with no resume and no USB re-enumeration. The driver re-runs init whenever
it sees a `B8` frame with byte 3 = `0xFE`, and `0xFE` is also the monocolor
command byte, so an RGB write can plausibly look like an MCU reset to the
driver. That is inferred from the source, not traced. Either way, the watcher
catches it like any other init.

## RGB: registered, but inert on this unit

`oxp:rgb:joystick_rings` appears, and its readback looks plausible, but:

- `effect=green_breathing`: the MCU acknowledges the command (`b8 3f 01 0e …`),
  and its next status frame still reports the old effect (`09`, cyberpunk). The
  rings did not change.
- `effect=monocolor`, `multi_intensity=255 0 0`: again no change.

This settles the question left open in CLAUDE.md §7. hid-oxp skips RGB
registration for boards on `oxp_hybrid_mcu_list` (the APEX and the G1 A/i),
because their lighting is not driven over this interface. This unit shares the
APEX's board and behaves the same, but is not on that list. So 7.2 registers an
LED device here that does nothing. Nothing in this repo uses it. The
effects and colours are still controllable only from Windows.

## Rumble

This needed no configuration before and needs none now. deck-uhid turns Steam's
rumble into force feedback on the X-Box pad (xpad). hid-oxp adds
`rumble_intensity` (0–5, default 5), a strength setting stored in the MCU and
re-applied after every mode switch.

## hid-oxp sysfs, for reference

On the vendor interface (`/sys/bus/hid/drivers/hid-oxp/0003:1A86:FE00.*/`, the one
exposing `button_m1`):

| attribute | |
|---|---|
| `button_a` … `button_d_right`, `button_m1`, `button_m2` | MCU-side remap; options in `button_mapping_options` |
| `reset_buttons` | write `1` to restore the defaults |
| `gamepad_mode` | `xinput`, or `debug` (the old full-intercept mode: silences the X-Box pad) |
| `rumble_intensity` | 0–5 |

A remap here happens *inside the controller*, before InputPlumber sees anything.
Mapping the paddles to anything other than their defaults removes them from the
vendor frames InputPlumber reads. Remap in Steam instead.

## Notes for upstream (hid-oxp)

Not sent; recorded for when it is. Maintainer: Derek J. Clark,
`linux-input@vger.kernel.org`. The board is `ONEXPLAYER X2Mini PRO` (board vendor
`ONE-NETBOOK`), with the same system board as the APEX.

1. **Paddles: init order.** On this board `oxp_mcu_init_fn` must send the button
   map *after* the debug→xinput cycle, not before it. Map-then-cycle leaves M1/M2
   silent; cycle-then-map arms them, and the X-Box pad keeps working. Candidate
   fixes: move `oxp_set_buttons()` after the second `TOGGLE_MODE`, or re-send it
   there, for all boards if the APEX tolerates it (it re-applies the map
   either way), otherwise behind a DMI quirk. `gamepad_mode_store()` probably
   needs the same, since a switch to xinput also drops the map.
2. **RGB: add the board to `oxp_hybrid_mcu_list`.** The GEN2 `B8` RGB commands
   are acknowledged and ignored, as on the APEX. Registering the LED device
   here gives userspace a control that does nothing.
3. **Possible false reset detection.** `oxp_hid_raw_event_gen_2()` treats any
   `B8` frame with `data[3] == 0xFE` as the MCU's post-resume reset, and
   `0xFE` is also `OXP_EFFECT_MONO_TRUE`. A monocolor write was followed by
   an unprompted re-init here. Worth checking whether the MCU echoes that
   command.
4. Minor: the default-map comments label index 48 as `KEY_F15` and 49 as
   `KEY_F16`, but the table entries are `KEY_F16` and `KEY_F17`, which is also
   what sysfs reports.
5. **Guide and Home: send page 3.** The map should end with HHD's X2 page 3
   (`24 02 02 05`, `25 01 21`), sent after pages 1 and 2 whenever they are.
   Without it, applying the map disables Guide and Home on this board.
6. **`BTN_GUIDE` is `0x21`, not `0x22`** (measured on this board; HHD agrees).
   Exposing Guide for remapping would need that fixed first.
