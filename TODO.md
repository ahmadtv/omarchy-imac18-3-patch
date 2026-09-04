# TODO

Open items for the iMac18,3 patch. Root causes are recorded here so nobody has
to re-derive them.

## Display — two boot artifacts (5K only)

Both are gaps in the patch's handling of the slave tile's *state*, not cosmetic
quirks. Both confirmed from the boot timeline.

### Skewed Apple logo on warm reboot (cold boot is fine)

The patch writes the panel-latch DPCD `0x4F1 = 1` to wake the slave tile in four
code paths, and **never tears it down** — there is no shutdown hook, `.remove`,
or suspend handler anywhere in the diff. The woken state therefore survives a
warm reboot, and Apple's firmware — which assumes the factory single-link state —
draws its boot logo into a panel configuration it doesn't expect. A cold boot
power-cycles the panel, which is why it looks correct then.

**Fix:** write `0x4F1 = 0` on shutdown/module-unload (amdgpu `.shutdown` /
`amdgpu_pci_shutdown`). Low risk — the code only runs as the machine goes down.

### Half-black screen at the LUKS password prompt

| t | event |
|---|---|
| 7.7 s | connectors enumerated, 5120 mode advertised |
| 18.9 s | `crtc_mode=5120x2880` but `stream_timing=2560x2880` — link[0] only |
| 19.03 s | `root wake 0x4F1 stage=slave-predetect` — slave tile finally woken |
| 19.03 s+ | peer stream added, `sync_enabled=1` — genlock latches |

The stitched mode is exposed to fbcon/Plymouth **before** the slave tile is awake,
so the prompt is drawn across 5120 px while only the left 2560 px is lit.

**Fix (preferred):** do the slave wake + link-train during amdgpu init, before the
connector/mode is published. **Fallback:** don't advertise 5120×2880 until both
streams report `sync_enabled=1`. Medium risk — touches bring-up ordering.

### DP-1 phantom output (cosmetic, low priority)

`hyprctl` lists DP-1 as a disabled connector. It is functionally correct — the
kernel drives the panel over both links (`master_link[1]`) and the stitch depends
on it. **Do not disable it from the compositor**; that risks the fused output.
Clean fix is patch-level: mark the slave connector `non-desktop` so compositors
ignore it without powering it down.

## GPU video encode (VCE) hang

Hardware encode via VAAPI can hang the GPU: `ring vce0 timeout` → full GPU reset →
`VRAM is lost` → the Wayland session dies. Seen from both an ffmpeg transcode
(file-manager preview pipeline) and `gpu-screen-recorder`.

Ruled out: macroblock alignment, sandboxing/app version, file corruption. Hardware
*decode* of the same file is fine. RADV exposes no `VK_KHR_video_encode*` on
Polaris, so VCE is the only encode silicon — there is no alternate API.

Leads, in order:
1. **Mesa radeonsi encode path** — Mesa builds the VCE command stream, so this may
   be a driver bug rather than firmware. Bisect encode parameters (rate control,
   GOP/IDR, reference frames, slice config, dimensions) against the reproducer.
2. **Kernel `VCE VM mode`** — boot log says VCE runs in VM mode, which has a
   history of hang bugs on Polaris. Check `vce_v3_0.c` for the gating.
3. **Blast-radius reduction** — per-ring recovery instead of full-chip reset; and
   GL robustness in Hyprland/aquamarine so a reset doesn't kill the session.

Blunt fallback that works by construction: `amdgpu.ip_block_mask=0xfffffeff`
masks out VCE entirely — no hardware encode, hang impossible.

**Test safely:** reproduce from `multi-user.target` over SSH, not from a desktop
session, so a GPU reset costs nothing. Capture the devcoredump at
`/sys/class/drm/card*/device/devcoredump/data` on the first controlled repro.

## Hardware not yet covered

| Item | State |
|---|---|
| Wi-Fi `clm_blob` | Confirmed missing (`no clm_blob available`) → limited channels |
| Backlight | `acpi_video0` exists, pinned at max — needs a functional test |
| Ambient light sensor | Exposed by applesmc (`light`) — unused; could drive auto-brightness |
| SD card reader | `sdhci-pci` bound — untested (needs a card) |
| HDMI audio | 7 devices present — untested |
| Built-in Ethernet | Driver up, `NO-CARRIER` — untested (needs a cable) |
| Bluetooth | Controller powered — pairing untested |

## Housekeeping

- Upload `.github/social-preview.png` in GitHub Settings → Social preview
  (no API for this; must be done in the web UI).

## Considered and rejected

**Fan curve daemon.** Measured 85 °C with the fan at its 1200 RPM minimum and
concluded the SMC never ramps. That was wrong: later sampling under sustained
load showed it holding ~1500–1700 RPM, well above minimum. It does respond — it
just doesn't track temperature closely, and 85–96 °C is uncomfortable but not
dangerous on a chip that throttles at 100 °C. The daemon also caused audible
noise during ordinary work. Removed; the SMC has fan control.

If revisiting: establish the problem first — watch `sensors` and
`/sys/devices/platform/applesmc.768/fan1_input` under sustained load for several
minutes and confirm the fan genuinely stays pinned while temperatures climb.
