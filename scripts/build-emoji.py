#!/usr/bin/env python3
"""Builds Resources/Emoji.json, what the emoji picker lists and searches.

From Unicode's emoji-test.txt (every emoji, in the order and groups the system keyboard uses, with
skin-tone variants) and CLDR's annotations (each one's name and the words people search it by),
plus a group of characters that aren't emoji but get looked for the same way (⌘ → ✓ ° €).
Emoji newer than the Mac can draw are dropped by the app when it loads, so this can stay current.

Usage: scripts/build-emoji.py   (downloads the two files; run again for a new Unicode version)
"""
import json
import os
import re
import unicodedata
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Emoji.json")
TEST = "https://unicode.org/Public/emoji/latest/emoji-test.txt"
CLDR = "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/{}/en/annotations.json"

TONES = ["\U0001F3FB", "\U0001F3FC", "\U0001F3FD", "\U0001F3FE", "\U0001F3FF"]
# The system keyboard's names for the groups, shorter than Unicode's.
GROUP_NAMES = {"Smileys & Emotion": "Smileys", "People & Body": "People", "Animals & Nature": "Nature",
               "Food & Drink": "Food", "Travel & Places": "Travel", "Activities": "Activities",
               "Objects": "Objects", "Symbols": "Symbols", "Flags": "Flags"}

# Not emoji, but what people open a picker for: keys, arrows, marks, maths, money.
CHARACTERS = (
    "⌘⌥⌃⇧⇪⏎↩⌫⌦⎋⇥␣⏏ ←→↑↓↔↕⇐⇒⇔↖↗↘↙↺↻ ✓✔✗✘•·…–—‘’“”«»‹›¡¿§¶†‡ "
    "°±×÷≈≠≤≥∞√∑∏∆∂∫πµΩ‰½⅓¼¾¹²³ €£¥₹₩₽¢©®™℠ ★☆♥♦♣♠♪♫☐☑☒⌀⌖◆◇○●□■△▲▽▼"
).replace(" ", "")
CHARACTER_WORDS = {"⌘": "command cmd", "⌥": "option alt opt", "⌃": "control ctrl", "⇧": "shift", "⇪": "caps lock",
                   "⏎": "return enter", "↩": "return enter", "⌫": "delete backspace", "⌦": "forward delete",
                   "⎋": "escape esc", "⇥": "tab", "␣": "space", "⏏": "eject", "✓": "check tick done",
                   "✔": "check tick done", "✗": "cross x", "✘": "cross x", "•": "bullet dot", "…": "ellipsis dots",
                   "–": "en dash", "—": "em dash", "°": "degree", "×": "times multiply", "÷": "divide",
                   "≈": "approximately", "≠": "not equal", "∞": "infinity", "√": "square root", "€": "euro",
                   "£": "pound sterling", "¥": "yen yuan", "₹": "rupee", "©": "copyright", "®": "registered",
                   "™": "trademark", "§": "section", "¶": "pilcrow paragraph", "→": "arrow right", "←": "arrow left",
                   "↑": "arrow up", "↓": "arrow down"}


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode("utf-8")


def plain(s):
    """Without variation selectors, for looking a sequence up whichever way it's written."""
    return s.replace("️", "").replace("︎", "")


def main():
    test = fetch(TEST)
    notes = {}
    # The derived set has the sequences (flags, families, people doing things).
    for path, key in (("cldr-annotations-full/annotations", "annotations"),
                      ("cldr-annotations-derived-full/annotationsDerived", "annotationsDerived")):
        for k, v in json.loads(fetch(CLDR.format(path)))[key]["annotations"].items():
            notes.setdefault(plain(k), v)

    groups, by_base, group = [], {}, None
    line = re.compile(r"^([0-9A-F ]+?)\s*;\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.+)$")
    for raw in test.splitlines():
        if raw.startswith("# group:"):
            name = raw.split(":", 1)[1].strip()
            group = {"name": GROUP_NAMES[name], "emoji": []} if name in GROUP_NAMES else None
            if group:
                groups.append(group)
            continue
        m = line.match(raw)
        if not m or group is None:
            continue
        emoji, name = m.group(2), m.group(3)
        tones = [t for t in TONES if t in emoji]
        if tones:
            # A variant: one tone throughout ("👩🏽‍🤝‍👩🏽"), filed under its base. Mixed tones are left out.
            if len(set(tones)) == 1:
                base = emoji
                for t in TONES:
                    base = base.replace(t, "")
                entry = by_base.get(plain(base))
                if entry is not None:
                    entry.setdefault("t", [None] * 5)[TONES.index(tones[0])] = emoji
            continue
        note = notes.get(plain(emoji), {})
        words = [w for w in note.get("default", []) if w.lower() != name.lower()]
        # A country's flag also answers to its code ("gb", "us"), and the UK's to "uk".
        letters = [chr(ord(c) - 0x1F1E6 + ord("a")) for c in emoji if 0x1F1E6 <= ord(c) <= 0x1F1FF]
        if len(letters) == 2:
            code = "".join(letters)
            words += [code] + (["uk"] if code == "gb" else [])
        entry = {"e": emoji, "n": (note.get("tts") or [name])[0]}
        if words:
            entry["k"] = " ".join(words)
        group["emoji"].append(entry)
        by_base[plain(emoji)] = entry
    for g in groups:
        for e in g["emoji"]:
            if "t" in e and None in e["t"]:
                del e["t"]  # only offer tones an emoji has all five of

    chars = []
    for c in CHARACTERS:
        try:
            name = unicodedata.name(c).lower()
        except ValueError:
            continue
        entry = {"e": c, "n": name}
        if c in CHARACTER_WORDS:
            entry["k"] = CHARACTER_WORDS[c]
        chars.append(entry)
    groups.append({"name": "Characters", "emoji": chars})

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "groups": groups}, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{OUT}: {sum(len(g['emoji']) for g in groups)} in {len(groups)} groups")


if __name__ == "__main__":
    main()
