-- init.lua -- glue + configuration for the MIDI -> Virtual Piano autoplayer.
--
-- WHAT THIS DOES
--   1. Lists the .mid files in your GitHub repo "Jonah-Midi-Collection".
--   2. Downloads the one you choose.
--   3. Plays it by sending keyboard inputs to the game's virtual piano.
--
-- HOW TO USE
--   * Fill in the BACKEND section below with your environment's real functions
--     for HTTP, timing, and keyboard input (examples are provided).
--   * Set CONFIG.pick to the song you want (by number or name), or wire
--     M.chooseAndPlay into your own menu/UI.
--   * require("init") (or paste these files in) and call M.run().

local Remote   = require("remote")
local Autoplay = require("autoplay")

local M = {}

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
  pick = 1,          -- default song: a number (1 = first), or a name substring
                     -- e.g. pick = "nineteen"  or  pick = "in the pool"
  skip_drums = true, -- ignore channel-10 percussion
}

-- ============================================================================
-- BACKEND  --  wire these to YOUR environment. Replace the bodies as needed.
-- ============================================================================
local backend = {}

-- ---- HTTP -------------------------------------------------------------------
-- Must return the response BODY as a string (or nil, errmsg). Needs HTTPS.
-- Example A: LuaSocket + LuaSec (standard Lua):
--   local https = require("ssl.https")
--   function backend.httpGet(url) local b,c = https.request(url)
--     if c ~= 200 then return nil, "HTTP "..tostring(c) end return b end
-- Example B: many game/mod runtimes expose their own request function, e.g.
--   function backend.httpGet(url) return game:HttpGet(url) end   -- (example)
function backend.httpGet(url)
  -- TODO: replace with your environment's HTTPS GET.
  error("backend.httpGet not wired up yet -- see examples above")
end

-- ---- timing -----------------------------------------------------------------
-- now(): seconds as a number.   sleep(s): wait s seconds (yield if coroutine).
-- Example (LuaSocket):  local socket = require("socket")
--   function backend.now() return socket.gettime() end
--   function backend.sleep(s) socket.sleep(s) end
function backend.now()   return os.clock() end
function backend.sleep(s)
  -- Fallback busy-wait (works anywhere, but a real sleep/yield is better):
  local t = os.clock() + s
  while os.clock() < t do end
end

-- ---- keyboard ---------------------------------------------------------------
-- Send a single virtual-piano key (a plain character like "t", "q", "5").
-- Sharps/black keys are Shift + the natural key, handled via shiftDown/Up.
--
-- Example A: a runtime that exposes press/release by character:
--   function backend.keyDown(c) keyboard.press(c) end
--   function backend.keyUp(c)   keyboard.release(c) end
--   function backend.shiftDown() keyboard.press("shift") end
--   function backend.shiftUp()   keyboard.release("shift") end
--
-- Example B: Logitech-style API (PressKey/ReleaseKey by key name):
--   function backend.keyDown(c) PressKey(c) end
--   function backend.keyUp(c)   ReleaseKey(c) end
--   function backend.shiftDown() PressKey("lshift") end
--   function backend.shiftUp()   ReleaseKey("lshift") end
--
-- Example C: LuaJIT + Windows SendInput (scan codes) -- see backend_windows.lua.
function backend.keyDown(c)    error("backend.keyDown not wired up yet") end
function backend.keyUp(c)      error("backend.keyUp not wired up yet") end
function backend.shiftDown()   error("backend.shiftDown not wired up yet") end
function backend.shiftUp()     error("backend.shiftUp not wired up yet") end

-- optional: where status messages go (defaults to print)
backend.log = function(msg) print("[autoplay] " .. tostring(msg)) end

M.backend = backend

-- ============================================================================
-- FLOW
-- ============================================================================

-- fetch + print the available songs; returns the list
function M.listSongs()
  local files, err = Remote.list(backend.httpGet)
  if not files then backend.log("List failed: " .. err); return nil end
  backend.log(("%d songs in %s/%s:"):format(#files, Remote.OWNER, Remote.REPO))
  for i, f in ipairs(files) do backend.log(("  %2d. %s"):format(i, f.name)) end
  return files
end

-- resolve CONFIG.pick (number or name substring) against a listing
local function resolvePick(files, pick)
  if type(pick) == "number" then return files[pick] end
  local hits = Remote.search(files, tostring(pick))
  return hits[1]
end

-- the whole thing: list -> pick -> download -> play
function M.run()
  local files = M.listSongs()
  if not files then return end
  local entry = resolvePick(files, CONFIG.pick)
  if not entry then backend.log("Could not find a song for pick=" ..
                                tostring(CONFIG.pick)); return end
  backend.log("Downloading: " .. entry.name)
  local data, err = Remote.fetch(backend.httpGet, entry)
  if not data then backend.log("Download failed: " .. err); return end
  local prepared, perr = Autoplay.prepare(data, { skip_drums = CONFIG.skip_drums })
  if not prepared then backend.log("Parse failed: " .. perr); return end
  backend.log(("Loaded '%s' (%d chords). Switch to the game now."):format(
              entry.name, #prepared.schedule))
  Autoplay.play(prepared, backend)
end

-- play a specific song by name or index directly
function M.playSong(pickBy)
  CONFIG.pick = pickBy
  M.run()
end

return M
