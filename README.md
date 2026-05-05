# sonde

A norns + monome grid instrument. Satellites scan a 128×64 NASA Blue Marble earth. The terrain underneath each satellite drives sound events.

The grid is the satellite downlink, an LRPT-style waterfall. Every tick, each active satellite samples 16 cells perpendicular to its velocity. The brightest sample per column is pushed onto the bottom row, older lines scroll up.

Inspired by the essay [Down to Earth](https://yimingsun.site/posts/down-to-earth).

## Requirements

- norns or norns shield
- monome grid (16×8 recommended; without it you lose the waterfall and the orbit editor)

## Install

Copy `sonde/` into `~/dust/code/`:

```
~/dust/code/sonde/
  sonde.lua
  lib/earth.lua
  lib/earth_data.lua
  lib/Engine_Sonde.sc
  README.md
```

Restart norns once after the first install so SuperCollider picks up `Engine_Sonde`.

## Controls

| Input | Function |
| --- | --- |
| E1 | tempo (0.5–8 Hz, 0.5 Hz steps) |
| E2 | inclination of active satellite (0–90°) |
| E3 | phase of active satellite (-180°–180°) |
| K1 (hold) | enter edit mode |
| K2 | reset trail / raster / probes |
| K3 | pause / resume |
| K1 + K2 | remove active satellite (only when n_sats > 1) |

In edit mode the grid becomes a per-satellite orbit editor:

- Columns 1–4: one editor per satellite slot.
- Rows 1–4: inclination preset (22° / 45° / 67° / 90°).
- Rows 5–8: phase preset (-180° / -60° / 60° / 180°).
- Tapping a not-yet-active column auto-enables that satellite and selects it.
- The header shows `-K2` whenever a removal is available.

In default mode, tapping any grid cell starts a probe. The cell brightens, a diamond ripple expands outward, and the cell's sound plays once on tap. While the probe is alive (~6 ticks) at most one soft echo can fire, gated by a terrain class change underneath. Probes cap at four simultaneous. Tapping the same cell again refreshes the visual without retriggering.

## OLED layout

| Region | Content |
| --- | --- |
| Top bar (y 0–6) | header: sat / inclination / phase / mode (left), tempo (right) |
| Map (y 7–63) | coastline, active orbit trail, scanline bar, raster strip |

Header forms:

- Default: `s1 i60° p180° n2` left, `2.0Hz` right.
- Edit (n_sats == 1): suffix `edit`.
- Edit (n_sats > 1): suffix `ed-K2`.
- Paused: suffix `pause`.

Coastline pixels are dim grey. Ice cells brighter. Mountain cells brighter still. The active satellite leaves a fading three-tier trail. Other satellites appear as small hollow squares. The active satellite's footprint sits inside a bright square with a 16-pixel scanline bar perpendicular to its motion. The right edge carries a vertical raster strip mirroring recent ticks.

## Sound

Five SynthDefs in `Engine_Sonde.sc`:

| Trigger | SynthDef | Character |
| --- | --- | --- |
| Ocean | `\sonde_ocean` | low filtered drone, long tail |
| Land | `\sonde_land` | resonant pluck, short percussive |
| Mountain | `\sonde_mountain` | FM spike with resonant peak |
| Ice | `\sonde_ice` | bell partials, long sparkle decay |
| Intersect | `\sonde_intersect` | major-7 chord bloom, 4.5 s |

Per-event mapping:

- Brightness drives amplitude and filter cutoff.
- Elevation drives base frequency.
- Longitude drives stereo pan.
- Per-satellite freq multiplier (unison / fifth / fourth-below / major-third) so satellites passing the same terrain stack into chord intervals rather than duplicates.

Every voice softclips before reaching the bus. The entire group runs through a single FreeVerb2 send at mix 0.28, room 0.62, damp 0.42.

## Intersect events

The intersect SynthDef fires once when two ground tracks come within ~3 cells of each other. The grid flashes briefly. An 18-tick cooldown prevents re-fire while the tracks separate.

These are intentionally rare. When you have a few satellites running and one of them happens to clip another, there is an oddly satisfying click of geometry, like watching a screensaver square land exactly in the corner of the display. The chord bloom is the audible version of that.

## Files

```
sonde.lua             main script
lib/earth.lua         terrain lookups + coastline cache
lib/earth_data.lua    128×64 NASA Blue Marble downsampling
lib/Engine_Sonde.sc   5 SynthDefs + global verb send
```

The orbit math is simplified geometry on a unit sphere, not real Kepler. The aim is musical response.

## Credits

Map data: NASA Visible Earth, Blue Marble (2002).

---

Hope you enjoy this script and find it interesting. Suggestions and contributions are welcome. Open an issue or send updates.
