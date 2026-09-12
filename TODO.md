# TODO

What is still open on the iMac18,3 under Omarchy. Finished work is not kept
here; `git log -p -- TODO.md` has every investigation, including the ones that
led to the fixes now in `patches/`.

## Auto-brightness

The brightness control works in macOS mode (`imac-patcher --apply macos`, the
default boot; see `igpu/README.md`). Still to do: wire the ambient light sensor
(`acpi-als`, iio:device0) to `acpi_video0`.

## Video encode (VCE)

Fixed: `patches/amdgpu-vce3-ring-align-mask.patch` (drm/amd#5595), and a GPU
reset now recovers (drm/amd#5810); see `patches/README.md`. Still to check: a
real screen recording with the webcam on, the case that turned the screen pink
on 2026-09-11. `scripts/vce-stress` and `scripts/vce-reset-test` re-check both
before the carried patches are dropped.

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
amdgpu, thunderbolt, brcmfmac, applesmc, sdhci-pci, and i915 now that macOS mode
binds it.

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
