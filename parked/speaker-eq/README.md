# Speaker EQ — parked 2026-09-10

Taken out of the patcher on 2026-09-10 at the owner's call: the speakers sound
fine without it, and after that day's cold boot it had been silently off anyway.
Kept here, whole, to revisit.

**What it was.** A native Omarchy speaker tuning for this machine (bass shelf,
two peaking cuts, a high shelf and an LSP lookahead limiter), installed into
Omarchy's tunings directory and switched on with `omarchy-audio-tuning on`,
which runs it as its own PipeWire instance (`omarchy-speaker-tuning.service`,
`pipewire -c omarchy-speaker-tuning.conf`). The shell hides the physical sink
while a sink named `omarchy_speaker_tuning` fronts it, so the panel showed one
output, "iMac Audio".

**Why it went.** After a cold boot the service was `active (running)` but had
created no nodes: only the bare codec sink existed, so audio bypassed the EQ
while the patcher reported it applied. The same config started by hand came up
immediately, so the curve and graph are fine — it is a startup problem. It left
no trace because the tuning host config sets `log.level = 0`.

**Before bringing it back:**
1. Find why the host comes up empty at login. It starts `After=pipewire.service
   wireplumber.service` and connects, but its filter-chain nodes never appear;
   start it with `PIPEWIRE_DEBUG=3` from a boot to see why (candidates: the
   LV2 limiter loading before `lilv` can see `/usr/lib/lv2`, or the host
   racing WirePlumber's startup). Loading the filter-chain inside the main
   PipeWire through `pipewire.conf.d` would remove the second instance entirely.
2. Make `detect` check the live node (`pw-cli ls Node | grep
   omarchy_speaker_tuning`), not files and a service state — that is what let
   "applied" and "off" coexist.
3. The tuning also applies to the headphone jack (speakers and headphones are
   two ports on one sink here); see the note in `filter-chain.conf`.
4. The device names (`audio/wireplumber/51-imac-audio-names.conf`) moved to the
   `audio` module; with the tuning back, the bare sink would need a distinct
   name again, as it had ("iMac Direct (no EQ)").

**Needs** `lsp-plugins-lv2`. **Removal it performed** (already done on the
owner's machine): `omarchy-audio-tuning off`, then delete the tuning directory,
the kept copy and the pacman hook listed in `eq-module.sh`.

## What is here

| File | Was |
|---|---|
| `eq-module.sh` | the `eq` module from `scripts/imac-patcher`, verbatim |
| `tuning.conf` | `audio/tunings/imac18-3/tuning.conf` — Omarchy tuning metadata |
| `filter-chain.conf` | `audio/tunings/imac18-3/filter-chain.conf` — the curve and limiter |
| `imac-speaker-tuning.hook` | `audio/pacman/imac-speaker-tuning.hook` — restores it after Omarchy updates |

To bring it back, put the files back at those paths, add `eq` to `MODULES` in
the patcher and paste the module in, after fixing what the list above names.

