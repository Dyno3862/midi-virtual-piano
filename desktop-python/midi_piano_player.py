"""
MIDI -> Virtual Piano Player
============================
Paste a link to a .mid file, click "Load", switch to your piano game, and press
F6 to play it as keystrokes. F7 (or Esc) stops.

Key output uses Windows SendInput with hardware SCAN CODES, which is what games
like Roblox pianos actually read -- the same low-level path AutoHotkey uses.

Requires: Python 3.9+, and `pip install mido`.  (Windows only.)
Build a standalone .exe with:
    pip install pyinstaller mido
    pyinstaller --onefile --windowed --name MidiPianoPlayer midi_piano_player.py
"""

import ctypes
import json
import os
import queue
import threading
import time
import webbrowser
import tkinter as tk
from ctypes import wintypes
from tkinter import ttk, filedialog

import piano_core as core

# ============================================================================
# SETTINGS  -- tweak these freely
# ============================================================================
START_VK = 0x75      # F6  -> start playback
STOP_VK  = 0x76      # F7  -> stop
ESC_VK   = 0x1B      # Esc -> also stops

COUNTDOWN_SECONDS = 3      # gives you time to click into the game after F6
KEY_TAP_SECONDS   = 0.012  # how long each key is held down (a virtual-piano tap)
CHORD_SPREAD      = 0.004  # tiny gap between the two halves of a mixed chord
CHORD_WINDOW      = 0.03   # notes within this many seconds count as one chord

# ============================================================================
# LOW-LEVEL KEYBOARD  (SendInput with scan codes -- best for games)
# ============================================================================
# Scan codes (Set 1) for exactly the keys the virtual-piano map can produce.
SCAN = {
    "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06,
    "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A, "0": 0x0B,
    "q": 0x10, "w": 0x11, "e": 0x12, "r": 0x13, "t": 0x14,
    "y": 0x15, "u": 0x16, "i": 0x17, "o": 0x18, "p": 0x19,
    "a": 0x1E, "s": 0x1F, "d": 0x20, "f": 0x21, "g": 0x22,
    "h": 0x23, "j": 0x24, "k": 0x25, "l": 0x26,
    "z": 0x2C, "x": 0x2D, "c": 0x2E, "v": 0x2F, "b": 0x30,
    "n": 0x31, "m": 0x32,
}
LSHIFT_SCAN = 0x2A

KEYEVENTF_SCANCODE = 0x0008
KEYEVENTF_KEYUP    = 0x0002
INPUT_KEYBOARD     = 1

_user32 = ctypes.WinDLL("user32", use_last_error=True)
_winmm  = ctypes.WinDLL("winmm")

# ULONG_PTR is 8 bytes on 64-bit Python, 4 on 32-bit -- WPARAM matches it.
ULONG_PTR = wintypes.WPARAM


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG),
                ("mouseData", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD),
                ("wParamH", wintypes.WORD)]


class _INPUTunion(ctypes.Union):
    # MUST include the larger members so sizeof(INPUT) matches what Windows
    # expects (40 bytes on 64-bit). Leaving only KEYBDINPUT here makes
    # SendInput reject every call and silently send nothing.
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTunion)]


_user32.SendInput.argtypes = (wintypes.UINT, ctypes.POINTER(INPUT),
                              ctypes.c_int)
_user32.SendInput.restype = wintypes.UINT
_user32.GetAsyncKeyState.argtypes = (ctypes.c_int,)
_user32.GetAsyncKeyState.restype = ctypes.c_short


def _send_scan(scan, keyup):
    """Send one scan-code key event. Returns 1 on success, 0 if Windows
    blocked it (e.g. game running elevated while we are not)."""
    flags = KEYEVENTF_SCANCODE | (KEYEVENTF_KEYUP if keyup else 0)
    inp = INPUT(type=INPUT_KEYBOARD)
    inp.ki = KEYBDINPUT(wVk=0, wScan=scan, dwFlags=flags, time=0,
                        dwExtraInfo=0)
    return _user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def send_chord(keys):
    """keys: list of (char, needs_shift). Play them as one virtual-piano hit.
    Returns how many key-down events Windows refused (0 == all delivered)."""
    fails = 0
    plain = [SCAN[c] for c, sh in keys if not sh and c in SCAN]
    sharp = [SCAN[c] for c, sh in keys if sh and c in SCAN]

    if plain:
        for s in plain:
            fails += 0 if _send_scan(s, False) else 1
        time.sleep(KEY_TAP_SECONDS)
        for s in plain:
            _send_scan(s, True)

    if sharp:
        if plain:
            time.sleep(CHORD_SPREAD)
        _send_scan(LSHIFT_SCAN, False)
        for s in sharp:
            fails += 0 if _send_scan(s, False) else 1
        time.sleep(KEY_TAP_SECONDS)
        for s in sharp:
            _send_scan(s, True)
        _send_scan(LSHIFT_SCAN, True)
    return fails


# ============================================================================
# PLAYBACK ENGINE
# ============================================================================
class Player:
    def __init__(self, log_fn):
        self.log = log_fn
        self.schedule = []
        self.total_s = 0.0        # full length in real playback seconds
        self.play_t0 = None       # perf_counter when notes actually start
        self._stop = threading.Event()
        self._thread = None

    @property
    def playing(self):
        return self._thread is not None and self._thread.is_alive()

    def load(self, schedule):
        self.schedule = schedule
        self.total_s = schedule[-1]["t"] if schedule else 0.0

    def position(self):
        """(elapsed, total) seconds while notes are playing, else None."""
        if self.play_t0 is None or not self.playing:
            return None
        elapsed = time.perf_counter() - self.play_t0
        return max(0.0, min(elapsed, self.total_s)), self.total_s

    def start(self):
        if self.playing or not self.schedule:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()

    def _run(self):
        # raise the OS timer resolution to ~1ms so sleeps are tight at fast tempos
        _winmm.timeBeginPeriod(1)
        sent = fails = 0
        warned = False
        try:
            for i in range(COUNTDOWN_SECONDS, 0, -1):
                if self._stop.is_set():
                    self.log("Cancelled.")
                    return
                self.log(f"Starting in {i}...")
                time.sleep(1)
            self.log("Playing.  (F7 / Esc to stop)")

            t0 = time.perf_counter()
            self.play_t0 = t0
            for ev in self.schedule:
                if self._stop.is_set():
                    break
                target = t0 + ev["t"]
                # sleep most of the way, then busy-wait the final ~2ms for accuracy
                while True:
                    remaining = target - time.perf_counter()
                    if remaining <= 0:
                        break
                    if self._stop.is_set():
                        break
                    if remaining > 0.003:
                        time.sleep(remaining - 0.002)
                    # else spin
                if self._stop.is_set():
                    break
                fails += send_chord(ev["keys"])
                sent += len(ev["keys"])
                # if the very first notes are all rejected, tell the user why
                if not warned and sent >= 1 and fails == sent:
                    warned = True
                    self.log("WARNING: Windows blocked every keystroke "
                             "(SendInput rejected). The game is almost "
                             "certainly running as Administrator -- close this "
                             "app and re-launch it 'As administrator' too, so "
                             "it can send keys into the game.")

            self.log("Stopped." if self._stop.is_set() else "Finished.")
        except Exception as e:
            self.log(f"Playback error: {type(e).__name__}: {e}")
        finally:
            _winmm.timeEndPeriod(1)
            self._stop.clear()
            self.play_t0 = None


# ============================================================================
# GLOBAL HOTKEYS  (polled with GetAsyncKeyState -- no extra dependency)
# ============================================================================
def hotkey_loop(app):
    def down(vk):
        return _user32.GetAsyncKeyState(vk) & 0x8000
    prev = {START_VK: 0, STOP_VK: 0, ESC_VK: 0}
    while not app.closing:
        for vk in prev:
            now = down(vk)
            if now and not prev[vk]:          # fresh press edge
                if vk == START_VK:
                    app.request_start()
                else:
                    app.request_stop()
            prev[vk] = now
        time.sleep(0.02)


# ============================================================================
# GUI
# ============================================================================
class App:
    def __init__(self, root):
        self.root = root
        self.closing = False
        self.q = queue.Queue()
        self.player = Player(self.log)

        root.title("MIDI -> Virtual Piano Player")
        root.geometry("620x600")
        root.minsize(520, 440)

        pad = {"padx": 10, "pady": 4}

        # persistent "recently loaded" list (survives restarts)
        self.RECENT_PATH = os.path.join(os.path.expanduser("~"),
                                        ".midi_piano_recent.json")
        self.recent = self._load_recent()
        self.FOLDER_CFG = os.path.join(os.path.expanduser("~"),
                                       ".midi_piano_folder.txt")
        self.local_folder = self._load_folder()

        nb = ttk.Notebook(root)
        nb.pack(fill="both", expand=True, padx=6, pady=6)
        self.nb = nb
        player_tab = ttk.Frame(nb); nb.add(player_tab, text="Player")
        search_tab = ttk.Frame(nb); nb.add(search_tab, text="Search")
        recent_tab = ttk.Frame(nb); nb.add(recent_tab, text="Recent")

        frm = ttk.Frame(player_tab)
        frm.pack(fill="both", expand=True, padx=10, pady=10)
        self._build_search_tab(search_tab)
        self._build_recent_tab(recent_tab)

        ttk.Label(frm, text="MIDI file URL or local path (.mid):").pack(anchor="w")
        self.url_var = tk.StringVar()
        row = ttk.Frame(frm); row.pack(fill="x", **pad)
        ttk.Entry(row, textvariable=self.url_var).pack(side="left", fill="x",
                                                       expand=True)
        self.browse_btn = ttk.Button(row, text="Browse...",
                                     command=self.on_browse)
        self.browse_btn.pack(side="left", padx=(6, 0))
        self.load_btn = ttk.Button(row, text="Load", command=self.on_load)
        self.load_btn.pack(side="left", padx=(6, 0))

        opts = ttk.Frame(frm); opts.pack(fill="x", **pad)
        ttk.Label(opts, text="Transpose (semitones):").pack(side="left")
        self.transpose = tk.IntVar(value=0)
        ttk.Spinbox(opts, from_=-24, to=24, width=5,
                    textvariable=self.transpose).pack(side="left", padx=(4, 16))
        ttk.Label(opts, text="Speed:").pack(side="left")
        self.speed = tk.DoubleVar(value=1.0)
        ttk.Spinbox(opts, from_=0.25, to=3.0, increment=0.05, width=6,
                    textvariable=self.speed).pack(side="left", padx=(4, 16))
        self.skip_drums = tk.BooleanVar(value=True)
        ttk.Checkbutton(opts, text="Skip drums",
                        variable=self.skip_drums).pack(side="left")
        self.overlay_on = tk.BooleanVar(value=True)
        ttk.Checkbutton(opts, text="Timer overlay",
                        variable=self.overlay_on).pack(side="left", padx=(16, 0))

        btns = ttk.Frame(frm); btns.pack(fill="x", **pad)
        self.play_btn = ttk.Button(btns, text="Play  (F6)",
                                   command=self.request_start, state="disabled")
        self.play_btn.pack(side="left")
        ttk.Button(btns, text="Stop  (F7)",
                   command=self.request_stop).pack(side="left", padx=6)

        ms = ttk.LabelFrame(frm, text="MuseScore helper (optional)")
        ms.pack(fill="x", **pad)
        self.ms_var = tk.StringVar()
        msrow = ttk.Frame(ms); msrow.pack(fill="x", padx=6, pady=(4, 2))
        ttk.Entry(msrow, textvariable=self.ms_var).pack(side="left", fill="x",
                                                        expand=True)
        ttk.Button(msrow, text="Open in nanomidi",
                   command=self.on_musescore_helper).pack(side="left", padx=(6, 0))
        ttk.Label(ms, text="Paste a MuseScore link and click: it copies the link "
                  "and opens nanomidi in your browser. Download the .mid there, "
                  "then use Browse (above) to load it.",
                  foreground="#555", wraplength=560,
                  justify="left").pack(anchor="w", padx=6, pady=(0, 4))

        ttk.Label(frm, text="After loading, click into the game, then press F6.",
                  foreground="#555").pack(anchor="w", **pad)

        self.title_var = tk.StringVar(value="")
        ttk.Label(frm, textvariable=self.title_var, font=("", 11, "bold"),
                  foreground="#0a7").pack(anchor="w", **pad)
        self.log_widget = tk.Text(frm, height=8, wrap="word", state="disabled",
                                  bg="#111", fg="#0f0", font=("Consolas", 9))
        self.log_widget.pack(fill="both", expand=True, **pad)

        self.data = None
        self.next_title = None      # title known ahead of load (from search/recent)
        self.log(f"Ready. Key range {core.MIN_NOTE}-{core.MAX_NOTE} "
                 f"(C2-C7 virtualpiano layout).")

        # small always-on-top overlay that follows the mouse during playback
        self.overlay = tk.Toplevel(root)
        self.overlay.overrideredirect(True)
        self.overlay.attributes("-topmost", True)
        try:
            self.overlay.attributes("-alpha", 0.85)
        except Exception:
            pass
        self.overlay_label = tk.Label(
            self.overlay, text="", bg="#111", fg="#0f0",
            font=("Consolas", 10, "bold"), padx=8, pady=3,
            bd=1, relief="solid")
        self.overlay_label.pack()
        self.overlay.withdraw()
        self._overlay_shown = False

        root.protocol("WM_DELETE_WINDOW", self.on_close)
        threading.Thread(target=hotkey_loop, args=(self,), daemon=True).start()
        self.root.after(60, self._drain_log)
        self.root.after(40, self._overlay_tick)

    # ---- search (online MIDI archives) --------------------------------------
    def _build_search_tab(self, parent):
        pad = {"padx": 10, "pady": 4}
        top = ttk.Frame(parent); top.pack(fill="x", **pad)
        ttk.Label(top, text="Search:").pack(side="left")
        self.search_var = tk.StringVar()
        ent = ttk.Entry(top, textvariable=self.search_var)
        ent.pack(side="left", fill="x", expand=True, padx=(4, 6))
        ent.bind("<Return>", lambda e: self.on_search())
        self.search_btn = ttk.Button(top, text="Search", command=self.on_search)
        self.search_btn.pack(side="left")

        srow = ttk.Frame(parent); srow.pack(fill="x", **pad)
        ttk.Label(srow, text="Sources:").pack(side="left")
        self.use_bitmidi = tk.BooleanVar(value=True)
        self.use_midifind = tk.BooleanVar(value=True)
        ttk.Checkbutton(srow, text="BitMidi",
                        variable=self.use_bitmidi).pack(side="left", padx=(4, 8))
        ttk.Checkbutton(srow, text="Midifind",
                        variable=self.use_midifind).pack(side="left")
        self.sort_plays = tk.BooleanVar(value=True)
        ttk.Checkbutton(srow, text="Sort by plays",
                        variable=self.sort_plays).pack(side="left", padx=(16, 0))
        self.use_local = tk.BooleanVar(value=True)
        ttk.Checkbutton(srow, text="My folder",
                        variable=self.use_local).pack(side="left", padx=(16, 0))

        frow = ttk.Frame(parent); frow.pack(fill="x", **pad)
        ttk.Label(frow, text="Folder:").pack(side="left")
        ttk.Button(frow, text="Change...",
                   command=self.on_pick_folder).pack(side="right")
        self.folder_lbl = ttk.Label(frow, text=self.local_folder,
                                    foreground="#555")
        self.folder_lbl.pack(side="left", padx=(4, 6))

        lf = ttk.Frame(parent); lf.pack(fill="both", expand=True, **pad)
        sb = ttk.Scrollbar(lf, orient="vertical")
        self.search_list = tk.Listbox(lf, activestyle="dotbox",
                                      yscrollcommand=sb.set)
        sb.config(command=self.search_list.yview)
        sb.pack(side="right", fill="y")
        self.search_list.pack(side="left", fill="both", expand=True)
        self.search_list.bind("<Double-Button-1>",
                              lambda e: self.on_search_load())

        b = ttk.Frame(parent); b.pack(fill="x", **pad)
        ttk.Button(b, text="Load selected",
                   command=self.on_search_load).pack(side="left")
        ttk.Label(b, text="Double-click a result to download and play it.",
                  foreground="#555").pack(side="left", padx=8)
        self.search_results = []

    def on_search(self):
        q = self.search_var.get().strip()
        online = self.use_bitmidi.get() or self.use_midifind.get()
        use_local = self.use_local.get()
        if not (online or use_local):
            self.log("Enable at least one source (BitMidi / Midifind / My folder).")
            return
        if not q and not use_local:
            self.log("Type something to search for.")
            return
        self.search_btn.config(state="disabled")
        self.search_results = []
        self.search_list.delete(0, "end")
        self.search_list.insert("end", "Searching...")
        # empty query -> scan only the local folder (online needs a query)
        ub = self.use_bitmidi.get() and bool(q)
        um = self.use_midifind.get() and bool(q)
        threading.Thread(
            target=self._search_worker,
            args=(q, ub, um, self.sort_plays.get(),
                  use_local, self.local_folder),
            daemon=True).start()

    def on_pick_folder(self):
        start = self.local_folder if os.path.isdir(self.local_folder) \
            else os.path.expanduser("~")
        d = filedialog.askdirectory(title="Choose your MIDI folder",
                                    initialdir=start)
        if d:
            self.local_folder = d
            self._save_folder()
            self.folder_lbl.config(text=d)
            self.log(f"Search folder set to: {d}")

    def _default_folder(self):
        return os.path.join(os.path.expanduser("~"), "Downloads", "Midi Files")

    def _load_folder(self):
        try:
            with open(self.FOLDER_CFG, "r", encoding="utf-8") as fh:
                p = fh.read().strip()
            if p:
                return p
        except Exception:
            pass
        return self._default_folder()

    def _save_folder(self):
        try:
            with open(self.FOLDER_CFG, "w", encoding="utf-8") as fh:
                fh.write(self.local_folder)
        except Exception:
            pass

    def _search_worker(self, q, use_b, use_m, sort_plays, use_local, folder):
        try:
            results, errors = core.search_midis(
                q, use_bitmidi=use_b, use_midifind=use_m,
                sort_by_plays=sort_plays,
                use_local=use_local, local_folder=folder)
        except Exception as e:
            results, errors = [], [f"Search failed: {e}"]

        def finish():
            self.search_btn.config(state="normal")
            self.search_results = results
            self.search_list.delete(0, "end")
            for r in results:
                plays = r.get("plays")
                extra = f"   ({plays:,} plays)" if plays else ""
                self.search_list.insert(
                    "end", f"[{r['source']}] {r['title']}{extra}")
            if not results:
                self.search_list.insert("end", "(no results)")
            for err in errors:
                self.log(err)
            self.log(f"Found {len(results)} result(s)"
                     + (f" for \"{q}\"." if q else "."))
        self.root.after(0, finish)

    def on_search_load(self):
        sel = self.search_list.curselection()
        if not sel or not self.search_results:
            self.log("Run a search and select a result first.")
            return
        idx = sel[0]
        if idx >= len(self.search_results):
            return
        r = self.search_results[idx]
        self.log(f"Loading '{r['title']}' from {r['source']}...")
        self.next_title = r.get("title", "")
        self.url_var.set(r["url"])
        self.nb.select(0)             # jump to the Player tab
        self.on_load()

    # ---- recent list --------------------------------------------------------
    def _load_recent(self):
        try:
            with open(self.RECENT_PATH, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            out = []
            if isinstance(data, list):
                for x in data:
                    if isinstance(x, dict) and x.get("url"):
                        out.append({"url": str(x["url"]),
                                    "title": str(x.get("title") or "")})
                    elif isinstance(x, str):          # old format: bare URL
                        out.append({"url": x, "title": ""})
            return out[:50]
        except Exception:
            pass
        return []

    def _save_recent(self):
        try:
            with open(self.RECENT_PATH, "w", encoding="utf-8") as fh:
                json.dump(self.recent, fh, indent=2)
        except Exception as e:
            self.log(f"(Could not save recent list: {e})")

    def _build_recent_tab(self, parent):
        pad = {"padx": 10, "pady": 4}
        ttk.Label(parent, text="Double-click an entry to load it "
                  "(or select it and use the buttons).").pack(anchor="w", **pad)
        lf = ttk.Frame(parent); lf.pack(fill="both", expand=True, **pad)
        sb = ttk.Scrollbar(lf, orient="vertical")
        self.recent_list = tk.Listbox(lf, activestyle="dotbox",
                                      yscrollcommand=sb.set)
        sb.config(command=self.recent_list.yview)
        sb.pack(side="right", fill="y")
        self.recent_list.pack(side="left", fill="both", expand=True)
        self.recent_list.bind("<Double-Button-1>",
                              lambda e: self.on_recent_load())
        rb = ttk.Frame(parent); rb.pack(fill="x", **pad)
        ttk.Button(rb, text="Load selected",
                   command=self.on_recent_load).pack(side="left")
        ttk.Button(rb, text="Remove",
                   command=self.on_recent_remove).pack(side="left", padx=6)
        ttk.Button(rb, text="Clear all",
                   command=self.on_recent_clear).pack(side="left")
        self._refresh_recent_listbox()

    def _refresh_recent_listbox(self):
        self.recent_list.delete(0, "end")
        for e in self.recent:
            self.recent_list.insert("end", e["title"] or e["url"])

    def add_recent(self, src, title=""):
        src = (src or "").strip()
        if not src:
            return
        title = (title or "").strip()
        low = title.lower()
        if low.endswith(".midi"):
            title = title[:-5].strip()
        elif low.endswith(".mid"):
            title = title[:-4].strip()
        self.recent = [e for e in self.recent if e["url"] != src]  # dedupe by url
        self.recent.insert(0, {"url": src, "title": title})
        self.recent = self.recent[:50]
        self._save_recent()
        self._refresh_recent_listbox()

    def on_recent_load(self):
        sel = self.recent_list.curselection()
        if not sel:
            self.log("Select an entry in the Recent tab first.")
            return
        entry = self.recent[sel[0]]
        self.next_title = entry.get("title", "")
        self.url_var.set(entry["url"])
        self.nb.select(0)          # jump to the Player tab
        self.on_load()

    def on_recent_remove(self):
        sel = self.recent_list.curselection()
        if not sel:
            self.log("Select an entry to remove.")
            return
        del self.recent[sel[0]]
        self._save_recent()
        self._refresh_recent_listbox()

    def on_recent_clear(self):
        self.recent = []
        self._save_recent()
        self._refresh_recent_listbox()
        self.log("Recent list cleared.")

    # ---- thread-safe logging ------------------------------------------------
    def log(self, msg):
        self.q.put(msg)

    def _drain_log(self):
        try:
            while True:
                msg = self.q.get_nowait()
                self.log_widget.config(state="normal")
                self.log_widget.insert("end", msg + "\n")
                self.log_widget.see("end")
                self.log_widget.config(state="disabled")
        except queue.Empty:
            pass
        if not self.closing:
            self.root.after(60, self._drain_log)

    # ---- mouse-following timer overlay --------------------------------------
    @staticmethod
    def _fmt_time(sec):
        sec = int(sec + 0.5)
        m, s = divmod(max(0, sec), 60)
        return f"{m}:{s:02d}"

    def _overlay_tick(self):
        try:
            pos = self.player.position()
            if self.overlay_on.get() and pos is not None:
                elapsed, total = pos
                left = max(0.0, total - elapsed)
                self.overlay_label.config(
                    text=f"\u25B6 {self._fmt_time(elapsed)} / "
                         f"{self._fmt_time(total)}   -{self._fmt_time(left)}")
                x, y = self.root.winfo_pointerxy()
                self.overlay.geometry(f"+{x + 16}+{y + 18}")
                if not self._overlay_shown:
                    self.overlay.deiconify()
                    self.overlay.attributes("-topmost", True)
                    self._overlay_shown = True
            elif self._overlay_shown:
                self.overlay.withdraw()
                self._overlay_shown = False
        except Exception:
            pass
        if not self.closing:
            self.root.after(40, self._overlay_tick)

    # ---- actions ------------------------------------------------------------
    def on_browse(self):
        path = filedialog.askopenfilename(
            title="Choose a MIDI file",
            filetypes=[("MIDI files", "*.mid *.midi"), ("All files", "*.*")],
        )
        if path:
            self.url_var.set(path)
            self.on_load()

    def on_load(self):
        url = self.url_var.get().strip()
        if not url:
            self.log("Paste a .mid URL or click Browse to pick a local file.")
            return
        self.load_btn.config(state="disabled")
        self.browse_btn.config(state="disabled")
        self.play_btn.config(state="disabled")
        src = "Reading" if not url.lower().startswith(("http://", "https://")) else "Fetching"
        self.log(f"{src} {url} ...")
        known = self.next_title
        self.next_title = None
        threading.Thread(target=self._load_worker, args=(url, known),
                         daemon=True).start()

    def _load_worker(self, url, known_title=None):
        try:
            data = core.load_midi(url)
            title = (known_title or "").strip() or core.extract_title(data, url)
            schedule, stats = core.summarize(
                data,
                skip_drums=self.skip_drums.get(),
                transpose=self.transpose.get(),
                speed=self.speed.get(),
                chord_window=CHORD_WINDOW,
            )
            self.player.load(schedule)
            shown = title or "(untitled)"
            self.root.after(0, lambda t=shown: self.title_var.set(f"\u266A  {t}"))
            self.log(f"Title: {shown}")
            mins, secs = divmod(int(stats["duration_s"]), 60)
            self.log(f"Loaded: {stats['chords']} chords / "
                     f"{stats['note_ons']} notes, ~{mins}:{secs:02d} long"
                     + (f", {stats['dropped']} out-of-range notes folded/dropped."
                        if stats["dropped"] else "."))
            self.log("Ready -- click into the game and press F6.")
            self.root.after(0, lambda: self.play_btn.config(state="normal"))
            self.root.after(0, lambda u=url, t=(title or ""): self.add_recent(u, t))
        except Exception as e:
            self.log(f"Error: {e}")
        finally:
            self.root.after(0, lambda: self.load_btn.config(state="normal"))
            self.root.after(0, lambda: self.browse_btn.config(state="normal"))

    def on_musescore_helper(self):
        url = self.ms_var.get().strip()
        if url:
            try:
                self.root.clipboard_clear()
                self.root.clipboard_append(url)
                self.log("MuseScore link copied to clipboard.")
            except Exception:
                pass
        try:
            webbrowser.open("https://nanomidi.net/musescore-downloader")
        except Exception as e:
            self.log(f"Could not open browser: {e}")
            return
        self.log("Opened nanomidi. Paste the link there, download the .mid, "
                 "then click Browse above to load it.")

    def request_start(self):
        if not self.player.schedule:
            self.log("Load a MIDI first.")
            return
        if self.player.playing:
            return
        self.player.start()

    def request_stop(self):
        if self.player.playing:
            self.player.stop()
            self.log("Stopping...")
        else:
            self.log("Nothing is playing.")

    def on_close(self):
        self.closing = True
        self.player.stop()
        self.root.after(120, self.root.destroy)


def main():
    root = tk.Tk()
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)  # crisp text on HiDPI
    except Exception:
        pass
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
