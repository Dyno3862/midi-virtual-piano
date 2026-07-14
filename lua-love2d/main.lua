-- main.lua -- MIDI -> Virtual Piano player, LÖVE (Love2D) edition.
-- Standalone Lua app: creates a MidiFiles/ folder, searches it, and plays the
-- selected MIDI on a touch-friendly on-screen virtualpiano-layout keyboard.
-- Runs on Windows/macOS/Linux and on Android/iOS (touch = tap).
--
-- NOTE: this is its own app -- it plays the music itself. It does not (and
-- cannot, on a normal device) send keypresses into another game.

local mapping = require("mapping")
local Midi    = require("midi")

local FOLDER = "MidiFiles"

local state = {
  screen = "browser",            -- "browser" | "player"
  files = {},                    -- all .mid/.midi filenames in the folder
  filtered = {},
  search = "",
  searchFocused = false,
  scroll = 0,
  savePath = "",
  message = "",
  -- player
  title = "",
  schedule = {},
  idx = 1,
  total = 0,
  elapsed = 0,
  playing = false,
  startClock = 0,
  active = {},                   -- note -> expiry time (for key highlight)
  toneCache = {},
  keyLayout = nil,               -- precomputed piano-key rectangles
}

local UI = { rowH = 52, pad = 12 }
local fontBig, fontMed, fontSmall

------------------------------------------------------------------- helpers ----
local function isMidiName(n)
  n = n:lower()
  return n:sub(-4) == ".mid" or n:sub(-5) == ".midi"
end

local function scanFolder()
  state.files = {}
  local ok, items = pcall(love.filesystem.getDirectoryItems, FOLDER)
  if ok and items then
    for _, name in ipairs(items) do
      if isMidiName(name) then state.files[#state.files + 1] = name end
    end
    table.sort(state.files, function(a, b) return a:lower() < b:lower() end)
  end
  state.filtered = {}
  local q = state.search:lower()
  for _, name in ipairs(state.files) do
    if q == "" or name:lower():find(q, 1, true) then
      state.filtered[#state.filtered + 1] = name
    end
  end
end

-- build a sine tone (cached) for a midi note
local function tone(note)
  if state.toneCache[note] then return state.toneCache[note] end
  local rate, dur = 44100, 0.35
  local n = math.floor(rate * dur)
  local sd = love.sound.newSoundData(n, rate, 16, 1)
  local f = mapping.freq(note)
  for i = 0, n - 1 do
    local t = i / rate
    local env = math.min(1, 12 * t) * math.max(0, 1 - t / dur)
    sd:setSample(i, math.sin(2 * math.pi * f * t) * 0.22 * env)
  end
  state.toneCache[note] = sd
  return sd
end

local function playChord(keys)
  local now = love.timer.getTime()
  for _, k in ipairs(keys) do
    state.active[k.note] = now + 0.28
    local ok, src = pcall(love.audio.newSource, tone(k.note), "static")
    if ok then src:play() end
  end
end

local function loadSong(filename)
  local data, err = love.filesystem.read(FOLDER .. "/" .. filename)
  if not data then state.message = "Could not read file."; return end
  local events, perr = Midi.parse(data, { skip_drums = true })
  if not events then state.message = perr or "Parse error."; return end
  local sched = Midi.schedule(events, mapping, 0.03)
  state.title = filename:gsub("%.midi?$", "")
  state.schedule = sched
  state.total = sched[#sched] and sched[#sched].t or 0
  state.idx = 1
  state.elapsed = 0
  state.playing = true
  state.startClock = love.timer.getTime()
  state.active = {}
  state.screen = "player"
end

-- precompute piano key rectangles for the current window size
local function layoutPiano(x, y, w, h)
  local whites = {}
  for note = mapping.MIN_NOTE, mapping.MAX_NOTE do
    local km = mapping.NOTE_MAP[note]
    if km and not km.shift then whites[#whites + 1] = note end
  end
  local wW = w / #whites
  local L = { whites = {}, blacks = {}, wW = wW }
  local wIndex = {}
  for i, note in ipairs(whites) do
    wIndex[note] = i
    L.whites[#L.whites + 1] =
      { note = note, x = x + (i - 1) * wW, y = y, w = wW, h = h,
        key = mapping.NOTE_MAP[note].key }
  end
  for note = mapping.MIN_NOTE, mapping.MAX_NOTE do
    local km = mapping.NOTE_MAP[note]
    if km and km.shift then
      local belowW = wIndex[note - 1]           -- white key just below the sharp
      if belowW then
        local bw = wW * 0.62
        L.blacks[#L.blacks + 1] =
          { note = note, x = x + belowW * wW - bw / 2, y = y,
            w = bw, h = h * 0.62, key = km.key }
      end
    end
  end
  return L
end

--------------------------------------------------------------------- love -----
function love.load()
  pcall(love.filesystem.createDirectory, FOLDER)
  state.savePath = love.filesystem.getSaveDirectory() .. "/" .. FOLDER
  fontBig   = love.graphics.newFont(22)
  fontMed   = love.graphics.newFont(17)
  fontSmall = love.graphics.newFont(13)
  love.graphics.setBackgroundColor(0.10, 0.11, 0.13)
  scanFolder()
  if #state.files == 0 then
    state.message = "Put .mid files in the folder shown above, then tap Refresh."
  end
end

function love.update(dt)
  if state.screen == "player" and state.playing then
    state.elapsed = love.timer.getTime() - state.startClock
    while state.idx <= #state.schedule
          and state.schedule[state.idx].t <= state.elapsed do
      playChord(state.schedule[state.idx].keys)
      state.idx = state.idx + 1
    end
    if state.idx > #state.schedule and state.elapsed >= state.total then
      state.playing = false
    end
  end
end

-- draw a simple touch/click button (hit-testing done separately via clicked())
local function button(label, x, y, w, h)
  love.graphics.setColor(0.22, 0.24, 0.30)
  love.graphics.rectangle("fill", x, y, w, h, 8, 8)
  love.graphics.setColor(0.85, 0.87, 0.92)
  love.graphics.setFont(fontMed)
  love.graphics.printf(label, x, y + h / 2 - 10, w, "center")
end

-- hit test helper used during draw
local function clicked(x, y, w, h)
  if _pendingClick and _pendingClick.x >= x and _pendingClick.x <= x + w
     and _pendingClick.y >= y and _pendingClick.y <= y + h then
    return true
  end
  return false
end

function love.draw()
  local W, H = love.graphics.getDimensions()
  if state.screen == "browser" then
    drawBrowser(W, H)
  else
    drawPlayer(W, H)
  end
  _pendingClick = nil
end

function drawBrowser(W, H)
  local pad = UI.pad
  love.graphics.setColor(0.95, 0.96, 1)
  love.graphics.setFont(fontBig)
  love.graphics.print("MIDI Virtual Piano", pad, pad)

  love.graphics.setFont(fontSmall)
  love.graphics.setColor(0.6, 0.63, 0.7)
  love.graphics.printf("Drop .mid files here:  " .. state.savePath,
                       pad, pad + 32, W - pad * 2, "left")

  -- search field
  local sx, sy, sw, sh = pad, pad + 62, W - pad * 2 - 200, 40
  love.graphics.setColor(state.searchFocused and 0.2 or 0.16,
                         0.17, 0.2)
  love.graphics.rectangle("fill", sx, sy, sw, sh, 6, 6)
  love.graphics.setColor(0.8, 0.82, 0.88)
  love.graphics.setFont(fontMed)
  local shown = state.search ~= "" and state.search or "Search files..."
  love.graphics.print(shown, sx + 10, sy + 10)
  if clicked(sx, sy, sw, sh) then
    state.searchFocused = true
    pcall(love.keyboard.setTextInput, true, sx, sy, sw, sh)
  end

  button("Refresh", W - pad - 190, sy, 90, sh)
  if clicked(W - pad - 190, sy, 90, sh) then scanFolder() end
  button("Clear", W - pad - 95, sy, 85, sh)
  if clicked(W - pad - 95, sy, 85, sh) then
    state.search = ""; state.searchFocused = false; scanFolder()
  end

  -- list
  local lx, ly = pad, sy + sh + 10
  local lw, lh = W - pad * 2, H - ly - pad
  love.graphics.setColor(0.13, 0.14, 0.17)
  love.graphics.rectangle("fill", lx, ly, lw, lh, 6, 6)
  love.graphics.setScissor(lx, ly, lw, lh)
  local rowH = UI.rowH
  for i, name in ipairs(state.filtered) do
    local ry = ly + (i - 1) * rowH - state.scroll
    if ry + rowH > ly and ry < ly + lh then
      love.graphics.setColor(0.17, 0.18, 0.22)
      love.graphics.rectangle("fill", lx + 4, ry + 3, lw - 8, rowH - 6, 5, 5)
      love.graphics.setColor(0.9, 0.92, 0.96)
      love.graphics.setFont(fontMed)
      love.graphics.print(name:gsub("%.midi?$", ""), lx + 14, ry + rowH / 2 - 10)
      if clicked(lx + 4, ry + 3, lw - 8, rowH - 6) then loadSong(name) end
    end
  end
  love.graphics.setScissor()

  if #state.filtered == 0 then
    love.graphics.setColor(0.6, 0.62, 0.7)
    love.graphics.setFont(fontMed)
    love.graphics.printf(state.message ~= "" and state.message
                         or "No matching files.", lx, ly + 20, lw, "center")
  end
end

function drawPlayer(W, H)
  local pad = UI.pad
  -- top bar
  button("< Back", pad, pad, 100, 40)
  if clicked(pad, pad, 100, 40) then
    state.playing = false; state.screen = "browser"; scanFolder()
  end
  love.graphics.setColor(0.2, 0.85, 0.6)
  love.graphics.setFont(fontBig)
  love.graphics.printf(state.title, pad + 110, pad + 4, W - pad * 2 - 110, "left")

  -- transport
  local by = pad + 54
  button(state.playing and "Pause" or "Play", pad, by, 110, 44)
  if clicked(pad, by, 110, 44) then
    if state.playing then
      state.playing = false
      state.pausedAt = state.elapsed
    else
      state.playing = true
      state.startClock = love.timer.getTime() - (state.pausedAt or state.elapsed)
    end
  end
  button("Stop", pad + 120, by, 110, 44)
  if clicked(pad + 120, by, 110, 44) then
    state.playing = false; state.elapsed = 0; state.idx = 1
    state.pausedAt = 0; state.active = {}
  end

  -- progress
  local function fmt(s) s = math.max(0, math.floor(s + 0.5))
    return string.format("%d:%02d", math.floor(s / 60), s % 60) end
  love.graphics.setColor(0.8, 0.82, 0.88); love.graphics.setFont(fontMed)
  love.graphics.printf(fmt(state.elapsed) .. " / " .. fmt(state.total),
                       pad + 240, by + 12, W - pad * 2 - 240, "left")
  local px, pyy, pw = pad, by + 52, W - pad * 2
  love.graphics.setColor(0.2, 0.21, 0.25)
  love.graphics.rectangle("fill", px, pyy, pw, 8, 4, 4)
  love.graphics.setColor(0.2, 0.75, 0.55)
  local frac = state.total > 0 and math.min(1, state.elapsed / state.total) or 0
  love.graphics.rectangle("fill", px, pyy, pw * frac, 8, 4, 4)

  -- piano
  local ky = pyy + 26
  local kh = H - ky - pad
  state.keyLayout = layoutPiano(pad, ky, W - pad * 2, kh)
  local now = love.timer.getTime()
  for _, wk in ipairs(state.keyLayout.whites) do
    local on = state.active[wk.note] and now < state.active[wk.note]
    love.graphics.setColor(on and 0.35 or 0.93, on and 0.85 or 0.94,
                           on and 0.55 or 0.96)
    love.graphics.rectangle("fill", wk.x + 1, wk.y, wk.w - 2, wk.h, 2, 2)
    love.graphics.setColor(0.4, 0.42, 0.5); love.graphics.setFont(fontSmall)
    love.graphics.printf(wk.key, wk.x, wk.y + wk.h - 20, wk.w, "center")
  end
  for _, bk in ipairs(state.keyLayout.blacks) do
    local on = state.active[bk.note] and now < state.active[bk.note]
    love.graphics.setColor(on and 0.3 or 0.08, on and 0.8 or 0.08,
                           on and 0.5 or 0.1)
    love.graphics.rectangle("fill", bk.x, bk.y, bk.w, bk.h, 2, 2)
  end
end

------------------------------------------------------------- input handlers ---
function love.mousepressed(x, y, b) if b == 1 then _pendingClick = {x=x, y=y} end end
function love.touchpressed(id, x, y) _pendingClick = { x = x, y = y } end

function love.textinput(t)
  if state.screen == "browser" and state.searchFocused then
    state.search = state.search .. t
    scanFolder()
  end
end

function love.keypressed(key)
  if state.screen == "browser" and state.searchFocused then
    if key == "backspace" then
      state.search = state.search:sub(1, -2); scanFolder()
    elseif key == "return" or key == "escape" then
      state.searchFocused = false
      pcall(love.keyboard.setTextInput, false)
    end
  elseif key == "escape" and state.screen == "player" then
    state.playing = false; state.screen = "browser"
  end
end

function love.wheelmoved(_, dy)
  if state.screen == "browser" then
    local maxScroll = math.max(0, #state.filtered * UI.rowH - 200)
    state.scroll = math.max(0, math.min(maxScroll, state.scroll - dy * 40))
  end
end
