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

**It took two fixes, and the second was the one that mattered.** Passing
`--hdr-enabled` is necessary but not sufficient: gamescope only advertises HDR
for panels it *recognises*, and this one was not in its table. With the flag
alone, both atoms stayed unset and Steam showed nothing.

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

**The gap is that gamescope is never told to use them.** The stock session
script builds its command line without `--hdr-enabled`:

```bash
exec gamescope \
	--generate-drm-mode "${DRM_MODE:-fixed}" \
	--xwayland-count "${XWAYLAND_COUNT:-2}" \
	...
	-O "${OUTPUT_CONNECTOR:-*,eDP-1}" \
```

Without that flag gamescope tonemaps HDR clients to SDR, and Steam shows no HDR
option. There is no environment variable that turns it on — the full set of
`GAMESCOPE_*_HDR_*` variables are output/feedback atoms, not inputs — so it has
to be a command-line argument.

The session script does set `STEAM_GAMESCOPE_HDR_SUPPORTED=1` globally, but
`STEAM_GAMESCOPE_FORCE_HDR_DEFAULT=1` and
`STEAM_GAMESCOPE_FORCE_OUTPUT_TO_HDR10PQ_DEFAULT=1` are gated on
`board_name = "Galileo"` (Steam Deck OLED), so they never apply here.

### Fix 2 — the display script (the one that actually mattered)

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

`--hdr-enabled` *permits* HDR; gamescope only switches the output to HDR10 PQ
when HDR content is actually on screen. An empty blob with nothing HDR running
is expected, not a fault. The real test is launching an HDR-capable game and
re-checking.

### Fix 1 — the `--hdr-enabled` flag, plus Steam's HDR defaults

`./hdr/install-hdr.sh` derives a patched copy of the session script with
`--hdr-enabled` inserted as the first gamescope argument, installs it to
`/usr/local/lib/steamos/gamescope-session-hdr`, and points a systemd drop-in at
it:

```ini
# /etc/systemd/user/gamescope-session.service.d/10-x2mini-hdr.conf
[Service]
ExecStart=
ExecStart=/usr/local/lib/steamos/gamescope-session-hdr
```

Deriving rather than vendoring means the copy tracks whatever the packaged
script does, apart from the one inserted line. The installer verifies the patch
applied, syntax-checks the result, and refuses to install a broken script. If a
future gamescope-session release adds `--hdr-enabled` itself, re-running the
installer detects that and removes the override instead.

### Applying it

```bash
./hdr/install-hdr.sh
systemctl --user restart gamescope-session.target
```

The service itself sets `RefuseManualStart=yes`, so restart the **target**, not
the service. The HDR toggle lives in Settings → Display.

### Re-run after updates

A `gamescope-session-cachyos` update replaces the stock session script but not
our copy, so re-run `./hdr/install-hdr.sh` to pick up upstream changes. The display
script in `/etc/` is unaffected by package updates.

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
