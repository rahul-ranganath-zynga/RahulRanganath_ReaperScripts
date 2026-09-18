-- GOT VO Tool for REAPER
-- Requires: ReaImGui  https://github.com/cfillion/reaimgui
--           js_ReaScriptAPI  (optional, enables native folder picker)
--
-- Edit the priority_groups table below to add/remove shows and characters.

local r = reaper
local ctx

-- ── Seed random once at startup ───────────────────────────────────────────
math.randomseed(os.time())

-- ── Persisted state ────────────────────────────────────────────────────────
local csv_folder   = r.GetExtState("GOTVOTool", "csv_folder")
local audio_folder = r.GetExtState("GOTVOTool", "audio_folder")
local game_id_buf  = r.GetExtState("GOTVOTool", "game_id")
local initials_buf = r.GetExtState("GOTVOTool", "char_initials")

-- ── Runtime state ──────────────────────────────────────────────────────────
local all_rows       = {}
local filtered_rows  = {}
local character_list = {}
local character_set  = {}

local combo_entries  = {}
local combo_sel_char = ""

local search_buf    = ""
local selected_line = -1

local pre_roll_buf  = "100"
local post_roll_buf = "150"

local status_msg = ""
local status_ok  = true

-- ── UI colour constants ───────────────────────────────────────────────────
local COLOR_HEADING = 0xFFDD88FF   -- gold:       "Line Details" title
local COLOR_LABEL   = 0xAADDFFFF   -- light blue: detail field keys
local COLOR_HEADER  = 0xFFAA44FF   -- orange:     combo group headers
local COLOR_OK      = 0x88FF88FF   -- green:      status bar success
local COLOR_ERROR   = 0xFF6666FF   -- red:        status bar error

-- ── Priority character groups ─────────────────────────────────────────────
local priority_groups = {
  {
    label = "Game of Thrones",
    characters = {
      "Jon Snow",
      "Daenerys Targaryen",
      "Tyrion Lannister",
      "Arya Stark",
      "Sansa Stark",
      "Cersei Lannister",
      "Jaime Lannister",
      "Ned Stark",
      "Robb Stark",
      "Catelyn Stark",
      "Bran Stark",
      "Theon Greyjoy",
      "Jorah Mormont",
      "Samwell Tarly",
      "Brienne of Tarth",
      "Petyr Baelish",
      "Varys",
      "Stannis Baratheon",
      "Davos Seaworth",
      "Joffrey Baratheon",
      "Sandor Clegane",
      "Tywin Lannister",
      "Margaery Tyrell",
      "Oberyn Martell",
      "Melisandre",
    },
  },
  {
    label = "House of the Dragon",
    characters = {
      "Princess Rhaenyra Targaryen",
      "Lady Alicent Hightower",
      "Queen Alicent Hightower",
      "Prince Daemon Targaryen",
      "Prince Aegon II Targaryen",
      "King Viserys I Targaryen",
      "Ser Otto Hightower",
      "Prince Jacaerys Velaryon",
      "Prince Aemond Targaryen",
      "Corlys Velaryon",
      "Lord Corlys Velaryon",
      "Princess Rhaenys Targaryen",
    },
  },
  {
    label = "A Knight of the Seven Kingdoms",
    characters = {
      "Egg",
      "Ser Duncan the Tall",
      "Dunk",
    },
  },
}

-- ── CSV helpers ───────────────────────────────────────────────────────────
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function remove_bom(s)
  if s:sub(1,3) == "\xEF\xBB\xBF" then return s:sub(4) end
  return s
end

local function parse_csv_line(line)
  local fields, i, len = {}, 1, #line
  while i <= len do
    if line:sub(i,i) == '"' then
      i = i + 1
      local buf = {}
      while i <= len do
        local c = line:sub(i,i)
        if c == '"' then
          if line:sub(i+1,i+1) == '"' then buf[#buf+1] = '"'; i = i + 2
          else i = i + 1; break end
        else buf[#buf+1] = c; i = i + 1 end
      end
      fields[#fields+1] = table.concat(buf)
      if line:sub(i,i) == ',' then i = i + 1 end
    else
      local field, ni = line:match("^([^,]*),()", i)
      if field then fields[#fields+1] = field; i = ni
      else fields[#fields+1] = line:sub(i); break end
    end
  end
  return fields
end

-- Split into logical CSV records, keeping newlines that sit inside quotes.
local function split_csv_records(raw)
  local lines, current, in_quotes = {}, "", false
  local n = #raw
  local i = 1
  while i <= n do
    local c = raw:sub(i, i)
    if c == '"' then
      in_quotes = not in_quotes
      current = current .. c
    elseif (c == "\n" or c == "\r") and not in_quotes then
      if c == "\r" and raw:sub(i + 1, i + 1) == "\n" then
        i = i + 1
      end
      if current ~= "" then lines[#lines+1] = current end
      current = ""
    else
      current = current .. c
    end
    i = i + 1
  end
  if current ~= "" then lines[#lines+1] = current end
  return lines
end

local function parse_number(s)
  s = trim(s)
  if s == "" then return nil end
  return tonumber((s:gsub(",", ".")))
end

local function read_csv_file(path)
  local f = io.open(path, "r")
  if not f then return nil, "Cannot open file", 0 end
  local raw = f:read("*all")
  f:close()
  if not raw or raw == "" then return nil, "Empty file", 0 end

  local lines = split_csv_records(raw)
  if #lines == 0 then return nil, "Empty file", 0 end

  local headers = parse_csv_line(remove_bom(lines[1]))
  for i, h in ipairs(headers) do headers[i] = trim(h) end

  local function col(fields, name)
    local name_lower = name:lower()
    for i, h in ipairs(headers) do
      if h:lower() == name_lower then return trim(fields[i] or "") end
    end
    return ""
  end

  local rows          = {}
  local unknown_count = 0

  for li = 2, #lines do
    local fields = parse_csv_line(lines[li])
    if #fields > 0 then
      -- Skip rows with no dialogue text
      local text = col(fields, "Text")
      if text ~= "" then
        local character = col(fields, "Speaker_Localized")
        if character == "" then character = col(fields, "Character") end
        if character == "" then
          character     = "Unknown"
          unknown_count = unknown_count + 1
        end
        rows[#rows+1] = {
          character      = character,
          text           = text,
          source_file    = col(fields, "Source_File"),
          start_sec      = parse_number(col(fields, "Start_Sec")),
          end_sec        = parse_number(col(fields, "End_Sec")),
          start_time     = col(fields, "Start_Time"),
          end_time       = col(fields, "End_Time"),
          season         = col(fields, "Season"),
          rating         = parse_number(col(fields, "Top_Sentence_Rating")) or 0,
          rating_reason  = col(fields, "Top_Sentence_Reason"),
          use_for_unlock = col(fields, "Use_For_Unlock"),
          confidence     = col(fields, "Speaker_Probability"),
          notes          = col(fields, "Speaker_Notes"),
          csv_file       = "",
          _audio_cached  = false,
          _audio_path    = nil,
          _label         = "",
        }
      end
    end
  end
  return rows, nil, unknown_count
end

-- ── Load all CSVs ─────────────────────────────────────────────────────────
local function load_csvs()
  all_rows, character_list, character_set, filtered_rows = {}, {}, {}, {}
  -- combo_sel_char is reset here only, not in build_combo_entries,
  -- to avoid a fragile call-order dependency.
  selected_line  = -1
  combo_entries  = {}
  combo_sel_char = ""

  if csv_folder == "" then
    status_msg = "No CSV folder selected."; status_ok = false; return
  end

  status_msg = "Loading CSVs..."; status_ok = true

  local loaded, failed, total_unknown = 0, {}, 0
  local fi = 0

  while true do
    local fname = r.EnumerateFiles(csv_folder, fi)
    if not fname then break end
    fi = fi + 1
    if fname:lower():match("%.csv$") and not fname:match("^[._~]") then
      local rows, err, unknown_count = read_csv_file(csv_folder .. "/" .. fname)
      if rows then
        for _, row in ipairs(rows) do
          row.csv_file = fname
          all_rows[#all_rows+1] = row
          character_set[row.character] = true
        end
        loaded        = loaded + 1
        total_unknown = total_unknown + (unknown_count or 0)
      else
        failed[#failed+1] = fname .. ": " .. (err or "unknown error")
      end
    end
  end

  if loaded == 0 then
    status_msg = "No valid CSV files found."; status_ok = false; return
  end

  for c in pairs(character_set) do character_list[#character_list+1] = c end
  table.sort(character_list)

  search_buf = ""
  status_msg = string.format("Loaded %d CSV file(s), %d lines.", loaded, #all_rows)
  if total_unknown > 0 then
    status_msg = status_msg .. string.format("  (%d rows with unknown character.)", total_unknown)
  end
  if #failed > 0 then
    status_msg = status_msg .. "  Failed: " .. table.concat(failed, ", ")
    status_ok  = false
  else
    status_ok = true
  end
end

-- ── Filter + sort ─────────────────────────────────────────────────────────
local function refresh_filter()
  local sel_char = combo_sel_char ~= "" and combo_sel_char or nil
  local search   = search_buf:lower()
  filtered_rows  = {}

  for _, row in ipairs(all_rows) do
    if sel_char and row.character ~= sel_char then goto continue end
    if search ~= "" and not row.text:lower():find(search, 1, true) then goto continue end
    filtered_rows[#filtered_rows+1] = row
    ::continue::
  end

  table.sort(filtered_rows, function(a, b)
    if a.rating ~= b.rating then return a.rating > b.rating end
    return #a.text < #b.text
  end)

  -- Pre-compute list labels so the render loop does no allocations per frame
  for i, row in ipairs(filtered_rows) do
    local pt = row.text
    if #pt > 110 then pt = pt:sub(1, 110) .. "..." end
    row._label = string.format("[%d] %04d | %s", row.rating, i, pt)
  end

  selected_line = #filtered_rows > 0 and 0 or -1
end

-- ── Audio matching ────────────────────────────────────────────────────────
-- NOTE: _walk uses module-level mutable state and is intentionally
-- non-reentrant. Do not call get_audio_path from within a _walk callback.

local function normalize_source_name(fname)
  local name = fname:lower()
  name = name:match("([^/\\]+)$") or name
  name = name:match("^(.+)%.[^%.]+$") or name
  name = name:gsub("_transcript", ""):gsub("%.l_transcript", ".l")
              :gsub("%.r_transcript", ".r"):gsub(" transcript", "")
  return name:match("^%s*(.-)%s*$")
end

local _walk_src_base = ""
local _walk_exact    = nil
local _walk_partial  = nil

local function _walk(dir)
  local fi = 0
  while true do
    local fname = r.EnumerateFiles(dir, fi)
    if not fname then break end
    fi = fi + 1
    if not fname:match("^[._~]") then
      local ab   = normalize_source_name(fname)
      local full = dir .. "/" .. fname
      if ab == _walk_src_base then
        _walk_exact = full; return
      elseif not _walk_partial and
        (_walk_src_base:find(ab, 1, true) or ab:find(_walk_src_base, 1, true)) then
        _walk_partial = full
      end
    end
  end
  if _walk_exact then return end
  local di = 0
  while true do
    local sub = r.EnumerateSubdirectories(dir, di)
    if not sub then break end
    di = di + 1
    _walk(dir .. "/" .. sub)
    if _walk_exact then return end
  end
end

-- Returns the resolved audio path; result is cached on the row object.
local function get_audio_path(row)
  if row._audio_cached then return row._audio_path end
  row._audio_cached = true
  if audio_folder == "" or row.source_file == "" then
    row._audio_path = nil; return nil
  end
  _walk_src_base = normalize_source_name(row.source_file)
  _walk_exact    = nil
  _walk_partial  = nil
  _walk(audio_folder)
  row._audio_path = _walk_exact or _walk_partial
  return row._audio_path
end

-- Invalidates all cached audio paths (called when audio_folder changes)
local function invalidate_audio_cache()
  for _, row in ipairs(all_rows) do
    row._audio_cached = false
    row._audio_path   = nil
  end
end

-- ── Detail field renderer (module scope — not redefined per frame) ─────────
local function draw_detail(k, val)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), COLOR_LABEL)
  r.ImGui_Text(ctx, k)
  r.ImGui_PopStyleColor(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_TextWrapped(ctx, tostring(val or ""))
end

-- ── VO naming: Vo_{Initials}-{PascalCaseLine}{GameID} ──────────────────────
-- Example: Vo_TL-CerseiThinksTheArmyOfDeadIsAStoryGOTS164
local INITIAL_SKIP = {
  ser=true, lady=true, queen=true, king=true, prince=true, princess=true,
  lord=true, of=true, the=true, a=true, an=true,
  i=true, ii=true, iii=true, iv=true, v=true, vi=true, vii=true, viii=true,
  ix=true, x=true,
}

local function character_initials(name)
  local initials = {}
  for word in (name or ""):gmatch("%S+") do
    local clean = word:gsub("[^%a]", "")
    if clean ~= "" and not INITIAL_SKIP[clean:lower()] then
      initials[#initials+1] = clean:sub(1, 1):upper()
    end
  end
  if #initials == 0 then
    local letters = (name or ""):gsub("[^%a]", "")
    if #letters >= 2 then
      return letters:sub(1, 2):upper()
    elseif #letters == 1 then
      return letters:upper()
    end
    return "XX"
  end
  return table.concat(initials)
end

local function line_to_pascal(text)
  local parts = {}
  for word in (text or ""):gmatch("[%a%d]+") do
    parts[#parts+1] = word:sub(1, 1):upper() .. word:sub(2):lower()
  end
  local s = table.concat(parts)
  if #s > 80 then s = s:sub(1, 80) end
  return s
end

local function sanitize_game_id(id)
  return (id or ""):gsub("%s+", ""):gsub("[^%w%-_]", "")
end

local function sanitize_initials(s)
  return (s or ""):gsub("[^%a%d]", ""):upper()
end

local function build_vo_name(row, game_id, initials_override)
  local initials = sanitize_initials(initials_override)
  if initials == "" then
    initials = character_initials(row.character)
  end
  local line = line_to_pascal(row.text)
  if line == "" then line = "Line" end
  local gid = sanitize_game_id(game_id)
  return "Vo_" .. initials .. "-" .. line .. gid
end

-- ── Clip import + region ──────────────────────────────────────────────────
local function extract_clip(row)
  if not row.start_sec or not row.end_sec then
    return false, "Start_Sec or End_Sec missing."
  end
  if row.end_sec <= row.start_sec then
    return false, "End_Sec must be greater than Start_Sec."
  end

  local audio_path = get_audio_path(row)
  if not audio_path then
    return false, "No matching audio file found for: " .. row.source_file
  end

  local clip_name = build_vo_name(row, game_id_buf, initials_buf)

  r.Undo_BeginBlock()

  -- ── Create new track ──────────────────────────────────────────────
  local num_tracks = r.CountTracks(0)
  r.InsertTrackAtIndex(num_tracks, false)
  local track = r.GetTrack(0, num_tracks)
  r.GetSetMediaTrackInfo_String(track, "P_NAME", clip_name, true)

  -- ── Load and validate source ──────────────────────────────────────
  local src = r.PCM_Source_CreateFromFile(audio_path)
  if not src then
    r.DeleteTrack(track)
    r.Undo_EndBlock("GOT VO import (failed)", -1)
    return false, "Could not load audio source: " .. audio_path
  end

  local src_len, is_qn = r.GetMediaSourceLength(src)
  if is_qn or not src_len or src_len <= 0 then
    r.PCM_Source_Destroy(src)
    r.DeleteTrack(track)
    r.Undo_EndBlock("GOT VO import (failed)", -1)
    return false, "Could not determine valid source length for: " .. audio_path
  end

  -- ── Pre / post roll (clamped to source boundaries) ────────────────
  local pre_roll  = math.max(0, tonumber(pre_roll_buf)  or 100) / 1000.0
  local post_roll = math.max(0, tonumber(post_roll_buf) or 150) / 1000.0

  local region_start = math.max(0,       row.start_sec - pre_roll)
  local region_end   = math.min(src_len, row.end_sec   + post_roll)
  local clip_len     = region_end - region_start
  if clip_len <= 0 then
    r.PCM_Source_Destroy(src)
    r.DeleteTrack(track)
    r.Undo_EndBlock("GOT VO import (failed)", -1)
    return false, string.format(
      "Clip window is outside the audio file (source is %.3fs, Start_Sec=%.3f, End_Sec=%.3f).",
      src_len, row.start_sec, row.end_sec)
  end
  local place_at = r.GetCursorPosition()

  -- ── Create media item ─────────────────────────────────────────────
  local item = r.AddMediaItemToTrack(track)
  if not item then
    r.PCM_Source_Destroy(src)
    r.DeleteTrack(track)
    r.Undo_EndBlock("GOT VO import (failed)", -1)
    return false, "Failed to create media item on track."
  end

  local take = r.AddTakeToMediaItem(item)
  if not take then
    r.PCM_Source_Destroy(src)
    r.DeleteTrack(track)
    r.Undo_EndBlock("GOT VO import (failed)", -1)
    return false, "Failed to create take on media item."
  end

  -- Once SetMediaItemTake_Source is called REAPER owns the source;
  -- do NOT call PCM_Source_Destroy after this point.
  r.SetMediaItemTake_Source(take, src)

  -- Place item at the edit cursor
  r.SetMediaItemPosition(item, place_at, false)
  r.SetMediaItemLength(item, clip_len, false)

  -- D_STARTOFFS tells REAPER where in the source file the item begins
  r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", region_start)
  r.GetSetMediaItemTakeInfo_String(take, "P_NAME", clip_name, true)

  r.UpdateArrange()

  -- ── Random region colour ──────────────────────────────────────────
  local red   = math.random(80, 255)
  local green = math.random(80, 255)
  local blue  = math.random(80, 255)
  local region_color = r.ColorToNative(red, green, blue) | 0x1000000

  -- ── Create region aligned to placed item in project time ──────────
  r.AddProjectMarker2(0,
    true,
    place_at,
    place_at + clip_len,
    clip_name,
    -1,
    region_color)

  -- Leave the edit cursor at the end of the new clip so the next import follows
  r.SetEditCurPos(place_at + clip_len, true, false)

  r.Undo_EndBlock("GOT VO: import + region", -1)

  return true, string.format(
    "'%s' | placed at %.3fs → %.3fs",
    clip_name, place_at, place_at + clip_len)
end

-- ── Folder picker ─────────────────────────────────────────────────────────
local function pick_folder(title, current)
  if r.JS_Dialog_BrowseForFolder then
    local ok, path = r.JS_Dialog_BrowseForFolder(title, current or "")
    if ok == 1 then return path end
    return nil
  end
  local ok, path = r.GetUserInputs(title, 1, "Folder path:,extrawidth=400", current or "")
  if ok then return trim(path) end
  return nil
end

-- ── Build combo entries ───────────────────────────────────────────────────
-- combo_sel_char is NOT reset here — reset happens in load_csvs only,
-- avoiding a fragile call-order dependency.
local function build_combo_entries()
  local entries = {}
  entries[#entries+1] = {type="char", name="-- All Characters --", value="", id="all0"}

  local any_priority = false
  for _, g in ipairs(priority_groups) do
    local present = {}
    for _, c in ipairs(g.characters) do
      if character_set[c] then present[#present+1] = c end
    end
    if #present > 0 then
      if not any_priority then
        entries[#entries+1] = {type="header", label="★  Main Characters"}
        any_priority = true
      end
      entries[#entries+1] = {type="header", label=g.label}
      for _, c in ipairs(present) do
        entries[#entries+1] = {type="char", name=c, value=c, id="prio"..tostring(#entries)}
      end
    end
  end

  if any_priority then
    entries[#entries+1] = {type="header", label="All Characters"}
  end
  for _, c in ipairs(character_list) do
    entries[#entries+1] = {type="char", name=c, value=c, id="all"..tostring(#entries)}
  end

  combo_entries = entries
end

-- ── Import helper (shared by button click and Enter key) ──────────────────
local function do_import()
  if selected_line >= 0 and selected_line < #filtered_rows then
    local row        = filtered_rows[selected_line + 1]
    local ok, result = extract_clip(row)
    if ok then
      status_msg = result; status_ok = true
    else
      status_msg = "Error: " .. result; status_ok = false
    end
  else
    status_msg = "No line selected."; status_ok = false
  end
end

-- ── GUI ───────────────────────────────────────────────────────────────────
local WINDOW_W     = 1380
local WINDOW_H     = 760
local LIST_W       = 820
local COL_DETAIL_W = 500

local function draw_folder_row(label, folder_var, ext_key, title)
  local display = folder_var ~= "" and folder_var or "(not selected)"
  r.ImGui_Text(ctx, label)
  r.ImGui_SameLine(ctx)
  r.ImGui_PushItemWidth(ctx, 580)
  r.ImGui_Text(ctx, display)
  r.ImGui_PopItemWidth(ctx)
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Browse##" .. ext_key) then
    local picked = pick_folder(title, folder_var ~= "" and folder_var or nil)
    if picked then
      r.SetExtState("GOTVOTool", ext_key, picked, true)
      return picked
    end
  end
  return nil
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, WINDOW_W, WINDOW_H, r.ImGui_Cond_Once())
  local visible, open = r.ImGui_Begin(ctx, "GOT VO Tool", true)

  if visible then

    -- ── Folder pickers ────────────────────────────────────────────────
    local new_csv = draw_folder_row("CSV Folder:  ", csv_folder, "csv_folder", "Select CSV Folder")
    if new_csv then
      csv_folder = new_csv
      load_csvs()
      build_combo_entries()
      refresh_filter()
    end

    local new_audio = draw_folder_row("Audio Folder:", audio_folder, "audio_folder", "Select Audio Folder")
    if new_audio then
      audio_folder = new_audio
      -- Invalidate all cached audio paths so they are re-resolved
      -- against the new folder on next access
      invalidate_audio_cache()
    end

    r.ImGui_Text(ctx, "Game ID:")
    r.ImGui_SameLine(ctx)
    r.ImGui_PushItemWidth(ctx, 140)
    local game_changed, new_game_id = r.ImGui_InputText(ctx, "##game_id", game_id_buf)
    r.ImGui_PopItemWidth(ctx)
    if game_changed then
      game_id_buf = new_game_id
      r.SetExtState("GOTVOTool", "game_id", game_id_buf, true)
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, "  (suffix, e.g. GOTS164)")

    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, "  Initials:")
    r.ImGui_SameLine(ctx)
    r.ImGui_PushItemWidth(ctx, 80)
    local init_changed, new_initials = r.ImGui_InputText(ctx, "##char_initials", initials_buf)
    r.ImGui_PopItemWidth(ctx)
    if init_changed then
      initials_buf = new_initials
      r.SetExtState("GOTVOTool", "char_initials", initials_buf, true)
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, "  (e.g. TL — overrides CSV speaker)")

    r.ImGui_Separator(ctx)

    -- ── Filter bar ────────────────────────────────────────────────────
    r.ImGui_Text(ctx, "Character:")
    r.ImGui_SameLine(ctx)
    r.ImGui_PushItemWidth(ctx, 300)

    local preview        = combo_sel_char ~= "" and combo_sel_char or "-- All Characters --"
    local filter_changed = false

    if r.ImGui_BeginCombo(ctx, "##char_combo", preview) then
      for _, entry in ipairs(combo_entries) do
        if entry.type == "header" then
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), COLOR_HEADER)
          r.ImGui_Text(ctx, "  " .. entry.label)
          r.ImGui_PopStyleColor(ctx)
        else
          local is_sel     = (entry.value == combo_sel_char)
          local label      = "  " .. entry.name .. "##" .. (entry.id or entry.value)
          local clicked, _ = r.ImGui_Selectable(ctx, label, is_sel)
          if clicked then
            combo_sel_char = entry.value; filter_changed = true
          end
          if is_sel then r.ImGui_SetItemDefaultFocus(ctx) end
        end
      end
      r.ImGui_EndCombo(ctx)
    end
    r.ImGui_PopItemWidth(ctx)

    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, "  Search:")
    r.ImGui_SameLine(ctx)
    r.ImGui_PushItemWidth(ctx, 300)
    local search_changed, new_search = r.ImGui_InputText(ctx, "##search", search_buf)
    r.ImGui_PopItemWidth(ctx)
    if search_changed then search_buf = new_search; filter_changed = true end

    if filter_changed then refresh_filter() end

    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, string.format("  %d lines", #filtered_rows))

    r.ImGui_Separator(ctx)

    -- ── Pre / post roll ───────────────────────────────────────────────
    local resolved_pre  = math.max(0, tonumber(pre_roll_buf)  or 100)
    local resolved_post = math.max(0, tonumber(post_roll_buf) or 150)

    r.ImGui_Text(ctx, "Pre-roll ms:")
    r.ImGui_SameLine(ctx)
    r.ImGui_PushItemWidth(ctx, 60)
    local _, v = r.ImGui_InputText(ctx, "##pre", pre_roll_buf)
    pre_roll_buf = v
    r.ImGui_PopItemWidth(ctx)
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, string.format("(%.0fms)", resolved_pre))

    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, "  Post-roll ms:")
    r.ImGui_SameLine(ctx)
    r.ImGui_PushItemWidth(ctx, 60)
    _, v = r.ImGui_InputText(ctx, "##post", post_roll_buf)
    post_roll_buf = v
    r.ImGui_PopItemWidth(ctx)
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, string.format("(%.0fms)", resolved_post))

    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, string.format("  Edit cursor: %.3fs", r.GetCursorPosition()))

    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Cursor to 0") then
      r.SetEditCurPos(0.0, true, false)
      status_msg = "Edit cursor moved to 0."; status_ok = true
    end

    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, "Import Selected Clip") then
      do_import()
    end

    r.ImGui_Separator(ctx)

    -- ── Main split: list + details ────────────────────────────────────
    local avail_w, avail_h = r.ImGui_GetContentRegionAvail(ctx)
    if not avail_h then avail_h = avail_w end
    local line_h  = r.ImGui_GetTextLineHeightWithSpacing(ctx)
    local list_h  = math.max(80, (avail_h or 0) - line_h - 8)

    -- List pane (ReaImGui: EndChild only if BeginChild returned true)
    local list_open = r.ImGui_BeginChild(ctx, "##list_pane", LIST_W, list_h, 1)
    if list_open then
      for i, row in ipairs(filtered_rows) do
        local idx        = i - 1
        local is_sel     = (idx == selected_line)
        local clicked, _ = r.ImGui_Selectable(ctx, row._label, is_sel, 0, LIST_W-16, 0)
        if clicked then selected_line = idx end
      end
      r.ImGui_EndChild(ctx)
    end

    -- Enter key triggers import when list pane has focus
    if list_open and r.ImGui_IsItemFocused(ctx) and
       r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter()) then
      do_import()
    end

    r.ImGui_SameLine(ctx)

    -- Detail pane
    if r.ImGui_BeginChild(ctx, "##detail_pane", COL_DETAIL_W, list_h, 1) then
      if selected_line >= 0 and selected_line < #filtered_rows then
        local row        = filtered_rows[selected_line + 1]
        local audio_path = get_audio_path(row)   -- cached; no filesystem hit after first call

        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), COLOR_HEADING)
        r.ImGui_TextWrapped(ctx, "Line Details")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_Separator(ctx)

        draw_detail("Character:     ", row.character)
        draw_detail("Rating:        ", row.rating)
        draw_detail("Reason:        ", row.rating_reason)
        draw_detail("Use for Unlock:", row.use_for_unlock)
        draw_detail("Confidence:    ", row.confidence)
        draw_detail("Season:        ", row.season)
        draw_detail("CSV File:      ", row.csv_file)
        draw_detail("Source File:   ", row.source_file)
        draw_detail("Start Time:    ", row.start_time)
        draw_detail("End Time:      ", row.end_time)
        draw_detail("Start Sec:     ", row.start_sec)
        draw_detail("End Sec:       ", row.end_sec)
        r.ImGui_Separator(ctx)

        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), COLOR_LABEL)
        r.ImGui_Text(ctx, "Text:")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_TextWrapped(ctx, row.text)
        r.ImGui_Separator(ctx)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), COLOR_LABEL)
        r.ImGui_Text(ctx, "Notes:")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_TextWrapped(ctx, row.notes)
        r.ImGui_Separator(ctx)

        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), COLOR_LABEL)
        r.ImGui_Text(ctx, "Audio:")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_TextWrapped(ctx, audio_path or "Not found")
        r.ImGui_Separator(ctx)
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), COLOR_LABEL)
        r.ImGui_Text(ctx, "Import name:")
        r.ImGui_PopStyleColor(ctx)
        r.ImGui_TextWrapped(ctx, build_vo_name(row, game_id_buf, initials_buf))

      else
        r.ImGui_TextWrapped(ctx, "Select a line to see details.")
      end
      r.ImGui_EndChild(ctx)
    end

    -- ── Status bar ────────────────────────────────────────────────────
    r.ImGui_Separator(ctx)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), status_ok and COLOR_OK or COLOR_ERROR)
    r.ImGui_TextWrapped(ctx, status_msg)
    r.ImGui_PopStyleColor(ctx)

    r.ImGui_End(ctx)
  end -- closes: if visible then

  return open
end

-- ── Entry point ───────────────────────────────────────────────────────────
local function init()
  if not r.ImGui_CreateContext then
    r.ShowMessageBox(
      "ReaImGui is required.\nInstall it via ReaPack: Extensions > ReaPack > Browse packages.",
      "GOT VO Tool", 0)
    return false
  end
  ctx = r.ImGui_CreateContext("GOT VO Tool")
  if csv_folder ~= "" then
    load_csvs(); build_combo_entries(); refresh_filter()
  end
  return true
end

local function shutdown()
  if ctx and r.ImGui_DestroyContext then
    r.ImGui_DestroyContext(ctx)
    ctx = nil
  end
end

local function main()
  if not init() then return end
  local function defer_loop()
    local ok, err = pcall(loop)
    if not ok then
      r.ShowMessageBox("Script error:\n" .. tostring(err), "GOT VO Tool", 0)
      shutdown()
      return
    end
    if err then
      r.defer(defer_loop)
    else
      shutdown()
    end
  end
  r.defer(defer_loop)
end

main()


