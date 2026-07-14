# MIDI → Virtual Piano — LÖVE (Lua) edition

A standalone [LÖVE (Love2D)](https://love2d.org) app, written in Lua, that runs
on **Windows, macOS, Linux, Android and iOS**. It creates a `MidiFiles/` folder,
lets you **search** it, and plays a selected `.mid` on a **touch-friendly**
on-screen virtual-piano keyboard (same virtualpiano.net layout as the desktop
version).

## Important: what this is (and isn't)

This is its **own** music player — it parses and plays the MIDI itself, showing
the notes on an on-screen keyboard. It does **not** send keypresses into another
game. A Lua script running *inside* a Roblox-style game cannot read files off
your device (the game sandbox blocks filesystem access), so a "read a folder of
MIDIs and auto-press a game's piano" build isn't possible without a third-party
exploit executor — which violates those platforms' terms and isn't something
included here.

## Run it

1. Install LÖVE 11.x from https://love2d.org.
2. Run the `lua-love2d` folder with LÖVE:
   - **Desktop:** drag the folder onto the LÖVE app, or `love path/to/lua-love2d`.
   - **Android:** install the LÖVE app from the store, zip the folder's *contents*
     as `game.love`, and open it with LÖVE (see love2d wiki "Game Distribution").
3. The app shows the exact **MidiFiles** folder path on screen. Drop `.mid`
   files there, then tap **Refresh**.

## Using it

- **Search** box filters the file list as you type.
- Tap a file to open the player: **Play / Pause / Stop**, a progress bar, and the
  keyboard highlighting each note as it plays (with tones).
- Landscape orientation is recommended on phones — the 36-key keyboard is wide.

## Files

| File | Role |
|---|---|
| `main.lua`    | UI, folder browser/search, playback engine, on-screen piano |
| `midi.lua`    | Pure-Lua Standard MIDI File parser (tempo, tracks, drums) |
| `mapping.lua` | MIDI-note → virtualpiano key map + note frequencies |
| `conf.lua`    | Window / mobile orientation config |

## Notes

- Playback uses simple generated sine tones (no external soundfont), so it's
  self-contained but not orchestral. The key-mapping/timing matches the desktop
  player.
- The MIDI parser handles format 0/1, variable-length timing, tempo changes and
  skips channel-10 drums. SMPTE-division files are approximated.
