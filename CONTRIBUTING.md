# Contributing to sonde

`sonde` is a small norns instrument, not a framework. Changes should keep the
project's texture intact: a sparse OLED earth, a grid waterfall, bounded probe
gestures, and a quiet constellation of satellite state driving sound.

## Project map

- `sonde.lua` owns norns state, controls, grid interaction, satellite movement,
  screen drawing, and calls into the engine.
- `lib/earth.lua` owns terrain lookup, brightness/elevation mapping, coastline
  caching, and latitude/longitude conversion.
- `lib/earth_data.lua` is generated 128x64 terrain data. Avoid hand-editing it
  unless the source data pipeline is also updated.
- `lib/Engine_Sonde.sc` owns the SuperCollider engine, SynthDefs, command
  handlers, drone synths, and shared reverb bus.
- `docs/_capture.py` captures README media from a real norns over matron's
  websocket REPL.

## Design boundaries

- Preserve bounded interaction. Probe taps, echoes, intersect events, and drone
  updates should stay capped so the instrument remains stable on norns hardware.
- Prefer small state helpers over broad rewrites. Most behavior is intentionally
  direct because it mirrors the physical controls.
- Keep the default screen functional rather than explanatory. The README can
  explain the instrument; the OLED should stay compact and playable.
- Keep grid behavior useful on larger grids by treating the 16x8 LRPT surface as
  the active instrument area.
- Let non-active satellites modulate the lead voice rather than adding parallel
  lead triggers.

## Local checks

This repository does not currently include an automated norns test harness. At a
minimum, run:

```sh
git diff --check
```

If Lua or SuperCollider tooling is available, also run the lightest syntax check
available in that environment. Do not treat desktop syntax checks as a
replacement for a device smoke test.

## Device smoke test

On norns or norns shield:

1. Restart norns after changing `lib/Engine_Sonde.sc`.
2. Launch `sonde`.
3. Confirm E1 changes tempo and does not leave the metro stuck.
4. Confirm E2/E3 update the active satellite inclination and phase.
5. Hold K1 and use grid columns 1-4 to select/add satellites.
6. In edit mode, confirm K1+K2 removes the active satellite only when more than
   one satellite exists.
7. In default mode, tap grid cells and confirm probes cap visually and audibly.
8. Use K2 reset and confirm satellites keep their intended spread.
9. Use K3 pause/resume and confirm drones do not click or hang.

## Media captures

README media is device-captured. To refresh it, run `docs/_capture.py` from the
repository root with a reachable `norns.local` and `ffmpeg` installed. Generated
temporary frames under `docs/_frames/` should not be committed.

## Repository hygiene

- Keep PRs narrow and explain whether they affect interaction, sound, visuals, or
  repository maintenance.
- If a change alters controls or OLED/header behavior, update `README.md`.
- If a change alters engine commands, update both `sonde.lua` and
  `lib/Engine_Sonde.sc` together.
- The repository currently has no explicit license. That should be decided by
  the maintainer before reuse terms are implied.
