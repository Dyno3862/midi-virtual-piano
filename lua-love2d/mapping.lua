-- mapping.lua -- MIDI note number <-> virtualpiano.net key (same layout as the
-- Python desktop version). 36 white keys C2..C7 on
-- 1234567890 qwertyuiop asdfghjkl zxcvbnm ; each sharp = Shift + white below.

local M = {}

local WHITE_KEYS = "1234567890qwertyuiopasdfghjklzxcvbnm" -- 36 chars
local WHITE_SEMI = { [0]=true, [2]=true, [4]=true, [5]=true, [7]=true,
                     [9]=true, [11]=true }
M.LOWEST_MIDI = 36  -- C2

function M.build(lowest)
  lowest = lowest or M.LOWEST_MIDI
  local map = {}
  local n, idx = lowest, 1
  while idx <= #WHITE_KEYS do
    if WHITE_SEMI[n % 12] then
      map[n] = { key = WHITE_KEYS:sub(idx, idx), shift = false }
      idx = idx + 1
    end
    n = n + 1
  end
  local highest_white = n - 1
  for note = lowest, highest_white do
    if not WHITE_SEMI[note % 12] and map[note - 1] then
      map[note] = { key = map[note - 1].key, shift = true }
    end
  end
  return map
end

M.NOTE_MAP = M.build()
do
  local lo, hi
  for note, _ in pairs(M.NOTE_MAP) do
    if not lo or note < lo then lo = note end
    if not hi or note > hi then hi = note end
  end
  M.MIN_NOTE, M.MAX_NOTE = lo, hi
end

-- fold an out-of-range note into playable range by whole octaves
function M.fold(note)
  while note < M.MIN_NOTE do note = note + 12 end
  while note > M.MAX_NOTE do note = note - 12 end
  if note >= M.MIN_NOTE and note <= M.MAX_NOTE then return note end
  return nil
end

-- concert-pitch frequency for a midi note (for tone playback)
function M.freq(note)
  return 440.0 * 2 ^ ((note - 69) / 12)
end

return M
