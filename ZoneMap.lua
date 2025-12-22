-- ZoneMap.lua
-- Slash command: /adtwhere
--
-- Computes ADT tile (x,y) + MCNK chunk (cx,cy) from WoW API world vector.
-- Decodes tile data and looks up area names.
--
-- Your client continent UiMapIDs:
--   1414 = Kalimdor
--   1415 = Eastern Kingdoms (ADT prefix "azeroth")

local ADDON_NAME, addon = ...
_G[ADDON_NAME] = addon

print(ADDON_NAME .. " loaded")

-- -------------------------
-- Dependencies
-- -------------------------
local LibDeflate = LibStub and LibStub("LibDeflate", true)
if not LibDeflate then
  error(ADDON_NAME .. " requires LibDeflate")
end

-- -------------------------
-- Storage for tile grids
-- -------------------------
addon.tileGrids = addon.tileGrids or {}
addon._tileCache = addon._tileCache or {}

-- -------------------------
-- u32 LE reader
-- -------------------------
local function read_u32_le(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  if not b1 then return 0 end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- -------------------------
-- Base64 decoder
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

local function base64_decode(s)
  if not s then return nil end
  s = s:gsub("%s+", "")
  local out = {}
  local i, len = 1, #s
  while i <= len do
    local c1, c2, c3, c4 = s:byte(i, i + 3)
    i = i + 4
    if not c1 or not c2 then break end
    local v1, v2 = _b64vals[c1], _b64vals[c2]
    if v1 == nil or v2 == nil then return nil end
    local pad3 = (c3 == 61) or (c3 == nil)
    local pad4 = (c4 == 61) or (c4 == nil)
    local v3 = pad3 and 0 or _b64vals[c3]
    local v4 = pad4 and 0 or _b64vals[c4]
    if (not pad3 and v3 == nil) or (not pad4 and v4 == nil) then return nil end
    local n = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if not pad3 then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if not pad4 then out[#out + 1] = string.char(n % 256) end
  end
  return table.concat(out)
end

-- -------------------------
-- Tile decode: base64 -> deflate -> raw bytes
-- -------------------------
local function decode_tile_blob(blob)
  if not blob then return nil end
  local compressed = base64_decode(blob)
  if not compressed then return nil end
  return LibDeflate:DecompressDeflate(compressed)
end

local function tile_key(tileX, tileY)
  return tileY * 64 + tileX
end

local function area_id_from_raw(raw, chunkX, chunkY)
  local idx = chunkY * 16 + chunkX
  local offset = idx * 4 + 1
  return read_u32_le(raw, offset)
end

-- -------------------------
-- Simple LRU cache
-- -------------------------
local function new_cache(max)
  return { max = max or 64, map = {}, keys = {}, size = 0 }
end

local function cache_get(c, key)
  return c.map[key]
end

local function cache_put(c, key, value)
  if c.map[key] then c.map[key] = value; return end
  c.map[key] = value
  c.keys[#c.keys + 1] = key
  c.size = c.size + 1
  if c.size > c.max then
    local old = table.remove(c.keys, 1)
    c.map[old] = nil
    c.size = c.size - 1
  end
end

local function get_cache(gridName)
  local c = addon._tileCache[gridName]
  if not c then c = new_cache(64); addon._tileCache[gridName] = c end
  return c
end

-- -------------------------
-- Public API: Register tile grids (called by data files)
-- -------------------------
function addon:RegisterTileGrid(name, grid)
  self.tileGrids[name] = grid
  addon._tileCache[name] = new_cache(64)
  local count = 0
  if grid.tiles then for _ in pairs(grid.tiles) do count = count + 1 end end
  print(ADDON_NAME .. ": Registered " .. name .. " (" .. count .. " tiles)")
end

-- -------------------------
-- Public API: Get area ID for a chunk
-- -------------------------
function addon:GetAreaIdForChunk(gridName, tileX, tileY, chunkX, chunkY)
  local grid = self.tileGrids[gridName]
  if not grid then return 0 end
  if tileX < 0 or tileX > 63 or tileY < 0 or tileY > 63 then return 0 end
  if chunkX < 0 or chunkX > 15 or chunkY < 0 or chunkY > 15 then return 0 end
  
  local key = tile_key(tileX, tileY)
  local cache = get_cache(gridName)
  local raw = cache_get(cache, key)
  if not raw then
    local blob = grid.tiles and grid.tiles[key]
    if not blob then return 0 end
    raw = decode_tile_blob(blob)
    if not raw then return 0 end
    cache_put(cache, key, raw)
  end
  return area_id_from_raw(raw, chunkX, chunkY)
end

-- -------------------------
-- Public API: Get area name from ID
-- -------------------------
function addon:GetAreaName(areaID)
  if not areaID or areaID == 0 then return nil end
  if C_Map and C_Map.GetAreaInfo then return C_Map.GetAreaInfo(areaID) end
  if GetAreaInfo then return GetAreaInfo(areaID) end
  return nil
end

-- =========================================================
-- Position calculation helpers
-- =========================================================

local createVec2 = CreateVector2D or Vector2D_Create

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

-- Swap axes: treat API world vector as (Y,X) for our ADT math.
local function world_xy(worldPos)
  return worldPos.y, worldPos.x
end

local function continent_name_prefix_grid(continentMapID)
  if continentMapID == 1414 then return "Kalimdor", "kalimdor", "Kalimdor" end
  if continentMapID == 1415 then return "Eastern Kingdoms", "azeroth", "Azeroth" end
  return ("continent:" .. tostring(continentMapID)), nil, nil
end

local function get_continent_map_id(uiMapID)
  if not (C_Map and C_Map.GetMapInfo and Enum and Enum.UIMapType) then return nil end
  local cur = uiMapID
  while cur and cur ~= 0 do
    local info = C_Map.GetMapInfo(cur)
    if not info then break end
    if info.mapType == Enum.UIMapType.Continent then
      return cur
    end
    cur = info.parentMapID
  end
  return nil
end

local function get_world_pos(mapID, nx, ny)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and createVec2) then return nil end
  local pos = createVec2(nx, ny)
  local _, worldPos = C_Map.GetWorldPosFromMapPos(mapID, pos)
  if not worldPos then return nil end
  return worldPos
end

local function get_continent_bounds(continentMapID)
  -- Bounds in world-vector space for the continent itself.
  -- IMPORTANT: swap axes consistently.
  local p00 = get_world_pos(continentMapID, 0, 0)
  local p11 = get_world_pos(continentMapID, 1, 1)
  if not (p00 and p11) then return nil end

  local x00, y00 = world_xy(p00)
  local x11, y11 = world_xy(p11)

  local minX, maxX = math.min(x00, x11), math.max(x00, x11)
  local minY, maxY = math.min(y00, y11), math.max(y00, y11)
  if (maxX - minX) == 0 or (maxY - minY) == 0 then return nil end

  return minX, maxX, minY, maxY
end

local function uv_to_tile_chunk(u, v)
  u, v = clamp01(u), clamp01(v)

  local tileX = math.floor(u * 64)
  local tileY = math.floor(v * 64)
  if tileX > 63 then tileX = 63 end
  if tileY > 63 then tileY = 63 end

  local withinU = u * 64 - tileX
  local withinV = v * 64 - tileY

  local chunkX = math.floor(withinU * 16)
  local chunkY = math.floor(withinV * 16)
  if chunkX > 15 then chunkX = 15 end
  if chunkY > 15 then chunkY = 15 end

  return tileX, tileY, chunkX, chunkY
end

local function world_to_tile_chunk(worldX, worldY, minX, maxX, minY, maxY, flipX, flipY)
  local u = (worldX - minX) / (maxX - minX)
  local v = (worldY - minY) / (maxY - minY)
  if flipX then u = 1 - u end
  if flipY then v = 1 - v end
  return uv_to_tile_chunk(u, v)
end

local function fmt_adt(prefix, tileX, tileY)
  if not prefix then return "(unknownprefix)" end
  return string.format("%s_%d_%d.adt", prefix, tileX, tileY)
end

-- =========================================================
-- Direct world-to-ADT tile calculation (standard WoW formula)
-- ADT tiles are 533.33333 yards, 64x64 grid, origin at tile 32,32
-- =========================================================
local ADT_TILE_SIZE = 533.33333
local ADT_HALF_SIZE = ADT_TILE_SIZE * 32  -- 17066.67

-- Try all 8 possible axis/sign combinations to find the right mapping
local function get_direct_tile_candidates(worldX, worldY)
  local candidates = {}
  
  -- Try different formulas - one of these should be correct
  local formulas = {
    -- Format: {tileX formula, tileY formula, label}
    function() return 
      math.floor((ADT_HALF_SIZE - worldX) / ADT_TILE_SIZE),
      math.floor((ADT_HALF_SIZE - worldY) / ADT_TILE_SIZE),
      "(-X,-Y)"
    end,
    function() return 
      math.floor((ADT_HALF_SIZE + worldX) / ADT_TILE_SIZE),
      math.floor((ADT_HALF_SIZE + worldY) / ADT_TILE_SIZE),
      "(+X,+Y)"
    end,
    function() return 
      math.floor((ADT_HALF_SIZE - worldX) / ADT_TILE_SIZE),
      math.floor((ADT_HALF_SIZE + worldY) / ADT_TILE_SIZE),
      "(-X,+Y)"
    end,
    function() return 
      math.floor((ADT_HALF_SIZE + worldX) / ADT_TILE_SIZE),
      math.floor((ADT_HALF_SIZE - worldY) / ADT_TILE_SIZE),
      "(+X,-Y)"
    end,
    -- Swapped X/Y
    function() return 
      math.floor((ADT_HALF_SIZE - worldY) / ADT_TILE_SIZE),
      math.floor((ADT_HALF_SIZE - worldX) / ADT_TILE_SIZE),
      "(-Y,-X)"
    end,
    function() return 
      math.floor((ADT_HALF_SIZE + worldY) / ADT_TILE_SIZE),
      math.floor((ADT_HALF_SIZE + worldX) / ADT_TILE_SIZE),
      "(+Y,+X)"
    end,
    function() return 
      math.floor((ADT_HALF_SIZE - worldY) / ADT_TILE_SIZE),
      math.floor((ADT_HALF_SIZE + worldX) / ADT_TILE_SIZE),
      "(-Y,+X)"
    end,
    function() return 
      math.floor((ADT_HALF_SIZE + worldY) / ADT_TILE_SIZE),
      math.floor((ADT_HALF_SIZE - worldX) / ADT_TILE_SIZE),
      "(+Y,-X)"
    end,
  }
  
  local seen = {}
  for _, fn in ipairs(formulas) do
    local tx, ty, label = fn()
    tx = math.max(0, math.min(63, tx))
    ty = math.max(0, math.min(63, ty))
    local key = ty * 64 + tx
    if not seen[key] then
      seen[key] = true
      candidates[#candidates + 1] = {tileX = tx, tileY = ty, key = key, label = label}
    end
  end
  
  return candidates
end

local function get_chunk_in_tile(worldX, worldY, tileX, tileY, formula)
  -- Calculate position within tile and then chunk
  -- This is approximate - we'll try a few variations
  local tileWorldX = ADT_HALF_SIZE - (tileX + 0.5) * ADT_TILE_SIZE
  local tileWorldY = ADT_HALF_SIZE - (tileY + 0.5) * ADT_TILE_SIZE
  
  -- Offset within tile (0 to 1)
  local offsetX = (worldX - (ADT_HALF_SIZE - (tileX + 1) * ADT_TILE_SIZE)) / ADT_TILE_SIZE
  local offsetY = (worldY - (ADT_HALF_SIZE - (tileY + 1) * ADT_TILE_SIZE)) / ADT_TILE_SIZE
  
  offsetX = math.max(0, math.min(1, offsetX))
  offsetY = math.max(0, math.min(1, offsetY))
  
  local chunkX = math.floor(offsetX * 16)
  local chunkY = math.floor(offsetY * 16)
  chunkX = math.max(0, math.min(15, chunkX))
  chunkY = math.max(0, math.min(15, chunkY))
  
  return chunkX, chunkY
end

-- =========================================================
-- /adtwhere - Main slash command
-- =========================================================
SLASH_ADTWHERE1 = "/adtwhere"
SlashCmdList.ADTWHERE = function()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
    print("adtwhere: C_Map APIs not available")
    return
  end

  local uiMapID = C_Map.GetBestMapForUnit("player")
  if not uiMapID then
    print("adtwhere: no uiMapID")
    return
  end

  local pos = C_Map.GetPlayerMapPosition(uiMapID, "player")
  if not pos then
    print("adtwhere: no player map position (instance/phasing?)")
    return
  end

  local continentMapID = get_continent_map_id(uiMapID)
  if not continentMapID then
    print("adtwhere: couldn't find continent parent for uiMapID", uiMapID)
    return
  end

  local worldPos = get_world_pos(uiMapID, pos.x, pos.y)
  if not worldPos then
    print("adtwhere: failed to get world pos")
    return
  end

  -- Get raw world pos (before any swap)
  local rawX, rawY = worldPos.x, worldPos.y
  -- Also get swapped version
  local swapX, swapY = worldPos.y, worldPos.x

  local contName, adtPrefix, gridName = continent_name_prefix_grid(continentMapID)
  
  -- What does the game think the zone is?
  local gameZone = GetZoneText and GetZoneText() or "?"
  local gameSubzone = GetSubZoneText and GetSubZoneText() or "?"
  
  print(string.format("adtwhere: Game says zone='%s' subzone='%s'", gameZone, gameSubzone))
  print(string.format("adtwhere: rawWorldPos=(%.2f, %.2f) swapped=(%.2f, %.2f)", rawX, rawY, swapX, swapY))

  local grid = gridName and addon.tileGrids[gridName]
  if not grid then
    print("adtwhere: No tile grid loaded for " .. (gridName or "nil"))
    return
  end

  -- Calculate what tile 40,32 would need in world coords (for debugging)
  -- If tile 40,32 is correct, what formula works?
  -- tile = floor((HALF - coord) / SIZE) => coord = HALF - (tile + 0.5) * SIZE
  local target40x = ADT_HALF_SIZE - (40 + 0.5) * ADT_TILE_SIZE  -- ~ -4533
  local target32y = ADT_HALF_SIZE - (32 + 0.5) * ADT_TILE_SIZE  -- ~ -267
  print(string.format("DEBUG: For tile[40,32], world would be ~(%.0f, %.0f) with formula HALF-tile*SIZE", target40x, target32y))
  
  -- Brute force: scan a range of tiles and find ones with valid data
  print("Scanning tiles for matches...")
  
  local best = nil
  local foundTiles = {}
  
  -- Get approximate center from our formulas
  local approxTileX = math.floor((ADT_HALF_SIZE - rawX) / ADT_TILE_SIZE)
  local approxTileY = math.floor((ADT_HALF_SIZE - rawY) / ADT_TILE_SIZE)
  
  -- Also try with swapped and different signs
  local centers = {
    {math.floor((ADT_HALF_SIZE - rawX) / ADT_TILE_SIZE), math.floor((ADT_HALF_SIZE - rawY) / ADT_TILE_SIZE)},
    {math.floor((ADT_HALF_SIZE + rawX) / ADT_TILE_SIZE), math.floor((ADT_HALF_SIZE + rawY) / ADT_TILE_SIZE)},
    {math.floor((ADT_HALF_SIZE - swapX) / ADT_TILE_SIZE), math.floor((ADT_HALF_SIZE - swapY) / ADT_TILE_SIZE)},
    {math.floor((ADT_HALF_SIZE + swapX) / ADT_TILE_SIZE), math.floor((ADT_HALF_SIZE + swapY) / ADT_TILE_SIZE)},
    {32, 32}, -- center of map
    {40, 32}, -- known Valley of Trials tile (for testing)
  }
  
  local scannedKeys = {}
  
  for _, center in ipairs(centers) do
    local cx, cy = center[1], center[2]
    -- Scan ±8 tiles around each center
    for dy = -8, 8 do
      for dx = -8, 8 do
        local tx = cx + dx
        local ty = cy + dy
        if tx >= 0 and tx <= 63 and ty >= 0 and ty <= 63 then
          local key = ty * 64 + tx
          if not scannedKeys[key] then
            scannedKeys[key] = true
            
            local hasBlob = grid.tiles and grid.tiles[key] ~= nil
            if hasBlob then
              -- Check center chunk for area
              local areaID = addon:GetAreaIdForChunk(gridName, tx, ty, 8, 8)
              if areaID and areaID ~= 0 then
                local areaName = addon:GetAreaName(areaID) or "?"
                foundTiles[#foundTiles + 1] = {
                  tileX = tx,
                  tileY = ty,
                  key = key,
                  areaID = areaID,
                  areaName = areaName,
                }
                
                -- Check if this matches game zone
                local score = 100
                if areaName == gameZone or areaName == gameSubzone then
                  score = 1000
                end
                
                if not best or score > best.score then
                  best = {
                    score = score,
                    tileX = tx,
                    tileY = ty,
                    chunkX = 8,
                    chunkY = 8,
                    areaID = areaID,
                    areaName = areaName,
                  }
                end
              end
            end
          end
        end
      end
    end
  end
  
  -- Print found tiles (limit output)
  print(string.format("Found %d tiles with data in scan range:", #foundTiles))
  local shown = 0
  for _, t in ipairs(foundTiles) do
    -- Prioritize showing matches to current zone
    if t.areaName == gameZone or t.areaName == gameSubzone or shown < 10 then
      local marker = (t.areaName == gameZone or t.areaName == gameSubzone) and "|cff00ff00*|r" or " "
      print(string.format(" %s tile[%d,%d] key=%d: area=%d '%s'",
        marker, t.tileX, t.tileY, t.key, t.areaID, t.areaName))
      shown = shown + 1
    end
  end
  if #foundTiles > shown then
    print(string.format("  ... and %d more tiles", #foundTiles - shown))
  end

  -- Print the best result
  if best and best.score > 0 then
    local isMatch = (best.areaName == gameZone or best.areaName == gameSubzone)
    local color = isMatch and "|cff00ff00" or "|cffffff00"
    print(string.format("%sBEST: tile[%d,%d] chunk[%d,%d] -> '%s' (areaID=%d)|r",
      color, best.tileX, best.tileY, best.chunkX, best.chunkY,
      best.areaName, best.areaID or 0))
  else
    print("|cffff0000No valid area found|r")
  end
end

-- =========================================================
-- /adtsearch <area_id> - Search all tiles for an area ID
-- =========================================================
SLASH_ADTSEARCH1 = "/adtsearch"
SlashCmdList.ADTSEARCH = function(msg)
  local searchID = tonumber(msg)
  if not searchID then
    print("Usage: /adtsearch <area_id>")
    print("Example: /adtsearch 215")
    return
  end

  local areaName = addon:GetAreaName(searchID) or "Unknown"
  print(string.format("Searching for areaID=%d (%s)...", searchID, areaName))

  local totalMatches = 0
  local tileMatches = {}

  for gridName, grid in pairs(addon.tileGrids) do
    if grid.tiles then
      local gridMatches = 0
      
      for key, blob in pairs(grid.tiles) do
        -- Decode the tile
        local raw = decode_tile_blob(blob)
        if raw then
          local tileY = math.floor(key / 64)
          local tileX = key % 64
          local chunksInTile = {}
          
          -- Check all 256 chunks in this tile
          for cy = 0, 15 do
            for cx = 0, 15 do
              local areaID = area_id_from_raw(raw, cx, cy)
              if areaID == searchID then
                chunksInTile[#chunksInTile + 1] = string.format("[%d,%d]", cx, cy)
                gridMatches = gridMatches + 1
              end
            end
          end
          
          -- If this tile had matches, record it
          if #chunksInTile > 0 then
            tileMatches[#tileMatches + 1] = {
              grid = gridName,
              tileX = tileX,
              tileY = tileY,
              key = key,
              chunks = chunksInTile,
            }
          end
        end
      end
      
      totalMatches = totalMatches + gridMatches
    end
  end

  -- Print results
  if #tileMatches == 0 then
    print(string.format("|cffff0000No matches found for areaID=%d|r", searchID))
  else
    print(string.format("|cff00ff00Found %d chunk(s) across %d tile(s):|r", totalMatches, #tileMatches))
    
    -- Limit output to avoid spam
    local maxTilesToShow = 20
    for i, match in ipairs(tileMatches) do
      if i > maxTilesToShow then
        print(string.format("  ... and %d more tiles (truncated)", #tileMatches - maxTilesToShow))
        break
      end
      
      local chunkStr
      if #match.chunks <= 5 then
        chunkStr = table.concat(match.chunks, ", ")
      else
        chunkStr = string.format("%s, ... (%d total)", 
          table.concat({match.chunks[1], match.chunks[2], match.chunks[3]}, ", "),
          #match.chunks)
      end
      
      print(string.format("  %s tile[%d,%d] key=%d: %s",
        match.grid, match.tileX, match.tileY, match.key, chunkStr))
    end
  end
end

-- =========================================================
-- /adtgrid - Toggle ADT tile grid overlay on world map
-- =========================================================
local gridOverlay = nil
local gridEnabled = false
local gridLines = {}
local gridLabels = {}

local function CreateGridOverlay()
  if gridOverlay then return gridOverlay end
  
  -- Create main overlay frame attached to WorldMapFrame
  local frame = CreateFrame("Frame", "ZoneMapGridOverlay", WorldMapFrame:GetCanvas())
  frame:SetAllPoints()
  frame:SetFrameStrata("HIGH")
  
  gridOverlay = frame
  return frame
end

local function WorldToMapPoint(continentMapID, worldX, worldY)
  -- Convert world coordinates to normalized map coordinates (0-1)
  -- This is the inverse of GetWorldPosFromMapPos
  if not (C_Map and C_Map.GetMapWorldSize) then return nil, nil end
  
  -- Get the map's world size and position
  local mapInfo = C_Map.GetMapInfo(continentMapID)
  if not mapInfo then return nil, nil end
  
  -- Use bounds to convert
  local p00 = get_world_pos(continentMapID, 0, 0)
  local p11 = get_world_pos(continentMapID, 1, 1)
  if not (p00 and p11) then return nil, nil end
  
  -- Normalize
  local nx = (worldX - p00.x) / (p11.x - p00.x)
  local ny = (worldY - p00.y) / (p11.y - p00.y)
  
  return nx, ny
end

local function ADTTileToWorld(tileX, tileY)
  -- Convert ADT tile corner to world coordinates
  -- Tile 0 starts at +17066.67, tile 63 ends at -17066.67
  local worldX = ADT_HALF_SIZE - tileX * ADT_TILE_SIZE
  local worldY = ADT_HALF_SIZE - tileY * ADT_TILE_SIZE
  return worldX, worldY
end

local function UpdateGridOverlay()
  if not gridOverlay or not gridEnabled then return end
  
  -- Hide existing elements
  for _, line in ipairs(gridLines) do
    line:Hide()
  end
  for _, label in ipairs(gridLabels) do
    label:Hide()
  end
  
  -- Get current map (use the actual displayed map, not continent)
  local mapID = WorldMapFrame:GetMapID()
  if not mapID then return end
  
  local canvas = WorldMapFrame:GetCanvas()
  local canvasWidth, canvasHeight = canvas:GetSize()
  if canvasWidth == 0 or canvasHeight == 0 then return end
  
  -- Get world bounds for the CURRENT map (not continent)
  -- This ensures the grid scales correctly when viewing zones vs continent
  local p00 = get_world_pos(mapID, 0, 0)
  local p11 = get_world_pos(mapID, 1, 1)
  if not (p00 and p11) then return end
  
  -- Calculate which tiles are visible based on current map bounds
  local minWX, maxWX = math.min(p00.x, p11.x), math.max(p00.x, p11.x)
  local minWY, maxWY = math.min(p00.y, p11.y), math.max(p00.y, p11.y)
  
  -- World coords to tile (accounting for axis swap)
  local minTileX = math.max(0, math.floor((ADT_HALF_SIZE - maxWY) / ADT_TILE_SIZE) - 1)
  local maxTileX = math.min(63, math.ceil((ADT_HALF_SIZE - minWY) / ADT_TILE_SIZE) + 1)
  local minTileY = math.max(0, math.floor((ADT_HALF_SIZE - maxWX) / ADT_TILE_SIZE) - 1)
  local maxTileY = math.min(63, math.ceil((ADT_HALF_SIZE - minWX) / ADT_TILE_SIZE) + 1)
  
  local lineIdx = 0
  local labelIdx = 0
  
  -- Draw vertical lines (tile X boundaries)
  for tileX = minTileX, maxTileX + 1 do
    local worldY_line = ADT_HALF_SIZE - tileX * ADT_TILE_SIZE
    
    -- Convert to map normalized coords using current map bounds
    local nx = (worldY_line - p00.y) / (p11.y - p00.y)
    
    if nx >= -0.5 and nx <= 1.5 then
      lineIdx = lineIdx + 1
      local line = gridLines[lineIdx]
      if not line then
        line = gridOverlay:CreateLine(nil, "OVERLAY")
        line:SetThickness(2)
        gridLines[lineIdx] = line
      end
      
      line:SetColorTexture(1, 1, 0, 0.6)  -- Yellow, semi-transparent
      line:SetStartPoint("TOPLEFT", canvas, nx * canvasWidth, 0)
      line:SetEndPoint("BOTTOMLEFT", canvas, nx * canvasWidth, -canvasHeight)
      line:Show()
    end
  end
  
  -- Draw horizontal lines (tile Y boundaries)
  for tileY = minTileY, maxTileY + 1 do
    local worldX_line = ADT_HALF_SIZE - tileY * ADT_TILE_SIZE
    
    -- Convert to map normalized coords
    local ny = (worldX_line - p00.x) / (p11.x - p00.x)
    
    if ny >= -0.5 and ny <= 1.5 then
      lineIdx = lineIdx + 1
      local line = gridLines[lineIdx]
      if not line then
        line = gridOverlay:CreateLine(nil, "OVERLAY")
        line:SetThickness(2)
        gridLines[lineIdx] = line
      end
      
      line:SetColorTexture(1, 1, 0, 0.6)
      line:SetStartPoint("TOPLEFT", canvas, 0, -ny * canvasHeight)
      line:SetEndPoint("TOPRIGHT", canvas, canvasWidth, -ny * canvasHeight)
      line:Show()
    end
  end
  
  -- Check if we're viewing a zone (not the full continent)
  -- If viewing continent, skip labels to reduce clutter
  local continentMapID = get_continent_map_id(mapID)
  local isZoomedIn = (mapID ~= continentMapID)
  
  -- Calculate how many tiles are visible - if too many, skip labels
  local visibleTilesX = maxTileX - minTileX
  local visibleTilesY = maxTileY - minTileY
  local showLabels = isZoomedIn or (visibleTilesX <= 15 and visibleTilesY <= 15)
  
  -- Draw labels at tile centers (only when zoomed in enough)
  if showLabels then
    for tileX = minTileX, maxTileX do
      for tileY = minTileY, maxTileY do
        local worldY_center = ADT_HALF_SIZE - (tileX + 0.5) * ADT_TILE_SIZE
        local worldX_center = ADT_HALF_SIZE - (tileY + 0.5) * ADT_TILE_SIZE
        
        local nx = (worldY_center - p00.y) / (p11.y - p00.y)
        local ny = (worldX_center - p00.x) / (p11.x - p00.x)
        
        if nx >= -0.1 and nx <= 1.1 and ny >= -0.1 and ny <= 1.1 then
          labelIdx = labelIdx + 1
          local label = gridLabels[labelIdx]
          if not label then
            label = gridOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            gridLabels[labelIdx] = label
          end
          
          label:ClearAllPoints()
          label:SetPoint("CENTER", canvas, "TOPLEFT", nx * canvasWidth, -ny * canvasHeight)
          label:SetText(string.format("%d,%d", tileX, tileY))
          label:SetTextColor(1, 1, 0, 0.9)
          label:Show()
        end
      end
    end
  end
end

local function ToggleGridOverlay(enable)
  if enable == nil then
    gridEnabled = not gridEnabled
  else
    gridEnabled = enable
  end
  
  if gridEnabled then
    CreateGridOverlay()
    gridOverlay:Show()
    
    -- Hook map updates
    if not gridOverlay.hooked then
      hooksecurefunc(WorldMapFrame, "OnMapChanged", UpdateGridOverlay)
      WorldMapFrame:HookScript("OnShow", UpdateGridOverlay)
      gridOverlay.hooked = true
    end
    
    UpdateGridOverlay()
    print("|cff00ff00ADT Grid overlay ENABLED|r")
  else
    if gridOverlay then
      gridOverlay:Hide()
    end
    print("|cffff0000ADT Grid overlay DISABLED|r")
  end
end

SLASH_ADTGRID1 = "/adtgrid"
SlashCmdList.ADTGRID = function()
  ToggleGridOverlay()
end

-- Update grid when map changes
if WorldMapFrame then
  WorldMapFrame:HookScript("OnShow", function()
    if gridEnabled then
      C_Timer.After(0.1, UpdateGridOverlay)
    end
  end)
end

-- =========================================================
-- /zonemap - Draw individual zones with colored overlays
-- =========================================================
local zoneOverlay = nil
local zoneEnabled = false
local zoneTextures = {}
local zoneLabels = {}
local zoneColorCache = {}

-- Generate a consistent color for an area ID using a hash
local function GetAreaColor(areaID)
  if zoneColorCache[areaID] then
    return unpack(zoneColorCache[areaID])
  end
  
  -- Use golden ratio for nice color distribution
  local golden_ratio = 0.618033988749895
  local hue = ((areaID * golden_ratio) % 1.0)
  
  -- HSV to RGB conversion (saturation=0.65, value=0.85)
  local s, v = 0.65, 0.85
  local c = v * s
  local x = c * (1 - math.abs((hue * 6) % 2 - 1))
  local m = v - c
  
  local r, g, b
  local h_sector = math.floor(hue * 6)
  if h_sector == 0 then r, g, b = c, x, 0
  elseif h_sector == 1 then r, g, b = x, c, 0
  elseif h_sector == 2 then r, g, b = 0, c, x
  elseif h_sector == 3 then r, g, b = 0, x, c
  elseif h_sector == 4 then r, g, b = x, 0, c
  else r, g, b = c, 0, x
  end
  
  r, g, b = r + m, g + m, b + m
  zoneColorCache[areaID] = {r, g, b}
  return r, g, b
end

local function CreateZoneOverlay()
  if zoneOverlay then return zoneOverlay end
  
  local frame = CreateFrame("Frame", "ZoneMapZoneOverlay", WorldMapFrame:GetCanvas())
  frame:SetAllPoints()
  frame:SetFrameStrata("MEDIUM")  -- Below grid overlay
  
  zoneOverlay = frame
  return frame
end

local MAX_ZONE_TEXTURES = 1000  -- Hard cap on textures to prevent lag
local zoneDebug = true  -- Set to false to disable debug messages

local function UpdateZoneOverlay()
  if not zoneOverlay or not zoneEnabled then return end
  
  -- Hide existing elements
  for _, tex in ipairs(zoneTextures) do
    tex:Hide()
  end
  for _, label in ipairs(zoneLabels) do
    label:Hide()
  end
  
  local mapID = WorldMapFrame:GetMapID()
  if not mapID then 
    if zoneDebug then print("zonemap: no mapID") end
    return 
  end
  
  local canvas = WorldMapFrame:GetCanvas()
  local canvasWidth, canvasHeight = canvas:GetSize()
  if canvasWidth == 0 or canvasHeight == 0 then 
    if zoneDebug then print("zonemap: canvas size 0") end
    return 
  end
  
  -- Get world bounds for current map
  local p00 = get_world_pos(mapID, 0, 0)
  local p11 = get_world_pos(mapID, 1, 1)
  if not (p00 and p11) then 
    if zoneDebug then print("zonemap: no world pos for mapID", mapID) end
    return 
  end
  
  -- Determine continent and grid
  local continentMapID = get_continent_map_id(mapID)
  if not continentMapID then 
    if zoneDebug then print("zonemap: no continent for mapID", mapID) end
    return 
  end
  
  local _, _, gridName = continent_name_prefix_grid(continentMapID)
  local grid = gridName and addon.tileGrids[gridName]
  if not grid then 
    if zoneDebug then print("zonemap: no grid for", gridName or "nil") end
    return 
  end
  
  -- Calculate visible tile range
  local minWX, maxWX = math.min(p00.x, p11.x), math.max(p00.x, p11.x)
  local minWY, maxWY = math.min(p00.y, p11.y), math.max(p00.y, p11.y)
  
  local minTileX = math.max(0, math.floor((ADT_HALF_SIZE - maxWY) / ADT_TILE_SIZE) - 1)
  local maxTileX = math.min(63, math.ceil((ADT_HALF_SIZE - minWY) / ADT_TILE_SIZE) + 1)
  local minTileY = math.max(0, math.floor((ADT_HALF_SIZE - maxWX) / ADT_TILE_SIZE) - 1)
  local maxTileY = math.min(63, math.ceil((ADT_HALF_SIZE - minWX) / ADT_TILE_SIZE) + 1)
  
  -- Calculate how many tiles are visible
  local visibleTilesX = maxTileX - minTileX + 1
  local visibleTilesY = maxTileY - minTileY + 1
  local totalVisibleTiles = visibleTilesX * visibleTilesY
  
  if zoneDebug then 
    print(string.format("zonemap: mapID=%d tiles=[%d-%d, %d-%d] (%d total)", 
      mapID, minTileX, maxTileX, minTileY, maxTileY, totalVisibleTiles))
  end
  
  -- Determine sampling rate based on zoom level
  -- More tiles visible = sample fewer chunks
  local chunkStep = 1
  if totalVisibleTiles > 30 then
    chunkStep = 2  -- Sample every other chunk
  end
  if totalVisibleTiles > 60 then
    chunkStep = 4  -- Sample every 4th chunk
  end
  if totalVisibleTiles > 150 then
    chunkStep = 8  -- Sample every 8th chunk (very coarse)
  end
  
  local texIdx = 0
  local labelIdx = 0
  
  -- Chunk size in world coordinates (adjusted for step)
  local baseChunkWorldSize = ADT_TILE_SIZE / 16
  local chunkWorldSize = baseChunkWorldSize * chunkStep
  
  -- Track zone centroids for labels
  local zoneCentroids = {}  -- areaID -> {sumX, sumY, count, name}
  
  -- Draw each chunk as a colored square
  for tileX = minTileX, maxTileX do
    for tileY = minTileY, maxTileY do
      local key = tile_key(tileX, tileY)
      if grid.tiles and grid.tiles[key] then
        -- Decode tile data
        local cache = get_cache(gridName)
        local raw = cache_get(cache, key)
        if not raw then
          local blob = grid.tiles[key]
          raw = decode_tile_blob(blob)
          if raw then
            cache_put(cache, key, raw)
          end
        end
        
        if raw then
          -- Draw chunks with sampling
          for chunkY = 0, 15, chunkStep do
            for chunkX = 0, 15, chunkStep do
              -- Hit texture limit, stop
              if texIdx >= MAX_ZONE_TEXTURES then
                break
              end
              
              local areaID = area_id_from_raw(raw, chunkX, chunkY)
              if areaID and areaID ~= 0 then
                -- Calculate chunk world position using same approach as adtgrid labels
                -- Tile center: ADT_HALF_SIZE - (tile + 0.5) * ADT_TILE_SIZE
                -- Chunk offset from tile center: (chunk - 7.5) / 16 * ADT_TILE_SIZE
                -- chunkY is row (0=north edge of tile, 15=south edge)
                -- chunkX is col (0=west edge of tile, 15=east edge)
                local chunkOffsetRow = (chunkY + (chunkStep - 1) / 2 - 7.5) / 16
                local chunkOffsetCol = (chunkX + (chunkStep - 1) / 2 - 7.5) / 16
                local chunkWorldY = ADT_HALF_SIZE - (tileX + 0.5 + chunkOffsetRow) * ADT_TILE_SIZE
                local chunkWorldX = ADT_HALF_SIZE - (tileY + 0.5 + chunkOffsetCol) * ADT_TILE_SIZE
                
                -- Convert to map normalized coords
                local nx = (chunkWorldY - p00.y) / (p11.y - p00.y)
                local ny = (chunkWorldX - p00.x) / (p11.x - p00.x)
                
                -- Check if visible
                if nx >= -0.1 and nx <= 1.1 and ny >= -0.1 and ny <= 1.1 then
                  -- Calculate chunk size on canvas
                  local chunkNormWidth = chunkWorldSize / math.abs(p11.y - p00.y)
                  local chunkNormHeight = chunkWorldSize / math.abs(p11.x - p00.x)
                  
                  local pixelX = nx * canvasWidth
                  local pixelY = ny * canvasHeight
                  local pixelW = chunkNormWidth * canvasWidth
                  local pixelH = chunkNormHeight * canvasHeight
                  
                  -- Get or create texture
                  texIdx = texIdx + 1
                  local tex = zoneTextures[texIdx]
                  if not tex then
                    tex = zoneOverlay:CreateTexture(nil, "ARTWORK")
                    zoneTextures[texIdx] = tex
                  end
                  
                  local r, g, b = GetAreaColor(areaID)
                  tex:SetColorTexture(r, g, b, 0.4)
                  tex:ClearAllPoints()
                  tex:SetPoint("TOPLEFT", canvas, "TOPLEFT", pixelX - pixelW/2, -(pixelY - pixelH/2))
                  tex:SetSize(pixelW, pixelH)
                  tex:Show()
                  
                  -- Track centroid for labels
                  if not zoneCentroids[areaID] then
                    local areaName = addon:GetAreaName(areaID)
                    zoneCentroids[areaID] = {sumX = 0, sumY = 0, count = 0, name = areaName}
                  end
                  zoneCentroids[areaID].sumX = zoneCentroids[areaID].sumX + pixelX
                  zoneCentroids[areaID].sumY = zoneCentroids[areaID].sumY + pixelY
                  zoneCentroids[areaID].count = zoneCentroids[areaID].count + 1
                end
              end
            end
            if texIdx >= MAX_ZONE_TEXTURES then break end
          end
        end
      end
      if texIdx >= MAX_ZONE_TEXTURES then break end
    end
    if texIdx >= MAX_ZONE_TEXTURES then break end
  end
  
  -- Draw zone labels at centroids
  for areaID, centroid in pairs(zoneCentroids) do
    if centroid.name and centroid.count > 2 then  -- Only label zones with enough visible chunks
      local avgX = centroid.sumX / centroid.count
      local avgY = centroid.sumY / centroid.count
      
      -- Check if centroid is on canvas
      if avgX >= 0 and avgX <= canvasWidth and avgY >= 0 and avgY <= canvasHeight then
        labelIdx = labelIdx + 1
        local label = zoneLabels[labelIdx]
        if not label then
          label = zoneOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
          label:SetFont(label:GetFont(), 11, "OUTLINE")
          zoneLabels[labelIdx] = label
        end
        
        local r, g, b = GetAreaColor(areaID)
        label:SetTextColor(r, g, b, 1)
        label:ClearAllPoints()
        label:SetPoint("CENTER", canvas, "TOPLEFT", avgX, -avgY)
        label:SetText(centroid.name)
        label:Show()
      end
    end
  end
end

local function ToggleZoneOverlay(enable)
  if enable == nil then
    zoneEnabled = not zoneEnabled
  else
    zoneEnabled = enable
  end
  
  if zoneEnabled then
    CreateZoneOverlay()
    zoneOverlay:Show()
    
    if not zoneOverlay.hooked then
      hooksecurefunc(WorldMapFrame, "OnMapChanged", UpdateZoneOverlay)
      WorldMapFrame:HookScript("OnShow", UpdateZoneOverlay)
      zoneOverlay.hooked = true
    end
    
    UpdateZoneOverlay()
    print("|cff00ff00Zone overlay ENABLED|r - showing area boundaries")
  else
    if zoneOverlay then
      zoneOverlay:Hide()
    end
    print("|cffff0000Zone overlay DISABLED|r")
  end
end

SLASH_ZONEMAP1 = "/zonemap"
SlashCmdList.ZONEMAP = function()
  ToggleZoneOverlay()
end

-- Update zone overlay when map changes
if WorldMapFrame then
  WorldMapFrame:HookScript("OnShow", function()
    if zoneEnabled then
      C_Timer.After(0.1, UpdateZoneOverlay)
    end
  end)
end