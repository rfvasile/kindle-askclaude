#!/usr/bin/env python3
"""kindle-ask: answers questions from the KOReader "Ask Claude" plugin with Claude Code.

The Kindle connects over SSH with a key whose authorized_keys entry forces this
script, so that key can do nothing else. The requested verb arrives in
SSH_ORIGINAL_COMMAND, request bodies on stdin, and every reply is one JSON
object on stdout.

Verbs:
  ping                          -> {ok}
  actions                       -> {ok, actions: [{id, label, scope}]}
  has-book <book>               -> {ok, present}
  put-book <book> <ext>         stdin: raw book file; converts it to plain text
  ask                           stdin: JSON request (see handle_ask); runs `claude -p`
  history <book>                -> {ok, entries: [...]} newest first
  history-delete <book> <entry> / history-clear <book>
  modules                       -> {ok, modules: [...]} all modules, enabled or not
  module-enable|module-disable|module-delete <module>
  module-new                    stdin: {description, book_id}; Claude drafts a module
  module-add|module-discard <draft>

Help modules: every modules/*.md file is a pluggable tip with a small header
(label, scope, order, enabled) and up to two sections:
  ## guidance   added to Claude's system prompt for every question
  ## prompt     makes the module a button in the Kindle menu; this is the question it asks
See modules/README.md. Drafts live in modules/drafts/, deleted modules in modules/trash/.

Per book, the laptop keeps the full text and a history of questions and answers
(books/<id>/). Claude only ever sees that book's working directory (work/<id>/):
book_so_far.txt (the text cut at the end of the reader's current page),
contents.txt (the chapters up to there) and history.md (earlier exchanges about
this book from no later than the current position). Its tools are limited to
Read/Grep/Glob, and reads outside that directory are denied.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

MODULES = Path(__file__).resolve().parent / "modules"
DRAFTS = MODULES / "drafts"
TRASH = MODULES / "trash"
DATA = Path.home() / ".local/share/kindle-ask"
BOOKS = DATA / "books"  # full text + history, outside Claude's reach
WORK = DATA / "work"  # per-book working dirs holding only what Claude may see
LOG = DATA / "log.txt"

MODEL = os.environ.get("KINDLE_ASK_MODEL")  # e.g. "sonnet"; None = account default
CLAUDE_TIMEOUT = 300
MAX_BOOK_BYTES = 200 * 1024 * 1024
MAX_LINE = 1000  # Claude's Read tool truncates very long lines
HISTORY_FOR_CLAUDE = 100  # most recent exchanges written to history.md

# The fixed part of the system prompt: who Claude is talking to and what the files
# are (the script creates them, so this must stay accurate). Everything about how
# to research and answer comes from the enabled modules.
CORE_PROMPT = """\
You are a reading companion. The user is reading a book on a Kindle and asks you \
questions from inside the reader, usually because they have lost the thread: who \
someone is, why something is happening, how the story got here, or what a passage means.

Files in the current directory:
- book_so_far.txt: the book's text from the start up to the end of the page the \
reader is on, one paragraph per line. The last lines are what they are reading now.
- contents.txt: the chapters so far and the line of book_so_far.txt where each \
starts. It may be missing or approximate for some books.
- history.md: earlier questions the reader asked about this book and your answers, \
oldest first. It may be empty.

Prefer several targeted Grep searches and short Reads to reading huge spans."""


def log(msg):
    DATA.mkdir(parents=True, exist_ok=True)
    with open(LOG, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")


def reply(obj):
    sys.stdout.write(json.dumps(obj))
    sys.stdout.flush()


def fail(msg):
    log(f"error: {msg}")
    reply({"ok": False, "error": msg})
    sys.exit(0)


def check_id(book_id):
    if not re.fullmatch(r"[0-9a-f]{32}", book_id or ""):
        fail("invalid book id")
    return book_id


def check_name(name):
    """Module/draft/entry ids: they become file names, so keep them boring."""
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", name or ""):
        fail("invalid name")
    return name


def read_json_stdin():
    try:
        return json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        fail("malformed request")


def find_claude():
    path = shutil.which("claude") or str(Path.home() / ".local/bin/claude")
    if not os.access(path, os.X_OK):
        fail("claude CLI not found on the computer")
    return path


def run_claude(prompt, workdir, sys_prompt, session_id=None, tools="Read,Grep,Glob", persist=True):
    cmd = [
        find_claude(), "-p",
        "--output-format", "json",
        "--tools", tools,
        "--permission-mode", "dontAsk",
        "--setting-sources", "project",
        "--strict-mcp-config",
        "--append-system-prompt", sys_prompt,
    ]
    if MODEL:
        cmd += ["--model", MODEL]
    if session_id:
        cmd += ["--resume", session_id]
    if not persist:
        cmd += ["--no-session-persistence"]
    env = dict(os.environ)
    env["PATH"] = f"{Path.home() / '.local/bin'}:{env.get('PATH', '/usr/bin:/bin')}"
    return subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                          cwd=workdir, env=env, timeout=CLAUDE_TIMEOUT)


def claude_result(res):
    try:
        out = json.loads(res.stdout)
    except json.JSONDecodeError:
        fail(f"unexpected output from claude: {(res.stderr or res.stdout).strip()[-300:]}")
    if out.get("is_error"):
        fail(str(out.get("result") or "Claude returned an error"))
    return out


# -------------------------------------------------------------- modules

def parse_module_text(text, module_id):
    """A `---` header of `key: value` lines, then `## guidance` / `## prompt` sections."""
    meta, body = {}, text
    m = re.match(r"\A---\n(.*?)\n---\n?(.*)\Z", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            if ":" in line and not line.lstrip().startswith("#"):
                k, v = line.split(":", 1)
                meta[k.strip().lower()] = v.strip()
        body = m.group(2)
    sections, current = {}, None
    for line in body.splitlines():
        h = re.match(r"^##\s+(\w+)\s*$", line)
        if h:
            current = h.group(1).lower()
            sections[current] = []
        elif current:
            sections[current].append(line)
    sections = {k: "\n".join(v).strip() for k, v in sections.items()}
    try:
        order = int(meta.get("order", 50))
    except ValueError:
        order = 50
    guidance, prompt = sections.get("guidance", ""), sections.get("prompt", "")
    return {
        "id": module_id,
        "label": meta.get("label") or re.sub(r"^\d+-", "", module_id).replace("-", " ").capitalize(),
        "scope": meta.get("scope", "any"),  # selection | page | any
        "order": order,
        "enabled": meta.get("enabled", "true").lower() not in ("false", "no", "off", "0"),
        "guidance": guidance,
        "prompt": prompt,
        "kind": "action + guidance" if prompt and guidance else "action" if prompt else "guidance",
    }


def module_files():
    return [p for p in sorted(MODULES.glob("*.md")) if p.name.lower() != "readme.md"]


def load_modules(include_disabled=False):
    mods = []
    for p in module_files():
        try:
            mod = parse_module_text(p.read_text(), p.stem)
        except (OSError, UnicodeDecodeError) as e:
            log(f"skipping module {p.name}: {e}")
            continue
        if mod["enabled"] or include_disabled:
            mods.append(mod)
    return sorted(mods, key=lambda m: (m["order"], m["id"]))


def system_prompt(mods):
    return "\n\n".join([CORE_PROMPT] + [m["guidance"] for m in mods if m["guidance"]])


def menu_actions(mods=None):
    mods = load_modules() if mods is None else mods
    return [{"id": m["id"], "label": m["label"], "scope": m["scope"]}
            for m in mods if m["prompt"]]


def handle_modules():
    out = []
    for m in load_modules(include_disabled=True):
        content = (MODULES / f"{m['id']}.md").read_text()
        out.append({k: m[k] for k in ("id", "label", "scope", "enabled", "kind")} | {"content": content})
    reply({"ok": True, "modules": out})


def set_enabled(text, enabled):
    value = "true" if enabled else "false"
    m = re.match(r"\A---\n(.*?)\n---\n?", text, re.S)
    if not m:
        return f"---\nenabled: {value}\n---\n{text}"
    header = m.group(1)
    if re.search(r"(?m)^enabled\s*:", header):
        header = re.sub(r"(?m)^enabled\s*:.*$", f"enabled: {value}", header)
    else:
        header += f"\nenabled: {value}"
    return f"---\n{header}\n---\n{text[m.end():]}"


def handle_module_toggle(name, enabled):
    path = MODULES / f"{check_name(name)}.md"
    if not path.is_file():
        fail("no such module")
    path.write_text(set_enabled(path.read_text(), enabled))
    log(f"module {name} {'enabled' if enabled else 'disabled'}")
    reply({"ok": True, "actions": menu_actions()})


def handle_module_delete(name):
    path = MODULES / f"{check_name(name)}.md"
    if not path.is_file():
        fail("no such module")
    TRASH.mkdir(parents=True, exist_ok=True)
    path.replace(TRASH / f"{name}.{time.strftime('%Y%m%d-%H%M%S')}.md")
    log(f"module {name} moved to trash")
    reply({"ok": True, "actions": menu_actions()})


GENERATOR_PROMPT = """\
You write help modules for a reading companion: Claude Code answering questions \
from someone reading a book on a Kindle. Your whole reply is the content of ONE \
module file, starting with the `---` line. No commentary, no code fences.

Format:
---
label: <button text, max 30 characters; only needed when there is a prompt>
scope: <selection | page | any>
order: <number>
enabled: true
---
## guidance
<optional: rules added to the reading companion's system prompt for EVERY question>

## prompt
<optional: the question asked when the reader taps this module's button>

Rules:
- A module needs a guidance section, a prompt section, or both. If the reader wants \
a button for a recurring kind of question, write a prompt (and guidance only if the \
answer needs special research or a special shape). If they want to change how every \
answer is researched or written, write guidance only, and leave out label and the \
prompt section.
- scope: "selection" for buttons that only make sense on highlighted text, "page" \
for buttons about the current position when nothing is selected, "any" for both.
- order: 30-79 for new buttons (menu position), 17-19 for research guidance, \
80-89 for answer-style guidance.
- Make it work for most books, not just the current one: no character names, \
places or plot details from any specific book.
- The reading companion's world: book_so_far.txt (the book up to the reader's \
position, one paragraph per line), contents.txt (chapters so far, with line \
numbers), history.md (earlier questions and answers about this book), and only the \
Grep, Read and Glob tools. Guidance may tell it how to use these.
- Never ask for anything past the reader's position: there must be no spoilers.
- Answers appear on a small e-ink screen as plain text, so a prompt can ask for a \
short list of lines, but not tables or Markdown.
- Be concise: guidance of 1-4 sentences, a prompt of 1-3 sentences.
- Don't duplicate an existing module. If the request overlaps one, write a module \
that covers only what is new."""


def slugify(text):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:40].strip("-") or "module"


def book_history_digest(book_id, limit=15):
    entries = read_history(book_id)[-limit:]
    lines = []
    for e in entries:
        q = e.get("question") or e.get("label") or ""
        lines.append(f"- Asked: {q[:200]}\n  Answer began: {(e.get('answer') or '')[:200]}")
    return "\n".join(lines)


def handle_module_new():
    req = read_json_stdin()
    description = (req.get("description") or "").strip()
    if not description:
        fail("describe the module you want")
    existing = "\n".join(
        f"- {m['id']} ({m['kind']}{', off' if not m['enabled'] else ''}): "
        f"{m['label'] if m['prompt'] else ''} {(m['prompt'] or m['guidance'])[:160]}"
        for m in load_modules(include_disabled=True))
    examples = "\n\n".join(
        f"Example ({p.name}):\n{p.read_text()}"
        for p in (MODULES / "20-how-did-i-get-here.md", MODULES / "12-names-and-variants.md") if p.is_file())
    parts = [f"Existing modules:\n{existing}", examples]
    book_id = req.get("book_id")
    if book_id and re.fullmatch(r"[0-9a-f]{32}", book_id):
        digest = book_history_digest(book_id)
        if digest:
            parts.append("What the reader has been asking recently (use it to understand "
                         "what would help them, but keep the module generic):\n" + digest)
    parts.append(f"The reader's request:\n{description}")

    gen_dir = DATA / "gen"
    gen_dir.mkdir(parents=True, exist_ok=True)
    out = claude_result(run_claude("\n\n".join(parts), gen_dir, GENERATOR_PROMPT,
                                   tools="", persist=False))
    content = (out.get("result") or "").strip()
    content = re.sub(r"\A```\w*\n|\n```\Z", "", content).strip() + "\n"
    if not content.startswith("---"):
        fail("Claude did not return a module; try rephrasing")
    mod = parse_module_text(content, "draft")
    if not mod["guidance"] and not mod["prompt"]:
        fail("the generated module was empty; try rephrasing")
    if mod["scope"] not in ("selection", "page", "any"):
        content = re.sub(r"(?m)^scope\s*:.*$", "scope: any", content)
    name = f"{max(0, min(mod['order'], 99)):02d}-{slugify(mod['label'] if mod['prompt'] else description)}"
    taken = {p.stem for p in module_files()}
    base, n = name, 2
    while name in taken:
        name, n = f"{base}-{n}", n + 1
    DRAFTS.mkdir(parents=True, exist_ok=True)
    (DRAFTS / f"{name}.md").write_text(content)
    log(f"drafted module {name} from {description[:80]!r}")
    reply({"ok": True, "id": name, "label": mod["label"], "kind": mod["kind"], "content": content})


def handle_module_add(name):
    draft = DRAFTS / f"{check_name(name)}.md"
    if not draft.is_file():
        fail("no such draft")
    target = MODULES / draft.name
    if target.exists():
        fail("a module with that name already exists")
    draft.replace(target)
    log(f"module {name} added")
    reply({"ok": True, "actions": menu_actions()})


def handle_module_discard(name):
    (DRAFTS / f"{check_name(name)}.md").unlink(missing_ok=True)
    reply({"ok": True})


# ---------------------------------------------------------------- books

def handle_has_book(book_id):
    txt = BOOKS / check_id(book_id) / "book.txt"
    reply({"ok": True, "present": txt.is_file() and txt.stat().st_size > 0})


def convert_to_text(src, dst):
    ext = src.suffix.lower()
    if ext == ".txt":
        shutil.copyfile(src, dst)
        return
    if ext == ".pdf" and shutil.which("pdftotext"):
        cmd = ["pdftotext", "-enc", "UTF-8", str(src), str(dst)]
    elif shutil.which("ebook-convert"):
        cmd = ["ebook-convert", str(src), str(dst), "--txt-output-encoding", "utf-8"]
    else:
        fail("no converter found (install calibre for ebook-convert)")
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if res.returncode != 0 or not dst.is_file():
        fail(f"could not convert book: {(res.stderr or res.stdout)[-300:]}")


def split_long(line):
    """Break an over-long paragraph into lines of whole sentences (hard-wrap as a last resort)."""
    if len(line) <= MAX_LINE:
        return [line]
    out, cur = [], ""
    for sent in re.split(r"(?<=[.!?…;:»”\"'])\s+", line):
        while len(sent) > MAX_LINE:  # one enormous sentence
            cut = sent.rfind(" ", 0, MAX_LINE)
            cut = cut if cut > 0 else MAX_LINE
            if cur:
                out.append(cur)
                cur = ""
            out.append(sent[:cut])
            sent = sent[cut:].lstrip()
        if cur and len(cur) + 1 + len(sent) > MAX_LINE:
            out.append(cur)
            cur = sent
        else:
            cur = f"{cur} {sent}" if cur else sent
    if cur:
        out.append(cur)
    return out


def normalize_text(text):
    """About one paragraph per line, no blank lines, so Grep/Read line numbers stay meaningful."""
    out = []
    for raw in text.splitlines():
        line = re.sub(r"[ \t ]+", " ", raw).strip()
        if line:
            out.extend(split_long(line))
    return "\n".join(out) + "\n"


def handle_put_book(book_id, ext):
    check_id(book_id)
    if not re.fullmatch(r"[a-z0-9]{1,6}", ext or ""):
        fail("invalid file extension")
    data = sys.stdin.buffer.read(MAX_BOOK_BYTES + 1)
    if not data:
        fail("received an empty book file")
    if len(data) > MAX_BOOK_BYTES:
        fail("book file is too large")
    d = BOOKS / book_id
    d.mkdir(parents=True, exist_ok=True)
    src = d / f"book.{ext}"
    src.write_bytes(data)
    raw = d / "book.raw.txt"
    convert_to_text(src, raw)
    text = normalize_text(raw.read_text(errors="replace"))
    raw.unlink()
    (d / "book.txt").write_text(text)
    log(f"stored book {book_id} ({ext}, {len(data)} bytes, {len(text)} chars)")
    reply({"ok": True, "chars": len(text)})


# ------------------------------------------------------------- history

def history_path(book_id):
    return BOOKS / book_id / "history.jsonl"


def read_history(book_id):
    path = history_path(book_id)
    if not path.is_file():
        return []
    entries = []
    for line in path.read_text().splitlines():
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return entries


def write_history(book_id, entries):
    path = history_path(book_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text("".join(json.dumps(e) + "\n" for e in entries))
    tmp.replace(path)


def append_history(book_id, entry):
    path = history_path(book_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(entry) + "\n")


def where_label(e):
    parts = []
    if e.get("chapter"):
        parts.append(str(e["chapter"]))
    if isinstance(e.get("percent"), (int, float)):
        parts.append(f"{round(e['percent'] * 100)}%")
    return ", ".join(parts)


def handle_history(book_id):
    entries = read_history(check_id(book_id))[::-1][:300]
    for e in entries:
        e["when"] = time.strftime("%d %b %H:%M", time.localtime(e.get("ts", 0)))
        e["where"] = where_label(e)
    reply({"ok": True, "entries": entries})


def handle_history_delete(book_id, entry_id):
    check_id(book_id)
    check_name(entry_id)
    entries = read_history(book_id)
    kept = [e for e in entries if e.get("id") != entry_id]
    if len(kept) == len(entries):
        fail("no such history entry")
    write_history(book_id, kept)
    reply({"ok": True})


def handle_history_clear(book_id):
    history_path(check_id(book_id)).unlink(missing_ok=True)
    log(f"cleared history for {book_id}")
    reply({"ok": True})


def history_markdown(book_id, percent):
    """Earlier exchanges for history.md: none from beyond the current position (re-reads)."""
    limit = percent + 0.005 if isinstance(percent, (int, float)) else None
    entries = [e for e in read_history(book_id)
               if limit is None or not isinstance(e.get("percent"), (int, float)) or e["percent"] <= limit]
    entries = entries[-HISTORY_FOR_CLAUDE:]
    blocks = []
    for e in entries:
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(e.get("ts", 0)))
        head = f"## {when}" + (f" ({where_label(e)})" if where_label(e) else "")
        body = []
        if e.get("selection"):
            body.append(f'Selected: "{e["selection"]}"')
        body.append(f"Asked: {e.get('question') or e.get('label') or ''}")
        body.append(f"Answer: {e.get('answer', '')}")
        blocks.append(head + "\n" + "\n".join(body))
    return blocks


# ------------------------------------------------------- reading position

def word_pattern(words):
    return re.compile(r"\W+".join(map(re.escape, words)), re.IGNORECASE)


def find_nearest(text, words, guess):
    """Match of `words` (separated by any punctuation/whitespace) closest to `guess`."""
    if not words:
        return None
    matches = list(word_pattern(words).finditer(text))
    return min(matches, key=lambda m: abs(m.start() - guess)) if matches else None


def line_end(text, i):
    nl = text.find("\n", i)
    return len(text) if nl == -1 else nl + 1


def cut_position(text, page_text, selection, percent):
    """Index in `text` at the end of the reader's current page."""
    n = len(text)
    guess = int(n * percent) if isinstance(percent, (int, float)) and 0 <= percent <= 1 else n
    page_words = re.findall(r"\w+", page_text or "")
    # Best: the last words of the visible page give its exact end. Try a long
    # tail first (unique), then shorter ones in case the conversion differs.
    for k in (12, 8, 5):
        if len(page_words) >= k:
            m = find_nearest(text, page_words[-k:], guess)
            if m:
                return m.end()  # exactly where the visible page ends
    # Next best: the selection is on the visible page; allow the rest of a page.
    m = find_nearest(text, re.findall(r"\w+", selection or "")[:12], guess)
    if m:
        return line_end(text, min(n, m.end() + 800))
    # Last resort: page-based percentage plus a little slack.
    return line_end(text, min(n, guess + 1000))


def build_contents(so_far, toc, total_len):
    """contents.txt lines mapping chapter titles to line numbers in so_far.

    Each TOC entry's percent is a fraction of the whole book (total_len chars).
    """
    out, pos = [], 0
    n = len(so_far)
    for entry in toc if isinstance(toc, list) else []:
        if not isinstance(entry, dict):
            continue
        title = str(entry.get("title") or "").strip()
        if not title:
            continue
        pct = entry.get("percent")
        guess = int(total_len * pct) if isinstance(pct, (int, float)) else pos
        words = re.findall(r"\w+", title)[:8]
        m = None
        if words:
            # Chapter titles are usually their own line; prefer matches at a line start
            # after the previous chapter, nearest to where the page count says it is.
            pat = re.compile(r"(?m)^\W*" + word_pattern(words).pattern, re.IGNORECASE)
            cands = [x for x in pat.finditer(so_far) if x.start() >= pos]
            m = min(cands, key=lambda x: abs(x.start() - guess)) if cands else None
        if m:
            pos = m.start()
            approx = ""
        elif isinstance(pct, (int, float)) and guess < n:
            pos = max(pos, guess)
            approx = "about "
        else:
            continue  # not found in the text read so far: could be a spoiler, leave it out
        line = so_far.count("\n", 0, pos) + 1
        indent = "  " * max(0, int(entry.get("depth") or 1) - 1)
        out.append(f"{indent}{title} (starts {approx}line {line})")
    return out


def prepare_workdir(book_id, req):
    """Write the spoiler-free view of the book. Returns (workdir, info dict)."""
    work = WORK / book_id
    work.mkdir(parents=True, exist_ok=True)
    history = history_markdown(book_id, req.get("percent"))
    (work / "history.md").write_text("\n\n".join(history) + "\n" if history else "")
    info = {"text": False, "lines": 0, "chapters": 0, "history": len(history)}
    full = BOOKS / book_id / "book.txt"
    if full.is_file():
        text = full.read_text(errors="replace")
        so_far = text[:cut_position(text, req.get("page_text"), req.get("selection"), req.get("percent"))]
        if not so_far.endswith("\n"):
            so_far += "\n"
        (work / "book_so_far.txt").write_text(so_far)
        contents = build_contents(so_far, req.get("toc"), len(text))
        (work / "contents.txt").write_text("\n".join(contents) + "\n" if contents else "")
        info.update(text=True, lines=so_far.count("\n"), chapters=len(contents))
    return work, info


# ---------------------------------------------------------------- ask

def resolve_question(req, mods):
    """The free-text question if one was typed, otherwise the chosen action's prompt."""
    question = (req.get("question") or "").strip()
    if question:
        return question
    for m in mods:
        if m["id"] == req.get("action") and m["prompt"]:
            return m["prompt"]
    return "Explain this."


def build_prompt(req, info, new_session, question):
    selection = (req.get("selection") or "").strip()
    parts = []
    title = req.get("title") or "an unknown book"
    authors = (req.get("authors") or "").replace("\n", ", ")
    pct = req.get("percent")
    chapter = req.get("chapter")
    where = []
    if isinstance(pct, (int, float)):
        where.append(f"about {round(pct * 100)}% of the way through")
    if chapter:
        where.append(f'in the chapter "{chapter}"')
    if new_session:
        intro = f'I\'m reading "{title}"' + (f" by {authors}" if authors else "")
        parts.append(intro + (", " + ", ".join(where) if where else "") + ".")
        if not info["text"]:
            parts.append("(The book's text isn't available, so answer from the passage and general knowledge.)")
        else:
            parts.append(f"(book_so_far.txt has {info['lines']} lines; contents.txt lists "
                         f"{info['chapters']} chapters; history.md has {info['history']} earlier exchanges.)")
        page = (req.get("page_text") or "").strip()
        if page and not selection:
            parts.append(f'The page I\'m on:\n"""\n{page[-2500:]}\n"""')
    elif where:
        parts.append("(I'm now " + ", ".join(where) + "; the files are updated to my position.)")
    if selection:
        parts.append(f'Selected passage:\n"""\n{selection}\n"""')
    parts.append(question)
    return "\n\n".join(parts)


def handle_ask():
    """Request: {book_id, title, authors, chapter, percent, page_text, toc,
    selection, action, question, session_id}. Reply: {ok, answer, session_id, actions}."""
    req = read_json_stdin()
    book_id = check_id(req.get("book_id"))
    session_id = req.get("session_id")
    if session_id and not re.fullmatch(r"[0-9a-fA-F-]{36}", str(session_id)):
        session_id = None

    mods = load_modules()
    sys_prompt = system_prompt(mods)
    question = resolve_question(req, mods)
    workdir, info = prepare_workdir(book_id, req)
    started = time.time()
    try:
        res = run_claude(build_prompt(req, info, not session_id, question), workdir, sys_prompt, session_id)
        if res.returncode != 0 and session_id:
            # The session may have been cleaned up; start a fresh conversation.
            log(f"resume failed ({res.stderr.strip()[-200:]}), retrying without session")
            session_id = None
            res = run_claude(build_prompt(req, info, True, question), workdir, sys_prompt)
    except subprocess.TimeoutExpired:
        fail("Claude took too long to answer")
    out = claude_result(res)
    answer = (out.get("result") or "").strip()
    label = next((m["label"] for m in mods if m["id"] == req.get("action")), None)
    append_history(book_id, {
        "id": uuid.uuid4().hex[:12],
        "ts": int(time.time()),
        "session_id": out.get("session_id"),
        "percent": req.get("percent") if isinstance(req.get("percent"), (int, float)) else None,
        "chapter": req.get("chapter") if isinstance(req.get("chapter"), str) else None,
        "action": req.get("action") if isinstance(req.get("action"), str) else None,
        "label": label,
        "question": (req.get("question") or "").strip() or label or question,
        "selection": (req.get("selection") or "").strip()[:1000] or None,
        "answer": answer,
    })
    log(f"ask {book_id} session={out.get('session_id')} turns={out.get('num_turns')} "
        f"{time.time() - started:.1f}s action={req.get('action')} q={question[:60]!r}")
    # The current menu rides along so the Kindle picks up added/removed modules.
    reply({"ok": True, "answer": answer, "session_id": out.get("session_id"),
           "actions": menu_actions(mods)})


# ---------------------------------------------------------------- main

VERBS = {
    # verb: (number of arguments, handler)
    "ping": (0, lambda: reply({"ok": True})),
    "actions": (0, lambda: reply({"ok": True, "actions": menu_actions()})),
    "has-book": (1, handle_has_book),
    "put-book": (2, handle_put_book),
    "ask": (0, handle_ask),
    "history": (1, handle_history),
    "history-delete": (2, handle_history_delete),
    "history-clear": (1, handle_history_clear),
    "modules": (0, handle_modules),
    "module-enable": (1, lambda n: handle_module_toggle(n, True)),
    "module-disable": (1, lambda n: handle_module_toggle(n, False)),
    "module-delete": (1, handle_module_delete),
    "module-new": (0, handle_module_new),
    "module-add": (1, handle_module_add),
    "module-discard": (1, handle_module_discard),
}


def main():
    if "SSH_ORIGINAL_COMMAND" not in os.environ and sys.argv[1:] == ["show-prompt"]:
        mods = load_modules()  # local preview of what Claude will be told
        print(system_prompt(mods), "\n\n--- menu actions ---")
        for a in menu_actions(mods):
            print(f"  [{a['scope']:9}] {a['label']}  ({a['id']})")
        return
    args = os.environ.get("SSH_ORIGINAL_COMMAND", " ".join(sys.argv[1:])).split()
    verb, rest = (args[0], args[1:]) if args else ("", [])
    try:
        nargs, handler = VERBS.get(verb, (None, None))
        if handler is None or len(rest) != nargs:
            fail(f"unknown command: {verb!r}")
        handler(*rest)
    except SystemExit:
        raise
    except Exception as e:  # report instead of dying silently on the Kindle side
        fail(f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
