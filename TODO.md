# TODO

What is still open on the iMac18,3 under Omarchy. Finished work is not kept
here; `git log -p -- TODO.md` has every investigation, including the ones that
led to the fixes now in `patches/`.

## Display dimming (backlight)

**2026-09-12: works on boots through `imac-set-os.efi` (macOS mode)** -- the firmware's
`acpi_video0` dims the panel there (see `igpu/README.md`). The notes below describe the
default boot, where it stays inert; the `acpi_backlight=native` entry is superseded once
the set_os boot becomes the default. Next: wire the ambient light sensor (`acpi-als`,
iio:device0) to auto-brightness.

At boot amdgpu logs `Skipping amdgpu DM backlight registration` and hands the
backlight to ACPI, whose `acpi_video0` is broken (`ACPI(GFX0) defines _DOD but
not _DOS`): it accepts writes and nothing dims. The panel has no AUX backlight
either (DPCD `0x701` reads `0x00`), so the control has to be the GPU's PWM.

- **Fix under test:** `acpi_backlight=native` on the Limine entry
  `/Test - native backlight (brightness fix)`. The entry is pinned to its own
  UKI copy (`omarchy_linux-blnative.efi`) so a rebuild of the default image can
  never change its hash (`hash_mismatch_panic: yes`).
- **Before the next test, rebuild that UKI on the current kernel** — it still
  carries 7.1.9, so modules loaded from disk would not match.
- **Expected:** `/sys/class/backlight/amdgpu_bl0` appears and writing to it
  dims the panel. If it appears but does not dim, read `BL_PWM_CNTL`: a
  changing `BL_ACTIVE_INT_FRAC_CNT` with no visible effect means the panel is on
  an SMC rail, and the next lead is `applesmc`. Never `amdgpu.backlight=1` —
  that forces the AUX path this panel lacks.
- **If it works:** move it into `KERNEL_CMDLINE[default]`, then wire the ambient
  light sensor to auto-brightness.

## Video encode (VCE) hangs the GPU -- FIXED 2026-09-11

Hardware encode can hang the GPU: `ring vce0 timeout` → full reset → `VRAM is
lost` → the session dies. Seen from an ffmpeg transcode and from
`gpu-screen-recorder`; on 2026-09-11, **screen recording with the webcam on
turned the screen pink and froze it**.

- **Verified and promoted (2026-09-11 20:14):** with the fix (amdgpu 625040DB)
  `scripts/vce-stress` ran 3 rounds on the Cursor clip and on each of the four
  clips that hung it before -- 165 encode jobs, every variant including the
  sw-decode + hwupload one that hung at 15:29, zero `vce0` timeouts. The same
  harness hung on its 7th encode before the fix. Default entry now 625040DB;
  the pre-fix module is kept as `amdgpu.ko.zst.known-good-B5E2105C` in the
  build cache. Remaining: a real screen recording with the webcam on.
- **Root cause (found 2026-09-11 evening):** a kernel regression, drm/amd#5595 (RX 580, same VCE firmware 53.26,
  same `signaled N, emitted N+1`; #5707, #5766, #5790 are duplicates). Since
  7.1.6, "always emit the job vm fence" (`bc639a9eadc7`) changed what the kernel
  writes on the VCE ring, and `vce_v3_0_ring_vm_funcs.align_mask = 0xf` pads
  frames to 16 dwords while the largest frame is 20 -- the engine stalls before
  the last job's fence. Upstream fix `2ee9836545e6` ("Fix VCE 3 ring
  align_mask", `0xf` -> `0x1f`, Cc stable) is in 7.3-rc1 but in no 7.2.y up to
  7.2.5. Backported as `patches/amdgpu-vce3-ring-align-mask.patch`; drop it when
  the distro kernel has it. This machine was installed on 7.1.9, so it has only
  ever run affected kernels -- which is why it "never happened on macOS" (macOS
  also encodes on the Intel iGPU, see below). The 30 Aug pink screen was the
  same bug (`gpu-screen-recorder`, `ring vce0 timeout, signaled seq=19,
  emitted seq=20`). The Debian #1146343 ASPM bisect is a false positive (that
  commit is a no-op for a GPU on an Intel root port, and reverting it alone
  did not help). Mesa is not involved (a 26.1.5 downgrade did not help; no Mesa
  knob reaches the VCE command stream).

- **Reproduced 2026-09-11 on kernel 7.2.3 / Mesa 26.2.2** with Strata's exact
  preview pipeline (from its 2026-09-04 core dump): `ffmpeg -hwaccel vaapi
  -hwaccel_output_format vaapi -i <file> -t 30 -vf scale_vaapi=w=1280:h=1280:…
  :format=nv12 -c:v h264_vaapi -b:v 2M …`. Two clips passed (a 10-bit HEVC
  1080p, a 4K H.264); the third, a 4K H.264 Canon clip
  (`camera-4k-b.mp4`), hung `vce0` and the GPU reset itself stuck in
  `amdgpu_device_pre_asic_reset` — the same failure as 2026-09-04. Kernel log in
  `evidence/vce-hang-2026-09-11/` (untracked). So it is not app-specific and not
  fixed by the September updates: **keep apps on software video encode**
  (Strata's `video_preview_backend = "software"`). Screen recording also encodes
  on VCE (`gpu-screen-recorder -k auto`), so it carries the same risk.
- **End to end, on a real hang (2026-09-11 15:29):** `scripts/vce-stress` ran
  the confirmed reproducer (`/path/to/screen-recording.mp4`)
  through eleven encode variants; the eighth — software decode, GPU encode
  only — hung vce0. Reset completed in 0.7 s, the `gpureset` module restarted
  the login manager, fresh desktop 5 s after the hang, no power button. Note
  for the root cause: the variant that hung does no GPU decoding, so the
  encoder is the faulty part, not decode or scaling. Still open: why VCE hangs.
- **Recovery fixed (2026-09-11 14:27, test entry `B5E2105C`):** the dead GPU
  after a reset was the driver, not firmware. `amdgpu_vce_suspend()` returns
  -EINVAL while an encode session is open, which in a reset is always (the hung
  job). That abort stopped the suspend of every block behind VCE, so after the
  ASIC reset they still claimed to be up, were never re-initialised, and the
  SMU firmware was never reloaded — hence "last message was failed". With
  `patches/amdgpu-vce-suspend-in-reset.patch` (drop the dead sessions and let
  the suspend go through) the on-demand reset (`vce-reset-test --trigger`),
  the same with an encode session open (`--trigger-encoding`), and a third
  run passed: "GPU reset(N) succeeded!", IB ring tests pass, SMU answering,
  no hung tasks, clean reboot afterwards. A reset still costs the graphics
  session (VRAM is lost by design); what happens to the desktop is the
  remaining check. The four-clip hang sequence did not trip the encoder in
  20 encodes that day — the hang is intermittent.
- **Deadlock fixed first (2026-09-11 13:38):**
  `patches/amdgpu-hpd-skip-during-reset.patch` makes the HPD handler skip its
  dc_lock section while a reset is in progress, as the HPD-RX handler already
  does. Verified on a test entry with `scripts/vce-reset-test`: the encoder
  hung, the reset completed in one second ("GPU reset succeeded"), no hung-task
  reports. But the GPU never came back: `suspend of IP block <vce_v3_0> failed
  -22` before the reset, the driver fell back to a PCI CONFIG reset, and after
  resume the SMU stopped answering (`last message was failed ret is 0` every
  4–5 s) until the journal ended 23 s later — power button again. The older
  "successful" resets (08-30, 09-01) also lost the machine within seconds, so
  a reset has never restored this GPU. Two problems: the deadlock (fixed, worth
  upstream) and post-reset recovery on this Polaris (open, next).
- **Why the reset used to freeze the machine outright:** the 2026-09-11
  kernel log shows a deadlock. The reset worker (`drm_sched_job_timedout →
  amdgpu_device_asic_reset → dm_suspend → amdgpu_dm_irq_suspend → __flush_work`)
  waits for pending display IRQ work, while that work (`dm_irq_work_func →
  handle_hpd_irq_helper`) is blocked on a mutex the kernel says the reset worker
  holds. So a hotplug interrupt arriving mid-reset turns a recoverable VCE hang
  (as on 09-01/09-02, which reset and only took the session down) into a frozen
  machine. None of the imac5k patches change these functions, so this looks like
  upstream reset locking; which link raised the hotplug is not logged — the 5K
  slave tile dropping its HPD when the reset stops the streams is a guess to
  check. Worth its own amd-gfx report with the two stacks.
- **Ruled out:** macroblock alignment, sandboxing or app version, file
  corruption. Decoding the same file is fine. RADV has no Vulkan encode on
  Polaris. On the Radeon, VCE is the only H.264 encoder; HEVC encode runs on
  UVD-ENC, a different ring (`hevc_vaapi`, `gpu-screen-recorder -k hevc`). In macOS
  mode (`macos` module) the Intel HD 630 is the default encoder for apps that take
  the first GPU; gpu-screen-recorder still encodes on the Radeon.
- **Leads:** bisect Mesa radeonsi encode parameters (rate control, GOP/IDR,
  reference frames, slices, dimensions) against a reproducer; the kernel's
  `VCE VM mode` on Polaris (`vce_v3_0.c`); per-ring recovery so a reset does not
  take the session with it.
- **Fallback that works by construction:** `amdgpu.ip_block_mask=0xfffffeff`
  masks VCE out — no hardware encode, no hang.
- **Test safely:** reproduce from `multi-user.target` over SSH, and keep the
  devcoredump (`/sys/class/drm/card*/device/devcoredump/data`).

## SD card reader

Never worked (no `mmcblk` in any boot). The card is identified, then every data
read fails: ACMD51 `SEND_SCR` gets a correct response, but the DAT lines never
deliver a byte and the transfer times out. Same with a second card.

- **Ruled out:** DMA (PIO fails the same), 64-bit DMA, UHS/1.8 V, 1-bit width
  and 100 kHz, every relevant `sdhci` quirk, and the ChromeOS BCM57785 register
  fixup (its registers already hold the values it writes). PCIe ASPM was
  dropping the reader's interrupts — `setpci -s 04:00.1 CAP_EXP+0x10.W=0x0040`
  (and `04:00.0`, `00:1c.1`; reverts on reboot) brings them back, but not data.
- **Most likely:** the data path in hardware — board wiring or mux, or the
  reader itself. **Last check:** can macOS read a card in this slot? If not,
  drop the reader from the table instead of tracking it.
- **Caution:** reload with `modprobe -r`, never sysfs unbind — unbinding while a
  card is failing wedges the writer in `D` state.

## Audio: choose speakers while a headset is plugged in

Wanted: the macOS choice — earbuds in, pick Speakers or the internal mic, and
have the sound move. Proven not hardware: the driver runs both amplifiers over
its private I2C path, and only its jack handler ever changes the routing, so
PipeWire's port switch writes to nothing.

Driver work, upstreamable on the jackdanyell PR:
1. Expose real `Speaker Playback Switch` / `Headphone Playback Switch` controls
   mapped to the I2C writes the jack handler already makes.
2. Make the jack event set a default instead of forcing the routing.
3. Honour `Capture Source` for the two microphones.

After that PipeWire's paths work unchanged and the panel can list every port.
**Risk:** reconfiguring the playback path inside a jack event once produced a
continuous tone on the headset output — budget a day with ear-testing.

## Audio: listening tests (speakers not yet judged)

The speakers sound acceptable without an EQ, but that is a first impression,
not a test. Before deciding whether the 18,3 needs a tuning at all:

1. **Compare against macOS on the same machine** (macOS boots from the external
   drive): the same tracks at matched loudness, speakers only — bass, voices,
   harshness at the top.
2. **Map the four channels.** Switch the card to the Analog Surround 4.0 profile
   and play a quiet test tone on each channel, to learn which feeds the tweeters
   and which the woofers. Keep the level low: bass sent to a tweeter at volume
   can damage it.
3. **Find out what the stereo profile does** with those four drivers — whether
   each side's woofer and tweeter both get the full-range signal.
4. **Headphones and EarPods** — the same check on the jack.

If a tuning turns out to be needed, measure it on this machine with a calibrated
microphone. Other tunings (taprobane99's, bundled by Pronkin's patcher) were
measured on an iMac17,1, whose codec and amplifiers differ (CS4206 on the stock
driver, versus CS8409 + CS42L83 here), so they are a starting point at most.
The parked module in `parked/speaker-eq/` is the other starting point.

## Audio: two small driver bugs

- The driver leaves `Internal Mic Boost Volume` at 3 while its ALSA range is
  `max=2`; after an internal-mic capture a WirePlumber restart then drops the
  whole analog device. One-line clamp in the driver's control setup.
- The internal mic defaults to 100 % plus +20 dB boost and peaks near clipping
  on room noise. Set a sane default gain.

## Suspend

Masked, because sleep and hibernate both hard-hang. Both share
`dpm_suspend_start()`, so a driver blocking in `.suspend` is the likely cause,
not firmware. Next step: boot with `no_console_suspend initcall_debug`, then
walk `/sys/power/pm_test` (`freezer` → `devices` → `platform` → …) over SSH;
`devices` decides it, and the log names the device that never returns. Suspects:
amdgpu, thunderbolt, brcmfmac, applesmc, sdhci-pci.

## Boot splash: the logo flashes in the top-left after unlock (cosmetic)

On some boots Plymouth also draws to the kernel's fbdev console at 1x, using the
2x screen's coordinates, and that buffer is shown for ~1.8 s between the splash
quitting and Hyprland's first frame. The cause is a race: mkinitcpio's `udev`
hook wipes the udev database before switch-root, and Plymouth only skips fbdev
when it finds an initialised sibling DRM card. Candidate fix: `DeviceScale=2` in
`/etc/plymouth/plymouthd.conf` (the visible splash is already 2x). The real bug
is Plymouth's sibling check.

## Parked: speaker EQ

Removed on 2026-09-10 — it had come up empty after a cold boot, and the
speakers seemed acceptable without it (not yet tested properly; see the
listening tests above). The code and what to fix before it
returns are in [`parked/speaker-eq/`](parked/speaker-eq/).

## Considered and rejected

- **A fan-curve daemon.** The SMC ramps the fan itself and closes the loop
  (1200 → 1852 RPM under a two-core burn, CPU held at 93–95 °C); a daemon only
  buys the unused top of the range at the cost of noise.
- **`reboot=pci` instead of the reboot handoff.** It also gives a straight Apple
  logo, but with a longer black gap and without surviving ramoops captures.
- **Hiding DP-1 from the compositor.** Disabling it from Hyprland risks the
  stitched output; the kernel now reports it disconnected instead
  (`imac5k-stitch-hide-slave.patch`).
