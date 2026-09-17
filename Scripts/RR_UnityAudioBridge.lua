-- UnityAudioBridge.lua
-- ReaScript (Lua) - Run via: Actions > Load ReaScript > Run
--
-- Polls a temp file written by AudioDawBridge.cs in Unity.
-- No extensions, no sockets, no extra installs required.
--
-- File location Unity writes to:
--   Windows:  C:\Users\<you>\AppData\Local\Temp\UnityAudioBridge.txt
--   Mac/Linux: /tmp/UnityAudioBridge.txt
--
-- Protocol: one line per sound event:
--   /unity/audio/play <key_name>
--
-- On receiving a key it tries to:
--   1. Find a media item on any track whose source filename contains the key
--      and seeks + plays from that item's position.
--   2. Find a region whose name contains the key and seeks there.
--   3. If neither match, just logs the key to the ReaScript console.
--
-- HOW TO USE
--   1. In Reaper: Actions > Show action list > Load ReaScript > pick this file > Run
--   2. Hit Play in Unity — keys appear in the console as sounds play
--
-- CONFIG

local POLL_INTERVAL = 0.05   -- seconds between file checks (50ms)
local AUTO_PLAY     = true   -- start Reaper playback when a match is found
local AUTO_SEEK     = true   -- move edit cursor to matched item/region
local LOG_ALL       = true   -- print every received key to the console

-- File path must match Path.GetTempPath() + "UnityAudioBridge.txt" in C#
local BRIDGE_FILE
if reaper.GetOS():find("Win") then
  local tmp = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
  BRIDGE_FILE = tmp .. "\\UnityAudioBridge.txt"
else
  BRIDGE_FILE = "/tmp/UnityAudioBridge.txt"
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function log(msg)
  reaper.ShowConsoleMsg("[UnityBridge] " .. tostring(msg) .. "\n")
end

local function find_item_pos(key)
  local key_lower = key:lower()
  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local take = reaper.GetActiveTake(item)
      if take then
        local src  = reaper.GetMediaItemTake_Source(take)
        local file = reaper.GetMediaSourceFileName(src)
        if file:lower():find(key_lower, 1, true) then
          local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local _, tname = reaper.GetTrackName(track)
          return pos, tname
        end
      end
    end
  end
  return nil
end

local function find_region_pos(key)
  local key_lower = key:lower()
  local total = reaper.CountProjectMarkers(0)
  for i = 0, total - 1 do
    local _, isrgn, pos, _, name = reaper.EnumProjectMarkers(i)
    if isrgn and name:lower():find(key_lower, 1, true) then
      return pos, name
    end
  end
  return nil
end

local function handle_key(key)
  if LOG_ALL then
    log("Key: " .. key)
  end

  local ipos, tname = find_item_pos(key)
  if ipos then
    log("  -> item on \"" .. tostring(tname) .. "\" at " .. string.format("%.3f", ipos) .. "s")
    if AUTO_SEEK or AUTO_PLAY then
      reaper.SetEditCurPos(ipos, true, false)
    end
    if AUTO_PLAY then reaper.OnPlayButton() end
    return
  end

  local rpos, rname = find_region_pos(key)
  if rpos then
    log("  -> region \"" .. tostring(rname) .. "\" at " .. string.format("%.3f", rpos) .. "s")
    if AUTO_SEEK or AUTO_PLAY then
      reaper.SetEditCurPos(rpos, true, false)
    end
    if AUTO_PLAY then reaper.OnPlayButton() end
    return
  end

  log("  -> no item or region found for \"" .. key .. "\"")
end

-------------------------------------------------------------------------------
-- File polling
-------------------------------------------------------------------------------

local last_size   = 0
local last_check  = 0

local function poll()
  local now = reaper.time_precise()
  if now - last_check < POLL_INTERVAL then
    reaper.defer(poll)
    return
  end
  last_check = now

  local f = io.open(BRIDGE_FILE, "r")
  if not f then
    reaper.defer(poll)
    return
  end

  -- Seek to where we left off
  f:seek("set", last_size)
  local new_data = f:read("*a")
  last_size = f:seek("end")
  f:close()

  if new_data and #new_data > 0 then
    for line in new_data:gmatch("[^\n]+") do
      line = line:gsub("\r", "")
      if line ~= "" then
        local key = line:match("^/unity/audio/play%s+(.+)$")
        if key then
          handle_key(key)
        end
      end
    end
  end

  reaper.defer(poll)
end

-------------------------------------------------------------------------------
-- Start
-------------------------------------------------------------------------------

log("Polling: " .. BRIDGE_FILE)
log("AUTO_PLAY=" .. tostring(AUTO_PLAY) .. "  AUTO_SEEK=" .. tostring(AUTO_SEEK))
log("Hit Play in Unity to start receiving keys.")
log("------------------------------------------------------")

-- Reset tracking in case file already exists from a previous session
local f = io.open(BRIDGE_FILE, "r")
if f then
  f:seek("end")
  last_size = f:seek("end")
  f:close()
end

reaper.atexit(function()
  log("Bridge stopped.")
end)

poll()

