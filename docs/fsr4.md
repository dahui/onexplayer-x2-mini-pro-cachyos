# FSR 4 (INT8) under Proton

AMD's official INT8 FSR 4 upscaler runs on this machine under proton-cachyos,
as it does on Windows. Verified on 2026-09-26 with proton-cachyos
`cachyos-11.0-20260703-slr`, Mesa 26.2.3 and Linux 7.2.3:

| Game | Result |
|---|---|
| Like a Dragon: Pirate Yakuza in Hawaii | FSR 3 selected in the game; Proton upgrades it; watermark `FSR4-int8 4.1.1` |
| Cyberpunk 2077 | has its own FSR 4 option, and uses FSR 4 only when that is selected, as on Windows; watermark `FSR4-int8` |

Nothing in this repo installs it. It is three pieces of user configuration.

## Setup

**1. `/etc/environment`** (applies to every game, and to game mode):

```
PROTON_FSR4_UPGRADE="4.1.1"
PROTON_FSR4_INDICATOR=1
```

- `PROTON_FSR4_UPGRADE` pins the `amdxcffx64.dll` runtime that protonfixes
  drops into each prefix, and sets `FSR4_UPGRADE=1`. **4.1.1 is the only version
  with the INT8 model** (AMD FSR SDK 2.3.0, Adrenalin 26.6.2); 4.0.0 is FP8
  only. `1` also works and picks the newest non-dev entry, 4.1.1 today.
- `FSR4_UPGRADE=1` is required here specifically. proton-cachyos turns the
  upgrade on by default only for **discrete** RDNA2+ GPUs (`is_rdna2()` in
  `dlls/amdxc64/main.c` rejects `VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU`).
- `PROTON_FSR4_INDICATOR=1` shows the on-screen watermark. Remove it once you
  are satisfied it works.

It reaches game mode because `gamescope-session.service` is a user unit.
systemd's environment generator reads `/etc/environment` into the user
manager, and the session script hands that environment to Steam. Check with
`systemctl --user show-environment`. Changes need a re-login.

**2. `DXIL_SPIRV_CONFIG=wmma_rdna3_workaround` is not needed for INT8.** Older
guides recommend it for RDNA3, where FSR 4 used to run by emulating FP8 through
FP16. INT8 was verified with it unset. Leave it out globally: with it set,
`check_fsr4_supported()` in proton-cachyos's `amdxc64` reports **FP8** support
to the game, and the shim logs `FSR4 FP16 emulation is not recommended, please
use FSR 4.1.1`. Whether that actually steers the upscaler off INT8 was not
tested here.

**3. Every game must run on proton-cachyos.** Valve's Proton has no protonfixes,
so the variables above do nothing there, and its prefixes get no
`amdxcffx64.dll`. Set **Steam → Settings → Compatibility → default** to
`proton-cachyos-slr`, and check any game that already has its own override.
Pirate Yakuza showed nothing until it was switched from Proton 11.0.

## What can be upgraded

The upgrade hooks the FidelityFX API, so it reaches only **DX12** games that
load FSR **3.1 or later** from `amd_fidelityfx_dx12.dll` (or the SDK 2.x
loader), with that upscaler selected in the game's menu. FSR 2.x, FSR 3.0,
statically linked FSR, Vulkan and DX11 titles are untouched.

**Games with their own FSR 4 option** (Cyberpunk) behave as on Windows: FSR 4
runs only when that option is selected in the game. Picking FSR 3 there shows no
FSR 4 watermark. That, not the Proton setup, was why Cyberpunk first appeared
not to work.

For other titles, OptiScaler can feed FSR 4 from DLSS, XeSS or FSR 2 inputs:
`PROTON_USE_OPTISCALER=1 PROTON_OPTISCALER_CONFIG="FSR.Fsr4ForceModel=2"`
(`2` = INT8). It injects a DLL, so check anti-cheat first. Not tested here.

## Frame generation: the trade-off (not yet measured)

The shim exposes ML frame generation only when the GPU reports FP8 or
`MLFG_UPGRADE=1` is set, and proton-cachyos's release notes say RDNA3 still
needs `wmma_rdna3_workaround` for it. So without that variable, expect FSR 3.1
frame generation rather than the ML one. To try ML frame generation in one game
without affecting the rest, set it in that game's launch options only:

```
DXIL_SPIRV_CONFIG=wmma_rdna3_workaround %command%
```

Whether that also moves that game's upscaler back to FP8 has not been checked.

## Diagnosing

| Watermark | Meaning |
|---|---|
| `FSR4-int8` | INT8 model, working |
| `FSR4` with no `-int8` | FP8 path, probably; check for `DXIL_SPIRV_CONFIG` (not observed here) |
| none | FSR 4 is not running: the game has its own FSR 4 option that is not selected, the game is on the wrong Proton, FSR 2.x/3.0 is selected, or the title cannot be upgraded |

For detail, launch with `PROTON_LOG=1 WINEDEBUG=+amdxc %command%` and look in
`~/steam-<appid>.log` for `returned provider:` (the model actually chosen) and
for `FSR4 FP16 emulation is not recommended` (the FP8 workaround is active).
`journalctl --user -b | grep ProtonFixes` confirms `Setting up FSR4 version
4.1.1` and `Automatic FSR4 upgrade enabled` per launch.

**Performance:** proton-cachyos leaves INT8 off on integrated GPUs "due to
performance reasons". It works well on this 8060S on Windows, but no Linux
comparison against FSR 3.1 has been made here yet.
