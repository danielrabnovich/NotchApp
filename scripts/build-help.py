#!/usr/bin/env python3
"""Builds the help knowledge base (Help.json) that Search answers questions about NotchApp from.

Three sources, so it stays current without anyone maintaining it by hand:
  - Help/Guide.md: the hand-written guide (how things work, where to find them).
  - The Settings window's source: every page, section and setting with its description, read
    straight from the SwiftUI code (ToggleRow, RowLabel, Section headers, footers…).
  - The git history: each commit as a changelog entry, newest first.

Usage: scripts/build-help.py <output.json>
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources", "NotchApp")
STRING = r'"((?:[^"\\]|\\.)*)"'


def clean(s):
    """A Swift string literal's text: interpolations become …, escapes are undone."""
    s = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "…", s)
    return s.replace('\\"', '"').replace("\\n", " ").strip()


def swift_files():
    for d, _, files in os.walk(SOURCES):
        for f in files:
            if f.endswith(".swift"):
                yield os.path.join(d, f)


def match_brace(text, open_index):
    """Index just past the brace matching the one at open_index, skipping string literals."""
    depth, i, n = 0, open_index, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def structs():
    """Every `struct Name: View` body in the app, by name."""
    out = {}
    for path in swift_files():
        text = open(path, encoding="utf-8").read()
        for m in re.finditer(r"^(?:private |fileprivate )?struct (\w+)[^{\n]*\{", text, re.M):
            start = text.index("{", m.start())
            out[m.group(1)] = text[start:match_brace(text, start)]
    return out


def pane_info():
    """Pane case → (title, summary, view struct) from SettingsView.swift."""
    text = open(os.path.join(SOURCES, "Settings", "SettingsView.swift"), encoding="utf-8").read()
    enum = text[text.index("enum SettingsPane"):]
    enum = enum[:match_brace(enum, enum.index("{"))]
    cases = dict(re.findall(r'case (\w+) = "([^"]+)"', enum))

    def switch_values(var):
        m = re.search(r"var " + var + r"[^{]*\{", enum)
        if not m:
            return {}
        body = enum[m.end():match_brace(enum, m.end() - 1)]
        return {k: clean(v) for k, v in re.findall(r"case \.(\w+)(?:, \.\w+)*: " + STRING, body)}

    titles, summaries = switch_values("title"), switch_values("summary")
    views = dict(re.findall(r"case \.(\w+): (\w+)\(\)", text[text.index("switch router.pane"):]))
    return {case: {"raw": raw, "title": titles.get(case, raw), "summary": summaries.get(case, ""), "view": views.get(case)}
            for case, raw in cases.items()}


ROW_PATTERNS = [
    # (regex, kind) — group 1 is the title, group 2 (optional) the description.
    (r"ToggleRow\(\s*" + STRING + r"(?:\s*,\s*subtitle:\s*[^\"\n]{0,60}?" + STRING + r")?", "setting"),
    (r"RowLabel\(\s*title:\s*" + STRING + r"(?:\s*,\s*subtitle:\s*[^\"\n]{0,60}?" + STRING + r")?", "setting"),
    (r"PermissionRow\(\s*title:\s*" + STRING + r"(?:\s*,\s*subtitle:\s*[^\"\n]{0,60}?" + STRING + r")?", "permission"),
    (r"(?:Picker|Toggle|Stepper|LabeledContent)\(\s*" + STRING, "setting"),
    (r"FooterText\(\s*" + STRING, "footer"),
]


def sections(body):
    """(start, end, header) for each Section block, header from Section("X") or `header: { Text("X") }`."""
    out = []
    for m in re.finditer(r"\bSection\b(\(\s*" + STRING + r"\s*\))?\s*\{", body):
        open_i = body.index("{", m.start())
        end = match_brace(body, open_i)
        header = clean(m.group(2)) if m.group(2) else None
        if not header:
            h = re.match(r"\s*header:\s*\{\s*Text\(\s*" + STRING, body[end:end + 200])
            if h:
                header = clean(h.group(1))
        out.append((open_i, end, header))
    return out


def rows_in(body, all_structs, seen, depth=0):
    """Settings rows in a view's body, in order, following the views it uses (two levels)."""
    found = []
    secs = sections(body)

    def section_at(i):
        best = None
        for s, e, h in secs:
            if s <= i < e and h and (best is None or s > best[0]):
                best = (s, h)
        return best[1] if best else None

    for pattern, kind in ROW_PATTERNS:
        for m in re.finditer(pattern, body):
            title = clean(m.group(1))
            desc = clean(m.group(2)) if m.lastindex and m.lastindex >= 2 and m.group(2) else ""
            if kind == "footer":
                title, desc = "", title
            if len(title) < 2 and not desc:
                continue
            row = {"kind": kind, "title": title, "text": desc, "section": section_at(m.start())}
            # The setting it switches (`isOn: $s.screenshotCleanup`), so help can say whether it's on now.
            tail = body[m.end():m.end() + 400]
            nxt = re.search(r"\b(?:ToggleRow|RowLabel|PermissionRow|Picker|Section)\(", tail)
            k = re.search(r"isOn:\s*\$s\.(\w+)", tail[:nxt.start()] if nxt else tail)
            if k:
                row["key"] = k.group(1)
            found.append((m.start(), row))
    if depth < 2:
        for m in re.finditer(r"\b([A-Z]\w+)\(", body):
            name = m.group(1)
            if name in all_structs and name not in seen and name not in ("Section", "Text"):
                seen.add(name)
                for _, row in rows_in(all_structs[name], all_structs, seen, depth + 1):
                    row.setdefault("section", None)
                    if not row["section"]:
                        row["section"] = section_at(m.start())
                    found.append((m.start(), row))
    found.sort(key=lambda x: x[0])
    return found


def settings_entries():
    all_structs = structs()
    entries = []
    for case, info in pane_info().items():
        view = info["view"]
        if not view:
            continue
        body = all_structs.get(view, "") if view else ""
        rows = [r for _, r in rows_in(body, all_structs, {view})] if body else []
        # Drop exact repeats (a row shown in two states of an `if`).
        uniq, keys = [], set()
        for r in rows:
            key = (r["title"], r["text"])
            if key not in keys:
                keys.add(key)
                uniq.append(r)
        headers = [h for h in dict.fromkeys(r["section"] for r in uniq if r["section"])]
        entries.append({
            "kind": "page", "pane": case, "title": f"Settings → {info['title']}",
            "text": " ".join(filter(None, [info["summary"],
                                           ("Sections: " + ", ".join(headers) + ".") if headers else "",
                                           ("Settings: " + "; ".join(t for t in dict.fromkeys(r["title"] for r in uniq if r["title"])) + ".")
                                           if any(r["title"] for r in uniq) else ""])),
        })
        for r in uniq:
            where = f"Settings → {info['title']}" + (f" → {r['section']}" if r["section"] else "")
            if r["kind"] == "footer":
                entries.append({"kind": "note", "pane": case, "title": where, "text": r["text"]})
            else:
                e = {"kind": r["kind"], "pane": case, "title": r["title"], "where": where, "text": r["text"]}
                if r.get("key"):
                    e["key"] = r["key"]
                entries.append(e)
    return entries


def guide_entries():
    """Help/Guide.md: each `## Heading {pane}` section is an entry; the pane, if given, links it."""
    path = os.path.join(ROOT, "Help", "Guide.md")
    if not os.path.exists(path):
        return []
    entries, current = [], None
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^##\s+(.+?)\s*(?:\{(\w+)\})?\s*$", line)
        if m:
            current = {"kind": "guide", "title": m.group(1), "pane": m.group(2), "text": ""}
            entries.append(current)
        elif current is not None and not line.startswith("# "):
            current["text"] += line
    for e in entries:
        e["text"] = re.sub(r"\n{3,}", "\n\n", e["text"]).strip()
        if not e["pane"]:
            del e["pane"]
    return entries


def repo_url():
    """The GitHub page of the origin remote, for linking commits; None if there isn't one."""
    try:
        url = subprocess.run(["git", "-C", ROOT, "remote", "get-url", "origin"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return None
    m = re.match(r"(?:https://|git@)([^/:]+)[/:](.+?)(?:\.git)?$", url)
    return f"https://{m.group(1)}/{m.group(2)}" if m else None


def changelog_entries(limit=400):
    repo = repo_url()
    try:
        out = subprocess.run(["git", "-C", ROOT, "log", f"-{limit}", "--no-merges", "--format=%h%x1f%ad%x1f%s%x1f%b%x1e",
                              "--date=short"], capture_output=True, text=True, check=True).stdout
    except Exception:
        return []
    entries = []
    for record in out.split("\x1e"):
        parts = record.strip("\n").split("\x1f")
        if len(parts) < 4:
            continue
        sha, date, subject, body = parts
        body = "\n".join(l for l in body.splitlines()
                         if not re.match(r"^(Co-Authored-By|Claude-Session|Signed-off-by):", l)).strip()
        entry = {"kind": "change", "title": subject.strip(), "date": date, "commit": sha, "text": body}
        if repo:
            entry["repo"] = repo
        entries.append(entry)
    return entries


def main():
    entries = guide_entries() + settings_entries() + changelog_entries()
    for i, e in enumerate(entries):
        e["id"] = i
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "Help.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "entries": entries}, f, ensure_ascii=False, indent=0)
    kinds = {}
    for e in entries:
        kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    print("  " + ", ".join(f"{v} {k}" for k, v in sorted(kinds.items())))


if __name__ == "__main__":
    main()
