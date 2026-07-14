-- midi.lua -- minimal Standard MIDI File parser (pure Lua, no dependencies).
-- Input: the raw file contents as a Lua string (love.filesystem.read gives this).
-- Output: a sorted list of note-on events: { {t=seconds, note=int}, ... }
-- Handles: format 0/1, variable-length delta times, running status,
-- tempo changes (meta FF 51), and note-off / note-on-vel-0. SMPTE division
-- is approximated. This mirrors what the Python core does with mido.

local Midi = {}

local function u8(s, p)  return string.byte(s, p) end
local function u16(s, p) return u8(s, p) * 256 + u8(s, p + 1) end
local function u32(s, p)
  return ((u8(s, p) * 256 + u8(s, p + 1)) * 256 + u8(s, p + 2)) * 256
         + u8(s, p + 3)
end

-- read a variable-length quantity starting at p; returns value, next_pos
local function readVLQ(s, p)
  local value = 0
  while true do
    local b = u8(s, p); p = p + 1
    value = value * 128 + (b % 128)
    if b < 128 then break end
  end
  return value, p
end

-- parse; returns events(list) , error(string|nil)
function Midi.parse(data, opts)
  opts = opts or {}
  local skip_drums = opts.skip_drums ~= false   -- default true
  if not data or #data < 14 or data:sub(1, 4) ~= "MThd" then
    return nil, "Not a MIDI file (missing MThd header)."
  end
  local format = u16(data, 9)
  local ntracks = u16(data, 11)
  local division = u16(data, 13)
  local ticksPerBeat = 480
  if division < 32768 then
    ticksPerBeat = division
  else
    -- SMPTE: high byte = -fps, low byte = ticks/frame (approx to ticks/beat)
    local fps = 256 - math.floor(division / 256)
    local tpf = division % 256
    ticksPerBeat = math.max(1, fps * tpf)   -- rough; keeps timing sane
  end

  -- 1) collect raw events (absolute ticks) across all tracks, plus tempo map
  local notes = {}       -- {tick=, note=}
  local tempos = {}      -- {tick=, usPerBeat=}
  local p = 15   -- MThd header is 14 bytes (1..14); first MTrk starts at 15
  for _ = 1, ntracks do
    if data:sub(p, p + 3) ~= "MTrk" then break end
    local length = u32(data, p + 4)
    local tp = p + 8
    local trackEnd = tp + length
    local absTick = 0
    local status = 0
    while tp < trackEnd do
      local delta; delta, tp = readVLQ(data, tp)
      absTick = absTick + delta
      local b = u8(data, tp)
      if b >= 128 then status = b; tp = tp + 1 else b = status end
      if b == 0xFF then                       -- meta
        local mtype = u8(data, tp); tp = tp + 1
        local mlen; mlen, tp = readVLQ(data, tp)
        if mtype == 0x51 and mlen == 3 then    -- set tempo
          local us = (u8(data, tp) * 256 + u8(data, tp + 1)) * 256
                     + u8(data, tp + 2)
          tempos[#tempos + 1] = { tick = absTick, us = us }
        end
        tp = tp + mlen
      elseif b == 0xF0 or b == 0xF7 then       -- sysex
        local slen; slen, tp = readVLQ(data, tp)
        tp = tp + slen
      else
        local hi = math.floor(b / 16)
        local chan = b % 16
        if hi == 0x9 then                      -- note on
          local note = u8(data, tp)
          local vel = u8(data, tp + 1)
          tp = tp + 2
          if vel > 0 and not (skip_drums and chan == 9) then
            notes[#notes + 1] = { tick = absTick, note = note }
          end
        elseif hi == 0x8 or hi == 0xA or hi == 0xB or hi == 0xE then
          tp = tp + 2                          -- note off / aftertouch / cc / pitch
        elseif hi == 0xC or hi == 0xD then
          tp = tp + 1                          -- program / channel pressure
        else
          tp = tp + 1
        end
      end
    end
    p = trackEnd
  end

  if #notes == 0 then return nil, "No playable notes found." end

  -- 2) sort tempo changes + notes by tick, walk clock converting ticks->seconds
  table.sort(tempos, function(a, b) return a.tick < b.tick end)
  table.sort(notes,  function(a, b) return a.tick < b.tick end)

  local function tickToSeconds(targetTick)
    local seconds = 0.0
    local curTick = 0
    local us = 500000           -- default 120 bpm
    local ti = 1
    while ti <= #tempos and tempos[ti].tick <= targetTick do
      local seg = tempos[ti].tick - curTick
      seconds = seconds + (seg / ticksPerBeat) * (us / 1000000)
      curTick = tempos[ti].tick
      us = tempos[ti].us
      ti = ti + 1
    end
    seconds = seconds + ((targetTick - curTick) / ticksPerBeat) * (us / 1000000)
    return seconds
  end

  local events = {}
  for i = 1, #notes do
    events[i] = { t = tickToSeconds(notes[i].tick), note = notes[i].note }
  end
  return events, nil
end

-- group near-simultaneous notes into chords, mapping each to a piano key.
-- returns schedule: { {t=seconds, keys={ {key=,shift=}, ...}}, ... }
function Midi.schedule(events, mapping, chordWindow)
  chordWindow = chordWindow or 0.03
  local sched = {}
  local i, N = 1, #events
  while i <= N do
    local startT = events[i].t
    local seen, keys = {}, {}
    while i <= N and (events[i].t - startT) <= chordWindow do
      local folded = mapping.fold(events[i].note)
      if folded then
        local km = mapping.NOTE_MAP[folded]
        local id = km.key .. (km.shift and "S" or "")
        if not seen[id] then
          seen[id] = true
          keys[#keys + 1] = { key = km.key, shift = km.shift, note = folded }
        end
      end
      i = i + 1
    end
    if #keys > 0 then sched[#sched + 1] = { t = startT, keys = keys } end
  end
  return sched
end

return Midi
