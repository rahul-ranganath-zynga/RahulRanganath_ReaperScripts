-- ============================================================
-- GoT Sound Spec CSV → REAPER Project Populator
--
-- HOW TO USE:
--   1. Download your Google Sheet as CSV
--   2. Run this script from REAPER: Actions > Show Action List >
--      New Action > Load ReaScript
--   3. A file browser will open — navigate to your CSV and click OK
--   4. A second file browser will open — navigate to your dummy
--      file and click OK (this file will be placed on every L2)
--   5. Empty items are placed from CSV Start Time to End Time.
--      The dummy file sits at the start of each event (no looping).
-- ============================================================

local r = reaper

local function pick_csv_file()
  local retval, CSV_PATH = r.GetUserFileNameForRead("", "Select Sound Spec CSV", "csv")
  if not retval or CSV_PATH == "" then return nil end
  return CSV_PATH
end

local function pick_dummy_file()
  local retval, DUMMY_PATH = r.GetUserFileNameForRead("", "Select Dummy File for L2 Tracks", "wav")
  if not retval or DUMMY_PATH == "" then return nil end
  return DUMMY_PATH
end

local function trim(s)
  if not s then return "" end
  return s:match("^%s*(.-)%s*$")
end

local function parse_csv_line(line)
  local fields = {}
  local i = 1
  local len = #line
  while i <= len do
    local field = ""
    if line:sub(i, i) == '"' then
      i = i + 1
      while i <= len do
        local c = line:sub(i, i)
        if c == '"' then
          if line:sub(i + 1, i + 1) == '"' then
            field = field .. '"'
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          field = field .. c
          i = i + 1
        end
      end
    else
      while i <= len and line:sub(i, i) ~= ',' do
        field = field .. line:sub(i, i)
        i = i + 1
      end
    end
    table.insert(fields, trim(field))
    if i <= len and line:sub(i, i) == ',' then i = i + 1 end
  end
  return fields
end

local function read_csv(path)
  local f = io.open(path, "r")
  if not f then return nil, "Cannot open file: " .. path end
  local raw = f:read("*all")
  f:close()
  local lines = {}
  local current = ""
  local in_quotes = false
  for i = 1, #raw do
    local c = raw:sub(i, i)
    if c == '"' then
      in_quotes = not in_quotes
      current = current .. c
    elseif (c == '\n' or c == '\r') and not in_quotes then
      if c == '\r' and raw:sub(i + 1, i + 1) == '\n' then
        -- skip \r in \r\n
      else
        if current ~= "" then table.insert(lines, current) end
        current = ""
      end
    else
      current = current .. c
    end
  end
  if current ~= "" then table.insert(lines, current) end
  local rows = {}
  for _, line in ipairs(lines) do
    table.insert(rows, parse_csv_line(line))
  end
  return rows, nil
end

local function find_col(headers, name)
  local name_lower = name:lower()
  for i, h in ipairs(headers) do
    if trim(h):lower() == name_lower then return i end
  end
  return nil
end

local LENGTH_COL_NAMES = {
  "length (s)",
  "length (sec)",
  "length_sec",
  "duration (s)",
  "duration",
  "length",
  "length (ms)",
  "duration (ms)",
}

local function find_col_any(headers, names)
  for _, name in ipairs(names) do
    local idx = find_col(headers, name)
    if idx then return idx, name end
  end
  return nil, nil
end

local function header_is_ms(col_name)
  if not col_name then return false end
  local n = col_name:lower()
  return n:find("%(ms%)") ~= nil or n:match("ms$") ~= nil
end

-- Parses CSV length as seconds. Accepts plain numbers, "1.5s", "1500ms",
-- mm:ss, and hh:mm:ss. If the column header is milliseconds, plain numbers
-- are divided by 1000.
local function parse_length_seconds(str, unit_is_ms)
  if not str or str == "" then return nil end
  local s = trim(str)
  local h, m, sec = s:match("^(%d+):(%d+):([%d%.]+)$")
  if h then
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
  end
  local m2, sec2 = s:match("^(%d+):([%d%.]+)$")
  if m2 then
    return tonumber(m2) * 60 + tonumber(sec2)
  end
  local lower = s:lower()
  local num = tonumber(lower:match("^([%d%.]+)"))
  if not num or num < 0 then return nil end
  if lower:find("ms") or unit_is_ms then
    return num / 1000.0
  end
  return num
end

local function should_skip(key)
  if not key or key == "" then return true end
  if key == "^" or key == "^^" then return true end
  if key:lower():find("_vo_") then return true end
  return false
end

local BILLING_TO_BUS = {
  ["fanfare"]       = "fanfare",
  ["musicalrollup"] = "fanfare",
  ["term"]          = "fanfare",
  ["minirollup"]    = "fanfare",
  ["flourish"]      = "flourish",
  ["foley"]         = "foley",
  ["music"]         = "music",
  ["intro"]         = "music",
  ["basetune"]      = "music",
  ["bonustune"]     = "music",
}

local function billing_to_bus(billing)
  if not billing or billing == "" then return nil end
  local key = billing:lower():gsub("%s+", "")
  return BILLING_TO_BUS[key]
end

local function add_empty_item(track, start_time, duration, item_name)
  local item = r.AddMediaItemToTrack(track)
  r.SetMediaItemInfo_Value(item, "D_POSITION", start_time)
  r.SetMediaItemInfo_Value(item, "D_LENGTH", duration)
  local take = r.AddTakeToMediaItem(item)
  r.GetSetMediaItemTakeInfo_String(take, "P_NAME", item_name, true)
  return item
end

local function create_bus(name, insert_idx)
  r.InsertTrackAtIndex(insert_idx, true)
  local bus = r.GetTrack(0, insert_idx)
  r.GetSetMediaTrackInfo_String(bus, "P_NAME", name, true)
  return bus
end

local function route_to_bus(source_track, bus_track)
  r.SetMediaTrackInfo_Value(source_track, "B_MAINSEND", 0)
  r.CreateTrackSend(source_track, bus_track)
end

local function main()

  local CSV_PATH = pick_csv_file()
  if not CSV_PATH then return end

  local DUMMY_PATH = pick_dummy_file()
  if not DUMMY_PATH then return end

  local rows, err = read_csv(CSV_PATH)
  if not rows then
    r.ShowMessageBox("Error reading CSV:\n" .. (err or "unknown error"), "Import Failed", 0)
    return
  end
  if #rows < 2 then
    r.ShowMessageBox("CSV appears empty or has only a header row.", "Import Failed", 0)
    return
  end

  local headers     = rows[1]
  local col_key     = find_col(headers, "default map key")
  local col_billing = find_col(headers, "billing")
  local col_asset   = find_col(headers, "clip/asset")
  local col_start   = find_col(headers, "start time")
  local col_end     = find_col(headers, "end time")

  if not col_key     then r.ShowMessageBox("Could not find 'default map key' column.", "Import Failed", 0) return end
  if not col_billing then r.ShowMessageBox("Could not find 'billing' column.",          "Import Failed", 0) return end
  if not col_asset   then r.ShowMessageBox("Could not find 'clip/asset' column.",       "Import Failed", 0) return end
  if not col_start   then r.ShowMessageBox("Could not find 'Start Time' column.",       "Import Failed", 0) return end
  if not col_end     then r.ShowMessageBox("Could not find 'End Time' column.",         "Import Failed", 0) return end

  local track_list = {}
  for row_i = 2, #rows do
    local row     = rows[row_i]
    local key     = trim(row[col_key]     or "")
    local billing = trim(row[col_billing] or "")
    local asset   = trim(row[col_asset]   or "")
    local start_t = parse_length_seconds(row[col_start] or "", false)
    local end_t   = parse_length_seconds(row[col_end]   or "", false)
    if should_skip(key) then goto continue end
    if asset == ""      then goto continue end
    if not start_t or not end_t or end_t <= start_t then goto continue end
    table.insert(track_list, {
      key = key,
      billing = billing,
      asset = asset,
      start_t = start_t,
      length = end_t - start_t,
    })
    ::continue::
  end

  if #track_list == 0 then
    r.ShowMessageBox("No valid tracks found in the CSV after filtering.", "Import Done", 0)
    return
  end

  r.Undo_BeginBlock()

  local insert_idx = r.CountTracks(0)

  -- ---- Create the 4 bus tracks ----
  local bus_defs = {
    { key = "fanfare",  name = "fanfare"  },
    { key = "flourish", name = "flourish" },
    { key = "foley",    name = "fx"       },
    { key = "music",    name = "music"    },
  }

  local buses = {}
  for _, bd in ipairs(bus_defs) do
    local bus = create_bus(bd.name, insert_idx)
    buses[bd.key] = bus
    insert_idx = insert_idx + 1
  end

  -- ---- Create asset tracks (flat, after the buses) ----
  -- Each asset has exactly 2 tracks:
  --   parent     (named after clip/asset, folder opener)
  --   child      (single track: holds dummy file + named empty item)
  local tracks_made = 0
  local asset_blocks = {}

  for _, td in ipairs(track_list) do

    -- Parent track
    r.InsertTrackAtIndex(insert_idx, true)
    local parent_track = r.GetTrack(0, insert_idx)
    r.GetSetMediaTrackInfo_String(parent_track, "P_NAME", td.asset, true)
    r.SetMediaTrackInfo_Value(parent_track, "I_FOLDERDEPTH", 1)
    insert_idx  = insert_idx + 1
    tracks_made = tracks_made + 1

    -- Route parent → bus
    local bus_key   = billing_to_bus(td.billing)
    local bus_track = bus_key and buses[bus_key] or nil
    if bus_track then
      route_to_bus(parent_track, bus_track)
    else
      r.SetMediaTrackInfo_Value(parent_track, "B_MAINSEND", 0)
    end

    -- Single child track (closes the folder)
    r.InsertTrackAtIndex(insert_idx, true)
    local child_track = r.GetTrack(0, insert_idx)
    r.GetSetMediaTrackInfo_String(child_track, "P_NAME", td.asset, true)
    r.SetMediaTrackInfo_Value(child_track, "I_FOLDERDEPTH", -1)
    insert_idx = insert_idx + 1

    -- Named empty item spans CSV Start Time → End Time
    add_empty_item(child_track, td.start_t, td.length, td.asset)

    -- Dummy file at the event start only (native length, no loop)
    r.SetOnlyTrackSelected(child_track)
    r.SetEditCurPos(td.start_t, false, false)
    r.InsertMedia(DUMMY_PATH, 0)

    local dummy_item = r.GetTrackMediaItem(child_track, r.CountTrackMediaItems(child_track) - 1)
    if dummy_item then
      r.SetMediaItemInfo_Value(dummy_item, "D_POSITION", td.start_t)
      r.SetMediaItemInfo_Value(dummy_item, "B_LOOPSRC", 0)
    end

    table.insert(asset_blocks, {
      parent_track = parent_track,
      child_track  = child_track,
      bus_key      = bus_key,
    })
  end

  -- ----------------------------------------------------------------
  -- Reorganisation pass: move each asset block (2 tracks) to sit
  -- inside its bus folder, in original CSV order.
  -- ----------------------------------------------------------------

  local function track_idx(tr)
    return r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") - 1
  end

  local BUS_ORDER = { "fanfare", "flourish", "foley", "music" }

  local bus_groups      = {}
  local unrouted_blocks = {}
  for _, bk in ipairs(BUS_ORDER) do bus_groups[bk] = {} end

  for _, blk in ipairs(asset_blocks) do
    if blk.bus_key and bus_groups[blk.bus_key] then
      table.insert(bus_groups[blk.bus_key], blk)
    else
      table.insert(unrouted_blocks, blk)
    end
  end

  for _, bus_key in ipairs(BUS_ORDER) do
    local group = bus_groups[bus_key]
    if #group == 0 then goto next_bus end

    local bus_tr      = buses[bus_key]
    local dest_offset = 1   -- tracks already placed after this bus

    for asset_i, blk in ipairs(group) do

      -- Remove the routing send (no longer needed)
      local num_sends = r.GetTrackNumSends(blk.parent_track, 0)
      for si = num_sends - 1, 0, -1 do
        local dest = r.GetTrackSendInfo_Value(blk.parent_track, 0, si, "P_DESTTRACK")
        if dest == bus_tr then
          r.RemoveTrackSend(blk.parent_track, 0, si)
          break
        end
      end
      r.SetMediaTrackInfo_Value(blk.parent_track, "B_MAINSEND", 1)

      -- Select both tracks in this block
      r.SetOnlyTrackSelected(blk.parent_track)
      r.SetTrackSelected(blk.child_track, true)

      -- Move to just after the bus track (past already-moved blocks)
      local target_idx = track_idx(bus_tr) + dest_offset
      r.ReorderSelectedTracks(target_idx, 0)

      dest_offset = dest_offset + 2   -- parent + child
    end

    -- Fix folder depths for this whole bus group
    r.SetMediaTrackInfo_Value(bus_tr, "I_FOLDERDEPTH", 1)

    for asset_i, blk in ipairs(group) do
      local is_last = (asset_i == #group)
      r.SetMediaTrackInfo_Value(blk.parent_track, "I_FOLDERDEPTH", 1)
      -- Last child of last asset closes both sub-folder and bus folder
      r.SetMediaTrackInfo_Value(blk.child_track, "I_FOLDERDEPTH", is_last and -2 or -1)
    end

    ::next_bus::
  end

  -- Unrouted blocks: clean up folder depths, leave in place
  for _, blk in ipairs(unrouted_blocks) do
    r.SetMediaTrackInfo_Value(blk.parent_track, "I_FOLDERDEPTH", 1)
    r.SetMediaTrackInfo_Value(blk.child_track,  "I_FOLDERDEPTH", -1)
  end

  r.TrackList_AdjustWindows(true)
  r.UpdateArrange()
  r.Undo_EndBlock("Import from CSV: GoT Sound Spec", -1)

  r.ShowConsoleMsg(string.format(
    "[GoT CSV Import] Done. 4 buses + %d parent track(s) created and reorganised.\n" ..
    "[GoT CSV Import] Dummy file used for child tracks: %s\n",
    tracks_made, DUMMY_PATH
  ))
  r.ShowMessageBox(
    string.format(
      "Import complete!\n\n" ..
      "• Buses created: Fanfare, Flourish, FX, Music\n" ..
      "• Asset tracks created: %d\n" ..
      "• Each asset track is a child of its bus folder\n" ..
      "• Each asset has one child track with the dummy file\n" ..
      "• Empty items sit on Start Time → End Time from the CSV\n" ..
      "• Dummy file is placed at each event start (not looped)\n" ..
      "• Dummy file: %s",
      tracks_made, DUMMY_PATH
    ),
    "GoT CSV Import", 0
  )
end

main()

