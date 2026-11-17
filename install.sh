#!/bin/bash
# workbench installer. Merges user/settings.fragment.json into settings.json in the Claude Code config folder
# (~/.claude, or $CLAUDE_CONFIG_DIR when it is set), writes workbench.json, the CLAUDE.md template and a
# user-level Explore agent there when they are missing, copies the plugin's runtime files to
# <config>/workbench-kit/ and installs the workbench plugin from that copy's local marketplace, so moving or
# deleting this checkout never turns the hooks off. Dry run by default. Bash 3.2 compatible; JSON work uses
# stdlib python3 -I.
set -u

usage() {
  cat <<'EOF'
Usage: install.sh [--apply] [--home DIR] [--no-plugin] [--author NAME] [--replace-old]

  (no flags)     dry run: print the plan and a JSON diff of settings.json; write nothing
  --apply        make the changes; settings.json, CLAUDE.md and agents/Explore.md are backed up first
  --home DIR     use DIR as the home directory instead of $HOME, and DIR/.claude as the config folder
                 (the tests use a sandbox); CLAUDE_CONFIG_DIR and WORKBENCH_CONFIG are then ignored, also
                 by the claude calls
  --no-plugin    skip the claude CLI steps (marketplace add, install, enable) and --replace-old;
                 the installed copy is still written
  --author NAME  your name for a new workbench.json and CLAUDE.md (default: git config --global user.name)
  --replace-old  retire an earlier hand-made setup once the plugin is confirmed: remove the user-level hook
                 entries for <config>/hooks/{guard,browser_cap,commit_gate,format_py}.sh and move
                 <config>/agents/reviewer.md and gate-runner.md into the backup (uninstall.sh restores them)

Config folder without --home: $CLAUDE_CONFIG_DIR if set, else ~/.claude (as Claude Code itself does).
workbench.json without --home: $WORKBENCH_CONFIG if set, else <config>/workbench.json (as the hooks read it).
After editing this folder, run install.sh --apply again: the plugin runs from the installed copy
<config>/workbench-kit. A new copy must pass its checks before it replaces the old one (the manifests and
hooks.json parse, the marketplace's plugin folder and the scripts hooks.json runs exist, hooks.json wires each
script to its event and tools, bash -n and a Python parse of the scripts, three guard.sh decisions with no
workbench.json and one decision each from guard.sh, commit_gate.sh and browser_cap.sh with a temp one, and claude
plugin validate, where a warning about hooks also fails, unless the CLI is missing or --no-plugin is given), and
the old one moves into the run's backup. If the new copy then fails to load, the old
one is put back. This folder must not be <config>/workbench-kit, sit inside it or contain it.

Exit codes: 0 done or nothing to do, 1 error or plugin step not finished, 2 bad usage or this folder at the
installed copy's path.
EOF
}

die() { echo "install.sh: $*" >&2; exit 1; }

APPLY=0
NO_PLUGIN=0
HOME_FLAG=0
REPLACE_OLD=0
AUTHOR_ARG=""
HOME_DIR="${HOME:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --no-plugin) NO_PLUGIN=1 ;;
    --replace-old) REPLACE_OLD=1 ;;
    --home)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      HOME_DIR="$2"; HOME_FLAG=1; shift ;;
    --home=*) HOME_DIR="${1#--home=}"; HOME_FLAG=1 ;;
    --author)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      AUTHOR_ARG="$2"; shift ;;
    --author=*) AUTHOR_ARG="${1#--author=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$HOME_DIR" ] || die "no home directory: set HOME or pass --home DIR"
case "$HOME_DIR" in /*) ;; *) HOME_DIR="$(pwd)/$HOME_DIR" ;; esac
HOME_DIR="${HOME_DIR%/}"
[ -d "$HOME_DIR" ] || die "home directory does not exist: $HOME_DIR"

# 0. Preflight: the hooks need jq, the commit gate needs git, the installer and link script need python3.
# Each must actually run: on a Mac without the Command Line Tools, git and python3 are stubs that only print an error.
missing=""
jq --version >/dev/null 2>&1 || missing="$missing
  jq       every hook reads its input with jq and steps aside without it.
           macOS 15 and later ship /usr/bin/jq; otherwise: brew install jq (Linux: apt install jq)"
git --version >/dev/null 2>&1 || missing="$missing
  git      macOS: xcode-select --install (Linux: apt install git)"
# -I as kitpy uses it; without it, Apple's python3 shim writes a bytecode cache under ~/Library/Caches.
python3 -I -c '' >/dev/null 2>&1 || missing="$missing
  python3  macOS: xcode-select --install, or python.org (Linux: apt install python3)"
if [ -n "$missing" ]; then
  echo "install.sh: these tools must run before anything is installed. Nothing was changed.$missing" >&2
  exit 1
fi

KIT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FRAGMENT="$KIT_DIR/user/settings.fragment.json"
TEMPLATE="$KIT_DIR/user/CLAUDE.md.template"
EXAMPLE="$KIT_DIR/kit.config.example.json"
AUDIT_TASK="$KIT_DIR/user/audit-task.md"
# Explore lives outside the plugin: a plugin copy would register a second, namespaced workbench:Explore.
EXPLORE_SRC="$KIT_DIR/user/agents/Explore.md"
for f in "$FRAGMENT" "$TEMPLATE" "$EXAMPLE" "$AUDIT_TASK" "$EXPLORE_SRC" "$KIT_DIR/.claude-plugin/marketplace.json" \
  "$KIT_DIR/LICENSE" "$KIT_DIR/README.md"; do
  [ -f "$f" ] || die "kit file missing: $f"
done
[ -d "$KIT_DIR/plugins/workbench" ] || die "kit folder missing: $KIT_DIR/plugins/workbench"

# The config folder, as Claude Code finds it: $CLAUDE_CONFIG_DIR when set, else ~/.claude. --home pins DIR/.claude.
abspath() { case "$1" in /*) printf '%s\n' "${1%/}" ;; *) printf '%s\n' "$(pwd)/${1%/}" ;; esac; }
if [ "$HOME_FLAG" = 0 ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CLAUDE_DIR="$(abspath "$CLAUDE_CONFIG_DIR")"
else
  CLAUDE_DIR="$HOME_DIR/.claude"
fi
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
# The hooks read $WORKBENCH_CONFIG when it is set, so the installer writes and protects that same file.
if [ "$HOME_FLAG" = 0 ] && [ -n "${WORKBENCH_CONFIG:-}" ]; then
  WB_JSON="$(abspath "$WORKBENCH_CONFIG")"
else
  WB_JSON="$CLAUDE_DIR/workbench.json"
fi
AGENTS_DIR="$CLAUDE_DIR/agents"
EXPLORE_DST="$AGENTS_DIR/Explore.md"
BACKUPS="$CLAUDE_DIR/backups"
ORIGINAL="$BACKUPS/workbench-original"
# Records of what install.sh wrote, so uninstall.sh removes a file only while it is unchanged, and re-runs add
# only the fragment entries that are new since the last run.
CREATED="$BACKUPS/workbench-created"
FRAG_RECORD="$CREATED/settings.fragment.applied.json"
SETTINGS_RECORD="$CREATED/settings.json.sha256"
RETIRED_RECORD="$CREATED/retired-agents"
# The plugin runs from this copy, not from the checkout, so moving or deleting the checkout changes nothing.
COPY="$CLAUDE_DIR/workbench-kit"
KNOWN="$CLAUDE_DIR/plugins/known_marketplaces.json"
PLUGIN_ID="workbench@workbench"
OLD_AGENT_NAMES="reviewer gate-runner"

# How a path reads in text Claude sees: ~/... under the home directory, else absolute.
disp() { case "$1" in "$HOME_DIR"/*) printf '~/%s\n' "${1#"$HOME_DIR"/}" ;; *) printf '%s\n' "$1" ;; esac; }
CFG_DISP="$(disp "$CLAUDE_DIR")"
WB_DISP="$(disp "$WB_JSON")"
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1; }

PLAN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/workbench-install.XXXXXX")" || die "cannot create a temp folder"
trap 'rm -rf "$PLAN_TMP"' EXIT

# Every claude call sees the same config folder as this script: with --home, CLAUDE_CONFIG_DIR is dropped.
cli() {
  if [ "$HOME_FLAG" = 1 ]; then
    env -u CLAUDE_CONFIG_DIR -u WORKBENCH_CONFIG HOME="$HOME_DIR" claude "$@" </dev/null
  else
    claude "$@" </dev/null
  fi
}

# All JSON reading and writing. Subcommands:
#   check FILE                      exit 1 with the parse error if FILE is not a JSON object
#   merge SETTINGS FRAGMENT HOME CFG WBJSON RECORD plan|apply
#                                   print a diff; exit 10 if the merge changes anything. With a RECORD (the
#                                   fragment as last applied) only entries new since then are added.
#   keptout SETTINGS FRAGMENT HOME CFG WBJSON RECORD   print recorded kit entries the user removed
#   record FRAGMENT HOME CFG WBJSON RECORD   write the rendered fragment to RECORD; exit 10 if it changed
#   hooks SETTINGS HOME CFG plan|apply  old hooks/ entries for the kit's scripts; exit 10 if any
#   plugin SETTINGS                 print enabled, disabled or absent for workbench@workbench in enabledPlugins
#   market KNOWN COPY               print here, absent or "elsewhere PATH" for the workbench marketplace
#   loaded TEXT COPY KIT            print ok, missing, disabled or "failed: ..." from claude plugin list output
#   author CONFIG                   print the "author" value (empty if missing or unreadable)
#   newconfig EXAMPLE OUT AUTHOR    write EXAMPLE to OUT with "author" set
#   hasagent DIR NAME               exit 0 if any *.md under DIR declares that agent name (or is NAME.md)
#   render TEMPLATE OUT AUTHOR CFG_DISP WB_DISP [RECORD]
#                                   fill {{AUTHOR}}, {{CONFIG_DIR}}, {{WORKBENCH_JSON}}; sha256 to RECORD
#   overlap KIT COPY                print is, inside or contains when KIT is COPY, sits in it or holds it
#   jsoncheck DIR KIT               print "fix KIT/<file>: <error>" for each manifest or hooks.json in the copy
#                                   DIR that is not a JSON object, and for each marketplace plugins[].source
#                                   that is not a folder inside DIR
#   smoke DIR KIT HOME              print "fix KIT/<file>: <error>" for each failed run check of the copy DIR
#                                   (see the comment above copy_checks); HOME is an empty temp folder it fills
#   valerr TEXT DIR KIT RC          the errors and hook warnings in claude plugin validate output (RC: its exit
#                                   code), as "fix <file>: <error>"
kitpy() {
  /usr/bin/env python3 -I - "$@" <<'PY'
import ast, copy, difflib, hashlib, json, os, re, shlex, subprocess, sys

PLUGIN_ID = "workbench@workbench"
OLD_HOOK_NAMES = ("guard", "browser_cap", "commit_gate", "format_py")
MISSING = object()


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


def load_obj(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except ValueError as e:  # json.JSONDecodeError and UnicodeDecodeError
        fail("ERROR: %s is not valid JSON: %s\n"
             "Nothing was changed. Fix that file first (claude doctor reports it too), then run install.sh again."
             % (path, e))
    except OSError as e:
        fail("ERROR: cannot read %s: %s" % (path, e))
    if not isinstance(data, dict):
        fail("ERROR: %s must hold a JSON object at the top level. Nothing was changed." % path)
    return data


def write_text(path, text):
    target = os.path.realpath(path)  # write through a symlinked dotfile instead of replacing the link
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = target + ".workbench-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    if os.path.exists(target):
        os.chmod(tmp, os.stat(target).st_mode & 0o7777)
    os.replace(tmp, target)


def dump(data):
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def dedupe_key(item, home):
    # "//Users/me/**/.env" and "~/**/.env" are the same rule, so the kit does not add a second copy.
    if isinstance(item, str):
        return ("s", item.replace("//" + home.lstrip("/") + "/", "~/"))
    return ("j", json.dumps(item, sort_keys=True))


def merge(user, frag, home):
    if isinstance(user, dict) and isinstance(frag, dict):
        out = dict(user)
        for key, value in frag.items():
            out[key] = merge(user[key], value, home) if key in user else copy.deepcopy(value)
        return out
    if isinstance(user, list) and isinstance(frag, list):
        out = list(user)
        seen = set(dedupe_key(x, home) for x in user)
        for item in frag:
            # ponytail: an existing autoMode list without "$defaults" was replaced on purpose; keep it that way.
            if item == "$defaults" and "$defaults" not in user:
                continue
            key = dedupe_key(item, home)
            if key not in seen:
                out.append(copy.deepcopy(item))
                seen.add(key)
        return out
    return user  # scalars and type mismatches: the user's value wins


def label(path, item=None):
    text = ".".join(path)
    return text if item is None else "%s: %s" % (text, item if isinstance(item, str) else json.dumps(item))


def new_part(frag, base, home, path, kept_out):
    """What a key the user does not have should get: only what is new since the record, else MISSING."""
    if isinstance(frag, dict) and isinstance(base, dict):
        out = {}
        for key, value in frag.items():
            sub = new_part(value, base[key], home, path + [key], kept_out) if key in base else copy.deepcopy(value)
            if sub is not MISSING:
                out[key] = sub
        return out if out else MISSING
    if isinstance(frag, list) and isinstance(base, list):
        old = set(dedupe_key(x, home) for x in base)
        fresh = []
        for item in frag:
            if item == "$defaults":
                continue
            if dedupe_key(item, home) in old:
                kept_out.append(label(path, item))
            else:
                fresh.append(copy.deepcopy(item))
        if not fresh:
            return MISSING
        # A list made from scratch keeps "$defaults" first, so it extends Claude Code's defaults.
        return (["$defaults"] if "$defaults" in frag else []) + fresh
    if frag == base:
        kept_out.append(label(path))
        return MISSING
    return copy.deepcopy(frag)


def merge3(user, frag, base, home, path, kept_out):
    """Three-way merge: add what the fragment has that the record (base) did not; what the user removed stays out."""
    if base is MISSING:
        return merge(user, frag, home)
    if isinstance(user, dict) and isinstance(frag, dict):
        out = dict(user)
        b = base if isinstance(base, dict) else {}
        for key, value in frag.items():
            if key in user:
                out[key] = merge3(user[key], value, b[key] if key in b else MISSING, home, path + [key], kept_out)
            elif key not in b:
                out[key] = copy.deepcopy(value)
            else:
                sub = new_part(value, b[key], home, path + [key], kept_out)
                if sub is not MISSING:
                    out[key] = sub
        return out
    if isinstance(user, list) and isinstance(frag, list):
        if not isinstance(base, list):
            return merge(user, frag, home)
        out = list(user)
        seen = set(dedupe_key(x, home) for x in user)
        old = set(dedupe_key(x, home) for x in base)
        for item in frag:
            if item == "$defaults" and "$defaults" not in user:
                continue
            key = dedupe_key(item, home)
            if key in seen:
                continue
            if key in old:
                kept_out.append(label(path, item))
                continue
            out.append(copy.deepcopy(item))
            seen.add(key)
        return out
    return user


def show_diff(path, before, after):
    lines = difflib.unified_diff(dump(before).splitlines(), dump(after).splitlines(),
                                 fromfile=path, tofile=path + " (after)", lineterm="", n=1)
    for line in lines:
        print(line)


def rule_path(home, path):
    """A path as a permission rule names it: ~/REL under home, else //ABS."""
    if path.startswith(home + "/"):
        return "~/" + path[len(home) + 1:]
    return "/" + path  # path is absolute, so this is the //path form


def render_fragment(frag, home, cfg, wbjson):
    # The fragment's ~/.claude/... and ~/.claude.json rules follow the config folder (CLAUDE_CONFIG_DIR), and
    # its workbench.json rule follows the file the hooks read (WORKBENCH_CONFIG).
    perms = frag.get("permissions")
    if not isinstance(perms, dict):
        return frag
    prefix = rule_path(home, cfg)
    wb_rule = "Edit(%s)" % rule_path(home, wbjson)
    out = copy.deepcopy(frag)
    for key, rules in perms.items():
        if not isinstance(rules, list):
            continue
        new = []
        for r in rules:
            if r == "Edit(~/.claude/workbench.json)":
                r = wb_rule
            elif isinstance(r, str) and prefix != "~/.claude":
                r = r.replace("(~/.claude/", "(" + prefix + "/").replace("(~/.claude.json)", "(" + prefix + "/.claude.json)")
            new.append(r)
        out["permissions"][key] = new
    return out


def load_record(path):
    if not os.path.exists(path):
        return MISSING
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        sys.stderr.write("warning: %s is unreadable; doing a full merge\n" % path)
        return MISSING
    return data if isinstance(data, dict) else MISSING


def old_hook_needles(home, cfg):
    bases = [p + ".claude/" for p in ("$HOME/", "${HOME}/", "~/", home + "/", os.path.realpath(home) + "/")]
    bases += [cfg + "/", os.path.realpath(cfg) + "/", "$CLAUDE_CONFIG_DIR/", "${CLAUDE_CONFIG_DIR}/"]
    for h in (home, os.path.realpath(home)):
        for c in (cfg, os.path.realpath(cfg)):
            if c.startswith(h + "/"):
                rel = c[len(h) + 1:]
                bases += [p + rel + "/" for p in ("$HOME/", "${HOME}/", "~/")]
    return sorted(set(p + "hooks/" + n + ".sh" for p in bases for n in OLD_HOOK_NAMES))


def is_old_hook(handler, needles):
    if not isinstance(handler, dict) or not isinstance(handler.get("command"), str):
        return False
    cmd = handler["command"].replace('"', "").replace("'", "")
    # The script name must end there: guard.sh.bak or guard.sh-old is not the kit's hook.
    return any(re.search(re.escape(n) + r"(?![\w.-])", cmd) for n in needles)


def strip_hooks(data, home, cfg):
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return data, []
    needles = old_hook_needles(home, cfg)
    removed, new_hooks = [], {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            new_hooks[event] = groups
            continue
        kept_groups = []
        for group in groups:
            handlers = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(handlers, list):
                kept_groups.append(group)
                continue
            kept = []
            for h in handlers:
                if is_old_hook(h, needles):
                    removed.append("%s [%s] %s" % (event, group.get("matcher", "*"), h["command"]))
                else:
                    kept.append(h)
            if kept:
                g = dict(group)
                g["hooks"] = kept
                kept_groups.append(g)
            elif not handlers:
                kept_groups.append(group)
        if kept_groups:
            new_hooks[event] = kept_groups
    out = dict(data)
    if new_hooks:
        out["hooks"] = new_hooks
    else:
        del out["hooks"]
    return out, removed


def has_agent(root, name):
    want = re.compile(r"^name:\s*[\"']?" + re.escape(name) + r"[\"']?\s*$")
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".md"):
                continue
            if fn == name + ".md":
                return True
            try:
                with open(os.path.join(dirpath, fn), encoding="utf-8", errors="replace") as f:
                    lines = f.read(8192).splitlines()
            except OSError:
                continue
            if not lines or lines[0].strip() != "---":
                continue
            for line in lines[1:]:
                if line.strip() == "---":
                    break
                if want.match(line.strip()):
                    return True
    return False


def market_state(known, where):
    entry = load_obj(known).get("workbench")
    loc = None
    if isinstance(entry, dict):
        loc = entry.get("installLocation") or (entry.get("source") or {}).get("path")
    if not isinstance(loc, str) or not loc:
        return "absent"
    return "here" if os.path.realpath(loc) == os.path.realpath(where) else "elsewhere " + loc


def load_state(text, copy_dir, kit):
    # `claude plugin list --json`: a list of {"id", "enabled", "errors": [...], "errorDetails": [{"path"}]}.
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, list):
        for p in data:
            if isinstance(p, dict) and p.get("id") == PLUGIN_ID:
                errors = p.get("errors") or []
                if errors:
                    files = []
                    for d in p.get("errorDetails") or []:
                        f = d.get("path") if isinstance(d, dict) else None
                        if isinstance(f, str) and f:
                            # A file in the installed copy is fixed in the checkout, then re-synced.
                            real, root = os.path.realpath(f), os.path.realpath(copy_dir)
                            if real.startswith(root + "/"):
                                f = kit + real[len(root):]
                            files.append(f)
                    msg = "failed: " + "; ".join(str(e) for e in errors)
                    return msg + "".join(" (fix %s)" % f for f in files)
                return "disabled" if p.get("enabled") is False else "ok"
        return "missing"
    # ponytail: a CLI without --json; read the plain listing up to the next entry marker.
    if PLUGIN_ID not in text:
        return "missing"
    block = text.split(PLUGIN_ID, 1)[1].split("\u276f", 1)[0]
    if "failed to load" in block:
        return "failed: " + "; ".join(l.strip() for l in block.splitlines() if "failed" in l or "Error" in l)
    return "ok"


def same_path(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return os.path.realpath(a) == os.path.realpath(b)


def parents(path):
    path, out = os.path.realpath(path), []
    while os.path.dirname(path) != path:
        path = os.path.dirname(path)
        out.append(path)
    return out


def overlap(kit, copy_dir):
    """How the checkout and the installed copy's path overlap: is, inside, contains, or nothing."""
    if same_path(kit, copy_dir):
        return "is"
    if any(same_path(p, copy_dir) for p in parents(kit)):
        return "inside"
    if any(same_path(p, kit) for p in parents(copy_dir)):
        return "contains"
    return ""


COPY_JSON = (".claude-plugin/marketplace.json", "plugins/workbench/.claude-plugin/plugin.json",
             "plugins/workbench/hooks/hooks.json")


def json_problems(copy_dir, kit):
    out = []
    for rel in COPY_JSON:
        try:
            with open(os.path.join(copy_dir, rel), encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as e:  # ValueError covers JSON and UTF-8 decoding errors
            out.append("fix %s/%s: %s" % (kit, rel, e))
            continue
        if not isinstance(data, dict):
            out.append("fix %s/%s: the top level is not a JSON object" % (kit, rel))
        elif rel == COPY_JSON[0]:
            # The CLI installs each plugin from its source folder in the copy, so that folder must be there.
            root = os.path.realpath(copy_dir)
            plugins = data.get("plugins")
            for i, p in enumerate(plugins if isinstance(plugins, list) else []):
                src = p.get("source") if isinstance(p, dict) else None
                where = os.path.realpath(os.path.join(copy_dir, src)) if isinstance(src, str) and src else ""
                if not where.startswith(root + "/") or not os.path.isdir(where):
                    out.append("fix %s/%s: plugins[%d].source %s is not a folder inside this kit"
                               % (kit, rel, i, json.dumps(src)))
    return out


# What the copy's guard.sh must answer with no workbench.json: its rules 1 to 3 are always on. {msg} is the absolute
# path of a message file holding the Claude trailer (SMOKE_TRAILER): only the parsed path (cmdparse.py) reads it, so
# guard.sh's whole-text fallback gives no decision there.
SMOKE_REQUESTS = (
    ("git stash", "git stash", "deny"),
    ("git push", "git push", "ask"),
    ("a commit whose message carries the Claude trailer",
     "git commit -m 'fix: x' -m 'Co-Authored-By: Claude <noreply@anthropic.com>'", "deny"),
    ("a commit whose -F message file carries the Claude trailer", "git commit -F {msg}", "deny"),
)
SMOKE_TRAILER = "fix: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n"
# What the hooks must answer with the smoke workbench.json (uv_repos holds the folder uv; commit_gates has one entry,
# for the repo folder repo whose origin is SMOKE_ORIGIN, with a check that always fails), as (script, what, command,
# folder, extra environment). Each must deny. All three read that file through kitconf.sh. One fake browser-like
# process (its argv carries --remote-debugging-pipe) runs meanwhile, so the cap at 0 sees a count of at least 1.
SMOKE_ORIGIN = "https://example.com/smoke/repo.git"
SMOKE_CONFIGURED = (
    ("guard.sh", "pip install x in a uv_repos folder", "pip install x", "uv", {}),
    ("commit_gate.sh", "a commit in a repo whose commit_gates check fails", "git commit -m x", "repo", {}),
    ("browser_cap.sh", "npx playwright test with CLAUDE_BROWSER_PROC_MAX=-1", "npx playwright test", "uv",
     {"CLAUDE_BROWSER_PROC_MAX": "-1"}),
    ("browser_cap.sh", "npx playwright test with CLAUDE_BROWSER_PROC_MAX=0 and one browser-like process running",
     "npx playwright test", "uv", {"CLAUDE_BROWSER_PROC_MAX": "0"}),
)
# The hook events Claude Code knows (2.1.311). claude plugin validate warns "unknown hook event; entry ignored at
# runtime" for any other key under "hooks", and nothing under it runs.
HOOK_EVENTS = frozenset((
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch", "Notification", "UserPromptSubmit",
    "UserPromptExpansion", "SessionStart", "SessionEnd", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
    "PreCompact", "PostCompact", "PreModelSwitch", "PostModelSwitch", "PermissionRequest", "PermissionDenied", "Setup",
    "TeammateIdle", "TaskCreated", "TaskCompleted", "Elicitation", "ElicitationResult", "ConfigChange",
    "WorktreeCreate", "WorktreeRemove", "InstructionsLoaded", "CwdChanged", "FileChanged", "DirectoryAdded",
    "MessageDisplay"))
# What hooks.json must wire, as (event, tool names, scripts): for each tool name, the event's groups whose matcher
# matches it run every one of those scripts between them.
HOOK_WIRING = (
    ("PreToolUse", ("Bash",), ("guard.sh", "commit_gate.sh", "browser_cap.sh")),
    ("PreToolUse", ("mcp__playwright__browser_navigate", "mcp__Claude_Browser__navigate",
                    "mcp__claude-in-chrome__navigate"), ("browser_cap.sh",)),
    ("PostToolUse", ("Edit", "Write"), ("format_py.sh",)),
)
PLUGIN_PATH = r"\$\{?CLAUDE_PLUGIN_ROOT\}?/([^\s\"';&|)]+)"
# The events whose matcher may also list tool names with commas and spaces ("Edit, Write"), as the CLI's own set
# says (2.1.311, the events its matcher function gets a true third argument for).
COMMA_EVENTS = frozenset((
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied",
    "UserPromptExpansion", "SessionStart", "SessionEnd", "Setup", "PreCompact", "PostCompact", "PreModelSwitch",
    "PostModelSwitch", "Notification", "SubagentStart", "SubagentStop", "Elicitation", "ElicitationResult",
    "ConfigChange", "InstructionsLoaded", "DirectoryAdded"))
# The PreToolUse scripts that decide: a hook that runs one of them must block, so none of these keys may be set
# (async and asyncRewake run it in the background, once removes it after its first run).
DECIDERS = ("guard.sh", "commit_gate.sh", "browser_cap.sh")
NON_BLOCKING = (("async", "runs it in the background and does not wait for its decision"),
                ("asyncRewake", "runs it in the background and does not wait for its decision"),
                ("once", "removes it after its first run"))
# commit_gate.sh's own time budget (WORKBENCH_GATE_TIMEOUT, default 170 s); the hook's timeout must be above it.
# With no timeout the CLI waits 600 s for a command hook (2.1.311).
GATE_BUDGET = 170


def matcher_matches(matcher, tool, event):
    """As Claude Code 2.1.311 reads a hook matcher: none, "" or "*" match every tool. For an event in COMMA_EVENTS,
    one made only of letters, digits, _, |, comma, space and - is a list of exact tool names split on | or comma,
    each name stripped; for any other event, one made only of letters, digits, _ and | is such a list split on |.
    Anything else is a regular expression that must match somewhere in the name."""
    if matcher is None or matcher in ("", "*"):
        return True
    if not isinstance(matcher, str):
        return False
    comma = event in COMMA_EVENTS
    if re.fullmatch(r"[A-Za-z0-9_|, -]+" if comma else r"[A-Za-z0-9_|]+", matcher):
        return tool in [name.strip() for name in re.split(r"[|,]" if comma else r"\|", matcher)]
    try:
        return re.search(matcher, tool) is not None
    except re.error:
        return False


def wiring_problems(hooks):
    """Where the parsed hooks.json differs from HOOK_EVENTS and HOOK_WIRING."""
    if not isinstance(hooks, dict):
        return []  # jsoncheck names this file
    events = hooks.get("hooks")
    if not isinstance(events, dict):
        return ['"hooks" is not an object of hook events, so no hook runs']
    out = ["%s is not a hook event Claude Code knows, so nothing under it runs" % json.dumps(name)
           for name in events if name not in HOOK_EVENTS]
    for event, tools, scripts in HOOK_WIRING:
        groups = events.get(event)
        groups = [g for g in groups if isinstance(g, dict)] if isinstance(groups, list) else []
        for tool in tools:
            ran = set()
            for g in groups:
                if not matcher_matches(g.get("matcher"), tool, event) or not isinstance(g.get("hooks"), list):
                    continue
                for h in g["hooks"]:
                    if isinstance(h, dict) and h.get("type") == "command" and isinstance(h.get("command"), str):
                        ran.update(re.findall(PLUGIN_PATH, h["command"]))
            out.extend("no %s group whose matcher matches %s runs ${CLAUDE_PLUGIN_ROOT}/scripts/%s" % (event, tool, s)
                       for s in scripts if "scripts/" + s not in ran)
    groups = events.get("PreToolUse")
    for g in groups if isinstance(groups, list) else []:
        for h in g.get("hooks") if isinstance(g, dict) and isinstance(g.get("hooks"), list) else []:
            if not isinstance(h, dict) or not isinstance(h.get("command"), str):
                continue
            ran = re.findall(PLUGIN_PATH, h["command"])
            for s in DECIDERS:
                if "scripts/" + s not in ran:
                    continue
                out.extend('the PreToolUse hook that runs ${CLAUDE_PLUGIN_ROOT}/scripts/%s sets "%s": %s, so Claude '
                           "Code %s" % (s, key, json.dumps(h[key]), why) for key, why in NON_BLOCKING if h.get(key))
                t = h.get("timeout")
                if s == "commit_gate.sh" and t is not None and not (
                        isinstance(t, (int, float)) and not isinstance(t, bool) and t > GATE_BUDGET):
                    out.append("the PreToolUse hook that runs ${CLAUDE_PLUGIN_ROOT}/scripts/commit_gate.sh has "
                               "timeout %s; it must be above %d, the gate's own time budget (WORKBENCH_GATE_TIMEOUT)"
                               % (json.dumps(t), GATE_BUDGET))
    return out


def hook_commands(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "command" and isinstance(value, str):
                yield value
            else:
                for c in hook_commands(value):
                    yield c
    elif isinstance(node, list):
        for value in node:
            for c in hook_commands(value):
                yield c


def smoke(copy_dir, kit, home):
    plugin = os.path.join(copy_dir, "plugins", "workbench")
    out = []

    def fix(rel, msg):
        line = "fix %s/plugins/workbench/%s: %s" % (kit, rel, msg)
        if line not in out:
            out.append(line)

    try:
        with open(os.path.join(plugin, "hooks", "hooks.json"), encoding="utf-8") as f:
            hooks = json.load(f)
    except (OSError, ValueError):
        hooks = None  # jsoncheck names this file
    for cmd in hook_commands(hooks):
        for rel in re.findall(PLUGIN_PATH, cmd):
            if not os.path.exists(os.path.join(plugin, rel)):
                fix("hooks/hooks.json", "it runs ${CLAUDE_PLUGIN_ROOT}/%s, which is not in the plugin" % rel)
    for p in wiring_problems(hooks):
        fix("hooks/hooks.json", p)
    scripts = os.path.join(plugin, "scripts")
    for name in sorted(os.listdir(scripts)) if os.path.isdir(scripts) else []:
        path = os.path.join(scripts, name)
        if name.endswith(".sh"):
            r = subprocess.run(["bash", "-n", path], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if r.returncode != 0:
                err = r.stderr.decode("utf-8", "replace").strip().splitlines() or ["exit %d" % r.returncode]
                fix("scripts/" + name, "bash -n: " + err[0].replace(path + ": ", ""))
        elif name.endswith(".py"):
            try:
                with open(path, "rb") as f:
                    ast.parse(f.read(), name)  # parse only: nothing is compiled or written
            except SyntaxError as e:
                fix("scripts/" + name, "it does not parse as Python: %s (line %s)" % (e.msg, e.lineno))
            except ValueError as e:  # a null byte
                fix("scripts/" + name, "it does not parse as Python: %s" % e)
    missing = [s for s in ("guard.sh", "commit_gate.sh", "browser_cap.sh", "kitconf.sh", "cmdparse.py")
               if not os.path.isfile(os.path.join(scripts, s))]
    for s in missing:
        fix("scripts/" + s, "missing")
    search = os.environ.get("PATH", "/usr/bin:/bin")
    # Two homes in HOME's folder: "empty" has no workbench.json; "conf" has the smoke one, its uv folder and repo.
    home = os.path.realpath(home)
    empty, conf = os.path.join(home, "empty"), os.path.join(home, "conf")
    uv, repo = os.path.join(conf, "uv"), os.path.join(conf, "repo")
    for d in (empty, os.path.join(conf, ".claude"), uv, repo):
        os.makedirs(d)
    with open(os.path.join(conf, ".claude", "workbench.json"), "w", encoding="utf-8") as f:
        json.dump({"uv_repos": [uv], "commit_gates": [
            {"remote": "smoke/repo", "checks": [{"name": "smoke", "files": ".", "cmd": "false"}]}]}, f)
    with open(os.path.join(repo, "a.txt"), "w", encoding="utf-8") as f:
        f.write("x\n")  # untracked, so the gate has a changed file to check
    msg = os.path.join(home, "msg.txt")
    with open(msg, "w", encoding="utf-8") as f:
        f.write(SMOKE_TRAILER)
    empty_env = {"HOME": empty, "PATH": search}
    conf_env = {"HOME": conf, "PATH": search, "TMPDIR": home}
    git_ok = all(subprocess.run(c, cwd=repo, env=conf_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=20).returncode == 0
                 for c in (["git", "init", "-q"], ["git", "remote", "add", "origin", SMOKE_ORIGIN]))

    def last_line(err):
        lines = [l.strip() for l in err.splitlines() if l.strip()]
        return lines[-1] if lines else ""

    def decision(want, where, what):
        def miss(text, err, rc):
            try:
                got = json.loads(text)["hookSpecificOutput"]["permissionDecision"]
            except (ValueError, KeyError, TypeError):
                got = None
            if got == want:
                return None
            said = ("answers %s" % got) if isinstance(got, str) else "gives no decision"
            if rc:
                said += " (exit %d%s)" % (rc, ": " + last_line(err) if last_line(err) else "")
            return "%s it %s for %s, not %s" % (where, said, what, want)
        return miss

    def request(command, cwd):
        return json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                           "tool_input": {"command": command}, "cwd": cwd})

    def named(rel, miss):
        return lambda text, err, rc: (lambda m: m and (rel, m))(miss(text, err, rc))

    bad_parser = ["cmdparse.py" in missing]  # set once cmdparse.py is named: missing, or it does not run

    def guarded(miss, where, what):
        """guard.sh answers these plain requests from cmdparse.py's segments. A "whole-text check" line on its stderr
        means it fell back to regexes over the text (cmdparse.py did not run, or its own segment check failed),
        which give the same answer to most of them: that is a miss too, named after the file at fault."""
        def check(text, err, rc):
            m = miss(text, err, rc)
            fb = [l.strip() for l in err.splitlines() if "whole-text check" in l]
            if not fb:
                return m and ("scripts/guard.sh", m)
            rel = "scripts/cmdparse.py" if "cmdparse" in fb[0] else "scripts/guard.sh"
            if rel == "scripts/cmdparse.py" and bad_parser[0]:
                return None  # cmdparse.py is named already
            return rel, "%s guard.sh falls back to its whole-text check for %s (it says: %s)%s" % (
                where, what, fb[0], "; " + m[len(where) + 1:] if m else "")
        return check

    def parsed(text, err, rc):
        try:
            recs = [json.loads(l) for l in text.splitlines() if l.strip()]
        except ValueError:
            recs = []
        if rc == 0 and recs and all(isinstance(r, dict) for r in recs):
            return None
        bad_parser[0] = True
        return "scripts/cmdparse.py", "it does not run as the hooks run it (/usr/bin/env python3 -I): %s" % (
            last_line(err) or ("exit %d" % rc if rc else "it prints no JSON records"))

    def hook_runs(script):
        """(label, argv, wired) for each command string hooks.json runs scripts/<script> with, run as Claude Code
        runs it (bash -c, CLAUDE_PLUGIN_ROOT set); plus the plain bash one as a reference when hooks.json uses
        another or none, so a miss names hooks.json only when the script itself passes."""
        plain = 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/%s"' % script
        cmds = [c for c in dict.fromkeys(hook_commands(hooks)) if "scripts/" + script in re.findall(PLUGIN_PATH, c)]
        runs = [(c, ["bash", "-c", c], True) for c in cmds]
        return runs + ([] if plain in cmds else [(plain, ["bash", "-c", plain], False)]), plain

    # (script, runs, plain label, stdin, cwd, env, check): check(stdout, stderr, exit code) gives (file, what went
    # wrong) or None. cmdparse.py comes first: the guard runs read whether it was named.
    checks = []
    if "cmdparse.py" not in missing:
        argv = ["/usr/bin/env", "python3", "-I", os.path.join(scripts, "cmdparse.py")]
        checks.append(("cmdparse.py", [("cmdparse.py", argv, False)], "cmdparse.py",
                       json.dumps({"command": "git commit -F " + shlex.quote(msg), "cwd": empty}), empty, empty_env,
                       parsed))

    def hook_check(script, data, cwd, env, check):
        runs, plain = hook_runs(script)
        checks.append((script, runs, plain, data, cwd, dict(env, CLAUDE_PLUGIN_ROOT=plugin), check))

    if "guard.sh" not in missing:
        for what, command, want in SMOKE_REQUESTS:
            where = "with an empty config folder"
            hook_check("guard.sh", request(command.format(msg=shlex.quote(msg)), empty), empty, empty_env,
                       guarded(decision(want, where, what), where, what))
    for script, what, command, where, extra in SMOKE_CONFIGURED:
        if script not in missing and (script != "commit_gate.sh" or git_ok):
            cwd, said = os.path.join(conf, where), "with a workbench.json"
            miss = decision("deny", said, what)
            hook_check(script, request(command, cwd), cwd, dict(conf_env, **extra),
                       guarded(miss, said, what) if script == "guard.sh" else named("scripts/" + script, miss))
    if os.path.isfile(os.path.join(scripts, "format_py.sh")):
        # The formatter decides nothing; its wired command must start and exit 0 (an edit of a .txt file it skips).
        what = "an Edit of a .txt file"
        hook_check("format_py.sh", json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Edit",
                                               "tool_input": {"file_path": os.path.join(empty, "a.txt")},
                                               "cwd": empty}), empty, empty_env,
                   lambda text, err, rc: None if rc == 0 else (
                       "scripts/format_py.sh", "with an empty config folder it exits %d for %s, not 0%s"
                       % (rc, what, " (" + last_line(err) + ")" if last_line(err) else "")))
    if "kitconf.sh" not in missing:
        # Sourced, as the hooks do, then asked for one path list and one value from the smoke workbench.json.
        call = 'kit_paths ".uv_repos[]?"; kit_get ".commit_gates[0].remote"'
        want = "%s\nsmoke/repo\n" % uv
        argv = ["bash", "-c", '. "$0"; ' + call, os.path.join(scripts, "kitconf.sh")]
        checks.append(("kitconf.sh", [("kitconf.sh", argv, False)], "kitconf.sh", "", conf, conf_env,
                       lambda text, err, rc: None if text == want else (
                           "scripts/kitconf.sh", "with a workbench.json, %s prints %s, not %s"
                           % (call, json.dumps(text), json.dumps(want)))))
    # One browser-like process for the cap to count while the runs go: its argv carries --remote-debugging-pipe, as
    # a Playwright Chrome's does. read is a bash builtin, so no child outlives the kill by PID below.
    fake = None
    if "browser_cap.sh" not in missing:
        try:
            fake = subprocess.Popen(["bash", "-c", "read -t 20 x", "workbench-smoke", "--remote-debugging-pipe"],
                                    stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    env={"PATH": search})
        except OSError:
            fake = None  # the run with the cap at 0 then names browser_cap.sh
    # Every run starts at once and is read afterwards, so the check takes about as long as its slowest run.
    # Each request goes in from a file, so no run waits for its stdin to be written.
    results, started = {}, []
    try:
        for i, (script, runs, plain, data, cwd, env, check) in enumerate(checks):
            req = os.path.join(home, "request.%d.json" % i)
            with open(req, "w", encoding="utf-8") as f:
                f.write(data)
            for label, argv, wired in runs:
                try:
                    with open(req, "rb") as f:
                        p = subprocess.Popen(argv, stdin=f, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                                             cwd=cwd)
                except OSError as e:
                    results[i, label] = "it does not run: %s" % e
                    continue
                started.append((p, i, label))
        for p, i, label in started:
            try:
                text, err = (s.decode("utf-8", "replace") for s in p.communicate(timeout=20))
                results[i, label] = (text, err, p.returncode)
            except subprocess.TimeoutExpired:
                p.kill()
                p.communicate()
                results[i, label] = "it gives no answer within 20 s"
    finally:
        if fake is not None:
            fake.kill()
            fake.communicate()
    for i, (script, runs, plain, data, cwd, env, check) in enumerate(checks):
        def judge(label):
            r = results.get((i, label))
            return ("scripts/" + script, r) if isinstance(r, str) else check(*r) if r else None
        base = judge(plain)
        if base:
            fix(*base)  # the script itself, run plainly
            continue
        for label, argv, wired in runs:
            m = judge(label) if wired and label != plain else None
            if m:
                fix("hooks/hooks.json",
                    "its command %s (run with bash -c, as Claude Code runs it): %s" % (label, m[1]))
    return out


def validate_errors(text, copy_dir, kit, failed):
    """claude plugin validate prints "Validating <what>: <file>", then "Found N error(s):" or "Found N warning(s):",
    a blank line and one line per error or warning up to the next blank line. Every error counts, and so does a
    warning about hooks (it exits 0 then, but says the entry is ignored at runtime). FAILED: it exited non-zero."""
    out, current, state, kind = [], "", 0, ""  # state 1: after a "Found" line, 2: in its list
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("Plugin directory checks"):
            break  # advice about the plugin directory listing; it does not change the verdict
        m = re.match(r"Validating [^:]*: (.+)$", s)
        found = re.search(r"Found \d+ (error|warning)s?:", s)
        if m:
            current, state = m.group(1), 0
        elif found:
            state, kind = 1, found.group(1)
        elif not s:
            state = 0 if state == 2 else state
        elif state:
            state = 2
            item = re.sub(r"^\W+", "", s)
            if kind == "error":
                out.append("fix %s: %s" % (current or copy_dir, item))
            elif item.startswith("hooks") or current.endswith("hooks.json"):
                out.append("fix %s: claude plugin validate warns: %s" % (current or copy_dir, item))
    if not out and failed:
        out = ["claude plugin validate: " + l.strip() for l in text.splitlines() if l.strip()][-5:]
    # The copy mirrors this checkout, so name the checkout's file: that is the one to fix.
    roots = sorted(set([copy_dir.rstrip("/"), os.path.realpath(copy_dir)]), key=len, reverse=True)
    for root in roots:
        out = [l.replace(root + "/", kit + "/") for l in out]
    return out


def main(argv):
    cmd = argv[0]
    if cmd == "check":
        load_obj(argv[1])
        return 0
    if cmd == "overlap":
        print(overlap(argv[1], argv[2]))
        return 0
    if cmd == "jsoncheck":
        problems = json_problems(argv[1], argv[2])
        for p in problems:
            print(p)
        return 1 if problems else 0
    if cmd == "smoke":
        problems = smoke(argv[1], argv[2], argv[3])
        for p in problems:
            print(p)
        return 1 if problems else 0
    if cmd == "valerr":
        for p in validate_errors(argv[1], argv[2], argv[3], argv[4] != "0"):
            print(p)
        return 0
    if cmd in ("merge", "keptout"):
        settings, fragment, home, cfg, wbjson, record = argv[1:7]
        user = load_obj(settings)
        if not os.path.exists(fragment):
            fail("ERROR: fragment missing: %s" % fragment)
        kept_out = []
        frag = render_fragment(load_obj(fragment), home, cfg, wbjson)
        # No settings.json at all is a fresh start: the whole fragment goes in, whatever the record says.
        base = load_record(record) if os.path.exists(settings) else MISSING
        merged = merge3(user, frag, base, home, [], kept_out)
        if cmd == "keptout":
            for k in kept_out:
                print("    " + k)
            return 0
        if merged == user:
            return 0
        show_diff(settings, user, merged)
        if argv[7] == "apply":
            write_text(settings, dump(merged))
        return 10
    if cmd == "record":
        fragment, home, cfg, wbjson, record = argv[1:6]
        text = dump(render_fragment(load_obj(fragment), home, cfg, wbjson))
        if os.path.exists(record):
            with open(record, encoding="utf-8") as f:
                if f.read() == text:
                    return 0
        write_text(record, text)
        return 10
    if cmd == "hooks":
        settings, home, cfg, mode = argv[1:5]
        data = load_obj(settings)
        out, removed = strip_hooks(data, home, cfg)
        for r in removed:
            print("    " + r)
        if not removed:
            return 0
        if mode == "apply":
            write_text(settings, dump(out))
        return 10
    if cmd == "plugin":
        enabled = load_obj(argv[1]).get("enabledPlugins")
        if not isinstance(enabled, dict) or PLUGIN_ID not in enabled:
            print("absent")
        else:
            print("enabled" if enabled[PLUGIN_ID] is True else "disabled")
        return 0
    if cmd == "market":
        print(market_state(argv[1], argv[2]))
        return 0
    if cmd == "loaded":
        print(load_state(argv[1], argv[2], argv[3]))
        return 0
    if cmd == "author":
        try:
            with open(argv[1], encoding="utf-8") as f:
                author = json.load(f).get("author", "")
        except (OSError, ValueError, AttributeError):
            sys.stderr.write("warning: cannot read author from %s\n" % argv[1])
            return 0
        print(author.strip() if isinstance(author, str) else "")
        return 0
    if cmd == "newconfig":
        example, out, author = argv[1:4]
        with open(example, encoding="utf-8") as f:
            text = f.read()
        data = json.loads(text)
        data["author"] = author
        # Keep the example's compact layout: swap only the author value, and check the result parses back.
        new = text.replace('"author": ""', '"author": ' + json.dumps(author, ensure_ascii=False), 1)
        try:
            ok = json.loads(new) == data
        except ValueError:
            ok = False
        write_text(out, new if ok else dump(data))
        return 0
    if cmd == "hasagent":
        return 0 if has_agent(argv[1], argv[2]) else 1
    if cmd == "render":
        template, out, author, cfg_disp, wb_disp = argv[1:6]
        with open(template, encoding="utf-8") as f:
            text = f.read()
        for key, value in (("{{AUTHOR}}", author), ("{{CONFIG_DIR}}", cfg_disp), ("{{WORKBENCH_JSON}}", wb_disp)):
            text = text.replace(key, value)
        write_text(out, text)
        if len(argv) > 6:
            # uninstall.sh removes CLAUDE.md only while it still has this hash, so later edits are never lost.
            with open(out, "rb") as f:
                write_text(argv[6], hashlib.sha256(f.read()).hexdigest() + "\n")
        return 0
    fail("kitpy: unknown subcommand %s" % cmd)


sys.exit(main(sys.argv[1:]))
PY
}

# 0b. This folder must not be the installed copy, sit inside it or hold it: a re-sync replaces that folder.
case "$(kitpy overlap "$KIT_DIR" "$COPY")" in
  is) where="is $COPY, the installed copy's path" ;;
  inside) where="is inside $COPY, the installed copy's path" ;;
  contains) where="contains $COPY, the installed copy's path" ;;
  *) where="" ;;
esac
if [ -n "$where" ]; then
  echo "install.sh: this checkout ($KIT_DIR) $where. --apply builds that folder from" >&2
  echo "this one and swaps it in, so it refuses. Move the checkout elsewhere (for example ~/code/workbench) and run" >&2
  echo "install.sh from there. Nothing was changed." >&2
  exit 2
fi

# 1. Never touch a settings file Claude Code itself cannot read.
if [ -e "$SETTINGS" ]; then
  kitpy check "$SETTINGS" || exit 1
fi
kitpy check "$FRAGMENT" || exit 1
if [ -e "$WB_JSON" ]; then
  kitpy check "$WB_JSON" || exit 1
fi

# 2. Work out the plan.
SETTINGS_DIFF="$(kitpy merge "$SETTINGS" "$FRAGMENT" "$HOME_DIR" "$CLAUDE_DIR" "$WB_JSON" "$FRAG_RECORD" plan)"
rc=$?
case $rc in
  0) SETTINGS_CHANGE=0 ;;
  10) SETTINGS_CHANGE=1 ;;
  *) exit 1 ;;
esac
KEPT_OUT="$(kitpy keptout "$SETTINGS" "$FRAGMENT" "$HOME_DIR" "$CLAUDE_DIR" "$WB_JSON" "$FRAG_RECORD")" || exit 1

WB_JSON_NEW=0; [ -e "$WB_JSON" ] || WB_JSON_NEW=1

# Author: an existing workbench.json wins (the guard messages read it), then --author, then git config.
AUTHOR=""; AUTHOR_FROM=""; WB_AUTHOR=""
[ "$WB_JSON_NEW" = 0 ] && WB_AUTHOR="$(kitpy author "$WB_JSON")"
if [ -n "$WB_AUTHOR" ]; then
  AUTHOR="$WB_AUTHOR"; AUTHOR_FROM="$WB_JSON"
elif [ -n "$AUTHOR_ARG" ]; then
  AUTHOR="$AUTHOR_ARG"; AUTHOR_FROM="--author"
else
  AUTHOR="$(HOME="$HOME_DIR" git config --global user.name 2>/dev/null)"
  AUTHOR_FROM="git config --global user.name"
fi
AUTHOR_SHOWN="$AUTHOR"; [ -n "$AUTHOR" ] || AUTHOR_SHOWN="<author: pass --author>"

# CLAUDE.md: create it when missing; an earlier run's render that is unchanged since (its sha256 matches the
# record) is brought up to date with the template; anything else is the user's and stays.
CLAUDE_MD_ACTION=keep
if [ ! -e "$CLAUDE_MD" ]; then
  CLAUDE_MD_ACTION=create
elif [ -f "$CREATED/CLAUDE.md.sha256" ] && [ "$(sha256 "$CLAUDE_MD")" = "$(cat "$CREATED/CLAUDE.md.sha256")" ]; then
  CLAUDE_MD_ACTION=kit
  if [ -n "$AUTHOR" ]; then
    kitpy render "$TEMPLATE" "$PLAN_TMP/CLAUDE.md" "$AUTHOR" "$CFG_DISP" "$WB_DISP" || exit 1
    cmp -s "$PLAN_TMP/CLAUDE.md" "$CLAUDE_MD" || CLAUDE_MD_ACTION=update
  fi
fi
if [ -z "$AUTHOR" ] && { [ "$WB_JSON_NEW" = 1 ] || [ "$CLAUDE_MD_ACTION" = create ]; } && [ "$APPLY" = 1 ]; then
  echo "install.sh: no author name. workbench.json and CLAUDE.md name the person who authors commits and" >&2
  echo "approves pushes. Pass --author \"Your Name\", or set git config --global user.name, then run again." >&2
  echo "Nothing was changed." >&2
  exit 1
fi

# Explore: only a user- or project-level agent named Explore replaces the built-in one (a plugin agent is
# namespaced). Copy the kit's user/agents/Explore.md to agents/ in the config folder unless the user has one.
EXPLORE_ACTION=none
if [ -e "$EXPLORE_DST" ]; then
  # Installed by an earlier run and untouched since: bring it up to date with the kit.
  if [ -f "$CREATED/agents/Explore.md" ] && cmp -s "$EXPLORE_DST" "$CREATED/agents/Explore.md" \
    && ! cmp -s "$EXPLORE_DST" "$EXPLORE_SRC"; then
    EXPLORE_ACTION=update
  fi
elif ! kitpy hasagent "$AGENTS_DIR" Explore; then
  EXPLORE_ACTION=create
fi

# The installed copy: the runtime part of this folder (the plugin's tests/ included, so the monthly audit can run
# the hook self-test), plus the audit prompt rendered for this config folder.
build_copy() {
  dest="$1"
  mkdir -p "$dest/plugins" || return 1
  cp -R "$KIT_DIR/.claude-plugin" "$dest/" || return 1
  cp -R "$KIT_DIR/plugins/workbench" "$dest/plugins/" || return 1
  cp "$KIT_DIR/LICENSE" "$KIT_DIR/README.md" "$dest/" || return 1
  # Only in this freshly built folder: bytecode and Finder files never reach the copy.
  find "$dest" \( -name __pycache__ -o -name '*.pyc' -o -name .DS_Store \) -prune -exec rm -rf {} + || return 1
  # A checkout from a web upload or a zip has no exec bits; the copy's scripts get them back.
  find "$dest/plugins/workbench" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod a+x {} + || return 1
  kitpy render "$AUDIT_TASK" "$dest/audit-task.md" "$AUTHOR_SHOWN" "$CFG_DISP" "$WB_DISP"
}
build_copy "$PLAN_TMP/copy" || die "cannot build the installed copy in $PLAN_TMP"
COPY_ACTION=none; COPY_WHY="they differ"
if [ ! -d "$COPY" ]; then
  COPY_ACTION=create
elif ! diff -rq "$PLAN_TMP/copy" "$COPY" >/dev/null 2>&1; then
  COPY_ACTION=resync
# Same files, but a script lost an exec bit (diff -rq does not compare modes). The mode bits are read, not
# [ -x ], which is false on a noexec mount whatever the bits say.
elif [ -n "$(find "$COPY/plugins/workbench" -type f \( -name '*.sh' -o -name '*.py' \) ! -perm -0111 -print 2>/dev/null | head -n 1)" ]; then
  COPY_ACTION=resync; COPY_WHY="a script lost its exec bit"
fi
COPY_SYNC=0; [ "$COPY_ACTION" != none ] && COPY_SYNC=1
# A new copy must pass these checks before it replaces anything, so a bad pull or a typo in this folder does not
# reach the running plugin. copy_checks runs them on a built copy and prints each miss as "fix <file in this
# folder>: <what>":
#   jsoncheck: .claude-plugin/marketplace.json, plugins/workbench/.claude-plugin/plugin.json and
#     plugins/workbench/hooks/hooks.json parse as JSON objects, and each marketplace plugins[].source is a folder
#     inside the copy;
#   smoke: every ${CLAUDE_PLUGIN_ROOT}/... path that hooks/hooks.json names exists; hooks/hooks.json is wired:
#     every key under "hooks" is a hook event Claude Code knows, the PreToolUse groups whose matcher matches Bash
#     run scripts/guard.sh, scripts/commit_gate.sh and scripts/browser_cap.sh, the PreToolUse groups matching
#     mcp__playwright__browser_navigate, mcp__Claude_Browser__navigate and mcp__claude-in-chrome__navigate run
#     scripts/browser_cap.sh, and the PostToolUse groups matching Edit and Write run scripts/format_py.sh, with
#     matchers read as the CLI (2.1.311) reads them (for PreToolUse and PostToolUse a matcher of letters, digits,
#     _, |, comma, space and - is a list of names split on | or comma, so "Edit, Write" lists two tools; any other
#     character makes it a regex); none of the PreToolUse hooks that run those three scripts sets async,
#     asyncRewake or once, and commit_gate.sh's hook has no timeout (the CLI then waits 600 s) or one above 170,
#     the gate's own budget; guard.sh, commit_gate.sh, browser_cap.sh, kitconf.sh and cmdparse.py are there;
#     bash -n passes on every scripts/*.sh; every scripts/*.py (cmdparse.py) parses as Python (ast.parse, nothing
#     compiled or written) and cmdparse.py runs on a request as the hooks run it (/usr/bin/env python3 -I);
#     then each command string hooks.json wires a script with runs as Claude Code runs it (bash -c, with
#     CLAUDE_PLUGIN_ROOT set to the copy's plugin folder; the plain bash command also runs when hooks.json uses
#     another, so a miss names hooks.json only when the script itself passes): the copy's scripts/guard.sh, run
#     with HOME set to an empty temp folder (no workbench.json), answers deny for git stash, ask for git push,
#     and deny for a commit whose message carries the Claude trailer, in -m text and in a -F message file (only
#     the parsed path reads that file), and any "whole-text check" line on its stderr is a miss (it fell back
#     to regexes: cmdparse.py did not run, or its own segment check failed); with HOME set to a temp folder
#     whose workbench.json lists a temp uv_repos folder and a commit_gates entry (origin
#     example.com/smoke/repo, a check that always fails) for a temp repo, guard.sh denies pip install x in that
#     folder, commit_gate.sh denies a commit in that repo, browser_cap.sh denies npx playwright test with
#     CLAUDE_BROWSER_PROC_MAX=-1 and with CLAUDE_BROWSER_PROC_MAX=0 while one fake browser-like process (a bash
#     whose argv carries --remote-debugging-pipe, killed by PID afterwards) runs, so its pgrep count is used,
#     format_py.sh exits 0 for an Edit of a .txt file, and kitconf.sh reads the folder and the remote back.
#     These runs start together, so the whole check takes about as long as the slowest one.
# The plan runs both on its copy, so the dry run reports a miss too; --apply then adds claude plugin validate on
# the marketplace and the plugin when it may use the CLI (an error, or a warning about hooks, is a miss), and runs
# both again on the folder it swaps in when that folder differs from the plan's copy (this folder changed during
# the run). They catch a broken, missing or unwired file and a hook that no longer gives these decisions, not
# every changed rule: plugins/workbench/tests/test_hooks.sh does that. If the swapped-in copy then fails to load,
# confirm_enabled puts the previous copy back.
copy_checks() {
  c1="$(kitpy jsoncheck "$1" "$KIT_DIR")"; r1=$?
  sh_home="$(mktemp -d "$PLAN_TMP/home.XXXXXX")" || { echo "cannot create a temp folder in $PLAN_TMP"; return 1; }
  c2="$(kitpy smoke "$1" "$KIT_DIR" "$sh_home")"; r2=$?
  rm -rf "$sh_home"
  # A check that stops without naming a miss (a Python error, printed above) is a miss too, never a pass.
  [ -n "$c1" ] && printf '%s\n' "$c1"
  [ "$r1" != 0 ] && [ -z "$c1" ] && echo "the jsoncheck of the copy stopped with exit $r1 (its error is printed above)"
  [ -n "$c2" ] && printf '%s\n' "$c2"
  [ "$r2" != 0 ] && [ -z "$c2" ] && echo "the smoke check of the copy stopped with exit $r2 (its error is printed above)"
  [ "$r1" = 0 ] && [ "$r2" = 0 ]
}
COPY_BAD=""
[ "$COPY_SYNC" = 1 ] && COPY_BAD="$(copy_checks "$PLAN_TMP/copy")"

# What claude plugin list says about the plugin: ok, missing, disabled, "failed: ...", or unknown.
load_state() {
  lout="$(cli plugin list --json 2>/dev/null)" || lout="$(cli plugin list 2>&1)" || { echo unknown; return; }
  kitpy loaded "$lout" "$COPY" "$KIT_DIR"
}

# The plugin counts as confirmed only when every check passes: settings.json enables it,
# plugins/known_marketplaces.json reads the workbench marketplace from the installed copy, and claude plugin
# list does not show it failing to load. Without the CLI the last check cannot run, so nothing old is retired.
CLI=0; command -v claude >/dev/null 2>&1 && CLI=1
PLUGIN_STATE=skip; MARKET=""; MARKET_AT=""; LOAD=""
DO_MARKET=0; DO_INSTALL=0; DO_ENABLE=0
if [ "$NO_PLUGIN" = 0 ]; then
  PLUGIN_STATE="$(kitpy plugin "$SETTINGS")" || exit 1
  m="$(kitpy market "$KNOWN" "$COPY")" || exit 1
  MARKET="${m%% *}"
  [ "$MARKET" = elsewhere ] && MARKET_AT="${m#elsewhere }"
  if [ "$PLUGIN_STATE" = enabled ] && [ "$MARKET" = here ]; then
    if [ "$CLI" = 1 ]; then LOAD="$(load_state)"; else LOAD=unchecked; fi
  fi
  [ "$MARKET" = here ] || DO_MARKET=1        # a round-3 install or a moved kit: re-add from the copy
  { [ "$PLUGIN_STATE" = absent ] || [ "$LOAD" = missing ]; } && DO_INSTALL=1
  # After a marketplace add the plugin may still be missing (settings.json from another machine enables it, so
  # the plan cannot tell); claude plugin install answers "already installed" with exit 0, so one run is enough.
  [ "$DO_MARKET" = 1 ] && DO_INSTALL=1
  [ "$PLUGIN_STATE" = disabled ] && DO_ENABLE=1
  # ponytail: a plugin that is installed and enabled but fails to load is not fixed by add or install again;
  # the file to fix is printed instead, and the next run re-syncs the copy from this folder.
fi
PLUGIN_READY=0
case "$LOAD" in ok|unchecked) PLUGIN_READY=1 ;; esac
CLI_STEPS=$((DO_MARKET + DO_INSTALL + DO_ENABLE))
# The CLI steps rewrite settings.json, so they count as a file change; a missing CLI or a plugin that fails
# to load changes nothing.
PLUGIN_CLI_CHANGES=0
[ "$CLI" = 1 ] && [ "$CLI_STEPS" -gt 0 ] && PLUGIN_CLI_CHANGES=1

# An earlier hand-made setup: user-level hook entries for <config>/hooks/<kit script>.sh, and user agents with
# the plugin's agent names. They stay unless --replace-old says to retire them.
OLD_HOOKS=""; OLD_AGENTS=""
if [ "$PLUGIN_STATE" != skip ]; then
  OLD_HOOKS="$(kitpy hooks "$SETTINGS" "$HOME_DIR" "$CLAUDE_DIR" plan)"
  rc=$?
  [ $rc = 0 ] || [ $rc = 10 ] || exit 1
  for a in $OLD_AGENT_NAMES; do
    [ -f "$AGENTS_DIR/$a.md" ] && OLD_AGENTS="$OLD_AGENTS $a.md"
  done
fi
OLD_ANY=0; { [ -n "$OLD_HOOKS" ] || [ -n "$OLD_AGENTS" ]; } && OLD_ANY=1
RETIRE=0; [ "$REPLACE_OLD" = 1 ] && [ "$OLD_ANY" = 1 ] && RETIRE=1
RETIRE_NOW=0
[ "$RETIRE" = 1 ] && [ "$PLUGIN_READY" = 1 ] && [ "$LOAD" = ok ] && RETIRE_NOW=1

NEED_BACKUP=0
if [ "$SETTINGS_CHANGE" = 1 ] || [ "$CLAUDE_MD_ACTION" = create ] || [ "$CLAUDE_MD_ACTION" = update ] \
  || [ "$EXPLORE_ACTION" != none ] || [ "$COPY_SYNC" = 1 ] || [ "$PLUGIN_CLI_CHANGES" = 1 ] || [ "$RETIRE_NOW" = 1 ]; then
  NEED_BACKUP=1
fi
CHANGES=0
{ [ "$NEED_BACKUP" = 1 ] || [ "$WB_JSON_NEW" = 1 ]; } && CHANGES=1
# Something the plugin step still owes: set it up, see it load, or retire what --replace-old names.
PENDING=0
if [ "$PLUGIN_STATE" != skip ]; then
  { [ "$PLUGIN_READY" = 0 ] || [ "$RETIRE" = 1 ]; } && PENDING=1
fi

if [ "$APPLY" = 1 ]; then
  echo "workbench install (applying)"
else
  echo "workbench install (dry run: nothing is written; re-run with --apply)"
fi
echo "  kit:    $KIT_DIR"
echo "  home:   $HOME_DIR"
echo "  config: $CLAUDE_DIR"
echo "  author: \"$AUTHOR_SHOWN\"${AUTHOR:+ (from $AUTHOR_FROM)}"
if [ -n "$WB_AUTHOR" ] && [ -n "$AUTHOR_ARG" ] && [ "$AUTHOR_ARG" != "$WB_AUTHOR" ]; then
  echo "  note: --author ignored; $WB_JSON already names \"$WB_AUTHOR\" (edit it there to change)"
fi
if [ "$SETTINGS_CHANGE" = 1 ]; then
  echo "  settings.json: merge the kit fragment (JSON diff below; your existing values win)"
else
  echo "  settings.json: already has every kit entry, no change"
fi
if [ -n "$KEPT_OUT" ]; then
  echo "  settings.json: removed by you, not re-added (kit entries an earlier run added that you took out):"
  echo "$KEPT_OUT"
fi
if [ "$CHANGES" = 1 ]; then
  if [ -d "$ORIGINAL" ]; then
    [ "$NEED_BACKUP" = 1 ] && echo "  backup: settings.json, CLAUDE.md and agents/Explore.md to $BACKUPS/workbench-<timestamp>/"
  else
    echo "  backup: settings.json, CLAUDE.md and agents/Explore.md to $ORIGINAL/ (written once; uninstall.sh restores it)"
  fi
fi
if [ "$WB_JSON_NEW" = 1 ]; then
  echo "  workbench.json: create $WB_JSON from kit.config.example.json with author \"$AUTHOR_SHOWN\"; then add your repos and gates"
else
  echo "  workbench.json: $WB_JSON exists, left as is"
  [ -z "$WB_AUTHOR" ] && echo "  note: $WB_JSON has no \"author\"; set it so the guard messages name you"
fi
case "$CLAUDE_MD_ACTION" in
  create) echo "  CLAUDE.md: create from user/CLAUDE.md.template with author \"$AUTHOR_SHOWN\"" ;;
  update) echo "  CLAUDE.md: update to the kit's current template (written by an earlier run, unchanged since)" ;;
  kit) echo "  CLAUDE.md: the kit's version, no change" ;;
  keep) echo "  CLAUDE.md: exists, left as is. Compare with the kit's version: diff \"$TEMPLATE\" \"$CLAUDE_MD\"" ;;
esac
case "$EXPLORE_ACTION" in
  create) echo "  agents/Explore.md: copy the kit's Explore agent (only a user-level Explore replaces the built-in one)" ;;
  update) echo "  agents/Explore.md: update to the kit's current version (installed by an earlier run, unchanged since)" ;;
  none)
    if [ -e "$EXPLORE_DST" ] && cmp -s "$EXPLORE_DST" "$EXPLORE_SRC"; then
      echo "  agents/Explore.md: the kit's version, no change"
    else
      echo "  agents/Explore.md: a user-level Explore agent exists, left as is"
    fi ;;
esac
case "$COPY_ACTION" in
  create) echo "  installed copy: create $COPY (.claude-plugin/, plugins/workbench/ with its tests/, LICENSE, README.md, audit-task.md); the plugin runs from it" ;;
  resync) echo "  installed copy: re-sync $COPY with this folder ($COPY_WHY); the current copy moves into this run's backup" ;;
  none) echo "  installed copy: $COPY matches this folder, no change" ;;
esac
if [ -n "$COPY_BAD" ]; then
  echo "  installed copy: this folder does not validate, so --apply stops before any change:"
  printf '%s\n' "$COPY_BAD" | sed 's/^/    /'
elif [ "$COPY_SYNC" = 1 ] && [ "$CLI" = 1 ] && [ "$NO_PLUGIN" = 0 ]; then
  echo "  installed copy: --apply runs claude plugin validate on the new copy first"
fi
if [ "$PLUGIN_STATE" = skip ]; then
  echo "  plugin: skipped (--no-plugin)"
  [ "$REPLACE_OLD" = 1 ] && echo "  note: --replace-old needs the plugin step, so it is ignored with --no-plugin"
else
  [ "$MARKET" = elsewhere ] && echo "  plugin: marketplace workbench points at $MARKET_AT, not the installed copy"
  [ "$PLUGIN_STATE" = disabled ] && echo "  plugin: $PLUGIN_ID is installed but disabled"
  case "$LOAD" in
    ok) echo "  plugin: $PLUGIN_ID enabled, read from the installed copy, and claude plugin list shows it loaded" ;;
    unchecked) echo "  plugin: $PLUGIN_ID enabled and read from the installed copy (claude CLI not on PATH, so load state unchecked)" ;;
    failed*) echo "  plugin: claude plugin list reports $PLUGIN_ID ${LOAD#failed: }"
      [ "$COPY_SYNC" = 1 ] && echo "  plugin: the re-sync of the installed copy may fix it; the load is checked again after it" ;;
    missing) echo "  plugin: claude plugin list does not show $PLUGIN_ID installed" ;;
    unknown) echo "  plugin: claude plugin list did not run, so the plugin cannot be confirmed" ;;
  esac
  steps=""
  [ "$DO_MARKET" = 1 ] && steps="claude plugin marketplace add \"$COPY\""
  [ "$DO_INSTALL" = 1 ] && steps="${steps:+$steps, then }claude plugin install $PLUGIN_ID"
  [ "$DO_ENABLE" = 1 ] && steps="${steps:+$steps, then }claude plugin enable $PLUGIN_ID --scope user"
  [ -n "$steps" ] && echo "  plugin: $steps"
  [ "$CLI" = 0 ] && [ -n "$steps" ] && echo "  plugin: the claude CLI is not on PATH, so this step waits (the /plugin steps are printed below)"
fi
if [ "$OLD_ANY" = 1 ]; then
  if [ "$REPLACE_OLD" = 1 ]; then
    echo "  old user-level hooks and agents to retire once the plugin is confirmed (--replace-old):"
  else
    echo "  old user-level hooks and agents (will run alongside the plugin; pass --replace-old to retire them):"
  fi
  [ -n "$OLD_HOOKS" ] && echo "$OLD_HOOKS"
  for a in $OLD_AGENTS; do
    if [ "$REPLACE_OLD" = 1 ]; then echo "    $AGENTS_DIR/$a (moved into the backup; uninstall.sh restores it)"
    else echo "    $AGENTS_DIR/$a"; fi
  done
fi
if [ "$SETTINGS_CHANGE" = 1 ]; then
  echo "--- JSON diff of settings.json ---"
  echo "$SETTINGS_DIFF"
  echo "---"
fi

print_audit_hint() {
  echo "Monthly audit: add a scheduled task (monthly, for example the 1st at 09:00) and paste the text of"
  echo "  $COPY/audit-task.md"
  echo "  as its prompt (the file is the prompt body only, rendered for this config folder). Desktop app:"
  echo "  Scheduled tasks, New task."
}

print_in_app() {
  echo "  Finish in a Claude Code session instead:"
  echo "    /plugin marketplace add $COPY"
  echo "    /plugin install $PLUGIN_ID      (or /plugin enable $PLUGIN_ID if it is installed but disabled)"
  [ "$RETIRE" = 1 ] && echo "  then run bash install.sh --apply --replace-old again with the claude CLI on PATH, so it can confirm the plugin loads and retire the old hooks and agents."
}

print_retire_wait() {
  echo "The old hook entries and agents were left in place: without the claude CLI on PATH, install.sh cannot"
  echo "  confirm that the plugin loads. In a Claude Code session, /plugin must show $PLUGIN_ID with no errors; then"
  echo "  delete the old entries in /hooks and move the agents aside by hand, or run"
  echo "  bash install.sh --apply --replace-old again where the claude CLI is on PATH."
}

write_fragment_record() {
  kitpy record "$FRAGMENT" "$HOME_DIR" "$CLAUDE_DIR" "$WB_JSON" "$FRAG_RECORD" >/dev/null
  rc=$?
  [ $rc = 0 ] || [ $rc = 10 ] || echo "  (could not record the applied fragment in $FRAG_RECORD; the next run does a full merge)" >&2
}

if [ "$APPLY" != 1 ]; then
  print_audit_hint
  [ -n "$COPY_BAD" ] && exit 1
  exit 0
fi

# claude plugin validate on the marketplace (both manifests) and on the plugin (its manifest and hooks.json). An
# error is a miss, and so is a warning about hooks, though validate exits 0 for it ("unknown hook event; entry
# ignored at runtime"): that entry would never run. Output that is not a validation report (an old CLI without the
# command, a CLI that cannot start) is noted, and the JSON check stands.
cli_validate() {
  for d in "$1" "$1/plugins/workbench"; do
    vout="$(cli plugin validate "$d" 2>&1)"; vrc=$?
    case "$vout" in
      *"Validating "*)
        vbad="$(kitpy valerr "$vout" "$1" "$KIT_DIR" "$vrc")"
        [ -n "$vbad" ] && { printf '%s\n' "$vbad"; return 0; } ;;
      *) [ "$vrc" = 0 ] || echo "  (claude plugin validate did not run on $d; the JSON check passed)" >&2 ;;
    esac
  done
}
if [ "$COPY_SYNC" = 1 ]; then
  [ -z "$COPY_BAD" ] && [ "$CLI" = 1 ] && [ "$NO_PLUGIN" = 0 ] && COPY_BAD="$(cli_validate "$PLAN_TMP/copy")"
  if [ -n "$COPY_BAD" ]; then
    kept=""; [ -d "$COPY" ] && kept="; the installed copy $COPY stays as it is"
    echo "install.sh: the kit in $KIT_DIR does not validate, so nothing was changed$kept:" >&2
    printf '%s\n' "$COPY_BAD" | sed 's/^/  /' >&2
    echo "Fix that in this folder, then run bash install.sh --apply again." >&2
    exit 1
  fi
fi

if [ "$CHANGES" = 0 ] && [ "$PENDING" = 0 ]; then
  write_fragment_record
  echo "Nothing to change."
  print_audit_hint
  exit 0
fi
[ "$CHANGES" = 0 ] && echo "No file changes."

SETTINGS_BEFORE=""; [ -f "$SETTINGS" ] && SETTINGS_BEFORE="$(sha256 "$SETTINGS")"

# 3. Apply, backup first. The first run keeps the pre-kit state in workbench-original/ until uninstall.sh
# restores it; later runs get timestamped backups, so a second --apply never hides what uninstall.sh should
# go back to. No backup is written when no file changes. Each backup also keeps install.sh's records as they
# were, so uninstall.sh --latest puts the records back together with the files.
write_backup() {
  dir="$1"
  mkdir -p "$dir/agents" || die "cannot create $dir"
  for name in settings.json CLAUDE.md agents/Explore.md; do
    if [ -e "$CLAUDE_DIR/$name" ]; then
      cp -p "$CLAUDE_DIR/$name" "$dir/$name" || die "backup of $name failed; nothing else was changed"
    else
      : > "$dir/$name.absent"   # uninstall.sh moves a file that did not exist before aside
    fi
  done
  if [ -d "$CREATED" ]; then
    cp -Rp "$CREATED" "$dir/workbench-created" || die "backup of $CREATED failed; nothing else was changed"
  else
    : > "$dir/workbench-created.absent"
  fi
  # A re-sync moves the old installed copy in here (below); a run that creates the copy marks it absent.
  [ "$COPY_ACTION" = create ] && : > "$dir/workbench-kit.absent"
  return 0
}
RUN_BACKUP=""
make_backup() {
  mkdir -p "$CLAUDE_DIR" || die "cannot create $CLAUDE_DIR"
  if [ ! -d "$ORIGINAL" ]; then
    tmpdir="$BACKUPS/.workbench-original.tmp-$$"
    rm -rf "$tmpdir"
    write_backup "$tmpdir"
    mv "$tmpdir" "$ORIGINAL" || die "cannot create $ORIGINAL"
    RUN_BACKUP="$ORIGINAL"
    echo "Backed up the pre-workbench state to $ORIGINAL"
  else
    base="$BACKUPS/workbench-$(date +%Y%m%d-%H%M%S)"
    RUN_BACKUP="$base"
    n=2
    while [ -e "$RUN_BACKUP" ]; do RUN_BACKUP="$base-$n"; n=$((n + 1)); done
    write_backup "$RUN_BACKUP"
    echo "Backed up to $RUN_BACKUP"
  fi
}
if [ "$CHANGES" = 1 ]; then
  if [ ! -d "$ORIGINAL" ] || [ "$NEED_BACKUP" = 1 ]; then
    make_backup
  fi
fi

if [ "$WB_JSON_NEW" = 1 ]; then
  kitpy newconfig "$EXAMPLE" "$WB_JSON" "$AUTHOR" || die "cannot create $WB_JSON"
  echo "Created $WB_JSON for $AUTHOR (add your repos and gates; README, Configure)"
fi

if [ "$SETTINGS_CHANGE" = 1 ]; then
  kitpy merge "$SETTINGS" "$FRAGMENT" "$HOME_DIR" "$CLAUDE_DIR" "$WB_JSON" "$FRAG_RECORD" apply >/dev/null
  rc=$?
  [ $rc = 10 ] || [ $rc = 0 ] || die "merging into $SETTINGS failed"
  echo "Merged the kit fragment into $SETTINGS"
fi
write_fragment_record

if [ "$CLAUDE_MD_ACTION" = create ] || [ "$CLAUDE_MD_ACTION" = update ]; then
  kitpy render "$TEMPLATE" "$CLAUDE_MD" "$AUTHOR" "$CFG_DISP" "$WB_DISP" "$CREATED/CLAUDE.md.sha256" \
    || die "cannot write $CLAUDE_MD"
  if [ "$CLAUDE_MD_ACTION" = create ]; then echo "Created $CLAUDE_MD for $AUTHOR"; else echo "Updated $CLAUDE_MD to the kit's template"; fi
fi

if [ "$EXPLORE_ACTION" != none ]; then
  mkdir -p "$AGENTS_DIR" "$CREATED/agents" || die "cannot create $AGENTS_DIR"
  cp "$EXPLORE_SRC" "$EXPLORE_DST" || die "cannot write $EXPLORE_DST"
  cp "$EXPLORE_SRC" "$CREATED/agents/Explore.md" || die "cannot record $EXPLORE_DST in $CREATED"
  echo "Installed $EXPLORE_DST (user-level, so it replaces the built-in Explore)"
fi

# Build the copy in a temp sibling, check it against the plan's copy, then swap it in, so the plugin never reads a
# half-written folder. The copy it replaces moves into this run's backup (uninstall.sh --latest puts it back, and
# confirm_enabled does when the new copy fails to load); this step deletes only the temp folder it built itself.
prev=""
if [ "$COPY_SYNC" = 1 ]; then
  tmp="$CLAUDE_DIR/.workbench-kit.tmp-$$"
  rm -rf "$tmp"
  build_copy "$tmp" || { rm -rf "$tmp"; die "cannot build the installed copy in $tmp"; }
  # The same files as the plan's checked copy need no second run; a folder that changed since is checked again.
  if ! diff -rq "$PLAN_TMP/copy" "$tmp" >/dev/null 2>&1; then
    bad="$(copy_checks "$tmp")" || {
      rm -rf "$tmp"; printf '%s\n' "$bad" >&2
      die "this folder changed during the run and no longer validates; $COPY was left as it is"
    }
  fi
  if [ -e "$COPY" ] || [ -L "$COPY" ]; then
    [ -n "$RUN_BACKUP" ] || make_backup
    prev="$RUN_BACKUP/workbench-kit"
    [ -e "$prev" ] && prev="$prev.$$"
    mv "$COPY" "$prev" || { rm -rf "$tmp"; die "cannot move the old $COPY into $RUN_BACKUP"; }
  fi
  mv "$tmp" "$COPY" || { [ -n "$prev" ] && mv "$prev" "$COPY"; die "cannot put the new copy in place at $COPY"; }
  if [ -z "$prev" ]; then echo "Created the installed copy $COPY"
  else echo "Re-synced $COPY with $KIT_DIR (the previous copy is in $prev)"; fi
fi

PLUGIN_FAILED=0
retire_old() {
  if [ -n "$OLD_HOOKS" ]; then
    out="$(kitpy hooks "$SETTINGS" "$HOME_DIR" "$CLAUDE_DIR" apply)"
    rc=$?
    if [ $rc = 10 ]; then
      echo "Removed old user-level hook entries (--replace-old):"
      echo "$out"
    elif [ $rc != 0 ]; then
      echo "Could not remove the old hook entries from $SETTINGS; remove them by hand to avoid double-firing." >&2
    fi
  fi
  [ -n "$OLD_AGENTS" ] || return 0
  [ -n "$RUN_BACKUP" ] || make_backup
  mkdir -p "$RUN_BACKUP/agents" "$CREATED" || die "cannot write to $RUN_BACKUP"
  for a in $OLD_AGENTS; do
    dest="$RUN_BACKUP/agents/$a"
    [ -e "$dest" ] && dest="$dest.retired-$(date +%Y%m%d-%H%M%S)"
    mv "$AGENTS_DIR/$a" "$dest" || { echo "Could not move $AGENTS_DIR/$a into $RUN_BACKUP; it stays." >&2; continue; }
    printf 'agents/%s\t%s\n' "$a" "${dest#"$BACKUPS"/}" >> "$RETIRED_RECORD"
    echo "Moved $AGENTS_DIR/$a to $dest (--replace-old; uninstall.sh restores it)"
  done
}
# Swap the copy this run built for the one it replaced ($prev, in this run's backup); the new one goes into the
# backup as workbench-kit.failed-to-load. Leaves the new copy in place if a move fails.
failed_copy=""
put_back_previous() {
  failed_copy="$RUN_BACKUP/workbench-kit.failed-to-load"
  [ -e "$failed_copy" ] && failed_copy="$failed_copy.$$"
  mv "$COPY" "$failed_copy" || return 1
  mv "$prev" "$COPY" && return 0
  mv "$failed_copy" "$COPY"
  return 1
}
# Re-run every check after the CLI calls: "claude plugin install" exits 0 for "already installed" and leaves
# a disabled plugin disabled, and a plugin can be enabled yet fail to load.
confirm_enabled() {
  if [ "$(kitpy plugin "$SETTINGS")" = disabled ]; then
    cli plugin enable "$PLUGIN_ID" --scope user || echo "  (claude plugin enable reported an error; checking again)"
  fi
  why=""
  st="$(kitpy plugin "$SETTINGS")"
  m="$(kitpy market "$KNOWN" "$COPY")"
  if [ "$st" != enabled ]; then
    why="$PLUGIN_ID is not enabled in $SETTINGS"
  elif [ "$m" = absent ]; then
    why="no workbench marketplace in $KNOWN"
  elif [ "$m" != here ]; then
    why="marketplace workbench points at ${m#elsewhere }, not $COPY"
  else
    l="$(load_state)"
    [ "$l" = ok ] || why="claude plugin list: $l"
  fi
  if [ -z "$why" ]; then
    echo "Plugin $PLUGIN_ID is enabled and loads from $COPY"
    [ "$RETIRE" = 1 ] && retire_old
    return 0
  fi
  # This run's re-sync swapped in a copy that fails to load, and the plan did not see the copy it replaced fail:
  # move the new one into the backup and put that one back, so new sessions keep the hooks that loaded.
  if [ "${l#failed}" != "$l" ] && [ "${LOAD#failed}" = "$LOAD" ] && [ -n "$prev" ] && [ -d "$prev" ] \
    && put_back_previous; then
    l2="$(load_state)"
    echo "The new copy fails to load (${l#failed: }); the previous copy was put back."
    echo "  The new copy is in $failed_copy; the old user-level hooks and agents were left in place."
    if [ "$l2" = ok ]; then
      echo "  Plugin $PLUGIN_ID loads from $COPY again (the previous copy)."
    else
      echo "  The previous copy does not load either: claude plugin list: $l2"
    fi
    echo "  Fix that in $KIT_DIR, then run bash $KIT_DIR/install.sh --apply again."
    PLUGIN_FAILED=1
    return 0
  fi
  echo "Plugin not confirmed ($why); the old user-level hooks and agents were left in place."
  case "$l" in failed*) echo "  Fix that in $KIT_DIR, then run bash $KIT_DIR/install.sh --apply again (it re-syncs the installed copy)." ;; esac
  case "$why" in "claude plugin list: failed"*) ;; *) print_in_app ;; esac
  PLUGIN_FAILED=1
}
l=""
if [ "$PLUGIN_STATE" = skip ]; then
  :
elif [ "$CLI" = 0 ]; then
  if [ "$PLUGIN_READY" = 0 ]; then
    echo "Plugin not set up: the claude CLI is not on PATH. The old user-level hooks and agents were left in place."
    print_in_app
    PLUGIN_FAILED=1
  elif [ "$RETIRE" = 1 ]; then
    print_retire_wait
    PLUGIN_FAILED=1
  fi
elif [ "$CLI_STEPS" = 0 ] && [ "$LOAD" = ok ] && [ "$COPY_SYNC" = 0 ]; then
  # Confirmed by the plan's checks, and nothing since has touched the plugin or its copy.
  echo "Plugin $PLUGIN_ID is enabled and loads from $COPY"
  [ "$RETIRE" = 1 ] && retire_old
else
  # A marketplace that points at another folder is re-pointed at the installed copy before anything else.
  # ponytail: install runs even if marketplace add fails (it may already be added); the checks decide.
  if [ "$DO_MARKET" = 1 ]; then
    cli plugin marketplace add "$COPY" || echo "  (claude plugin marketplace add reported an error)"
  fi
  if [ "$DO_INSTALL" = 1 ]; then
    cli plugin install "$PLUGIN_ID" || echo "  (claude plugin install reported an error)"
  fi
  confirm_enabled
fi

# The settings.json as this run left it, so uninstall.sh can say whether it changed since.
if [ -f "$SETTINGS" ] && [ "$(sha256 "$SETTINGS")" != "$SETTINGS_BEFORE" ]; then
  mkdir -p "$CREATED" && sha256 "$SETTINGS" > "$SETTINGS_RECORD"
fi

print_audit_hint
echo "Undo with: bash $KIT_DIR/uninstall.sh (shows the plan and asks first; --dry-run, --latest, --keep-files, --yes)"
exit $PLUGIN_FAILED
