-- earth.lua
-- terrain data + lookups for sonde / listening earth.
-- the "score surface" the satellite scans.
--
-- coastlines come from real NASA Blue Marble (2048×1024) downsampled
-- box-filter to 128×64. mountains overlaid on land via known ranges.

local M = {}

M.W = 128
M.H = 64

M.TERRAIN = {
  OCEAN    = 0,
  LAND     = 1,
  ICE      = 2,
  MOUNTAIN = 3,
}

-- mountain ranges (overlay on land cells, upgrade to MOUNTAIN class).
-- {name, lat_min, lat_max, lon_min, lon_max}
local mountain_regions = {
  {"rockies",         32,  62, -130, -105},
  {"sierra_madre",    16,  32, -106,  -98},
  {"andes",          -55,  12,  -78,  -65},
  {"appalachian",     33,  48,  -84,  -73},
  {"alps",            43,  48,    5,   16},
  {"pyrenees",        42,  44,   -2,    3},
  {"caucasus",        38,  44,   38,   50},
  {"atlas",           29,  37,  -10,   12},
  {"ethiopian",       -3,  16,   33,   42},
  {"hindu_kush",      32,  39,   65,   75},
  {"himalayas",       25,  38,   72,  104},
  {"tien_shan",       38,  44,   70,   82},
  {"altai",           45,  53,   82,   95},
  {"japanese_alps",   34,  46,  133,  145},
  {"new_guinea_hi",   -8,  -2,  136,  150},
  {"new_zealand_alp",-46, -41,  165,  175},
  {"south_alaskan",   58,  64, -155, -130},
  {"transantarctic", -88, -75,  150,  170},  -- note: south of 65 already ice
}

local data            -- terrain class per cell
local coast           -- precomputed boundary cells
local rows_src        -- raw character rows from earth_data

local function in_box(lat, lon, r)
  return lat >= r[2] and lat <= r[3] and lon >= r[4] and lon <= r[5]
end

local function char_to_terrain(c)
  if c == "." then return M.TERRAIN.OCEAN end
  if c == "l" then return M.TERRAIN.LAND  end
  if c == "i" then return M.TERRAIN.ICE   end
  return M.TERRAIN.OCEAN
end

local function maybe_mountain(lat, lon)
  for _, mr in ipairs(mountain_regions) do
    if in_box(lat, lon, mr) then return true end
  end
  return false
end

local function terrain_raw(x, y)
  if y < 0 or y >= M.H then return M.TERRAIN.OCEAN end
  return data[y][x % M.W]
end

local function is_coast(x, y)
  local t = terrain_raw(x, y)
  if t == M.TERRAIN.OCEAN then return false end
  if terrain_raw(x - 1, y) ~= t then return true end
  if terrain_raw(x + 1, y) ~= t then return true end
  if terrain_raw(x, y - 1) ~= t then return true end
  if terrain_raw(x, y + 1) ~= t then return true end
  return false
end

function M.init()
  rows_src = include("sonde/lib/earth_data")
  data = {}
  for y = 0, M.H - 1 do
    data[y] = {}
    local row = rows_src[y + 1]
    for x = 0, M.W - 1 do
      local c = row:sub(x + 1, x + 1)
      local t = char_to_terrain(c)
      if t == M.TERRAIN.LAND then
        local lat = 90 - (y + 0.5) / M.H * 180
        local lon = (x + 0.5) / M.W * 360 - 180
        if maybe_mountain(lat, lon) then t = M.TERRAIN.MOUNTAIN end
      end
      data[y][x] = t
    end
  end
  coast = {}
  for y = 0, M.H - 1 do
    for x = 0, M.W - 1 do
      if is_coast(x, y) then
        table.insert(coast, {x = x, y = y, t = data[y][x]})
      end
    end
  end
end

function M.terrain_at(x, y) return terrain_raw(x, y) end

function M.brightness_at(x, y)
  local t = terrain_raw(x, y)
  if t == M.TERRAIN.OCEAN    then return 0.30 end
  if t == M.TERRAIN.LAND     then return 0.55 end
  if t == M.TERRAIN.MOUNTAIN then return 0.78 end
  if t == M.TERRAIN.ICE      then return 0.95 end
  return 0
end

function M.elevation_at(x, y)
  local t = terrain_raw(x, y)
  if t == M.TERRAIN.OCEAN    then return 0.0 end
  if t == M.TERRAIN.LAND     then return 0.35 end
  if t == M.TERRAIN.MOUNTAIN then return 0.85 end
  if t == M.TERRAIN.ICE      then return 0.7 end
  return 0
end

function M.coastline() return coast end

function M.latlon_to_xy(lat, lon)
  while lon > 180  do lon = lon - 360 end
  while lon < -180 do lon = lon + 360 end
  local x = math.floor((lon + 180) / 360 * M.W) % M.W
  local y = math.floor((90 - lat)  / 180 * M.H)
  if y < 0 then y = 0 end
  if y >= M.H then y = M.H - 1 end
  return x, y
end

return M
