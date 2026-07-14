-- autoplay.lua -- turn a parsed MIDI into virtual-piano keystrokes and play it
-- by driving a "backend" you provide (your game's keyboard-input API).
--
-- The backend table must implement:
--   backend.now()            -> number   (seconds, monotonic-ish clock)
--   backend.sleep(seconds)               (yield/wait for that long)
--   backend.keyDown(char)                (press a virtual-piano key, e.g. "t")
--   backend.keyUp(char)                  (release it)
--   backend.shiftDown()                  (hold Shift  -- for sharp/black keys)
--   backend.shiftUp()                    (release Shift)
--
-- See init.lua for ready-to-edit example backends.

local Midi    = require("midi")
local mapping = require("mapping")

local Autoplay = {}

Autoplay.KEY_TAP    = 0.012   -- how long each key is held (seconds)
Autoplay.CHORD_GAP  = 0.004   -- gap between the natural and sharp halves of a chord
Autoplay.COUNTDOWN  = 3       -- seconds before playback starts (switch to the game)

-- build a playable schedule straight from raw MIDI bytes
function Autoplay.prepare(data, opts)
  local events, err = Midi.parse(data, opts or { skip_drums = true })
  if not events then return nil, err end
  local schedule = Midi.schedule(events, mapping, 0.03)
  local total = schedule[#schedule] and schedule[#schedule].t or 0
  return { schedule = schedule, total = total }, nil
end

-- send one chord as a virtual-piano hit (naturals, then shifted sharps)
local function sendChord(keys, backend)
  local plain, sharp = {}, {}
  for _, k in ipairs(keys) do
    if k.shift then sharp[#sharp + 1] = k.key else plain[#plain + 1] = k.key end
  end
  if #plain > 0 then
    for _, c in ipairs(plain) do backend.keyDown(c) end
    backend.sleep(Autoplay.KEY_TAP)
    for _, c in ipairs(plain) do backend.keyUp(c) end
  end
  if #sharp > 0 then
    if #plain > 0 then backend.sleep(Autoplay.CHORD_GAP) end
    backend.shiftDown()
    for _, c in ipairs(sharp) do backend.keyDown(c) end
    backend.sleep(Autoplay.KEY_TAP)
    for _, c in ipairs(sharp) do backend.keyUp(c) end
    backend.shiftUp()
  end
end

-- Play a prepared song (blocking). `shouldStop` is an optional function that,
-- if it returns true, stops playback early. Returns true if it finished.
function Autoplay.play(prepared, backend, shouldStop)
  for i = Autoplay.COUNTDOWN, 1, -1 do
    if shouldStop and shouldStop() then return false end
    if backend.log then backend.log("Starting in " .. i .. "...") end
    backend.sleep(1)
  end
  if backend.log then backend.log("Playing. " .. #prepared.schedule .. " chords.") end

  local start = backend.now()
  for _, chord in ipairs(prepared.schedule) do
    -- wait until this chord's timestamp (relative to start)
    while (backend.now() - start) < chord.t do
      if shouldStop and shouldStop() then return false end
      local remaining = chord.t - (backend.now() - start)
      backend.sleep(remaining > 0.004 and (remaining - 0.003) or 0.001)
    end
    if shouldStop and shouldStop() then return false end
    sendChord(chord.keys, backend)
  end
  if backend.log then backend.log("Finished.") end
  return true
end

return Autoplay
