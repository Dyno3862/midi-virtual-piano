--[[  MIDI -> Virtual Piano  ::  single-file remote-loadable autoplay GUI
      Load it in your game with:
        loadstring(game:HttpGet("<raw url>"))()
      Everything is inlined (MIDI parser, virtualpiano.net mapping, GitHub
      fetch, GUI, autoplay) so it runs as ONE self-contained chunk.

      Written in plain Lua 5.1 / Luau-compatible syntax.
============================================================================ ]]

-- ###########################################################################
-- ##  CONFIG + ADAPTER  --  THIS IS THE ONLY PART YOU EDIT                  ##
-- ###########################################################################
local CONFIG = {
  repoOwner = "Dyno3862",           -- your MIDI repo owner
  repoName  = "Jonah-Midi-Collection",
  branch    = "main",
  keyTap    = 0.05,                 -- seconds each key is held
  chordGap  = 0.01,                 -- gap between naturals and sharps in a chord
  defaultSpeed = 1.0,               -- tempo multiplier (1 = original)
}

local Adapter = {}

-- ---- HTTP GET: return the response body as a string -----------------------
-- Default = Roblox HttpService (Game Settings > enable HTTP Requests).
-- Alternative shown in comments (game:HttpGet, used by many script loaders).
function Adapter.httpGet(url)
  local ok, res = pcall(function()
    return game:GetService("HttpService"):GetAsync(url)
  end)
  if ok and res then return res end
  local ok2, res2 = pcall(function() return game:HttpGet(url) end) -- fallback
  if ok2 and res2 then return res2 end
  return nil, tostring(res)
end

-- ---- KEY OUTPUT: send REAL key events to drive your piano -----------------
-- Your piano reads keyboard input via UserInputService InputBegan/InputEnded,
-- so the autoplayer synthesizes genuine key events with VirtualInputManager.
-- VIM:SendKeyEvent(isDown, keyCode, false, game) makes InputBegan/InputEnded
-- fire exactly as if the user pressed the key.
--
-- NOTE: VirtualInputManager:SendKeyEvent is only callable from an ELEVATED
-- context (a script executor, or Roblox Studio's command bar / a plugin). A
-- plain in-experience LocalScript cannot call it -- Roblox locks it down.
--
-- FALLBACK if VIM is blocked in your environment: replace the four Adapter
-- functions below to call your piano's handler directly, e.g.
--     function Adapter.keyDown(char) MyPiano:onKeyDown(KEYCODES[char]) end
--     function Adapter.keyUp(char)   MyPiano:onKeyUp(KEYCODES[char])   end
-- (KEYCODES maps each virtualpiano character to its Enum.KeyCode below.)
local VIM = game:GetService("VirtualInputManager")

-- virtualpiano.net character -> Roblox KeyCode. Covers EVERY character the
-- mapping emits: the number row 1234567890 and the letters q..m. Sharps are
-- the same natural key held together with LeftShift (see shiftDown/shiftUp).
local KEYCODES = {
  ["1"]=Enum.KeyCode.One,   ["2"]=Enum.KeyCode.Two,   ["3"]=Enum.KeyCode.Three,
  ["4"]=Enum.KeyCode.Four,  ["5"]=Enum.KeyCode.Five,  ["6"]=Enum.KeyCode.Six,
  ["7"]=Enum.KeyCode.Seven, ["8"]=Enum.KeyCode.Eight, ["9"]=Enum.KeyCode.Nine,
  ["0"]=Enum.KeyCode.Zero,
  q=Enum.KeyCode.Q, w=Enum.KeyCode.W, e=Enum.KeyCode.E, r=Enum.KeyCode.R,
  t=Enum.KeyCode.T, y=Enum.KeyCode.Y, u=Enum.KeyCode.U, i=Enum.KeyCode.I,
  o=Enum.KeyCode.O, p=Enum.KeyCode.P, a=Enum.KeyCode.A, s=Enum.KeyCode.S,
  d=Enum.KeyCode.D, f=Enum.KeyCode.F, g=Enum.KeyCode.G, h=Enum.KeyCode.H,
  j=Enum.KeyCode.J, k=Enum.KeyCode.K, l=Enum.KeyCode.L, z=Enum.KeyCode.Z,
  x=Enum.KeyCode.X, c=Enum.KeyCode.C, v=Enum.KeyCode.V, b=Enum.KeyCode.B,
  n=Enum.KeyCode.N, m=Enum.KeyCode.M,
}

-- Track which keys are currently held so we NEVER leave one stuck. A stuck key
-- (keyDown with no matching keyUp) makes Roblox treat it as already-down, so a
-- later SendKeyEvent(down) for that key fires NO new InputBegan -- exactly the
-- "letters stopped registering but Shift still worked" bug.
local heldKeys = {}       -- [char] = true while held down
local heldShift = false

local function rawKey(char, isDown)
  local kc = KEYCODES[char]
  if kc then VIM:SendKeyEvent(isDown, kc, false, game) end
  -- a char with no KeyCode is silently skipped (degrades gracefully, no error)
end

function Adapter.keyDown(char)
  if heldKeys[char] then rawKey(char, false) end   -- release a duplicate/stuck press first
  rawKey(char, true)
  heldKeys[char] = true
end
function Adapter.keyUp(char)
  rawKey(char, false)
  heldKeys[char] = nil
end
function Adapter.shiftDown()
  if not heldShift then VIM:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game); heldShift = true end
end
function Adapter.shiftUp()
  if heldShift then VIM:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game); heldShift = false end
end
-- release EVERYTHING still held (Stop, song end, error, and start of each Play)
function Adapter.releaseAll()
  for char in pairs(heldKeys) do rawKey(char, false) end
  heldKeys = {}
  if heldShift then
    VIM:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game); heldShift = false
  end
end

-- ---- TIMING ---------------------------------------------------------------
function Adapter.now()
  if os and os.clock then return os.clock() end
  return tick()
end
function Adapter.wait(t)
  if task and task.wait then return task.wait(t) end
  if wait then return wait(t) end
end
function Adapter.spawn(fn)
  if task and task.spawn then return task.spawn(fn) end
  if spawn then return spawn(fn) end
  return fn()
end
-- ###########################################################################
-- ##  END CONFIG  --  no need to edit below this line                       ##
-- ###########################################################################


-- ===========================================================================
-- virtualpiano.net KEY MAP  (36 white keys C2..C7; sharps = Shift + white below)
-- ===========================================================================
local WHITE_KEYS = "1234567890qwertyuiopasdfghjklzxcvbnm"
local WHITE_SEMI = {[0]=true,[2]=true,[4]=true,[5]=true,[7]=true,[9]=true,[11]=true}
local LOWEST_MIDI = 36

local NOTE_MAP = {}
do
  local n, idx = LOWEST_MIDI, 1
  while idx <= #WHITE_KEYS do
    if WHITE_SEMI[n % 12] then
      NOTE_MAP[n] = { key = WHITE_KEYS:sub(idx, idx), shift = false }
      idx = idx + 1
    end
    n = n + 1
  end
  local highest_white = n - 1
  for note = LOWEST_MIDI, highest_white do
    if not WHITE_SEMI[note % 12] and NOTE_MAP[note - 1] then
      NOTE_MAP[note] = { key = NOTE_MAP[note - 1].key, shift = true }
    end
  end
end
local MIN_NOTE, MAX_NOTE = LOWEST_MIDI, nil
do local hi; for k,_ in pairs(NOTE_MAP) do if not hi or k>hi then hi=k end end; MAX_NOTE=hi end

local function foldNote(note)
  while note < MIN_NOTE do note = note + 12 end
  while note > MAX_NOTE do note = note - 12 end
  if note >= MIN_NOTE and note <= MAX_NOTE then return note end
  return nil
end

-- ===========================================================================
-- MIDI PARSER (pure Lua; format 0/1, VLQ, running status, tempo, drum-skip)
-- ===========================================================================
local function u8(s,p)  return string.byte(s,p) end
local function u16(s,p) return u8(s,p)*256 + u8(s,p+1) end
local function u32(s,p) return ((u8(s,p)*256+u8(s,p+1))*256+u8(s,p+2))*256+u8(s,p+3) end
local function readVLQ(s,p)
  local v=0
  while true do local b=u8(s,p); p=p+1; v=v*128+(b%128); if b<128 then break end end
  return v,p
end

local function parseMidi(data, skipDrums)
  if skipDrums == nil then skipDrums = true end
  if not data or #data < 14 or data:sub(1,4) ~= "MThd" then
    return nil, "Not a MIDI file (no MThd header)."
  end
  local ntracks = u16(data,11)
  local division = u16(data,13)
  local ticksPerBeat = 480
  if division < 32768 then ticksPerBeat = division
  else local fps = 256 - math.floor(division/256); local tpf = division % 256
       ticksPerBeat = math.max(1, fps*tpf) end
  local notes, tempos = {}, {}
  local p = 15
  for _=1,ntracks do
    if data:sub(p,p+3) ~= "MTrk" then break end
    local length = u32(data,p+4)
    local tp = p+8
    local trackEnd = tp+length
    local absTick, status = 0, 0
    while tp < trackEnd do
      local delta; delta,tp = readVLQ(data,tp); absTick = absTick+delta
      local b = u8(data,tp)
      if b >= 128 then status=b; tp=tp+1 else b=status end
      if b == 0xFF then
        local mtype=u8(data,tp); tp=tp+1
        local mlen; mlen,tp = readVLQ(data,tp)
        if mtype==0x51 and mlen==3 then
          tempos[#tempos+1] = { tick=absTick, us=(u8(data,tp)*256+u8(data,tp+1))*256+u8(data,tp+2) }
        end
        tp = tp+mlen
      elseif b == 0xF0 or b == 0xF7 then
        local slen; slen,tp = readVLQ(data,tp); tp = tp+slen
      else
        local hi = math.floor(b/16); local chan = b % 16
        if hi == 0x9 then
          local note=u8(data,tp); local vel=u8(data,tp+1); tp=tp+2
          if vel>0 and not (skipDrums and chan==9) then
            notes[#notes+1] = { tick=absTick, note=note }
          end
        elseif hi==0x8 or hi==0xA or hi==0xB or hi==0xE then tp=tp+2
        elseif hi==0xC or hi==0xD then tp=tp+1
        else tp=tp+1 end
      end
    end
    p = trackEnd
  end
  if #notes == 0 then return nil, "No playable notes found." end
  table.sort(tempos, function(a,b) return a.tick<b.tick end)
  table.sort(notes,  function(a,b) return a.tick<b.tick end)
  local function tickToSec(target)
    local sec,cur,us,ti = 0.0,0,500000,1
    while ti<=#tempos and tempos[ti].tick<=target do
      sec = sec + ((tempos[ti].tick-cur)/ticksPerBeat)*(us/1000000)
      cur = tempos[ti].tick; us = tempos[ti].us; ti = ti+1
    end
    return sec + ((target-cur)/ticksPerBeat)*(us/1000000)
  end
  local events = {}
  for i=1,#notes do events[i] = { t=tickToSec(notes[i].tick), note=notes[i].note } end
  return events
end

local function buildSchedule(events, chordWindow)
  chordWindow = chordWindow or 0.03
  local sched = {}
  local i,N = 1,#events
  while i <= N do
    local startT = events[i].t
    local seen,keys = {},{}
    while i <= N and (events[i].t-startT) <= chordWindow do
      local folded = foldNote(events[i].note)
      if folded then
        local km = NOTE_MAP[folded]
        local id = km.key .. (km.shift and "S" or "")
        if not seen[id] then seen[id]=true; keys[#keys+1] = { key=km.key, shift=km.shift } end
      end
      i = i+1
    end
    if #keys > 0 then sched[#sched+1] = { t=startT, keys=keys } end
  end
  return sched
end

-- ===========================================================================
-- REMOTE (list + fetch from the GitHub repo)
-- ===========================================================================
local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end
local function contentsURL()
  return ("https://api.github.com/repos/%s/%s/contents/?ref=%s"):format(CONFIG.repoOwner, CONFIG.repoName, CONFIG.branch)
end
local function rawBase()
  return ("https://raw.githubusercontent.com/%s/%s/%s/"):format(CONFIG.repoOwner, CONFIG.repoName, CONFIG.branch)
end
local function listSongs()
  local body, err = Adapter.httpGet(contentsURL())
  if not body then return nil, "GitHub list failed: "..tostring(err) end
  local files, seen = {}, {}
  for path in body:gmatch('"path"%s*:%s*"([^"]-)"') do
    local low = path:lower()
    if (low:sub(-4)==".mid" or low:sub(-5)==".midi") and not seen[path] then
      seen[path]=true
      files[#files+1] = { name=(path:gsub("%.midi?$","")), url=rawBase()..urlencode(path) }
    end
  end
  table.sort(files, function(a,b) return a.name:lower() < b.name:lower() end)
  if #files == 0 then return nil, "No .mid files found in repo." end
  return files
end
local function fetchSong(entry)
  local data, err = Adapter.httpGet(entry.url)
  if not data then return nil, "download failed: "..tostring(err) end
  if data:sub(1,4) ~= "MThd" then return nil, "not a MIDI file" end
  return data
end

-- ---- extra online sources: BitMidi (JSON API) + MIDIFind (HTML scrape) ----
local function stripExt(name) return (name:gsub("%.midi?$", "")) end

-- BitMidi has a public JSON API: /api/midi/search?q=...  -> results[] each with
-- name, plays and a relative downloadUrl ("/uploads/<id>.mid").
local function searchBitMidi(query)
  local url = "https://bitmidi.com/api/midi/search?q=" .. urlencode(query)
  local body, err = Adapter.httpGet(url)
  if not body then return nil, "BitMidi request failed: " .. tostring(err) end
  local files = {}
  for name, plays, dl in body:gmatch('"name"%s*:%s*"([^"]-)".-"plays"%s*:%s*(%d+).-"downloadUrl"%s*:%s*"([^"]-)"') do
    files[#files + 1] = { name = stripExt(name) .. "  (" .. plays .. " plays)",
                          url = "https://bitmidi.com" .. dl }
    if #files >= 40 then break end
  end
  if #files == 0 then return nil, "No BitMidi results." end
  return files
end

-- MIDIFind has no JSON API, so we scrape its server-rendered results page.
-- Each result links to /files/.../<n>-1-0-<id>; the file itself downloads from
-- /files/0-0-1-<id>-20. Titles are inside a <div class="w-100 ..."> block.
local function htmlUnescape(str)
  str = str:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#0?39;", "'")
  str = str:gsub("&#(%d+);", function(n)
          local ok, ch = pcall(function() return utf8.char(tonumber(n)) end)
          return ok and ch or ""
        end)
  return str
end
local function searchMidiFind(query)
  local url = "https://midifind.com/search/?q=" .. urlencode(query)
  local html, err = Adapter.httpGet(url)
  if not html then return nil, "MIDIFind request failed: " .. tostring(err) end
  local files = {}
  for href, title in html:gmatch('href="(/files/[^"]-)"[^>]-class="item".-<div class="w%-100[^"]*">(.-)</div>') do
    local id = href:match("(%d+)$")
    if id then
      local t = title:gsub("%b<>", "")     -- strip <b> highlight tags
      t = t:gsub("%s+", " ")
      t = htmlUnescape(t)
      t = t:gsub("^%s+", ""); t = t:gsub("%s+$", "")
      files[#files + 1] = { name = (t ~= "" and t or ("MIDIFind #" .. id)),
                            url = "https://midifind.com/files/0-0-1-" .. id .. "-20" }
    end
    if #files >= 40 then break end
  end
  if #files == 0 then return nil, "No MIDIFind results." end
  return files
end

-- ===========================================================================
-- AUTOPLAY ENGINE
-- ===========================================================================
local State = { speed = CONFIG.defaultSpeed, playing = false, stop = false,
                prepared = nil, current = nil, playToken = 0 }
local setStatus  -- forward decl (GUI wires this)

-- Play one chord. Every keyDown is guaranteed a keyUp; if anything errors
-- mid-hit we release all held keys instead of leaving them stuck.
-- Returns ok(boolean), err.
local function sendChord(keys)
  local plain, sharp = {}, {}
  for _,k in ipairs(keys) do
    if k.shift then sharp[#sharp+1]=k.key else plain[#plain+1]=k.key end
  end
  local ok, err = pcall(function()
    if #plain > 0 then
      for _,c in ipairs(plain) do Adapter.keyDown(c) end
      Adapter.wait(CONFIG.keyTap)
      for _,c in ipairs(plain) do Adapter.keyUp(c) end
    end
    if #sharp > 0 then
      if #plain > 0 then Adapter.wait(CONFIG.chordGap) end
      Adapter.shiftDown()
      for _,c in ipairs(sharp) do Adapter.keyDown(c) end
      Adapter.wait(CONFIG.keyTap)
      for _,c in ipairs(sharp) do Adapter.keyUp(c) end
      Adapter.shiftUp()
    end
  end)
  if not ok then Adapter.releaseAll(); return false, err end
  return true
end

local function stopPlayback()
  State.stop = true
  Adapter.releaseAll()          -- immediately free any held keys
end

-- the actual note loop. `myToken` lets a newer Play/song supersede an older run.
local function runPlayLoop(myToken)
  Adapter.releaseAll()          -- clean slate before we press anything
  State.stop = false
  State.playing = true
  local sched = State.prepared.schedule
  local start = Adapter.now()
  local errMsg
  for i=1,#sched do
    if State.stop or State.playToken ~= myToken then break end
    local targetT = sched[i].t / (State.speed > 0 and State.speed or 1)
    while (Adapter.now()-start) < targetT do
      if State.stop or State.playToken ~= myToken then break end
      Adapter.wait()
    end
    if State.stop or State.playToken ~= myToken then break end
    local ok, err = sendChord(sched[i].keys)
    if not ok then errMsg = err; break end
  end
  Adapter.releaseAll()          -- ALWAYS release on exit: finish / stop / error / superseded
  State.playing = false
  if State.playToken == myToken and setStatus then
    if errMsg then setStatus("Playback error: " .. tostring(errMsg))
    elseif State.stop then setStatus("Stopped.")
    else setStatus("Finished.") end
  end
end

local function startPlayback()
  if not State.prepared then return end
  State.playToken = (State.playToken or 0) + 1   -- supersede any running loop
  local myToken = State.playToken
  State.stop = true                              -- ask the old loop to bail out
  Adapter.spawn(function()
    local guard = 0
    while State.playing and guard < 300 do Adapter.wait(); guard = guard + 1 end
    if State.playToken ~= myToken then return end -- a newer Play already took over
    runPlayLoop(myToken)
  end)
end

local function loadAndMaybePlay(entry, autoplay)
  if setStatus then setStatus("Loading: "..entry.name.."...") end
  Adapter.spawn(function()
    local data, err = fetchSong(entry)
    if not data then if setStatus then setStatus("Error: "..err) end return end
    local events, perr = parseMidi(data, true)
    if not events then if setStatus then setStatus("Error: "..perr) end return end
    State.prepared = { schedule = buildSchedule(events, 0.03) }
    State.current = entry
    if setStatus then setStatus("Loaded: "..entry.name.." ("..#State.prepared.schedule.." chords)") end
    if autoplay then startPlayback() end
  end)
end

-- ===========================================================================
-- GUI  (Roblox). If you're on a different engine, replace this block; the
-- engine-agnostic core above (parse/map/fetch/autoplay) stays the same.
-- ===========================================================================
local function buildGui()
  local Players = game:GetService("Players")
  local plr = Players.LocalPlayer
  local parent = plr and plr:WaitForChild("PlayerGui") or game:GetService("CoreGui")
  local C = Color3.fromRGB
  local function make(cls, props, kids)
    local o = Instance.new(cls)
    for k,v in pairs(props or {}) do o[k]=v end
    for _,c in ipairs(kids or {}) do c.Parent = o end
    return o
  end
  local function corner(o, r)
    local u = Instance.new("UICorner"); u.CornerRadius = UDim.new(0, r or 6); u.Parent = o
    return o
  end

  local sg = make("ScreenGui", { Name="MidiAutoplay", ResetOnSpawn=false })
  sg.Parent = parent
  local win = corner(make("Frame", { Parent=sg, Size=UDim2.new(0,320,0,404),
    Position=UDim2.new(0,20,0,60), BackgroundColor3=C(24,26,31), BorderSizePixel=0,
    Active=true, Draggable=true }))

  make("TextLabel", { Parent=win, Size=UDim2.new(1,0,0,24), Position=UDim2.new(0,0,0,6),
    BackgroundTransparency=1, Text="MIDI Autoplay", TextColor3=C(230,235,245),
    Font=Enum.Font.GothamBold, TextSize=16 })

  -- source selector: My Collection / BitMidi / MIDIFind
  State.source = "collection"
  local srcRow = make("Frame", { Parent=win, BackgroundTransparency=1,
    Size=UDim2.new(1,-20,0,26), Position=UDim2.new(0,10,0,32) })
  local srcButtons = {}
  local function setSource(src)
    State.source = src
    for key,btn in pairs(srcButtons) do
      btn.BackgroundColor3 = (key==src) and C(60,110,90) or C(40,43,50)
    end
  end
  local function mkSrc(key, label, xscale)
    local b = corner(make("TextButton", { Parent=srcRow, Size=UDim2.new(0.32,0,1,0),
      Position=UDim2.new(xscale,0,0,0), BackgroundColor3=C(40,43,50), TextColor3=C(230,235,245),
      Text=label, Font=Enum.Font.Gotham, TextSize=12, AutoButtonColor=true }), 5)
    srcButtons[key] = b; return b
  end
  local bCol = mkSrc("collection","My Collection",0)
  local bBit = mkSrc("bitmidi","BitMidi",0.34)
  local bMid = mkSrc("midifind","MIDIFind",0.68)

  -- search box
  local search = corner(make("TextBox", { Parent=win, Size=UDim2.new(1,-20,0,28),
    Position=UDim2.new(0,10,0,64), BackgroundColor3=C(38,41,48), TextColor3=C(220,225,235),
    PlaceholderText="Search... (press Enter)", Text="", Font=Enum.Font.Gotham, TextSize=14,
    ClearTextOnFocus=false }))

  -- results list
  local list = corner(make("ScrollingFrame", { Parent=win, Size=UDim2.new(1,-20,0,190),
    Position=UDim2.new(0,10,0,98), BackgroundColor3=C(18,20,24), BorderSizePixel=0,
    ScrollBarThickness=6, CanvasSize=UDim2.new() }))
  local layout = make("UIListLayout", { Parent=list, Padding=UDim.new(0,4),
    SortOrder=Enum.SortOrder.LayoutOrder })

  -- status
  local status = make("TextLabel", { Parent=win, Size=UDim2.new(1,-20,0,32),
    Position=UDim2.new(0,10,0,292), BackgroundTransparency=1, Text="Loading collection...",
    TextColor3=C(120,220,170), Font=Enum.Font.Gotham, TextSize=13, TextWrapped=true,
    TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top })
  setStatus = function(t) status.Text = t end

  -- ##### TUNABLES: exact typed numbers (no sliders) #####
  make("TextLabel", { Parent=win, Size=UDim2.new(0,46,0,26), Position=UDim2.new(0,10,0,328),
    BackgroundTransparency=1, Text="Tempo", TextColor3=C(200,205,215),
    Font=Enum.Font.Gotham, TextSize=13, TextXAlignment=Enum.TextXAlignment.Left })
  local tempoBox = corner(make("TextBox", { Parent=win, Size=UDim2.new(0,56,0,26),
    Position=UDim2.new(0,58,0,328), BackgroundColor3=C(38,41,48), TextColor3=C(225,230,240),
    Text=string.format("%.2f", State.speed), Font=Enum.Font.Gotham, TextSize=13,
    ClearTextOnFocus=false }), 5)
  make("TextLabel", { Parent=win, Size=UDim2.new(0,52,0,26), Position=UDim2.new(0,126,0,328),
    BackgroundTransparency=1, Text="Hold(s)", TextColor3=C(200,205,215),
    Font=Enum.Font.Gotham, TextSize=13, TextXAlignment=Enum.TextXAlignment.Left })
  local holdBox = corner(make("TextBox", { Parent=win, Size=UDim2.new(0,60,0,26),
    Position=UDim2.new(0,182,0,328), BackgroundColor3=C(38,41,48), TextColor3=C(225,230,240),
    Text=string.format("%.3f", CONFIG.keyTap), Font=Enum.Font.Gotham, TextSize=13,
    ClearTextOnFocus=false }), 5)

  -- validate + clamp a typed number, writing the clean value back into the box
  local function numField(box, getCur, lo, hi, fmt, apply)
    box.FocusLost:Connect(function()
      local n = tonumber(box.Text)
      if n then
        if n < lo then n = lo elseif n > hi then n = hi end
        apply(n); box.Text = string.format(fmt, n)
      else
        box.Text = string.format(fmt, getCur())   -- revert invalid input
      end
    end)
  end
  numField(tempoBox, function() return State.speed end, 0.25, 3.0, "%.2f",
    function(n) State.speed = n end)
  numField(holdBox, function() return CONFIG.keyTap end, 0.005, 0.5, "%.3f",
    function(n) CONFIG.keyTap = n end)

  -- play / stop
  local playBtn = corner(make("TextButton", { Parent=win, Size=UDim2.new(0,145,0,34),
    Position=UDim2.new(0,10,0,362), BackgroundColor3=C(40,120,80), TextColor3=C(240,244,250),
    Text="Play", Font=Enum.Font.GothamBold, TextSize=14, AutoButtonColor=true }))
  local stopBtn = corner(make("TextButton", { Parent=win, Size=UDim2.new(0,145,0,34),
    Position=UDim2.new(0,165,0,362), BackgroundColor3=C(150,60,60), TextColor3=C(240,244,250),
    Text="Stop", Font=Enum.Font.GothamBold, TextSize=14, AutoButtonColor=true }))
  playBtn.MouseButton1Click:Connect(function()
    if State.prepared then startPlayback() else setStatus("Pick a song first.") end
  end)
  stopBtn.MouseButton1Click:Connect(stopPlayback)

  -- list population + search routing
  local repoFiles = {}
  local function populate(entries)
    for _,ch in ipairs(list:GetChildren()) do
      if ch:IsA("TextButton") then ch:Destroy() end
    end
    for i,entry in ipairs(entries) do
      local b = corner(make("TextButton", { Parent=list, Size=UDim2.new(1,-8,0,28),
        BackgroundColor3=C(34,37,44), TextColor3=C(225,230,240), Text="  "..entry.name,
        Font=Enum.Font.Gotham, TextSize=13, TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=i, TextTruncate=Enum.TextTruncate.AtEnd }), 5)
      b.MouseButton1Click:Connect(function() loadAndMaybePlay(entry, true) end)
    end
    list.CanvasSize = UDim2.new(0,0,0, layout.AbsoluteContentSize.Y + 8)
  end
  local function filterCollection(q)
    q = (q or ""):lower()
    local out = {}
    for _,e in ipairs(repoFiles) do
      if q == "" or e.name:lower():find(q, 1, true) then out[#out+1] = e end
    end
    populate(out)
  end
  local function runSearch()
    local q = search.Text
    if State.source == "collection" then
      filterCollection(q); setStatus(#repoFiles.." in collection.")
    elseif q == "" then
      setStatus("Type a search and press Enter.")
    else
      local siteName = (State.source == "bitmidi") and "BitMidi" or "MIDIFind"
      setStatus("Searching "..siteName.."...")
      Adapter.spawn(function()
        local files, err
        if State.source == "bitmidi" then files, err = searchBitMidi(q)
        else files, err = searchMidiFind(q) end
        if not files then setStatus(tostring(err)); populate({}); return end
        populate(files); setStatus(#files.." results for '"..q.."'.")
      end)
    end
  end

  bCol.MouseButton1Click:Connect(function() setSource("collection"); filterCollection(search.Text); setStatus(#repoFiles.." in collection.") end)
  bBit.MouseButton1Click:Connect(function() setSource("bitmidi"); populate({}); setStatus("BitMidi: type a search and press Enter.") end)
  bMid.MouseButton1Click:Connect(function() setSource("midifind"); populate({}); setStatus("MIDIFind: type a search and press Enter.") end)
  setSource("collection")

  search.FocusLost:Connect(function(enterPressed) if enterPressed then runSearch() end end)
  search:GetPropertyChangedSignal("Text"):Connect(function()
    if State.source == "collection" then filterCollection(search.Text) end
  end)

  -- load the collection once, at startup
  Adapter.spawn(function()
    local files, err = listSongs()
    if not files then setStatus("Collection error: "..tostring(err)); return end
    repoFiles = files
    if State.source == "collection" then populate(files) end
    setStatus(#files.." songs in your collection. Pick one to play.")
  end)
end

buildGui()
