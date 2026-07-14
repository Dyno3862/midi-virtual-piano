# MIDI → Virtual Piano

Play MIDI files as a virtual piano (virtualpiano.net layout). Two editions:

## 1. `desktop-python/` — Windows desktop auto-player
Loads a `.mid` from a file, URL, or built-in search (BitMidi / Midifind / a
local folder) and **types the notes as keystrokes** so any on-screen/virtual
piano that reads the keyboard plays along. Includes a mouse-following timer
overlay, song-title detection, a recent list, and more. Windows only (uses
`SendInput`). See [`desktop-python/README.md`](desktop-python/README.md). Run
with `run.vbs` / `run.bat` or `python midi_piano_player.py`.

## 2. `lua/` — in-game Lua autoplayer (remote MIDIs)
A Lua autoplayer meant to run **inside a Lua-scripted game**. It pulls MIDI
files straight from the GitHub repo
[`Jonah-Midi-Collection`](https://github.com/Dyno3862/Jonah-Midi-Collection)
(GitHub API + `raw.githubusercontent.com`), parses them, and **sends keyboard
inputs** to the game's virtual piano. No local folder — add `.mid` files to that
repo and they appear in the list. You wire three small adapter functions (HTTP,
timing, keyboard) to your environment; a ready-made LuaJIT/Windows keyboard
backend is included. See [`lua/README.md`](lua/README.md).

## Layout
```
desktop-python/   Windows keystroke auto-player (Python + tkinter)
lua/              In-game Lua autoplayer, streams MIDIs from GitHub
```

## License
MIT — see [LICENSE](LICENSE).
