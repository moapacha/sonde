-- sonde / listening earth
-- a norns + monome grid instrument
--
--   E1 tempo · E2 inclination · E3 phase
--   K1 (hold) edit mode · K2 reset · K3 pause
--   in edit mode: K1 + K2 = remove the active satellite (n_sats > 1)
--
-- grid is an LRPT-style waterfall (16 cols x 8 rows):
--   each tick every active satellite scans 16 ground samples perpendicular
--   to its velocity. brightest per column wins; that line pushes onto the
--   bottom row, older lines scroll up.
--   tap a cell -> single trigger + diamond ripple over ~6 ticks. if the
--   scanline scrolls a strong terrain change under the probe it fires
--   ONE softer echo, then stays silent for the rest of its life. probes
--   are capped at 4 simultaneous.
--   K1 hold -> sonde editor:
--     cols 1..4 each = orbit editor for satellite 1..4.
--     touching any cell in col c auto-enables sat c (extending n_sats)
--     and selects it as the encoder-active satellite.
--     rows 1-4: inclination preset (22/45/67/90 deg)
--     rows 5-8: phase preset       (-180/-60/60/180 deg)
--     not-yet-enabled columns show as a dim outline. tap to bring online.
--     K1 + K2: remove the active satellite (only when n_sats > 1).
--     waterfall stays visible, dimmed in the background.
--
-- each satellite has its own freq multiplier (unison / fifth / fourth-down
-- / major-third). only the active sat fires lead voices; the other (up to
-- three) sats stay in the background in two ways:
--   1. drone bed — one quiet sustained partial per non-active slot, locked
--      to a stable root × that slot's mul, so the inactive sats together
--      voice a soft major triad. amp follows the brightness of whatever
--      cell each sat is currently over (loud over ice/mountain, near silent
--      over deep ocean), pan follows that sat's longitude.
--   2. modulation — every active-sat trigger is shaped by the non-active
--      sats' positions: m1 (1st non-active sat's brightness) lifts the
--      cell brightness fed to the lead voice; m2 (2nd's |latitude|/90)
--      stretches the note duration; m3 (3rd's longitude/180) nudges pan.
--      No new voices, no parallel triggers — just the lead inflected by
--      where the rest of the constellation happens to be.
--
-- when two satellite ground tracks cross within ~3 cells of each other,
-- a chord-bloom intersect event fires (independent of the above).

engine.name = "Sonde"

local earth = include("sonde/lib/earth")
local g = grid.connect()

-- ----- state ---------------------------------------------------------------

local N_MAX        = 4
local sats         = {}     -- 1..n_sats
local n_sats       = 1
local active_sat   = 1
-- per-sat freq multiplier so each satellite is harmonically distinct.
-- chosen as consonant intervals: unison, fifth, fourth-below, major-third.
local SAT_FREQ_MUL = {1.0, 1.5, 0.75, 1.25}
-- drone bed pitch grid. each sat sustains a partial at
-- DRONE_ROOT_HZ * SAT_FREQ_MUL[i] * DRONE_OCT_MUL[i]. The OCT_MUL spreads
-- the four pitches across registers so they don't pile up in the bass:
--   sat 1: 82.4 × 1.0  × 2 = 164.8 Hz (E3)
--   sat 2: 82.4 × 1.5  × 1 = 123.6 Hz (B2  - P5 below E3)
--   sat 3: 82.4 × 0.75 × 4 = 247.2 Hz (B3  - P5 above E3)
--   sat 4: 82.4 × 1.25 × 2 = 206.0 Hz (G#3 - M3 above E3)
-- Together that's an open-voicing E major triad (B - E - G# - B). The active
-- sat's drone is held at a soft floor instead of muted, so switching active
-- never drops a chord tone.
local DRONE_ROOT_HZ   = 82.41
local DRONE_OCT_MUL   = {2, 1, 4, 2}
local DRONE_AMP_MAX   = 0.05    -- per non-active sat (× brightness)
local DRONE_AMP_FLOOR = 0.018   -- per active sat, fixed soft floor

local earth_rot       = 0.0
local earth_rot_speed = 0.0015

local trail        = {}     -- ground track of ACTIVE sat for OLED
local TRAIL_LEN    = 90
local raster       = {}     -- right-edge OLED strip
local RASTER_LEN   = 57
local clock_tick   = 0
local paused       = false
local metro_clock

-- OLED map y-offset so top of earth sits below the params/header bar.
-- header rect = (0, 0, 116, 7) — first usable row is 7.
local MAP_Y_OFFSET = 7
-- skip polar boundary rows in coastline rendering so we don't get a
-- 1-pixel horizontal line at the screen edges from the forced ice caps.
local POLAR_TOP_SKIP    = 3   -- earth y < this is hidden (top arctic line)
local POLAR_BOTTOM_SKIP = 60  -- earth y > this is hidden (bottom antarctic line)

-- LRPT scanline waterfall (one combined buffer fed by all sats).
local SCAN_W, SCAN_H = 16, 8
local SCAN_STEP      = 1    -- earth-cell distance between samples in a scanline
local scanline_buf   = {}   -- [1..SCAN_H][1..SCAN_W] = {b, ex, ey, terrain}
local shift          = false
local probes         = {}   -- {x, y, life, max_life, tap_terrain, echoed}
local PROBE_LIFE     = 6
local PROBE_MAX      = 4    -- cap simultaneous probes
local PROBE_ECHO_MIN = 3    -- ticks of life elapsed before echo allowed
local TAP_THROTTLE   = 1    -- ticks before same cell can be re-tapped
local last_tap_tick  = {}   -- per-cell tap timestamp
local intersect_flash = 0   -- frames remaining to flash full grid
local intersect_cooldown = 0

-- ----- math ----------------------------------------------------------------

local function deg2rad(d) return d * math.pi / 180 end
local function rad2deg(r) return r * 180 / math.pi end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function compute_position_at(theta, sat)
  local i_rad     = deg2rad(sat.inclination)
  local phase_rad = deg2rad(sat.phase)
  local x_o = math.cos(theta)
  local y_o = math.sin(theta) * math.cos(i_rad)
  local z_o = math.sin(theta) * math.sin(i_rad)
  local lat_rad = math.asin(z_o)
  local lon_rad = math.atan(y_o, x_o) + phase_rad - earth_rot
  while lon_rad >  math.pi do lon_rad = lon_rad - 2 * math.pi end
  while lon_rad < -math.pi do lon_rad = lon_rad + 2 * math.pi end
  return rad2deg(lat_rad), rad2deg(lon_rad)
end

local function make_sat(opts)
  return {
    angle       = opts.angle       or 0.0,
    inclination = opts.inclination or 60,
    phase       = opts.phase       or 0,
    speed       = opts.speed       or 0.06,
    last_x = -1, last_y = -1, last_terr = -1, level = 0,
  }
end

local function ensure_n_sats(n)
  while #sats < n do
    -- spread inclinations and phases so they're visually distinct
    local k = #sats + 1
    table.insert(sats, make_sat({
      inclination = ({60, 30, 80, 45})[k] or 60,
      phase       = ({0, 90, -90, 180})[k] or 0,
      speed       = ({0.06, 0.045, 0.075, 0.05})[k] or 0.06,
      angle       = (k - 1) * 0.7,
    }))
  end
  while #sats > n do table.remove(sats) end
  if active_sat > #sats then active_sat = #sats end
end

local function scanline_buf_init()
  scanline_buf = {}
  for r = 1, SCAN_H do
    scanline_buf[r] = {}
    for c = 1, SCAN_W do
      scanline_buf[r][c] = {b = 0, ex = 0, ey = 0, terrain = 0}
    end
  end
end

local function scanline_buf_push(line)
  for r = 1, SCAN_H - 1 do scanline_buf[r] = scanline_buf[r + 1] end
  scanline_buf[SCAN_H] = line
end

-- one scanline for ONE satellite at its current position.
local function compute_sat_scanline(sat, x0, y0)
  local lat1, lon1 = compute_position_at(sat.angle - sat.speed, sat)
  local x1, y1 = earth.latlon_to_xy(lat1, lon1)
  local vx, vy = x0 - x1, y0 - y1
  if vx >  earth.W * 0.5 then vx = vx - earth.W end
  if vx < -earth.W * 0.5 then vx = vx + earth.W end
  local mag = math.sqrt(vx * vx + vy * vy)
  local pxn, pyn
  if mag < 1e-4 then
    pxn, pyn = 1, 0
  else
    pxn, pyn = -vy / mag, vx / mag
  end
  local line = {}
  local center = (SCAN_W + 1) * 0.5
  for k = 1, SCAN_W do
    local off = (k - center) * SCAN_STEP
    local sx = x0 + pxn * off
    local sy = y0 + pyn * off
    local exi = math.floor(sx + 0.5) % earth.W
    local eyi = clamp(math.floor(sy + 0.5), 0, earth.H - 1)
    line[k] = {
      b       = earth.brightness_at(exi, eyi),
      ex      = exi,
      ey      = eyi,
      terrain = earth.terrain_at(exi, eyi),
    }
  end
  return line, pxn, pyn
end

-- combined scanline: per-cell max brightness across all sats.
local function compute_combined_scanline()
  local combined = {}
  for k = 1, SCAN_W do
    combined[k] = {b = 0, ex = 0, ey = 0, terrain = 0}
  end
  for _, sat in ipairs(sats) do
    local lat0, lon0 = compute_position_at(sat.angle, sat)
    local x0, y0 = earth.latlon_to_xy(lat0, lon0)
    sat.last_x, sat.last_y = x0, y0
    local sat_line = compute_sat_scanline(sat, x0, y0)
    for k = 1, SCAN_W do
      if sat_line[k].b > combined[k].b then combined[k] = sat_line[k] end
    end
  end
  return combined
end

local function check_intersections()
  if intersect_cooldown > 0 then
    intersect_cooldown = intersect_cooldown - 1
    return
  end
  if #sats < 2 then return end
  for i = 1, #sats - 1 do
    for j = i + 1, #sats do
      local dx = sats[i].last_x - sats[j].last_x
      if dx >  earth.W * 0.5 then dx = dx - earth.W end
      if dx < -earth.W * 0.5 then dx = dx + earth.W end
      local dy = sats[i].last_y - sats[j].last_y
      if dx * dx + dy * dy < 9 then    -- within ~3 cells
        local mid_x = (sats[i].last_x + sats[j].last_x) * 0.5
        local mid_y = (sats[i].last_y + sats[j].last_y) * 0.5
        local lon = (mid_x / earth.W) * 360 - 180
        local lat = 90 - (mid_y / earth.H) * 180
        local pan  = clamp(lon / 180, -1, 1)
        local freq = 180 * 2 ^ ((lat + 30) / 60)
        engine.intersect(freq, 0.45, pan)
        intersect_cooldown = 18
        intersect_flash    = 6
        return
      end
    end
  end
end

-- ----- triggering helpers --------------------------------------------------

local function dur_for(terrain)
  if     terrain == earth.TERRAIN.OCEAN    then return 1.8
  elseif terrain == earth.TERRAIN.ICE      then return 1.6
  elseif terrain == earth.TERRAIN.MOUNTAIN then return 0.7 end
  return 0.4
end

-- non-active sats inflect the active sat's lead voice (no new voices).
-- Returns three normalized scalars derived from up to three non-active sats:
--   m1 (0..1) = brightness under 1st non-active sat   -> boost lead amp
--   m2 (0..1) = |latitude|/90 of 2nd non-active sat   -> stretch dur
--   m3 (-1..1) = longitude/180 of 3rd non-active sat  -> nudge pan
-- order is by slot index, skipping active_sat. With n_sats=1 all three are 0.
local function compute_mods()
  local m1, m2, m3 = 0, 0, 0
  local seen = 0
  for i = 1, #sats do
    if i ~= active_sat then
      seen = seen + 1
      local s = sats[i]
      if s.last_x >= 0 then
        if seen == 1 then
          m1 = earth.brightness_at(s.last_x, s.last_y)
        elseif seen == 2 then
          local lat = 90 - (s.last_y / earth.H) * 180
          m2 = math.abs(lat) / 90
        elseif seen == 3 then
          local lon = (s.last_x / earth.W) * 360 - 180
          m3 = clamp(lon / 180, -1, 1)
          break
        end
      end
    end
  end
  return m1, m2, m3
end

-- one engine.drone update per slot per tick. amp=0 for unallocated slots,
-- DRONE_AMP_FLOOR for the active slot (so the chord stays whole), brightness-
-- modulated for non-active slots. SC-side Lag.kr smooths step changes.
local function update_drones()
  for i = 1, N_MAX do
    local s = sats[i]
    local amp, pan
    local freq = DRONE_ROOT_HZ * (SAT_FREQ_MUL[i] or 1.0)
                                * (DRONE_OCT_MUL[i] or 1)
    if (not s) or s.last_x < 0 then
      amp, pan = 0, 0
    else
      local lon = (s.last_x / earth.W) * 360 - 180
      pan = clamp(lon / 180, -1, 1)
      if i == active_sat then
        amp = DRONE_AMP_FLOOR
      else
        amp = earth.brightness_at(s.last_x, s.last_y) * DRONE_AMP_MAX
      end
    end
    engine.drone(i, amp, freq, pan)
  end
end

local function trigger_from_cell(cell, amp_scale, sat_idx)
  amp_scale = amp_scale or 1.0
  sat_idx   = sat_idx   or active_sat
  local elev = earth.elevation_at(cell.ex, cell.ey)
  local lon  = (cell.ex / earth.W) * 360 - 180
  local pan  = clamp(lon / 180, -1, 1)
  local m1, m2, m3 = compute_mods()
  local b   = clamp(cell.b * amp_scale * (1 + m1 * 0.5), 0, 1)
  local dur = dur_for(cell.terrain) * (0.7 + m2 * 0.6)
  local p   = clamp(pan + m3 * 0.3, -1, 1)
  engine.trigger(cell.terrain, b, elev, p, dur,
    SAT_FREQ_MUL[sat_idx] or 1.0)
end

-- ----- tick ----------------------------------------------------------------

local function tick()
  clock_tick = clock_tick + 1
  for _, sat in ipairs(sats) do
    sat.angle = sat.angle + sat.speed
    if sat.angle > math.pi * 2 then sat.angle = sat.angle - math.pi * 2 end
  end
  earth_rot = earth_rot + earth_rot_speed

  -- combined scanline (also updates sat.last_x/last_y)
  local line = compute_combined_scanline()
  scanline_buf_push(line)

  -- update the persistent drone bed for all four slots. Done after the
  -- scanline pass since that's what filled in sat.last_x/last_y for every
  -- sat (including non-active ones that wouldn't otherwise be touched here).
  update_drones()

  -- active satellite drives the OLED trail + raster strip
  local act = sats[active_sat]
  if act then
    table.insert(trail, {x = act.last_x, y = act.last_y})
    if #trail > TRAIL_LEN then table.remove(trail, 1) end
    local b = earth.brightness_at(act.last_x, act.last_y)
    table.insert(raster, 1, b)
    if #raster > RASTER_LEN then raster[#raster] = nil end
    -- terrain trigger on active sat moving to new cell, inflected by the
    -- non-active sats via compute_mods (lift amp, stretch dur, nudge pan).
    if act.last_x ~= act.last_terr_x or act.last_y ~= act.last_terr_y then
      local terrain = earth.terrain_at(act.last_x, act.last_y)
      local elev    = earth.elevation_at(act.last_x, act.last_y)
      local lon     = (act.last_x / earth.W) * 360 - 180
      local pan     = clamp(lon / 180, -1, 1)
      local m1, m2, m3 = compute_mods()
      local b_mod   = clamp(b * (1 + m1 * 0.5), 0, 1)
      local dur_mod = dur_for(terrain) * (0.7 + m2 * 0.6)
      local pan_mod = clamp(pan + m3 * 0.3, -1, 1)
      engine.trigger(terrain, b_mod, elev, pan_mod, dur_mod,
        SAT_FREQ_MUL[active_sat] or 1.0)
      act.last_terr_x, act.last_terr_y = act.last_x, act.last_y
      act.level = b
    else
      act.level = act.level * 0.92
    end
  end

  -- intersections
  check_intersections()
  if intersect_flash > 0 then intersect_flash = intersect_flash - 1 end

  -- probes: tick life down. each probe gets at most ONE echo over its
  -- lifetime, fired only after PROBE_ECHO_MIN ticks elapsed AND only on
  -- a terrain class change with bright cell underneath. this keeps voice
  -- count bounded (no scrolling buffer pile-up).
  for i = #probes, 1, -1 do
    local p = probes[i]
    p.life = p.life - 1
    if p.life > 0 then
      if not p.echoed then
        local elapsed = p.max_life - p.life
        if elapsed >= PROBE_ECHO_MIN then
          local cell = scanline_buf[p.y][p.x]
          if cell.terrain ~= p.tap_terrain and cell.b > 0.25 then
            trigger_from_cell(cell, 0.35, active_sat)
            p.echoed = true
          end
        end
      end
    else
      table.remove(probes, i)
    end
  end

  redraw()
  grid_redraw()
end

-- ----- params --------------------------------------------------------------

local function add_params()
  params:add_separator("sonde")
  params:add_control("tempo", "tempo",
    controlspec.new(0.5, 8, 'lin', 0.5, 2, "Hz"))
  params:set_action("tempo", function(v)
    if metro_clock then metro_clock.time = 1 / v end
  end)

  params:add_number("n_sats", "satellites", 1, N_MAX, 1)
  params:set_action("n_sats", function(v)
    n_sats = v
    ensure_n_sats(v)
  end)
  params:add_number("active_sat", "active sat", 1, N_MAX, 1)
  params:set_action("active_sat", function(v)
    if v > #sats then v = #sats end
    active_sat = v
    -- reflect this sat's values into the editor params
    params:set("incl",  sats[v].inclination, true)
    params:set("phase", sats[v].phase, true)
    params:set("speed", sats[v].speed, true)
  end)

  params:add_control("incl", "inclination",
    controlspec.new(0, 90, 'lin', 1, 60, "°"))
  params:set_action("incl", function(v)
    if sats[active_sat] then sats[active_sat].inclination = v end
  end)
  params:add_control("phase", "phase",
    controlspec.new(-180, 180, 'lin', 1, 0, "°"))
  params:set_action("phase", function(v)
    if sats[active_sat] then sats[active_sat].phase = v end
  end)
  params:add_control("speed", "orbital speed",
    controlspec.new(0.005, 0.2, 'exp', 0, 0.06))
  params:set_action("speed", function(v)
    if sats[active_sat] then sats[active_sat].speed = v end
  end)
  params:add_control("earth_rot", "earth rotation",
    controlspec.new(0, 0.01, 'lin', 0, 0.0015))
  params:set_action("earth_rot", function(v) earth_rot_speed = v end)
end

-- ----- grid ----------------------------------------------------------------

local INCL_STEPS  = {22, 45, 67, 90}
local PHASE_STEPS = {-180, -60, 60, 180}

local function nearest_idx(steps, v)
  local best, bestd = 1, math.huge
  for i, s in ipairs(steps) do
    local d = math.abs(v - s)
    if d < bestd then bestd, best = d, i end
  end
  return best
end

local function led_bump(leds, x, y, lvl)
  if x < 1 or x > SCAN_W or y < 1 or y > SCAN_H then return end
  if lvl > 15 then lvl = 15 end
  if leds[y][x] < lvl then leds[y][x] = lvl end
end

local function compose_lrpt(leds, scale)
  for gy = 1, SCAN_H do
    local row = scanline_buf[gy]
    local emphasis = (gy == SCAN_H) and 1.25 or 1.0
    for gx = 1, SCAN_W do
      local lvl = math.floor(row[gx].b * 15 * scale * emphasis)
      led_bump(leds, gx, gy, lvl)
    end
  end
end

local function compose_probes(leds)
  for _, p in ipairs(probes) do
    local elapsed   = p.max_life - p.life
    local life_frac = p.life / p.max_life
    -- center cell stays lit, fades smoothly
    led_bump(leds, p.x, p.y, math.floor(15 * life_frac))
    -- diamond (manhattan) ring as the wave front. softer trailing rim
    -- one step behind reads like a wake, not a square outline.
    local r = elapsed
    if r > 0 and r <= 5 then
      local front = math.floor(13 * (1 - r / 6))
      local trail_lvl = math.floor(5  * (1 - r / 6))
      for dx = -r, r do
        for dy = -r, r do
          local md = math.abs(dx) + math.abs(dy)
          if md == r then
            led_bump(leds, p.x + dx, p.y + dy, front)
          elseif md == r - 1 and r >= 2 then
            led_bump(leds, p.x + dx, p.y + dy, trail_lvl)
          end
        end
      end
    end
  end
end

local function compose_intersect_flash(leds)
  if intersect_flash <= 0 then return end
  local f = intersect_flash * 2
  for y = 1, SCAN_H do
    for x = 1, SCAN_W do led_bump(leds, x, y, f) end
  end
end

function grid_redraw()
  if g == nil then return end
  local leds = {}
  for y = 1, SCAN_H do
    leds[y] = {}; for x = 1, SCAN_W do leds[y][x] = 0 end
  end

  if shift then
    -- dim waterfall under the editor
    compose_lrpt(leds, 0.25)
    -- cols 1..4: per-sat orbit editor.
    -- enabled (c <= n_sats): bright markers for current incl/phase choice.
    -- not yet enabled: dim full-column outline — invitation to tap.
    for c = 1, 4 do
      if c <= n_sats then
        local s = sats[c]
        local i_idx = nearest_idx(INCL_STEPS,  s.inclination)
        local p_idx = nearest_idx(PHASE_STEPS, s.phase)
        local high = (c == active_sat) and 14 or 9
        for r = 1, 4 do led_bump(leds, c, r,     (r == i_idx) and high or 4) end
        for r = 1, 4 do led_bump(leds, c, r + 4, (r == p_idx) and high or 4) end
      else
        for r = 1, 8 do led_bump(leds, c, r, 2) end
      end
    end
  else
    compose_lrpt(leds, 1.0)
    compose_probes(leds)
    compose_intersect_flash(leds)
  end

  g:all(0)
  for y = 1, SCAN_H do
    local row = leds[y]
    for x = 1, SCAN_W do
      if row[x] > 0 then g:led(x, y, row[x]) end
    end
  end
  g:refresh()
end

if g ~= nil then
  g.key = function(x, y, z)
    if z ~= 1 then return end
    if shift then
      -- cols 1..4 are sat editors. tap a not-yet-enabled column → auto-add.
      if x >= 1 and x <= N_MAX then
        if x > n_sats then params:set("n_sats", x) end
        active_sat = x
        if y >= 1 and y <= 4 then
          sats[x].inclination = INCL_STEPS[y]
        elseif y >= 5 and y <= 8 then
          sats[x].phase = PHASE_STEPS[y - 4]
        end
        params:set("incl",  sats[x].inclination, true)
        params:set("phase", sats[x].phase,       true)
        params:set("active_sat", x,              true)
      end
    else
      -- probe: per-cell throttle to prevent rapid-retap pile-up.
      -- if a probe already exists at this cell, refresh life and skip
      -- a new audio trigger so holding/spamming doesn't stack voices.
      if (clock_tick - (last_tap_tick[y][x] or -100)) < TAP_THROTTLE then
        return
      end
      last_tap_tick[y][x] = clock_tick
      local cell = scanline_buf[y][x]
      if cell and cell.b > 0 then
        local existing
        for _, p in ipairs(probes) do
          if p.x == x and p.y == y then existing = p; break end
        end
        if existing then
          existing.life       = PROBE_LIFE
          existing.tap_terrain = cell.terrain
          existing.echoed     = false
        else
          trigger_from_cell(cell, 1.0, active_sat)
          if #probes >= PROBE_MAX then table.remove(probes, 1) end
          table.insert(probes, {
            x = x, y = y,
            life = PROBE_LIFE, max_life = PROBE_LIFE,
            tap_terrain = cell.terrain,
            echoed = false,
          })
        end
      end
    end
    grid_redraw()
  end
end

-- ----- screen --------------------------------------------------------------

function redraw()
  screen.clear()
  screen.aa(0)

  -- earth coastline (one batched fill).
  -- skip polar boundary rows so the forced-ice top/bottom doesn't
  -- show as a 1-pixel horizontal line.
  screen.level(2)
  for _, c in ipairs(earth.coastline()) do
    if c.y >= POLAR_TOP_SKIP and c.y <= POLAR_BOTTOM_SKIP then
      screen.pixel(c.x, c.y + MAP_Y_OFFSET)
    end
  end
  screen.fill()

  -- ice cells brighter
  screen.level(5)
  for _, c in ipairs(earth.coastline()) do
    if c.t == earth.TERRAIN.ICE
       and c.y >= POLAR_TOP_SKIP and c.y <= POLAR_BOTTOM_SKIP then
      screen.pixel(c.x, c.y + MAP_Y_OFFSET)
    end
  end
  screen.fill()

  -- mountain cells distinguishable too
  screen.level(7)
  for _, c in ipairs(earth.coastline()) do
    if c.t == earth.TERRAIN.MOUNTAIN then
      screen.pixel(c.x, c.y + MAP_Y_OFFSET)
    end
  end
  screen.fill()

  -- orbit trail (active sat) bucketed into 3 tiers
  local tn = #trail
  local trecent = math.max(1, tn - 25)
  local tmid    = math.max(1, tn - 60)
  screen.level(3)
  for i = 1, math.min(tn, tmid - 1) do
    local p = trail[i]; screen.pixel(p.x, p.y + MAP_Y_OFFSET)
  end
  screen.fill()
  screen.level(7)
  for i = tmid, math.min(tn, trecent - 1) do
    local p = trail[i]; screen.pixel(p.x, p.y + MAP_Y_OFFSET)
  end
  screen.fill()
  screen.level(11)
  for i = trecent, tn do
    local p = trail[i]; screen.pixel(p.x, p.y + MAP_Y_OFFSET)
  end
  screen.fill()

  -- other satellites' positions as small dim dots
  for i, s in ipairs(sats) do
    if i ~= active_sat and s.last_x >= 0 then
      screen.level(9)
      screen.rect(s.last_x - 1, s.last_y - 1 + MAP_Y_OFFSET, 3, 3)
      screen.stroke()
    end
  end

  -- active satellite footprint + perpendicular scanline bar
  local act = sats[active_sat]
  if act and act.last_x >= 0 then
    screen.level(15)
    screen.rect(act.last_x - 1, act.last_y - 1 + MAP_Y_OFFSET, 3, 3)
    screen.stroke()
    -- physical scanline bar at active sat's footprint
    local _, pxn, pyn = compute_sat_scanline(act, act.last_x, act.last_y)
    screen.level(10)
    local center = (SCAN_W + 1) * 0.5
    for k = 1, SCAN_W do
      local off = (k - center) * SCAN_STEP
      local sx = math.floor(act.last_x + pxn * off + 0.5) % earth.W
      local sy = clamp(math.floor(act.last_y + pyn * off + 0.5), 0, earth.H - 1)
      screen.pixel(sx, sy + MAP_Y_OFFSET)
    end
    screen.fill()
  end

  -- LRPT-style raster strip at right edge — sits inside the map area.
  local buckets = {{}, {}, {}, {}}
  for i, b in ipairs(raster) do
    local q = clamp(math.floor(b * 4) + 1, 1, 4)
    table.insert(buckets[q], i)
  end
  local lvls = {2, 6, 10, 14}
  for q = 1, 4 do
    screen.level(lvls[q])
    for _, i in ipairs(buckets[q]) do
      screen.rect(124, i - 1 + MAP_Y_OFFSET, 4, 1)
    end
    screen.fill()
  end

  -- header. compact format keeps everything on one line even at p=180:
  --   default: "s1 i60° p180° n1"          right: "2.0Hz"
  --   edit:    "s1 i60° p180° edit -K2"    (drops to " ed-K2" if tight)
  --   paused:  "s1 i60° p180° pause"
  screen.level(0); screen.rect(0, 0, 128, 7); screen.fill()
  screen.level(15); screen.move(2, 6)
  local mode_suffix
  if shift then
    mode_suffix = (n_sats > 1) and " ed-K2" or " edit"
  elseif paused then
    mode_suffix = " pause"
  else
    mode_suffix = string.format(" n%d", n_sats)
  end
  screen.text(string.format("s%d i%d° p%d°%s",
    active_sat,
    math.floor(sats[active_sat].inclination),
    math.floor(sats[active_sat].phase),
    mode_suffix))

  -- tempo readout, right-aligned in the header bar.
  screen.move(127, 6)
  screen.text_right(string.format("%.1fHz", params:get("tempo")))

  screen.update()
end

-- ----- keys / encoders -----------------------------------------------------

function enc(n, d)
  if n == 1 then params:delta("tempo", d)
  elseif n == 2 then params:delta("incl",  d)
  elseif n == 3 then params:delta("phase", d) end
end

function key(n, z)
  if n == 1 then
    shift = (z == 1)
    grid_redraw()
    redraw()
    return
  end
  if z ~= 1 then return end
  if n == 2 then
    if shift then
      -- K1 + K2: drop the active satellite, leaving the rest in place.
      if n_sats > 1 then
        table.remove(sats, active_sat)
        n_sats = n_sats - 1
        if active_sat > n_sats then active_sat = n_sats end
        params:set("n_sats",     n_sats,     true)
        params:set("active_sat", active_sat, true)
        params:set("incl",  sats[active_sat].inclination, true)
        params:set("phase", sats[active_sat].phase,       true)
        grid_redraw()
        redraw()
      end
      return
    end
    for _, s in ipairs(sats) do s.angle = (s.k_angle_seed or 0) end
    earth_rot = 0
    trail     = {}
    raster    = {}
    probes    = {}
    intersect_flash = 0
    intersect_cooldown = 0
    scanline_buf_init()
    for _, s in ipairs(sats) do s.last_x, s.last_y, s.last_terr_x, s.last_terr_y = -1, -1, nil, nil end
    redraw()
  elseif n == 3 then
    paused = not paused
    if paused then metro_clock:stop() else metro_clock:start() end
    redraw()
  end
end

-- ----- lifecycle -----------------------------------------------------------

function init()
  earth.init()
  scanline_buf_init()
  for y = 1, SCAN_H do
    last_tap_tick[y] = {}
    for x = 1, SCAN_W do last_tap_tick[y][x] = -100 end
  end
  ensure_n_sats(1)
  add_params()
  metro_clock = metro.init()
  metro_clock.time  = 1 / params:get("tempo")
  metro_clock.event = tick
  metro_clock:start()
  redraw()
  grid_redraw()
end

function cleanup()
  if metro_clock then metro_clock:stop() end
end
