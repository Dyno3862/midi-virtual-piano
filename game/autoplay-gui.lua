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
  transpose = 0,                    -- semitone offset applied before mapping (-24..24)
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

local function buildSchedule(events, chordWindow, transpose)
  chordWindow = chordWindow or 0.03
  transpose = transpose or 0
  local sched = {}
  local i,N = 1,#events
  while i <= N do
    local startT = events[i].t
    local seen,keys = {},{}
    while i <= N and (events[i].t-startT) <= chordWindow do
      local folded = foldNote(events[i].note + transpose)
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
                prepared = nil, current = nil, playToken = 0, playStart = 0 }
local setStatus     -- forward decl (GUI wires this)
local onPlayStart   -- forward decl: GUI hook, auto-minimizes the menu on play

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
  if setStatus then setStatus("\u{25B6} Playing "..(State.current and State.current.name or "")) end
  local sched = buildSchedule(State.prepared.events, 0.03, CONFIG.transpose)
  State.playStart = Adapter.now()
  local start = State.playStart
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
    if errMsg then setStatus("\u{26A0} " .. tostring(errMsg))
    elseif State.stop then setStatus("\u{23F9} Stopped")
    else setStatus("\u{2714} Finished") end
  end
end

local function startPlayback()
  if not State.prepared then return end
  if onPlayStart then pcall(onPlayStart) end     -- auto-minimize the menu
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
    local total = (events[#events] and events[#events].t) or 0
    State.prepared = { events = events, total = total }
    State.current = entry
    local preview = buildSchedule(events, 0.03, CONFIG.transpose)
    if setStatus then setStatus("Loaded: "..entry.name.." ("..#preview.." chords)") end
    if autoplay then startPlayback() end
  end)
end

-- ===========================================================================
-- GUI  (Roblox). If you're on a different engine, replace this block; the
-- engine-agnostic core above (parse/map/fetch/autoplay) stays the same.
-- ===========================================================================
-- device detection: MOBILE = touch AND no physical keyboard, so a touch laptop
-- (touch + keyboard) stays on desktop. Console (ten-foot UI) uses desktop too.
local function detectMobile()
  local UIS = game:GetService("UserInputService")
  local okC, isConsole = pcall(function()
    return game:GetService("GuiService"):IsTenFootInterface()
  end)
  if okC and isConsole then return false end
  local touch = UIS.TouchEnabled
  local kb    = UIS.KeyboardEnabled
  local mouse = UIS.MouseEnabled
  if touch and (not kb) then return true end            -- primary signal
  local vpX = 1000
  local cam = workspace.CurrentCamera
  if cam then vpX = cam.ViewportSize.X end
  if touch and (not mouse) and vpX <= 900 then return true end   -- tablet fallback
  return false
end

-- layout constants: DESKTOP = original values (unchanged); MOBILE = compact
-- panel with finger-sized targets and larger fonts. The GUI build reads L.*,
-- so there is only ONE build path for both.
local DESKTOP = {
  pad=12, gap=10, corner=8, cornerSm=6, scrollBar=8,
  panelW=580, panelH=480, panelX=60, panelY=60,
  titleBarH=36, titleFont=17, winBtn=26,
  sidebarW=150, tabItemH=48, tabFont=15,
  cardTitleFont=17, cardSubFont=12, cardTextFont=15,
  statusCardH=66, urlCardH=64, filesCardH=300,
  srcH=30, srcFont=13, searchH=32, searchFont=15,
  ddBtnH=30, ddPanelH=200, rowH=32, rowFont=14,
  actionH=44, actionFont=15,
  fieldH=36, fieldFont=15, fieldLabelW=210, fieldBoxW=90,
  toggleH=36, toggleFont=15, toggleBtnW=66,
  inputW=220, fabSize=58, fabX=60, fabY=60, remFont=28,
}
local MOBILE = {
  pad=6, gap=5, corner=8, cornerSm=6, scrollBar=5,
  panelW=272, panelH=250, panelX=8, panelY=8,
  titleBarH=24, titleFont=12, winBtn=18,
  sidebarW=78, tabItemH=32, tabFont=10,
  cardTitleFont=12, cardSubFont=9, cardTextFont=11,
  statusCardH=46, urlCardH=44, filesCardH=126,
  srcH=20, srcFont=9, searchH=22, searchFont=11,
  ddBtnH=24, ddPanelH=120, rowH=24, rowFont=11,
  actionH=28, actionFont=11,
  fieldH=26, fieldFont=11, fieldLabelW=96, fieldBoxW=52,
  toggleH=26, toggleFont=10, toggleBtnW=44,
  inputW=104, fabSize=44, fabX=8, fabY=8, remFont=18,
}
local IS_MOBILE = detectMobile()
local L = IS_MOBILE and MOBILE or DESKTOP

local function buildGui()
  local UIS = game:GetService("UserInputService")
  local RunService = game:GetService("RunService")
  local Players = game:GetService("Players")
  local plr = Players.LocalPlayer
  local parent = plr and plr:WaitForChild("PlayerGui") or game:GetService("CoreGui")
  local C = Color3.fromRGB
  local pad, gap = L.pad, L.gap
  -- palette
  local PANEL   = C(30,30,30)
  local SIDEBAR = C(24,24,24)
  local CARD    = C(42,42,42)
  local INPUT   = C(52,52,52)
  local HILITE  = C(58,58,62)
  local TXT     = C(240,240,242)
  local MUTED   = C(158,158,164)
  local ACCENT  = C(96,170,132)
  local DANGER  = C(158,74,74)

  local function make(cls, props)
    local o = Instance.new(cls)
    for k,v in pairs(props or {}) do o[k]=v end
    return o
  end
  local function corner(o, r)
    local u = Instance.new("UICorner"); u.CornerRadius = UDim.new(0, r or L.corner); u.Parent = o
    return o
  end
  local function makeDraggable(handle, target, onTap)
    target = target or handle
    local dragging, moved, startInput, startPos
    handle.InputBegan:Connect(function(input)
      if input.UserInputType == Enum.UserInputType.MouseButton1
         or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; moved = false
        startInput = input.Position; startPos = target.Position
        input.Changed:Connect(function()
          if input.UserInputState == Enum.UserInputState.End then
            dragging = false
            if (not moved) and onTap then onTap() end
          end
        end)
      end
    end)
    UIS.InputChanged:Connect(function(input)
      if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                       or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - startInput
        if math.abs(d.X) + math.abs(d.Y) > 6 then moved = true end
        target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                    startPos.Y.Scale, startPos.Y.Offset + d.Y)
      end
    end)
  end

  local sg = make("ScreenGui", { Name="MidiAutoplay", ResetOnSpawn=false, IgnoreGuiInset=true })
  sg.Parent = parent

  -- top-right live remaining-time overlay
  local remLabel = make("TextLabel", { Parent=sg, Size=UDim2.new(0,90,0,30),
    AnchorPoint=Vector2.new(1,0), Position=UDim2.new(1,-8,0,8), BackgroundColor3=C(18,18,18),
    BackgroundTransparency=0.15, TextColor3=ACCENT, Font=Enum.Font.GothamBold,
    TextSize=L.remFont, Text="0:00", Visible=false })
  corner(remLabel, 6)

  -- draggable floating button (tap to re-open)
  local fab = make("TextButton", { Parent=sg, Size=UDim2.new(0,L.fabSize,0,L.fabSize),
    Position=UDim2.new(0,L.fabX,0,L.fabY), BackgroundColor3=ACCENT, TextColor3=C(20,20,20),
    Text="\u{266A}", Font=Enum.Font.GothamBold, TextSize=math.floor(L.fabSize*0.5),
    AutoButtonColor=true, Visible=false })
  corner(fab, math.floor(L.fabSize/2))

  -- panel
  local win = make("Frame", { Parent=sg, BackgroundColor3=PANEL, BorderSizePixel=0,
    Position=UDim2.new(0,L.panelX,0,L.panelY), Size=UDim2.new(0,L.panelW,0,L.panelH) })
  corner(win, L.corner)

  -- ===== title bar =====
  local titleBar = make("Frame", { Parent=win, BackgroundTransparency=1, Active=true,
    Size=UDim2.new(1,0,0,L.titleBarH), Position=UDim2.new(0,0,0,0) })
  make("TextLabel", { Parent=titleBar, BackgroundTransparency=1, Text="MIDI Autoplay",
    Size=UDim2.new(1,-3*L.winBtn-pad*3,1,0), Position=UDim2.new(0,pad,0,0), TextColor3=TXT,
    Font=Enum.Font.GothamBold, TextSize=L.titleFont, TextXAlignment=Enum.TextXAlignment.Left })
  local function winBtn(order, glyph, col)
    local b = corner(make("TextButton", { Parent=titleBar, Size=UDim2.new(0,L.winBtn,0,L.winBtn),
      Position=UDim2.new(1,-pad-order*L.winBtn-(order-1)*4,0,math.floor((L.titleBarH-L.winBtn)/2)),
      BackgroundColor3=col or HILITE, TextColor3=TXT, Text=glyph, Font=Enum.Font.GothamBold,
      TextSize=L.titleFont, AutoButtonColor=true }), L.cornerSm)
    return b
  end
  local closeBtn = winBtn(1, "\u{2715}", DANGER)
  local maxBtn   = winBtn(2, "\u{25A1}")
  local minBtn   = winBtn(3, "\u{2013}")
  makeDraggable(titleBar, win, nil)

  -- ===== left sidebar =====
  local sidebar = make("Frame", { Parent=win, BackgroundColor3=SIDEBAR, BorderSizePixel=0,
    Position=UDim2.new(0,0,0,L.titleBarH), Size=UDim2.new(0,L.sidebarW,1,-L.titleBarH) })
  local tabButtons = {}
  local sy = gap
  local function sidebarItem(key, icon, label)
    local b = corner(make("TextButton", { Parent=sidebar, Size=UDim2.new(1,-2*gap,0,L.tabItemH),
      Position=UDim2.new(0,gap,0,sy), BackgroundColor3=HILITE, BackgroundTransparency=1,
      TextColor3=TXT, Text="  "..icon.."  "..label, Font=Enum.Font.GothamMedium,
      TextSize=L.tabFont, TextXAlignment=Enum.TextXAlignment.Left, AutoButtonColor=false }), L.cornerSm)
    tabButtons[key] = b; sy = sy + L.tabItemH + gap
    return b
  end
  local tabMain     = sidebarItem("main", "\u{25A3}", "Main")
  local tabSettings = sidebarItem("settings", "\u{2699}", "Settings")

  -- ===== content area (right) =====
  local content = make("Frame", { Parent=win, BackgroundTransparency=1,
    Position=UDim2.new(0,L.sidebarW,0,L.titleBarH), Size=UDim2.new(1,-L.sidebarW,1,-L.titleBarH) })
  local function newPage()
    local sfr = make("ScrollingFrame", { Parent=content, BackgroundTransparency=1, BorderSizePixel=0,
      Size=UDim2.new(1,-2*pad,1,-2*pad), Position=UDim2.new(0,pad,0,pad),
      ScrollBarThickness=L.scrollBar, CanvasSize=UDim2.new() })
    local lay = make("UIListLayout", { Parent=sfr, Padding=UDim.new(0,gap), SortOrder=Enum.SortOrder.LayoutOrder })
    lay:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
      sfr.CanvasSize = UDim2.new(0,0,0, lay.AbsoluteContentSize.Y + gap)
    end)
    return sfr
  end
  local mainPage = newPage()
  local settingsPage = newPage(); settingsPage.Visible = false

  local function newCard(parent, order, h)
    return corner(make("Frame", { Parent=parent, Size=UDim2.new(1,-L.scrollBar-2,0,h),
      BackgroundColor3=CARD, BorderSizePixel=0, LayoutOrder=order }), L.corner)
  end
  local function cardLabel(card, txt, x, yy, w, font, colr, bold, align)
    return make("TextLabel", { Parent=card, BackgroundTransparency=1, Text=txt,
      Position=UDim2.new(0,x,0,yy), Size=UDim2.new(0,w,0,font+4), TextColor3=colr or TXT,
      Font=bold and Enum.Font.GothamBold or Enum.Font.Gotham, TextSize=font,
      TextXAlignment=align or Enum.TextXAlignment.Left, TextTruncate=Enum.TextTruncate.AtEnd })
  end

  -- ---- MAIN: status card ----
  local statusCard = newCard(mainPage, 1, L.statusCardH)
  cardLabel(statusCard, "Status", pad, pad, 200, L.cardTitleFont, TXT, true)
  local stateLbl = cardLabel(statusCard, "\u{23F9} Stopped", pad, pad+L.cardTitleFont+4,
    L.panelW, L.cardTextFont, MUTED, false)
  setStatus = function(t) stateLbl.Text = t end

  -- ---- MAIN: URL / filename card ----
  local urlCard = newCard(mainPage, 2, L.urlCardH)
  cardLabel(urlCard, "URL or Filename", pad, math.floor((L.urlCardH-L.cardTextFont)/2)-2,
    L.panelW-L.inputW-3*pad, L.cardTextFont, TXT, false)
  local urlBox = corner(make("TextBox", { Parent=urlCard, Size=UDim2.new(0,L.inputW,0,L.urlCardH-2*pad),
    Position=UDim2.new(1,-pad-L.inputW,0,pad), BackgroundColor3=INPUT, TextColor3=TXT,
    PlaceholderText="paste .mid URL / name", Text="", Font=Enum.Font.Gotham, TextSize=L.cardTextFont,
    ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Left }), L.cornerSm)

  -- ---- MAIN: MIDI files card (sources + search + dropdown) ----
  local filesCard = newCard(mainPage, 3, L.filesCardH)
  cardLabel(filesCard, "MIDI Files", pad, pad, 200, L.cardTitleFont, TXT, true)
  cardLabel(filesCard, "Choose from your collection", pad, pad+L.cardTitleFont+2, L.panelW,
    L.cardSubFont, MUTED, false)
  local fy = pad + L.cardTitleFont + L.cardSubFont + 6
  local innerCW = L.panelW - L.sidebarW - 2*pad - L.scrollBar - 2*pad
  State.source = "collection"
  local srcRow = make("Frame", { Parent=filesCard, BackgroundTransparency=1,
    Size=UDim2.new(1,-2*pad,0,L.srcH), Position=UDim2.new(0,pad,0,fy) })
  local srcButtons = {}
  local function setSource(src)
    State.source = src
    for k,b in pairs(srcButtons) do b.BackgroundColor3 = (k==src) and ACCENT or HILITE end
  end
  local function mkSrc(key,label,xs)
    local b = corner(make("TextButton", { Parent=srcRow, Size=UDim2.new(0.32,0,1,0),
      Position=UDim2.new(xs,0,0,0), BackgroundColor3=HILITE, TextColor3=TXT, Text=label,
      Font=Enum.Font.Gotham, TextSize=L.srcFont, AutoButtonColor=true }), L.cornerSm)
    srcButtons[key]=b; return b
  end
  local bCol = mkSrc("collection","Coll",0)
  local bBit = mkSrc("bitmidi","Bit",0.34)
  local bMid = mkSrc("midifind","Find",0.68)
  fy = fy + L.srcH + gap
  local search = corner(make("TextBox", { Parent=filesCard, Size=UDim2.new(1,-2*pad,0,L.searchH),
    Position=UDim2.new(0,pad,0,fy), BackgroundColor3=INPUT, TextColor3=TXT,
    PlaceholderText="Search... (Enter)", Text="", Font=Enum.Font.Gotham, TextSize=L.searchFont,
    ClearTextOnFocus=false }), L.cornerSm)
  fy = fy + L.searchH + gap
  -- song picker: desktop = tall inline scrollable list (all songs); mobile = dropdown
  local resultsContainer, resultsLayout
  local ddBtn, ddPanel, ddLayout
  local ddOpen = false
  if IS_MOBILE then
    ddBtn = corner(make("TextButton", { Parent=filesCard, Size=UDim2.new(1,-2*pad,0,L.ddBtnH),
      Position=UDim2.new(0,pad,0,fy), BackgroundColor3=INPUT, TextColor3=TXT,
      Text="  Select a song  \u{25BE}", Font=Enum.Font.Gotham, TextSize=L.searchFont,
      TextXAlignment=Enum.TextXAlignment.Left, AutoButtonColor=true }), L.cornerSm)
    ddPanel = make("ScrollingFrame", { Parent=sg, Visible=false, BackgroundColor3=CARD,
      BorderSizePixel=0, ScrollBarThickness=L.scrollBar, CanvasSize=UDim2.new(), ZIndex=5 })
    corner(ddPanel, L.cornerSm)
    ddLayout = make("UIListLayout", { Parent=ddPanel, Padding=UDim.new(0,2), SortOrder=Enum.SortOrder.LayoutOrder })
    resultsContainer, resultsLayout = ddPanel, ddLayout
  else
    local listH = L.filesCardH - fy - pad
    resultsContainer = corner(make("ScrollingFrame", { Parent=filesCard, BackgroundColor3=C(34,34,34),
      BorderSizePixel=0, ScrollBarThickness=L.scrollBar, CanvasSize=UDim2.new(),
      Size=UDim2.new(1,-2*pad,0,listH), Position=UDim2.new(0,pad,0,fy) }), L.cornerSm)
    resultsLayout = make("UIListLayout", { Parent=resultsContainer, Padding=UDim.new(0,3), SortOrder=Enum.SortOrder.LayoutOrder })
  end

  -- ---- MAIN: action buttons ----
  local function actionCard(order, label, icon, bg)
    local b = corner(make("TextButton", { Parent=mainPage, Size=UDim2.new(1,-L.scrollBar-2,0,L.actionH),
      BackgroundColor3=bg or CARD, TextColor3=TXT, Text="   "..label, Font=Enum.Font.GothamMedium,
      TextSize=L.actionFont, TextXAlignment=Enum.TextXAlignment.Left, AutoButtonColor=true,
      LayoutOrder=order }), L.corner)
    make("TextLabel", { Parent=b, BackgroundTransparency=1, Size=UDim2.new(0,26,1,0),
      Position=UDim2.new(1,-30,0,0), Text=icon, TextColor3=ACCENT, Font=Enum.Font.GothamBold,
      TextSize=L.actionFont+2 })
    return b
  end
  local loadBtn    = actionCard(4, "Load", "\u{2193}")
  local refreshBtn = actionCard(5, "Refresh File List", "\u{21BB}")
  local playBtn    = actionCard(6, "Play", "\u{25B6}")
  local stopBtn    = actionCard(7, "Stop", "\u{25A0}")

  -- ---- SETTINGS page ----
  local function numField(box, getCur, lo, hi, fmt, apply, isInt)
    box.FocusLost:Connect(function()
      local n = tonumber(box.Text)
      if n then
        if n < lo then n = lo elseif n > hi then n = hi end
        if isInt then n = math.floor(n + 0.5) end
        apply(n); box.Text = string.format(fmt, n)
      else box.Text = string.format(fmt, getCur()) end
    end)
  end
  local function settingRow(order, labelText, boxText)
    local cardH = L.fieldH + 2*pad
    local card = newCard(settingsPage, order, cardH)
    cardLabel(card, labelText, pad, math.floor((cardH-L.fieldFont)/2)-2, L.fieldLabelW, L.fieldFont, TXT, false)
    local box = corner(make("TextBox", { Parent=card, Size=UDim2.new(0,L.fieldBoxW,0,L.fieldH),
      Position=UDim2.new(1,-pad-L.fieldBoxW,0,pad), BackgroundColor3=INPUT, TextColor3=TXT,
      Text=boxText, Font=Enum.Font.Gotham, TextSize=L.fieldFont, ClearTextOnFocus=false }), L.cornerSm)
    return box
  end
  local transposeBox = settingRow(1, "Transpose (semitones)", string.format("%d", CONFIG.transpose))
  numField(transposeBox, function() return CONFIG.transpose end, -24, 24, "%d",
    function(n) CONFIG.transpose = n end, true)
  local speedBox = settingRow(2, "Speed (tempo)", string.format("%.2f", State.speed))
  numField(speedBox, function() return State.speed end, 0.25, 3.0, "%.2f",
    function(n) State.speed = n end)
  local prefsShowRemaining = false
  local togH = L.toggleH + 2*pad
  local togCard = newCard(settingsPage, 3, togH)
  cardLabel(togCard, "Show time left", pad, math.floor((togH-L.toggleFont)/2)-2,
    L.panelW, L.toggleFont, TXT, false)
  local remToggle = corner(make("TextButton", { Parent=togCard, Size=UDim2.new(0,L.toggleBtnW,0,L.toggleH),
    Position=UDim2.new(1,-pad-L.toggleBtnW,0,pad), BackgroundColor3=DANGER, TextColor3=TXT,
    Text="OFF", Font=Enum.Font.GothamBold, TextSize=L.toggleFont, AutoButtonColor=true }), L.cornerSm)
  remToggle.MouseButton1Click:Connect(function()
    prefsShowRemaining = not prefsShowRemaining
    remToggle.Text = prefsShowRemaining and "ON" or "OFF"
    remToggle.BackgroundColor3 = prefsShowRemaining and ACCENT or DANGER
  end)

  -- ===== tab switching =====
  local function setTab(name)
    mainPage.Visible = (name=="main")
    settingsPage.Visible = (name=="settings")
    for k,b in pairs(tabButtons) do b.BackgroundTransparency = (k==name) and 0 or 1 end
  end
  tabMain.MouseButton1Click:Connect(function() setTab("main") end)
  tabSettings.MouseButton1Click:Connect(function() setTab("settings") end)
  setTab("main")

  -- ===== window controls =====
  local function setMinimized(m) win.Visible = not m; fab.Visible = m; if m and ddPanel then ddPanel.Visible=false end end
  local maximized = false
  minBtn.MouseButton1Click:Connect(function() setMinimized(true) end)
  maxBtn.MouseButton1Click:Connect(function()
    maximized = not maximized
    if maximized then
      win.Size = UDim2.new(0, math.floor(L.panelW*1.35), 0, math.floor(L.panelH*1.35))
    else
      win.Size = UDim2.new(0, L.panelW, 0, L.panelH)
    end
  end)
  closeBtn.MouseButton1Click:Connect(function() sg.Enabled = false end)   -- clean close
  makeDraggable(fab, fab, function() setMinimized(false) end)
  onPlayStart = function() setMinimized(true) end

  -- ===== countdown =====
  RunService.Heartbeat:Connect(function()
    if State.playing and prefsShowRemaining and State.prepared then
      local dur = (State.prepared.total or 0) / (State.speed > 0 and State.speed or 1)
      local rem = dur - (Adapter.now() - (State.playStart or Adapter.now()))
      if rem < 0 then rem = 0 end
      remLabel.Text = string.format("%d:%02d", math.floor(rem/60), math.floor(rem % 60))
      remLabel.Visible = true
    else remLabel.Visible = false end
  end)

  -- ===== data: collection + search + dropdown =====
  local repoFiles = {}
  local currentResults = {}
  local selectedEntry = nil

  local function renderResults(entries)
    for _,ch in ipairs(resultsContainer:GetChildren()) do
      if ch:IsA("TextButton") then ch:Destroy() end
    end
    for i,entry in ipairs(entries) do
      local b = corner(make("TextButton", { Parent=resultsContainer, Size=UDim2.new(1,-L.scrollBar-2,0,L.rowH),
        BackgroundColor3=INPUT, TextColor3=TXT, Text=" "..entry.name, Font=Enum.Font.Gotham,
        TextSize=L.rowFont, TextXAlignment=Enum.TextXAlignment.Left, LayoutOrder=i,
        TextTruncate=Enum.TextTruncate.AtEnd, ZIndex=(IS_MOBILE and 6 or 1) }), L.cornerSm)
      b.MouseButton1Click:Connect(function()
        selectedEntry = entry
        if IS_MOBILE and ddPanel then ddBtn.Text = "  "..entry.name; ddOpen = false; ddPanel.Visible = false end
        loadAndMaybePlay(entry, false)
      end)
    end
    resultsContainer.CanvasSize = UDim2.new(0,0,0, resultsLayout.AbsoluteContentSize.Y + 4)
  end
  local function setResults(list)
    currentResults = list or {}
    if IS_MOBILE then
      if ddOpen then renderResults(currentResults) end
    else
      renderResults(currentResults)      -- desktop: always show the full list inline
    end
  end
  if IS_MOBILE then
    ddBtn.MouseButton1Click:Connect(function()
      ddOpen = not ddOpen
      if ddOpen then
        local ap = ddBtn.AbsolutePosition
        ddPanel.Position = UDim2.new(0, ap.X, 0, ap.Y + ddBtn.AbsoluteSize.Y + 2)
        ddPanel.Size = UDim2.new(0, ddBtn.AbsoluteSize.X, 0, L.ddPanelH)
        renderResults(currentResults); ddPanel.Visible = true
      else ddPanel.Visible = false end
    end)
  end

  local function filterCollection(q)
    q = (q or ""):lower()
    local out = {}
    for _,e in ipairs(repoFiles) do
      if q == "" or e.name:lower():find(q, 1, true) then out[#out+1] = e end
    end
    setResults(out)
  end
  local function runSearch()
    local q = search.Text
    if State.source == "collection" then
      filterCollection(q); setStatus(#currentResults.." in collection")
    elseif q == "" then setStatus("Type a search and press Enter.")
    else
      local site = (State.source=="bitmidi") and "BitMidi" or "MIDIFind"
      setStatus("Searching "..site.."...")
      Adapter.spawn(function()
        local files, err
        if State.source=="bitmidi" then files,err = searchBitMidi(q) else files,err = searchMidiFind(q) end
        if not files then setStatus(tostring(err)); setResults({}); return end
        setResults(files); setStatus(#files.." results")
      end)
    end
  end
  bCol.MouseButton1Click:Connect(function() setSource("collection"); filterCollection(search.Text) end)
  bBit.MouseButton1Click:Connect(function() setSource("bitmidi"); setResults({}); setStatus("BitMidi: search + Enter") end)
  bMid.MouseButton1Click:Connect(function() setSource("midifind"); setResults({}); setStatus("MIDIFind: search + Enter") end)
  setSource("collection")
  search.FocusLost:Connect(function(enter) if enter then runSearch() end end)
  search:GetPropertyChangedSignal("Text"):Connect(function()
    if State.source=="collection" then filterCollection(search.Text) end
  end)

  -- ===== load-from-input (URL or filename) =====
  local function loadFromInput(txt)
    txt = tostring(txt or ""):gsub("^%s+",""):gsub("%s+$","")
    if txt == "" then setStatus("Enter a URL or filename."); return end
    local entry
    if txt:lower():match("^https?://") then
      entry = { name = (txt:match("([^/]+)%.midi?$") or txt:match("([^/]+)$") or txt), url = txt }
    else
      for _,e in ipairs(repoFiles) do
        if e.name:lower():find(txt:lower(), 1, true) then entry = e; break end
      end
      if not entry then
        local fn = txt
        if not fn:lower():match("%.midi?$") then fn = fn..".mid" end
        entry = { name = txt, url = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(
          CONFIG.repoOwner, CONFIG.repoName, CONFIG.branch) .. urlencode(fn) }
      end
    end
    loadAndMaybePlay(entry, false)
  end

  -- ===== action buttons =====
  loadBtn.MouseButton1Click:Connect(function()
    if (search and urlBox.Text:gsub("%s","") ~= "") then loadFromInput(urlBox.Text)
    elseif selectedEntry then loadAndMaybePlay(selectedEntry, false)
    else setStatus("Pick a song or paste a URL.") end
  end)
  local function refreshList()
    setStatus("Refreshing...")
    Adapter.spawn(function()
      local files, err = listSongs()
      if not files then setStatus("Refresh failed: "..tostring(err)); return end
      repoFiles = files
      if State.source=="collection" then filterCollection(search.Text) end
      setStatus(#files.." songs in collection")
    end)
  end
  refreshBtn.MouseButton1Click:Connect(refreshList)
  playBtn.MouseButton1Click:Connect(function()
    if State.prepared then startPlayback() else setStatus("Load a song first.") end
  end)
  stopBtn.MouseButton1Click:Connect(stopPlayback)

  setMinimized(false)

  -- initial collection load
  Adapter.spawn(function()
    local files, err = listSongs()
    if not files then setStatus("Collection error: "..tostring(err)); return end
    repoFiles = files
    filterCollection("")
    setStatus(#files.." songs. Pick one.")
  end)
end

buildGui()
