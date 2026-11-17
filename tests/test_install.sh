#!/bin/bash
# Sandbox tests for install.sh and uninstall.sh. Every run uses a temp HOME inside one
# /tmp/workbench-test-install.* dir (this run's own mktemp dir, removed on exit), a scrubbed environment and a
# fake `claude` on PATH, so the live ~/.claude and the real CLI are never touched.
# Regression sections for the round-3 findings: 19 (P1 moved kit), 20 (P2 install/uninstall cycles),
# 21 (P3 CLAUDE_CONFIG_DIR), 22 (P5 no backup without a file change). Round 4: every check named "U<n>: ..."
# covers item n of SPEC.md "Round 4 changes", part U-C (sections 23 to 38, plus checks in the earlier ones).
# Round 5: every check named "C<n>: ..." covers item n of SPEC.md "Round 5 changes", part V-C (sections 32 to 39,
# plus checks in the earlier ones). Round 6: every check named "W-C<n>: ..." covers item n of SPEC.md "Round 6
# changes", part W-C (sections 38 to 42). Round 7: "X-C<n>: ..." covers item n of "Round 7 changes", part X-C
# (sections 43 to 46). Round 8: "Y-C<n>: ..." covers item n of "Round 8 changes", part Y-C (sections 47 to 51).
# Prints ok/FAIL per case and exits non-zero on any failure. Bash 3.2 compatible.
set -u

KIT="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$(mktemp -d /tmp/workbench-test-install.XXXXXX)" || exit 1
case "$ROOT" in
  /tmp/workbench-test-install.*|/private/tmp/workbench-test-install.*) ;;
  *) echo "unexpected sandbox: $ROOT"; exit 1 ;;
esac
trap 'rm -rf "$ROOT"' EXIT
FAKEBIN="$ROOT/fakebin"
LOG="$ROOT/claude-calls.log"
SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$FAKEBIN"
: > "$LOG"

PASS=0
FAIL=0
ok() { echo "ok   $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
jqt() { jq -e "$2" "$1"; }   # jqt FILE FILTER: true when FILTER is truthy for FILE
same_json() { [ "$(jq -S . "$1")" = "$(jq -S . "$2")" ]; }
snap() { (cd "$1" && find . | sort && find . -type f | sort | while read -r f; do shasum "$f"; done); }
calls() { wc -l < "$LOG" | tr -d ' '; }
stamped() { ls -1d "$1"/.claude/backups/workbench-[0-9]* 2>/dev/null; }   # timestamped backups of a sandbox
EXPLORE_SRC="$KIT/user/agents/Explore.md"

# A fake claude CLI: logs its arguments and edits settings.json, plugins/known_marketplaces.json and
# plugins/installed_plugins.json in ${CLAUDE_CONFIG_DIR:-$HOME/.claude} the way the real CLI does.
#   FAKE_CLAUDE_FAIL=1          every call fails
#   FAKE_CLAUDE_INSTALL_NOOP=1  install exits 0 ("already installed") without enabling anything
#   FAKE_CLAUDE_ENABLE_FAIL=1   enable fails
#   FAKE_CLAUDE_LOAD_FAIL=1     plugin list shows workbench as failed to load
#   FAKE_CLAUDE_LOAD_FAIL_IF=REL  plugin list shows it failed to load while the marketplace's installLocation holds
#                               REL (a marker file a test puts in one copy only)
# Like the real CLI, plugin list shows only installed plugins (an enabledPlugins entry alone is not an install),
# install needs the marketplace, and plugin list shows a load failure when the marketplace's installLocation holds
# no marketplace (cache-miss), or when its plugins/workbench/hooks/hooks.json does not parse (hook-load-failed,
# with the file in errorDetails[].path). plugin validate DIR checks the marketplace (DIR/.claude-plugin/
# marketplace.json) or the plugin (its plugin.json, and hooks/hooks.json, whose "hooks" must be an object), and
# prints "Validating <what>: <file>" and "Found N error(s):" as the real one does. Like the real one (2.1.311), it
# exits 0 with "Found N warning(s):" for a hook entry it would ignore at runtime (an unknown event, a command hook
# with no command), and ends the plugin report with plugin directory advice that does not change the verdict.
cat > "$FAKEBIN/claude" <<'EOF'
#!/bin/bash
echo "$*" >> "${FAKE_CLAUDE_LOG:-/dev/null}"
if [ "${FAKE_CLAUDE_FAIL:-0}" = 1 ]; then echo "fake claude: simulated failure" >&2; exit 1; fi
exec /usr/bin/env python3 -I - "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$@" <<'PY'
import json, os, sys
cfg, args = sys.argv[1], sys.argv[2:]
ID = "workbench@workbench"
sp, kp = os.path.join(cfg, "settings.json"), os.path.join(cfg, "plugins", "known_marketplaces.json")
ip = os.path.join(cfg, "plugins", "installed_plugins.json")


def flag(name):
    return os.environ.get(name, "0") == "1"


def load(p):
    return json.load(open(p)) if os.path.exists(p) else {}


def save(p, d):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        json.dump(d, f, indent=2)


EVENTS = set("""PreToolUse PostToolUse PostToolUseFailure PostToolBatch Notification UserPromptSubmit UserPromptExpansion
    SessionStart SessionEnd Stop StopFailure SubagentStart SubagentStop PreCompact PostCompact PreModelSwitch
    PostModelSwitch PermissionRequest PermissionDenied Setup TeammateIdle TaskCreated TaskCompleted Elicitation
    ElicitationResult ConfigChange WorktreeCreate WorktreeRemove InstructionsLoaded CwdChanged FileChanged
    DirectoryAdded MessageDisplay""".split())


def hook_entries(h):
    for ev, groups in h["hooks"].items():
        for i, g in enumerate(groups if isinstance(groups, list) else []):
            for j, e in enumerate(g.get("hooks") if isinstance(g, dict) and isinstance(g.get("hooks"), list) else []):
                yield ev, i, j, e


def hook_error(h):
    """The first error the real validator reports: "hooks" not an object, or a hook type it does not know."""
    if not isinstance(h, dict) or not isinstance(h.get("hooks"), dict):
        return "hooks: Expected object, received array"
    for ev, i, j, e in hook_entries(h):
        if isinstance(e, dict) and e.get("type") not in ("command", "prompt", "agent", "http"):
            return 'hooks: hooks.%s.%d.hooks.%d: Unknown hook type "%s"' % (ev, i, j, e.get("type"))
    return None


def hook_warnings(h):
    """What the real validator warns about and then ignores at runtime: an unknown event, a command hook with no
    command string."""
    if not isinstance(h, dict) or not isinstance(h.get("hooks"), dict):
        return []
    out = ["hooks: hooks.%s: unknown hook event; entry ignored at runtime" % ev for ev in h["hooks"] if ev not in EVENTS]
    for ev, i, j, e in hook_entries(h):
        if ev in EVENTS and isinstance(e, dict) and e.get("type") == "command" and not isinstance(e.get("command"), str):
            out.append("hooks: hooks.%s.%d.hooks.%d: Invalid command hook (command: Invalid input: expected "
                       "string, received undefined); entry ignored at runtime" % (ev, i, j))
    return out


def validate(d):
    errors, warnings = 0, 0

    def one(what, path, check=None, warn=None):
        print("Validating %s: %s" % (what, path))
        found = []
        try:
            with open(path) as f:
                data = json.load(f)
            problem = check(data) if check else None
            found = warn(data) if warn else []
        except (OSError, ValueError) as e:
            problem = "json: Invalid JSON syntax: %s" % e
        if problem:
            print("\nFound 1 error:\n\n  > %s\n" % problem)
        if found:
            print("\n! Found %d warning%s:\n\n%s\n" % (len(found), "s" if len(found) > 1 else "",
                                                       "\n".join("  > " + w for w in found)))
        return (1 if problem else 0), len(found)

    if os.path.isfile(os.path.join(d, ".claude-plugin", "marketplace.json")):
        errors += one("marketplace manifest", os.path.join(d, ".claude-plugin", "marketplace.json"))[0]
    else:
        errors += one("plugin manifest", os.path.join(d, ".claude-plugin", "plugin.json"))[0]
        if os.path.exists(os.path.join(d, "hooks", "hooks.json")):
            e, w = one("hooks", os.path.join(d, "hooks", "hooks.json"),
                       hook_error, hook_warnings)
            errors, warnings = errors + e, warnings + w
        # Like the real one, advice for the plugin directory follows; it never changes the verdict.
        print("\nPlugin directory checks for %s. Advice only.\n\n! Found 1 plugin directory warning:\n\n"
              "  > hooks/hooks.json: a fake directory note (FAKE_DIRECTORY_NOTE)\n" % d)
    print("Validation failed" if errors else "Validation passed with warnings" if warnings else "Validation passed")
    return 1 if errors else 0


s, k, inst = load(sp), load(kp), load(ip)
plugins = s.get("enabledPlugins", {})
installed = inst.setdefault("plugins", {})
cmd = " ".join(args)
if cmd.startswith("plugin validate "):
    sys.exit(validate(args[2]))
elif cmd.startswith("plugin marketplace add "):
    src = {"source": "directory", "path": args[3]}
    k["workbench"] = {"source": src, "installLocation": args[3]}
    s.setdefault("extraKnownMarketplaces", {})["workbench"] = {"source": src}
    save(kp, k)
    save(sp, s)
elif cmd == "plugin install " + ID:
    if ID in installed or flag("FAKE_CLAUDE_INSTALL_NOOP"):
        print('Plugin "%s" is already installed (scope: user)' % ID)
        sys.exit(0)
    if "workbench" not in k:
        sys.stderr.write('Plugin "%s" not found in any configured marketplace\n' % ID)
        sys.exit(1)
    installed[ID] = [{"scope": "user"}]
    save(ip, inst)
    s.setdefault("enabledPlugins", {})[ID] = True
    save(sp, s)
elif cmd == "plugin enable %s --scope user" % ID:
    if flag("FAKE_CLAUDE_ENABLE_FAIL"):
        sys.stderr.write("fake claude: enable blocked\n")
        sys.exit(1)
    if plugins.get(ID) is True:
        print('Plugin "workbench" is already enabled')
        sys.exit(1)
    s.setdefault("enabledPlugins", {})[ID] = True
    save(sp, s)
elif cmd == "plugin list --json":
    out = []
    if ID in installed:
        entry = {"id": ID, "scope": "user", "enabled": plugins.get(ID) is True}
        loc = k.get("workbench", {}).get("installLocation", "")
        hooks = os.path.join(loc, "plugins", "workbench", "hooks", "hooks.json")
        mark = os.environ.get("FAKE_CLAUDE_LOAD_FAIL_IF", "")
        if flag("FAKE_CLAUDE_LOAD_FAIL"):
            entry["errors"] = ["Plugin workbench failed to load: simulated"]
        elif mark and os.path.exists(os.path.join(loc, mark)):
            entry["errors"] = ["Plugin workbench failed to load: simulated by %s" % mark]
        elif not os.path.isfile(os.path.join(loc, ".claude-plugin", "marketplace.json")):
            entry["errors"] = ["Marketplace workbench failed to load: cache-miss"]
            entry["errorDetails"] = [{"type": "marketplace-load-failed", "marketplace": "workbench"}]
        else:
            try:
                json.load(open(hooks))
            except (OSError, ValueError):
                entry["errors"] = ["Hook load failed: JSON Parse error"]
                entry["errorDetails"] = [{"type": "hook-load-failed", "plugin": "workbench", "path": hooks}]
        out.append(entry)
    print(json.dumps(out, indent=2))
elif cmd == "plugin uninstall " + ID:
    if installed.pop(ID, None) is not None:
        save(ip, inst)
    if ID in plugins:
        del plugins[ID]
        save(sp, s)
elif cmd == "plugin marketplace remove workbench":
    if k.pop("workbench", None) is not None:
        save(kp, k)
    if s.get("extraKnownMarketplaces", {}).pop("workbench", None) is not None:
        save(sp, s)
PY
EOF
chmod +x "$FAKEBIN/claude"

# Runs a command on a pseudo-terminal and types ANSWER at the first "[y/N]" prompt: uninstall.sh only asks
# when stdin is a terminal.
cat > "$ROOT/pty_answer.py" <<'EOF'
import os, pty, select, subprocess, sys
answer, cmd = sys.argv[1], sys.argv[2:]
master, slave = pty.openpty()
p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
out, sent = b"", False
while True:
    ready, _, _ = select.select([master], [], [], 60)
    if not ready:
        break
    try:
        data = os.read(master, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
    if not sent and b"[y/N]" in out:
        os.write(master, (answer + "\n").encode())
        sent = True
p.wait()
sys.stdout.write(out.decode("utf-8", "replace").replace("\r\n", "\n"))
sys.exit(p.returncode)
EOF

# run_kit SANDBOX SCRIPT [ARGS...]: run install.sh or uninstall.sh with HOME and --home set to SANDBOX.
# Output lands in $OUT, exit code in $RC. Stdin is empty (not a terminal) unless RUN_TTY is set.
#   RUN_KIT=DIR   run the scripts of the kit copy in DIR     NO_HOME_FLAG=1  leave out --home
#   RUN_CFG=DIR   set CLAUDE_CONFIG_DIR=DIR                  RUN_PATH=...    PATH (default: the fake CLI first)
#   RUN_WB=FILE   set WORKBENCH_CONFIG=FILE                  RUN_TTY=ANSWER  run on a terminal, type ANSWER
run_kit() {
  sb="$1"; script="$2"; shift 2
  [ "${NO_HOME_FLAG:-0}" = 1 ] || set -- --home "$sb" "$@"
  if [ -n "${RUN_TTY:-}" ]; then
    set -- /usr/bin/env python3 -I "$ROOT/pty_answer.py" "$RUN_TTY" /bin/bash "${RUN_KIT:-$KIT}/$script" "$@"
  else
    set -- /bin/bash "${RUN_KIT:-$KIT}/$script" "$@"
  fi
  OUT="$(env -i PATH="${RUN_PATH:-$FAKEBIN:$SYS_PATH}" HOME="$sb" \
    TMPDIR="$ROOT" FAKE_CLAUDE_LOG="$LOG" FAKE_CLAUDE_FAIL="${FAKE_CLAUDE_FAIL:-0}" \
    FAKE_CLAUDE_INSTALL_NOOP="${FAKE_CLAUDE_INSTALL_NOOP:-0}" FAKE_CLAUDE_ENABLE_FAIL="${FAKE_CLAUDE_ENABLE_FAIL:-0}" \
    FAKE_CLAUDE_LOAD_FAIL="${FAKE_CLAUDE_LOAD_FAIL:-0}" FAKE_CLAUDE_LOAD_FAIL_IF="${FAKE_CLAUDE_LOAD_FAIL_IF:-}" \
    ${RUN_CFG:+"CLAUDE_CONFIG_DIR=$RUN_CFG"} \
    ${RUN_WB:+"WORKBENCH_CONFIG=$RUN_WB"} "$@" 2>&1 </dev/null)"
  RC=$?
}
# fake_cli SANDBOX ARGS...: run the fake CLI directly in that sandbox, as a user typing claude would.
fake_cli() { sb="$1"; shift; env -i PATH="$FAKEBIN:$SYS_PATH" HOME="$sb" FAKE_CLAUDE_LOG="$LOG" claude "$@" >/dev/null 2>&1; }
# known_at SANDBOX DIR: record the workbench marketplace at DIR, as an in-app /plugin marketplace add does.
known_at() {
  mkdir -p "$1/.claude/plugins"
  jq -n --arg d "$2" '{workbench: {source: {source: "directory", path: $d}, installLocation: $d}}' \
    > "$1/.claude/plugins/known_marketplaces.json"
}
copy_of() { echo "$1/.claude/workbench-kit"; }   # the installed copy of a sandbox
# copy_matches KIT COPY: the copy holds exactly the runtime subset of KIT (the plugin's tests/ included, C6) plus
# audit-task.md; bytecode and Finder files never reach it.
copy_matches() {
  diff -rq "$1/.claude-plugin" "$2/.claude-plugin" \
    && diff -rq -x __pycache__ -x '*.pyc' -x .DS_Store "$1/plugins/workbench" "$2/plugins/workbench" \
    && cmp -s "$1/LICENSE" "$2/LICENSE" && cmp -s "$1/README.md" "$2/README.md" && [ -f "$2/audit-task.md" ] \
    && [ -f "$2/plugins/workbench/tests/test_hooks.sh" ] && [ -z "$(find "$2" -name __pycache__ -o -name '*.pyc')" ] \
    && [ "$(cd "$2" && ls -A | tr '\n' ' ')" = ".claude-plugin LICENSE README.md audit-task.md plugins " ]
}
# installed_in SANDBOX: record workbench@workbench as installed, as /plugin install in the app does.
installed_in() {
  mkdir -p "$1/.claude/plugins"
  echo '{"plugins": {"workbench@workbench": [{"scope": "user"}]}}' > "$1/.claude/plugins/installed_plugins.json"
}
# setup_log: the CLI calls that set the plugin up; plugin validate (read-only, C5) is checked on its own.
setup_log() { grep -v '^plugin validate ' "$LOG"; }
# plugin_ok SANDBOX: claude plugin list shows workbench@workbench installed, enabled and loading without errors.
plugin_ok() {
  env -i PATH="$FAKEBIN:$SYS_PATH" HOME="$1" FAKE_CLAUDE_LOAD_FAIL_IF="${FAKE_CLAUDE_LOAD_FAIL_IF:-}" claude plugin list --json \
    | jq -e '[.[] | select(.id == "workbench@workbench" and .enabled == true and ((.errors // []) | length == 0))] | length == 1'
}

# The author's own config (private/<author>.workbench.json, git-ignored, never published) and the names it holds,
# read from it so this file names nobody: the author's name and its parts, and every repo, remote, group and
# ERP-specific token it lists. A clone of the published kit has no private/; the checks that need it are skipped.
OWN_EX="$(ls -1 "$KIT"/private/*.workbench.json 2>/dev/null | head -n 1)"
own_check() { if [ -n "$OWN_EX" ]; then check "$@"; else echo "skip $1 (no private/*.workbench.json)"; fi; }
own_names() {
  jq -r '[(.author // "" | ., splits(" +")),
      (((.uv_repos // [])[], (.pytest_env_required.paths // [])[], ((.repo_groups // [])[] | .repos[]?, .memory_dir)) | strings | split("/") | last),
      ((.commit_gates // [])[].remote | strings | split("/") | .[], (.[0] | split("-")[0])), ((.repo_groups // [])[].name | strings),
      ((.pytest_env_required.accept // [])[] | select(test("^[A-Za-z]")) | rtrimstr("="))]
    | map(select(length > 2)) | unique | .[]' "$OWN_EX" 2>/dev/null
}
# Short lowercase names (a group like "abc") are matched as whole words, case-sensitive, so the same letters in
# prose ("ABC") are not a mention; the rest are matched case-insensitively anywhere.
NAMES_CI=""; NAMES_CS=""; NAMES_N=0
while IFS= read -r n; do
  [ -n "$n" ] || continue
  n="$(printf '%s' "$n" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
  case "$n" in
    [a-z][a-z][a-z]|[a-z][a-z][a-z][a-z]) NAMES_CS="${NAMES_CS:+$NAMES_CS|}$n" ;;
    *) NAMES_CI="${NAMES_CI:+$NAMES_CI|}$n" ;;
  esac
  NAMES_N=$((NAMES_N + 1))
done <<EOF
$(own_names)
EOF
# named_in GREP_FLAGS PATH...: file:line of every mention of those names. A line that lists names as a grep -E
# pattern (another suite's own no-name check) is not a mention.
named_in() {
  flags="$1"; shift
  { [ -n "$NAMES_CI" ] && grep -H "$flags"niE "$NAMES_CI" "$@"; [ -n "$NAMES_CS" ] && grep -H "$flags"nwE "$NAMES_CS" "$@"; } 2>/dev/null \
    | grep -vE 'grep -[a-zA-Z]*E' | cut -d: -f1,2 | sort -u
}
names_nobody() { [ -z "$(named_in - "$@")" ]; }

# new_sandbox NAME [nogit]: a home dir with .claude/ and, unless nogit, a .gitconfig naming "Sam Sandbox".
new_sandbox() {
  d="$ROOT/$1"; mkdir -p "$d/.claude"
  [ "${2:-}" = nogit ] || printf '[user]\n\tname = Sam Sandbox\n' > "$d/.gitconfig"
  echo "$d"
}

# Seed: extra user keys, one overlapping allow rule, a home-absolute .env deny that matches the kit's
# ~/ rule, an autoMode list without "$defaults", and old user-level hook entries next to unrelated ones.
# write_seed SANDBOX [CONFIG_DIR]: writes CONFIG_DIR/settings.json (default SANDBOX/.claude).
write_seed() {
  sb="$1"
  cat > "${2:-$sb/.claude}/settings.json" <<EOF
{
  "model": "opus",
  "theme": "dark",
  "env": {"MY_VAR": "1", "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "3"},
  "permissions": {
    "allow": ["Bash(git status*)", "Bash(make test*)"],
    "deny": ["Read(/$sb/**/.env)", "Bash(rm -rf /*)"],
    "additionalDirectories": ["/tmp"]
  },
  "bashOutputMaxChars": 5000,
  "autoMode": {
    "environment": ["Source control: example.org/team"],
    "soft_deny": ["\$defaults", "never touch the staging DB"]
  },
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "\"\$HOME/.claude/hooks/guard.sh\"", "timeout": 5},
        {"type": "command", "command": "\$HOME/bin/my_other_hook.sh"}]},
      {"matcher": "Bash|mcp__playwright.*", "hooks": [
        {"type": "command", "command": "\"\$HOME/.claude/hooks/browser_cap.sh\"", "timeout": 5}]}
    ],
    "PostToolUse": [
      {"matcher": "Edit|Write", "hooks": [
        {"type": "command", "command": "\"\$HOME/.claude/hooks/format_py.sh\"", "timeout": 60}]}
    ],
    "Notification": [
      {"hooks": [{"type": "command", "command": "\$HOME/bin/notify.sh"}]}
    ]
  }
}
EOF
}
set_json() { jq "$2" "$1" > "$ROOT/t.json" && mv "$ROOT/t.json" "$1"; }   # set_json FILE FILTER
OLD_HOOKS_GONE='[.. | objects | .command? // empty | select(test("\\.claude/hooks/"))] | length == 0'
hooks_as_seeded() { [ "$(jq -S .hooks "$1")" = "$(jq -S .hooks "$2")" ]; }   # hooks_as_seeded FILE SEED
# own_agents SANDBOX: user-level reviewer.md and gate-runner.md of an earlier hand-made setup.
own_agents() {
  mkdir -p "$1/.claude/agents"
  printf -- '---\nname: reviewer\n---\nMy reviewer.\n' > "$1/.claude/agents/reviewer.md"
  printf -- '---\nname: gate-runner\n---\nMy gate runner.\n' > "$1/.claude/agents/gate-runner.md"
}

echo "# sandbox root: $ROOT"

# --- 0. kit files ------------------------------------------------------------------------------------
EX="$KIT/kit.config.example.json"
check "example config is neutral (no author, repos, gates or groups)" \
  jqt "$EX" '.author == "" and .uv_repos == [] and .commit_gates == [] and .repo_groups == [] and .pytest_env_required.paths == [] and .pytest_env_required.accept == []'
check "example config: _examples has one entry of each shape" \
  jqt "$EX" '._examples | (.uv_repos | length == 1) and (.pytest_env_required.paths | length == 1)
    and (.commit_gates | length == 1) and (.commit_gates[0] | has("remote") and has("require") and (.checks[0] | has("name") and has("files") and has("cmd")))
    and (.repo_groups | length == 1) and (.repo_groups[0] | has("name") and has("memory_dir") and has("repos"))'
own_check "C8: the author's own config is in private/ and names at least 8 things to keep out of shared files" \
  [ -n "$OWN_EX" -a "$NAMES_N" -ge 8 -a -n "$NAMES_CI" -a -n "$NAMES_CS" ]
check "example config names nobody" names_nobody "$EX" "$KIT/user/CLAUDE.md.template" "$KIT/user/settings.fragment.json" "$KIT/user/audit-task.md" "$EXPLORE_SRC"
own_check "the author's own config keeps its real values" \
  jqt "$OWN_EX" '(.author | length > 0) and (.commit_gates | length == 2) and (.repo_groups[0].name | length > 0) and (.uv_repos | length > 0)'
own_check "U15: the author's own config denies a commit when a gate's tool is missing, on both gates" \
  jqt "$OWN_EX" '[.commit_gates[].on_missing_tool] == ["deny", "deny"]'
own="$(named_in - "$KIT/tests/test_install.sh" "$KIT/install.sh" "$KIT/uninstall.sh" "$KIT"/user/*.* "$KIT"/user/agents/* "$KIT/kit.config.example.json" | tr '\n' ' ')"
check "C8: test_install.sh, the installer and user/ name nobody from the author's config" [ -z "$own" ]
[ -z "$own" ] || echo "     still named: $own"
check "marketplace and plugin are named workbench" \
  jq -e -n --slurpfile m "$KIT/.claude-plugin/marketplace.json" --slurpfile p "$KIT/plugins/workbench/.claude-plugin/plugin.json" \
  '$m[0].name == "workbench" and $m[0].plugins[0].name == "workbench" and $m[0].plugins[0].source == "./plugins/workbench" and $p[0].name == "workbench" and $p[0].license == "MIT"'
check "LICENSE at the kit root and in the plugin" [ -s "$KIT/LICENSE" -a -s "$KIT/plugins/workbench/LICENSE" ]
check "hooks.json: four scripts via CLAUDE_PLUGIN_ROOT, timeouts 5/180/5/60" \
  jqt "$KIT/plugins/workbench/hooks/hooks.json" '[.hooks[][].hooks[] | select(.command | contains("${CLAUDE_PLUGIN_ROOT}/scripts/")) | {s: (.command | capture("scripts/(?<s>[a-z_]+)[.]sh").s), t: .timeout}] | sort_by(.s) == [{"s":"browser_cap","t":5},{"s":"commit_gate","t":180},{"s":"format_py","t":60},{"s":"guard","t":5}]'
check "audit-task.md is a plain prompt that calls the skill" \
  [ "$(head -n 1 "$KIT/user/audit-task.md")" = "/workbench:config-audit" ]
check "audit-task.md has the inline fallback" grep -q 'claude plugin list' "$KIT/user/audit-task.md"
check "U12: audit-task.md fallback FAILs a plugin that failed to load" \
  grep -q 'FAIL when workbench@workbench is missing, disabled, or listed with errors ("failed to load")' "$KIT/user/audit-task.md"
check "C9: audit-task.md fallback FAILs when the workbench marketplace's install location is missing" \
  grep -q "FAIL when the workbench marketplace's install location does not exist (the \`installLocation\` of the \`workbench\` entry in <cfg>/plugins/known_marketplaces.json" "$KIT/user/audit-task.md"
check "U10: CLAUDE.md template and audit-task.md name the config through placeholders, not ~/.claude" \
  [ "$(grep -c '{{WORKBENCH_JSON}}' "$KIT/user/CLAUDE.md.template")" -ge 1 -a "$(grep -c '{{CONFIG_DIR}}' "$KIT/user/audit-task.md")" -ge 1 \
    -a "$(cat "$KIT/user/CLAUDE.md.template" "$KIT/user/audit-task.md" | grep -c '~/\.claude')" = 0 ]
check "U10: plugin.json description does not pin ~/.claude/workbench.json" \
  jqt "$KIT/plugins/workbench/.claude-plugin/plugin.json" '.description | contains("~/.claude/workbench.json") | not'
old_names="$(cd "$KIT" && grep -l -E 'claude-kit|kit\.json|CLAUDE_KIT_CONFIG|KIT_GATE_TIMEOUT' \
  install.sh uninstall.sh README.md user/*.* user/agents/* kit.config.example.json .claude-plugin/marketplace.json \
  plugins/workbench/.claude-plugin/plugin.json plugins/workbench/hooks/hooks.json 2>/dev/null)"
check "no round-1 names left in installer, docs and manifests" [ -z "$old_names" ]
[ -z "$old_names" ] || echo "     still named: $old_names"
FRAG="$KIT/user/settings.fragment.json"
check "fragment: 17 allow, 14 ask, 14 deny" \
  jqt "$FRAG" '.permissions | (.allow | length == 17) and (.ask | length == 14) and (.deny | length == 14)'
check "fragment: no repo-specific verify_dev rule (P6)" [ "$(grep -c verify_dev "$FRAG")" = 0 ]
check "fragment: editing workbench.json asks (I2)" jqt "$FRAG" '.permissions.ask | index(["Edit(~/.claude/workbench.json)"]) != null'
check "U1: fragment: editing the installed copy asks, and hooks/ still asks" \
  jqt "$FRAG" '.permissions.ask | index(["Edit(~/.claude/workbench-kit/**)"]) != null and index(["Edit(~/.claude/hooks/**)"]) != null'
check "plugin ships only the reviewer and gate-runner agents (P4)" \
  [ "$(cd "$KIT/plugins/workbench/agents" && ls | tr '\n' ' ')" = "gate-runner.md reviewer.md " ]
check "the Explore agent lives in user/agents (P4)" grep -q '^name: Explore$' "$EXPLORE_SRC"
check ".gitignore covers __pycache__/, *.pyc and .DS_Store (I3)" \
  [ "$(grep -c -x -e '__pycache__/' -e '\*\.pyc' -e '\.DS_Store' "$KIT/.gitignore" 2>/dev/null)" = 3 ]
check "kit files have no em dash" [ -z "$(cd "$KIT" && grep -l "$(printf '\342\200\224')" install.sh uninstall.sh README.md .gitignore user/*.* user/agents/* examples/* tests/test_install.sh 2>/dev/null)" ]
# DS-10: the author's name only in LICENSE and the manifests' owner/author fields; no ERP-specific text in the
# plugin (its tests run in every teammate's audit).
jq 'del(.owner)' "$KIT/.claude-plugin/marketplace.json" > "$ROOT/m-no-owner.json"
jq 'del(.author)' "$KIT/plugins/workbench/.claude-plugin/plugin.json" > "$ROOT/p-no-author.json"
check "U13: manifests name the author only in owner/author" names_nobody "$ROOT/m-no-owner.json" "$ROOT/p-no-author.json"
# LICENSE and plugin.json (checked above without its author field) may name the author.
plugin_named="$(cd "$KIT/plugins/workbench" && named_in -r . | grep -vE '^(\./)?(LICENSE|\.claude-plugin/plugin\.json):' | cut -d: -f1 | sort -u | tr '\n' ' ')"
check "U13: the plugin (tests included) carries no personal name or ERP-specific text" [ -z "$plugin_named" ]
[ -z "$plugin_named" ] || echo "     still named: $plugin_named"
check "U13: README says where the author's name appears" \
  grep -q "names the kit's author only in LICENSE and in the owner and author fields of the two manifests" "$KIT/README.md"
check "C7: README says private/ is git-ignored and never published" \
  bash -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "\`private/\` is git-ignored, so nothing in it is ever published"' _ "$KIT/README.md"
check "C7: no build history or author config is tracked outside private/" \
  [ -z "$(git -C "$KIT" ls-files 2>/dev/null | grep -E '(^|/)SPEC\.md$|^examples/|\.workbench\.json$|^private/')" ]
check "C7: .gitignore keeps private/ out of git" grep -qx 'private/' "$KIT/.gitignore"
LIMITS="$(sed -n '/^## Known limits/,$p' "$KIT/README.md")"
check "U16: Known limits: trailer files read via ~, \$HOME, \$TMPDIR, \$PWD" grep -q '`~`, `$HOME`, `$TMPDIR`, `$PWD`' <<< "$LIMITS"
check "U16: Known limits: uv run git, sudo and find -exec are not parsed" grep -q '`uv run git`, `sudo` and `find -exec`' <<< "$LIMITS"
check "U16: Known limits: pytest and uv rules use each command's own dir" grep -q "each command's own folder" <<< "$LIMITS"
check "U16: Known limits: editing the kit needs a re-run of install.sh" grep -q 'run `bash install.sh --apply` again' <<< "$LIMITS"
check "U16: Known limits: --replace-old and the uninstall flags" \
  bash -c 'for w in --replace-old --dry-run --keep-files --yes --latest; do grep -q -- "$w" <<< "$1" || exit 1; done' _ "$LIMITS"
check "U16: README states the permission counts" grep -q '17 allow, 14 ask and 14 deny' "$KIT/README.md"

# --- 1. dry run writes nothing --------------------------------------------------------------------
SB="$(new_sandbox main)"
write_seed "$SB"
cp "$SB/.claude/settings.json" "$ROOT/seed.json"
before="$(snap "$SB")"
run_kit "$SB" install.sh
check "dry run exits 0" [ "$RC" = 0 ]
check "dry run writes nothing" [ "$before" = "$(snap "$SB")" ]
check "dry run prints a JSON diff" grep -q -- '--- JSON diff of settings.json ---' <<< "$OUT"
check "dry run diff shows a kit allow rule" grep -q '^+.*"Bash(npm run \*)"' <<< "$OUT"
check "dry run plans the plugin step" grep -q 'claude plugin install workbench@workbench' <<< "$OUT"
check "dry run plans the original backup" grep -q 'backups/workbench-original/ (written once' <<< "$OUT"
check "dry run plans the Explore copy" grep -q "agents/Explore.md: copy the kit's Explore agent" <<< "$OUT"
check "dry run takes the author from git config" grep -q 'author: "Sam Sandbox" (from git config' <<< "$OUT"
check "dry run calls no claude CLI" [ "$(calls)" = 0 ]
check "U1: dry run plans the installed copy" grep -q "installed copy: create $SB/.claude/workbench-kit" <<< "$OUT"
check "U1: dry run adds the marketplace from the installed copy" grep -q "claude plugin marketplace add \"$SB/.claude/workbench-kit\"" <<< "$OUT"

# --- 2. first apply --no-plugin ------------------------------------------------------------------------
run_kit "$SB" install.sh --apply --no-plugin
S="$SB/.claude/settings.json"
ORIG="$SB/.claude/backups/workbench-original"
check "apply exits 0" [ "$RC" = 0 ]
check "settings.json is valid JSON" jq -e . "$S"
check "original backup made" [ -d "$ORIG" ]
check "no timestamped backup on the first run" [ -z "$(stamped "$SB")" ]
check "original holds the pre-kit settings.json" cmp -s "$ORIG/settings.json" "$ROOT/seed.json"
check "original marks CLAUDE.md as absent" [ -f "$ORIG/CLAUDE.md.absent" ]
check "original marks agents/Explore.md as absent" [ -f "$ORIG/agents/Explore.md.absent" ]
check "user scalar keys kept" jqt "$S" '.model == "opus" and .theme == "dark" and .bashOutputMaxChars == 5000'
check "user env kept, user value wins" jqt "$S" '.env.MY_VAR == "1" and .env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS == "3"'
check "kit env key added" jqt "$S" '.env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD == "1"'
check "user-only permission key kept" jqt "$S" '.permissions.additionalDirectories == ["/tmp"]'
check "no list anywhere has duplicates" jqt "$S" '[.. | arrays | length == (unique | length)] | all'
check "allow: user order first, union of 2 + 17 minus 1 overlap" \
  jqt "$S" '.permissions.allow | .[0] == "Bash(git status*)" and .[1] == "Bash(make test*)" and length == 18'
check "allow has every kit rule" jq -e --slurpfile f "$KIT/user/settings.fragment.json" \
  '(.permissions.allow) as $a | $f[0].permissions.allow | all(. as $x | $a | index([$x]))' "$S"
check "ask gets all 14 kit rules" jqt "$S" '.permissions.ask | length == 14'
check "deny: home-absolute .env rule counts as the kit's ~/ rule" \
  jqt "$S" '.permissions.deny | (index(["Read(~/**/.env)"]) | not) and (index(["Edit(~/**/.env)"]) != null) and length == 15'
check "autoMode list without \$defaults left without it" \
  jqt "$S" '.autoMode.environment == ["Source control: example.org/team"]'
check "autoMode soft_deny unioned, \$defaults once and first" \
  jqt "$S" '.autoMode.soft_deny | .[0] == "$defaults" and .[1] == "never touch the staging DB" and length == 5 and (map(select(. == "$defaults")) | length == 1)'
check "autoMode hard_deny and allow added with \$defaults first" \
  jqt "$S" '.autoMode.hard_deny[0] == "$defaults" and (.autoMode.hard_deny | length == 2) and .autoMode.allow == ["$defaults"]'
check "--no-plugin leaves hooks untouched" hooks_as_seeded "$S" "$ROOT/seed.json"
W="$SB/.claude/workbench.json"
check "workbench.json created with the git config author" jqt "$W" '.author == "Sam Sandbox"'
check "workbench.json is the example otherwise (incl. _examples)" \
  jq -e -n --slurpfile w "$W" --slurpfile e "$EX" '($w[0] | del(.author)) == ($e[0] | del(.author))'
check "no kit.json written" [ ! -e "$SB/.claude/kit.json" ]
check "CLAUDE.md created with the author filled in" grep -q "^# Sam Sandbox's rules for every repo" "$SB/.claude/CLAUDE.md"
check "CLAUDE.md has no placeholder left" [ "$(grep -c '{{' "$SB/.claude/CLAUDE.md")" = 0 ]
check "a teammate's install names nobody else" names_nobody "$W" "$SB/.claude/CLAUDE.md" "$S" "$(copy_of "$SB")/audit-task.md"
check "Explore agent copied to user level" cmp -s "$SB/.claude/agents/Explore.md" "$EXPLORE_SRC"
check "Explore copy recorded for uninstall" cmp -s "$SB/.claude/backups/workbench-created/agents/Explore.md" "$EXPLORE_SRC"
check "CLAUDE.md sha256 recorded for uninstall" \
  [ "$(cat "$SB/.claude/backups/workbench-created/CLAUDE.md.sha256" 2>/dev/null)" = "$(shasum -a 256 < "$SB/.claude/CLAUDE.md" | cut -d' ' -f1)" ]
check "--no-plugin calls no claude CLI" [ "$(calls)" = 0 ]
check "U1, C6: the installed copy holds the runtime subset, the plugin's tests/ included" copy_matches "$KIT" "$(copy_of "$SB")"
check "C6: the copy's hook self-test is the checkout's (config-audit check 3 runs it)" \
  cmp -s "$KIT/plugins/workbench/tests/test_hooks.sh" "$(copy_of "$SB")/plugins/workbench/tests/test_hooks.sh"
check "U1: the installed copy's audit prompt is rendered (no placeholder left)" \
  [ "$(grep -c '{{' "$(copy_of "$SB")/audit-task.md")" = 0 -a "$(grep -c 'config folder, ~/.claude\.' "$(copy_of "$SB")/audit-task.md")" = 1 ]
check "U1: the copy's ask rule is in settings.json" jqt "$S" '.permissions.ask | index(["Edit(~/.claude/workbench-kit/**)"]) != null'
check "U2: the applied fragment is recorded" \
  same_json "$SB/.claude/backups/workbench-created/settings.fragment.applied.json" "$FRAG"
cp "$S" "$ROOT/merged.json"

# --- 3. second apply is a no-op -----------------------------------------------------------------------
before="$(snap "$SB")"
run_kit "$SB" install.sh --apply --no-plugin
check "second apply exits 0" [ "$RC" = 0 ]
check "second apply reports nothing to change" grep -q 'Nothing to change.' <<< "$OUT"
check "second apply changes no file and makes no backup" [ "$before" = "$(snap "$SB")" ]
check "U1: second apply sees the copy in step with the kit" grep -q 'installed copy: .* matches this folder, no change' <<< "$OUT"
check "U14: second apply calls the kit's own CLAUDE.md render the kit's version" grep -q "CLAUDE.md: the kit's version, no change" <<< "$OUT"

# --- 4. uninstall: nothing changes until --yes (or y on a terminal); then the original comes back -------
before="$(snap "$SB")"
: > "$LOG"
run_kit "$SB" uninstall.sh
check "U4: uninstall without a terminal or --yes exits 0" [ "$RC" = 0 ]
check "U4: uninstall without a terminal or --yes changes nothing" [ "$before" = "$(snap "$SB")" ]
check "U4: uninstall without a terminal or --yes runs no claude CLI" [ "$(calls)" = 0 ]
check "U4: uninstall without a terminal says nothing changed and how to go ahead" grep -q 'nothing changed. Re-run with --yes' <<< "$OUT"
check "uninstall plan shows the plugin and the backup" \
  grep -q 'plugin: claude plugin uninstall workbench@workbench' <<< "$OUT"
run_kit "$SB" uninstall.sh --dry-run
check "U4: uninstall --dry-run exits 0, prints the plan and changes nothing" \
  [ "$RC" = 0 -a "$before" = "$(snap "$SB")" -a "$(calls)" = 0 ]
check "U4: uninstall --dry-run says so" grep -q 'Dry run: nothing changed.' <<< "$OUT"
RUN_TTY=n run_kit "$SB" uninstall.sh
check "U4: uninstall answered n on a terminal changes nothing and runs no CLI" \
  [ "$RC" = 0 -a "$before" = "$(snap "$SB")" -a "$(calls)" = 0 ]
check "U4: uninstall answered n says nothing changed" grep -q '^Nothing changed.' <<< "$OUT"
check "uninstall (n) keeps the merged settings" cmp -s "$S" "$ROOT/merged.json"
check "uninstall (n) keeps the original backup in place" [ -d "$ORIG" ]
RUN_TTY=y run_kit "$SB" uninstall.sh
check "uninstall (y on a terminal) exits 0" [ "$RC" = 0 ]
check "uninstall runs claude plugin uninstall" grep -qx 'plugin uninstall workbench@workbench' "$LOG"
check "uninstall removes the workbench marketplace" grep -qx 'plugin marketplace remove workbench' "$LOG"
check "uninstall (y) restores settings.json byte for byte" cmp -s "$S" "$ROOT/seed.json"
check "uninstall (y) moves the installed CLAUDE.md aside" [ ! -e "$SB/.claude/CLAUDE.md" ]
check "uninstall (y) drops the CLAUDE.md record" [ ! -e "$SB/.claude/backups/workbench-created/CLAUDE.md.sha256" ]
check "uninstall (y) removes the Explore it created" [ ! -e "$SB/.claude/agents/Explore.md" ]
check "uninstall (y) drops the Explore record" [ ! -e "$SB/.claude/backups/workbench-created/agents/Explore.md" ]
check "U14: uninstall (y) removes the emptied workbench-created/ folders" [ ! -e "$SB/.claude/backups/workbench-created" ]
ARCH="$(ls -1d "$ORIG".restored-* 2>/dev/null | head -n 1)"
check "uninstall (y) archives the original as workbench-original.restored-<stamp>" [ -n "$ARCH" -a ! -e "$ORIG" ]
check "uninstall (y) keeps a copy of what it replaced" \
  ls "$ARCH"/CLAUDE.md.before-uninstall-* "$ARCH"/settings.json.before-uninstall-* "$ARCH"/agents/Explore.md.before-uninstall-*
check "U1: uninstall moves the installed copy into the restored archive" \
  [ ! -e "$(copy_of "$SB")" -a -n "$(ls -1d "$ARCH"/workbench-kit.before-uninstall-* 2>/dev/null)" ]
check "uninstall keeps workbench.json" [ -f "$W" ]

# --- 5. invalid settings.json or workbench.json is refused --------------------------------------------
SB="$(new_sandbox broken)"
printf '{"permissions": {"allow": ["Bash(ls*)",]}}\n' > "$SB/.claude/settings.json"
before="$(snap "$SB")"
run_kit "$SB" install.sh --apply --no-plugin
check "invalid JSON: apply exits 1" [ "$RC" = 1 ]
check "invalid JSON: error names the file" grep -q 'settings.json is not valid JSON' <<< "$OUT"
check "invalid JSON: nothing written (no backup, workbench.json, CLAUDE.md, agent or copy)" [ "$before" = "$(snap "$SB")" ]
run_kit "$SB" install.sh
check "invalid JSON: dry run also stops with exit 1" [ "$RC" = 1 ]
SB="$(new_sandbox broken-config)"
printf '{"author": "Pat",}\n' > "$SB/.claude/workbench.json"
before="$(snap "$SB")"
run_kit "$SB" install.sh --apply --no-plugin
check "invalid workbench.json: apply exits 1 and writes nothing" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ]

# --- 6. existing CLAUDE.md and workbench.json are kept; no settings.json yet --------------------------
SB="$(new_sandbox existing nogit)"
echo "my own rules" > "$SB/.claude/CLAUDE.md"
echo '{"author": "Pat Example"}' > "$SB/.claude/workbench.json"
run_kit "$SB" install.sh --apply --no-plugin
check "fresh settings: apply exits 0" [ "$RC" = 0 ]
check "existing CLAUDE.md left as is" [ "$(cat "$SB/.claude/CLAUDE.md")" = "my own rules" ]
check "existing CLAUDE.md gets a hint" grep -q 'CLAUDE.md: exists, left as is' <<< "$OUT"
check "existing workbench.json left as is" [ "$(cat "$SB/.claude/workbench.json")" = '{"author": "Pat Example"}' ]
check "missing settings.json becomes the fragment" same_json "$SB/.claude/settings.json" "$KIT/user/settings.fragment.json"
b6="$SB/.claude/backups/workbench-original"
check "original marks the missing settings.json as absent" [ -f "$b6/settings.json.absent" ]
check "original copies the existing CLAUDE.md" cmp -s "$b6/CLAUDE.md" "$SB/.claude/CLAUDE.md"
run_kit "$SB" uninstall.sh --yes
check "uninstall moves the created settings.json aside" [ ! -e "$SB/.claude/settings.json" ]
check "uninstall leaves the user's CLAUDE.md content" [ "$(cat "$SB/.claude/CLAUDE.md")" = "my own rules" ]

# --- 7. author: workbench.json, then --author, then git config, else refuse ----------------------------
SB="$(new_sandbox author)"
echo '{"author": "Pat Example"}' > "$SB/.claude/workbench.json"
run_kit "$SB" install.sh --apply --no-plugin --author "Lee Flag"
check "existing workbench.json author beats --author and git config" grep -q "^# Pat Example's rules for every repo" "$SB/.claude/CLAUDE.md"
check "commit rule names the workbench.json author" grep -q 'authored by Pat Example\.' "$SB/.claude/CLAUDE.md"
check "ignored --author is reported" grep -q 'note: --author ignored' <<< "$OUT"
SB="$(new_sandbox flag)"
run_kit "$SB" install.sh --apply --no-plugin --author "Ann \"Lee\" O'Neil"
check "--author beats git config on a first install" jqt "$SB/.claude/workbench.json" '.author == "Ann \"Lee\" O'"'"'Neil"'
check "--author keeps the example layout" grep -q '"repos": \["~/code/api", "~/code/web"\]' "$SB/.claude/workbench.json"
check "CLAUDE.md rendered from --author" grep -q "^# Ann \"Lee\" O'Neil's rules for every repo" "$SB/.claude/CLAUDE.md"
SB="$(new_sandbox anonymous nogit)"
before="$(snap "$SB")"
run_kit "$SB" install.sh --apply --no-plugin
check "no author anywhere: apply exits 1" [ "$RC" = 1 ]
check "no author anywhere: message says how to fix it" grep -q 'Pass --author "Your Name", or set git config --global user.name' <<< "$OUT"
check "no author anywhere: nothing written" [ "$before" = "$(snap "$SB")" ]
run_kit "$SB" install.sh
check "U14: no author anywhere: the dry run still shows the plan and exits 0" [ "$RC" = 0 ]
check "U14: no author anywhere: the dry run shows the author placeholder" grep -q 'author: "<author: pass --author>"' <<< "$OUT"
check "U14: no author anywhere: the dry run writes nothing" [ "$before" = "$(snap "$SB")" ]

# --- 8. plugin step with the fake CLI: installs; old hooks stay unless --replace-old ---------------------
SB="$(new_sandbox plugin)"
write_seed "$SB"
S="$SB/.claude/settings.json"
C="$(copy_of "$SB")"
: > "$LOG"
run_kit "$SB" install.sh --apply
check "plugin: apply exits 0" [ "$RC" = 0 ]
check "U1: plugin: marketplace add from the installed copy, install, then plugin list to confirm" \
  [ "$(setup_log)" = "$(printf 'plugin marketplace add %s\nplugin install workbench@workbench\nplugin list --json' "$C")" ]
check "C5: plugin: the new copy is validated (marketplace, then plugin) before anything else" \
  bash -c 'head -n 2 "$1" | sed "s|^plugin validate [^ ]*/copy|plugin validate COPY|" | tr "\n" " " | grep -qx "plugin validate COPY plugin validate COPY/plugins/workbench "' _ "$LOG"
check "plugin: enabled in settings" jqt "$S" '.enabledPlugins["workbench@workbench"] == true'
check "U1: plugin: known_marketplaces.json points at the installed copy" \
  jqt "$SB/.claude/plugins/known_marketplaces.json" ".workbench.installLocation == \"$C\""
check "U3: plugin: without --replace-old the old hooks stay" hooks_as_seeded "$S" "$ROOT/seed.json"
check "U3: plugin: the plan says they run alongside the plugin" \
  grep -q 'will run alongside the plugin; pass --replace-old to retire them' <<< "$OUT"
check "U3: plugin: the plan no longer claims the plugin runs the same scripts" [ "$(grep -c 'the plugin runs the same scripts' <<< "$OUT")" = 0 ]
before="$(snap "$SB")"
run_kit "$SB" install.sh --apply
check "plugin: second apply reports nothing to change" grep -q 'Nothing to change.' <<< "$OUT"
check "plugin: second apply only reads plugin list" [ "$(setup_log | sed -n '4,$p')" = 'plugin list --json' ]
check "C5: plugin: the second apply (copy in step) validates nothing" [ "$(grep -c '^plugin validate ' "$LOG")" = 2 ]
check "plugin: second apply changes no file" [ "$before" = "$(snap "$SB")" ]
run_kit "$SB" install.sh --apply --replace-old
check "plugin --replace-old: exit 0" [ "$RC" = 0 ]
check "plugin --replace-old: old guard/browser_cap/format_py entries removed" jqt "$S" "$OLD_HOOKS_GONE"
check "plugin --replace-old: unrelated hook in the same group kept" \
  jqt "$S" '.hooks.PreToolUse == [{"matcher": "Bash", "hooks": [{"type": "command", "command": "$HOME/bin/my_other_hook.sh"}]}]'
check "plugin --replace-old: emptied event dropped, other events kept" \
  jqt "$S" '(.hooks | has("PostToolUse") | not) and .hooks.Notification[0].hooks[0].command == "$HOME/bin/notify.sh"'
check "plugin: original backup holds the old hooks" jqt "$SB/.claude/backups/workbench-original/settings.json" '.hooks.PostToolUse | length == 1'

# --- 9. plugin step fails: hooks stay, in-app steps printed ------------------------------------------
SB="$(new_sandbox plugin-fail)"
write_seed "$SB"
FAKE_CLAUDE_FAIL=1 run_kit "$SB" install.sh --apply --replace-old
check "CLI failure: exit 1" [ "$RC" = 1 ]
check "CLI failure: prints the in-app equivalent for the installed copy" grep -q "/plugin marketplace add $SB/.claude/workbench-kit" <<< "$OUT"
check "CLI failure: old hooks left in place" hooks_as_seeded "$SB/.claude/settings.json" "$ROOT/seed.json"
check "CLI failure: settings still merged" jqt "$SB/.claude/settings.json" '.permissions.ask | length == 14'

# --- 10. no claude on PATH ---------------------------------------------------------------------------
SB="$(new_sandbox no-cli)"
write_seed "$SB"
RUN_PATH="$SYS_PATH" run_kit "$SB" install.sh --apply --replace-old
check "no CLI: exit 1" [ "$RC" = 1 ]
check "no CLI: prints the in-app install step" grep -q '/plugin install workbench@workbench' <<< "$OUT"
check "no CLI: old hooks left in place" hooks_as_seeded "$SB/.claude/settings.json" "$ROOT/seed.json"
check "U1: no CLI: the installed copy is still written for the in-app step" copy_matches "$KIT" "$(copy_of "$SB")"

# --- 11. plugin already enabled in the app (from the installed copy) -----------------------------------
SB="$(new_sandbox in-app)"
write_seed "$SB"
RUN_PATH="$SYS_PATH" run_kit "$SB" install.sh --apply           # no CLI: the copy is written, the plugin waits
fake_cli "$SB" plugin marketplace add "$(copy_of "$SB")"          # the /plugin steps it printed, run in the app
fake_cli "$SB" plugin install workbench@workbench
: > "$LOG"
run_kit "$SB" install.sh --apply --replace-old
check "in-app install: exit 0" [ "$RC" = 0 ]
check "in-app install: the only CLI call is plugin list" [ "$(cat "$LOG")" = 'plugin list --json' ]
check "in-app install --replace-old: old hooks removed" jqt "$SB/.claude/settings.json" "$OLD_HOOKS_GONE"
SB="$(new_sandbox in-app-no-cli)"
write_seed "$SB"
RUN_PATH="$SYS_PATH" run_kit "$SB" install.sh --apply
fake_cli "$SB" plugin marketplace add "$(copy_of "$SB")"
fake_cli "$SB" plugin install workbench@workbench
cp "$SB/.claude/settings.json" "$ROOT/in-app-no-cli.json"
RUN_PATH="$SYS_PATH" run_kit "$SB" install.sh --apply
check "in-app install, no CLI: nothing to retire asked, so exit 0" [ "$RC" = 0 ]
check "in-app install, no CLI: old hooks kept" hooks_as_seeded "$SB/.claude/settings.json" "$ROOT/in-app-no-cli.json"
before="$(snap "$SB")"
RUN_PATH="$SYS_PATH" run_kit "$SB" install.sh --apply --replace-old
check "U5: no CLI, --replace-old: old hooks are never removed" hooks_as_seeded "$SB/.claude/settings.json" "$ROOT/in-app-no-cli.json"
check "U5: no CLI, --replace-old: exit 1 (not finished)" [ "$RC" = 1 ]
check "U5: no CLI, --replace-old: prints the in-app steps" grep -q 'in /hooks' <<< "$OUT"
check "U5: no CLI, --replace-old: no file changes and no backup" [ "$before" = "$(snap "$SB")" ]

# --- 12. installed but disabled: enable first, then remove the old hooks -------------------------------
SB="$(new_sandbox disabled)"
write_seed "$SB"
run_kit "$SB" install.sh --apply --no-plugin
set_json "$SB/.claude/settings.json" '.enabledPlugins = {"workbench@workbench": false}'
known_at "$SB" "$(copy_of "$SB")"; installed_in "$SB"   # installed in the app
: > "$LOG"
run_kit "$SB" install.sh --apply --replace-old
check "disabled: exit 0" [ "$RC" = 0 ]
check "disabled: claude plugin enable, then plugin list to confirm" \
  [ "$(cat "$LOG")" = "$(printf 'plugin enable workbench@workbench --scope user\nplugin list --json')" ]
check "disabled: plugin enabled" jqt "$SB/.claude/settings.json" '.enabledPlugins["workbench@workbench"] == true'
check "disabled: old hooks removed after the enable" jqt "$SB/.claude/settings.json" "$OLD_HOOKS_GONE"

# --- 13. disabled and enable fails: the old hooks stay -----------------------------------------------
SB="$(new_sandbox disabled-stuck)"
write_seed "$SB"
run_kit "$SB" install.sh --apply --no-plugin
set_json "$SB/.claude/settings.json" '.enabledPlugins = {"workbench@workbench": false}'
known_at "$SB" "$(copy_of "$SB")"; installed_in "$SB"   # installed in the app
FAKE_CLAUDE_ENABLE_FAIL=1 run_kit "$SB" install.sh --apply --replace-old
check "enable fails: exit 1" [ "$RC" = 1 ]
check "enable fails: says the plugin is not enabled" grep -q 'is not enabled' <<< "$OUT"
check "enable fails: old hooks left in place" hooks_as_seeded "$SB/.claude/settings.json" "$ROOT/seed.json"

# --- 14. install exits 0 but nothing is enabled: the old hooks stay --------------------------------------
SB="$(new_sandbox install-noop)"
write_seed "$SB"
FAKE_CLAUDE_INSTALL_NOOP=1 run_kit "$SB" install.sh --apply --replace-old
check "install no-op: exit 1" [ "$RC" = 1 ]
check "install no-op: old hooks left in place" hooks_as_seeded "$SB/.claude/settings.json" "$ROOT/seed.json"

# --- 15. regression: two runs, then uninstall goes back to the pre-kit state ---------------------------
SB="$(new_sandbox two-runs)"
write_seed "$SB"
S="$SB/.claude/settings.json"
cp "$S" "$ROOT/seed-two-runs.json"   # the seed embeds the sandbox path, so each sandbox keeps its own copy
RUN_PATH="$SYS_PATH" run_kit "$SB" install.sh --apply --replace-old   # run 1: no CLI, so the plugin step waits
check "two runs: run 1 stops at the plugin step" [ "$RC" = 1 ]
cp "$S" "$ROOT/after-run1.json"
run_kit "$SB" install.sh --apply --replace-old                          # run 2: the plugin goes in, old hooks go
check "two runs: run 2 exits 0" [ "$RC" = 0 ]
check "two runs: run 2 removed the old hooks" jqt "$S" "$OLD_HOOKS_GONE"
check "two runs: run 2 made one timestamped backup" [ "$(stamped "$SB" | grep -c .)" = 1 ]
check "two runs: the original is untouched by run 2" cmp -s "$SB/.claude/backups/workbench-original/settings.json" "$ROOT/seed-two-runs.json"
run_kit "$SB" uninstall.sh --latest --yes
check "two runs: uninstall --latest restores the state before run 2" cmp -s "$S" "$ROOT/after-run1.json"
check "two runs: uninstall --latest keeps run 1's CLAUDE.md" [ -f "$SB/.claude/CLAUDE.md" ]
check "two runs: uninstall --latest keeps the original in place" [ -d "$SB/.claude/backups/workbench-original" ]
run_kit "$SB" uninstall.sh --yes
check "two runs: uninstall restores the pre-kit settings.json byte for byte" cmp -s "$S" "$ROOT/seed-two-runs.json"
check "two runs: uninstall removes the kit's CLAUDE.md" [ ! -e "$SB/.claude/CLAUDE.md" ]
check "two runs: uninstall removes the kit's Explore" [ ! -e "$SB/.claude/agents/Explore.md" ]
check "two runs: the restore archives this cycle's timestamped backups too" \
  [ -z "$(stamped "$SB")" -a "$(ls -1d "$SB"/.claude/backups/workbench-original.restored-*/workbench-[0-9]* 2>/dev/null | grep -c .)" = 1 ]

# --- 16. a user-level Explore of the user's own is never replaced or removed ---------------------------
SB="$(new_sandbox own-explore)"
mkdir -p "$SB/.claude/agents/research"
printf -- '---\nname: "Explore"\nmodel: haiku\n---\nMine.\n' > "$SB/.claude/agents/research/fast.md"
run_kit "$SB" install.sh --apply --no-plugin
check "own Explore (by name): no copy made" [ ! -e "$SB/.claude/agents/Explore.md" ]
check "own Explore (by name): plan says it is left as is" grep -q 'a user-level Explore agent exists, left as is' <<< "$OUT"
SB="$(new_sandbox own-explore-file)"
mkdir -p "$SB/.claude/agents"
echo "my explore" > "$SB/.claude/agents/Explore.md"
run_kit "$SB" install.sh --apply --no-plugin
check "own Explore.md: left as is" [ "$(cat "$SB/.claude/agents/Explore.md")" = "my explore" ]
check "own Explore.md: kept in the original backup" [ "$(cat "$SB/.claude/backups/workbench-original/agents/Explore.md")" = "my explore" ]
run_kit "$SB" uninstall.sh --yes
check "own Explore.md: uninstall keeps it" [ "$(cat "$SB/.claude/agents/Explore.md")" = "my explore" ]

# --- 17. the kit's Explore: updated while untouched, kept once the user edits it ----------------------
SB="$(new_sandbox kit-explore)"
run_kit "$SB" install.sh --apply --no-plugin
E="$SB/.claude/agents/Explore.md"
echo "older kit version" > "$E"; cp "$E" "$SB/.claude/backups/workbench-created/agents/Explore.md"
run_kit "$SB" install.sh --apply --no-plugin
check "kit Explore, untouched: a re-run updates it to the kit's version" cmp -s "$E" "$EXPLORE_SRC"
echo "edited by me" >> "$E"
run_kit "$SB" install.sh --apply --no-plugin
check "kit Explore, edited: a re-run keeps the edit" grep -q 'edited by me' "$E"
run_kit "$SB" uninstall.sh --yes
check "kit Explore, edited: uninstall leaves it in place" grep -q 'edited by me' "$E"
check "kit Explore, edited: uninstall says why" grep -q 'Left .*agents/Explore.md in place' <<< "$OUT"

# --- 18. preflight: jq, git and python3 must run before anything changes ------------------------------
for tool in jq git python3; do
  BROKEN="$ROOT/broken-$tool"
  mkdir -p "$BROKEN"
  printf '#!/bin/sh\necho "%s: stub, install the real one" >&2\nexit 1\n' "$tool" > "$BROKEN/$tool"
  chmod +x "$BROKEN/$tool"
  SB="$(new_sandbox "preflight-$tool")"
  write_seed "$SB"
  before="$(snap "$SB")"
  RUN_PATH="$BROKEN:$FAKEBIN:$SYS_PATH" run_kit "$SB" install.sh --apply
  check "preflight $tool: exit 1" [ "$RC" = 1 ]
  check "preflight $tool: names the tool" grep -qE "^  $tool +" <<< "$OUT"
  check "preflight $tool: says how to install it" grep -qE 'brew install|xcode-select --install' <<< "$OUT"
  check "preflight $tool: nothing written" [ "$before" = "$(snap "$SB")" ]
done

# --- 19. regression P1 and U1: a moved checkout, a marketplace elsewhere, a plugin that fails to load ---
PROOT="$(cd "$ROOT" && pwd -P)"   # install.sh names its folder by its physical path (/private/tmp on macOS)
KC="$PROOT/kitC"; KD="$PROOT/kitD"; KE="$PROOT/kitE"
cp -R "$KIT" "$KC" && rm -rf "$KC/.git"
# A round-3 style setup: the marketplace was added from the checkout kitC (old hooks still in settings.json),
# then the checkout moved to kitD.
SB="$(new_sandbox moved)"
write_seed "$SB"
S="$SB/.claude/settings.json"
C="$(copy_of "$SB")"
cp "$S" "$ROOT/seed-moved.json"
fake_cli "$SB" plugin marketplace add "$KC"
fake_cli "$SB" plugin install workbench@workbench
mv "$KC" "$KD"
RUN_KIT="$KD" run_kit "$SB" install.sh
check "moved kit: the dry run sees the marketplace pointing at the old folder" grep -q "marketplace workbench points at $KC" <<< "$OUT"
RUN_KIT="$KD" RUN_PATH="$SYS_PATH" run_kit "$SB" install.sh --apply --replace-old
check "moved kit, no CLI: exit 1" [ "$RC" = 1 ]
check "moved kit, no CLI: old hooks left in place" hooks_as_seeded "$S" "$ROOT/seed-moved.json"
check "moved kit, no CLI: prints the in-app marketplace step for the installed copy" grep -q "/plugin marketplace add $C" <<< "$OUT"
RUN_KIT="$KD" FAKE_CLAUDE_FAIL=1 run_kit "$SB" install.sh --apply --replace-old
check "moved kit, CLI fails: exit 1" [ "$RC" = 1 ]
check "moved kit, CLI fails: old hooks left in place" hooks_as_seeded "$S" "$ROOT/seed-moved.json"
: > "$LOG"
RUN_KIT="$KD" run_kit "$SB" install.sh --apply --replace-old
check "moved kit: exit 0 once the CLI works" [ "$RC" = 0 ]
check "U1: moved kit: the marketplace is re-added from the installed copy first" \
  [ "$(head -n 1 "$LOG")" = "plugin marketplace add $C" ]
check "U1: moved kit: known_marketplaces.json now points at the installed copy" \
  jqt "$SB/.claude/plugins/known_marketplaces.json" ".workbench.installLocation == \"$C\""
check "moved kit: old hooks removed only after that" jqt "$S" "$OLD_HOOKS_GONE"
RUN_KIT="$KD" run_kit "$SB" install.sh --apply
check "moved kit: the next run exits 0" [ "$RC" = 0 ]
check "moved kit: the next run has nothing to change" grep -q 'Nothing to change.' <<< "$OUT"
# U1: once the plugin runs from the copy, moving or deleting the checkout changes nothing.
mv "$KD" "$KE"
: > "$LOG"
fake_cli "$SB" plugin list --json
check "U1: checkout moved after install: the plugin still loads from the copy" \
  [ "$(env -i PATH="$FAKEBIN:$SYS_PATH" HOME="$SB" claude plugin list --json | jq -c '.[0].errors // []')" = '[]' ]
before="$(snap "$SB")"
RUN_KIT="$KE" run_kit "$SB" install.sh --apply
check "U1: a re-run from the moved checkout has nothing to change" [ "$RC" = 0 -a "$before" = "$(snap "$SB")" ]
printf '\n<!-- edited in the checkout -->\n' >> "$KE/plugins/workbench/agents/reviewer.md"
RUN_KIT="$KE" run_kit "$SB" install.sh
check "U1: after editing the checkout, the dry run plans a re-sync" grep -q "installed copy: re-sync $C" <<< "$OUT"
RUN_KIT="$KE" run_kit "$SB" install.sh --apply
check "U1: the re-run re-syncs the copy" [ "$RC" = 0 ] && check "U1: the copy matches the edited checkout" copy_matches "$KE" "$C"
check "U1: a re-sync counts as a file change (timestamped backup)" [ "$(stamped "$SB" | grep -c .)" -ge 1 ]
rm -rf "$KE"
check "U1: checkout deleted: the plugin still loads" \
  [ "$(env -i PATH="$FAKEBIN:$SYS_PATH" HOME="$SB" claude plugin list --json | jq -c '.[0].errors // []')" = '[]' ]
# Marketplace at the copy, but claude plugin list shows the plugin as failed to load.
SB="$(new_sandbox load-fail)"
write_seed "$SB"
run_kit "$SB" install.sh --apply --no-plugin
set_json "$SB/.claude/settings.json" '.enabledPlugins = {"workbench@workbench": true}'
known_at "$SB" "$(copy_of "$SB")"; installed_in "$SB"   # installed in the app
cp "$SB/.claude/settings.json" "$ROOT/load-fail.json"
FAKE_CLAUDE_LOAD_FAIL=1 run_kit "$SB" install.sh --apply --replace-old
check "fails to load: exit 1" [ "$RC" = 1 ]
check "fails to load: says so" grep -q 'failed to load' <<< "$OUT"
check "fails to load: old hooks left in place" hooks_as_seeded "$SB/.claude/settings.json" "$ROOT/load-fail.json"

# --- 20. regression P2: install, uninstall, user edits, install, uninstall keeps the edits ---------------
SB="$(new_sandbox cycle)"
S="$SB/.claude/settings.json"
B="$SB/.claude/backups"
echo '{"model": "opus"}' > "$S"
run_kit "$SB" install.sh --apply
check "cycle: first install exits 0" [ "$RC" = 0 ]
set_json "$S" '.enabledPlugins["workbench@workbench"] = false'      # a disabled plugin: run 2 re-enables it
run_kit "$SB" install.sh --apply
check "cycle: a second run in cycle 1 makes a timestamped backup" [ "$(stamped "$SB" | grep -c .)" = 1 ]
run_kit "$SB" uninstall.sh --yes
check "cycle: first uninstall restores the seed" [ "$(cat "$S")" = '{"model": "opus"}' ]
check "cycle: first uninstall archives cycle 1's backups" [ ! -e "$B/workbench-original" -a -z "$(stamped "$SB")" ]
set_json "$S" '.permissions.allow = ["Bash(make *)"] | .enabledPlugins = {"other@market": true}'
echo "my own rules" > "$SB/.claude/CLAUDE.md"
cp "$S" "$ROOT/cycle-edited.json"
run_kit "$SB" install.sh --apply
check "cycle: second install exits 0" [ "$RC" = 0 ]
check "cycle: second install takes a fresh original" cmp -s "$B/workbench-original/settings.json" "$ROOT/cycle-edited.json"
check "cycle: second install keeps the user's CLAUDE.md" [ "$(cat "$SB/.claude/CLAUDE.md")" = "my own rules" ]
check "U2: cycle: after an uninstall the next install merges the whole fragment again" \
  jqt "$S" '.permissions.ask | length == 14'
run_kit "$SB" uninstall.sh --yes
check "cycle: second uninstall keeps the user's rule and plugin" cmp -s "$S" "$ROOT/cycle-edited.json"
check "cycle: second uninstall keeps the user's own CLAUDE.md" [ "$(cat "$SB/.claude/CLAUDE.md")" = "my own rules" ]
check "cycle: the user's CLAUDE.md is restored from the fresh snapshot, not moved aside" \
  [ "$(grep -c 'CLAUDE.md will be OVERWRITTEN' <<< "$OUT")" = 0 -a "$(grep -c 'CLAUDE.md matches the backup copy' <<< "$OUT")" = 1 -a "$(grep -c 'Moved .*CLAUDE.md' <<< "$OUT")" = 0 ]
check "cycle: two archived originals" [ "$(ls -1d "$B"/workbench-original.restored-* | grep -c .)" = 2 ]
# A CLAUDE.md the kit wrote and the user then edited stays, with a note.
SB="$(new_sandbox claude-md-edited)"
run_kit "$SB" install.sh --apply --no-plugin
echo "- my extra rule" >> "$SB/.claude/CLAUDE.md"
run_kit "$SB" uninstall.sh --yes
check "edited CLAUDE.md: uninstall leaves it in place" grep -q 'my extra rule' "$SB/.claude/CLAUDE.md"
check "edited CLAUDE.md: uninstall says why" grep -q 'Left .*CLAUDE.md in place' <<< "$OUT"
check "U6: edited CLAUDE.md: the plan says it changed since install" \
  grep -q 'CLAUDE.md was written by install.sh and changed since install; it stays' <<< "$OUT"

# --- 21. regression P3: without --home, CLAUDE_CONFIG_DIR is the config root ------------------------------
SB="$(new_sandbox cfgdir)"
CFG="$SB/cfg"
mkdir -p "$CFG"
write_seed "$SB" "$CFG"
cp "$CFG/settings.json" "$ROOT/seed-cfg.json"
NO_HOME_FLAG=1 RUN_CFG="$CFG" run_kit "$SB" install.sh --apply --replace-old
check "CLAUDE_CONFIG_DIR: apply exits 0" [ "$RC" = 0 ]
check "CLAUDE_CONFIG_DIR: fragment merged into its settings.json" jqt "$CFG/settings.json" '.permissions.ask | length == 14'
check "CLAUDE_CONFIG_DIR: plugin enabled there, old hooks removed" \
  jqt "$CFG/settings.json" ".enabledPlugins[\"workbench@workbench\"] == true and ($OLD_HOOKS_GONE)"
check "CLAUDE_CONFIG_DIR: CLAUDE.md, workbench.json, agents/Explore.md and the backup are there" \
  [ -f "$CFG/CLAUDE.md" -a -f "$CFG/workbench.json" -a -f "$CFG/agents/Explore.md" -a -d "$CFG/backups/workbench-original" ]
check "CLAUDE_CONFIG_DIR: nothing written under ~/.claude" [ -z "$(ls -A "$SB/.claude")" ]
check "CLAUDE_CONFIG_DIR: the config ask rules name that folder" \
  jqt "$CFG/settings.json" '.permissions.ask | index(["Edit(~/cfg/workbench.json)"]) != null and index(["Edit(~/cfg/settings.json)"]) != null and (map(select(startswith("Edit(~/.claude"))) | length == 0)'
check "U1: CLAUDE_CONFIG_DIR: the copy is in that folder and its ask rule names it" \
  [ -d "$CFG/workbench-kit" ] && check "U1: CLAUDE_CONFIG_DIR: Edit(~/cfg/workbench-kit/**) asks" \
  jqt "$CFG/settings.json" '.permissions.ask | index(["Edit(~/cfg/workbench-kit/**)"]) != null'
check "U10: CLAUDE_CONFIG_DIR: CLAUDE.md names ~/cfg/workbench.json" grep -q 'listed in ~/cfg/workbench.json\.' "$CFG/CLAUDE.md"
check "U10: CLAUDE_CONFIG_DIR: the rendered audit prompt names ~/cfg" \
  [ "$(grep -c 'config folder, ~/cfg\.' "$CFG/workbench-kit/audit-task.md")" = 1 -a "$(grep -c '~/\.claude' "$CFG/workbench-kit/audit-task.md")" = 0 ]
NO_HOME_FLAG=1 RUN_CFG="$CFG" run_kit "$SB" uninstall.sh --yes
check "CLAUDE_CONFIG_DIR: uninstall restores that settings.json byte for byte" cmp -s "$CFG/settings.json" "$ROOT/seed-cfg.json"
SB="$(new_sandbox cfg-home)"
RUN_CFG="$ROOT/not-this-cfg" run_kit "$SB" install.sh --apply
check "--home beats CLAUDE_CONFIG_DIR, for the CLI calls too" \
  [ "$RC" = 0 -a ! -e "$ROOT/not-this-cfg" -a -f "$SB/.claude/plugins/known_marketplaces.json" ]

# --- 22. regression P5: no backup when no file change is planned ----------------------------------------
SB="$(new_sandbox no-cli-thrice)"
write_seed "$SB"
rcs=""
for i in 1 2 3; do RUN_PATH="$SYS_PATH" run_kit "$SB" install.sh --apply; rcs="$rcs$RC"; done
check "no CLI, three runs: each exits 1 (plugin step not finished)" [ "$rcs" = 111 ]
check "no CLI, three runs: one backup (the original), no timestamped ones" \
  [ -d "$SB/.claude/backups/workbench-original" -a -z "$(stamped "$SB")" ]
check "no CLI, re-run: says there are no file changes" grep -q 'No file changes' <<< "$OUT"

# --- 23. U2: three-way merge: what the user removed or moved stays that way ------------------------------
SB="$(new_sandbox three-way)"
write_seed "$SB"
S="$SB/.claude/settings.json"
run_kit "$SB" install.sh --apply --no-plugin
set_json "$S" '.permissions.allow -= ["Bash(npm run *)"] | .permissions.deny -= ["Bash(docker compose down*)"]
  | .permissions.allow += ["Bash(docker compose down*)"] | del(.env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD)
  | .permissions.ask -= ["Edit(~/.claude/CLAUDE.md)"]'
cp "$S" "$ROOT/three-way-edited.json"
run_kit "$SB" install.sh
check "U2: the dry run lists the removed entries as not re-added" \
  bash -c 'grep -q "removed by you, not re-added" <<< "$1" && grep -q "permissions.allow: Bash(npm run \*)" <<< "$1" && grep -q "permissions.deny: Bash(docker compose down\*)" <<< "$1" && grep -q "env.CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD" <<< "$1"' _ "$OUT"
run_kit "$SB" install.sh --apply --no-plugin
check "U2: re-run exits 0" [ "$RC" = 0 ]
check "U2: a deleted allow rule is not re-added" jqt "$S" '.permissions.allow | index(["Bash(npm run *)"]) | not'
check "U2: a deny rule moved to allow stays in allow and out of deny" \
  jqt "$S" '(.permissions.deny | index(["Bash(docker compose down*)"]) | not) and (.permissions.allow | index(["Bash(docker compose down*)"]) != null)'
check "U2: a deleted env key and ask rule stay out" \
  jqt "$S" '(.env | has("CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD") | not) and (.permissions.ask | index(["Edit(~/.claude/CLAUDE.md)"]) | not)'
check "U2: the re-run changes nothing else" cmp -s "$S" "$ROOT/three-way-edited.json"
# A kit entry that is new since the last run is still added.
KN="$PROOT/kit-newrule"; cp -R "$KIT" "$KN" && rm -rf "$KN/.git"
jq '.permissions.allow += ["Bash(make lint*)"]' "$KN/user/settings.fragment.json" > "$ROOT/f.json" && mv "$ROOT/f.json" "$KN/user/settings.fragment.json"
RUN_KIT="$KN" run_kit "$SB" install.sh --apply --no-plugin
check "U2: a rule new in the fragment is added on the next run" jqt "$S" '.permissions.allow | index(["Bash(make lint*)"]) != null'
check "U2: and the removed ones still stay out" jqt "$S" '.permissions.allow | index(["Bash(npm run *)"]) | not'
check "U2: the record follows the fragment that was applied" \
  same_json "$SB/.claude/backups/workbench-created/settings.fragment.applied.json" "$KN/user/settings.fragment.json"
# No record (an install from before round 4): a full merge.
rm -f "$SB/.claude/backups/workbench-created/settings.fragment.applied.json"
RUN_KIT="$KN" run_kit "$SB" install.sh --apply --no-plugin
check "U2: without a record, a re-run does a full merge" jqt "$S" '.permissions.allow | index(["Bash(npm run *)"]) != null'
rm -rf "$KN"

# --- 24. U3: --replace-old retires the old hooks and agents, and the default uninstall brings them back --
SB="$(new_sandbox replace-old)"
write_seed "$SB"
own_agents "$SB"
mkdir -p "$SB/.claude/hooks"
printf '#!/bin/bash\n# my own guard, not the kit'"'"'s\nexit 0\n' > "$SB/.claude/hooks/guard.sh"
S="$SB/.claude/settings.json"
cp "$S" "$ROOT/seed-replace.json"
cp "$SB/.claude/agents/reviewer.md" "$ROOT/reviewer-own.md"
run_kit "$SB" install.sh --apply
check "U3: without --replace-old: exit 0" [ "$RC" = 0 ]
check "U3: without --replace-old: the user's own guard.sh entry and the old hooks stay" hooks_as_seeded "$S" "$ROOT/seed-replace.json"
check "U3: without --replace-old: user reviewer.md and gate-runner.md stay" \
  [ -f "$SB/.claude/agents/reviewer.md" -a -f "$SB/.claude/agents/gate-runner.md" ]
check "U3: without --replace-old: the plan lists the agents as running alongside" \
  grep -qx "    $SB/.claude/agents/reviewer.md" <<< "$OUT"
run_kit "$SB" install.sh --apply --replace-old
check "U3: --replace-old: exit 0" [ "$RC" = 0 ]
check "U3: --replace-old: old hook entries removed once the plugin is confirmed" jqt "$S" "$OLD_HOOKS_GONE"
check "U3: --replace-old: reviewer.md and gate-runner.md moved out of agents/" \
  [ ! -e "$SB/.claude/agents/reviewer.md" -a ! -e "$SB/.claude/agents/gate-runner.md" ]
check "U3: --replace-old: they are in the run's backup" \
  [ -n "$(ls "$SB"/.claude/backups/workbench-[0-9]*/agents/reviewer.md 2>/dev/null)" ]
check "U3: --replace-old: recorded for uninstall" grep -q "^agents/reviewer.md$(printf '\t')workbench-[0-9]" "$SB/.claude/backups/workbench-created/retired-agents"
check "U3: --replace-old: the script files stay on disk" [ -f "$SB/.claude/hooks/guard.sh" ]
run_kit "$SB" uninstall.sh --dry-run
check "U3: the uninstall plan names the retired agents" grep -q "$SB/.claude/agents/reviewer.md will be restored from" <<< "$OUT"
run_kit "$SB" uninstall.sh --yes
check "U3: default uninstall restores the user agents byte for byte" \
  cmp -s "$SB/.claude/agents/reviewer.md" "$ROOT/reviewer-own.md" && check "U3: and gate-runner.md" [ -f "$SB/.claude/agents/gate-runner.md" ]
check "U3: default uninstall restores settings.json byte for byte" cmp -s "$S" "$ROOT/seed-replace.json"
check "U3: default uninstall leaves no install records" [ ! -e "$SB/.claude/backups/workbench-created" ]

# --- 25. U4: uninstall --keep-files: plugin out, files kept, old hook entries written back ---------------
SB="$(new_sandbox keep-files)"
write_seed "$SB"
own_agents "$SB"
S="$SB/.claude/settings.json"
cp "$S" "$ROOT/seed-keep.json"   # what workbench-original/settings.json holds (C3 archives that folder)
run_kit "$SB" install.sh --apply --replace-old
cp "$SB/.claude/CLAUDE.md" "$ROOT/keep-claude.md"
: > "$LOG"
run_kit "$SB" uninstall.sh --keep-files --yes
check "U4: --keep-files: exit 0" [ "$RC" = 0 ]
check "U4: --keep-files: the plugin is uninstalled" \
  [ "$(cat "$LOG")" = "$(printf 'plugin uninstall workbench@workbench\nplugin marketplace remove workbench')" ]
check "U4: --keep-files: CLAUDE.md, Explore.md and the kit rules stay" \
  [ -f "$SB/.claude/agents/Explore.md" ] && check "U4: --keep-files: CLAUDE.md unchanged" cmp -s "$SB/.claude/CLAUDE.md" "$ROOT/keep-claude.md"
check "U4: --keep-files: settings.json keeps the kit's rules" jqt "$S" '.permissions.ask | length == 14'
check "U4: --keep-files: the old hook entries are written back, as the original had them" \
  [ "$(jq -S '[.hooks[][].hooks[] | select(.command | test("\\.claude/hooks/"))]' "$S")" = \
    "$(jq -S '[.hooks[][].hooks[] | select(.command | test("\\.claude/hooks/"))]' "$ROOT/seed-keep.json")" ]
check "U4: --keep-files: the user's other hooks are kept" jqt "$S" '[.. | objects | .command? // empty] | index("$HOME/bin/notify.sh") != null'
check "U4: --keep-files: the retired agents come back" [ -f "$SB/.claude/agents/reviewer.md" -a -f "$SB/.claude/agents/gate-runner.md" ]
check "U4: --keep-files: the installed copy is moved away" [ ! -e "$(copy_of "$SB")" ]
KARCH="$(ls -1d "$SB"/.claude/backups/workbench-original.restored-* 2>/dev/null | head -n 1)"
check "C3: --keep-files archives workbench-original as workbench-original.restored-<stamp>" \
  [ -n "$KARCH" -a ! -e "$SB/.claude/backups/workbench-original" ]
check "C3: --keep-files: the archive holds the installed copy it moved away" \
  [ -n "$(ls -1d "$KARCH"/workbench-kit.before-uninstall-* 2>/dev/null)" ]
check "C3: --keep-files: the archived original still holds the pre-kit settings.json" cmp -s "$KARCH/settings.json" "$ROOT/seed-keep.json"
run_kit "$SB" uninstall.sh --latest --keep-files
check "U4: --latest with --keep-files is refused (exit 2)" [ "$RC" = 2 ]

# --- 26. U6: uninstall plan says when a file changed since install ---------------------------------------
SB="$(new_sandbox changed-since)"
run_kit "$SB" install.sh --apply --no-plugin          # no settings.json before
run_kit "$SB" uninstall.sh --dry-run
check "U6: unedited settings.json: unchanged since install" \
  grep -q 'settings.json was written by install.sh and is unchanged since; it will be moved' <<< "$OUT"
set_json "$SB/.claude/settings.json" '.theme = "light" | .permissions.allow += ["Bash(make *)"]'
run_kit "$SB" uninstall.sh --dry-run
check "U6: edited settings.json: says it changed since install" \
  grep -q 'settings.json was written by install.sh and changed since install; it will be moved into the backup folder (your edits are kept only in that copy)' <<< "$OUT"
check "U6: edited settings.json: never called unchanged" [ "$(grep -c 'settings.json.*unchanged' <<< "$OUT")" = 0 ]
SB="$(new_sandbox changed-since-existing)"
echo '{"model": "opus"}' > "$SB/.claude/settings.json"
run_kit "$SB" install.sh --apply --no-plugin
run_kit "$SB" uninstall.sh --dry-run
check "U6: existing settings.json as install left it: says so" grep -q 'settings.json will be OVERWRITTEN with the backup copy (it is as install.sh left it)' <<< "$OUT"
set_json "$SB/.claude/settings.json" '.theme = "light"'
run_kit "$SB" uninstall.sh --dry-run
check "U6: existing settings.json edited since: says it changed since install" \
  grep -q 'settings.json will be OVERWRITTEN with the backup copy; it changed since install' <<< "$OUT"

# --- 27. U7: after an Explore update, --latest and then a full uninstall remove the kit's Explore ---------
SB="$(new_sandbox explore-latest)"
KX="$PROOT/kit-explore-v2"; cp -R "$KIT" "$KX" && rm -rf "$KX/.git"
run_kit "$SB" install.sh --apply --no-plugin
cp "$SB/.claude/agents/Explore.md" "$ROOT/explore-v1.md"
printf '\nKit v2: also report line counts.\n' >> "$KX/user/agents/Explore.md"
RUN_KIT="$KX" run_kit "$SB" install.sh --apply --no-plugin
check "U7: the re-run updates Explore to v2" cmp -s "$SB/.claude/agents/Explore.md" "$KX/user/agents/Explore.md"
run_kit "$SB" uninstall.sh --latest --yes
check "U7: --latest restores v1" cmp -s "$SB/.claude/agents/Explore.md" "$ROOT/explore-v1.md"
check "U7: --latest puts the v1 record back" cmp -s "$SB/.claude/backups/workbench-created/agents/Explore.md" "$ROOT/explore-v1.md"
run_kit "$SB" uninstall.sh --yes
check "U7: the full uninstall still recognizes the installer's Explore and removes it" [ ! -e "$SB/.claude/agents/Explore.md" ]
rm -rf "$KX"

# --- 28. U8: a plugin that fails to load is not a file change ---------------------------------------------
SB="$(new_sandbox hook-load-fail)"
KB="$PROOT/kit-broken-hooks"; cp -R "$KIT" "$KB" && rm -rf "$KB/.git"
write_seed "$SB"
RUN_KIT="$KB" run_kit "$SB" install.sh --apply
printf '{"hooks": {"PreToolUse": [ broken\n' > "$KB/plugins/workbench/hooks/hooks.json"   # a bad pull
RUN_KIT="$KB" run_kit "$SB" install.sh --apply --replace-old           # re-syncs the broken file: a change
check "U8: a broken hooks.json in the copy: exit 1" [ "$RC" = 1 ]
check "U8: names the file to fix in the checkout" grep -q "fix $KB/plugins/workbench/hooks/hooks.json" <<< "$OUT"
n1="$(stamped "$SB" | grep -c .)"
: > "$LOG"
rcs=""
for i in 1 2 3; do RUN_KIT="$KB" run_kit "$SB" install.sh --apply --replace-old; rcs="$rcs$RC"; done
check "U8: three more runs while it fails to load: each exits 1" [ "$rcs" = 111 ]
check "U8: three more runs: no new timestamped backup" [ "$(stamped "$SB" | grep -c .)" = "$n1" ]
check "U8: three more runs: no marketplace add or install" [ "$(grep -c -E 'marketplace add|plugin install' "$LOG")" = 0 ]
check "U8: three more runs: the old hooks stay" jqt "$SB/.claude/settings.json" '[.. | objects | .command? // empty | select(test("\\.claude/hooks/"))] | length == 3'
cp "$KIT/plugins/workbench/hooks/hooks.json" "$KB/plugins/workbench/hooks/hooks.json"     # fixed in the checkout
RUN_KIT="$KB" run_kit "$SB" install.sh --apply --replace-old
check "U8: once fixed in the checkout, the re-run re-syncs, confirms and retires" [ "$RC" = 0 ] && \
  check "U8: and the old hooks go" jqt "$SB/.claude/settings.json" "$OLD_HOOKS_GONE"
rm -rf "$KB"

# --- 29. U9: old hook entries written for the CLAUDE_CONFIG_DIR folder are recognized ---------------------
SB="$(new_sandbox cfg-hooks)"
CFG="$SB/cfg"
mkdir -p "$CFG"
cat > "$CFG/settings.json" <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
  {"type": "command", "command": "~/cfg/hooks/guard.sh"},
  {"type": "command", "command": "\"$CLAUDE_CONFIG_DIR/hooks/commit_gate.sh\""},
  {"type": "command", "command": "${CLAUDE_CONFIG_DIR}/hooks/browser_cap.sh"},
  {"type": "command", "command": "\"$HOME/cfg/hooks/format_py.sh\""},
  {"type": "command", "command": "~/cfg/hooks/guard.sh.bak"}]}]}}
EOF
NO_HOME_FLAG=1 RUN_CFG="$CFG" run_kit "$SB" install.sh --apply --replace-old
check "U9: CLAUDE_CONFIG_DIR forms (~/cfg, \$CLAUDE_CONFIG_DIR, \${CLAUDE_CONFIG_DIR}, \$HOME/cfg) are removed" \
  jqt "$CFG/settings.json" '[.hooks.PreToolUse[].hooks[].command] == ["~/cfg/hooks/guard.sh.bak"]'

# --- 30. U11: WORKBENCH_CONFIG decides where workbench.json lives --------------------------------------
SB="$(new_sandbox wb-config)"
mkdir -p "$SB/dot"
echo '{"author": "Dot Author"}' > "$SB/dot/wb.json"
NO_HOME_FLAG=1 RUN_WB="$SB/dot/wb.json" run_kit "$SB" install.sh --no-plugin
check "U11: the dry run reads the author from WORKBENCH_CONFIG" grep -q "author: \"Dot Author\" (from $SB/dot/wb.json)" <<< "$OUT"
NO_HOME_FLAG=1 RUN_WB="$SB/dot/wb.json" run_kit "$SB" install.sh --apply --no-plugin --author "Other Name"
check "U11: apply exits 0" [ "$RC" = 0 ]
check "U11: no second workbench.json in the config folder" [ ! -e "$SB/.claude/workbench.json" ]
check "U11: CLAUDE.md names the WORKBENCH_CONFIG author and file" \
  grep -q "^# Dot Author's rules" "$SB/.claude/CLAUDE.md" && check "U11: CLAUDE.md points at ~/dot/wb.json" grep -q 'listed in ~/dot/wb.json\.' "$SB/.claude/CLAUDE.md"
check "U11: the ask rule covers that file" jqt "$SB/.claude/settings.json" '.permissions.ask | index(["Edit(~/dot/wb.json)"]) != null and (index(["Edit(~/.claude/workbench.json)"]) | not)'
SB="$(new_sandbox wb-config-new)"
NO_HOME_FLAG=1 RUN_WB="$SB/elsewhere/wb.json" run_kit "$SB" install.sh --apply --no-plugin
check "U11: a missing WORKBENCH_CONFIG file is created there" jqt "$SB/elsewhere/wb.json" '.author == "Sam Sandbox"'

# --- 31. U14: CLAUDE.md the kit rendered is kept in step, and called the kit's version -------------------
SB="$(new_sandbox claude-md-update)"
KT="$PROOT/kit-template-v2"; cp -R "$KIT" "$KT" && rm -rf "$KT/.git"
run_kit "$SB" install.sh --apply --no-plugin
printf -- '- Kit v2 rule.\n' >> "$KT/user/CLAUDE.md.template"
RUN_KIT="$KT" run_kit "$SB" install.sh
check "U14: an unchanged kit CLAUDE.md is planned for update when the template changes" \
  grep -q "CLAUDE.md: update to the kit's current template" <<< "$OUT"
RUN_KIT="$KT" run_kit "$SB" install.sh --apply --no-plugin
check "U14: the update is applied" grep -q 'Kit v2 rule' "$SB/.claude/CLAUDE.md"
RUN_KIT="$KT" run_kit "$SB" install.sh --apply --no-plugin
check "U14: the next run calls it the kit's version" grep -q "CLAUDE.md: the kit's version, no change" <<< "$OUT"
rm -rf "$KT"

# --- 32. C1: a checkout at, inside or around <cfg>/workbench-kit is refused, and nothing changes ------------
SB="$(new_sandbox kit-in-cfg)"
KG="$SB/.claude/workbench-kit"
cp -R "$KIT" "$KG" && rm -rf "$KG/.git"
G() { env -i PATH="$SYS_PATH" HOME="$SB" git -C "$KG" -c user.name=t -c user.email=t@x.invalid -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
G init -q && G add -A && G commit -qm kit      # the kit cloned straight into the config folder
echo 'my uncommitted notes' > "$KG/NOTES.md"
before="$(snap "$SB")"
: > "$LOG"
RUN_KIT="$KG" run_kit "$SB" install.sh --apply --author "Sam Sandbox"
check "C1: a git checkout at <cfg>/workbench-kit: --apply exits 2" [ "$RC" = 2 ]
check "C1: says the checkout is the installed copy's path" grep -q "is $SB/.claude/workbench-kit, the installed copy's path" <<< "$OUT"
check "C1: its files (.git and uncommitted notes included) are byte-identical, and nothing else changed" [ "$before" = "$(snap "$SB")" ]
RUN_KIT="$KG" run_kit "$SB" install.sh
check "C1: the dry run is refused too (exit 2), nothing changed" [ "$RC" = 2 -a "$before" = "$(snap "$SB")" ]
RUN_KIT="$KG" run_kit "$SB" uninstall.sh --yes
check "C1: uninstall.sh run from that checkout is refused (exit 2), nothing changed" [ "$RC" = 2 -a "$before" = "$(snap "$SB")" ]
check "C1: no claude CLI call" [ "$(calls)" = 0 ]
SB="$(new_sandbox kit-inside-copy)"
KI="$SB/.claude/workbench-kit/src/kit"; mkdir -p "$(dirname "$KI")"; cp -R "$KIT" "$KI" && rm -rf "$KI/.git"
before="$(snap "$SB")"
RUN_KIT="$KI" run_kit "$SB" install.sh --apply
check "C1: a checkout inside <cfg>/workbench-kit: exit 2, nothing changed" [ "$RC" = 2 -a "$before" = "$(snap "$SB")" ] \
  && check "C1: says it is inside" grep -q "is inside $SB/.claude/workbench-kit" <<< "$OUT"
KH="$PROOT/kit-as-home"; cp -R "$KIT" "$KH" && rm -rf "$KH/.git"; mkdir -p "$KH/.claude"
before="$(snap "$KH")"
RUN_KIT="$KH" run_kit "$KH" install.sh --apply --author "Sam Sandbox"
check "C1: a checkout that contains the config folder: exit 2, nothing changed" [ "$RC" = 2 -a "$before" = "$(snap "$KH")" ] \
  && check "C1: says it contains the copy's path" grep -q "contains $KH/.claude/workbench-kit" <<< "$OUT"
SB="$(new_sandbox kit-symlinked)"
KL="$PROOT/kit-linked"; cp -R "$KIT" "$KL" && rm -rf "$KL/.git"
ln -s "$KL" "$SB/.claude/workbench-kit"
before="$(snap "$SB")$(snap "$KL")"
RUN_KIT="$KL" run_kit "$SB" install.sh --apply
check "C1: <cfg>/workbench-kit as a symlink to the checkout: exit 2, nothing changed" \
  [ "$RC" = 2 -a "$before" = "$(snap "$SB")$(snap "$KL")" ]
rm -rf "$KH" "$KL"

# --- 33. C1, C2: a re-sync keeps the old copy in the run's backup; --latest puts it back, plugin installed ----
SB="$(new_sandbox latest-copy)"
KU="$PROOT/kit-update"; cp -R "$KIT" "$KU" && rm -rf "$KU/.git"
S="$SB/.claude/settings.json"; C="$(copy_of "$SB")"
write_seed "$SB"
cp "$S" "$ROOT/seed-latest.json"
RUN_KIT="$KU" run_kit "$SB" install.sh --apply
check "C2: install exits 0 and the plugin loads" [ "$RC" = 0 ] && check "C2: plugin list shows it loaded" plugin_ok "$SB"
copy_v1="$(snap "$C")"
printf '\n# kit v2\n' >> "$KU/plugins/workbench/scripts/guard.sh"      # a kit update
RUN_KIT="$KU" run_kit "$SB" install.sh --apply
check "C2: the update run exits 0 and re-syncs the copy" [ "$RC" = 0 ] && check "C2: the copy has v2" grep -q '# kit v2' "$C/plugins/workbench/scripts/guard.sh"
BK="$(stamped "$SB" | tail -n 1)"
check "C1: the replaced copy moved into that run's backup, unchanged" [ -n "$BK" ] && check "C1: byte for byte" [ "$(snap "$BK/workbench-kit")" = "$copy_v1" ]
check "C1: no temp or old copy is left next to the copy" [ -z "$(ls -A "$SB/.claude" | grep '^\.workbench-kit')" ]
check "C1: the update run says where the previous copy is" grep -q "the previous copy is in $BK/workbench-kit" <<< "$OUT"
: > "$LOG"
run_kit "$SB" uninstall.sh --latest --dry-run
check "C2: the --latest plan keeps the plugin installed" grep -q 'workbench@workbench and its marketplace stay installed' <<< "$OUT"
check "C2: the --latest plan puts the copy back" grep -q "installed copy: put back from $BK/workbench-kit" <<< "$OUT"
run_kit "$SB" uninstall.sh --latest --yes
check "C2: --latest exits 0" [ "$RC" = 0 ]
check "C2: --latest runs no plugin uninstall or marketplace remove" [ "$(grep -c -E 'plugin uninstall|marketplace remove' "$LOG")" = 0 ]
check "C2: --latest puts the copy from before the update back at <cfg>/workbench-kit" [ "$(snap "$C")" = "$copy_v1" ]
check "C2: after --latest the plugin is installed, enabled and loads from it" plugin_ok "$SB"
check "C2: after --latest the marketplace still reads from the copy" \
  jqt "$SB/.claude/plugins/known_marketplaces.json" ".workbench.installLocation == \"$C\""
check "C2: after --latest settings.json enables the plugin and names its marketplace" \
  jqt "$S" '.enabledPlugins["workbench@workbench"] == true and .extraKnownMarketplaces.workbench != null'
check "C2: the v2 copy it replaced is kept in the backup" \
  grep -q '# kit v2' "$(ls -1d "$BK"/workbench-kit.before-uninstall-* | head -n 1)/plugins/workbench/scripts/guard.sh"
check "C2: the backup's copy stays there for a repeat --latest" [ "$(snap "$BK/workbench-kit")" = "$copy_v1" ]
check "C2: no temp copy is left behind" [ -z "$(ls -A "$SB/.claude" | grep '^\.workbench-kit')" ]
run_kit "$SB" uninstall.sh --yes
check "C2: a full uninstall afterwards removes the plugin" \
  [ "$(env -i PATH="$FAKEBIN:$SYS_PATH" HOME="$SB" claude plugin list --json | jq length)" = 0 ]
check "C2: and restores the pre-kit settings.json byte for byte" cmp -s "$S" "$ROOT/seed-latest.json"
rm -rf "$KU"
# Control: when the plugin was not installed before the last run, --latest removes it and settings.json then names
# no workbench plugin or marketplace.
SB="$(new_sandbox latest-no-plugin)"
S="$SB/.claude/settings.json"
echo '{"model": "opus"}' > "$S"
run_kit "$SB" install.sh --apply --no-plugin
run_kit "$SB" install.sh --apply
run_kit "$SB" uninstall.sh --latest --yes
check "C2: --latest after the run that installed the plugin removes it, and no workbench entry is left" \
  [ "$(env -i PATH="$FAKEBIN:$SYS_PATH" HOME="$SB" claude plugin list --json | jq length)" = 0 ] \
  && check "C2: settings.json names no workbench plugin or marketplace" \
  jqt "$S" '(.enabledPlugins // {} | has("workbench@workbench") | not) and (.extraKnownMarketplaces // {} | has("workbench") | not)'
check "C2: that run did not touch the copy, so it stays" [ -d "$(copy_of "$SB")" ]

# --- 34. C3: --keep-files, your edits, a reinstall, then uninstall: the edits survive -------------------------
SB="$(new_sandbox keep-edit-cycle)"
S="$SB/.claude/settings.json"
B="$SB/.claude/backups"
echo '{"theme": "dark"}' > "$S"
run_kit "$SB" install.sh --apply
run_kit "$SB" install.sh --apply --replace-old       # nothing to change; no backup
set_json "$S" '.enabledPlugins["workbench@workbench"] = false'
run_kit "$SB" install.sh --apply                     # re-enables: a timestamped backup
run_kit "$SB" uninstall.sh --keep-files --yes
check "C3: --keep-files exits 0 and archives the original with this cycle's timestamped backup" \
  [ "$RC" = 0 -a ! -e "$B/workbench-original" -a -z "$(stamped "$SB")" ] \
  && check "C3: the archive holds the timestamped backup" [ -n "$(ls -1d "$B"/workbench-original.restored-*/workbench-[0-9]* 2>/dev/null)" ]
set_json "$S" '.permissions.allow += ["Bash(make *)"] | .model = "opus"'   # your edits while the kit is off
cp "$S" "$ROOT/keep-edited.json"
run_kit "$SB" install.sh --apply                     # a later reinstall
check "C3: the reinstall exits 0 and takes a fresh original with the edits" \
  [ "$RC" = 0 ] && check "C3: fresh original = the edited file" cmp -s "$B/workbench-original/settings.json" "$ROOT/keep-edited.json"
run_kit "$SB" uninstall.sh --dry-run
check "C3: the plan restores that fresh original" grep -q "backup: $B/workbench-original (the state before the first install)" <<< "$OUT"
check "C3: the plan lists no plugin entry as a change of yours" [ "$(grep -c -E 'enabledPlugins|extraKnownMarketplaces' <<< "$OUT")" = 0 ]
run_kit "$SB" uninstall.sh --yes
check "C3: the edits made after --keep-files survive the uninstall" \
  jqt "$S" '.theme == "dark" and .model == "opus" and (.permissions.allow | index(["Bash(make *)"]) != null)'
check "C3: settings.json is the edited file byte for byte" cmp -s "$S" "$ROOT/keep-edited.json"

# --- 35. C3: the uninstall plan lists settings.json changes that are not kit or plugin entries ---------------
SB="$(new_sandbox nonkit-plan)"
S="$SB/.claude/settings.json"
echo '{"theme": "dark", "permissions": {"deny": ["Bash(rm -rf /*)"]}}' > "$S"
run_kit "$SB" install.sh --apply
set_json "$S" '.permissions.allow += ["Bash(make *)"] | .model = "opus" | .theme = "light" | .permissions.deny -= ["Bash(rm -rf /*)"]'
KF="$PROOT/kit-frag-v2"; cp -R "$KIT" "$KF" && rm -rf "$KF/.git"
jq '.permissions.allow += ["Bash(make lint*)"]' "$KF/user/settings.fragment.json" > "$ROOT/f.json" && mv "$ROOT/f.json" "$KF/user/settings.fragment.json"
RUN_KIT="$KF" run_kit "$SB" install.sh --apply       # a kit update: settings.json is rewritten and re-recorded
check "C3: the kit-update run adds its new rule" jqt "$S" '.permissions.allow | index(["Bash(make lint*)"]) != null'
RUN_KIT="$KF" run_kit "$SB" uninstall.sh --dry-run
check "C3: the plan says settings.json changed since install" \
  grep -q 'settings.json will be OVERWRITTEN with the backup copy; it changed since install' <<< "$OUT"
check "C3: the plan never calls it as install.sh left it" [ "$(grep -c 'as install.sh left it' <<< "$OUT")" = 0 ]
check "C3: the plan lists an added rule of yours" grep -q 'permissions.allow: + Bash(make \*)' <<< "$OUT"
check "C3: the plan lists an added key of yours" grep -q 'model: "opus" (not in the backup)' <<< "$OUT"
check "C3: the plan lists a changed value of yours" grep -q 'theme: "light" (was "dark")' <<< "$OUT"
check "C3: the plan lists a rule of yours that you removed" grep -q 'permissions.deny: - Bash(rm -rf /\*)' <<< "$OUT"
check "C3: the plan lists no kit rule (old or new) and no plugin entry" \
  [ "$(grep -c -E 'make lint|npm run|enabledPlugins|extraKnownMarketplaces|workbench-kit' <<< "$(sed -n '/changes since the backup/,$p' <<< "$OUT")")" = 0 ]
rm -rf "$KF"

# --- 36. C4: settings.json enables workbench@workbench but nothing is installed: one --apply finishes ----------
SB="$(new_sandbox enabled-not-installed)"
S="$SB/.claude/settings.json"
C="$(copy_of "$SB")"
echo '{"enabledPlugins": {"workbench@workbench": true}}' > "$S"   # synced from another machine
run_kit "$SB" install.sh
check "C4: the dry run plans the marketplace add and the install" \
  grep -q "plugin: claude plugin marketplace add \"$C\", then claude plugin install workbench@workbench" <<< "$OUT"
: > "$LOG"
run_kit "$SB" install.sh --apply
check "C4: one --apply exits 0" [ "$RC" = 0 ]
check "C4: it adds the marketplace, installs, then confirms" \
  [ "$(setup_log)" = "$(printf 'plugin marketplace add %s\nplugin install workbench@workbench\nplugin list --json' "$C")" ]
check "C4: the plugin loads after that one run" plugin_ok "$SB"
run_kit "$SB" install.sh --apply
check "C4: the next run has nothing to change" [ "$RC" = 0 ] && check "C4: says so" grep -q 'Nothing to change.' <<< "$OUT"

# --- 37. C5: the new copy is validated before the swap; on failure nothing changes ----------------------------
SB="$(new_sandbox validate)"
KV="$PROOT/kit-validate"; cp -R "$KIT" "$KV" && rm -rf "$KV/.git"
write_seed "$SB"
C="$(copy_of "$SB")"
RUN_KIT="$KV" run_kit "$SB" install.sh --apply
cp "$KV/plugins/workbench/hooks/hooks.json" "$ROOT/hooks-good.json"
printf '{"hooks": {"PreToolUse": [ \n' > "$KV/plugins/workbench/hooks/hooks.json"   # a bad pull or a typo
before="$(snap "$SB")"
: > "$LOG"
RUN_KIT="$KV" run_kit "$SB" install.sh
check "C5: the dry run names the file to fix and exits 1" \
  [ "$RC" = 1 ] && check "C5: (dry run) file named" grep -q "fix $KV/plugins/workbench/hooks/hooks.json" <<< "$OUT"
RUN_KIT="$KV" run_kit "$SB" install.sh --apply --replace-old
check "C5: a hooks.json that does not parse: --apply exits 1" [ "$RC" = 1 ]
check "C5: names the file to fix in the checkout" grep -q "fix $KV/plugins/workbench/hooks/hooks.json" <<< "$OUT"
check "C5: says the installed copy stays as it is" grep -q "the installed copy $C stays as it is" <<< "$OUT"
check "C5: nothing changed (copy, settings.json, backups, old hooks)" [ "$before" = "$(snap "$SB")" ]
check "C5: the plugin still loads from the old copy" plugin_ok "$SB"
check "C5: no marketplace add, install or enable" [ "$(grep -c -E 'marketplace add|plugin install|plugin enable' "$LOG")" = 0 ]
echo '{"hooks": []}' > "$KV/plugins/workbench/hooks/hooks.json"   # parses; since X-C1 the wiring check rejects it first
RUN_KIT="$KV" run_kit "$SB" install.sh --apply
check "C5: a hooks.json whose hooks is an array: exit 1, nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ]
check "C5: names that file (X-C1: the wiring check)" \
  grep -qF "fix $KV/plugins/workbench/hooks/hooks.json: \"hooks\" is not an object of hook events" <<< "$OUT"
# Wired as required, but one entry has a hook type the CLI does not know: only claude plugin validate rejects it.
jq '.hooks.PreToolUse[0].hooks += [{"type": "bogus", "command": "true"}]' "$ROOT/hooks-good.json" \
  > "$KV/plugins/workbench/hooks/hooks.json"
RUN_KIT="$KV" run_kit "$SB" install.sh --apply
check "C5: a hooks.json only claude plugin validate rejects: exit 1, nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ]
check "C5: names that file and the validator's error" \
  grep -qF "fix $KV/plugins/workbench/hooks/hooks.json: hooks: hooks.PreToolUse.0.hooks.2: Unknown hook type" <<< "$OUT"
cp "$ROOT/hooks-good.json" "$KV/plugins/workbench/hooks/hooks.json"
printf '{"name": ' > "$KV/.claude-plugin/marketplace.json"
RUN_PATH="$SYS_PATH" RUN_KIT="$KV" run_kit "$SB" install.sh --apply
check "C5: no CLI: a marketplace.json that does not parse stops the run, nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ]
check "C5: no CLI: names that file" grep -q "fix $KV/.claude-plugin/marketplace.json" <<< "$OUT"
cp "$KIT/.claude-plugin/marketplace.json" "$KV/.claude-plugin/marketplace.json"
printf '\n# a good edit\n' >> "$KV/plugins/workbench/scripts/guard.sh"
RUN_KIT="$KV" run_kit "$SB" install.sh --apply
check "C5: once fixed, the re-run validates, re-syncs and exits 0" [ "$RC" = 0 ] && check "C5: the copy matches the fixed checkout" copy_matches "$KV" "$C"
rm -rf "$KV"

# --- 38. W-C1: the new copy is run-checked before the swap; a miss changes nothing ------------------------------
# edit_in FILE SED_SCRIPT: edit FILE in place, keeping its mode (BSD and GNU sed differ on -i).
edit_in() { sed "$2" "$1" > "$ROOT/edit.tmp" && cat "$ROOT/edit.tmp" > "$1"; }
SB="$(new_sandbox smoke)"
KS="$PROOT/kit-smoke"; cp -R "$KIT" "$KS" && rm -rf "$KS/.git"
write_seed "$SB"
C="$(copy_of "$SB")"
GS="$KS/plugins/workbench/scripts/guard.sh"
RUN_KIT="$KS" run_kit "$SB" install.sh --apply
check "W-C1: the first install exits 0" [ "$RC" = 0 ]
before="$(snap "$SB")"
for f in plugins/workbench/scripts/guard.sh plugins/workbench/scripts/format_py.sh plugins/workbench/scripts/cmdparse.py \
  plugins/workbench/hooks/hooks.json; do
  cp "$KS/$f" "$ROOT/good.$(basename "$f")"
done
restore_good() {
  for f in plugins/workbench/scripts/guard.sh plugins/workbench/scripts/format_py.sh plugins/workbench/scripts/cmdparse.py \
    plugins/workbench/hooks/hooks.json; do
    cat "$ROOT/good.$(basename "$f")" > "$KS/$f"
  done
}
# smoke_case NAME EXPECTED_LINE: --apply on the edited checkout exits 1, prints EXPECTED_LINE, changes nothing.
smoke_case() {
  : > "$LOG"
  RUN_KIT="$KS" run_kit "$SB" install.sh --apply --replace-old
  check "W-C1: $1: --apply exits 1" [ "$RC" = 1 ]
  check "W-C1: $1: names the file and the miss" grep -qF "$2" <<< "$OUT"
  check "W-C1: $1: says the installed copy stays as it is" grep -q "the installed copy $C stays as it is" <<< "$OUT"
  check "W-C1: $1: nothing changed (the copy byte-identical, settings.json, backups)" [ "$before" = "$(snap "$SB")" ]
  check "W-C1: $1: no marketplace add, install or enable" [ "$(grep -c -E 'marketplace add|plugin install|plugin enable' "$LOG")" = 0 ]
  restore_good
}
# installer-1 variant A: one ')' lost in guard.sh's first jq filter. bash -n and claude plugin validate pass, and
# the guard then gives no decision for anything.
edit_in "$GS" 's#| select(\$c | test(\$kw))#| select($c | test($kw)#'
check "W-C1: (setup) the jq typo applies to guard.sh" [ "$(cat "$GS")" != "$(cat "$ROOT/good.guard.sh")" ]
RUN_KIT="$KS" run_kit "$SB" install.sh
check "W-C1: guard typo: the dry run exits 1 and names guard.sh" \
  [ "$RC" = 1 ] && check "W-C1: guard typo: (dry run) names guard.sh" grep -qF "fix $KS/plugins/workbench/scripts/guard.sh:" <<< "$OUT"
smoke_case "guard typo" "fix $KS/plugins/workbench/scripts/guard.sh: with an empty config folder it gives no decision for git stash, not deny"
edit_in "$GS" 's#| select(\$c | test(\$kw))#| select($c | test($kw)#'
RUN_PATH="$SYS_PATH" RUN_KIT="$KS" run_kit "$SB" install.sh --apply
check "W-C1: no CLI: the guard typo still stops the run (exit 1), nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ] \
  && check "W-C1: no CLI: names guard.sh" grep -qF "fix $KS/plugins/workbench/scripts/guard.sh:" <<< "$OUT"
restore_good
# installer-1 variant B: hooks.json names a script that is not there.
edit_in "$KS/plugins/workbench/hooks/hooks.json" 's#scripts/guard.sh#scripts/guard2.sh#'
smoke_case "hooks.json names a missing script" \
  "fix $KS/plugins/workbench/hooks/hooks.json: it runs \${CLAUDE_PLUGIN_ROOT}/scripts/guard2.sh, which is not in the plugin"
printf '#!/bin/bash\ncat >/dev/null\necho %s\n' \
  "'{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"stub\"}}'" > "$GS"
smoke_case "a guard that denies git push" \
  "fix $KS/plugins/workbench/scripts/guard.sh: with an empty config folder it answers deny for git push, not ask"
cat > "$GS" <<'EOF'
#!/bin/bash
c=$(jq -r .tool_input.command)
case "$c" in
  "git stash"*) d=deny ;;
  "git push"*) d=ask ;;
  *) exit 0 ;;
esac
jq -n --arg d "$d" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: "stub"}}'
EOF
smoke_case "a guard blind to the trailer" \
  "fix $KS/plugins/workbench/scripts/guard.sh: with an empty config folder it gives no decision for a commit whose message carries the Claude trailer, not deny"
printf 'if then\n' >> "$KS/plugins/workbench/scripts/format_py.sh"
smoke_case "a shell syntax error" "fix $KS/plugins/workbench/scripts/format_py.sh: bash -n: line"
printf 'def broken(:\n' >> "$KS/plugins/workbench/scripts/cmdparse.py"
smoke_case "a Python syntax error" "fix $KS/plugins/workbench/scripts/cmdparse.py: it does not parse as Python"
check "W-C1: the checks write no bytecode in the checkout or the sandbox" [ -z "$(find "$KS" "$SB" -name __pycache__ -o -name '*.pyc')" ]
GREQ="$(jq -cn '{tool_name: "Bash", tool_input: {command: "git stash"}, cwd: "/tmp"}')"
check "W-C1: after the refused runs the copy's guard still denies git stash" \
  bash -c 'printf "%s" "$1" | env -i HOME="$2" PATH="$3" bash "$4" | grep -q "\"deny\""' \
  _ "$GREQ" "$ROOT" "$SYS_PATH" "$C/plugins/workbench/scripts/guard.sh"
printf '\n# a good edit\n' >> "$GS"
RUN_KIT="$KS" run_kit "$SB" install.sh --apply
check "W-C1: a good edit passes the checks, re-syncs and exits 0" [ "$RC" = 0 ] && check "W-C1: the copy matches it" copy_matches "$KS" "$C"
check "W-C1: the comment above copy_checks says what is checked" \
  bash -c 'c="$(sed -n "/^# A new copy must pass these checks/,/^copy_checks()/p" "$1" | tr -d "#" | tr "\n" " " | tr -s " ")"
    for w in "plugins[].source is a folder inside the copy" "every \${CLAUDE_PLUGIN_ROOT}/... path that hooks/hooks.json names exists" \
      "bash -n passes on every scripts/*.sh" "(cmdparse.py) parses as Python (ast.parse, nothing compiled or written)" \
      "HOME set to an empty temp folder" "deny for git stash, ask for git push, and deny for a commit whose message carries the Claude trailer"; do
      case "$c" in *"$w"*) ;; *) echo "missing: $w"; exit 1 ;; esac
    done' _ "$KIT/install.sh"
rm -rf "$KS"

# --- 39. W-C2: marketplace sources must be folders in the copy; a copy that fails to load is swapped back out -----
SB="$(new_sandbox source-rollback)"
KM="$PROOT/kit-market"; cp -R "$KIT" "$KM" && rm -rf "$KM/.git"
MJ="$KM/.claude-plugin/marketplace.json"
C="$(copy_of "$SB")"
RUN_KIT="$KM" run_kit "$SB" install.sh --apply
before="$(snap "$SB")"
jq '.plugins[0].source = "./plugins/nope"' "$KIT/.claude-plugin/marketplace.json" > "$MJ"   # installer-2
RUN_KIT="$KM" run_kit "$SB" install.sh
check "W-C2: a source that is not in the copy: the dry run exits 1 and names marketplace.json" \
  [ "$RC" = 1 ] && check "W-C2: (dry run) names the source" grep -qF "fix $MJ: plugins[0].source \"./plugins/nope\" is not a folder inside this kit" <<< "$OUT"
RUN_KIT="$KM" run_kit "$SB" install.sh --apply
check "W-C2: ./plugins/nope: --apply exits 1, nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ]
check "W-C2: ./plugins/nope: the previous copy still loads" plugin_ok "$SB"
for src in /tmp ../ ./plugins/workbench/../../..; do
  jq --arg s "$src" '.plugins[0].source = $s' "$KIT/.claude-plugin/marketplace.json" > "$MJ"
  RUN_KIT="$KM" run_kit "$SB" install.sh --apply
  check "W-C2: source $src (outside the copy): exit 1, nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ]
done
cp "$KIT/.claude-plugin/marketplace.json" "$MJ"
copy_v1="$(snap "$C")"
MARK=plugins/workbench/.fake-load-fail
: > "$KM/$MARK"                                    # passes every check, yet this copy fails to load
FAKE_CLAUDE_LOAD_FAIL_IF="$MARK" RUN_KIT="$KM" run_kit "$SB" install.sh --apply
BK="$(stamped "$SB" | tail -n 1)"
check "W-C2: a re-synced copy that fails to load: --apply exits 1" [ "$RC" = 1 ]
check "W-C2: says the new copy fails to load and the previous copy was put back" \
  grep -qF "The new copy fails to load (Plugin workbench failed to load: simulated by $MARK); the previous copy was put back." <<< "$OUT"
check "W-C2: the previous copy is back, byte for byte" [ "$(snap "$C")" = "$copy_v1" ]
check "W-C2: the new copy is in that run's backup" [ -f "$BK/workbench-kit.failed-to-load/$MARK" ]
check "W-C2: says where the new copy is" grep -qF "The new copy is in $BK/workbench-kit.failed-to-load" <<< "$OUT"
check "W-C2: checked again: the previous copy loads" grep -qF "Plugin workbench@workbench loads from $C again (the previous copy)." <<< "$OUT"
FAKE_CLAUDE_LOAD_FAIL_IF="$MARK" check "W-C2: plugin list shows the previous copy loading, the marker honoured" plugin_ok "$SB"
check "W-C2: no temp copy is left behind" [ -z "$(ls -A "$SB/.claude" | grep '^\.workbench-kit')" ]
# Control: when the plan already saw the running copy fail to load, the re-sync keeps the new copy.
printf '\n# another edit\n' >> "$KM/plugins/workbench/scripts/guard.sh"
FAKE_CLAUDE_LOAD_FAIL=1 RUN_KIT="$KM" run_kit "$SB" install.sh --apply
check "W-C2: control: a copy that was already failing: exit 1, no swap back" \
  [ "$RC" = 1 ] && check "W-C2: control: the new copy stays" grep -q '# another edit' "$C/plugins/workbench/scripts/guard.sh"
rm -rf "$KM"

# --- 40. W-C3, W-C7: uninstall.sh --latest reports the plugin as claude plugin list shows it ----------------------
# latest_case NAME: install, a kit update (re-sync), then --latest; the update's backup is the newest one.
latest_case() {
  SB="$(new_sandbox "latest-$1")"; KL="$PROOT/kit-latest-$1"; cp -R "$KIT" "$KL" && rm -rf "$KL/.git"
  S="$SB/.claude/settings.json"; C="$(copy_of "$SB")"
  RUN_KIT="$KL" run_kit "$SB" install.sh --apply
}
latest_update() { printf '\n# kit v2\n' >> "$KL/plugins/workbench/scripts/guard.sh"; RUN_KIT="$KL" run_kit "$SB" install.sh --apply; }
latest_case enabled
latest_update
run_kit "$SB" uninstall.sh --latest --dry-run
check "W-C3: the plan shows the backup's enabled value (true)" \
  grep -qF "the backup's settings.json lists it with enabled: true" <<< "$OUT"
check "W-C7: the plan says the three files match the backup copy" [ "$(grep -c 'matches the backup copy; it stays as it is' <<< "$OUT")" = 3 ]
for f in "$S" "$SB/.claude/CLAUDE.md" "$SB/.claude/agents/Explore.md"; do touch -t 202001010000 "$f"; done
run_kit "$SB" uninstall.sh --latest --yes
check "W-C3: enabled: --latest exits 0" [ "$RC" = 0 ]
check "W-C3: enabled: says it is enabled and loads" \
  grep -qF "The plugin workbench@workbench is enabled and loads (claude plugin list shows no errors)" <<< "$OUT"
check "W-C3: no unchecked 'runs from' claim" [ "$(grep -c 'stays installed and runs from' <<< "$OUT")" = 0 ]
check "W-C7: no Restored line for a file that matches the backup" [ "$(grep -c '^Restored ' <<< "$OUT")" = 0 ]
check "W-C7: and those files are not rewritten" \
  [ -z "$(find "$S" "$SB/.claude/CLAUDE.md" "$SB/.claude/agents/Explore.md" -newer "$ROOT/seed.json")" ]
rm -rf "$KL"
latest_case disabled                              # installer-3 case A
set_json "$S" '.enabledPlugins["workbench@workbench"] = false'   # the user disables the plugin
latest_update                                     # re-enables it and re-syncs
check "W-C3: disabled: (setup) the update run re-enabled the plugin" plugin_ok "$SB"
run_kit "$SB" uninstall.sh --latest --dry-run
check "W-C3: the plan shows the backup's enabled value (false)" \
  grep -qF "the backup's settings.json lists it with enabled: false" <<< "$OUT"
check "W-C3: the plan says the restored settings.json leaves it disabled" \
  grep -q 'so the restored settings.json leaves it disabled' <<< "$OUT"
run_kit "$SB" uninstall.sh --latest --yes
check "W-C3: disabled: --latest exits 0" [ "$RC" = 0 ]
check "W-C3: disabled: says installed but disabled, as before the last --apply" \
  grep -qF "The plugin workbench@workbench is installed but disabled, as it was before the last --apply, so no workbench hook runs." <<< "$OUT"
check "W-C3: disabled: gives the enable command" grep -qF "claude plugin enable workbench@workbench --scope user turns the hooks on." <<< "$OUT"
check "W-C3: disabled: plugin list agrees (enabled false)" \
  [ "$(env -i PATH="$FAKEBIN:$SYS_PATH" HOME="$SB" claude plugin list --json | jq -c '[.[] | .enabled]')" = '[false]' ]
check "W-C3: disabled: no unchecked 'runs from' claim" [ "$(grep -c 'stays installed and runs from' <<< "$OUT")" = 0 ]
rm -rf "$KL"
latest_case missing                               # installer-3 case B
latest_update
fake_cli "$SB" plugin uninstall workbench@workbench   # by hand, after the last --apply
run_kit "$SB" uninstall.sh --latest --yes
check "W-C3: not installed: --latest exits 0" [ "$RC" = 0 ]
check "W-C3: not installed: says so and points at install.sh --apply" \
  grep -qF "The plugin workbench@workbench is not installed, so no workbench hook runs." <<< "$OUT" \
  && check "W-C3: not installed: the install command" grep -qF "Run bash $KIT/install.sh --apply to set it up again." <<< "$OUT"
rm -rf "$KL"
latest_case nocli
latest_update
RUN_PATH="$SYS_PATH" run_kit "$SB" uninstall.sh --latest --yes
check "W-C3: no CLI: --latest exits 0 and says the load state is unchecked" \
  [ "$RC" = 0 ] && check "W-C3: no CLI: (text)" grep -qF "CLI is not on PATH, so whether it loads is unchecked" <<< "$OUT"
rm -rf "$KL"

# --- 41. W-C4: the installed copy names nobody from the author's config outside LICENSE and the manifests ---------
SB="$(new_sandbox teammate-copy nogit)"
printf '[user]\n\tname = Pat Teammate\n' > "$SB/.gitconfig"
run_kit "$SB" install.sh --apply
C="$(copy_of "$SB")"
# copy_hits DIR: every mention of the example config's author and repo tokens in DIR, except in LICENSE files and the
# manifests' owner/author fields. Unlike named_in, no line is excused.
copy_hits() {
  { [ -n "$NAMES_CI" ] && grep -rHniE "$NAMES_CI" "$1"; [ -n "$NAMES_CS" ] && grep -rHnwE "$NAMES_CS" "$1"; } 2>/dev/null \
    | grep -vF -e "$1/LICENSE:" -e "$1/plugins/workbench/LICENSE:" -e "$1/.claude-plugin/marketplace.json:" \
      -e "$1/plugins/workbench/.claude-plugin/plugin.json:" | cut -d: -f1,2
  jq 'del(.owner)' "$1/.claude-plugin/marketplace.json" > "$ROOT/hits-m.json"
  jq 'del(.author)' "$1/plugins/workbench/.claude-plugin/plugin.json" > "$ROOT/hits-p.json"
  { [ -n "$NAMES_CI" ] && grep -HniE "$NAMES_CI" "$ROOT/hits-m.json" "$ROOT/hits-p.json"; \
    [ -n "$NAMES_CS" ] && grep -HnwE "$NAMES_CS" "$ROOT/hits-m.json" "$ROOT/hits-p.json"; } 2>/dev/null | cut -d: -f1,2
}
hits="$(copy_hits "$C" | sed "s#^$C/##" | sort -u | tr '\n' ' ')"
check "W-C4: a teammate's installed copy holds 0 author or repo tokens outside LICENSE and the manifests" [ "$RC" = 0 -a -z "$hits" ]
[ -z "$hits" ] || echo "     named in: $hits"
own_check "W-C4: (control) the copy's LICENSE does name the author" [ -n "$(named_in - "$C/LICENSE")" ]
KN="$PROOT/kit-names"; mkdir -p "$KN"
(cd "$KIT" && find . -type f ! -path './.git/*' ! -path './private/*' ! -name '*.pyc' ! -name .DS_Store) \
  | while read -r f; do mkdir -p "$KN/$(dirname "$f")"; cp "$KIT/$f" "$KN/$f"; done
hits="$(copy_hits "$KN" | sed "s#^$KN/##" | sort -u | tr '\n' ' ')"
check "W-C4: no kit file outside private/ names the author's config tokens (LICENSE, manifest fields aside)" [ -z "$hits" ]
[ -z "$hits" ] || echo "     named in: $hits"
rm -rf "$KN"
check "W-C4: README says where your own config lives (private/<you>.workbench.json)" \
  bash -c 'tr "\n" " " < "$1" | tr -s " " | grep -qF "keep your own config there (\`private/<you>.workbench.json\`)"' _ "$KIT/README.md"
check "W-C4: README names no file in private/ by the author's name" [ "$(grep -c 'private/[a-z]*\.workbench\.json' "$KIT/README.md")" = 0 ]

# --- 42. W-C5: README scopes the CLAUDE.md and Explore.md removal, and says what --keep-files keeps ---------------
RD="$(tr '\n' ' ' < "$KIT/README.md" | tr -s ' ')"
check "W-C5: the removal sentence is scoped to the default and --latest restores" \
  grep -qF 'The default and `--latest` restores remove `CLAUDE.md` and `Explore.md` only if the installer wrote them' <<< "$RD"
check "W-C5: --keep-files: CLAUDE.md and Explore.md stay, and the kept CLAUDE.md still names the workbench hooks" \
  grep -qF '`settings.json`, `CLAUDE.md` and `Explore.md` stay even when the installer wrote them, so the kept `CLAUDE.md` still says the workbench hooks back its rules' <<< "$RD"
check "W-C5: the old unscoped sentence is gone" \
  bash -c 'case "$1" in *"as they are then. \`CLAUDE.md\` and \`Explore.md\` are removed only if"*) exit 1 ;; esac' _ "$RD"
SB="$(new_sandbox keep-files-claude-md)"
run_kit "$SB" install.sh --apply
cp "$SB/.claude/CLAUDE.md" "$ROOT/kept-claude.md"; cp "$SB/.claude/agents/Explore.md" "$ROOT/kept-explore.md"
run_kit "$SB" uninstall.sh --keep-files --yes
check "W-C5: as README says: --keep-files leaves the kit's CLAUDE.md and Explore.md byte-identical" \
  cmp -s "$SB/.claude/CLAUDE.md" "$ROOT/kept-claude.md" && check "W-C5: (Explore.md)" cmp -s "$SB/.claude/agents/Explore.md" "$ROOT/kept-explore.md"
check "W-C5: as README says: the kept CLAUDE.md still names the workbench hooks" grep -q 'the workbench hooks back' "$SB/.claude/CLAUDE.md"

# --- 43. X-C1: hooks.json must wire each script to its event and tools; a hook warning from validate is a miss ----
SB="$(new_sandbox wiring)"
KH="$PROOT/kit-wiring"; cp -R "$KIT" "$KH" && rm -rf "$KH/.git"
HJ="$KH/plugins/workbench/hooks/hooks.json"
cp "$HJ" "$ROOT/good-hooks.json"
C="$(copy_of "$SB")"
write_seed "$SB"
RUN_KIT="$KH" run_kit "$SB" install.sh --apply
check "X-C1: the first install exits 0" [ "$RC" = 0 ]
before="$(snap "$SB")"
# wiring_case NAME JQ_FILTER LINE...: hooks.json edited by JQ_FILTER (it still parses, and every script it names
# exists); --apply exits 1, prints each LINE, changes nothing and runs no plugin step.
wiring_case() {
  wname="$1"; jq "$2" "$ROOT/good-hooks.json" > "$HJ"; shift 2
  : > "$LOG"
  RUN_KIT="$KH" run_kit "$SB" install.sh --apply --replace-old
  check "X-C1: $wname: --apply exits 1" [ "$RC" = 1 ]
  for line in "$@"; do
    check "X-C1: $wname: says ${line#"fix $HJ: "}" grep -qF "$line" <<< "$OUT"
  done
  check "X-C1: $wname: says the installed copy stays as it is" grep -q "the installed copy $C stays as it is" <<< "$OUT"
  check "X-C1: $wname: nothing changed (the copy byte-identical, settings.json, backups)" [ "$before" = "$(snap "$SB")" ]
  check "X-C1: $wname: no marketplace add, install or enable" \
    [ "$(grep -c -E 'marketplace add|plugin install|plugin enable' "$LOG")" = 0 ]
  cp "$ROOT/good-hooks.json" "$HJ"
}
NOPRE="fix $HJ: no PreToolUse group whose matcher matches"
NOPOST="fix $HJ: no PostToolUse group whose matcher matches"
SCR='${CLAUDE_PLUGIN_ROOT}/scripts'
# installer-1, event case: validate only warns, and the CLI then loads PostToolUse alone.
wiring_case "PreToolUse renamed PreToolUser" '.hooks.PreToolUser = .hooks.PreToolUse | del(.hooks.PreToolUse)' \
  "fix $HJ: \"PreToolUser\" is not a hook event Claude Code knows, so nothing under it runs" \
  "$NOPRE Bash runs $SCR/guard.sh" "$NOPRE Bash runs $SCR/commit_gate.sh" "$NOPRE Bash runs $SCR/browser_cap.sh" \
  "$NOPRE mcp__playwright__browser_navigate runs $SCR/browser_cap.sh"
# installer-1, matcher case: validate says nothing at all.
wiring_case "matcher Bsh" '.hooks.PreToolUse[0].matcher = "Bsh"' \
  "$NOPRE Bash runs $SCR/guard.sh" "$NOPRE Bash runs $SCR/commit_gate.sh"
wiring_case "browser matcher without two MCP servers" '.hooks.PreToolUse[1].matcher = "Bash|mcp__playwright.*"' \
  "$NOPRE mcp__Claude_Browser__navigate runs $SCR/browser_cap.sh" \
  "$NOPRE mcp__claude-in-chrome__navigate runs $SCR/browser_cap.sh"
wiring_case "browser_cap.sh as a prompt hook" '.hooks.PreToolUse[1].hooks[0].type = "prompt"' \
  "$NOPRE Bash runs $SCR/browser_cap.sh" "$NOPRE mcp__claude-in-chrome__navigate runs $SCR/browser_cap.sh"
wiring_case "PostToolUse on Edit only" '.hooks.PostToolUse[0].matcher = "Edit"' "$NOPOST Write runs $SCR/format_py.sh"
wiring_case "PostToolUse runs guard.sh instead" '.hooks.PostToolUse[0].hooks[0].command |= sub("format_py"; "guard")' \
  "$NOPOST Edit runs $SCR/format_py.sh" "$NOPOST Write runs $SCR/format_py.sh"
wiring_case "an invalid regex matcher" '.hooks.PreToolUse[1].matcher = "Bash|mcp__(playwright"' \
  "$NOPRE Bash runs $SCR/browser_cap.sh"
# Only claude plugin validate sees this one: a command hook with no command. It exits 0 and warns.
wiring_case "a hook warning from claude plugin validate" '.hooks.PostToolUse[0].hooks += [{"type": "command"}]' \
  "fix $HJ: claude plugin validate warns: hooks: hooks.PostToolUse.0.hooks.1: Invalid command hook"
jq '.hooks.PreToolUser = .hooks.PreToolUse | del(.hooks.PreToolUse)' "$ROOT/good-hooks.json" > "$HJ"
RUN_KIT="$KH" run_kit "$SB" install.sh
check "X-C1: PreToolUser: the dry run exits 1 and names hooks.json" \
  [ "$RC" = 1 ] && check "X-C1: PreToolUser: (dry run) the line" grep -qF "fix $HJ: \"PreToolUser\" is not a hook event" <<< "$OUT"
RUN_PATH="$SYS_PATH" RUN_KIT="$KH" run_kit "$SB" install.sh --apply
check "X-C1: no CLI: PreToolUser still stops the run (exit 1), nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ] \
  && check "X-C1: no CLI: names hooks.json" grep -qF "fix $HJ: \"PreToolUser\" is not a hook event" <<< "$OUT"
cp "$ROOT/good-hooks.json" "$HJ"
# Controls: other spellings that wire the same scripts pass, and plugin directory advice never counts.
jq '.hooks.PreToolUse[0].matcher = "Bash|Read" | .hooks.PreToolUse[1].matcher = "^(Bash|mcp__.*)$"
  | .hooks.PostToolUse[0].matcher = "Write|Edit|MultiEdit"' "$ROOT/good-hooks.json" > "$HJ"
: > "$LOG"
RUN_KIT="$KH" run_kit "$SB" install.sh --apply
check "X-C1: control: matchers Bash|Read, ^(Bash|mcp__.*)$ and Write|Edit|MultiEdit pass, re-sync and exit 0" [ "$RC" = 0 ] \
  && check "X-C1: control: the copy matches" copy_matches "$KH" "$C"
check "X-C1: control: claude plugin validate ran on both (its plugin directory advice did not count)" \
  [ "$(grep -c '^plugin validate ' "$LOG")" = 2 ]
check "X-C1: the comment above copy_checks says what the wiring check and validate require" \
  bash -c 'c="$(sed -n "/^# A new copy must pass these checks/,/^copy_checks()/p" "$1" | tr -d "#" | tr "\n" " " | tr -s " ")"
    for w in "every key under \"hooks\" is a hook event Claude Code knows" \
      "the PreToolUse groups whose matcher matches Bash run scripts/guard.sh, scripts/commit_gate.sh and scripts/browser_cap.sh" \
      "mcp__playwright__browser_navigate, mcp__Claude_Browser__navigate and mcp__claude-in-chrome__navigate run scripts/browser_cap.sh" \
      "the PostToolUse groups matching Edit and Write run scripts/format_py.sh" "(an error, or a warning about hooks, is a miss)"; do
      case "$c" in *"$w"*) ;; *) echo "missing: $w"; exit 1 ;; esac
    done' _ "$KIT/install.sh"
rm -rf "$KH"

# --- 44. X-C2: each hook script runs against a temp workbench.json before the swap; a broken one changes nothing ----
SB="$(new_sandbox hookrun)"
KR="$PROOT/kit-hookrun"; cp -R "$KIT" "$KR" && rm -rf "$KR/.git"
SR="$KR/plugins/workbench/scripts"
C="$(copy_of "$SB")"
RUN_KIT="$KR" run_kit "$SB" install.sh --apply
check "X-C2: the first install exits 0" [ "$RC" = 0 ]
before="$(snap "$SB")"
# typo_case NAME FILE SED LINE...: a one-character edit to FILE's jq filter (bash -n, the empty-config guard runs and
# claude plugin validate all still pass); --apply exits 1, prints each LINE, changes nothing.
typo_case() {
  tname="$1"; tf="$SR/$2"; tsed="$3"; shift 3
  cp "$tf" "$ROOT/typo.good"
  edit_in "$tf" "$tsed"
  check "X-C2: $tname: (setup) the edit applies and bash -n still passes" \
    bash -c '! cmp -s "$1" "$2" && bash -n "$1"' _ "$tf" "$ROOT/typo.good"
  : > "$LOG"
  RUN_KIT="$KR" run_kit "$SB" install.sh --apply
  check "X-C2: $tname: --apply exits 1" [ "$RC" = 1 ]
  for line in "$@"; do
    check "X-C2: $tname: says ${line#"fix $SR/"}" grep -qF "$line" <<< "$OUT"
  done
  check "X-C2: $tname: the empty-config guard runs still pass (no line for them)" \
    [ "$(grep -c 'with an empty config folder' <<< "$OUT")" = 0 ]
  check "X-C2: $tname: nothing changed (the copy byte-identical, settings.json, backups)" [ "$before" = "$(snap "$SB")" ]
  check "X-C2: $tname: no marketplace add, install or enable" \
    [ "$(grep -c -E 'marketplace add|plugin install|plugin enable' "$LOG")" = 0 ]
  cat "$ROOT/typo.good" > "$tf"
}
# installer-2: the reviewer's three one-character jq typos, plus a guard that reads the wrong key.
typo_case "commit_gate.sh jq typo" commit_gate.sh 's#cwd: (.cwd // "" | tostring)}#cwd: (.cwd // "" | tostring}#' \
  "fix $SR/commit_gate.sh: with a workbench.json it gives no decision for a commit in a repo whose commit_gates check fails, not deny"
typo_case "browser_cap.sh jq typo" browser_cap.sh "s#tool=\$(jq -r '.tool_name // \"\"'#tool=\$(jq -r '.tool_name // \"\"\"'#" \
  "fix $SR/browser_cap.sh: with a workbench.json it gives no decision for npx playwright test with CLAUDE_BROWSER_PROC_MAX=-1, not deny"
typo_case "kitconf.sh jq typo" kitconf.sh 's#| rtrimstr("/") | select(startswith("/"))#| rtrimstr("/") | select(startswith("/")#' \
  "fix $SR/kitconf.sh: with a workbench.json, kit_paths \".uv_repos[]?\"; kit_get \".commit_gates[0].remote\" prints" \
  "fix $SR/guard.sh: with a workbench.json it gives no decision for pip install x in a uv_repos folder, not deny"
typo_case "guard.sh reads uv_repo" guard.sh 's#\.uv_repos\[\]?#.uv_repo[]?#g' \
  "fix $SR/guard.sh: with a workbench.json it gives no decision for pip install x in a uv_repos folder, not deny"
cp "$SR/commit_gate.sh" "$ROOT/gate.good"
edit_in "$SR/commit_gate.sh" 's#cwd: (.cwd // "" | tostring)}#cwd: (.cwd // "" | tostring}#'
RUN_KIT="$KR" run_kit "$SB" install.sh
check "X-C2: commit_gate.sh typo: the dry run exits 1 and names commit_gate.sh" \
  [ "$RC" = 1 ] && check "X-C2: (dry run) the line" grep -qF "fix $SR/commit_gate.sh: with a workbench.json" <<< "$OUT"
RUN_PATH="$SYS_PATH" RUN_KIT="$KR" run_kit "$SB" install.sh --apply
check "X-C2: no CLI: the commit_gate.sh typo still stops the run (exit 1), nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ]
cat "$ROOT/gate.good" > "$SR/commit_gate.sh"
# A smoke check that crashes (here: an install.sh whose smoke raises) is a miss, not a pass.
cp "$KR/install.sh" "$ROOT/install.good"
edit_in "$KR/install.sh" 's#^def smoke(copy_dir, kit, home):$#&\
    raise RuntimeError("simulated crash")#'
printf '\n# a good edit\n' >> "$SR/commit_gate.sh"
RUN_KIT="$KR" run_kit "$SB" install.sh --apply
check "X-C2: (setup) the crash is in place" grep -q 'simulated crash' "$KR/install.sh"
check "X-C2: a smoke check that crashes: --apply exits 1, nothing changed" [ "$RC" = 1 -a "$before" = "$(snap "$SB")" ] \
  && check "X-C2: says the smoke check stopped" grep -qF "the smoke check of the copy stopped with exit 1" <<< "$OUT"
cat "$ROOT/install.good" > "$KR/install.sh"; cat "$ROOT/gate.good" > "$SR/commit_gate.sh"
# The smoke check on its own: extracted from install.sh and run on this clean checkout, as the copy's layout.
sed -n "/^  \/usr\/bin\/env python3 -I - \"\$@\" <<'PY'\$/,/^PY\$/p" "$KIT/install.sh" | sed '1d;$d' > "$ROOT/kitpy.py"
SMOKE_T="$(/usr/bin/env python3 -I - "$ROOT/kitpy.py" "$KR" "$ROOT" <<'PY'
import os, subprocess, sys, tempfile, time
kitpy, kit, root = sys.argv[1:4]
best, rcs = None, []
for _ in range(2):
    home = tempfile.mkdtemp(prefix="smoke-time.", dir=root)
    t = time.monotonic()
    r = subprocess.run([sys.executable, "-I", kitpy, "smoke", kit, kit, home], stdout=subprocess.DEVNULL,
                       env={"HOME": home, "PATH": os.environ["PATH"]})
    d = time.monotonic() - t
    best = d if best is None else min(best, d)
    rcs.append(r.returncode)
    subprocess.run(["rm", "-rf", home])
print("%.2f %s" % (best, ",".join(map(str, rcs))))
PY
)"
check "X-C2: the smoke check passes on a clean checkout (rc 0,0)" [ "${SMOKE_T#* }" = "0,0" ]
check "X-C2: the smoke check takes under 2 s (best of 2: ${SMOKE_T%% *} s)" \
  /usr/bin/env python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 2 else 1)' "${SMOKE_T%% *}"
printf '\n# a good edit\n' >> "$SR/commit_gate.sh"
RUN_KIT="$KR" run_kit "$SB" install.sh --apply
check "X-C2: a good edit passes every run, re-syncs and exits 0" [ "$RC" = 0 ] && check "X-C2: the copy matches it" copy_matches "$KR" "$C"
check "X-C2: the runs leave no temp folder (install, gate or smoke) behind" \
  [ -z "$(ls -A "$ROOT" | grep -E '^(workbench-install|workbench-gate|smoke-time)\.')" ]
check "X-C2: the runs write no bytecode in the checkout or the sandbox" [ -z "$(find "$KR" "$SB" -name __pycache__ -o -name '*.pyc')" ]
check "X-C2: the smoke repo's origin is example.com (no real repo, no live gate)" \
  grep -qF 'SMOKE_ORIGIN = "https://example.com/smoke/repo.git"' "$KIT/install.sh"
rm -rf "$KR" "$ROOT/kitpy.py"

# --- 45. X-C3: README says what the browser cap counts, and Known limits what it and the parser do not -------------
CAPROW="$(grep '^| Browser launches' "$KIT/README.md")"
for w in '`node`' '`deno`' '`bun`' '`tsx`' '`ts-node`' '`python`' '`uv run python`' '`npx`' '`npm exec`' '`pnpm exec`' \
  '`--with playwright`' 'piped' '`sed -i`' '`.launch(`'; do
  check "X-C3: the browser-cap row names $w" grep -qF -- "$w" <<< "$CAPROW"
done
LIM="$(sed -n '/^## Known limits/,$p' "$KIT/README.md" | tr '\n' ' ' | tr -s ' ')"
for w in '`uvx`' '`uv tool run`' '`git submodule foreach`' '`git rebase --exec`' '`git bisect run`' \
  '`make e2e`' '`pytest tests/e2e`' '`docker run`' "\`sed -i '\$a ...' f && git commit -F f\`" '`git commit -t`'; do
  check "X-C3: Known limits names $w" grep -qF -- "$w" <<< "$LIM"
done
STEP7="$(sed -n '/^7\. Copies the plugin/,/^8\. Sets up the plugin/p' "$KIT/README.md" | tr '\n' ' ' | tr -s ' ')"
for w in 'every key under `hooks` is a hook event Claude Code knows' 'commit_gate.sh` denies a commit' \
  'browser_cap.sh` denies `npx playwright test`' '`guard.sh` denies `pip install x`' 'a warning about hooks'; do
  check "X-C3: README step 7 lists: $w" grep -qF -- "$w" <<< "$STEP7"
done

# --- 46. X-C4: config-audit check 1 also verifies the hooks.json wiring ---------------------------------------------
AUD="$KIT/plugins/workbench/skills/config-audit/SKILL.md"
CHK1="$(sed -n '/^1\. \*\*Settings parse/,/^2\. \*\*claude doctor/p' "$AUD" | tr '\n' ' ' | tr -s ' ')"
for w in 'unknown hook event' 'matcher matches `Bash`' '`guard.sh`, `commit_gate.sh` and `browser_cap.sh`' \
  '`mcp__playwright__browser_navigate`' '`mcp__Claude_Browser__navigate`' '`mcp__claude-in-chrome__navigate`' \
  '`Edit` and `Write`' '`format_py.sh`' 'claude plugin validate'; do
  check "X-C4: config-audit check 1 names $w" grep -qF -- "$w" <<< "$CHK1"
done
check "X-C4: config-audit SKILL.md has no em dash" [ -z "$(grep -l "$(printf '\342\200\224')" "$AUD")" ]

# --- 47. Y-C1: cmdparse.py must be there and run; guard.sh may not fall back to its whole-text check ---------------
# y_setup ITEM NAME: a sandbox and a checkout copy for one section, installed once; sets YSB, YK, YC and YBEFORE.
y_setup() {
  YSB="$(new_sandbox "$2")"; YK="$PROOT/kit-$2"; rm -rf "$YK"; cp -R "$KIT" "$YK" && rm -rf "$YK/.git"
  YC="$(copy_of "$YSB")"
  RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
  check "$1: the first install exits 0" [ "$RC" = 0 ]
  YBEFORE="$(snap "$YSB")"
}
# y_case ITEM NAME LINE...: --apply on the edited checkout $YK exits 1, prints each LINE, changes nothing in the
# sandbox $YSB and runs no plugin step.
y_case() {
  yi="$1"; yname="$2"; shift 2
  : > "$LOG"
  RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
  check "$yi: $yname: --apply exits 1" [ "$RC" = 1 ]
  for line in "$@"; do
    check "$yi: $yname: says ${line#"fix $YK/plugins/workbench/"}" grep -qF -- "$line" <<< "$OUT"
  done
  check "$yi: $yname: nothing changed (the copy byte-identical, settings.json, backups)" [ "$YBEFORE" = "$(snap "$YSB")" ]
  check "$yi: $yname: no marketplace add, install or enable" \
    [ "$(grep -c -E 'marketplace add|plugin install|plugin enable' "$LOG")" = 0 ]
}
# changed_from FILE GOOD: the edit applied (FILE differs from GOOD) and bash -n or ast.parse still passes on it.
changed_from() {
  ! cmp -s "$1" "$2" || return 1
  case "$1" in
    *.py) /usr/bin/env python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1], "rb").read())' "$1" ;;
    *) bash -n "$1" ;;
  esac
}
y_setup Y-C1 parser
YS="$YK/plugins/workbench/scripts"
cp "$YS/cmdparse.py" "$ROOT/y.cmdparse.py"; cp "$YS/guard.sh" "$ROOT/y.guard.sh"
y1_restore() { rm -f "$YS/cmd_parse.py"; cat "$ROOT/y.cmdparse.py" > "$YS/cmdparse.py"; cat "$ROOT/y.guard.sh" > "$YS/guard.sh"; }
CPF="fix $YS/cmdparse.py:"
NOGUARD="fix $YS/guard.sh:"
# installer-1 (a) and (b): cmdparse.py still parses (ast) but stops at its imports, or in main().
edit_in "$YS/cmdparse.py" 's/^import shlex$/import shlx/'
check "Y-C1: (setup) the import typo applies and cmdparse.py still parses" changed_from "$YS/cmdparse.py" "$ROOT/y.cmdparse.py"
y_case Y-C1 "import shlx in cmdparse.py" \
  "$CPF it does not run as the hooks run it (/usr/bin/env python3 -I): ModuleNotFoundError: No module named 'shlx'"
check "Y-C1: import shlx: guard.sh is not named for it" [ "$(grep -c "$NOGUARD" <<< "$OUT")" = 0 ]
y1_restore
edit_in "$YS/cmdparse.py" 's/records = writers(/records = writer(/'
check "Y-C1: (setup) the NameError edit applies and cmdparse.py still parses" changed_from "$YS/cmdparse.py" "$ROOT/y.cmdparse.py"
y_case Y-C1 "writers called writer in cmdparse.py" "$CPF it does not run as the hooks run it (/usr/bin/env python3 -I): NameError"
y1_restore
# (c) cmdparse.py renamed: guard.sh and commit_gate.sh fall back to regexes, which answer the -m requests alike.
mv "$YS/cmdparse.py" "$YS/cmd_parse.py"
y_case Y-C1 "cmdparse.py renamed cmd_parse.py" "$CPF missing"
check "Y-C1: cmdparse.py renamed: guard.sh is not named for it" [ "$(grep -c "$NOGUARD" <<< "$OUT")" = 0 ]
RUN_KIT="$YK" run_kit "$YSB" install.sh
check "Y-C1: cmdparse.py renamed: the dry run exits 1" [ "$RC" = 1 ] \
  && check "Y-C1: cmdparse.py renamed: (dry run) names cmdparse.py" grep -qF "$CPF missing" <<< "$OUT"
RUN_PATH="$SYS_PATH" RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
check "Y-C1: no CLI: cmdparse.py renamed still stops the run (exit 1), nothing changed" \
  [ "$RC" = 1 -a "$YBEFORE" = "$(snap "$YSB")" ]
y1_restore
# (d) one ')' lost in guard.sh's segment jq: guard.sh falls back to regexes and says so on stderr.
edit_in "$YS/guard.sh" 's/^def base: sub(".\*\/"; "");$/def base: sub(".*\/"; "";/'
check "Y-C1: (setup) the guard.sh segment jq typo applies and bash -n passes" changed_from "$YS/guard.sh" "$ROOT/y.guard.sh"
y_case Y-C1 "a jq typo in guard.sh's segment check" \
  "$NOGUARD with an empty config folder guard.sh falls back to its whole-text check for git stash (it says: workbench guard: whole-text check" \
  "$NOGUARD with an empty config folder guard.sh falls back to its whole-text check for a commit whose -F message file carries the Claude trailer (it says:"
y1_restore
# A guard that reads only the command text, as the whole-text fallback does: the -F message file request catches it.
cat > "$YS/guard.sh" <<'EOF'
#!/bin/bash
c=$(jq -r .tool_input.command)
case "$c" in
  *"git push"*) d=ask ;;
  *"git stash"*|*Co-Authored-By*|*"pip install"*) d=deny ;;
  *) exit 0 ;;
esac
jq -n --arg d "$d" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: "stub"}}'
EOF
y_case Y-C1 "a guard that reads only the command text" \
  "$NOGUARD with an empty config folder it gives no decision for a commit whose -F message file carries the Claude trailer, not deny"
check "Y-C1: text-only guard: every other request passes (one distinct guard.sh line)" \
  [ "$(grep -F "$NOGUARD" <<< "$OUT" | sed 's/^ *//' | sort -u | grep -c .)" = 1 ]
y1_restore
# A guard that gives every decision but says on stderr that it fell back.
cat > "$YS/guard.sh" <<'EOF'
#!/bin/bash
c=$(jq -r .tool_input.command)
echo "workbench guard: whole-text check (stub)" >&2
case "$c" in "git push"*) d=ask ;; *) d=deny ;; esac
jq -n --arg d "$d" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: "stub"}}'
EOF
y_case Y-C1 "a guard that decides right but falls back" \
  "$NOGUARD with an empty config folder guard.sh falls back to its whole-text check for git stash (it says: workbench guard: whole-text check (stub))" \
  "$NOGUARD with a workbench.json guard.sh falls back to its whole-text check for pip install x in a uv_repos folder (it says:"
y1_restore
check "Y-C1: the refused runs wrote no bytecode in the checkout or the sandbox" \
  [ -z "$(find "$YK" "$YSB" -name __pycache__ -o -name '*.pyc')" ]
printf '\n# a good edit\n' >> "$YS/guard.sh"
RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
check "Y-C1: a good edit passes every check, re-syncs and exits 0" [ "$RC" = 0 ] \
  && check "Y-C1: the copy matches it" copy_matches "$YK" "$YC"
printf 'fix: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$ROOT/y.msg.txt"
check "Y-C1: the installed copy's guard denies git commit -F of a file holding the trailer" \
  bash -c 'jq -cn --arg c "git commit -F $1" "{tool_name: \"Bash\", tool_input: {command: \$c}, cwd: \"/tmp\"}" \
    | env -i HOME="$2" PATH="$3" bash "$4" 2>/dev/null | grep -q "\"deny\""' \
  _ "$ROOT/y.msg.txt" "$ROOT" "$SYS_PATH" "$YC/plugins/workbench/scripts/guard.sh"
check "Y-C1: the comment above copy_checks says cmdparse.py must run, and what the -F request and stderr check add" \
  bash -c 'c="$(sed -n "/^# A new copy must pass these checks/,/^copy_checks()/p" "$1" | tr -d "#" | tr "\n" " " | tr -s " ")"
    for w in "guard.sh, commit_gate.sh, browser_cap.sh, kitconf.sh and cmdparse.py are there" \
      "cmdparse.py runs on a request as the hooks run it (/usr/bin/env python3 -I)" \
      "in -m text and in a -F message file (only the parsed path reads that file)" \
      "any \"whole-text check\" line on its stderr is a miss"; do
      case "$c" in *"$w"*) ;; *) echo "missing: $w"; exit 1 ;; esac
    done' _ "$KIT/install.sh"
rm -rf "$YK"

# --- 48. Y-C2: the cap's process count is used: a fake browser-like process runs while browser_cap.sh is asked ------
y_setup Y-C2 capcount
CAPF="$YK/plugins/workbench/scripts/browser_cap.sh"
cp "$CAPF" "$ROOT/y.cap.sh"
CAPLINE="fix $CAPF: with a workbench.json it gives no decision for npx playwright test with CLAUDE_BROWSER_PROC_MAX=0 and one browser-like process running, not deny"
# installer-2: a grep-style \| (a literal | in ERE) and an unbalanced ( in the pgrep pattern both make the count 0,
# and the cap at -1 still denies on a count of 0.
edit_in "$CAPF" "s#'chrome-headless-shell|--remote-debugging-pipe'#'chrome-headless-shell\\\\|--remote-debugging-pipe'#"
check "Y-C2: (setup) the \\| edit applies and bash -n passes" changed_from "$CAPF" "$ROOT/y.cap.sh"
y_case Y-C2 "a grep-style \\| in the pgrep pattern" "$CAPLINE"
check "Y-C2: \\|: the run with the cap at -1 still passes (no line for it)" \
  [ "$(grep -c 'CLAUDE_BROWSER_PROC_MAX=-1' <<< "$OUT")" = 0 ]
cat "$ROOT/y.cap.sh" > "$CAPF"
edit_in "$CAPF" "s#'chrome-headless-shell|--remote-debugging-pipe'#'chrome-headless-shell|--remote-debugging-pipe|(msedge'#"
check "Y-C2: (setup) the unbalanced ( edit applies and bash -n passes" changed_from "$CAPF" "$ROOT/y.cap.sh"
y_case Y-C2 "an unbalanced ( in the pgrep pattern" "$CAPLINE"
cat "$ROOT/y.cap.sh" > "$CAPF"
check "Y-C2: no fake browser-like process is left running" bash -c '! pgrep -f "workbench-smok[e] --remote" >/dev/null'
# What the cap sees: a browser_cap.sh that records pgrep's count of the fake process, then denies like the real one.
cat > "$CAPF" <<EOF
#!/bin/bash
cat >/dev/null
pgrep -f 'workbench-smoke --remote-debugging-pip[e]' | wc -l | tr -d ' ' >> "$ROOT/y.capcount"
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub"}}'
EOF
: > "$ROOT/y.capcount"
RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
check "Y-C2: a recording cap passes and re-syncs" [ "$RC" = 0 ]
check "Y-C2: each cap run (plan and swap, cap at -1 and 0) saw exactly one fake process" \
  bash -c '[ "$(wc -l < "$1" | tr -d " ")" -ge 2 ] && [ -z "$(grep -vx 1 "$1")" ]' _ "$ROOT/y.capcount"
cat "$ROOT/y.cap.sh" > "$CAPF"
RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
check "Y-C2: the real browser_cap.sh is back, re-synced" [ "$RC" = 0 ] && check "Y-C2: the copy matches it" copy_matches "$YK" "$YC"
check "Y-C2: the comment above copy_checks names the fake process and the cap at 0" \
  bash -c 'c="$(sed -n "/^# A new copy must pass these checks/,/^copy_checks()/p" "$1" | tr -d "#" | tr "\n" " " | tr -s " ")"
    case "$c" in *"CLAUDE_BROWSER_PROC_MAX=0 while one fake browser-like process (a bash whose argv carries --remote-debugging-pipe, killed by PID afterwards) runs"*) ;; *) exit 1 ;; esac' _ "$KIT/install.sh"
rm -rf "$YK"

# --- 49. Y-C3: hook matchers are read as the CLI (2.1.311) reads them ----------------------------------------------
sed -n "/^  \/usr\/bin\/env python3 -I - \"\$@\" <<'PY'\$/,/^PY\$/p" "$KIT/install.sh" | sed '1d;$d' > "$ROOT/kitpy.py"
# One line per case: ok or FAIL, then the case. The first ten are the round-7 matcher_cmp.py cases with the
# CLI's answers; the rest pin the event rule and the match-all forms.
/usr/bin/env python3 -I - "$ROOT/kitpy.py" > "$ROOT/y.matcher" <<'PY'
import json, sys
src = open(sys.argv[1], encoding="utf-8").read()
ns = {}
exec(compile(src[:src.index("\ndef main(")], "kitpy", "exec"), ns)
P = "Bash|mcp__playwright|mcp__Claude_Browser|mcp__claude-in-chrome"
R = "Bash|mcp__playwright.*|mcp__Claude_Browser__.*|mcp__claude-in-chrome__.*"
cases = [
    (P, "mcp__claude-in-chrome__navigate", "PreToolUse", False),
    (P, "mcp__playwright__browser_navigate", "PreToolUse", False),
    (P, "mcp__Claude_Browser__navigate", "PreToolUse", False),
    (P, "Bash", "PreToolUse", True),
    ("Edit, Write", "Edit", "PostToolUse", True),
    ("Edit, Write", "Write", "PostToolUse", True),
    ("Bash ", "Bash", "PreToolUse", True),
    ("Bash,Edit", "Bash", "PreToolUse", True),
    ("Bash", "Bash", "PreToolUse", True),
    (R, "mcp__claude-in-chrome__navigate", "PreToolUse", True),
    ("Edit, Write", "Edit", "Stop", False),
    ("Edit|Write", "Write", "Stop", True),
    ("Bash\n", "Bash", "PreToolUse", False),
    ("", "Bash", "PreToolUse", True),
    ("*", "Write", "PostToolUse", True),
    (None, "Write", "PostToolUse", True),
    ("Bsh", "Bash", "PreToolUse", False),
]
for m, t, e, want in cases:
    try:
        got = ns["matcher_matches"](m, t, e)
    except TypeError as x:
        got = "TypeError: %s" % x
    print("%s matcher %s, tool %s, event %s: %s" % ("ok" if got is want else "FAIL", json.dumps(m), t, e,
                                                   "matches" if want else "does not match"))
PY
check "Y-C3: the matcher cases ran (17)" [ "$(grep -c . "$ROOT/y.matcher")" = 17 ]
while IFS= read -r l; do
  check "Y-C3: ${l#* }" [ "${l%% *}" = ok ]
done < "$ROOT/y.matcher"
y_setup Y-C3 matcher
YHJ="$YK/plugins/workbench/hooks/hooks.json"; cp "$YHJ" "$ROOT/y.hooks.json"
hj_edit() { jq "$1" "$ROOT/y.hooks.json" > "$YHJ"; }
NOPRE="fix $YHJ: no PreToolUse group whose matcher matches"
SCR='${CLAUDE_PLUGIN_ROOT}/scripts'
# installer-3 part A: prefix names without .* look like regexes but are a plain list for the CLI, so none of the
# three MCP browser tools runs the cap.
hj_edit '.hooks.PreToolUse[1].matcher = "Bash|mcp__playwright|mcp__Claude_Browser|mcp__claude-in-chrome"'
y_case Y-C3 "a prefix-name matcher list" "$NOPRE mcp__playwright__browser_navigate runs $SCR/browser_cap.sh" \
  "$NOPRE mcp__Claude_Browser__navigate runs $SCR/browser_cap.sh" "$NOPRE mcp__claude-in-chrome__navigate runs $SCR/browser_cap.sh"
check "Y-C3: prefix list: Bash still runs the cap (no line for it)" [ "$(grep -c "$NOPRE Bash runs" <<< "$OUT")" = 0 ]
# installer-3 part B: the CLI runs "Edit, Write" and "Bash , Read"; so does the check.
hj_edit '.hooks.PostToolUse[0].matcher = "Edit, Write" | .hooks.PreToolUse[0].matcher = "Bash , Read"'
: > "$LOG"
RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
check "Y-C3: matchers \"Edit, Write\" and \"Bash , Read\" pass, re-sync and exit 0" [ "$RC" = 0 ] \
  && check "Y-C3: the copy matches it" copy_matches "$YK" "$YC"
check "Y-C3: the comment above copy_checks says how matchers are read" \
  bash -c 'c="$(sed -n "/^# A new copy must pass these checks/,/^copy_checks()/p" "$1" | tr -d "#" | tr "\n" " " | tr -s " ")"
    case "$c" in *"a matcher of letters, digits, _, |, comma, space and - is a list of names split on | or comma"*) ;; *) exit 1 ;; esac' \
  _ "$KIT/install.sh"
rm -rf "$YK" "$ROOT/kitpy.py"

# --- 50. Y-C4: the wired command strings run as Claude Code runs them; the decider hooks block and the gate has time --
y_setup Y-C4 wired
YHJ="$YK/plugins/workbench/hooks/hooks.json"; cp "$YHJ" "$ROOT/y.hooks.json"
YS="$YK/plugins/workbench/scripts"; cp "$YS/guard.sh" "$ROOT/y.guard.sh"
HJF="fix $YHJ:"
RUNS='(run with bash -c, as Claude Code runs it):'
# installer-4: a typo in the command's own words (the interpreter, a quote) passes every path check.
hj_edit '.hooks.PreToolUse[0].hooks[0].command |= sub("^bash "; "bahs ")'
y_case Y-C4 "bahs for bash in the guard command" \
  "$HJF its command bahs \"$SCR/guard.sh\" $RUNS with an empty config folder it gives no decision (exit 127: bash: bahs: command not found) for git stash, not deny"
check "Y-C4: bahs: guard.sh itself is not named" [ "$(grep -c "fix $YS/guard.sh:" <<< "$OUT")" = 0 ]
RUN_KIT="$YK" run_kit "$YSB" install.sh
check "Y-C4: bahs: the dry run exits 1 and names hooks.json" [ "$RC" = 1 ] \
  && check "Y-C4: bahs: (dry run) the line" grep -qF "$HJF its command bahs" <<< "$OUT"
hj_edit '.hooks.PreToolUse[0].hooks[0].command |= sub("\"$"; "")'
y_case Y-C4 "the guard command's closing quote lost" \
  "$HJF its command bash \"$SCR/guard.sh $RUNS with an empty config folder it gives no decision (exit 2:"
hj_edit '.hooks.PreToolUse[0].hooks[1].command |= sub("^bash "; "bahs ")'
y_case Y-C4 "bahs in the commit gate command" \
  "$HJF its command bahs \"$SCR/commit_gate.sh\" $RUNS with a workbench.json it gives no decision (exit 127"
hj_edit '.hooks.PreToolUse[1].hooks[0].command |= sub("^bash "; "bahs ")'
y_case Y-C4 "bahs in the browser cap command" \
  "$HJF its command bahs \"$SCR/browser_cap.sh\" $RUNS with a workbench.json it gives no decision (exit 127"
hj_edit '.hooks.PostToolUse[0].hooks[0].command |= sub("^bash "; "bahs ")'
y_case Y-C4 "bahs in the formatter command" \
  "$HJF its command bahs \"$SCR/format_py.sh\" $RUNS with an empty config folder it exits 127 for an Edit of a .txt file, not 0"
# The gate's checks share a 170 s budget: a hook timeout at or under it cuts them off.
hj_edit '.hooks.PreToolUse[0].hooks[1].timeout = 18'
y_case Y-C4 "commit gate timeout 18" \
  "$HJF the PreToolUse hook that runs $SCR/commit_gate.sh has timeout 18; it must be above 170, the gate's own time budget (WORKBENCH_GATE_TIMEOUT)"
hj_edit '.hooks.PreToolUse[0].hooks[1].timeout = 170'
y_case Y-C4 "commit gate timeout 170" "$HJF the PreToolUse hook that runs $SCR/commit_gate.sh has timeout 170; it must be above 170"
# A hook that runs in the background, or only once, decides nothing the CLI waits for.
hj_edit '.hooks.PreToolUse[0].hooks[1].async = true'
y_case Y-C4 "async on the commit gate" \
  "$HJF the PreToolUse hook that runs $SCR/commit_gate.sh sets \"async\": true, so Claude Code runs it in the background and does not wait for its decision"
hj_edit '.hooks.PreToolUse[0].hooks[0].async = true'
y_case Y-C4 "async on the guard" "$HJF the PreToolUse hook that runs $SCR/guard.sh sets \"async\": true"
hj_edit '.hooks.PreToolUse[1].hooks[0].asyncRewake = true'
y_case Y-C4 "asyncRewake on the browser cap" "$HJF the PreToolUse hook that runs $SCR/browser_cap.sh sets \"asyncRewake\": true"
hj_edit '.hooks.PreToolUse[0].hooks[0].once = true'
y_case Y-C4 "once on the guard" \
  "$HJF the PreToolUse hook that runs $SCR/guard.sh sets \"once\": true, so Claude Code removes it after its first run"
# A broken script behind a command written another way: the script is named, not hooks.json.
hj_edit '.hooks.PreToolUse[0].hooks[0].command = "/bin/bash \"${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh\""'
edit_in "$YS/guard.sh" 's#| select(\$c | test(\$kw))#| select($c | test($kw)#'
check "Y-C4: (setup) the guard.sh jq typo applies" changed_from "$YS/guard.sh" "$ROOT/y.guard.sh"
y_case Y-C4 "a guard typo behind /bin/bash" "fix $YS/guard.sh: with an empty config folder it gives no decision for git stash, not deny"
check "Y-C4: guard typo behind /bin/bash: hooks.json is not named" [ "$(grep -c "$HJF its command" <<< "$OUT")" = 0 ]
cat "$ROOT/y.guard.sh" > "$YS/guard.sh"
# Controls: no timeout (the CLI then waits 600 s), async false, commands written another way; then timeout 171.
hj_edit 'del(.hooks.PreToolUse[0].hooks[1].timeout) | .hooks.PreToolUse[0].hooks[0].async = false
  | .hooks.PreToolUse[0].hooks[0].command = "/bin/bash \"${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh\""
  | .hooks.PreToolUse[1].hooks[0].command = "bash ${CLAUDE_PLUGIN_ROOT}/scripts/browser_cap.sh"'
: > "$LOG"
RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
check "Y-C4: control: no gate timeout, async false and other command spellings pass, re-sync and exit 0" [ "$RC" = 0 ] \
  && check "Y-C4: control: the copy matches it" copy_matches "$YK" "$YC"
hj_edit '.hooks.PreToolUse[0].hooks[1].timeout = 171'
RUN_KIT="$YK" run_kit "$YSB" install.sh --apply
check "Y-C4: control: gate timeout 171 passes, re-syncs and exits 0" [ "$RC" = 0 ] \
  && check "Y-C4: control: the copy matches it" copy_matches "$YK" "$YC"
check "Y-C4: the comment above copy_checks says how hooks.json commands run and what they may not set" \
  bash -c 'c="$(sed -n "/^# A new copy must pass these checks/,/^copy_checks()/p" "$1" | tr -d "#" | tr "\n" " " | tr -s " ")"
    for w in "none of the PreToolUse hooks that run those three scripts sets async, asyncRewake or once" \
      "commit_gate.sh'"'"'s hook has no timeout (the CLI then waits 600 s) or one above 170" \
      "each command string hooks.json wires a script with runs as Claude Code runs it (bash -c, with CLAUDE_PLUGIN_ROOT set"; do
      case "$c" in *"$w"*) ;; *) echo "missing: $w"; exit 1 ;; esac
    done' _ "$KIT/install.sh"
rm -rf "$YK"

# --- 51. Y-C5: README and config-audit say what round 8 checks; Known limits list the round-7 lows left open -------
LIM="$(sed -n '/^## Known limits/,$p' "$KIT/README.md" | tr '\n' ' ' | tr -s ' ')"
# hooks-regress-4, -5, -6, -8 and -9 of the round-7 review, all with no rows in the real-command corpora.
for w in 'A runner inside a message is message text' '`git submodule foreach "$CMD"`' '`git bisect run "$CMD"`' \
  '`$(< /dev/stdin)`' '`... | xargs gh ...`' '`npx --package=playwright ...`' '`node < e2e/x.mjs`' \
  'a script written by `echo` or `printf` with `>`' '`git tag -F -`' '`gh --body-file -`'; do
  check "Y-C5: Known limits names $w" grep -qF -- "$w" <<< "$LIM"
done
# What round 8 made the hooks do (owner A): the cap row and the shell-code row say it.
CAPROW="$(grep '^| Browser launches' "$KIT/README.md")"
for w in '`uv run X.py`' '`npx tsx@4`' '`puppeteer-core`' '`cat <<EOF \| tee run.sh`' '`echo ... \| tee t.js`'; do
  check "Y-C5: the browser-cap row names $w" grep -qF -- "$w" <<< "$CAPROW"
done
SHROW="$(grep '^| Code fed to a shell' "$KIT/README.md")"
for w in '`cat > s.sh <<EOF ... EOF; bash s.sh`' '`sh s.sh`' '`./s.sh`' 'except a `./s.sh` whose `#!` line names a non-shell'; do
  check "Y-C5: the shell-code row names $w" grep -qF -- "$w" <<< "$SHROW"
done
STEP7="$(sed -n '/^7\. Copies the plugin/,/^8\. Sets up the plugin/p' "$KIT/README.md" | tr '\n' ' ' | tr -s ' ')"
for w in '`cmdparse.py` runs on a request the way the hooks run it' 'in `-m` text and in a `-F` message file' \
  'A "whole-text check" line on its stderr is a miss' '`CLAUDE_BROWSER_PROC_MAX=0`' '`--remote-debugging-pipe`' \
  '`Edit, Write` lists two tools' 'none sets `async`, `asyncRewake` or `once`' 'above 170 seconds' \
  'runs the way Claude Code runs it (`bash -c`, with `CLAUDE_PLUGIN_ROOT` set'; do
  check "Y-C5: README step 7 says: $w" grep -qF -- "$w" <<< "$STEP7"
done
AUD="$KIT/plugins/workbench/skills/config-audit/SKILL.md"
CHK1="$(sed -n '/^1\. \*\*Settings parse/,/^2\. \*\*claude doctor/p' "$AUD" | tr '\n' ' ' | tr -s ' ')"
for w in 'commas, spaces and `-` is a list of exact tool names split on `|` or `,`' '`Edit, Write` lists two tools' \
  'sets `async`, `asyncRewake` or `once`' '`timeout` is 170 or less' 'bash -c "$C"' \
  'CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"' 'HOME=/nonexistent' '`bahs` for `bash`'; do
  check "Y-C5: config-audit check 1 names $w" grep -qF -- "$w" <<< "$CHK1"
done
# The audit's loop, as written in check 1, on this checkout's hooks.json and on one with an interpreter typo.
sed -n '/^1\. \*\*Settings parse/,/^2\. \*\*claude doctor/p' "$AUD" | sed -n '/^   ```bash$/,/^   ```$/p' | sed '1d;$d' \
  | sed 's/^   //' > "$ROOT/y.audit-loop.sh"
AL="$(env -i PATH="$SYS_PATH" CLAUDE_PLUGIN_ROOT="$KIT/plugins/workbench" bash "$ROOT/y.audit-loop.sh" 2>&1)"
check "Y-C5: the audit loop runs this checkout's three PreToolUse commands, each with exit 0" \
  [ "$(grep -c '^exit 0 for bash "${CLAUDE_PLUGIN_ROOT}/scripts/' <<< "$AL")" = 3 -a "$(grep -c . <<< "$AL")" = 3 ]
YP="$PROOT/kit-auditloop"; rm -rf "$YP"; cp -R "$KIT/plugins/workbench" "$YP"
jq '.hooks.PreToolUse[0].hooks[0].command |= sub("^bash "; "bahs ")' "$KIT/plugins/workbench/hooks/hooks.json" \
  > "$YP/hooks/hooks.json"
AL="$(env -i PATH="$SYS_PATH" CLAUDE_PLUGIN_ROOT="$YP" bash "$ROOT/y.audit-loop.sh" 2>/dev/null)"
check "Y-C5: the audit loop shows exit 127 for a bahs typo" \
  grep -qF 'exit 127 for bahs "${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh"' <<< "$AL"
rm -rf "$YP"
check "Y-C5: README and config-audit SKILL.md have no em dash" \
  [ -z "$(grep -l "$(printf '\342\200\224')" "$KIT/README.md" "$AUD")" ]

# --- 52. Web upload: a checkout with no exec bits installs, its copy gets them back, and the docs run bash ----------
SB="$(new_sandbox webup)"; KW="$PROOT/kit-webup"; rm -rf "$KW"; cp -R "$KIT" "$KW" && rm -rf "$KW/.git"
find "$KW" -type f -exec chmod 644 {} +
check "WU: the test checkout really has no exec bits" [ -z "$(find "$KW" -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \))" ]
RUN_KIT="$KW" run_kit "$SB" install.sh --apply; WU_OUT="$OUT"
check "WU: install.sh --apply from a checkout with no exec bits exits 0" [ "$RC" = 0 ]
WC="$(copy_of "$SB")"
wu_scripts() { find "$1/plugins/workbench" -type f \( -name '*.sh' -o -name '*.py' \); }
check "WU: the copy holds the 9 plugin scripts" [ "$(wu_scripts "$WC" | wc -l | tr -d ' ')" = 9 ]
check "WU: each of them is executable in the copy" [ -z "$(wu_scripts "$WC" | while read -r f; do [ -x "$f" ] || echo "$f"; done)" ]
WU_DEC="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push origin x"},"cwd":"/tmp"}' \
  | env -i HOME="$SB" PATH="$SYS_PATH" "$WC/plugins/workbench/scripts/guard.sh" 2>/dev/null \
  | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)"
check "WU: the copy's guard.sh runs when executed directly (push asks)" [ "$WU_DEC" = ask ]
check "WU: the undo hint runs uninstall.sh with bash" grep -qF "Undo with: bash $KW/uninstall.sh" <<< "$WU_OUT"
RUN_KIT="$KW" run_kit "$SB" install.sh
check "WU: a second dry run plans no copy change" grep -qF "matches this folder, no change" <<< "$OUT"
wu_scripts "$WC" | while read -r f; do chmod 644 "$f"; done   # a copy an older install.sh built from such a checkout
RUN_KIT="$KW" run_kit "$SB" install.sh
check "WU: a copy whose scripts lost their exec bits is planned for a re-sync" grep -qF "installed copy: re-sync" <<< "$OUT"; WU_RESYNC_PLAN="$OUT"
RUN_KIT="$KW" run_kit "$SB" install.sh --apply
check "WU: the re-sync exits 0" [ "$RC" = 0 ]
check "WU: and gives the copy's scripts their exec bits back" [ -z "$(wu_scripts "$WC" | while read -r f; do [ -x "$f" ] || echo "$f"; done)" ]
check "WU: uninstall.sh's install hint runs install.sh with bash" grep -qF 'echo "  Run bash $KIT_DIR/install.sh --apply' "$KIT/uninstall.sh"
check "WU: uninstall.sh's fix hint runs install.sh with bash" grep -qF 'then run bash $KIT_DIR/install.sh --apply.' "$KIT/uninstall.sh"
check "WU: no printed hint in install.sh or uninstall.sh runs install.sh without bash" \
  [ -z "$(grep -hE 'echo .*install\.sh --apply' "$KIT/install.sh" "$KIT/uninstall.sh" | grep -vE 'bash (\$KIT_DIR/)?install\.sh --apply')" ]
check "WU: the audit prompt and config-audit run install.sh with bash" \
  [ "$(grep -c '`install.sh --apply`' "$KIT/user/audit-task.md" "$KIT/plugins/workbench/skills/config-audit/SKILL.md" | awk -F: '{s+=$2} END {print s}')" = 0 ]
check "WU: a copy re-synced only for modes says why" grep -qF "(a script lost its exec bit)" <<< "$WU_RESYNC_PLAN"
check "WU: README never runs ./install.sh or ./uninstall.sh" [ "$(grep -cE '\./(un)?install\.sh' "$KIT/README.md")" = 0 ]
check "WU: README says why the scripts run with bash" grep -qF 'a web upload or a zip' "$KIT/README.md"
rm -rf "$KW"

echo "# $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
