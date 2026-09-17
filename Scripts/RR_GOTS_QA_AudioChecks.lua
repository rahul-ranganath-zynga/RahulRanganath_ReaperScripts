-- ============================================================
--  RR_GOTS_QA_AudioChecks.lua
--  Role    : Technical Audio Designer – Vendor Asset QA
--  Reaper  : 6.x / 7.x  (ReaScript Lua)
--  GUI     : ReaImGui (Dear ImGui wrapper — install via ReaPack)
--  Output  : HTML report (browser) + CSV
-- ============================================================
--  REQUIRES: ReaImGui extension
--  Install : ReaPack → Extensions → ReaImGui
-- ============================================================
--  LUFS-I NOTE:
--  Integrated loudness is calculated per ITU-R BS.1770-4:
--    1) K-weighting (pre-filter high-shelf + RLB high-pass biquads)
--    2) 400ms blocks, 75% overlap (100ms step)
--    3) Absolute gate at -70 LUFS, relative gate at (ungated avg - 10 LU)
--  Channel weighting assumes L/R/mono only (weight = 1.0); surround
--  channel weighting (+1.41 for Ls/Rs) is not implemented since game
--  SFX/dialogue/music assets are virtually always mono or stereo.
-- ============================================================

-- ============================================================
--  CHECK ReaImGui is available
-- ============================================================
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "This script requires the ReaImGui extension.\n\n" ..
    "Install it via ReaPack:\n" ..
    "Extensions > ReaPack > Browse packages > search 'ReaImGui'",
    "Missing Dependency", 0)
  return
end

-- ============================================================
--  DEFAULT SPEC
-- ============================================================
local SR_OPTIONS        = { 44100, 48000, 96000, 192000 }
local BIT_DEPTH_OPTIONS = { 16, 24, 32 }

local SPEC = {
  clipping_dbtp        =  0.0,
  blank_rms_threshold  = -80.0,
  tail_db              = -40.0,
  tail_duration_sec    =  1.5,
  pre_roll_max_sec     =  0.1,
  dc_offset_db_thresh  = -40.0,
  balance_db_thresh    =  3.0,
  required_channels    =  2,
  check_stereo         = false,
  required_sample_rate = 48000,
  required_bit_depth   = 24,
  lufs_integrated_max  = -9.0,
  naming_allow_upper   = true,
}

-- ============================================================
--  SPEC VALIDATION
-- ============================================================
local function validate_spec(s)
  assert(type(s.clipping_dbtp)       == "number", "True Peak ceiling must be a number")
  assert(type(s.blank_rms_threshold) == "number", "Blank RMS threshold must be a number")
  assert(s.tail_duration_sec         >  0,        "Max tail duration must be > 0")
  assert(s.pre_roll_max_sec          >= 0,        "Max pre-roll must be >= 0")
  assert(s.balance_db_thresh         >  0,        "Balance limit must be > 0")
  assert(type(s.lufs_integrated_max) == "number", "LUFS-I ceiling must be a number")

  local sr_ok = false
  for _, v in ipairs(SR_OPTIONS) do if v == s.required_sample_rate then sr_ok = true end end
  assert(sr_ok, "Sample rate must be one of 44100 / 48000 / 96000 / 192000")

  local bd_ok = false
  for _, v in ipairs(BIT_DEPTH_OPTIONS) do if v == s.required_bit_depth then bd_ok = true end end
  assert(bd_ok, "Bit depth must be one of 16 / 24 / 32")
end

-- ============================================================
--  UTILITIES
-- ============================================================
local function db(linear)
  if linear <= 0 then return -math.huge end
  return 20 * math.log(linear, 10)
end

local function round2(n)
  return math.floor(n * 100 + 0.5) / 100
end

-- Power-domain (loudness) conversion: L = -0.691 + 10*log10(mean_square)
local function loudness_db(mean_square)
  if mean_square <= 0 then return -math.huge end
  return -0.691 + 10 * math.log(mean_square, 10)
end

-- ============================================================
--  WAV HEADER PARSER  (bit depth detection)
--  Reaper's ReaScript API has no native "get bit depth" call, so we
--  read the fmt chunk directly. Handles PCM, IEEE float, and
--  WAVE_FORMAT_EXTENSIBLE (uses validBitsPerSample when present).
-- ============================================================
local function read_u16_le(s, pos)
  local b1, b2 = s:byte(pos, pos + 1)
  if not b1 or not b2 then return nil end
  return b1 + b2 * 256
end

local function read_u32_le(s, pos)
  local b1, b2, b3, b4 = s:byte(pos, pos + 3)
  if not b1 or not b2 or not b3 or not b4 then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function get_wav_format_info(filepath)
  local f = io.open(filepath, "rb")
  if not f then return nil end

  local header = f:read(12)
  if not header or #header < 12 or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
    f:close()
    return nil
  end

  local bit_depth, audio_format, valid_bits = nil, nil, nil

  while true do
    local chunk_header = f:read(8)
    if not chunk_header or #chunk_header < 8 then break end
    local chunk_id   = chunk_header:sub(1, 4)
    local chunk_size = read_u32_le(chunk_header, 5)
    if not chunk_size then break end

    if chunk_id == "fmt " then
      local fmt_data = f:read(chunk_size)
      if fmt_data and #fmt_data >= 16 then
        audio_format = read_u16_le(fmt_data, 1)
        bit_depth    = read_u16_le(fmt_data, 15)
        if audio_format == 0xFFFE and #fmt_data >= 20 then
          valid_bits = read_u16_le(fmt_data, 19)
        end
      end
      break
    else
      local skip = chunk_size + (chunk_size % 2)
      local ok = f:seek("cur", skip)
      if not ok then break end
    end
  end

  f:close()
  if not bit_depth then return nil end

  local effective_bits = (valid_bits and valid_bits > 0) and valid_bits or bit_depth
  return {
    bit_depth  = effective_bits,
    is_float   = (audio_format == 3),
    audio_fmt  = audio_format,
  }
end

-- ============================================================
--  FILENAME CONVENTION CHECK
-- ============================================================
local function bad_filename(name)
  local stem = name:match("(.+)%.[^%.]+$") or name
  if stem:find(" ")          then return true, "spaces"        end
  if stem:find("[^%w%._%-]") then return true, "special chars" end
  if not SPEC.naming_allow_upper and stem ~= stem:lower() then
    return true, "uppercase"
  end
  return false, nil
end

-- ============================================================
--  ITU-R BS.1770-4 K-WEIGHTING FILTER COEFFICIENTS
--  Coefficients derived per-sample-rate via bilinear transform of
--  the standard analog prototypes (same formulas used by libebur128
--  / pyloudnorm reference implementations).
-- ============================================================
local function compute_k_weighting_coeffs(fs)
  -- Stage 1: high-shelf pre-filter
  local f0_1, G1, Q1 = 1681.9744509555319, 3.99984385397, 0.7071752369554193
  local K1  = math.tan(math.pi * f0_1 / fs)
  local Vh1 = 10 ^ (G1 / 20)
  local Vb1 = K1 ^ 0.4996667741545416
  local a0_1 = 1 + K1 / Q1 + K1 * K1
  local stage1 = {
    b0 = (Vh1 + Vb1 * K1 / Q1 + K1 * K1) / a0_1,
    b1 = 2 * (K1 * K1 - Vh1) / a0_1,
    b2 = (Vh1 - Vb1 * K1 / Q1 + K1 * K1) / a0_1,
    a1 = 2 * (K1 * K1 - 1) / a0_1,
    a2 = (1 - K1 / Q1 + K1 * K1) / a0_1,
  }

  -- Stage 2: RLB high-pass filter
  local f0_2, Q2 = 38.13547087602444, 0.5003270373238773
  local K2 = math.tan(math.pi * f0_2 / fs)
  local a0_2 = 1 + K2 / Q2 + K2 * K2
  local stage2 = {
    b0 = 1 / a0_2,
    b1 = -2 / a0_2,
    b2 = 1 / a0_2,
    a1 = 2 * (K2 * K2 - 1) / a0_2,
    a2 = (1 - K2 / Q2 + K2 * K2) / a0_2,
  }

  return stage1, stage2
end

-- Direct Form I biquad. `state` holds {x1,x2,y1,y2} and is mutated in place.
local function biquad_process(state, coef, x)
  local y = coef.b0 * x + coef.b1 * state.x1 + coef.b2 * state.x2
          - coef.a1 * state.y1 - coef.a2 * state.y2
  state.x2, state.x1 = state.x1, x
  state.y2, state.y1 = state.y1, y
  return y
end

-- Two-stage ITU-R BS.1770-4 gating: absolute gate at -70 LUFS, then
-- relative gate at (ungated average - 10 LU). Input is a list of
-- per-block weighted mean-square (linear power) values.
local function compute_lufs_integrated(block_ms_list)
  if #block_ms_list == 0 then return -math.huge end

  local abs_gated = {}
  for _, ms in ipairs(block_ms_list) do
    if loudness_db(ms) >= -70.0 then table.insert(abs_gated, ms) end
  end
  if #abs_gated == 0 then return -math.huge end

  local sum = 0
  for _, ms in ipairs(abs_gated) do sum = sum + ms end
  local avg_abs = sum / #abs_gated
  local relative_threshold = loudness_db(avg_abs) - 10.0

  local rel_gated = {}
  for _, ms in ipairs(abs_gated) do
    if loudness_db(ms) >= relative_threshold then table.insert(rel_gated, ms) end
  end
  if #rel_gated == 0 then return loudness_db(avg_abs) end

  local sum2 = 0
  for _, ms in ipairs(rel_gated) do sum2 = sum2 + ms end
  return loudness_db(sum2 / #rel_gated)
end

-- ============================================================
--  ANALYSE A SINGLE ACCESSOR
--  Computes peak/RMS/DC/tail/pre-roll/balance (existing checks)
--  PLUS full ITU-R BS.1770-4 LUFS-Integrated via K-weighting +
--  400ms gated blocks (75% overlap) + two-stage gating.
-- ============================================================
local function analyse_accessor(accessor, channels, sample_rate, num_samples)
  local total       = num_samples * channels
  local BLOCK       = 4096
  local buf         = reaper.new_array(BLOCK * channels)
  local block_count = math.ceil(num_samples / BLOCK)

  local sum_sq_acc = 0
  local sum_acc    = 0
  local peak_acc   = 0
  local clip_count = 0

  local ch_peak = {}
  for c = 1, channels do ch_peak[c] = 0 end

  local quiet_run             = 0
  local tail_sample_start     = nil
  local tail_threshold_linear = 10 ^ (SPEC.tail_db / 20)
  local tail_min_samples      = math.floor(SPEC.tail_duration_sec * sample_rate)

  local pre_roll_frames    = 0
  local pre_roll_done      = false
  local pre_roll_threshold = tail_threshold_linear

  -- ---- LUFS-I (ITU-R BS.1770-4) state -----------------------
  local stage1, stage2 = compute_k_weighting_coeffs(sample_rate)
  local filt_state = {}
  for c = 1, channels do
    filt_state[c] = {
      s1 = { x1=0, x2=0, y1=0, y2=0 },
      s2 = { x1=0, x2=0, y1=0, y2=0 },
    }
  end

  local segment_len = math.max(1, math.floor(0.1 * sample_rate))  -- 100ms hop
  local segment_count = 0
  local segment_sumsq = {}
  for c = 1, channels do segment_sumsq[c] = 0 end

  local segment_ring = {}   -- holds up to 4 most recent {ch_sums, n} entries
  local block_ms_list = {}

  local function flush_segment()
    table.insert(segment_ring, { sums = segment_sumsq, n = segment_count })
    if #segment_ring > 4 then table.remove(segment_ring, 1) end
    if #segment_ring == 4 then
      local total_n = 0
      local total_weighted = 0
      for _, seg in ipairs(segment_ring) do
        total_n = total_n + seg.n * channels
        for c = 1, channels do total_weighted = total_weighted + seg.sums[c] end
      end
      if total_n > 0 then
        table.insert(block_ms_list, total_weighted / total_n)
      end
    end
    segment_sumsq = {}
    for c = 1, channels do segment_sumsq[c] = 0 end
    segment_count = 0
  end

  local pos = 0

  for _ = 0, block_count - 1 do
    local frames = math.min(BLOCK, num_samples - pos)
    if frames <= 0 then break end
    local start_sec = pos / sample_rate
    reaper.GetAudioAccessorSamples(accessor, sample_rate, channels, start_sec, frames, buf)

    for i = 1, frames * channels do
      local v  = buf[i]
      local av = math.abs(v)
      sum_sq_acc = sum_sq_acc + av * av
      sum_acc    = sum_acc    + v
      if av > peak_acc then peak_acc = av end
      if av >= 1.0     then clip_count = clip_count + 1 end
      local ch = ((i - 1) % channels) + 1
      if av > ch_peak[ch] then ch_peak[ch] = av end
    end

    -- K-weighting + 100ms segment accumulation (per frame, per channel)
    for f = 0, frames - 1 do
      for c = 1, channels do
        local x = buf[f * channels + c]
        local st = filt_state[c]
        local y1 = biquad_process(st.s1, stage1, x)
        local y2 = biquad_process(st.s2, stage2, y1)
        segment_sumsq[c] = segment_sumsq[c] + y2 * y2
      end
      segment_count = segment_count + 1
      if segment_count >= segment_len then flush_segment() end
    end

    for f = 0, frames - 1 do
      local frame_peak = 0
      for c = 0, channels - 1 do
        local v = math.abs(buf[f * channels + c + 1])
        if v > frame_peak then frame_peak = v end
      end
      if not pre_roll_done then
        if frame_peak < pre_roll_threshold then
          pre_roll_frames = pre_roll_frames + 1
        else
          pre_roll_done = true
        end
      end
      if frame_peak < tail_threshold_linear then
        quiet_run = quiet_run + 1
        if quiet_run == 1 then tail_sample_start = pos + f end
      else
        quiet_run         = 0
        tail_sample_start = nil
      end
    end
    pos = pos + frames
  end

  local rms_linear = math.sqrt(sum_sq_acc / math.max(total, 1))
  local dc_offset  = sum_acc / math.max(total, 1)
  local peak_dbtp  = db(peak_acc)
  local rms_db     = db(rms_linear)
  local dc_db      = db(math.abs(dc_offset))

  local tail_sec = 0
  if tail_sample_start and quiet_run >= tail_min_samples then
    tail_sec = quiet_run / sample_rate
  end

  local pre_roll_sec = pre_roll_frames / sample_rate

  local balance_db = 0
  if channels >= 2 and ch_peak[1] > 0 and ch_peak[2] > 0 then
    balance_db = math.abs(db(ch_peak[1]) - db(ch_peak[2]))
  end

  local lufs_i = compute_lufs_integrated(block_ms_list)
  -- Files shorter than one 400ms gating block have no valid LUFS-I result
  local lufs_caution = (lufs_i == -math.huge) or (#block_ms_list == 0)

  return {
    peak_dbtp    = round2(peak_dbtp),
    rms_db       = round2(rms_db),
    lufs_i       = lufs_caution and nil or round2(lufs_i),
    lufs_caution = lufs_caution,
    clip_count   = clip_count,
    tail_sec     = round2(tail_sec),
    pre_roll_sec = round2(pre_roll_sec),
    dc_db        = round2(dc_db),
    balance_db   = round2(balance_db),
  }
end

-- ============================================================
--  GATHER MEDIA SOURCE INFO  (+ bit depth via WAV header parse)
-- ============================================================
local function get_source_info(source, filepath)
  local info       = {}
  info.channels    = reaper.GetMediaSourceNumChannels(source)
  info.sample_rate = reaper.GetMediaSourceSampleRate(source)
  info.length_sec  = reaper.GetMediaSourceLength(source)
  info.num_samples = math.floor(info.length_sec * info.sample_rate)
  info.file_type   = reaper.GetMediaSourceType(source, "")

  local wav_info = get_wav_format_info(filepath)
  if wav_info then
    info.bit_depth = wav_info.bit_depth
    info.is_float  = wav_info.is_float
  else
    info.bit_depth = nil
    info.is_float  = false
  end
  return info
end

-- ============================================================
--  BUILD FLAGS
-- ============================================================
local function build_flags(r)
  local flags = {}
  local function add(cond, cls, label)
    if cond then table.insert(flags, { cls = cls, label = label }) end
  end
  add(r.is_clipping,     "flag-clip",    "CLIP")
  add(r.is_blank,        "flag-blank",   "BLANK")
  add(r.is_mono,         "flag-mono",    "MONO")
  add(r.has_long_tail,   "flag-tail",    "LONG TAIL")
  add(r.wrong_sr,        "flag-sr",      "WRONG SR")
  add(r.wrong_bit_depth, "flag-bd",      "WRONG BIT DEPTH")
  add(r.has_dc_offset,   "flag-dc",      "DC OFFSET")
  add(r.bad_name,        "flag-name",    "BAD NAME")
  add(r.has_pre_roll,    "flag-preroll", "PRE-ROLL")
  add(r.is_imbalanced,   "flag-bal",     "IMBALANCE")
  add(r.lufs_over,       "flag-lufs",    "LUFS-I OVER")
  return flags
end

-- ============================================================
--  PROCESS ONE TAKE
-- ============================================================
local function process_take(take, item_idx)
  local source = reaper.GetMediaItemTake_Source(take)
  if not source then return nil end
  local root = reaper.GetMediaSourceParent(source)
  if root then source = root end

  local filename   = reaper.GetMediaSourceFileName(source, "")
  local short_name = filename:match("([^/\\]+)$") or filename

  if filename == "" then
    return { index=item_idx, file="(offline)", filepath="",
             error="Missing or offline source file", spec_pass=false }
  end

  local sinfo = get_source_info(source, filename)

  if sinfo.num_samples <= 0 or sinfo.length_sec <= 0 then
    return { index=item_idx, file=short_name, filepath=filename,
             error="Zero-length or corrupt source", spec_pass=false }
  end

  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then
    return { index=item_idx, file=short_name, filepath=filename,
             error="Could not create audio accessor", spec_pass=false }
  end

  local acc_start    = reaper.GetAudioAccessorStartTime(accessor)
  local acc_end      = reaper.GetAudioAccessorEndTime(accessor)
  local true_samples = math.floor((acc_end - acc_start) * sinfo.sample_rate)
  if true_samples > 0 then sinfo.num_samples = true_samples end

  local stats = analyse_accessor(accessor, sinfo.channels, sinfo.sample_rate, sinfo.num_samples)

  local destroy_fn = reaper.DestroyAudioAccessor or reaper.DestroyTakeAudioAccessor
  if destroy_fn then destroy_fn(accessor) end

  local is_clipping     = stats.peak_dbtp    >= SPEC.clipping_dbtp
  local is_blank        = stats.rms_db       <= SPEC.blank_rms_threshold
  local is_mono         = SPEC.check_stereo  and (sinfo.channels ~= SPEC.required_channels)
  local wrong_sr        = sinfo.sample_rate  ~= SPEC.required_sample_rate
  local wrong_bit_depth = (sinfo.bit_depth ~= nil) and (sinfo.bit_depth ~= SPEC.required_bit_depth)
  local has_long_tail   = stats.tail_sec     >  SPEC.tail_duration_sec
  local has_dc_offset   = stats.dc_db        >  SPEC.dc_offset_db_thresh
  local has_pre_roll    = stats.pre_roll_sec >  SPEC.pre_roll_max_sec
  local is_imbalanced   = sinfo.channels >= 2 and stats.balance_db > SPEC.balance_db_thresh
  local lufs_over       = (stats.lufs_i ~= nil) and (stats.lufs_i > SPEC.lufs_integrated_max)
  local bad_name, name_reason = bad_filename(short_name)

  local spec_pass = not is_clipping     and not is_blank      and not is_mono
                and not wrong_sr        and not wrong_bit_depth and not has_long_tail
                and not has_dc_offset   and not has_pre_roll    and not is_imbalanced
                and not bad_name        and not lufs_over

  local result = {
    index=item_idx, file=short_name, filepath=filename,
    channels=sinfo.channels, sample_rate=sinfo.sample_rate,
    bit_depth=sinfo.bit_depth, is_float=sinfo.is_float,
    length_sec=round2(sinfo.length_sec), file_type=sinfo.file_type,
    peak_dbtp=stats.peak_dbtp, rms_db=stats.rms_db,
    lufs_i=stats.lufs_i, lufs_caution=stats.lufs_caution,
    clip_count=stats.clip_count, tail_sec=stats.tail_sec,
    pre_roll_sec=stats.pre_roll_sec, dc_db=stats.dc_db,
    balance_db=stats.balance_db,
    is_clipping=is_clipping, is_blank=is_blank, is_mono=is_mono,
    wrong_sr=wrong_sr, wrong_bit_depth=wrong_bit_depth,
    has_long_tail=has_long_tail,
    has_dc_offset=has_dc_offset, has_pre_roll=has_pre_roll,
    is_imbalanced=is_imbalanced, bad_name=bad_name,
    lufs_over=lufs_over,
    name_reason=name_reason, spec_pass=spec_pass,
  }
  result.flags = build_flags(result)
  return result
end

-- ============================================================
--  COLLECT ALL TAKES
-- ============================================================
local function collect_results()
  local results    = {}
  local item_count = reaper.CountMediaItems(0)
  reaper.ShowConsoleMsg("QA Audio Check — scanning " .. item_count .. " items...\n")
  for i = 0, item_count - 1 do
    local item = reaper.GetMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local source   = reaper.GetMediaItemTake_Source(take)
      local filepath = source and reaper.GetMediaSourceFileName(source, "") or ""
      if not filepath:lower():match("%.wav$") then goto skip_item end
      local r = process_take(take, i + 1)
      if r then
        table.insert(results, r)
        local status = r.spec_pass and "\xE2\x9C\x94" or "\xE2\x9C\x98"
        reaper.ShowConsoleMsg(status .. " [" .. (i+1) .. "] " .. r.file .. "\n")
      end
      ::skip_item::
    end
    reaper.UpdateArrange()
  end
  return results
end

-- ============================================================
--  CSV WRITER
-- ============================================================
local function write_csv(results, path)
  local f = io.open(path, "w")
  if not f then return false end
  f:write("#,File,Type,Channels,SampleRate,BitDepth,Length(s),Peak(dBTP),RMS(dB),"
       .. "LUFS-I,ClipSamples,Tail(s),PreRoll(s),DC(dB),Balance(dB),"
       .. "CLIP?,BLANK?,MONO?,WRONG_SR?,WRONG_BITDEPTH?,LONG_TAIL?,DC_OFFSET?,PRE_ROLL?,IMBALANCE?,BAD_NAME?,LUFS_OVER?,SPEC_PASS\n")
  local DATA_COLUMN_COUNT = 27  -- must match header column count exactly
  for _, r in ipairs(results) do
    if r.error then
      -- Build error row programmatically to avoid comma-count mismatches:
      -- index, file, "ERROR", (blanks for remaining columns except last), error message
      local blanks = string.rep(",", DATA_COLUMN_COUNT - 4)
      f:write(string.format("%d,%s,ERROR%s,%s\n", r.index or 0, r.file, blanks, r.error))
    else
      local lufs_str = r.lufs_i and string.format("%.2f", r.lufs_i) or "N/A"
      local bd_str   = r.bit_depth and tostring(r.bit_depth) or "?"
      f:write(string.format(
        "%d,%s,%s,%d,%d,%s,%.2f,%.2f,%.2f,%s,%d,%.2f,%.2f,%.2f,%.2f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
        r.index, r.file, r.file_type, r.channels, r.sample_rate, bd_str, r.length_sec,
        r.peak_dbtp, r.rms_db, lufs_str, r.clip_count,
        r.tail_sec, r.pre_roll_sec, r.dc_db, r.balance_db,
        tostring(r.is_clipping), tostring(r.is_blank),
        tostring(r.is_mono),     tostring(r.wrong_sr),
        tostring(r.wrong_bit_depth),
        tostring(r.has_long_tail), tostring(r.has_dc_offset),
        tostring(r.has_pre_roll),  tostring(r.is_imbalanced),
        tostring(r.bad_name),      tostring(r.lufs_over),
        tostring(r.spec_pass)
      ))
    end
  end
  f:close()
  return true
end

-- ============================================================
--  HTML WRITER
-- ============================================================
local function write_html(results, path, spec, proj_name)
  local pass_count, fail_count = 0, 0
  for _, r in ipairs(results) do
    if r.spec_pass then pass_count = pass_count + 1 else fail_count = fail_count + 1 end
  end
  local f = io.open(path, "w")
  if not f then return false end

  f:write([[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>]] .. proj_name .. [[ - Audio QA Report</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',Arial,sans-serif;background:#0f1117;color:#e0e0e0;padding:24px}
  h1{font-size:1.6rem;font-weight:700;margin-bottom:4px;color:#fff}
  .subtitle{font-size:.85rem;color:#888;margin-bottom:24px}
  .summary{display:flex;gap:16px;margin-bottom:28px;flex-wrap:wrap}
  .card{background:#1a1d27;border-radius:10px;padding:16px 24px;min-width:140px;text-align:center;border:1px solid #2a2d3a}
  .card .num{font-size:2rem;font-weight:800}
  .card .lbl{font-size:.75rem;color:#888;margin-top:4px;text-transform:uppercase;letter-spacing:.05em}
  .card.total .num{color:#60a5fa}.card.ok .num{color:#34d399}.card.bad .num{color:#f87171}
  .spec-box{background:#1a1d27;border:1px solid #2a2d3a;border-radius:10px;padding:14px 20px;margin-bottom:28px;font-size:.82rem;color:#aaa}
  .spec-box h2{font-size:.9rem;color:#fff;margin-bottom:8px}
  .spec-box ul{padding-left:18px;line-height:1.8}
  .spec-box li span{color:#60a5fa;font-family:monospace}
  .tbl-wrap{overflow-x:auto;border-radius:10px;border:1px solid #2a2d3a}
  table{border-collapse:collapse;width:100%;font-size:.8rem}
  thead tr{background:#1e2130}
  th{padding:10px 12px;text-align:left;font-weight:600;color:#a0a8c0;white-space:nowrap;border-bottom:1px solid #2a2d3a}
  tbody tr:nth-child(even){background:#13151f}tbody tr:nth-child(odd){background:#0f1117}
  tbody tr:hover{background:#1e2130}
  td{padding:8px 12px;white-space:nowrap;border-bottom:1px solid #1e2130}
  td.pass{color:#34d399;font-weight:600}td.fail{color:#f87171;font-weight:700}td.warn{color:#fbbf24;font-weight:600}
  .badge{display:inline-block;padding:2px 9px;border-radius:20px;font-size:.72rem;font-weight:700}
  .badge.pass{background:#065f46;color:#34d399;border:1px solid #34d399}
  .badge.fail{background:#7f1d1d;color:#f87171;border:1px solid #f87171}
  .filename{font-family:monospace;color:#c4b5fd;font-size:.78rem}
  .flags{display:flex;gap:4px;flex-wrap:wrap;align-items:center}
  .flag-chip{font-size:.65rem;padding:1px 7px;border-radius:12px;font-weight:700}
  .flag-clip{background:#7f1d1d;color:#fca5a5}.flag-blank{background:#713f12;color:#fde68a}
  .flag-mono{background:#1e3a5f;color:#93c5fd}.flag-tail{background:#3b1f5e;color:#d8b4fe}
  .flag-sr{background:#14532d;color:#86efac}.flag-dc{background:#422006;color:#fed7aa}
  .flag-name{background:#1e1b4b;color:#a5b4fc}.flag-preroll{background:#0c4a6e;color:#7dd3fc}
  .flag-bal{background:#4a1942;color:#f0abfc}.flag-bd{background:#57534e;color:#e7e5e4}
  .flag-lufs{background:#701a35;color:#fbcfe8}
  .mono-val{color:#94a3b8}.lufs-caution{font-size:.65rem;color:#fbbf24;vertical-align:super}
  @media(max-width:600px){.summary{flex-direction:column}}
</style></head><body>
]])

  f:write('<h1>&#127911; '..proj_name..' &mdash; Audio QA Report</h1>\n')
  f:write('<p class="subtitle">Generated by RR_GOTS_QA_AudioChecks.lua &mdash; '..os.date("%Y-%m-%d %H:%M:%S")..'</p>\n')
  f:write('<div class="summary">\n')
  f:write('<div class="card total"><div class="num">'..#results..'</div><div class="lbl">Total Assets</div></div>\n')
  f:write('<div class="card ok"><div class="num">'..pass_count..'</div><div class="lbl">Spec Pass</div></div>\n')
  f:write('<div class="card bad"><div class="num">'..fail_count..'</div><div class="lbl">Spec Fail</div></div>\n')
  f:write('</div>\n')

  f:write('<div class="spec-box"><h2>Active Spec Thresholds</h2><ul>\n')
  f:write('<li>No Clipping    &mdash; True Peak &lt; <span>'..spec.clipping_dbtp..' dBTP</span></li>\n')
  f:write('<li>Not Blank      &mdash; RMS &gt; <span>'..spec.blank_rms_threshold..' dB</span></li>\n')
  f:write('<li>LUFS-I Ceiling &mdash; Integrated Loudness &lt; <span>'..spec.lufs_integrated_max..' LUFS</span></li>\n')
  f:write('<li>No Long Tail   &mdash; trailing quiet &lt; <span>'..spec.tail_duration_sec..'s @ '..spec.tail_db..' dBFS</span></li>\n')
  f:write('<li>No Pre-Roll    &mdash; leader silence &lt; <span>'..spec.pre_roll_max_sec..'s</span></li>\n')
  f:write('<li>No DC Offset   &mdash; DC &lt; <span>'..spec.dc_offset_db_thresh..' dB</span></li>\n')
  f:write('<li>Stereo Balance &mdash; L/R diff &lt; <span>'..spec.balance_db_thresh..' dB</span></li>\n')
  f:write('<li>Sample Rate    &mdash; must be <span>'..spec.required_sample_rate..' Hz</span></li>\n')
  f:write('<li>Bit Depth      &mdash; must be <span>'..spec.required_bit_depth..'-bit</span></li>\n')
  if spec.check_stereo then
    f:write('<li>Must Be Stereo &mdash; <span>'..spec.required_channels..' channels</span></li>\n')
  end
  f:write('</ul></div>\n')

  local headers = {"#","File","Type","Ch","SR (Hz)","Bits","Length (s)",
                   "Peak (dBTP)","RMS (dB)","LUFS-I","Clip Smp",
                   "Tail (s)","Pre-Roll (s)","DC (dB)","Bal (dB)","Flags","SPEC"}
  f:write('<div class="tbl-wrap"><table>\n<thead><tr>')
  for _, h in ipairs(headers) do f:write('<th>'..h..'</th>') end
  f:write('</tr></thead>\n<tbody>\n')

  local function cell(fail) return fail and ' class="fail"' or ' class="pass"' end

  for _, r in ipairs(results) do
    f:write('<tr>\n')
    f:write('<td class="mono-val">'..(r.index or "?")..'</td>\n')
    f:write('<td class="filename">'..r.file..'</td>\n')
    if r.error then
      f:write('<td colspan="15" class="fail">'..r.error..'</td>\n')
    else
      f:write('<td>'..r.file_type..'</td>\n')
      f:write('<td'..cell(r.is_mono)..'>'..r.channels..'</td>\n')
      f:write('<td'..cell(r.wrong_sr)..'>'..r.sample_rate..'</td>\n')
      local bd_display = r.bit_depth and (tostring(r.bit_depth)..(r.is_float and 'f' or '')) or '?'
      f:write('<td'..cell(r.wrong_bit_depth)..'>'..bd_display..'</td>\n')
      f:write('<td class="mono-val">'..string.format("%.2f",r.length_sec)..'</td>\n')
      f:write('<td'..cell(r.is_clipping)..'>'..string.format("%.2f",r.peak_dbtp)..'</td>\n')
      local rms_warn = r.rms_db <= SPEC.blank_rms_threshold + 10
      local rms_cls  = r.is_blank and ' class="fail"' or (rms_warn and ' class="warn"' or '')
      f:write('<td'..rms_cls..'>'..string.format("%.2f",r.rms_db)..'</td>\n')
      local lufs_str
      if r.lufs_i then
        lufs_str = string.format("%.2f",r.lufs_i)
      else
        lufs_str = 'N/A<sup class="lufs-caution" title="File too short for a full 400ms gating block">!</sup>'
      end
      f:write('<td'..cell(r.lufs_over)..'>'..lufs_str..'</td>\n')
      f:write('<td'..cell(r.is_clipping)..'>'..r.clip_count..'</td>\n')
      f:write('<td'..cell(r.has_long_tail)..'>'..string.format("%.2f",r.tail_sec)..'</td>\n')
      f:write('<td'..cell(r.has_pre_roll)..'>'..string.format("%.2f",r.pre_roll_sec)..'</td>\n')
      f:write('<td'..cell(r.has_dc_offset)..'>'..string.format("%.2f",r.dc_db)..'</td>\n')
      f:write('<td'..cell(r.is_imbalanced)..'>'..string.format("%.2f",r.balance_db)..'</td>\n')
      f:write('<td><div class="flags">')
      if #r.flags == 0 then
        f:write('<span style="color:#34d399;font-size:.7rem">&#10003; clean</span>')
      else
        for _, fl in ipairs(r.flags) do
          local title = (fl.cls=="flag-name" and r.name_reason)
                        and (' title="'..r.name_reason..'"') or ''
          f:write('<span class="flag-chip '..fl.cls..'"'..title..'>'..fl.label..'</span>')
        end
      end
      f:write('</div></td>\n')
    end
    if r.spec_pass then f:write('<td><span class="badge pass">PASS</span></td>\n')
    else                f:write('<td><span class="badge fail">FAIL</span></td>\n') end
    f:write('</tr>\n')
  end

  f:write('</tbody></table></div>\n')
  f:write('<p style="margin-top:16px;font-size:.75rem;color:#555">LUFS-I is calculated per ITU-R BS.1770-4 '
       ..'(K-weighting + 400ms gated blocks, absolute + relative gating). '
       ..'Files marked <sup style="color:#fbbf24">!</sup> are too short for a full gating block and show N/A.</p>\n')
  f:write('</body></html>\n')
  f:close()
  return true
end

-- ============================================================
--  REAIMGUI SETTINGS DIALOG
--  Non-blocking: uses reaper.defer() loop, will not hang Reaper.
-- ============================================================
local ctx = reaper.ImGui_CreateContext('QA Audio Check — Settings')
local FONT_SIZE = 15
local FONT = reaper.ImGui_CreateFont('sans-serif', FONT_SIZE)
reaper.ImGui_Attach(ctx, FONT)

-- Build combo strings (null-separated, ReaImGui convention) + index lookups
local function build_combo_items(list)
  local items = {}
  local index_of = {}
  for i, v in ipairs(list) do
    items[#items+1] = tostring(v)
    index_of[v] = i - 1  -- ReaImGui combos are 0-indexed
  end
  return table.concat(items, '\0') .. '\0', index_of
 end

local SR_COMBO_STR, SR_INDEX_OF = build_combo_items(SR_OPTIONS)
local BD_COMBO_STR, BD_INDEX_OF = build_combo_items(BIT_DEPTH_OPTIONS)

-- Editable state, seeded from SPEC defaults
local state = {
  clipping_dbtp        = SPEC.clipping_dbtp,
  blank_rms_threshold  = SPEC.blank_rms_threshold,
  lufs_integrated_max  = SPEC.lufs_integrated_max,
  tail_db              = SPEC.tail_db,
  tail_duration_sec    = SPEC.tail_duration_sec,
  pre_roll_max_sec     = SPEC.pre_roll_max_sec,
  dc_offset_db_thresh  = SPEC.dc_offset_db_thresh,
  balance_db_thresh    = SPEC.balance_db_thresh,
  sr_combo_idx         = SR_INDEX_OF[SPEC.required_sample_rate] or 1,
  bd_combo_idx         = BD_INDEX_OF[SPEC.required_bit_depth]   or 0,
  check_stereo         = SPEC.check_stereo,
  naming_allow_upper   = SPEC.naming_allow_upper,
}

local dialog_open    = true
local user_action    = nil   -- "run" | "cancel" | nil (still open)
local validation_err = nil

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, 480, 0, reaper.ImGui_Cond_FirstUseEver())
  -- Newer ReaImGui builds require a size argument on PushFont; pcall guards
  -- against older builds that only accept (ctx, font).
  local font_pushed = pcall(reaper.ImGui_PushFont, ctx, FONT, FONT_SIZE)
  if not font_pushed then
    font_pushed = pcall(reaper.ImGui_PushFont, ctx, FONT)
  end

  local visible, open = reaper.ImGui_Begin(ctx, 'QA Audio Check — Settings', true,
    reaper.ImGui_WindowFlags_NoCollapse())

  if visible then
    reaper.ImGui_TextColored(ctx, 0x8899AAFF, 'Edit thresholds below. Changes apply to this run only.')
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.clipping_dbtp = reaper.ImGui_InputDouble(ctx, 'True Peak ceiling (dBTP)', state.clipping_dbtp, 0, 0, '%.2f')

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.blank_rms_threshold = reaper.ImGui_InputDouble(ctx, 'Blank RMS threshold (dB)', state.blank_rms_threshold, 0, 0, '%.2f')

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.lufs_integrated_max = reaper.ImGui_InputDouble(ctx, 'LUFS-I ceiling (LUFS)', state.lufs_integrated_max, 0, 0, '%.2f')

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.tail_db = reaper.ImGui_InputDouble(ctx, 'Tail quiet threshold (dBFS)', state.tail_db, 0, 0, '%.2f')

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.tail_duration_sec = reaper.ImGui_InputDouble(ctx, 'Max tail duration (s)', state.tail_duration_sec, 0, 0, '%.2f')

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.pre_roll_max_sec = reaper.ImGui_InputDouble(ctx, 'Max pre-roll silence (s)', state.pre_roll_max_sec, 0, 0, '%.2f')

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.dc_offset_db_thresh = reaper.ImGui_InputDouble(ctx, 'DC offset limit (dB)', state.dc_offset_db_thresh, 0, 0, '%.2f')

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.balance_db_thresh = reaper.ImGui_InputDouble(ctx, 'L/R balance limit (dB)', state.balance_db_thresh, 0, 0, '%.2f')

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.sr_combo_idx = reaper.ImGui_Combo(ctx, 'Required sample rate (Hz)', state.sr_combo_idx, SR_COMBO_STR)

    reaper.ImGui_SetNextItemWidth(ctx, 140)
    _, state.bd_combo_idx = reaper.ImGui_Combo(ctx, 'Required bit depth', state.bd_combo_idx, BD_COMBO_STR)

    reaper.ImGui_Spacing(ctx)
    _, state.check_stereo       = reaper.ImGui_Checkbox(ctx, 'Fail mono files', state.check_stereo)
    _, state.naming_allow_upper = reaper.ImGui_Checkbox(ctx, 'Allow uppercase filenames', state.naming_allow_upper)

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    if validation_err then
      reaper.ImGui_TextColored(ctx, 0xF87171FF, 'Invalid settings: ' .. validation_err)
      reaper.ImGui_Spacing(ctx)
    end

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x065F46FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x0A7A5AFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x055A40FF)
    if reaper.ImGui_Button(ctx, 'Run QA Scan', 200, 34) then
      local ok = state.tail_duration_sec > 0
             and state.pre_roll_max_sec  >= 0
             and state.balance_db_thresh > 0
      if ok then
        SPEC.clipping_dbtp        = state.clipping_dbtp
        SPEC.blank_rms_threshold  = state.blank_rms_threshold
        SPEC.lufs_integrated_max  = state.lufs_integrated_max
        SPEC.tail_db              = state.tail_db
        SPEC.tail_duration_sec    = state.tail_duration_sec
        SPEC.pre_roll_max_sec     = state.pre_roll_max_sec
        SPEC.dc_offset_db_thresh  = state.dc_offset_db_thresh
        SPEC.balance_db_thresh    = state.balance_db_thresh
        SPEC.required_sample_rate = SR_OPTIONS[state.sr_combo_idx + 1]
        SPEC.required_bit_depth   = BIT_DEPTH_OPTIONS[state.bd_combo_idx + 1]
        SPEC.check_stereo         = state.check_stereo
        SPEC.naming_allow_upper   = state.naming_allow_upper
        user_action  = "run"
        dialog_open  = false
      else
        validation_err = "tail duration, pre-roll, and balance limit must be positive"
      end
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_SameLine(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x7F1D1DFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x9B2C2CFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x651616FF)
    if reaper.ImGui_Button(ctx, 'Cancel', 140, 34) then
      user_action = "cancel"
      dialog_open = false
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_End(ctx)
  end

  if font_pushed then reaper.ImGui_PopFont(ctx) end

  if not open then
    user_action = user_action or "cancel"
    dialog_open = false
  end

  if dialog_open then
    reaper.defer(loop)
  end
end

-- ============================================================
--  RUN QA SCAN  (called after dialog closes with "run")
-- ============================================================
local function run_qa_scan()
  local ok_valid, err = pcall(validate_spec, SPEC)
  if not ok_valid then
    reaper.ShowMessageBox("Invalid settings:\n" .. tostring(err), "QA Audio Check", 0)
    return
  end

  local proj_path = reaper.GetProjectPath("")
  if proj_path == "" then
    proj_path = os.getenv("HOME") or os.getenv("USERPROFILE") or "/tmp"
  end
  local sep       = package.config:sub(1, 1)
  local timestamp = os.date("%Y%m%d_%H%M%S")
  local proj_name = reaper.GetProjectName(0, "")
  proj_name = proj_name:gsub("%.rpp$", "")
  if proj_name == "" then proj_name = "Untitled" end

  local html_path = proj_path .. sep .. proj_name .. "_QA_" .. timestamp .. ".html"
  local csv_path  = proj_path .. sep .. proj_name .. "_QA_" .. timestamp .. ".csv"

  local results = collect_results()
  if #results == 0 then
    reaper.ShowMessageBox("No .wav audio items found in the project!", "QA Audio Check", 0)
    return
  end

  local html_ok = write_html(results, html_path, SPEC, proj_name)
  local csv_ok  = write_csv(results, csv_path)

  local counts = { clip=0, blank=0, mono=0, tail=0, sr=0, bd=0,
                   dc=0, preroll=0, bal=0, name=0, lufs=0, fail=0 }
  for _, r in ipairs(results) do
    if r.is_clipping     then counts.clip    = counts.clip    + 1 end
    if r.is_blank        then counts.blank   = counts.blank   + 1 end
    if r.is_mono         then counts.mono    = counts.mono    + 1 end
    if r.has_long_tail   then counts.tail    = counts.tail    + 1 end
    if r.wrong_sr        then counts.sr      = counts.sr      + 1 end
    if r.wrong_bit_depth then counts.bd      = counts.bd      + 1 end
    if r.has_dc_offset   then counts.dc      = counts.dc      + 1 end
    if r.has_pre_roll    then counts.preroll = counts.preroll + 1 end
    if r.is_imbalanced   then counts.bal     = counts.bal     + 1 end
    if r.bad_name        then counts.name    = counts.name    + 1 end
    if r.lufs_over       then counts.lufs    = counts.lufs    + 1 end
    if not r.spec_pass   then counts.fail    = counts.fail    + 1 end
  end

  local summary = string.format(
    "QA Complete: %d assets analysed\n"
  .. "  SPEC PASS  : %d\n"  .. "  SPEC FAIL  : %d\n"
  .. "    Clipping    : %d\n" .. "    Blank       : %d\n"
  .. "    Mono        : %d\n" .. "    Long Tail   : %d\n"
  .. "    Wrong SR    : %d\n" .. "    Wrong Bits  : %d\n"
  .. "    DC Offset   : %d\n" .. "    Pre-Roll    : %d\n"
  .. "    Imbalance   : %d\n" .. "    Bad Name    : %d\n"
  .. "    LUFS-I Over : %d\n\n"
  .. "HTML : %s\nCSV  : %s",
    #results, #results - counts.fail, counts.fail,
    counts.clip, counts.blank, counts.mono,  counts.tail,
    counts.sr,   counts.bd,    counts.dc,    counts.preroll,
    counts.bal,  counts.name,  counts.lufs,
    html_ok and html_path or "WRITE FAILED",
    csv_ok  and csv_path  or "WRITE FAILED"
  )

  reaper.ShowConsoleMsg("\n" .. summary .. "\n")
  reaper.ShowMessageBox(summary, "QA Audio Check - Done", 0)

  if html_ok then
    local os_name = reaper.GetOS()
    if     os_name:find("Win")             then os.execute('start "" "'  .. html_path .. '"')
    elseif os_name:find("OSX") or
           os_name:find("macOS")           then os.execute('open "'      .. html_path .. '"')
    else                                        os.execute('xdg-open "'  .. html_path .. '"')
    end
  end
end

-- ============================================================
--  WATCHER  (polls dialog_open, fires scan once dialog closes)
-- ============================================================
local function watch_dialog()
  if dialog_open then
    reaper.defer(watch_dialog)
    return
  end
  if user_action == "run" then
    run_qa_scan()
  else
    reaper.ShowConsoleMsg("QA Audio Check cancelled.\n")
  end
end

-- ============================================================
--  ENTRY POINT
-- ============================================================
reaper.defer(loop)
reaper.defer(watch_dialog)
