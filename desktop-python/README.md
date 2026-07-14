# MIDI → Virtual Piano Player

Load a `.mid` file — either **Browse** to a file on your PC or paste a **URL** — then
switch to your piano game and press **F6** to play it as keystrokes. **F7** or **Esc** stops.

Two files:
- `midi_piano_player.py` — the GUI app + keystroke output (Windows).
- `piano_core.py` — fetch / parse / mapping logic (must sit next to the app).

## Run it (quick test, no build)

```bat
pip install mido
python midi_piano_player.py
```

## Build a standalone .exe

Run this **on your Windows machine** (PyInstaller builds are OS-specific):

```bat
pip install pyinstaller mido
pyinstaller --onefile --windowed --name MidiPianoPlayer midi_piano_player.py
```

The `.exe` lands in the `dist\` folder. `piano_core.py` is bundled automatically
because the app imports it.

> Tip: some games only accept synthetic keystrokes when the sender runs with the
> same privileges as the game. If keys don't register, run the `.exe` as
> Administrator.

## How to use

1. Load a MIDI file one of two ways:
   - Click **Browse...** and pick a `.mid` / `.midi` file from your computer, **or**
   - Paste a direct link to a `.mid` file and click **Load**.

   Either way it shows how many chords/notes it found and the length.
2. Optionally set **Transpose** (shift octaves/keys), **Speed**, or **Skip drums**.
3. Click into the piano game window.
4. Press **F6**. There's a 3-second countdown, then it plays. **F7/Esc** stops.

## Search tab

Don't have a file or link? Use the **Search** tab to find one:

1. Type a song name and press **Search** (or Enter).
2. Results come from two public archives -- **BitMidi** and **Midifind** --
   which you can toggle with the **Sources** checkboxes. Duplicates are merged
   across sources (keeping the most-played copy), and with **Sort by plays**
   ticked the most popular (usually most accurate) versions rise to the top.
3. Double-click a result (or select it and click **Load selected**). It
   downloads, jumps to the Player tab, loads, and is added to **Recent** -- then
   just press F6.

Notes:
- These are community archives, so you'll often see several versions of the same
  song; pick by name / play count.
- If a site is down or changes its layout, that source may return an error in
  the log -- the other source still works, and searching never crashes the app.

## Recent tab

Every file or URL you successfully load is saved to the **Recent** tab. Switch
to it, double-click any entry to reload it instantly (no re-pasting), or use
**Load selected / Remove / Clear all**. The list is newest-first, de-duplicated,
and persists between runs in `.midi_piano_recent.json` in your home folder.

## Song title & your own folder

When a file loads, the app shows the **song title** -- read from the MIDI's
embedded name, or failing that from a tidy version of the filename/URL. Titles
also appear in the **Recent** list so entries are readable instead of raw links.

The **Search** tab has a **My folder** source that scans a local directory for
`.mid`/`.midi` files by name (subfolders included). It defaults to
`Downloads\Midi Files`; use **Change...** to point it anywhere. Leave the search
box empty with **My folder** ticked to list every MIDI in that folder.

## Timer overlay

While a song plays, a small always-on-top readout follows your mouse showing
`elapsed / total  -remaining` -- handy when you're focused on the game window.
It sits just below-right of the cursor so it never blocks your clicks, and
hides itself when nothing is playing. Turn it off with the **Timer overlay**
checkbox on the Player tab.

## MuseScore helper (optional)

On the **Player** tab there's a small "MuseScore helper" box. Paste a MuseScore
score link and click **Open in nanomidi** -- it copies the link and opens
nanomidi's downloader in your browser. Download the `.mid` there, then use
**Browse** to load it. (It's just a shortcut to that external tool; the app
doesn't download from MuseScore itself.)

## Key mapping

Uses the **virtualpiano.net standard** (what almost every Roblox piano, including
"Digital Piano", copies): 61 keys, C2–C7, white notes on
`1234567890 qwertyuiop asdfghjkl zxcvbnm`, and each sharp = **Shift + the white
key just below it**.

If your game's lowest key isn't C2, open `piano_core.py` and change one line:

```python
LOWEST_MIDI = 36    # 36 = C2.  Try 48 for C3, 24 for C1, etc.
```

Notes outside the 61-key range are automatically folded into range by octaves.

## Tuning (top of `midi_piano_player.py`)

| Setting | Meaning |
|---|---|
| `COUNTDOWN_SECONDS` | delay after F6 before playing |
| `KEY_TAP_SECONDS`   | how long each key is held |
| `CHORD_WINDOW`      | notes within this many seconds = one chord |
| `START_VK/STOP_VK`  | hotkey virtual-key codes (F6=0x75, F7=0x76) |

## Troubleshooting

- **"not a MIDI file"** → the link returned a web page (not raw `.mid` bytes), or
  the local file isn't a real MIDI. Use a direct file link (often a "download"
  URL), or pick the file with **Browse...**.
- **Keys don't register in the game** → run as Administrator. The app already
  uses hardware scan codes (the same low-level path AutoHotkey uses), which is
  the most game-compatible method.
- **Timing drifts on fast songs** → it shouldn't; playback locks each note to an
  absolute clock rather than accumulating sleeps. If a game stutters, lower
  `KEY_TAP_SECONDS` slightly.
