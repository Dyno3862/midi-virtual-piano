# MIDI → Virtual Piano — Lua in-game autoplayer

A Lua autoplayer that pulls MIDI files from your GitHub repo
[`Jonah-Midi-Collection`](https://github.com/Dyno3862/Jonah-Midi-Collection),
parses them, and **sends keyboard inputs** to your game's virtual piano
(virtualpiano.net layout — the same mapping as the desktop version).

There is **no local folder** — the song list comes straight from the repo, so
you just add `.mid` files to `Jonah-Midi-Collection` on GitHub and they show up.

## Files
| File | Role |
|---|---|
| `init.lua`            | Config + **backend adapters** (wire your env here) + flow |
| `remote.lua`         | Lists/downloads MIDIs from the GitHub repo |
| `autoplay.lua`       | Builds the schedule and sends the keystrokes |
| `midi.lua`           | Pure-Lua MIDI parser (tempo, tracks, drums) |
| `mapping.lua`        | MIDI note → virtual-piano key map |
| `backend_windows.lua`| Ready-made LuaJIT/Windows keyboard backend (SendInput) |

## Wiring it to your environment (the only part you edit)

Open `init.lua` and fill in the **BACKEND** section with your environment's real
functions. Three things are needed:

1. **HTTP (HTTPS GET)** — `backend.httpGet(url)` returns the response body.
   Examples for LuaSocket/LuaSec and for game runtimes that expose their own
   request function are in the file.
2. **Timing** — `backend.now()` / `backend.sleep(s)`.
3. **Keyboard** — `keyDown/keyUp/shiftDown/shiftUp`. Sharps are Shift + the
   natural key. If you're on **LuaJIT/Windows**, you can use the included
   `backend_windows.lua` as-is:
   ```lua
   local kb = require("backend_windows")
   backend.keyDown, backend.keyUp = kb.keyDown, kb.keyUp
   backend.shiftDown, backend.shiftUp = kb.shiftDown, kb.shiftUp
   backend.now, backend.sleep = kb.now, kb.sleep
   ```

## Playing

```lua
local M = require("init")
M.listSongs()            -- print the songs in the repo
M.playSong("nineteen")   -- play by name substring...
M.playSong(1)            -- ...or by number
```

`Autoplay.play` counts down 3 seconds (switch to the game), then streams the
notes as keystrokes locked to a real clock. Tune `KEY_TAP`, `CHORD_GAP`,
`COUNTDOWN` at the top of `autoplay.lua`.

## How the pieces connect
```
GitHub repo (Jonah-Midi-Collection)
   │  GitHub contents API  (remote.list)      → song list
   │  raw.githubusercontent (remote.fetch)    → .mid bytes
   ▼
midi.lua  → note events → mapping.lua → chord schedule (autoplay.prepare)
   ▼
autoplay.play → backend.keyDown/keyUp/shift  → your game's virtual piano
```

> This is an automation/bot for a game you control where scripted keyboard input
> is allowed. Make sure that's true for your target game before using it.
