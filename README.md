# MIDI → Virtual Piano

Play MIDI files as a virtual piano (virtualpiano.net layout). Two editions:

## 1. `desktop-python/` — Windows desktop auto-player
The full-featured original. Loads a `.mid` from a file, URL, or built-in search
(BitMidi / Midifind / a local folder), then **types the notes as keystrokes** so
any on-screen/virtual piano that reads the keyboard plays along. Includes a
mouse-following timer overlay, song-title detection, recent list, and more.
See [`desktop-python/README.md`](desktop-python/README.md). Windows only
(uses `SendInput`). Run with `run.vbs` / `run.bat` or `python midi_piano_player.py`.

## 2. `lua-love2d/` — cross-platform Lua (LÖVE) player
A standalone [LÖVE](https://love2d.org) app in Lua that runs on desktop **and
mobile**. It creates a `MidiFiles/` folder, searches it, and plays the selected
MIDI on a **touch** on-screen piano. See
[`lua-love2d/README.md`](lua-love2d/README.md).

> The Lua edition is a self-contained *player* — it does not (and on a normal
> device cannot) inject keypresses into another game. Reading a local MIDI folder
> from inside a Roblox-style Lua game requires a third-party exploit executor,
> which violates those platforms' terms and is intentionally not included.

## Layout
```
desktop-python/   Windows keystroke auto-player (Python + tkinter)
lua-love2d/       Cross-platform LÖVE player (Lua)
```

## License
MIT — see [LICENSE](LICENSE).
