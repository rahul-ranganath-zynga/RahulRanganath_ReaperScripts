-- ============================================================
-- Name Tracks From First Item
--
-- Renames each selected track to match the name of the take
-- on its earliest timeline item.
--
-- HOW TO USE:
--   1. Select the tracks you want to rename
--   2. Run this script
-- ============================================================

local r = reaper

local function main()
  local sel_count = r.CountSelectedTracks(0)

  if sel_count == 0 then
    r.ShowMessageBox("No tracks selected.\nSelect one or more tracks and run again.", "Name From Item", 0)
    return
  end

  r.Undo_BeginBlock()

  local renamed = 0
  local skipped = 0

  for i = 0, sel_count - 1 do
    local track      = r.GetSelectedTrack(0, i)
    local item_count = r.CountTrackMediaItems(track)

    if item_count == 0 then
      skipped = skipped + 1
      goto continue
    end

    -- Find the item with the earliest start position
    local first_item = nil
    local earliest   = math.huge

    for j = 0, item_count - 1 do
      local item = r.GetTrackMediaItem(track, j)
      local pos  = r.GetMediaItemInfo_Value(item, "D_POSITION")
      if pos < earliest then
        earliest   = pos
        first_item = item
      end
    end

    -- Get the active take name
    local take = r.GetActiveTake(first_item)
    if not take then
      skipped = skipped + 1
      goto continue
    end

    local _, take_name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)

    if take_name == "" then
      skipped = skipped + 1
      goto continue
    end

    r.GetSetMediaTrackInfo_String(track, "P_NAME", take_name, true)
    renamed = renamed + 1

    ::continue::
  end

  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  r.Undo_EndBlock("Name tracks from first item", -1)

  r.ShowMessageBox(
    string.format("Done!\n\n• Tracks renamed: %d\n• Tracks skipped: %d\n  (no items, no take, or empty take name)", renamed, skipped),
    "Name From Item", 0
  )
end

main()

