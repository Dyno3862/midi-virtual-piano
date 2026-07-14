"""
piano_core.py  -- platform-independent core for the MIDI -> Virtual Piano player.

This module has NO Windows / GUI dependencies so it can be unit-tested anywhere.
It handles:
  * building the MIDI-note -> keyboard-key map (virtualpiano.net standard)
  * fetching a .mid over HTTPS
  * parsing MIDI into absolute-time note-on events (mido does the tempo math)
  * folding out-of-range notes into the playable range
  * grouping near-simultaneous notes into chords
  * producing a flat "schedule" the player thread walks against a real clock
"""

import io
import json
import os
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request
import html as _html

# ----------------------------------------------------------------------------
# KEY MAP  (virtualpiano.net "MAX" layout -- the standard almost every Roblox
# piano, including "Digital Piano", copies)
#
#   * 36 white notes, C2..C7, mapped to:  1234567890 qwertyuiop asdfghjkl zxcvbnm
#   * each sharp = Shift + the white key just below it  (C#=Shift+C, D#=Shift+D, ...)
#
# If your game's lowest key isn't C2, change LOWEST_MIDI below (e.g. 48 = C3).
# ----------------------------------------------------------------------------

WHITE_KEYS = "1234567890qwertyuiopasdfghjklzxcvbnm"   # 36 chars = 36 white notes
WHITE_SEMITONES = {0, 2, 4, 5, 7, 9, 11}              # C D E F G A B within an octave
LOWEST_MIDI = 36                                       # 36 = C2  (change if needed)


def build_note_map(lowest_midi=LOWEST_MIDI):
    """MIDI note number -> (base_key_char, needs_shift)."""
    note_map = {}
    # 1) assign the 36 white keys to the 36 white notes, ascending
    n, idx = lowest_midi, 0
    while idx < len(WHITE_KEYS):
        if n % 12 in WHITE_SEMITONES:
            note_map[n] = (WHITE_KEYS[idx], False)
            idx += 1
        n += 1
    highest_white = n - 1
    # 2) every sharp = Shift + the white key immediately below it
    for note in range(lowest_midi, highest_white + 1):
        if note % 12 not in WHITE_SEMITONES and (note - 1) in note_map:
            base_char, _ = note_map[note - 1]
            note_map[note] = (base_char, True)
    return note_map


NOTE_MAP = build_note_map()
MIN_NOTE = min(NOTE_MAP)
MAX_NOTE = max(NOTE_MAP)


def fold_into_range(note):
    """Shift an out-of-range note by whole octaves until it fits, else None."""
    while note < MIN_NOTE:
        note += 12
    while note > MAX_NOTE:
        note -= 12
    return note if MIN_NOTE <= note <= MAX_NOTE else None


# ----------------------------------------------------------------------------
# FETCH
# ----------------------------------------------------------------------------

def _validate_midi(data, source_hint="that source"):
    """Raise a helpful error if the bytes are not a Standard MIDI File."""
    if data[:4] != b"MThd":
        raise ValueError(
            f"{source_hint} did not return a MIDI file (no 'MThd' header). "
            "Make sure it points straight at a .mid file."
        )
    return data


def fetch_midi(url, timeout=20):
    """Download raw bytes of a .mid over HTTP/HTTPS. Follows redirects.

    Tries a normal, certificate-verified request first. If the server's TLS
    certificate is expired or otherwise unverifiable, retries once with
    verification disabled (many MIDI archives run on old/misconfigured hosts).
    """
    req = urllib.request.Request(
        url, headers={"User-Agent": "Mozilla/5.0 (MidiPianoPlayer)"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
    except urllib.error.URLError as e:
        if not isinstance(getattr(e, "reason", None), ssl.SSLError):
            raise
        # certificate problem -> retry without verification
        insecure = ssl.create_default_context()
        insecure.check_hostname = False
        insecure.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(req, timeout=timeout,
                                    context=insecure) as resp:
            data = resp.read()
    return _validate_midi(data, "That link")


def read_local_midi(path):
    """Read raw bytes of a .mid file from the local filesystem."""
    with open(path, "rb") as fh:
        data = fh.read()
    return _validate_midi(data, "That file")


def load_midi(source):
    """Load MIDI bytes from either a URL (http/https) or a local file path."""
    s = str(source).strip()
    if s.lower().startswith(("http://", "https://")):
        return fetch_midi(s)
    return read_local_midi(s)


# ----------------------------------------------------------------------------
# PARSE  +  SCHEDULE
# ----------------------------------------------------------------------------

def parse_events(data, skip_drums=True, transpose=0, speed=1.0):
    """
    Return a list of (abs_seconds, midi_note) note-on events.
    mido's iteration yields messages already converted to real seconds,
    handling variable-length delta times, running status and tempo changes.
    """
    import mido  # imported here so the map/fetch logic stays import-light

    mid = mido.MidiFile(file=io.BytesIO(data))
    events, t = [], 0.0
    for msg in mid:
        t += msg.time
        if msg.type == "note_on" and msg.velocity > 0:
            if skip_drums and getattr(msg, "channel", None) == 9:
                continue          # channel 10 (0-indexed 9) is percussion
            events.append((t / speed, msg.note + transpose))
    return events


def build_schedule(events, chord_window=0.03):
    """
    Group note-ons that land within `chord_window` seconds into single chord
    events, mapping every note to its key. Returns a list of dicts:
        {"t": seconds, "keys": [(char, shift), ...], "dropped": int}
    """
    schedule = []
    i, N = 0, len(events)
    events = sorted(events, key=lambda e: e[0])
    while i < N:
        start_t = events[i][0]
        notes = []
        while i < N and events[i][0] - start_t <= chord_window:
            notes.append(events[i][1])
            i += 1
        keys, dropped = [], 0
        seen = set()
        for note in notes:
            folded = fold_into_range(note)
            if folded is None:
                dropped += 1
                continue
            key = NOTE_MAP[folded]
            if key not in seen:          # de-dupe identical keys in one chord
                seen.add(key)
                keys.append(key)
        if keys:
            schedule.append({"t": start_t, "keys": keys, "dropped": dropped})
    return schedule


def summarize(data, **kw):
    """Convenience: parse + schedule + return (schedule, stats dict)."""
    events = parse_events(data, **{k: v for k, v in kw.items()
                                   if k in ("skip_drums", "transpose", "speed")})
    schedule = build_schedule(events, chord_window=kw.get("chord_window", 0.03))
    duration = schedule[-1]["t"] if schedule else 0.0
    return schedule, {
        "note_ons": len(events),
        "chords": len(schedule),
        "duration_s": duration,
        "dropped": sum(s["dropped"] for s in schedule),
    }


# ----------------------------------------------------------------------------
# TITLE DETECTION
# ----------------------------------------------------------------------------

def _title_from_source(source):
    """Best-effort song title from a filename or URL (None if uninformative)."""
    if not source:
        return None
    s = str(source).split("?")[0].split("#")[0]
    base = s.replace("\\", "/").rstrip("/").split("/")[-1]
    base = urllib.parse.unquote(base)
    base = re.sub(r"\.midi?$", "", base, flags=re.I)
    # reject id-like names (all digits / dashes), e.g. "28362" or "0-0-1-8332-20"
    if not base or re.fullmatch(r"[\d\-_.]+", base):
        return None
    base = re.sub(r"[_]+", " ", base)
    # use the filename as-is when nothing better exists -- even if it happens
    # to be an instrument-ish word like "Piano"; the filename is the last resort.
    return re.sub(r"\s+", " ", base).strip() or None


# Track names that are really instrument/part labels, not song titles.
_INSTRUMENT_NAMES = {
    "piano", "grand piano", "acoustic grand piano", "acoustic grand",
    "bright acoustic piano", "electric piano", "electric piano 1",
    "electric piano 2", "electric grand piano", "honky-tonk piano",
    "honky tonk piano", "harpsichord", "clavinet", "keyboard", "keys",
    "bass", "electric bass", "electric bass (finger)", "electric bass (pick)",
    "acoustic bass", "fingered bass", "picked bass", "fretless bass",
    "slap bass", "slap bass 1", "slap bass 2", "synth bass",
    "guitar", "acoustic guitar", "acoustic guitar (nylon)",
    "acoustic guitar (steel)", "electric guitar", "electric guitar (jazz)",
    "electric guitar (clean)", "electric guitar (muted)", "nylon guitar",
    "steel guitar", "clean guitar", "distortion guitar", "overdriven guitar",
    "overdrive guitar", "jazz guitar",
    "drums", "drum kit", "drumset", "drum set", "percussion",
    "drums (percussion)", "standard kit",
    "strings", "string ensemble", "string ensemble 1", "string ensemble 2",
    "violin", "viola", "cello", "violoncello", "contrabass", "double bass",
    "harp", "orchestral harp", "orchestra", "orchestra hit",
    "flute", "piccolo", "recorder", "clarinet", "oboe", "bassoon",
    "english horn", "pan flute",
    "trumpet", "trombone", "tuba", "french horn", "horn", "brass",
    "brass section", "muted trumpet",
    "sax", "saxophone", "alto sax", "tenor sax", "soprano sax",
    "baritone sax", "alto saxophone", "tenor saxophone",
    "organ", "church organ", "rock organ", "drawbar organ",
    "percussive organ", "reed organ", "accordion",
    "choir", "choir aahs", "voice", "voices", "voice oohs", "vocal",
    "vocals", "lead vocal", "synth voice",
    "lead", "lead 1", "lead 2", "melody", "harmony", "chords",
    "accompaniment", "accomp", "comp",
    "synth", "synth lead", "synth pad", "synth strings", "synth strings 1",
    "pad", "pads", "fx", "sound effects",
    "untitled", "unnamed", "new track", "midi", "midi out", "track",
    "instrument", "part", "right hand", "left hand", "r.h.", "l.h.",
    "rh", "lh", "treble", "bass clef", "main", "music",
}
_GENERIC_NAME_RE = re.compile(
    r"^(track|part|staff|stave|instrument|channel|voice)\s*\d+$", re.I)

# an instrument name optionally followed by a number or hand/clef qualifier,
# e.g. "Piano 1", "Piano RH", "Grand Piano (left hand)", "Guitar 2"
_INSTRUMENT_QUALIFIED_RE = re.compile(
    r"^(grand |electric |acoustic |synth )?"
    r"(piano|guitar|bass|violin|viola|cello|flute|organ|synth|drums?|"
    r"strings?|voice|vocals?|lead|sax|trumpet|trombone|choir|harp|keys)"
    r"[\s\-\(]*(\d+|r\.?h\.?|l\.?h\.?|right|left)"
    r"(\s*hand)?\)?$", re.I)


def _clean_meta(text):
    """Strip null/control padding some exporters leave on meta strings."""
    return re.sub(r"\s+", " ", re.sub(r"[\x00-\x1f\x7f]+", " ", text)).strip()


def _is_instrument_name(name):
    n = _clean_meta(name).lower()
    return (n in _INSTRUMENT_NAMES
            or bool(_GENERIC_NAME_RE.match(n))
            or bool(_INSTRUMENT_QUALIFIED_RE.match(n)))


def extract_title(data, source=""):
    """Song title from the MIDI's embedded name, else from the filename/URL.
    Ignores plain instrument/part labels (e.g. "Piano", "Track 1") so those
    never get mistaken for the title. Returns a string, or None."""
    try:
        import mido
        mid = mido.MidiFile(file=io.BytesIO(data))
        # first embedded track name that isn't just an instrument/part label
        for track in mid.tracks:
            for msg in track:
                if msg.is_meta and msg.type == "track_name":
                    name = _clean_meta(msg.name)
                    if name and not _is_instrument_name(name):
                        return name
        # a text meta on track 0 as a weak fallback (also filtered)
        if mid.tracks:
            for msg in mid.tracks[0]:
                if msg.is_meta and msg.type == "text":
                    t = _clean_meta(msg.text)
                    if len(t) > 1 and not _is_instrument_name(t):
                        return t
    except Exception:
        pass
    return _title_from_source(source)


# ----------------------------------------------------------------------------
# LOCAL FOLDER SEARCH
# ----------------------------------------------------------------------------

def search_local_folder(query, folder, limit=200):
    """Find .mid/.midi files under `folder` whose name matches `query`
    (case-insensitive substring; empty query lists everything)."""
    out = []
    q = (query or "").lower().strip()
    if not folder or not os.path.isdir(folder):
        return out
    for root, _dirs, files in os.walk(folder):
        for fn in sorted(files):
            if fn.lower().endswith((".mid", ".midi")) and (not q or q in fn.lower()):
                out.append({
                    "source": "Local",
                    "title": os.path.splitext(fn)[0],
                    "plays": None,
                    "url": os.path.join(root, fn),
                })
                if len(out) >= limit:
                    return out
    return out


# ----------------------------------------------------------------------------
# SEARCH  (find MIDIs on public archives and return direct-download URLs)
# ----------------------------------------------------------------------------

BITMIDI_BASE = "https://bitmidi.com"
MIDIFIND_BASE = "https://midifind.com"
_UA = {"User-Agent": "Mozilla/5.0 (MidiPianoPlayer)"}


def _http_get(url, timeout=20):
    """GET raw bytes, retrying once without TLS verification on cert errors."""
    req = urllib.request.Request(url, headers=_UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.URLError as e:
        if not isinstance(getattr(e, "reason", None), ssl.SSLError):
            raise
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.read()


def search_bitmidi(query, limit=25, timeout=20):
    """Search bitmidi.com via its JSON API. Returns a list of result dicts."""
    url = BITMIDI_BASE + "/api/midi/search?q=" + urllib.parse.quote(query)
    data = json.loads(_http_get(url, timeout).decode("utf-8", "replace"))
    out = []
    for r in data.get("result", {}).get("results", []):
        dl = r.get("downloadUrl")
        if not dl:
            continue
        out.append({
            "source": "BitMidi",
            "title": (r.get("name") or "(untitled)").strip(),
            "plays": r.get("plays"),
            "url": BITMIDI_BASE + dl,
        })
        if len(out) >= limit:
            break
    return out


# one search-result <a> block -> capture (href-with-id, id, inner title html)
_MIDIFIND_RE = re.compile(
    r'href="(/files/[^"]+?-\d+-\d+-(\d+))"[^>]*class="item"'
    r'[\s\S]*?<div class="w-100[^"]*">([\s\S]*?)</div>'
)


def search_midifind(query, limit=25, timeout=20):
    """Search midifind.com by scraping its server-rendered results page."""
    url = MIDIFIND_BASE + "/search/?q=" + urllib.parse.quote(query)
    page = _http_get(url, timeout).decode("utf-8", "replace")
    out = []
    for m in _MIDIFIND_RE.finditer(page):
        fid = m.group(2)
        title = re.sub(r"<[^>]+>", "", m.group(3))   # drop <b> highlight tags
        title = _html.unescape(title)
        title = re.sub(r"\s+", " ", title).strip()
        out.append({
            "source": "Midifind",
            "title": title or "(untitled)",
            "plays": None,
            "url": f"{MIDIFIND_BASE}/files/0-0-1-{fid}-20",
        })
        if len(out) >= limit:
            break
    return out


def _norm_title(title):
    """Loose key for spotting the same song across sources/versions."""
    t = title.strip().lower()
    t = re.sub(r"\.midi?$", "", t)          # drop a trailing .mid/.midi
    t = re.sub(r"[^a-z0-9]+", " ", t)        # keep only letters/digits
    return t.strip()


def _dedupe(results):
    """Collapse duplicates by normalized title, keeping the most-played copy.
    Preserves first-seen order (BitMidi before Midifind)."""
    best, order = {}, []
    for r in results:
        key = _norm_title(r["title"]) or r["url"]
        if key not in best:
            best[key] = r
            order.append(key)
        elif (r.get("plays") or 0) > (best[key].get("plays") or 0):
            best[key] = r          # prefer the version with more plays
    return [best[k] for k in order]


def search_midis(query, use_bitmidi=True, use_midifind=True, limit=25,
                 sort_by_plays=True, dedupe=True,
                 use_local=False, local_folder=None):
    """Search the enabled archives. Returns (results, errors).

    results: list of dicts with keys source/title/plays/url (url is ready to
    hand straight to load_midi). errors: human-readable strings for any source
    that failed, so one dead site never kills the whole search.

    De-duplicates across sources (by normalized title) and, when
    sort_by_plays is set, orders the list by play count (highest first;
    entries with no play data keep their original relative order below).
    """
    results, errors = [], []
    if use_bitmidi:
        try:
            results += search_bitmidi(query, limit)
        except Exception as e:
            errors.append(f"BitMidi search failed: {e}")
    if use_midifind:
        try:
            results += search_midifind(query, limit)
        except Exception as e:
            errors.append(f"Midifind search failed: {e}")
    if use_local and local_folder:
        try:
            results += search_local_folder(query, local_folder)
        except Exception as e:
            errors.append(f"Local folder search failed: {e}")
    if dedupe:
        results = _dedupe(results)
    if sort_by_plays:
        # stable sort -> ties (e.g. all the play-less Midifind hits) keep order
        results.sort(key=lambda r: (r.get("plays") or 0), reverse=True)
    return results, errors
