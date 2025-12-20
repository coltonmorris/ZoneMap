-- ============================================
-- ZoneMap.lua (full addon runtime, fixed)
-- - Per-tile blobs: base64(deflate(raw 1024 bytes))
-- - Standard base64 decoder (works with Rust base64 STANDARD)
-- - LibDeflate DecompressDeflate
-- - LRU cache
-- - /zonemap (tile 0,0 sample) and /zmwhere (current player area via uiMapID + normalized pos)
-- ============================================

local ADDON_NAME, addon = ...

-- Expose for /run debugging: /run ZoneMap:DebugPrintTile("Kalimdor",0,0)
_G[ADDON_NAME] = addon

-- -------------------------
-- Dependencies
-- -------------------------
local LibDeflate = LibStub and LibStub("LibDeflate", true)
if not LibDeflate then
  error(ADDON_NAME .. " requires LibDeflate")
end

-- -------------------------
-- Storage
-- -------------------------
addon.tileGrids = addon.tileGrids or {}     -- [continentName] = { tiles = { [tileKey] = blob }, tileSize=16, tilesPerSide=64 }
addon._tileCache = addon._tileCache or {}  -- [continentName] = LRU cache
addon._continentBounds = addon._continentBounds or {} -- [continentMapID] = bounds + flips

-- -------------------------
-- u32 LE reader
-- -------------------------
local function read_u32_le(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  if not b1 then return 0 end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- -------------------------
-- Standard Base64 decoder (supports +/ and -_ alphabets, with = padding)
-- -------------------------
local _b64vals = {}
do
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #alphabet do
    _b64vals[alphabet:byte(i)] = i - 1
  end
  _b64vals[string.byte("-")] = _b64vals[string.byte("+")]
  _b64vals[string.byte("_")] = _b64vals[string.byte("/")]
end

local function base64_decode_std(s)
  if not s then return nil end
  s = s:gsub("%s+", "")
  local out = {}

  local i = 1
  local len = #s
  while i <= len do
    local c1 = s:byte(i); i = i + 1
    local c2 = s:byte(i); i = i + 1
    local c3 = s:byte(i); i = i + 1
    local c4 = s:byte(i); i = i + 1

    if not c1 or not c2 then break end

    local v1 = _b64vals[c1]
    local v2 = _b64vals[c2]
    if v1 == nil or v2 == nil then return nil end

    local pad3 = (c3 == string.byte("=")) or (c3 == nil)
    local pad4 = (c4 == string.byte("=")) or (c4 == nil)

    local v3 = pad3 and 0 or _b64vals[c3]
    local v4 = pad4 and 0 or _b64vals[c4]
    if (not pad3 and v3 == nil) or (not pad4 and v4 == nil) then return nil end

    local n = v1 * 262144 + v2 * 4096 + v3 * 64 + v4

    local b1 = math.floor(n / 65536) % 256
    local b2 = math.floor(n / 256) % 256
    local b3 = n % 256

    out[#out + 1] = string.char(b1)
    if not pad3 then out[#out + 1] = string.char(b2) end
    if not pad4 then out[#out + 1] = string.char(b3) end
  end

  return table.concat(out)
end

-- -------------------------
-- Tile decode: base64 -> deflate bytes -> raw tile bytes (1024)
-- -------------------------
local function decode_tile_blob(blob)
  if not blob then return nil end
  local compressed = base64_decode_std(blob)
  if not compressed then return nil end
  return LibDeflate:DecompressDeflate(compressed)
end

local function tile_key(tileX, tileY)
  return tileY * 64 + tileX
end

local function area_id_from_tile_raw(raw, chunkX, chunkY)
  local idx = chunkY * 16 + chunkX -- 0..255
  local offset = idx * 4 + 1       -- 1-indexed
  return read_u32_le(raw, offset)
end

-- -------------------------
-- LRU cache
-- -------------------------
local function new_lru_cache(maxEntries)
  local cache = {
    max = maxEntries or 256,
    map = {},
    head = nil, -- most recent
    tail = nil, -- least recent
    size = 0,
  }

  local function detach(node)
    if node.prev then node.prev.next = node.next end
    if node.next then node.next.prev = node.prev end
    if cache.head == node then cache.head = node.next end
    if cache.tail == node then cache.tail = node.prev end
    node.prev, node.next = nil, nil
  end

  local function attach_front(node)
    node.prev = nil
    node.next = cache.head
    if cache.head then cache.head.prev = node end
    cache.head = node
    if not cache.tail then cache.tail = node end
  end

  function cache:get(key)
    local node = self.map[key]
    if not node then return nil end
    detach(node)
    attach_front(node)
    return node.value
  end

  function cache:put(key, value)
    local node = self.map[key]
    if node then
      node.value = value
      detach(node)
      attach_front(node)
      return
    end

    node = { key = key, value = value }
    self.map[key] = node
    attach_front(node)
    self.size = self.size + 1

    if self.size > self.max then
      local evict = self.tail
      if evict then
        detach(evict)
        self.map[evict.key] = nil
        self.size = self.size - 1
      end
    end
  end

  function cache:clear()
    self.map = {}
    self.head, self.tail = nil, nil
    self.size = 0
  end

  return cache
end

local function get_continent_cache(continentName)
  local c = addon._tileCache[continentName]
  if not c then
    c = new_lru_cache(256)
    addon._tileCache[continentName] = c
  end
  return c
end

-- -------------------------
-- Public API: registration
-- -------------------------
function addon:RegisterTileGrid(continentName, grid)
  self.tileGrids[continentName] = grid
  get_continent_cache(continentName):clear()
  print(ADDON_NAME .. ": Registered grid " .. tostring(continentName) .. " tiles=" .. tostring(grid.tiles and "yes" or "no"))
end

function addon:SetTileCacheSize(continentName, maxEntries)
  addon._tileCache[continentName] = new_lru_cache(maxEntries)
end

-- -------------------------
-- Public API: lookup by tile/chunk
-- -------------------------
function addon:GetAreaIdForChunk(continentName, tileX, tileY, chunkX, chunkY)
  local grid = self.tileGrids[continentName]
  if not grid then return 0 end

  if tileX < 0 or tileX > 63 or tileY < 0 or tileY > 63 then return 0 end
  if chunkX < 0 or chunkX > 15 or chunkY < 0 or chunkY > 15 then return 0 end

  local key = tile_key(tileX, tileY)
  local cache = get_continent_cache(continentName)

  local raw = cache:get(key)
  if not raw then
    local blob = grid.tiles[key]
    if not blob then return 0 end
    raw = decode_tile_blob(blob)
    if not raw then return 0 end
    cache:put(key, raw)
  end

  return area_id_from_tile_raw(raw, chunkX, chunkY)
end

-- -------------------------
-- Public API: area name
-- -------------------------
function addon:GetAreaName(areaID)
  if not areaID or areaID == 0 then return nil end
  if C_Map and C_Map.GetAreaInfo then
    return C_Map.GetAreaInfo(areaID)
  end
  if GetAreaInfo then
    return GetAreaInfo(areaID)
  end
  return nil
end

-- -------------------------
-- Debug: print tile sample
-- -------------------------
function addon:DebugPrintTile(continentName, tileX, tileY)
  local grid = self.tileGrids[continentName]
  if not grid then
    print("No grid registered for", continentName)
    return
  end

  local key = tile_key(tileX, tileY)
  local blob = grid.tiles[key]
  if not blob then
    print("No tile data for", continentName, tileX, tileY, "key", key)
    return
  end

  local raw = decode_tile_blob(blob)
  if not raw then
    print("failed to decode tile blob")
    return
  end

  print(("Tile %s [%d,%d] key=%d rawLen=%d"):format(continentName, tileX, tileY, key, #raw))
  for y = 0, 3 do
    local line = {}
    for x = 0, 3 do
      line[#line + 1] = tostring(area_id_from_tile_raw(raw, x, y))
    end
    print("  ", table.concat(line, " "))
  end
end

-- /zonemap -> debug tile 0,0 in Kalimdor
SLASH_ZONEMAP1 = "/zonemap"
SlashCmdList.ZONEMAP = function()
  addon:DebugPrintTile("Kalimdor", 0, 0)
end

-- /zmtile <x> <y> -> debug specific tile
SLASH_ZMTILE1 = "/zmtile"
SlashCmdList.ZMTILE = function(msg)
  local x, y = msg:match("(%d+)%s+(%d+)")
  if not x or not y then
    print("Usage: /zmtile <tileX> <tileY>")
    return
  end
  x, y = tonumber(x), tonumber(y)
  local key = y * 64 + x
  print(("Checking tile (%d, %d) key=%d"):format(x, y, key))
  
  local grid = addon.tileGrids["Kalimdor"]
  if not grid then
    print("No Kalimdor grid loaded")
    return
  end
  
  if grid.tiles[key] then
    print("Tile EXISTS - decoding...")
    addon:DebugPrintTile("Kalimdor", x, y)
  else
    print("Tile NOT FOUND in data")
    -- Show nearby keys that exist
    for dy = -2, 2 do
      for dx = -2, 2 do
        local nearKey = (y + dy) * 64 + (x + dx)
        if grid.tiles[nearKey] then
          print(string.format("  nearby: tile[%d,%d] key=%d EXISTS", x+dx, y+dy, nearKey))
        end
      end
    end
  end
end

-- ============================================
-- uiMapID + normalized pos -> continent bounds -> tile/chunk
-- ============================================

-- Your grids use: "Kalimdor" and "Azeroth"
-- These continent uiMapIDs are commonly:
-- 12 = Kalimdor, 13 = Eastern Kingdoms
local CONTINENT_TO_GRIDNAME = {
  [1414] = "Kalimdor",
  [1415] = "Azeroth",
}

local createVec2 = CreateVector2D or Vector2D_Create

local function get_continent_map_id(uiMapID)
  -- Prefer MapUtil helper
  if MapUtil and MapUtil.GetMapParentInfo and Enum and Enum.UIMapType then
    local TOP_MOST = true
    local info = MapUtil.GetMapParentInfo(uiMapID, Enum.UIMapType.Continent, TOP_MOST)
    if info then
      return info.mapID or info.uiMapID
    end
  end

  -- Fallback: walk parents
  local cur = uiMapID
  while cur and cur ~= 0 and C_Map and C_Map.GetMapInfo and Enum and Enum.UIMapType do
    local mi = C_Map.GetMapInfo(cur)
    if not mi then break end
    if mi.mapType == Enum.UIMapType.Continent then
      return mi.mapID or cur
    end
    cur = mi.parentMapID
  end

  return nil
end

local function get_grid_name_for_continent(continentMapID)
  local name = CONTINENT_TO_GRIDNAME[continentMapID]
  if name then return name end
  return nil
end

local function get_world_pos(uiMapID, nx, ny)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and createVec2) then
    return nil
  end
  local pos = createVec2(nx, ny)
  local continentID, worldPos = C_Map.GetWorldPosFromMapPos(uiMapID, pos)
  if not worldPos then return nil end
  return continentID, worldPos
end

local function get_or_build_continent_bounds(continentMapID)
  local b = addon._continentBounds[continentMapID]
  if b and b.minX then return b end

  local _, p00 = get_world_pos(continentMapID, 0, 0)
  local _, p11 = get_world_pos(continentMapID, 1, 1)
  if not (p00 and p11) then return nil end

  local minX, maxX = math.min(p00.x, p11.x), math.max(p00.x, p11.x)
  local minY, maxY = math.min(p00.y, p11.y), math.max(p00.y, p11.y)
  if (maxX - minX) == 0 or (maxY - minY) == 0 then return nil end

  b = b or {}
  b.minX, b.maxX, b.minY, b.maxY = minX, maxX, minY, maxY
  b.flipX = b.flipX or false
  b.flipY = b.flipY or false
  addon._continentBounds[continentMapID] = b
  return b
end

-- -------------------------
-- ADT World Coordinate System
-- -------------------------
-- ADT tiles are 533.33333 yards each, 64x64 grid
-- World origin (0,0) is at tile (32,32)
-- World coords span approximately -17066.67 to +17066.67
local ADT_TILE_SIZE = 533.33333
local ADT_HALF_SIZE = ADT_TILE_SIZE * 32  -- 17066.67

-- Convert world coordinates directly to ADT tile and chunk indices
-- Returns: tileX, tileY, chunkX, chunkY
local function world_to_adt_tile_chunk(worldX, worldY)
  -- Convert world coords to continuous tile position
  -- Tile 0 is at +17066.67, Tile 63 is at -17066.67
  local tileXf = (ADT_HALF_SIZE - worldY) / ADT_TILE_SIZE
  local tileYf = (ADT_HALF_SIZE - worldX) / ADT_TILE_SIZE
  
  local tileX = math.floor(tileXf)
  local tileY = math.floor(tileYf)
  
  -- Clamp to valid range
  tileX = math.max(0, math.min(63, tileX))
  tileY = math.max(0, math.min(63, tileY))
  
  -- Calculate chunk within tile (16 chunks per tile)
  local chunkXf = (tileXf - tileX) * 16
  local chunkYf = (tileYf - tileY) * 16
  
  local chunkX = math.floor(chunkXf)
  local chunkY = math.floor(chunkYf)
  
  chunkX = math.max(0, math.min(15, chunkX))
  chunkY = math.max(0, math.min(15, chunkY))
  
  return tileX, tileY, chunkX, chunkY
end

function addon:GetAreaIdForUiMapPos(uiMapID, nx, ny)
  if not uiMapID or not nx or not ny then return 0 end

  local continentMapID = get_continent_map_id(uiMapID)
  if not continentMapID then return 0 end

  local gridName = get_grid_name_for_continent(continentMapID)
  if not gridName then return 0 end
  if not (self.tileGrids and self.tileGrids[gridName]) then return 0 end

  -- Get world position from map position
  local _, wpos = get_world_pos(uiMapID, nx, ny)
  if not wpos then return 0 end

  -- NOTE: C_Map API returns coords swapped from WoW's traditional X/Y
  -- wpos.x is actually Y, wpos.y is actually X in ADT terms
  local realWorldX, realWorldY = wpos.y, wpos.x
  
  -- Use direct world-to-ADT conversion (no bounds/UV needed)
  local tileX, tileY, chunkX, chunkY = world_to_adt_tile_chunk(realWorldX, realWorldY)
  local area = self:GetAreaIdForChunk(gridName, tileX, tileY, chunkX, chunkY)
  
  return area, gridName, continentMapID, tileX, tileY, chunkX, chunkY, realWorldX, realWorldY
end

-- /zmwhere -> print current areaID + name + tile/chunk
SLASH_ZMWHERE1 = "/zmwhere"
SlashCmdList.ZMWHERE = function()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
    print("zmwhere: C_Map APIs not available")
    return
  end

  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then
    print("zmwhere: no mapID")
    return
  end

  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then
    print("zmwhere: no player position (instance/phasing?)")
    return
  end

  -- What does the game think the zone is?
  local gameZone = GetZoneText and GetZoneText() or "?"
  local gameSubzone = GetSubZoneText and GetSubZoneText() or "?"
  print(("zmwhere GAME: zone='%s' subzone='%s'"):format(gameZone, gameSubzone))

  local area, gridName, contID, tx, ty, cx, cy, worldX, worldY = addon:GetAreaIdForUiMapPos(mapID, pos.x, pos.y)
  local name = addon:GetAreaName(area) or "?"
  
  print(("zmwhere DEBUG: worldPos=(%.2f, %.2f) [after swap]"):format(worldX or 0, worldY or 0))
  print(("zmwhere RESULT: tile=%s,%s chunk=%s,%s areaID=%s name='%s'"):format(
    tostring(tx), tostring(ty), tostring(cx), tostring(cy), tostring(area), tostring(name)))
  
  -- Debug: check if tile exists in grid
  if gridName and tx and ty then
    local grid = addon.tileGrids[gridName]
    if grid and grid.tiles then
      local key = ty * 64 + tx  -- tile_key formula
      local hasData = grid.tiles[key] ~= nil
      print(("zmwhere DEBUG: tileKey=%d exists=%s"):format(key, tostring(hasData)))
      
      -- Also try swapped key
      local swappedKey = tx * 64 + ty
      local hasSwapped = grid.tiles[swappedKey] ~= nil
      print(("zmwhere DEBUG: swappedKey=%d exists=%s"):format(swappedKey, tostring(hasSwapped)))
      
      -- If swapped exists but normal doesn't, try lookup with swapped
      if hasSwapped and not hasData then
        local swapArea = addon:GetAreaIdForChunk(gridName, ty, tx, cy, cx)
        local swapName = addon:GetAreaName(swapArea) or "?"
        print(("zmwhere TRYING SWAPPED: areaID=%s name='%s'"):format(tostring(swapArea), swapName))
      end
      
      -- If both missing, try nearby tiles to find data
      if not hasData and not hasSwapped then
        print("zmwhere DEBUG: Tile missing! Checking nearby tiles...")
        for dy = -1, 1 do
          for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
              local nearbyKey = (ty + dy) * 64 + (tx + dx)
              if grid.tiles[nearbyKey] then
                local nearbyArea = addon:GetAreaIdForChunk(gridName, tx + dx, ty + dy, cx, cy)
                local nearbyName = addon:GetAreaName(nearbyArea) or "?"
                print(string.format("  nearby tile[%d,%d] key=%d: areaID=%d name='%s'",
                  tx + dx, ty + dy, nearbyKey, nearbyArea, nearbyName))
              end
            end
          end
        end
      end
    end
  end
  
  -- Compare
  if name == gameZone or name == gameSubzone or (gameSubzone ~= "" and name == gameSubzone) then
    print("|cff00ff00zmwhere MATCH!|r")
  else
    print("|cffff0000zmwhere MISMATCH: got '" .. name .. "' but game says '" .. gameZone .. "/" .. gameSubzone .. "'|r")
  end
end