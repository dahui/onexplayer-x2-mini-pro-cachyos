# HDR and brightness in Steam game mode

## HDR — working, confirmed with a real title

Verified in game mode on Like a Dragon: Infinite Wealth:

```
drm: Got known display: oxp_x2mini_oled (AMS881KB01-0 OLED)

GAMESCOPE_DISPLAY_SUPPORTS_HDR = 1
GAMESCOPE_DISPLAY_HDR_ENABLED  = 1
GAMESCOPE_HDR_OUTPUT_FEEDBACK  = 1   <- output actually engaged
```

The first two atoms are what Steam reads to decide whether to offer HDR;
`GAMESCOPE_HDR_OUTPUT_FEEDBACK` is the one that confirms HDR output actually
engaged rather than merely being advertised.

**One file is all it takes: the gamescope display script.** gamescope only
advertises HDR for panels it *recognises*, and this one was not in its table.

An earlier version of this repo also patched the gamescope session to pass
`--hdr-enabled`, and this document claimed the flag was "necessary but not
sufficient". **That was wrong, and it was never tested.** The sequence had been
flag-alone (no HDR), then flag-plus-script (HDR) — the script-without-flag case
was simply never tried, and the conclusion was written as though it had been.

Retested with the stock, unpatched session script and only the display script
installed. HDR engaged on Like a Dragon: Infinite Wealth, with no
`--hdr-enabled` anywhere in the running gamescope command line:

```
$ pgrep -af gamescope
gamescope --generate-drm-mode fixed --xwayland-count 2 ... -O *,eDP-1
                                       (no --hdr-enabled)
$ DISPLAY=:0 xprop -root GAMESCOPE_DISPLAY_SUPPORTS_HDR \
      GAMESCOPE_DISPLAY_HDR_ENABLED GAMESCOPE_HDR_OUTPUT_FEEDBACK
GAMESCOPE_DISPLAY_SUPPORTS_HDR(CARDINAL) = 1
GAMESCOPE_DISPLAY_HDR_ENABLED(CARDINAL) = 1
GAMESCOPE_HDR_OUTPUT_FEEDBACK(CARDINAL) = 1
```

### Why the flag is redundant

`--hdr-enabled` sets one convar, which defaults off:

```cpp
// steamcompmgr.cpp:460
gamescope::ConVar<bool> cv_hdr_enabled{ "hdr_enabled", false, ... };
// :7869   --hdr-enabled  ->  cv_hdr_enabled = true
// :5892   cv_hdr_enabled = !!get_prop( ..., gamescopeDisplayHDREnabled, 0 );
```

That last line is the point: **Steam sets the same convar at runtime** through
the `GAMESCOPE_DISPLAY_HDR_ENABLED` atom. The flag only pre-sets it at startup.
This is also why the Steam Deck OLED has working HDR with a completely
unmodified session script — the same script that ships here.

The session script is a poor place to patch anyway: it has no argument
passthrough and no environment equivalent for gamescope flags (its last line is
a bare `-O "${OUTPUT_CONNECTOR:-*,eDP-1}" \`), so the old approach had to derive
a patched copy and re-derive it after every `gamescope-session-cachyos` update.
All of that is gone.

### `force_enabled` does nothing

Several bundled OLED entries set `hdr.force_enabled = true`, and this repo
copied it. gamescope 3.16 never reads it — `DRMBackend.cpp:2334` reads exactly
`supported`, `eotf`, `max_content_light_level`, `max_frame_average_luminance`
and `min_content_light_level`, and the string `force_enabled` does not appear in
the binary at all. It has been removed rather than left implying behaviour it
does not have.

Everything below gamescope is ready. The panel is a Samsung `AMS881KB01-0`
OLED, and its EDID advertises HDR properly:

```
Colorimetry Data Block: BT2020RGB
HDR Static Metadata Data Block:
  Electro optical transfer functions: Traditional gamma - SDR, SMPTE ST2084
  Desired content max luminance: 1107.128 cd/m^2
  Desired content max frame-average luminance: 475.683 cd/m^2
  Desired content min luminance: 0.001 cd/m^2
Display Device Technology: Organic LED
Native Color Depth: 12 bpc
```

and the kernel exposes the properties gamescope needs on the connector:

```console
$ sudo modetest -M amdgpu -c   # eDP-1 props
  125 Colorspace:
    8 HDR_OUTPUT_METADATA:
  124 max bpc:
```

The stock session script builds its gamescope command line without
`--hdr-enabled`, and that turns out not to matter — Steam sets the convar itself
at runtime, as described above.

It does set `STEAM_GAMESCOPE_HDR_SUPPORTED=1` globally, while
`STEAM_GAMESCOPE_FORCE_HDR_DEFAULT=1` and
`STEAM_GAMESCOPE_FORCE_OUTPUT_TO_HDR10PQ_DEFAULT=1` are gated on
`board_name = "Galileo"` (Steam Deck OLED), so they never apply here. Those
control whether Steam *defaults* HDR on, not whether it is available.

### The display script — the whole fix

gamescope keeps a `gamescope.config.known_displays` table, populated by Lua
scripts in `/usr/share/gamescope/scripts/00-gamescope/displays/`. Each entry
matches a panel by EDID and declares, among other things, whether it supports
HDR. Panels with no entry get no HDR, regardless of the command line.

The shipped set covers the Steam Deck LCD/OLED, ROG Ally, GPD Win 4, Zotac Zone,
OneXPlayer F1 OLED, and the Legion Go / Go S — **the last two are the LCD models
only, and both declare `supported = false`.** This panel is the same one used in
the Legion Go 2, which gamescope 3.16 has no entry for either, so there was
nothing to copy.

`scripts/onexplayer.x2mini.oled.lua` adds one, matching on EDID vendor `SDC` and
product `0x4301`, with every value taken from the panel's own EDID rather than a
datasheet:

| | |
|---|---|
| max content light level | 1107 cd/m² |
| max frame-average luminance | 476 cd/m² |
| min content light level | 0.001 cd/m² |
| primaries | R 0.6835,0.3154 · G 0.2402,0.7138 · B 0.1396,0.0439 · W 0.3134,0.3291 |

It installs to `/etc/gamescope/scripts/`, which gamescope scans *after* its
bundled directory — so it survives gamescope updates, unlike the session script.

`force_enabled = true` matches every other OLED entry gamescope ships, so HDR
comes up on rather than merely available.

`max bpc` on the connector reads `16` (range 8–16), so there is no bit-depth
clamp blocking HDR10.

### Where the toggle lives

**Settings → Display**, not the Quick Access side menu.

### `HDR_OUTPUT_METADATA` being empty is normal

```console
$ sudo modetest -M amdgpu -c | grep -A4 HDR_OUTPUT_METADATA
	8 HDR_OUTPUT_METADATA:
		flags: blob
		value:            <- empty
```

gamescope only switches the output to HDR10 PQ when HDR content is actually on
screen. An empty blob with nothing HDR running is expected, not a fault. The real
test is launching an HDR-capable game and re-checking
`GAMESCOPE_HDR_OUTPUT_FEEDBACK`.

### Applying it

```bash
./install.sh                       # or just the one file:
sudo install -Dm644 etc/gamescope/scripts/onexplayer.x2mini.oled.lua \
    /etc/gamescope/scripts/onexplayer.x2mini.oled.lua
```

Takes effect on the next game-mode session. Nothing needs restarting from the
desktop, and there is no session script to keep in sync.

`/etc/gamescope/scripts` is scanned after gamescope's bundled directory, so this
survives gamescope updates — including `gamescope-session-cachyos` updates, which
used to require re-running an installer.

### Verifying

```bash
journalctl --user -u gamescope-session -b | grep -iE "known display|Connector eDP"
DISPLAY=:0 xprop -root GAMESCOPE_DISPLAY_SUPPORTS_HDR GAMESCOPE_DISPLAY_HDR_ENABLED
```

Both atoms should read `1`. If `Got known display` is missing, the EDID match
failed — check the reported vendor/product against the `matches` function.
`--hdr-debug-force-support` is a useful probe for isolating a match problem from
a capability one.

## Brightness — working

The slider works in game mode as of the session that loaded the display script
above. Confirmed by the handoff pattern in the log plus a live value that has
since moved off it:

```
p-holo-priv-write: commit: 236000 -> /sys/class/backlight/amdgpu_bl1/brightness
$ cat /sys/class/backlight/amdgpu_bl1/brightness
151706
```

i.e. Steam took ownership via the polkit helper at session start and has been
writing the device directly since.

### Why it started working is not proven

The likeliest explanation is the display script, but **not** through any direct
backlight setting — there are no brightness or backlight fields in gamescope's
display-config schema, and `known_displays` is consumed only for HDR, refresh
rates, colorimetry and `pretty_name`.

The plausible link is the **patched EDID**. gamescope regenerates it from the
known-display entry and advertises the path to Steam:

```console
$ DISPLAY=:0 xprop -root GAMESCOPE_DISPLAY_EDID_PATH GAMESCOPE_DISPLAY_IS_EXTERNAL
GAMESCOPE_DISPLAY_EDID_PATH(UTF8_STRING) = "/home/<user>/.config/gamescope/edid.bin"
GAMESCOPE_DISPLAY_IS_EXTERNAL(CARDINAL) = 0
```

That file was written at the session restart which loaded the script, and now
holds 384 valid bytes with the full HDR metadata. The session script only
`touch`es it at startup, so before the panel was recognised Steam may have been
reading an empty or incomplete EDID and declining to drive the backlight.

Two confounders make this correlation rather than proof: several reboots
happened in the same window, and the session was restarted. Testing it would
mean removing `/etc/gamescope/scripts/onexplayer.x2mini.oled.lua`, restarting
the session and seeing whether brightness breaks again — worth doing only if it
regresses.

### What was ruled out earlier, and is still true

**The sysfs interface works.** Writing to it moves the panel:

```console
$ cat /sys/class/backlight/amdgpu_bl1/max_brightness   # 472000
# writing half → actual_brightness follows, panel visibly dims
```

**Permissions are correct** — `root:jeff`, mode `664`, so your session can write
it directly.

**Nothing in the obvious places implements it.** Neither gamescope nor
steamos-manager contains any backlight code at all — no `/sys/class/backlight`
string, no ddcutil, no libdisplay-info. Steam's own binaries reference
brightness only for the *status LED* (`CLEDDeviceSysfs`, `CLEDManager_*`), not
the display.

**What actually does it** is `/usr/bin/holo-polkit-helpers/holo-priv-write` from
`jupiter-hw-support` — a polkit helper with an allowlist. Backlight is permitted
unconditionally:

```bash
if MatchFilenamePattern "$WRITE_PATH" "/sys/class/backlight/*/brightness"; then
    CommitWrite   # writes the value, then chgrp to uid 1000 + chmod g+w
fi
```

That `chgrp`/`chmod` is exactly the `root:jeff 664` seen on the file, and the
helper logs every call — it has been running successfully:

```
Aug 04 14:18:07 p-holo-priv-write[1913]: checking: /sys/class/backlight/amdgpu_bl1/brightness
Aug 04 14:18:07 p-holo-priv-write[1916]: commit: 236000 -> /sys/class/backlight/amdgpu_bl1/brightness
```

So Steam hands off once at session start to take ownership of the file, then
writes it directly. Every link in that chain checks out.

### One thing worth knowing regardless

`holo-priv-write` gates several *other* paths behind
`/usr/lib/hwsupport/valve-hardware`, which returns non-zero here:

```bash
if MatchFilenamePattern "$WRITE_PATH" "/sys/class/hwmon/hwmon*/power*_cap"; then
    if /usr/lib/hwsupport/valve-hardware; then CommitWrite; ...
```

So `power*_cap`, `power_dpm_force_performance_level` and `pp_od_clk_voltage`
writes from Steam are refused on non-Valve hardware. This does not affect
brightness, and steamos-manager has its own root path for GPU controls, but it
is relevant background for the TDP story in `tdp.md`.
