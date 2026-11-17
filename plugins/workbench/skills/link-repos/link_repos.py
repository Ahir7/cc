#!/usr/bin/env -S python3 -I
"""Link a group of git repos into one Claude Code session with shared memory.

  link_repos.py --group NAME [--memory-dir DIR] REPO REPO [REPO ...] [--apply] [--approve-imports]
                [--allow-external PATH ...] [--home DIR]
  link_repos.py --from-config NAME [--memory-dir DIR] [--apply] [--approve-imports] [--allow-external PATH ...]
                [--home DIR]

For each repo R it plans:
  R/.claude/settings.local.json   merge autoMemoryDirectory and permissions.additionalDirectories (keeps other keys)
  R/.claude/rules/linked-repos.md one @import line per sibling CLAUDE.md / CLAUDE.local.md (rewritten each run)
  R/.git/info/exclude             the local-only files above, unless git already ignores them
  R/.worktreeinclude              CLAUDE.local.md and the rule file, so new worktrees get them (never .env)
plus the memory dir's MEMORY.md and, with --approve-imports, the external-import flags in .claude.json
(<home>/.claude.json; without --home, $CLAUDE_CONFIG_DIR/.claude.json when that is set, else ~/.claude.json).

The approval flag is one boolean per project: it approves every external import, not just the sibling bridge.
So every run also lists, as [external] lines, the @imports and rule symlinks in each repo's instruction files that
resolve outside that repo and are not a sibling's CLAUDE.md / CLAUDE.local.md. --approve-imports refuses (exit 3)
unless --allow-external names each one, and also refuses while any instruction file is [unscanned]: over
SCAN_MAX_BYTES, or not a regular file (a FIFO or device, in the repo or as an [external] target). --allow-external
cannot override that.

Every read resolves symlinks, opens only regular files (never blocking on a FIFO) and is capped: SCAN_MAX_BYTES for
instruction files, READ_MAX_BYTES for the settings, state, config and git files. Bytes that are not UTF-8 never
crash it: instruction files decode with errors="replace"; files it rewrites keep their bytes (surrogateescape).

Dry run by default: prints every planned change and writes nothing. A second --apply changes nothing.
Exit 0 on success, 2 on refusal (bad input, not a primary checkout, unsafe symlink, a file that does not parse, is
not a regular file, is over READ_MAX_BYTES or cannot be read), 3 when --approve-imports would approve an external
import that no --allow-external names or an [unscanned] file exists. Nothing is written on 2 or 3.
Stdlib only.
"""
import argparse
import collections
import json
import os
import re
import stat
import subprocess
import sys
import tempfile

RULE_REL = ".claude/rules/linked-repos.md"
SETTINGS_REL = ".claude/settings.local.json"
WTI_REL = ".worktreeinclude"
EXCLUDE_REL = ".git/info/exclude"
# The spec names the first three; settings.local.json is added because this script writes absolute paths into it
# and a sandbox or fresh machine may not ignore it globally yet. Lines git already ignores are skipped.
EXCLUDE_LINES = [RULE_REL, "CLAUDE.local.md", WTI_REL, SETTINGS_REL]
WTI_LINES = ["CLAUDE.local.md", RULE_REL]
SIBLING_FILES = ["CLAUDE.md", "CLAUDE.local.md"]
APPROVAL_KEYS = ["hasClaudeMdExternalIncludesApproved", "hasClaudeMdExternalIncludesWarningShown"]

# Instruction files Claude Code loads for a project; the import scan starts from these, every .md under
# .claude/rules/ (discovered recursively, like Claude Code does) and tracked nested copies of these names.
SCAN_ROOTS = ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".claude/AGENTS.md"]
SCAN_NAMES = ("CLAUDE.md", "CLAUDE.local.md", "AGENTS.md")
RULES_DIR = ".claude/rules"
MAX_IMPORT_HOPS = 5          # Claude Code follows four; one more costs nothing
SCAN_MAX_BYTES = 1 << 20     # a file over this is not scanned; it is listed as [unscanned] and blocks approval
READ_MAX_BYTES = 16 << 20    # cap for every other file read (settings, .claude.json, workbench config, git files)
# An @path ends at the first unescaped space. The lookbehind is looser than Claude Code's (start or whitespace)
# so that markup such as **@path** is still caught; a stray match can only add a report, never hide one.
IMPORT_RE = re.compile(r"(?<![A-Za-z0-9@])@((?:\\ |\S)+)")
FENCE_RE = re.compile(r"^( {0,3})(`{3,}|~{3,})(.*)$")
FENCE_CLOSE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})[ \t]*$")
HTML_OPEN_RE = re.compile(r"^ {0,3}<(!--|\?|!\[CDATA\[|![A-Za-z]|(?:script|pre|style|textarea)(?=[\s>]|$)|/?[A-Za-z])",
                          re.I)
HTML_ENDS = {"!--": "-->", "?": "?>", "![cdata[": "]]>"}
RAW_HTML_END_RE = re.compile(r"</(script|pre|style|textarea)>", re.I)
INLINE_HTML_RE = re.compile(r"<[A-Za-z/!?]")

External = collections.namedtuple("External", "repo source line token target")


class Refusal(Exception):
    def __init__(self, message, code=2):
        Exception.__init__(self, message)
        self.code = code


class Unreadable(Exception):
    """A path this script will not read: not a regular file, or over its cap. str(err) says why."""


# ---------- paths ----------

def expand(path, home):
    if path == "~":
        return home
    if path.startswith("~/"):
        return os.path.join(home, path[2:])
    return path


def within(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def safe_target(root, rel):
    """Real path to write for root/rel. Follows symlinks only while they stay inside the repo."""
    path = os.path.join(root, rel)
    real = os.path.realpath(path)
    if not within(real, root):
        raise Refusal("%s resolves outside the repo (%s); refusing to follow that symlink" % (path, real))
    if os.path.exists(real) and not os.path.isfile(real):
        raise Refusal("%s exists and is not a regular file" % real)
    return real


def umask_mode():
    current = os.umask(0)
    os.umask(current)
    return 0o666 & ~current


def atomic_write(path, text, default_mode, guard=None):
    """Write text via a temp file in the same directory and os.replace; keep the file's existing mode.

    guard, when given, is called right before the replace and must return True, else the temp file is
    dropped and False is returned (used to detect a concurrent writer)."""
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        mode = default_mode
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        if guard is not None and not guard():
            os.unlink(tmp)
            return False
        os.replace(tmp, path)
    except BaseException:
        if os.path.lexists(tmp):
            os.unlink(tmp)
        raise
    return True


def kind_name(mode):
    for test, name in ((stat.S_ISFIFO, "a FIFO"), (stat.S_ISCHR, "a character device"),
                       (stat.S_ISBLK, "a block device"), (stat.S_ISSOCK, "a socket"), (stat.S_ISDIR, "a directory")):
        if test(mode):
            return name
    return "a special file"


def read_bytes(path, cap, cap_name):
    """Bytes of the regular file path resolves to, or None when nothing is there. Raises Unreadable for a FIFO,
    device, socket or directory (without opening it) and for a file over cap bytes; OSError when it cannot be read.
    The open is non-blocking and fstat-checked, so a file swapped for a FIFO after the stat cannot hang the read."""
    real = os.path.realpath(path)
    try:
        st = os.stat(real)
    except (FileNotFoundError, NotADirectoryError):
        return None
    if not stat.S_ISREG(st.st_mode):
        raise Unreadable("%s, not a regular file" % kind_name(st.st_mode))
    if st.st_size > cap:
        raise Unreadable("%d bytes over the %s cap" % (st.st_size, cap_name))
    fd = os.open(real, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOCTTY", 0))
    with os.fdopen(fd, "rb") as handle:
        st = os.fstat(handle.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise Unreadable("%s, not a regular file" % kind_name(st.st_mode))
        data = handle.read(cap + 1)
    if len(data) > cap:
        raise Unreadable("over the %s cap" % cap_name)
    return data


def read_text(path):
    """A settings, state, config or git file the script may rewrite, or None when missing. Bytes that are not UTF-8
    survive a rewrite unchanged (surrogateescape). Raises Refusal when the file is unsafe or unreadable."""
    try:
        data = read_bytes(path, READ_MAX_BYTES, "%d byte read" % READ_MAX_BYTES)
    except Unreadable as err:
        raise Refusal("%s is %s; refusing to read it, nothing was written" % (path, err))
    except OSError as err:
        raise Refusal("cannot read %s (%s); nothing was written" % (path, err.strerror or err))
    return None if data is None else data.decode("utf-8", "surrogateescape")


def read_instruction(path):
    """Text of an instruction file for scanning, or None when missing (decoded with errors="replace").
    Raises Unreadable (not a regular file, over SCAN_MAX_BYTES) or OSError."""
    data = read_bytes(path, SCAN_MAX_BYTES, "scan")
    return None if data is None else data.decode("utf-8", "replace")


def import_line(path):
    # Claude Code ends an @path at the first unescaped space.
    return "@" + path.replace(" ", "\\ ")


# ---------- git ----------

def git(root, *args):
    # surrogateescape: a tracked path that is not UTF-8 maps back to its own bytes instead of crashing the decode.
    proc = subprocess.run(["git", "-C", root] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, encoding="utf-8", errors="surrogateescape")
    return proc.returncode, proc.stdout


def primary_checkout(raw, home):
    path = os.path.abspath(expand(raw, home))
    real = os.path.realpath(path)
    if not os.path.isdir(real):
        raise Refusal("%s: not a directory" % raw)
    dotgit = os.path.join(real, ".git")
    if os.path.islink(dotgit) or not os.path.isdir(dotgit):
        raise Refusal("%s: not a git repo's primary checkout (.git is not a directory; linked worktrees and "
                      "submodules are refused, link the main checkout instead)" % raw)
    code, out = git(real, "rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir")
    lines = out.splitlines()
    if code != 0 or len(lines) != 3:
        raise Refusal("%s: git rev-parse failed; not a usable git checkout" % raw)
    top, git_dir, common = lines
    common = os.path.join(real, common) if not os.path.isabs(common) else common
    want = os.path.realpath(dotgit)
    if (os.path.realpath(top) != real or os.path.realpath(git_dir) != want
            or os.path.realpath(common) != want):
        raise Refusal("%s: not the repo root's primary checkout (toplevel %s)" % (raw, top))
    return real


def is_tracked(root, rel):
    code, _ = git(root, "ls-files", "--error-unmatch", "--", rel)
    return code == 0


def is_ignored(root, rel):
    code, _ = git(root, "check-ignore", "-q", "--", rel)
    return code == 0


# ---------- planning ----------

class Change(object):
    """One file write. text is the full new content; lines are what the plan prints."""

    def __init__(self, label, path, text, lines, default_mode):
        self.label = label
        self.path = path
        self.text = text
        self.lines = lines
        self.default_mode = default_mode


def load_json_object(path, what):
    text = read_text(path)
    if text is None:
        return None
    try:
        data = json.loads(text)
    except ValueError as err:
        raise Refusal("%s does not parse as JSON (%s); fix it first, nothing was written" % (what, err))
    if not isinstance(data, dict):
        raise Refusal("%s is not a JSON object; fix it first, nothing was written" % what)
    return data


def plan_settings(root, siblings, memory, home, mode):
    path = safe_target(root, SETTINGS_REL)
    data = load_json_object(path, path)
    is_new = data is None
    data = {} if data is None else data
    lines = []
    if memory is not None:
        value, absolute = memory
        current = data.get("autoMemoryDirectory")
        same = isinstance(current, str) and os.path.realpath(expand(current, home)) == os.path.realpath(absolute)
        if not same:
            if current is None:
                lines.append("+ autoMemoryDirectory = %s" % json.dumps(value))
            else:
                lines.append("~ autoMemoryDirectory %s -> %s (WARNING: replaces a different memory dir)"
                             % (json.dumps(current), json.dumps(value)))
            data["autoMemoryDirectory"] = value
    perms = data.get("permissions")
    if perms is None:
        perms = {}
    if not isinstance(perms, dict):
        raise Refusal("%s: permissions is not an object; fix it first" % path)
    dirs = perms.get("additionalDirectories")
    if dirs is None:
        dirs = []
    if not isinstance(dirs, list):
        raise Refusal("%s: permissions.additionalDirectories is not a list; fix it first" % path)
    have = set()
    for entry in dirs:
        if isinstance(entry, str):
            have.add(os.path.realpath(os.path.join(root, expand(entry, home))))
    added = [s for s in siblings if s not in have]
    if added:
        dirs = dirs + added
        perms["additionalDirectories"] = dirs
        data["permissions"] = perms
        lines.extend("+ permissions.additionalDirectories += %s" % json.dumps(s) for s in added)
    if not lines:
        return None
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    return Change(SETTINGS_REL + (" (create)" if is_new else " (merge)"), path, text, lines, mode)


def rule_text(group, siblings):
    out = [
        "# Linked repos: group %s" % group,
        "",
        "Generated by workbench link-repos; local and git-excluded, so rerun the skill instead of editing.",
        "Sessions here also have file access to the sibling repos below (permissions.additionalDirectories).",
        "That grants file access only, so their instructions are imported here and apply to cross-repo work.",
    ]
    for sib in siblings:
        out.append("")
        out.append("Sibling `%s`:" % sib)
        found = False
        for name in SIBLING_FILES:
            target = os.path.join(sib, name)
            if os.path.isfile(target):
                out.append(import_line(target))
                found = True
        if not found:
            out.append("(no CLAUDE.md or CLAUDE.local.md yet; rerun link-repos after adding one)")
    return "\n".join(out) + "\n"


def plan_rule(root, group, siblings, mode):
    path = safe_target(root, RULE_REL)
    text = rule_text(group, siblings)
    current = read_text(path)
    if current == text:
        return None
    lines = ["| " + line if line else "|" for line in text.rstrip("\n").split("\n")]
    return Change(RULE_REL + (" (create)" if current is None else " (rewrite)"), path, text, lines, mode)


def plan_exclude(root, mode):
    path = safe_target(root, EXCLUDE_REL)
    current = read_text(path) or ""
    present = set(line.strip() for line in current.splitlines())
    missing = [line for line in EXCLUDE_LINES if line not in present and not is_ignored(root, line)]
    if not missing:
        return None
    text = current
    if text and not text.endswith("\n"):
        text += "\n"
    text += "# workbench link-repos: local-only Claude files\n" + "".join(line + "\n" for line in missing)
    return Change(EXCLUDE_REL + " (append)", path, text, ["+ " + line for line in missing], mode)


def plan_worktreeinclude(root, mode, notes):
    path = safe_target(root, WTI_REL)
    current = read_text(path)
    present = set(line.strip() for line in (current or "").splitlines())
    if ".env" in present:
        notes.append("%s/%s copies .env into new worktrees; each worktree usually needs its own" % (root, WTI_REL))
    missing = [line for line in WTI_LINES if line not in present]
    if not missing:
        return None
    if current is None:
        text = ("# Gitignored files Claude Code copies into each new worktree (local-only, git-excluded).\n"
                "# Never add .env: each worktree needs its own.\n")
    else:
        text = current if (not current or current.endswith("\n")) else current + "\n"
    text += "".join(line + "\n" for line in missing)
    return Change(WTI_REL + (" (create)" if current is None else " (append)"), path, text,
                  ["+ " + line for line in missing], mode)


def bridge_notes(root, siblings, home, notes):
    """Point out hand-built bridges that already import a sibling, so nothing loads twice by surprise."""
    for rel in ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"]:
        path = os.path.join(root, rel)
        if not within(os.path.realpath(path), root):
            continue  # never opened; the scan lists it as [external]
        try:
            text = read_instruction(path)
        except (Unreadable, OSError):
            continue  # the scan lists it as [unscanned], or Claude Code cannot read it either
        if not text:
            continue
        for sib in siblings:
            forms = [sib]
            if within(sib, os.path.realpath(home)):
                forms.append("~/" + os.path.relpath(sib, os.path.realpath(home)))
            if any("@" + form + "/" in text for form in forms):
                notes.append("%s/%s already imports from %s (a hand-built bridge?); the generated rule covers it, "
                             "so that import can go. Left unchanged." % (root, rel, sib))


def plan_repo(root, repos, group, memory, home, mode, notes):
    siblings = [r for r in repos if r != root]
    changes = []
    for rel, planner in [
        (SETTINGS_REL, lambda: plan_settings(root, siblings, memory, home, mode)),
        (RULE_REL, lambda: plan_rule(root, group, siblings, mode)),
        (EXCLUDE_REL, lambda: plan_exclude(root, mode)),
        (WTI_REL, lambda: plan_worktreeinclude(root, mode, notes)),
    ]:
        if rel != EXCLUDE_REL and is_tracked(root, rel):
            notes.append("%s/%s is tracked by git, so it is shared with the team; left unchanged. "
                         "Make the change by hand if it belongs there." % (root, rel))
            continue
        change = planner()
        if change is not None:
            changes.append(change)
    bridge_notes(root, siblings, home, notes)
    return changes


# ---------- external imports ----------
# ponytail: a line-based approximation of CommonMark. Wherever it is unsure it keeps the text, so a mistake can
# only add an [external] line, never hide one: unclosed fences, indented code, fences inside HTML blocks,
# blockquotes or list markers, and code spans on a line with a pipe, inline HTML or an escaped backtick stay checked.

def leading_spaces(line):
    expanded = line.expandtabs(4)
    return len(expanded) - len(expanded.lstrip(" "))


def html_block_end(lines, i):
    """Index of the last line of the HTML block starting at line i (CommonMark end conditions), or None."""
    match = HTML_OPEN_RE.match(lines[i])
    if match is None:
        return None
    kind = match.group(1).lower()
    if kind in ("script", "pre", "style", "textarea"):
        done = RAW_HTML_END_RE.search
    elif kind.startswith("!") or kind == "?":
        end = HTML_ENDS.get(kind, ">")
        done = lambda line: end in line
    else:
        j = i
        while j + 1 < len(lines) and lines[j + 1].strip():
            j += 1
        return j
    return next((j for j in range(i, len(lines)) if done(lines[j])), len(lines) - 1)


def fence_block_end(lines, i):
    """Index of the closing fence of a fenced code block opening at line i, or None to keep the lines checked."""
    match = FENCE_RE.match(lines[i])
    if match is None:
        return None
    pad, fence, info = len(match.group(1)), match.group(2), match.group(3)
    if fence[0] == "`" and "`" in info:
        return None
    for j in range(i + 1, len(lines)):
        close = FENCE_CLOSE_RE.match(lines[j])
        if close and close.group(1)[0] == fence[0] and len(close.group(1)) >= len(fence):
            return j
        if pad and lines[j].strip() and leading_spaces(lines[j]) < pad:
            return None  # an indented fence may sit in a list item that ends here, closing the fence early
    return None  # unclosed


def line_spans(line):
    """CommonMark code-span pairing within one line: ([(start, end)], has_unpaired_backtick_run)."""
    runs = [(m.start(), m.end()) for m in re.finditer(r"`+", line)]
    spans, unpaired, k = [], False, 0
    while k < len(runs):
        start, end = runs[k]
        j = next((j for j in range(k + 1, len(runs)) if runs[j][1] - runs[j][0] == end - start), None)
        if j is None:
            unpaired = True
            k += 1
        else:
            spans.append((start, runs[j][1]))
            k = j + 1
    return spans, unpaired


def code_free_lines(text):
    """text's lines with fenced code blocks and code spans blanked, as Claude Code skips @imports there."""
    lines = text.split("\n")
    out = list(lines)
    block = []  # line indexes of the current run of plain non-blank lines (roughly one paragraph)

    def flush():
        # A backtick run left unpaired on one line can pair with one on a later line, so strip spans only when
        # every line of the run pairs its own backticks.
        if not any(line_spans(lines[k])[1] or "\\`" in lines[k] for k in block):
            for k in block:
                if "|" in lines[k] or INLINE_HTML_RE.search(lines[k]):
                    continue
                line = lines[k]
                for start, end in reversed(line_spans(line)[0]):
                    line = line[:start] + " " + line[end:]
                out[k] = line
        del block[:]

    i = 0
    while i < len(lines):
        end = html_block_end(lines, i)
        if end is None:
            end = fence_block_end(lines, i)
            if end is not None:
                for k in range(i, end + 1):
                    out[k] = ""
        if end is not None:
            flush()
            i = end + 1
            continue
        if lines[i].strip():
            block.append(i)
        else:
            flush()
        i += 1
    flush()
    return out


def import_target(token, base_dir, home):
    # Trailing markup and punctuation (**, a sentence's full stop) are not part of the file Claude Code loads.
    path = token.split("#", 1)[0].replace("\\ ", " ").rstrip("*_`'\",.;:!?)]}>")
    if not path:
        return None
    if path == "~" or path.startswith("~/"):
        path = expand(path, home)
    elif not os.path.isabs(path):
        path = os.path.join(base_dir, path)
    return os.path.normpath(path)


def instruction_files(root):
    paths = [os.path.join(root, rel) for rel in SCAN_ROOTS]
    stack, seen = [os.path.join(root, RULES_DIR)], set()
    while stack:
        directory = stack.pop()
        real = os.path.realpath(directory)
        if real in seen or not os.path.isdir(real):
            continue
        seen.add(real)
        if not within(real, root):
            paths.append(directory)  # a symlinked rules dir that leaves the repo; reported, not entered
            continue
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            path = os.path.join(directory, name)
            if os.path.isdir(path):
                stack.append(path)
            elif name.endswith(".md"):
                paths.append(path)
    code, out = git(root, "ls-files", "-z")
    if code == 0:
        for rel in out.split("\0"):
            if os.path.basename(rel) in SCAN_NAMES or ("/" + RULES_DIR + "/" in "/" + rel and rel.endswith(".md")):
                paths.append(os.path.join(root, rel))
    return paths


def scan_externals(root, siblings, home, overrides, unscanned):
    """External @imports and symlinks reachable from root's instruction files, minus the sibling bridge.

    overrides maps a real path to the text it will have after --apply (the regenerated rule file). Files outside
    the repo are never opened: they may hold secrets, and the approval covers them whatever they import.
    A file over SCAN_MAX_BYTES or not a regular file (FIFO, device, socket; in the repo or as an outside target) is
    not read; (path, reason) goes into the unscanned list instead. Directories are skipped."""
    bridge = set(os.path.realpath(os.path.join(s, name)) for s in siblings for name in SIBLING_FILES)
    found = []
    queue = collections.deque((path, 0) for path in instruction_files(root) + sorted(overrides))
    seen = set()
    while queue:
        path, hops = queue.popleft()
        real = os.path.realpath(path)
        if real in seen:
            continue
        seen.add(real)
        if not within(real, root):
            if os.path.lexists(path) and real not in bridge:
                found.append(External(root, path, None, None, real))
                note_special(real, unscanned)
            continue
        text = overrides.get(real)
        if text is None:
            if os.path.isdir(real):
                continue
            try:
                text = read_instruction(real)
            except Unreadable as err:
                unscanned.append((path, str(err)))
                continue
            except OSError:
                continue  # unreadable for this user, so Claude Code cannot load it either
            if text is None:
                continue
        for number, line in enumerate(code_free_lines(text), 1):
            for match in IMPORT_RE.finditer(line):
                target = import_target(match.group(1), os.path.dirname(path), home)
                if target is None:
                    continue
                target_real = os.path.realpath(target)
                if target_real in bridge:
                    continue
                if within(target, root) and within(target_real, root):
                    if hops < MAX_IMPORT_HOPS:
                        queue.append((target, hops + 1))
                else:
                    found.append(External(root, path, number, "@" + match.group(1), target_real))
                    note_special(target_real, unscanned)
    return found


def note_special(real, unscanned):
    """An outside target is never opened, but a FIFO or device there would hang or flood Claude Code when it loads
    the import, so it goes on the unscanned list (which --allow-external cannot override). Stat only."""
    try:
        mode = os.stat(real).st_mode
    except OSError:
        return
    if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
        entry = (real, "%s, not a regular file" % kind_name(mode))
        if entry not in unscanned:
            unscanned.append(entry)


def allow_forms(raw, home):
    path = os.path.normpath(os.path.abspath(expand(raw, home)))
    return set([path, os.path.realpath(path)])


def recorded_approvals(claude_json):
    """Repos whose external-import approval is already recorded (read only; errors mean none)."""
    if not os.path.isfile(claude_json):
        return set()
    try:
        data = load_json_object(claude_json, claude_json)
    except Refusal:
        return set()
    projects = (data or {}).get("projects")
    if not isinstance(projects, dict):
        return set()
    return set(repo for repo, entry in projects.items()
               if isinstance(entry, dict) and entry.get(APPROVAL_KEYS[0]) is True)


def plan_memory(memory, group, repos):
    if memory is None:
        return None, None
    absolute = memory[1]
    index = os.path.join(absolute, "MEMORY.md")
    if os.path.lexists(index):
        return None, index
    names = ", ".join(os.path.basename(r) for r in repos)
    text = ("# Memory Index (shared by group %s: %s)\n"
            "One line per memory; the detail lives in topic files next to this one. Keep this index under\n"
            "200 lines and 25 KB: Claude Code stops loading it past that.\n" % (group, names))
    return text, index


def claude_json_sig(path):
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None
    return (st.st_mtime_ns, st.st_size, st.st_ino)


def plan_approvals(claude_json, repos):
    """Returns (data, trailing_newline, [(repo, keys to set)]); raises Refusal on an unsafe file."""
    if os.path.islink(claude_json):
        raise Refusal("%s is a symlink; refusing to follow or replace it. Set %s to true under projects[<repo>] "
                      "by hand." % (claude_json, " and ".join(APPROVAL_KEYS)))
    if os.path.exists(claude_json) and not os.path.isfile(claude_json):
        raise Refusal("%s is not a regular file" % claude_json)
    raw = read_text(claude_json)
    data = load_json_object(claude_json, claude_json)
    data = {} if data is None else data
    projects = data.get("projects")
    if projects is None:
        projects = {}
    if not isinstance(projects, dict):
        raise Refusal("%s: projects is not an object; fix it first" % claude_json)
    todo = []
    for repo in repos:
        entry = projects.get(repo)
        if entry is None:
            entry = {}
        if not isinstance(entry, dict):
            raise Refusal("%s: projects[%s] is not an object; fix it first" % (claude_json, repo))
        keys = [k for k in APPROVAL_KEYS if entry.get(k) is not True]
        if keys:
            for k in keys:
                entry[k] = True
            projects[repo] = entry
            todo.append((repo, keys))
    data["projects"] = projects
    trailing = raw is None or raw.endswith("\n")
    return data, trailing, todo


def apply_approvals(claude_json, repos):
    """Read-modify-write with a retry when Claude Code writes the file between our read and our replace."""
    for _ in range(5):
        before = claude_json_sig(claude_json)
        data, trailing, todo = plan_approvals(claude_json, repos)
        if not todo:
            return todo
        text = json.dumps(data, indent=2, ensure_ascii=False) + ("\n" if trailing else "")
        # ponytail: the stat check narrows, but cannot close, the window between the check and os.replace.
        if atomic_write(claude_json, text, 0o600, guard=lambda: claude_json_sig(claude_json) == before):
            return todo
    raise Refusal("%s kept changing while being updated (a running Claude Code writes it); retry" % claude_json)


# ---------- main ----------

def parse_args(argv):
    parser = argparse.ArgumentParser(description="Link git repos into one Claude Code session with shared memory.")
    parser.add_argument("--group", help="group name (used in the generated rule and memory index)")
    parser.add_argument("--from-config", metavar="NAME",
                        help="read the group from repo_groups in $WORKBENCH_CONFIG or ~/.claude/workbench.json")
    parser.add_argument("--memory-dir", help="shared auto-memory directory (absolute or ~/...)")
    parser.add_argument("--apply", action="store_true", help="write the changes (default: dry run)")
    parser.add_argument("--approve-imports", action="store_true",
                        help="mark external @imports approved for each repo in <home>/.claude.json")
    parser.add_argument("--allow-external", metavar="PATH", action="append", default=[],
                        help="an [external] target --approve-imports may approve; repeat once per target")
    parser.add_argument("--home", help="home directory to use instead of $HOME (tests use a sandbox)")
    parser.add_argument("repos", nargs="*", help="primary checkouts of the repos to link")
    return parser.parse_args(argv)


def config_paths(args, home):
    """(config_dir, claude_json). --home wins and means <home>/.claude and <home>/.claude.json. Without it,
    CLAUDE_CONFIG_DIR moves both the config dir and .claude.json inside it; otherwise ~/.claude and ~/.claude.json
    (https://code.claude.com/docs/en/claude-directory: with CLAUDE_CONFIG_DIR set, `.claude.json` lives under it)."""
    if args.home:
        return os.path.join(home, ".claude"), os.path.join(home, ".claude.json")
    override = os.environ.get("CLAUDE_CONFIG_DIR")
    if override:
        config_dir = os.path.abspath(expand(override, home))
        return config_dir, os.path.join(config_dir, ".claude.json")
    return os.path.join(home, ".claude"), os.path.join(home, ".claude.json")


def resolve_group(args, home):
    if args.from_config:
        if args.group or args.repos:
            raise Refusal("--from-config takes the group and repos from the workbench config; drop --group and "
                          "REPO arguments")
        config = os.environ.get("WORKBENCH_CONFIG") or os.path.join(config_paths(args, home)[0], "workbench.json")
        data = load_json_object(config, config)
        if data is None:
            raise Refusal("%s not found; create it or pass --group NAME REPO REPO" % config)
        groups = data.get("repo_groups") or []
        match = [g for g in groups if isinstance(g, dict) and g.get("name") == args.from_config]
        if not match:
            raise Refusal("no repo_groups entry named %r in %s" % (args.from_config, config))
        group = match[0]
        repos = group.get("repos") or []
        if not isinstance(repos, list) or not all(isinstance(r, str) for r in repos):
            raise Refusal("repo_groups[%s].repos must be a list of paths" % args.from_config)
        memory_dir = args.memory_dir or group.get("memory_dir")
        return args.from_config, repos, memory_dir
    if not args.group:
        raise Refusal("pass --group NAME with two or more repos, or --from-config NAME")
    return args.group, args.repos, args.memory_dir


def resolve_memory(memory_dir, home):
    if not memory_dir:
        return None
    absolute = os.path.abspath(expand(memory_dir, home))
    home_real = os.path.realpath(home)
    real = os.path.realpath(absolute)
    if within(real, home_real) and real != home_real:
        return ("~/" + os.path.relpath(real, home_real), absolute)
    return (absolute, absolute)


def run(argv):
    args = parse_args(argv)
    home = os.path.abspath(args.home or os.environ.get("HOME") or os.path.expanduser("~"))
    group, raw_repos, memory_dir = resolve_group(args, home)
    repos = []
    for raw in raw_repos:
        real = primary_checkout(raw, home)
        if real not in repos:
            repos.append(real)
    if len(repos) < 2:
        raise Refusal("need at least two distinct repos to link (got %d)" % len(repos))
    memory = resolve_memory(memory_dir, home)
    if memory is not None and any(within(os.path.realpath(memory[1]), r) for r in repos):
        raise Refusal("memory dir %s is inside a linked repo; pick a directory outside the repos" % memory[1])
    mode = umask_mode()
    claude_json = config_paths(args, home)[1]

    # Plan everything first, so every refusal happens before the first write.
    notes = []
    per_repo = [(root, plan_repo(root, repos, group, memory, home, mode, notes)) for root in repos]
    memory_text, memory_index = plan_memory(memory, group, repos)
    approvals = plan_approvals(claude_json, repos)[2] if args.approve_imports else []
    # Every repo's instruction file is imported by its siblings, so any such file means external imports.
    has_imports = any(os.path.isfile(os.path.join(r, name)) for r in repos for name in SIBLING_FILES)
    needs_approval = False
    if has_imports and not args.approve_imports:
        try:
            needs_approval = bool(plan_approvals(claude_json, repos)[2])
        except Refusal:
            needs_approval = True
    # The approval flag covers every external import of the project, so find the ones that are not the bridge.
    externals = []
    unscanned = []
    for root, changes in per_repo:
        overrides = dict((c.path, c.text) for c in changes if c.label.startswith(RULE_REL + " "))
        externals.extend(scan_externals(root, [r for r in repos if r != root], home, overrides, unscanned))
    allowed = set()
    for raw in args.allow_external:
        forms = allow_forms(raw, home)
        allowed |= forms
        if not any(ext.target in forms for ext in externals):
            notes.append("--allow-external %s matches no [external] line; ignored" % raw)
    blocked = [ext for ext in externals if ext.target not in allowed]
    approved = recorded_approvals(claude_json)

    total = 0
    print("Group %s: %d repos%s" % (group, len(repos), ", memory dir %s" % memory[0] if memory else ""))
    for root, changes in per_repo:
        print("[repo] %s" % root)
        if not changes:
            print("  = up to date")
        for change in changes:
            total += 1
            print("  %s" % change.label)
            for line in change.lines:
                print("      %s" % line)
    if memory is not None:
        if memory_text is None:
            print("[memory] %s: index exists, left unchanged" % memory_index)
        else:
            total += 1
            print("[memory] %s (create)" % memory_index)
    for repo, keys in approvals:
        total += 1
        print("[%s] projects[%s]: set %s = true" % (claude_json, json.dumps(repo), ", ".join(keys)))
    for ext in externals:
        where = ext.source if ext.line is None else "%s:%d" % (ext.source, ext.line)
        tags = []
        if not os.path.lexists(ext.target):
            tags.append("missing now")
        if ext.target in allowed:
            tags.append("allowed by --allow-external")
        elif ext.repo in approved:
            tags.append("WARNING: this repo's import approval is already recorded, so it loads without asking")
        print("[external] %s: %s -> %s%s" % (where, ext.token or "symlink", ext.target,
                                              " (%s)" % "; ".join(tags) if tags else ""))
    for path, reason in unscanned:
        print("[unscanned] %s: %s" % (path, reason))
    for note in notes:
        print("note: %s" % note)
    if needs_approval:
        print("hint: the rule imports files outside each repo. Claude Code asks once per project before loading "
              "external imports; rerun with --approve-imports to record that approval in %s instead." % claude_json)
    if unscanned and args.approve_imports:
        raise Refusal("--approve-imports refused: %d instruction file(s) were not scanned for external imports (the "
                      "[unscanned] lines above: over the %d byte scan cap, or not a regular file). Shrink or split "
                      "them, or replace a FIFO or device with a regular file, then rerun. Nothing was written."
                      % (len(unscanned), SCAN_MAX_BYTES), code=3)
    if blocked:
        if not args.approve_imports:
            print("hint: the approval is one flag per project, so it would cover the %d [external] line(s) above "
                  "too. --approve-imports refuses until --allow-external names each target." % len(blocked))
        else:
            raise Refusal("--approve-imports would also approve %d external import(s) that no --allow-external "
                          "names (the [external] lines above). Read each target, then rerun with "
                          "--allow-external PATH for each one you trust, or remove the import. Nothing was written."
                          % len(blocked), code=3)

    if not args.apply:
        print("Summary: %d change(s) planned. Dry run: nothing written; rerun with --apply to write them." % total)
        return 0

    for root, changes in per_repo:
        for change in changes:
            os.makedirs(os.path.dirname(change.path), exist_ok=True)
            atomic_write(change.path, change.text, change.default_mode)
    if memory_text is not None:
        os.makedirs(memory[1], exist_ok=True)
        with open(memory_index, "x", encoding="utf-8", errors="surrogateescape") as handle:
            handle.write(memory_text)
    if args.approve_imports:
        apply_approvals(claude_json, repos)
    print("Summary: %d change(s) applied." % total)
    return 0


def main():
    # A path or file name that is not UTF-8 prints as escapes instead of raising UnicodeEncodeError.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    try:
        sys.exit(run(sys.argv[1:]))
    except Refusal as err:
        print("refused: %s" % err, file=sys.stderr)
        sys.exit(err.code)


if __name__ == "__main__":
    main()
