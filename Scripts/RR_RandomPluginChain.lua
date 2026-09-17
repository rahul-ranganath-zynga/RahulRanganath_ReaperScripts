-- Load 6 random plugins from the entire FX list into selected track
-- Then close all floating FX windows on that track

local NUM_PLUGINS = 6

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.ShowMessageBox("Select a track first", "Error", 0)
  return
end

-- Collect all installed FX
local all_fx = {}
local i = 0

while true do
  local retval, fxname = reaper.EnumInstalledFX(i)
  if not retval then break end
  table.insert(all_fx, fxname)
  i = i + 1
end

if #all_fx < NUM_PLUGINS then
  reaper.ShowMessageBox("Not enough plugins installed", "Error", 0)
  return
end

-- Shuffle helper
local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
end

shuffle(all_fx)

-- Insert the first N random plugins
for i = 1, NUM_PLUGINS do
  reaper.TrackFX_AddByName(track, all_fx[i], false, -1)
end

---------------------------------------------------------
-- CLOSE ALL FLOATING FX WINDOWS ON THIS TRACK (WORKING)
---------------------------------------------------------

local fx_count = reaper.TrackFX_GetCount(track)

for fx = 0, fx_count - 1 do
  local hwnd = reaper.TrackFX_GetFloatingWindow(track, fx)
  if hwnd then
    -- 2 = hide floating window
    reaper.TrackFX_Show(track, fx, 2)
  end
end

reaper.ShowMessageBox("Loaded 6 random plugins and closed all floating FX windows!", "Done", 0)
