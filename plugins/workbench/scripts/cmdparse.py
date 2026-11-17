#!/usr/bin/env -S python3 -I
"""workbench command parser, shared by guard.sh, commit_gate.sh and browser_cap.sh. Stdlib only, Python 3.8+.

Reads {"command": ..., "cwd": ..., "bodies": true|false} as JSON on stdin. Prints one JSON object per shell
segment, one per line:
  {"dir": effective dir, "argv": [...], "raw": segment text, "git": {"sub": ..., "args": [...]} | null,
   "uv_run": argv of the program `uv run`, `uv tool run` or `uvx` starts, wrappers dropped | null,
   "stdin": [files fed to its stdin by < or by a `cat F |` before it] (only when any),
   "subfiles": [files printed by cat F or <F inside its $(...) or `...`, not piped on] (only when any),
   "assigns": true when it sets a variable for later segments (NAME=... alone, export NAME=...) (only when so),
   "envpre": the NAME=value words in front of the bash -c, eval or git command that runs it (nested records
   only, outermost first, one per line),
   "text": what the segment itself says (git commit, gh and glab only), "msgfiles", "stdin_msg", "feed",
   "pretext", "pydirs", "unparsed", "fb" (described below)}
When the request asks for "bodies", each record also carries (only when any) "bodies": its heredoc and here-string
bodies; "writes": the files it writes (> >> >| &> &>> targets, tee's operands, sed -i or perl -i operands, the
cp or mv target); "paths": word -> file for the program when run by path and each non-option word (a name with
an unknown $VAR stays as written, so it matches the same word in "writes"); "up": the indexes of the records piped
into it; "inmsg": true for the commands in the $(...) of a git commit, gh or glab segment.
File paths are absolute, seen from the shell's dir (not git -C). Segments end at ; && || | & newline ( ), also
when shlex glues an operator to a redirection (`;>`, `&&<`, `|>`), and after the `{` of `function NAME {`. argv
drops leading NAME=value words, shell keywords (if, then, do, !, {), the fd number of a redirection (2>) and the
wrappers time, nohup, exec, env, command, builtin, nice, timeout and xargs. `cd X` moves the dir for later
segments (a subshell's cd ends at its `)`); `git -C X`, `env -C X` and `uv [run] --directory X` or `--project X`
move it for that segment only. Before splitting, heredoc bodies and # comments are dropped, and each $(...),
`...`, <(...) or >(...) body is parsed as its own segments (as are the string of `bash -c STRING`, `eval WORDS`,
the command of `git submodule foreach`, `git rebase --exec` or `-x` and `git bisect run`, with each word quoted
as git passes it, the $(...) in an unquoted heredoc body, which the shell runs, and the heredoc or here-string
body that an earlier segment wrote to a file (cat > F <<EOF, tee F <<EOF, cat <<EOF | tee F) when a shell runs F
as its script (bash F, sh -e F) or F is the program run by path (./F, unless its #! line names a non-shell), in
that segment's dir), so words inside messages never count as commands. uvx and `uv tool run` drop a version or
extras spec from the tool word (pytest@8 -> pytest). $'...' is one quoted word in which a backslash escapes the
next character (\\' included).
"text" is the segment's words, with each $(...) replaced by the text of the commands inside it, plus the heredoc
and here-string bodies it reads. Of sed, grep, rg, awk and perl (and their variants) only the heredoc and
here-string bodies count, here and below: their words are patterns. "msgfiles" are the files named by -F, --file
or --body-file; "stdin_msg" says one of them is stdin (-, /dev/stdin) or a bare `cat` in its $(...) reads stdin
("$(cat)"), and then "feed" holds the text of the commands piped into it from the last sed/grep/rg/awk/perl on.
A commit, gh or glab segment that reads a file (msgfiles, subfiles) or stdin, or has a $VAR word (after `commit`
for git), may carry text an earlier segment wrote: its "pretext" is the text of every earlier segment in the
command. "pydirs": for a bare python or pip, or a .venv/bin python or pip, the dirs of the paths it runs
(python's script, pip's path operands; not the program's own dir). Paths expand ~, $HOME, $TMPDIR (from this process's env) and $PWD or $(pwd) (the segment's shell dir),
also as ${...}; any other $VAR leaves a path unknown.
"unparsed": true marks a segment that runs code this parser cannot see, and "fb" is the text the hooks then scan
with whole-text regexes: its raw text and heredoc bodies plus the raw text of the commands piped into it, and for
eval or bash -c of $NAME, of the earlier segments that set NAME (NAME=..., export NAME=...) plus the value on a
line of its own. That is a shell (bash, sh, zsh, dash, ksh) reading its script from stdin (no -c and no script
operand, -s, or - or /dev/stdin as the script), source or . of stdin, eval of a word holding a $VAR, bash -c of a
bare $VAR or ${VAR} (a literal script that merely holds a $ is parsed), and eval, bash -c or source of a $(...)
or <(...) that prints text written in the command (echo, printf, or a heredoc or here-string). The segment is
still parsed as far as it goes. `source "$HOME/x"` and `eval "$(ssh-agent -s)"` are not unparsed: the code they
run is invisible either way. When the text cannot be split at all (unbalanced quotes), the only record is
{"dir": cwd, "argv": [], "raw": command, "fb": command, "unparsed": true}.
ponytail: a shell-like reading, not bash itself. Aliases, functions, case patterns inside $( ) and unknown
$VAR values are not resolved; sandboxing is the real wall.
"""
import json
import os
import re
import shlex
import sys

PUNCT = ";&|()<>\n"
HIDE = {c: chr(0xE100 + i) for i, c in enumerate(PUNCT)}  # quoted punctuation, so it never splits a segment
SQ = chr(0xE100 + len(PUNCT))  # a ' inside $'...', so the word stays one single-quoted word
UNHIDE = str.maketrans({**{v: k for k, v in HIDE.items()}, SQ: "'"})
ANSI_C = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"'}  # other \X escapes stay as written
S_OPEN, S_CLOSE, H_OPEN, H_CLOSE = chr(0xE000), chr(0xE001), chr(0xE002), chr(0xE003)
SUB = re.compile(S_OPEN + "([0-9]+)" + S_CLOSE)  # placeholder left where a $(...), `...` or <(...) was
HD = re.compile(H_OPEN + "([0-9]+)" + H_CLOSE)  # placeholder for a heredoc's delimiter word
ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")
# shlex returns a run of punctuation as one token (";>", "&&<", ")|"); OPS splits it into bash's operators.
OPS = re.compile(r";;&|;;|;&|\|\||\|&|&&|&>>|&>|<<<|<<|<>|<&|>>|>&|>\||[;&|()<>\n]")
REDIRS = {"<", ">", ">>", "<<", "<<<", "<>", "<&", ">&", ">|", "&>", "&>>"}
WRITE_OPS = {">", ">>", ">|", "&>", "&>>"}
KEYWORDS = {"!", "{", "if", "then", "else", "elif", "do", "while", "until"}
WRAPPERS = {  # wrapper -> its options that take a separate value
    "time": set(), "nohup": set(), "builtin": set(), "command": set(), "exec": {"-a"},
    "env": {"-u", "--unset", "-P", "-S", "--split-string", "-C", "--chdir"},
    "nice": {"-n", "--adjustment"}, "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "xargs": {"-I", "-L", "-n", "-P", "-s", "-E", "-d", "-a", "-J", "-R", "-S"},
}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
SHELL_VALUE_OPTS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
STDIN_NAMES = {"-", "/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"}
FILTERS = {"sed", "gsed", "grep", "egrep", "fgrep", "ggrep", "rg", "awk", "gawk", "mawk", "nawk", "perl"}
PRINTERS = {"echo", "printf"}
DECLARE = {"export", "declare", "typeset", "local", "readonly"}
VARREF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")  # the name in $NAME or ${NAME...}
VARWORD = re.compile(r"\$[{A-Za-z_0-9@*]")  # a word that expands a variable (not $( or $'...')
BAREVAR = re.compile(r"\s*(\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*]|\{[^{}]*\})\s*)+")  # "$X", "${X}", "$X $Y" only
PYEXE = re.compile(r"python(3(\.[0-9]+)?)?$")
PIPEXE = re.compile(r"pip(3(\.[0-9]+)?)?$")
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env",
                  "--attr-source"}
UV_VALUE_OPTS = {
    "--directory", "--project", "--cache-dir", "--config-file", "--python", "-p", "--with", "-w", "--with-editable",
    "--with-requirements", "--env-file", "--extra", "--no-extra", "--group", "--no-group", "--only-group",
    "--package", "--index", "--default-index", "--index-url", "-i", "--extra-index-url", "--find-links", "-f",
    "--color", "--python-platform", "--allow-insecure-host", "--resolution", "--prerelease", "--exclude-newer",
    "--link-mode", "--keyring-provider", "--index-strategy", "--refresh-package", "--reinstall-package",
    "--upgrade-package", "-P", "--no-binary-package", "--no-build-package", "--config-setting", "-C", "--from",
}
UV_RUN = (["run"], ["tool", "run"])
TOOL_SPEC = re.compile(r"[@=<>~!\[].*$", re.S)  # the version or extras spec of a uvx tool word
SHEBANG = re.compile(r"#![ \t]*(?:\S*/env[ \t]+(?:-\S*[ \t]+)*)?(\S+)")  # group 1: the interpreter
MAX_DEPTH = 4


class Scan:
    """Quote-aware pass over the raw text: drops heredoc bodies (kept in self.bodies), comments, line
    continuations and the fd number of a redirection, hides quoted punctuation, and swaps each command or process
    substitution for a placeholder (its body goes to self.subs)."""

    def __init__(self, text):
        self.t, self.n = text, len(text)
        self.subs, self.kinds, self.bodies, self.hwords = [], [], [], []

    def run(self, i, stop):  # stop: None (end of text), ")" closing $( or <(, "`" closing a backtick
        t, n = self.t, self.n
        out, quote, pending, depth = [], None, [], 0
        while i < n:
            c = t[i]
            if quote == "'":
                if c == "'":
                    quote = None
                out.append(c if c == "'" else HIDE.get(c, c))
                i += 1
                continue
            if c == "\\" and i + 1 < n:
                if t[i + 1] != "\n":  # backslash-newline is a line continuation: drop both
                    out.append(c + HIDE.get(t[i + 1], t[i + 1]))
                i += 2
                continue
            if c == "$" and t.startswith("$(", i) and not t.startswith("$((", i):
                i = self.sub(i + 2, ")", out, "$(")
                continue
            if c == "`" and stop != "`":
                i = self.sub(i + 1, "`", out, "$(")
                continue
            if quote == '"':
                if c == '"':
                    quote = None
                out.append(c if c == '"' else HIDE.get(c, c))
                i += 1
                continue
            if stop == "`" and c == "`" or stop == ")" and c == ")" and depth == 0:
                return "".join(out), i + 1
            if t.startswith("$'", i):
                i = self.ansi_c(i + 2, out)
                continue
            if c in "'\"":
                quote = c
            elif c == "#" and (i == 0 or t[i - 1] in " \t\n;&|()`"):
                j = t.find("\n", i)
                i = n if j < 0 else j
                continue
            elif t.startswith("<<<", i):  # a here-string; its second < must not start a heredoc
                out.append("<<<")
                i += 3
                continue
            elif t.startswith("<<", i):
                i = self.heredoc(i, out, pending)
                continue
            elif c in "<>" and t.startswith("(", i + 1):  # process substitution <(...) or >(...)
                i = self.sub(i + 2, ")", out, c + "(")
                continue
            elif c == "\n" and pending:
                i = self.skip_bodies(i + 1, pending, out)
                out.append(c)
                pending = []
                continue
            elif c.isdigit() and (i == 0 or t[i - 1] in " \t\n;&|()"):
                j = i + 1
                while j < n and t[j].isdigit():
                    j += 1
                if j < n and t[j] in "<>":  # `2>x`: the 2 is part of the redirection, not a word
                    i = j
                    continue
            elif stop == ")" and c == "(":
                depth += 1
            elif stop == ")" and c == ")":
                depth -= 1
            out.append(c)
            i += 1
        if quote or stop:
            raise ValueError("unbalanced quote or substitution")
        return "".join(out), i

    def ansi_c(self, i, out):
        """i just after $': ANSI-C quoting, where a backslash escapes the next character (\\' included). The body
        goes out as one single-quoted word."""
        t, n, body = self.t, self.n, []
        while i < n and t[i] != "'":
            if t[i] == "\\" and i + 1 < n:
                body.append(ANSI_C.get(t[i + 1], t[i:i + 2]))
                i += 2
            else:
                body.append(t[i])
                i += 1
        if i >= n:
            raise ValueError("unbalanced $'...' quote")
        out.append("'" + "".join(SQ if c == "'" else HIDE.get(c, c) for c in "".join(body)) + "'")
        return i + 1

    def sub(self, i, stop, out, kind):
        _, end = self.run(i, stop)
        out.append("%s%d%s" % (S_OPEN, len(self.subs), S_CLOSE))
        self.subs.append(self.t[i:end - 1])
        self.kinds.append(kind)
        return end

    def heredoc(self, i, out, pending):  # i at "<<": record the delimiter, keep the operator and a placeholder
        t, n = self.t, self.n
        j = i + 2
        strip = j < n and t[j] == "-"
        j += strip
        while j < n and t[j] in " \t":
            j += 1
        k, word, quoted = j, [], False
        while k < n and t[k] not in " \t\n;&|()<>":
            if t[k] in "'\"":
                e = t.find(t[k], k + 1)
                if e < 0:
                    raise ValueError("unbalanced heredoc word")
                word.append(t[k + 1:e])
                k, quoted = e + 1, True
            elif t[k] == "\\" and k + 1 < n:
                word.append(t[k + 1])
                k, quoted = k + 2, True
            else:
                word.append(t[k])
                k += 1
        if not word:
            out.append(t[i:k])
            return k
        pending.append(("".join(word), strip, quoted, len(self.bodies)))
        out.append("<<%s%d%s" % (H_OPEN, len(self.bodies), H_CLOSE))
        self.bodies.append("")
        self.hwords.append(t[j:k])
        return k

    def skip_bodies(self, i, pending, out):
        """i at the line after the operator; returns the index after the last body. A body whose delimiter
        line never comes is kept (so `1<<2` in arithmetic hides nothing)."""
        t, n = self.t, self.n
        for word, strip, quoted, idx in pending:
            k = i
            while k < n:
                j = t.find("\n", k)
                line = t[k:] if j < 0 else t[k:j]
                start, k = k, n if j < 0 else j + 1
                if (line.lstrip("\t") if strip else line) == word:
                    self.bodies[idx] = t[i:start]
                    if not quoted:
                        self.body_subs(i, start, out)
                    i = k
                    break
            else:
                break
        return i

    def body_subs(self, a, b, out):
        """An unquoted heredoc body (t[a:b]) runs its $(...) and `...` when the shell reads it. Each one becomes a
        placeholder after <<<, so it is parsed as its own segments while the command's argv stays the same."""
        t = self.t
        while a < b:
            if t[a] == "\\":
                a += 2
            elif t.startswith("$(", a) and not t.startswith("$((", a):
                out.append(" <<<")
                a = self.sub(a + 2, ")", out, "$(")
            elif t[a] == "`":
                out.append(" <<<")
                a = self.sub(a + 1, "`", out, "$(")
            else:
                a += 1


def expand(x, sdir):
    """x with a leading ~, $HOME, $TMPDIR or $PWD/$(pwd) (sdir) expanded; None while any other $ or ` is left."""
    env = os.environ
    for pre, val in (("~", env.get("HOME")), ("$HOME", env.get("HOME")), ("${HOME}", env.get("HOME")),
                     ("$TMPDIR", env.get("TMPDIR")), ("${TMPDIR}", env.get("TMPDIR")),
                     ("$PWD", sdir), ("${PWD}", sdir), ("$(pwd)", sdir)):
        if x == pre or x.startswith(pre + "/"):
            if not val:
                return None
            x = val + x[len(pre):]
            break
    if not x or "$" in x or "`" in x or x.startswith("~"):
        return None
    return x


def resolve(base, x, sdir=None):
    """Path x seen from dir base ($PWD = sdir, default base). Unknown ($VAR, ~user) keeps base."""
    y = expand(x, base if sdir is None else sdir)
    return os.path.normpath(os.path.join(base, y)) if y else base


def fpath(base, x, sdir=None):
    """File x seen from dir base, or None when unknown. A name that resolves to base itself is a dir: None."""
    p = resolve(base, x, sdir)
    return None if p == base or x in STDIN_NAMES else p


def wpath(base, x):
    """fpath, or for a name that holds an unknown $VAR the word itself, so a file written as $S/x.sh and run as
    $S/x.sh still matches by text (writes and paths only)."""
    return fpath(base, x) or (x if "$" in x else None)


def prog_of(rec):
    return os.path.basename(rec["argv"][0]) if rec["argv"] else ""


def unwrap(words, d):
    """Drop assignments, keywords and wrappers in front of the real command. Returns (argv, dir)."""
    i = 0
    while i < len(words):
        w = words[i]
        name = os.path.basename(w)
        if ASSIGN.match(w) or w in KEYWORDS:
            i += 1
            continue
        if name not in WRAPPERS or (w != name and not w.startswith("/")):
            break
        start, i = i, i + 1
        while i < len(words) and words[i].startswith("-"):
            opt = words[i]
            i += 1
            if opt == "--":
                break
            if name == "command" and opt in ("-v", "-V"):
                return words[start:], d  # command -v only looks a name up; it runs nothing
            if opt in WRAPPERS[name] and i < len(words):
                if opt in ("-C", "--chdir"):
                    d = resolve(d, words[i])
                i += 1
            elif opt.startswith("--chdir="):
                d = resolve(d, opt[len("--chdir="):])
        if name == "timeout" and i < len(words):
            i += 1  # the duration
    return words[i:], d


def git_info(argv, d):
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in GIT_VALUE_OPTS:
            if i + 1 < len(argv) and a in ("-C", "--work-tree"):
                d = resolve(d, argv[i + 1])
            i += 2
        elif a.startswith("--work-tree="):
            d = resolve(d, a[len("--work-tree="):])
            i += 1
        elif a.startswith("-"):
            i += 1
        else:
            return {"sub": a, "args": argv[i + 1:]}, d
    return {"sub": None, "args": []}, d


def git_nested(argv, apre, sub):
    """The command strings git runs for this segment: `submodule [opts] foreach [opts] CMD...`, every
    `rebase --exec CMD` / `-x CMD`, and `bisect run CMD...`. argv[sub] is the subcommand; apre is argv before
    restore, so the strings keep their substitution placeholders. git runs one foreach word as a shell string, and
    several foreach words or the bisect run words as an argv, so those are re-quoted (sh -c 'a b' stays one word)."""
    name, out, j = argv[sub], [], sub + 1
    if name == "submodule":
        while j < len(argv) and argv[j].startswith("-"):
            j += 1
        if j < len(argv) and argv[j] == "foreach":
            j += 1
            while j < len(argv) and argv[j].startswith("-"):
                j += 1
            out = [apre[j] if len(apre) - j == 1 else " ".join(shlex.quote(w) for w in apre[j:])]
    elif name == "rebase":
        for k in range(j, len(argv)):
            a = argv[k]
            if a in ("-x", "--exec") and k + 1 < len(argv):
                out.append(apre[k + 1])
            elif a.startswith("--exec="):
                out.append(apre[k][len("--exec="):])
            elif a.startswith("-x") and len(a) > 2:
                out.append(apre[k][2:])
    elif name == "bisect" and argv[j:j + 1] == ["run"]:
        out = [" ".join(shlex.quote(w) for w in apre[j + 1:])]
    return [c for c in out if c.strip()]


def uv_info(argv, d):
    """For uv and uvx: apply --directory and --project, and return the program argv after `uv run [options]`,
    `uv tool run [options]` or `uvx [options]`. For uvx and uv tool run, a version or extras spec on the program
    word (pytest@8, pytest==8.3.0, pytest>=8, black[jupyter]) is dropped first, so it never reads as NAME=value."""
    i, subs = 1, (["tool", "run"] if os.path.basename(argv[0]) == "uvx" else [])
    while i < len(argv):
        a = argv[i]
        if a == "--":
            i += 1
            break
        if a.startswith("--directory=") or a.startswith("--project="):
            d = resolve(d, a.split("=", 1)[1])
        elif a in UV_VALUE_OPTS:
            if a in ("--directory", "--project") and i + 1 < len(argv):
                d = resolve(d, argv[i + 1])
            i += 1
        elif not a.startswith("-"):
            if subs in UV_RUN or len(subs) > 1 or subs and subs != ["tool"]:  # the program, or another subcommand
                break
            subs.append(a)
        i += 1
    if subs not in UV_RUN:
        return None, d
    if subs == ["tool", "run"] and i < len(argv):
        return [TOOL_SPEC.sub("", argv[i]) or argv[i]] + argv[i + 1:], d
    return argv[i:], d


def shell_script(argv):
    """For sh/bash/...: ("c", index of STRING) for -c, ("stdin", None) when it reads its script from stdin,
    ("file", index of the script operand) when it runs a script file, else (None, None)."""
    i, has_c, has_s = 1, False, False
    while i < len(argv) and argv[i][:1] in ("-", "+") and argv[i] not in ("-", "--"):
        o = argv[i]
        if o[:1] == "-" and o[:2] != "--":
            has_c, has_s = has_c or "c" in o, has_s or "s" in o
        i += 2 if o in SHELL_VALUE_OPTS else 1
    if i < len(argv) and argv[i] in ("-", "--"):
        i += 1
    if has_c:
        return ("c", i) if i < len(argv) else (None, None)
    if has_s or i >= len(argv) or argv[i] in STDIN_NAMES:
        return "stdin", None
    return "file", i


def written_body(records, f):
    """The heredoc or here-string text that the last of records writing file f with one wrote there: its own bodies,
    or for a writer fed by a pipe (cat <<EOF | tee F) the bodies of the records piped into it. None when none did."""
    for r in reversed(records):
        if f in r.get("_writes", ()):
            body = r.get("_btext") or "\n".join(u["_btext"] for u in r.get("_up", ()) if u.get("_btext"))
            if body:
                return body
    return None


def foreign_shebang(body):
    """The body starts with a #! line whose interpreter is not a shell (#!/usr/bin/env python3), so running the
    file by path does not run it as shell code."""
    m = SHEBANG.match(body)
    return bool(m) and os.path.basename(m.group(1)) not in SHELLS


def msg_files(argv, gdir, sdir, stdin):
    """Files named by -F (also in a group like -aF), --file or --body-file: (paths, reads stdin)."""
    out, rs = [], False
    for i, a in enumerate(argv):
        if a in ("--file", "--body-file"):
            v = argv[i + 1] if i + 1 < len(argv) else ""
        elif a.startswith("--file=") or a.startswith("--body-file="):
            v = a.split("=", 1)[1]
        elif re.match(r"-[A-Za-z]*?F", a):
            v = re.sub(r"^-[A-Za-z]*?F", "", a) or (argv[i + 1] if i + 1 < len(argv) else "")
        else:
            continue
        if v in STDIN_NAMES:
            rs = True
        elif v:
            f = fpath(gdir, v, sdir)
            if f:
                out.append(f)
    return out + (stdin if rs else []), rs


def py_dirs(argv, d):
    """Dirs a bare python or pip, or a .venv/bin python or pip, reaches by path (see the module doc). The
    program's own dir never counts: a uv repo's .venv/bin tool run from elsewhere works on that dir, not the repo."""
    a0, dirs = argv[0], []
    if a0.startswith(".venv/bin/") or "/.venv/bin/" in a0:
        a0 = os.path.basename(a0)
    if PYEXE.match(a0):
        i = 1
        while i < len(argv):
            a = argv[i]
            if a == "-" or a == "--":
                return []
            if not a.startswith("-"):
                f = fpath(d, a)
                return [os.path.dirname(f)] if f else []
            i += 1
            if a.startswith("--"):
                i += a == "--check-hash-based-pycs"
                continue
            for k, ch in enumerate(a[1:]):
                if ch in "cm":
                    return []  # -c CODE or -m MODULE: no script file
                if ch in "WX":
                    i += k == len(a) - 2  # the value is the next word unless it is attached
                    break
        return []
    if PIPEXE.match(a0):
        for a in argv[1:]:
            v = a.split("=", 1)[1] if a.startswith("--") and "=" in a else a
            if v.startswith("-") or "/" not in v:
                continue
            f = fpath(d, v)
            if f:
                dirs.append(os.path.dirname(f) if os.path.isfile(f) else f)
    return dirs


def bare_cat(rec):
    """A `cat` that reads the stdin of the command around it: no file operands (or only - or /dev/stdin), no <F,
    no heredoc or here-string, and nothing piped into it."""
    a = rec["argv"]
    return (bool(a) and os.path.basename(a[0]) == "cat" and not rec.get("stdin") and not rec["_btext"]
            and not rec["_up"] and all(x.startswith("-") or x in STDIN_NAMES for x in a[1:]))


def edits(argv, d):
    """Files a segment writes through its arguments: tee's operands, the operands of sed -i or perl -i (every
    non-option word, the script included: an extra path that names no real file never matches), and the target
    (last operand) of cp or mv."""
    prog = os.path.basename(argv[0]) if argv else ""
    ops = [x for x in argv[1:] if not x.startswith("-")]
    if prog in ("cp", "mv"):
        ops = ops[-1:] if len(ops) > 1 else []
    elif not (prog == "tee" or prog in ("sed", "gsed", "perl") and any(in_place(prog, x) for x in argv[1:])):
        return []
    return [f for f in (wpath(d, x) for x in ops) if f]


def in_place(prog, opt):
    """opt edits files in place: --in-place[=SUF], or a short option group holding i (sed -Ei, perl -pi) before an
    option that takes the rest of the group as its value."""
    if opt.startswith("--in-place"):
        return True
    if not opt.startswith("-") or opt.startswith("--"):
        return False
    for ch in opt[1:]:
        if ch == "i":
            return True
        if ch in ("efl" if prog != "perl" else "eEMmIxCdDl0"):
            return False
    return False


def reads(rec):
    """Files whose text a record prints: cat's file operands and stdin, or the file of a bare `<F`."""
    a = rec["argv"]
    if a and os.path.basename(a[0]) != "cat":
        return []
    files = [fpath(rec["dir"], x) for x in a[1:] if not x.startswith("-")]
    return [f for f in files if f] + rec.get("stdin", [])


def parse(command, cwd, depth=0):
    if depth > MAX_DEPTH:
        return [unparsed(command, cwd, depth)]
    scan = Scan(command)
    clean, _ = scan.run(0, None)
    lex = shlex.shlex(clean, posix=True, punctuation_chars=PUNCT)
    lex.whitespace, lex.whitespace_split, lex.commenters = " \t\r", True, ""
    records, stack, cur, d, piped, up = [], [], [], cwd, [], []
    for tok in lex:
        if tok and all(ch in PUNCT for ch in tok):
            for op in OPS.findall(tok):
                if op in REDIRS:
                    cur.append((op, True))
                    continue
                d, rec = segment(cur, d, scan, depth, records, piped, up)
                if rec is not None and op in ("|", "|&"):
                    rec["_pipe"] = True
                    piped, up = reads(rec), up + [rec]
                else:
                    piped, up = [], []
                cur = []
                if op == "(":
                    stack.append(d)
                elif op == ")" and stack:
                    d = stack.pop()
            continue
        cur.append((tok.translate(UNHIDE), False))
    segment(cur, d, scan, depth, records, piped, up)
    return records


def segment(cur, d, scan, depth, records, piped, up):
    """Append the records for one segment (nested ones first). Returns (dir for the next segment, its record).
    piped: files a `cat F |` feeds it; up: the records piped into it."""
    if not cur:
        return d, None
    if cur[0] == ("function", False):  # `function NAME {`: the body starts a segment after the brace
        return segment(cur[2:], d, scan, depth, records, piped, up)

    def restore(s):
        s = SUB.sub(lambda m: scan.kinds[int(m.group(1))] + scan.subs[int(m.group(1))] + ")", s)
        return HD.sub(lambda m: scan.hwords[int(m.group(1))], s)

    subfiles, subtext, subvis, catin, s0 = [], {}, {}, False, len(records)
    for tok, _ in cur:
        for m in SUB.finditer(tok):
            n = int(m.group(1))
            inner = nested(scan.subs[n], d, depth)
            records.extend(inner)
            subfiles.extend(f for r in inner if not r.get("_pipe") for f in reads(r))
            subtext[n] = " ".join(s for s in (said(r) for r in inner if r["_lvl"] == depth + 1) if s)
            subvis[n] = any(prog_of(r) in PRINTERS or r["_btext"] for r in inner)
            catin = catin or any(r["_lvl"] == depth + 1 and bare_cat(r) for r in inner)

    def own(s):  # a word as text: each substitution replaced by what its commands say
        return SUB.sub(lambda m: subtext[int(m.group(1))], s)

    def nonliteral(ws):  # (holds a $VAR, holds a substitution that prints text from the command)
        return (any("$" in w for w in ws),
                any(subvis[int(m.group(1))] for w in ws for m in SUB.finditer(w)))

    words, pre, raw, op, stdin, bodies, writes = [], [], [], None, list(piped), [], []
    for tok, redir in cur:
        full = restore(tok)
        raw.append(full if redir else shlex.quote(full))
        if redir:
            op = tok
            continue
        if op:  # the word after a redirection operator is its target, not an argument
            if op in ("<", "<>"):
                f = fpath(d, full)
                if f:
                    stdin.append(f)
            elif op in WRITE_OPS:
                f = wpath(d, full)
                if f:
                    writes.append(f)
            elif op == "<<":
                m = HD.search(tok)
                if m:
                    bodies.append(scan.bodies[int(m.group(1))])
            elif op == "<<<":
                bodies.append(own(tok))
            op = None
            continue
        words.append(full)
        pre.append(tok)
    argv, seg_dir = unwrap(words, d)
    apre = pre[len(pre) - len(argv):]  # argv before restore: substitutions still placeholders
    git, uv_run, nxt, opaque, extra, evaled, script = None, None, d, False, {}, [], None
    prog = os.path.basename(argv[0]) if argv else ""
    sets = {}  # variables this segment sets for later ones (NAME=... alone, or export NAME=...): name -> value
    if not argv or prog in DECLARE and argv[0] == prog:
        for w in argv[1:] if argv else words:
            m = ASSIGN.match(w)
            if m:
                sets[VARREF.match("$" + w).group(1)] = w[m.end():]
    n0 = len(records)  # the records code() adds below are the nested ones
    if prog == "git":
        git, seg_dir = git_info(argv, seg_dir)
        if git["sub"]:
            for c in git_nested(argv, apre, len(argv) - len(git["args"]) - 1):
                code(c, seg_dir, depth, records)
    elif prog in ("uv", "uvx"):
        uv_run, seg_dir = uv_info(argv, seg_dir)
        if uv_run:
            uv_run, seg_dir = unwrap(uv_run, seg_dir)
    elif prog in ("cd", "pushd") and argv[0] == prog:
        args = [a for a in argv[1:] if not (a.startswith("-") and a != "-")]
        if not args:
            nxt = os.environ.get("HOME", "") or d
        elif args[0] != "-":
            nxt = resolve(d, args[0])
    elif prog in SHELLS:
        kind, k = shell_script(argv)
        if kind == "c":  # opaque only for a bare $VAR or a substitution that prints text; else parsed
            code(apre[k], seg_dir, depth, records)
            opaque, evaled = bool(BAREVAR.fullmatch(apre[k])) or nonliteral([apre[k]])[1], [apre[k]]
        else:
            opaque = kind == "stdin"
            script = argv[k] if kind == "file" else None
    elif prog == "eval" and len(argv) > 1:
        code(" ".join(apre[1:]), seg_dir, depth, records)
        opaque, evaled = any(nonliteral(apre[1:])), apre[1:]
    elif prog in ("source", ".") and argv[0] == prog:
        opaque = len(argv) < 2 or argv[1] in STDIN_NAMES or nonliteral(apre[1:2])[1]
    by_path = script is None and bool(argv) and "/" in argv[0]
    f = wpath(seg_dir, argv[0] if by_path else script) if by_path or script else None
    body = written_body(records[:n0], f) if f else None
    if body and not (by_path and foreign_shebang(body)):  # a script an earlier segment wrote: run as bash -c is
        code(body, seg_dir, depth, records)
    envpre = " ".join(w for w in words[:len(words) - len(argv)] if ASSIGN.match(w))
    if envpre:  # NAME=value or env NAME=value in front of bash -c, eval or git: in the nested commands' env
        for r in records[n0:]:
            r["envpre"] = envpre + ("\n" + r["envpre"] if r.get("envpre") else "")
    btext = "\n".join(bodies)
    text = " ".join(own(w) for w in pre) + ("\n" + btext if bodies else "")
    if git and git["sub"] == "commit" or prog in ("gh", "glab"):
        extra["text"] = text
        for r in records[s0:n0]:  # its $(...) commands: their heredocs are message text
            r["_inmsg"] = True
        mf, rs = msg_files(argv, seg_dir, d, stdin)
        if catin and not rs:  # a bare `cat` in its $(...) reads the segment's stdin
            mf, rs = mf + stdin, True
        if mf:
            extra["msgfiles"] = mf
        if rs:
            last = max([i for i, r in enumerate(up) if prog_of(r) in FILTERS] or [0])
            extra["stdin_msg"], extra["feed"] = True, "\n".join(s for s in (said(r) for r in up[last:]) if s)
        extra["_reader"] = bool(mf or rs or stdin or subfiles) or any(
            VARWORD.search(w) for w in (git["args"] if git else argv[1:]))
    elif argv and (PYEXE.match(argv[0]) or PIPEXE.match(argv[0]) or "/.venv/bin/" in argv[0]
                   or argv[0].startswith(".venv/bin/")):
        pyd = py_dirs(argv, d)
        if pyd:
            extra["pydirs"] = pyd
    rec = {"dir": seg_dir, "argv": argv, "raw": " ".join(raw), "git": git, "uv_run": uv_run}
    if stdin:
        rec["stdin"] = stdin
    if subfiles:
        rec["subfiles"] = subfiles
    if sets:
        rec["assigns"] = True
    rec.update(extra)
    writes += edits(argv, seg_dir)
    if writes:
        rec["_writes"] = writes
    if opaque:
        rec["unparsed"] = True
        names = {m.group(1) for w in evaled for m in VARREF.finditer(w)}
        setters = ["\n".join([r["raw"]] + [v for k, v in r.get("_sets", {}).items() if k in names] + [r["_btext"]])
                   for r in records if names.intersection(r.get("_sets", ()))] if names else []
        rec["fb"] = "\n".join(setters + [rec["raw"], btext] + [r["raw"] + "\n" + r["_btext"] for r in up])
    rec.update(_text=text, _btext=btext, _lvl=depth, _sets=sets, _up=up)
    records.append(rec)
    return nxt, rec


def code(text, d, depth, records):
    """The string bash -c, eval or git (git_nested) runs, parsed as segments. Each substitution in it (already
    parsed on its own) counts as one plain word; a string that holds nothing else is skipped."""
    if SUB.sub("", text).strip():
        records.extend(nested(SUB.sub("_", text), d, depth))


def nested(text, d, depth):
    try:
        return parse(text, d, depth + 1)
    except ValueError:
        return [unparsed(text, d, depth + 1)]


def said(rec):
    """The text a record adds to a message: its _text, or for sed, grep, rg, awk and perl (whose words are
    patterns) only the heredoc and here-string bodies it reads."""
    return rec["_btext"] if prog_of(rec) in FILTERS else rec["_text"]


def writers(records):
    """A message can be written by an earlier segment of the same command (cat > m <<EOF, printf ... > m,
    MSG=..., sed ... <<EOF > m) and read later (-F m, $MSG). So a reader (see the module doc) gets "pretext": what
    every earlier segment says (said())."""
    # ponytail: each reader carries its own copy, so N readers after a big heredoc cost N copies; real commands
    # have one or two (300 readers or a 1 MB heredoc stay near 0.1 s per call).
    seen = []
    for rec in records:
        if rec.get("_reader") and seen:
            rec["pretext"] = "\n".join(seen)
        s = said(rec)
        if s:
            seen.append(s)
    return records


def unparsed(command, cwd, depth=0):
    return {"dir": cwd, "argv": [], "raw": command, "git": None, "unparsed": True, "fb": command,
            "_text": command, "_btext": "", "_lvl": depth}


def paths(rec):
    """word -> absolute file, for the program when it is run by path and for each non-option word."""
    a = rec["argv"]
    words = ([a[0]] if a and "/" in a[0] else []) + [x for x in a[1:] if not x.startswith("-")]
    out = {}
    for w in words:
        f = wpath(rec["dir"], w)
        if f:
            out[w] = f
    return out


def main():
    try:
        req = json.load(sys.stdin)
    except ValueError:
        req = {}
    if not isinstance(req, dict):
        req = {}
    command, cwd = req.get("command"), req.get("cwd")
    command = command if isinstance(command, str) else ""
    cwd = cwd if isinstance(cwd, str) else ""
    try:
        records = writers(parse(command, cwd))
    except ValueError:
        records = [unparsed(command, cwd)]
    full = req.get("bodies") is True
    index = {id(r): k for k, r in enumerate(records)}
    for rec in records:
        out = {k: v for k, v in rec.items() if not k.startswith("_")}
        if full:
            if rec.get("_btext"):
                out["bodies"] = rec["_btext"]
            for key, val in (("writes", rec.get("_writes")), ("paths", paths(rec)), ("inmsg", rec.get("_inmsg")),
                             ("up", [index[id(r)] for r in rec.get("_up", ()) if id(r) in index])):
                if val:
                    out[key] = val
        sys.stdout.write(json.dumps(out) + "\n")


if __name__ == "__main__":
    main()
