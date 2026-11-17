#!/bin/bash
# workbench uninstaller. Shows its plan, asks, and only then uninstalls the plugin (claude CLI, best effort),
# moves the installed copy (<config>/workbench-kit) into the backup folder and restores settings.json,
# CLAUDE.md and agents/Explore.md in the Claude Code config folder (~/.claude, or $CLAUDE_CONFIG_DIR when it
# is set) from a workbench backup: the pre-workbench state in backups/workbench-original/ by default, or the
# newest backup with --latest (which also puts back the installed copy from then, and keeps the plugin when it
# was installed then). Agents that install.sh --replace-old retired come back too.
# Never deletes workbench.json, memory or audits. Bash 3.2 compatible.
set -u

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--home DIR] [--latest | --keep-files] [--dry-run] [--yes]

  (default)     uninstall the plugin and restore the state from before the first install.sh --apply
                (backups/workbench-original/), then archive that backup as
                workbench-original.restored-<timestamp> so a later install takes a fresh snapshot
  --latest      restore the newest timestamped backup instead: the files, install.sh's records and the
                installed copy from before the last install.sh --apply. When that backup's settings.json lists
                the plugin (it was installed before that run), the plugin and marketplace stay installed, and
                the run ends with the state claude plugin list shows (enabled, disabled, not installed);
                otherwise they are removed as by default. A file that matches the backup is left as it is
  --keep-files  uninstall the plugin but keep settings.json, CLAUDE.md and agents/Explore.md as they are;
                write back the old hook entries install.sh --replace-old removed (taken from
                backups/workbench-original/settings.json) and the agents it retired; then archive the backups
                as the default does, so a later install takes a fresh snapshot
  --dry-run     print the plan and change nothing
  --yes         go ahead without asking; without a terminal nothing changes unless this is given
  --home DIR    use DIR as the home directory instead of $HOME, and DIR/.claude as the config folder
                (the tests use a sandbox); CLAUDE_CONFIG_DIR is then ignored, also by the claude calls

Config folder without --home: $CLAUDE_CONFIG_DIR if set, else ~/.claude.
Asks before any change; anything but y or yes changes nothing (exit 0).
Exit codes: 0 done or nothing changed, 1 error, 2 bad usage or run from the installed copy's path.
EOF
}

die() { echo "uninstall.sh: $*" >&2; exit 1; }

LATEST=0
KEEP=0
DRY_RUN=0
YES=0
HOME_FLAG=0
HOME_DIR="${HOME:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --latest) LATEST=1 ;;
    --keep-files) KEEP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) YES=1 ;;
    --home)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      HOME_DIR="$2"; HOME_FLAG=1; shift ;;
    --home=*) HOME_DIR="${1#--home=}"; HOME_FLAG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "uninstall.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [ "$LATEST" = 1 ] && [ "$KEEP" = 1 ]; then
  echo "uninstall.sh: --latest restores files and --keep-files keeps them; pass one of the two" >&2
  exit 2
fi

[ -n "$HOME_DIR" ] || die "no home directory: set HOME or pass --home DIR"
case "$HOME_DIR" in /*) ;; *) HOME_DIR="$(pwd)/$HOME_DIR" ;; esac
HOME_DIR="${HOME_DIR%/}"
[ -d "$HOME_DIR" ] || die "home directory does not exist: $HOME_DIR"

KIT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# The same config folder install.sh used: $CLAUDE_CONFIG_DIR when set, else ~/.claude. --home pins DIR/.claude.
abspath() { case "$1" in /*) printf '%s\n' "${1%/}" ;; *) printf '%s\n' "$(pwd)/${1%/}" ;; esac; }
if [ "$HOME_FLAG" = 0 ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CLAUDE_DIR="$(abspath "$CLAUDE_CONFIG_DIR")"
else
  CLAUDE_DIR="$HOME_DIR/.claude"
fi
if [ "$HOME_FLAG" = 0 ] && [ -n "${WORKBENCH_CONFIG:-}" ]; then
  WB_JSON="$(abspath "$WORKBENCH_CONFIG")"
else
  WB_JSON="$CLAUDE_DIR/workbench.json"
fi
SETTINGS="$CLAUDE_DIR/settings.json"
BACKUPS="$CLAUDE_DIR/backups"
ORIGINAL="$BACKUPS/workbench-original"
CREATED="$BACKUPS/workbench-created"
FRAG_RECORD="$CREATED/settings.fragment.applied.json"
SETTINGS_RECORD="$CREATED/settings.json.sha256"
RETIRED_RECORD="$CREATED/retired-agents"
COPY="$CLAUDE_DIR/workbench-kit"
PLUGIN_ID="workbench@workbench"
NAMES="settings.json CLAUDE.md agents/Explore.md"

cli() {
  if [ "$HOME_FLAG" = 1 ]; then
    env -u CLAUDE_CONFIG_DIR -u WORKBENCH_CONFIG HOME="$HOME_DIR" claude "$@" </dev/null
  else
    claude "$@" </dev/null
  fi
}
CLI=0; command -v claude >/dev/null 2>&1 && CLI=1
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1"; else sha256sum < "$1"; fi | cut -d' ' -f1; }

# JSON work. Subcommands:
#   writeback ORIGINAL_SETTINGS SETTINGS plan|apply
#       the hook entries for the kit's old hooks/ scripts that the original settings.json had and the current one
#       lacks (install.sh --replace-old removed them). Prints one line per entry; apply also writes them back next
#       to entries with the same matcher. Exit 10 if there are any.
#   listed SETTINGS          exit 0 if enabledPlugins names workbench@workbench, and print its value (true, false)
#   state TEXT               from claude plugin list --json output: ok, disabled, missing, "failed: ..." or unknown
#   userdiff BACKUP SETTINGS HOME FRAGMENT...
#       the keys and rules of SETTINGS that differ from BACKUP ("" for none) and are not entries of any FRAGMENT
#       (the kit's), plugin entries, or the old hook entries --replace-old removed
#   overlap KIT COPY         print is, inside or contains when KIT is COPY, sits in it or holds it
unpy() {
  /usr/bin/env python3 -I - "$@" <<'PY'
import copy, json, os, re, sys

PAT = re.compile(r"/hooks/(guard|browser_cap|commit_gate|format_py)\.sh(?![\w.-])")
PLUGIN_ID = "workbench@workbench"


def load(path):
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        sys.stderr.write("ERROR: cannot read %s: %s\n" % (path, e))
        sys.exit(1)
    return data if isinstance(data, dict) else {}


def old_hook(h):
    cmd = h.get("command") if isinstance(h, dict) else None
    return isinstance(cmd, str) and PAT.search(cmd.replace('"', "").replace("'", "")) is not None


def writeback(orig_path, cur_path, mode):
    old = load(orig_path).get("hooks")
    data = load(cur_path)
    hooks = copy.deepcopy(data.get("hooks")) if isinstance(data.get("hooks"), dict) else {}
    added = []
    for event, groups in (old.items() if isinstance(old, dict) else []):
        for group in groups if isinstance(groups, list) else []:
            handlers = group.get("hooks") if isinstance(group, dict) else None
            for h in handlers if isinstance(handlers, list) else []:
                if not old_hook(h):
                    continue
                now = hooks.setdefault(event, [])
                if not isinstance(now, list):
                    continue
                if any(h in (g.get("hooks") or []) for g in now if isinstance(g, dict)):
                    continue
                target = None
                for g in now:
                    if isinstance(g, dict) and g.get("matcher") == group.get("matcher") and isinstance(g.get("hooks"), list):
                        target = g
                        break
                if target is None:
                    target = {k: copy.deepcopy(v) for k, v in group.items() if k != "hooks"}
                    target["hooks"] = []
                    now.append(target)
                target["hooks"].append(copy.deepcopy(h))
                added.append("%s [%s] %s" % (event, group.get("matcher", "*"), h["command"]))
    for line in added:
        print("    " + line)
    if not added:
        return 0
    if mode == "apply":
        data["hooks"] = hooks
        target = os.path.realpath(cur_path)  # write through a symlinked dotfile
        tmp = target + ".workbench-tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        if os.path.exists(target):
            os.chmod(tmp, os.stat(target).st_mode & 0o7777)
        os.replace(tmp, target)
    return 10


def entries(data, home):
    """Every leaf as (path, kind, key) -> value: list items, scalars, and each hook handler on its own."""
    out = {}

    def norm(item):
        if isinstance(item, str):  # "//Users/me/**/.env" and "~/**/.env" are the same rule
            return item.replace("//" + home.lstrip("/") + "/", "~/")
        return json.dumps(item, sort_keys=True)

    def walk(v, path):
        if path == ("hooks",) and isinstance(v, dict):
            for event, groups in v.items():
                for g in groups if isinstance(groups, list) else [groups]:
                    hs = g.get("hooks") if isinstance(g, dict) else None
                    if isinstance(hs, list):
                        for h in hs:
                            key = (("hooks", event, "[%s]" % g.get("matcher", "*")), "h", json.dumps(h, sort_keys=True))
                            out[key] = h
                    else:
                        out[(("hooks", event), "h", json.dumps(g, sort_keys=True))] = g
        elif isinstance(v, dict):
            for k, x in v.items():
                walk(x, path + (k,))
        elif isinstance(v, list):
            for x in v:
                out[(path, "i", norm(x))] = x
        else:
            out[(path, "s", json.dumps(v, sort_keys=True))] = v

    walk(data, ())
    return out


def userdiff(backup, cur, home, frags):
    before, now = entries(load(backup), home), entries(load(cur), home)
    kit = set()
    for f in frags:
        kit.update(entries(load(f), home))

    def mine(key, value):
        path = key[0]
        if key in kit or path[:2] in (("enabledPlugins", PLUGIN_ID), ("extraKnownMarketplaces", "workbench")):
            return False
        return not (key[1] == "h" and old_hook(value))

    def label(path):
        return ".".join(path[:2]) + " " + path[2] if path[:1] == ("hooks",) and len(path) > 2 else ".".join(path)

    def show(value):
        if isinstance(value, dict) and isinstance(value.get("command"), str):
            return value["command"]
        return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)

    added = [(k, v) for k, v in now.items() if k not in before and mine(k, v)]
    removed = [(k, v) for k, v in before.items() if k not in now and mine(k, v)]
    was = dict((k[0], v) for k, v in removed if k[1] == "s")
    is_now = set(k[0] for k, v in added if k[1] == "s")
    for k, v in added:
        if k[1] != "s":
            print("        %s: + %s" % (label(k[0]), show(v)))
        elif k[0] in was:
            print("        %s: %s (was %s)" % (label(k[0]), json.dumps(v), json.dumps(was[k[0]])))
        else:
            print("        %s: %s (not in the backup)" % (label(k[0]), json.dumps(v)))
    for k, v in removed:
        if k[1] != "s":
            print("        %s: - %s" % (label(k[0]), show(v)))
        elif k[0] not in is_now:
            print("        %s: removed (was %s)" % (label(k[0]), json.dumps(v)))
    return 0


def overlap(kit, copy_dir):
    def same(a, b):
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

    if same(kit, copy_dir):
        return "is"
    if any(same(p, copy_dir) for p in parents(kit)):
        return "inside"
    if any(same(p, kit) for p in parents(copy_dir)):
        return "contains"
    return ""


cmd, args = sys.argv[1], sys.argv[2:]
if cmd == "writeback":
    sys.exit(writeback(*args[:3]))
if cmd == "listed":
    enabled = load(args[0]).get("enabledPlugins")
    if not isinstance(enabled, dict) or PLUGIN_ID not in enabled:
        sys.exit(1)
    print(json.dumps(enabled[PLUGIN_ID]))
    sys.exit(0)
if cmd == "state":
    try:
        listing = json.loads(args[0])
    except ValueError:
        listing = None
    if not isinstance(listing, list):
        print("unknown")
        sys.exit(0)
    for p in listing:
        if isinstance(p, dict) and p.get("id") == PLUGIN_ID:
            errors = p.get("errors") or []
            if errors:
                print("failed: " + "; ".join(str(e) for e in errors))
            else:
                print("disabled" if p.get("enabled") is False else "ok")
            sys.exit(0)
    print("missing")
    sys.exit(0)
if cmd == "userdiff":
    sys.exit(userdiff(args[0], args[1], args[2], args[3:]))
if cmd == "overlap":
    print(overlap(args[0], args[1]))
    sys.exit(0)
sys.stderr.write("unpy: unknown subcommand %s\n" % cmd)
sys.exit(1)
PY
}

# Run from the installed copy's path (or a folder inside it), this script would move its own folder away.
case "$(unpy overlap "$KIT_DIR" "$COPY")" in
  is|inside)
    echo "uninstall.sh: this checkout ($KIT_DIR) is the installed copy's path $COPY, or inside it, and" >&2
    echo "uninstall moves that folder into the backup. Copy the kit elsewhere and run uninstall.sh from there." >&2
    echo "Nothing was changed." >&2
    exit 2 ;;
esac

# Which backup to restore from (none with --keep-files).
BACKUP=""
if [ "$KEEP" = 0 ]; then
  BACKUP="$ORIGINAL"
  if [ "$LATEST" = 1 ]; then
    newest="$(ls -1d "$BACKUPS"/workbench-[0-9]* 2>/dev/null | sort | tail -n 1)"
    [ -n "$newest" ] && BACKUP="$newest"   # with one install so far, the original is the newest
  fi
  [ -d "$BACKUP" ] || BACKUP=""
fi

# --latest goes back to the state before the last --apply. When the plugin was installed then (that backup's
# settings.json lists it), it stays installed; when that run re-synced the installed copy, install.sh moved the
# previous copy into the backup, and it comes back. COPY_PLAN: back (put that copy back), keep (the run did not
# touch the copy, or the plugin stays and runs from it) or away (move it into the backup folder).
PLUGIN_STAYS=0
BACKUP_ENABLED=""   # the enabledPlugins value for the plugin in that backup's settings.json
COPY_BACK=""
COPY_PLAN=away
if [ "$LATEST" = 1 ] && [ -n "$BACKUP" ] && [ "$BACKUP" != "$ORIGINAL" ]; then
  [ -f "$BACKUP/settings.json" ] && BACKUP_ENABLED="$(unpy listed "$BACKUP/settings.json")" && PLUGIN_STAYS=1
  if [ -d "$BACKUP/workbench-kit" ]; then
    COPY_BACK="$BACKUP/workbench-kit"; COPY_PLAN=back
  elif [ "$PLUGIN_STAYS" = 1 ] || [ ! -e "$BACKUP/workbench-kit.absent" ]; then
    COPY_PLAN=keep
  fi
fi

# What install.sh recorded for a file right after it wrote it (a sha256), or nothing.
record_hash() {
  case "$1" in
    settings.json) [ -f "$SETTINGS_RECORD" ] && cat "$SETTINGS_RECORD" ;;
    CLAUDE.md) [ -f "$CREATED/CLAUDE.md.sha256" ] && cat "$CREATED/CLAUDE.md.sha256" ;;
    agents/Explore.md) [ -f "$CREATED/agents/Explore.md" ] && sha256 "$CREATED/agents/Explore.md" ;;
  esac
  return 0
}
record_of() {
  case "$1" in
    settings.json) echo "$SETTINGS_RECORD" ;;
    CLAUDE.md) echo "$CREATED/CLAUDE.md.sha256" ;;
    *) echo "$CREATED/$1" ;;
  esac
}
# The file as the last install left it: install.sh's record, else, for CLAUDE.md and Explore.md (which
# install.sh never writes over a file it did not create), the backup copy. settings.json has no fallback.
post_install_hash() {
  r="$(record_hash "$1")"
  if [ -n "$r" ]; then echo "$r"
  elif [ "$1" != settings.json ] && [ -n "$BACKUP" ] && [ -f "$BACKUP/$1" ]; then sha256 "$BACKUP/$1"
  fi
}
changed_since_install() {
  p="$(post_install_hash "$1")"
  [ -n "$p" ] && [ "$(sha256 "$CLAUDE_DIR/$1")" != "$p" ]
}
# A file the backup marks as absent goes only if install.sh wrote it and it is unchanged since: settings.json
# always (it did not exist before; a copy is kept), CLAUDE.md and agents/Explore.md only while they match
# install.sh's record. Anything the user wrote or edited stays.
removable() {
  [ "$1" = settings.json ] && return 0
  r="$(record_hash "$1")"
  [ -n "$r" ] && [ "$(sha256 "$CLAUDE_DIR/$1")" = "$r" ]
}
# The settings.json keys and rules that changed since the backup and are not the kit's: the fragments install.sh
# recorded (now and in the backup) and the kit's own fragment count as the kit's, and so do the plugin entries.
nonkit_changes() {
  b=""; [ -f "$BACKUP/settings.json" ] && b="$BACKUP/settings.json"
  set --
  for f in "$FRAG_RECORD" "$BACKUP/workbench-created/settings.fragment.applied.json" "$KIT_DIR/user/settings.fragment.json"; do
    [ -f "$f" ] && set -- "$@" "$f"
  done
  unpy userdiff "$b" "$SETTINGS" "$HOME_DIR" "$@"
}

# Agents install.sh --replace-old moved into a backup: "agents/NAME<TAB>path under backups/". The default
# restore and --keep-files bring back all of them, --latest those moved into the backup it restores.
retired_lines() {
  [ -f "$RETIRED_RECORD" ] || return 0
  while IFS="$(printf '\t')" read -r live rel; do
    [ -n "$live" ] && [ -n "$rel" ] || continue
    if [ "$KEEP" = 1 ] || [ "$BACKUP" = "$ORIGINAL" ]; then
      printf '%s\t%s\n' "$live" "$rel"
    elif [ -n "$BACKUP" ]; then
      case "$BACKUPS/$rel" in "$BACKUP"/*) printf '%s\t%s\n' "$live" "$rel" ;; esac
    fi
  done < "$RETIRED_RECORD"
}
RETIRED="$(retired_lines)"

# The default restore and --keep-files end this install: the original backup and this cycle's timestamped
# backups are archived together, so the next install.sh --apply snapshots the files as they are then.
ARCHIVE_ORIGINAL=0
if [ -d "$ORIGINAL" ] && { [ "$KEEP" = 1 ] || [ "$BACKUP" = "$ORIGINAL" ]; }; then ARCHIVE_ORIGINAL=1; fi

echo "workbench uninstall"
[ "$DRY_RUN" = 1 ] && echo "  (dry run: nothing is changed)"
echo "  home:   $HOME_DIR"
echo "  config: $CLAUDE_DIR"
if [ "$PLUGIN_STAYS" = 1 ]; then
  echo "  plugin: $PLUGIN_ID and its marketplace stay installed (the backup's settings.json lists it with enabled: $BACKUP_ENABLED; it was installed before the last --apply)"
  [ "$BACKUP_ENABLED" = false ] && echo "    so the restored settings.json leaves it disabled, and its hooks stay off until you enable it"
elif [ "$CLI" = 1 ]; then
  echo "  plugin: claude plugin uninstall $PLUGIN_ID, then claude plugin marketplace remove workbench"
else
  echo "  plugin: the claude CLI is not on PATH; the /plugin steps to run in a session are printed"
fi
if [ -n "$BACKUP" ]; then SAVE_DIR="$BACKUP"
elif [ "$KEEP" = 1 ] && [ -d "$ORIGINAL" ]; then SAVE_DIR="$ORIGINAL"
else SAVE_DIR="$BACKUPS/workbench-uninstall-<timestamp>"
fi
case "$COPY_PLAN" in
  back)
    echo "  installed copy: put back from $COPY_BACK (the copy from before the last --apply)"
    { [ -e "$COPY" ] || [ -L "$COPY" ]; } && echo "    the current $COPY is moved into $SAVE_DIR first" ;;
  keep) [ -d "$COPY" ] && echo "  installed copy: $COPY stays (the last --apply did not re-sync it)" ;;
  away) [ -d "$COPY" ] && echo "  installed copy: $COPY will be moved into $SAVE_DIR" ;;
esac

show_changes() {
  [ -n "$1" ] || return 0
  echo "      changes since the backup that are not kit or plugin entries:"
  printf '%s\n' "$1"
}
HOOKS_BACK=""
if [ "$KEEP" = 1 ]; then
  echo "  files: settings.json, CLAUDE.md and agents/Explore.md stay as they are"
  if [ -f "$ORIGINAL/settings.json" ]; then
    HOOKS_BACK="$(unpy writeback "$ORIGINAL/settings.json" "$SETTINGS" plan)"
    rc=$?
    [ $rc = 0 ] || [ $rc = 10 ] || exit 1
  fi
  if [ -n "$HOOKS_BACK" ]; then
    echo "  old hook entries to write back into settings.json (from $ORIGINAL/settings.json):"
    echo "$HOOKS_BACK"
  else
    echo "  old hook entries: none to write back"
  fi
elif [ -n "$BACKUP" ]; then
  if [ "$BACKUP" = "$ORIGINAL" ]; then
    echo "  backup: $BACKUP (the state before the first install)"
  else
    echo "  backup: $BACKUP (the newest; the pre-workbench state is in $ORIGINAL)"
  fi
  for name in $NAMES; do
    cur="$CLAUDE_DIR/$name"
    ud=""
    if [ "$name" = settings.json ] && [ -f "$cur" ] && ! cmp -s "$cur" "$BACKUP/$name"; then ud="$(nonkit_changes)"; fi
    if [ -f "$BACKUP/$name" ]; then
      if [ ! -e "$cur" ]; then
        echo "    $cur is missing; it will be restored from the backup copy"
      elif cmp -s "$cur" "$BACKUP/$name"; then
        echo "    $cur matches the backup copy; it stays as it is"
      elif [ -n "$ud" ] || changed_since_install "$name"; then
        echo "    $cur will be OVERWRITTEN with the backup copy; it changed since install (those edits are kept only in the saved copy)"
        show_changes "$ud"
      elif [ -n "$(post_install_hash "$name")" ]; then
        echo "    $cur will be OVERWRITTEN with the backup copy (it is as install.sh left it)"
      else
        echo "    $cur will be OVERWRITTEN with the backup copy"
      fi
    elif [ -f "$BACKUP/$name.absent" ] && [ -e "$cur" ]; then
      r="$(record_hash "$name")"
      if [ "$name" = settings.json ]; then
        if [ -n "$r" ] && { [ -n "$ud" ] || [ "$(sha256 "$cur")" != "$r" ]; }; then
          echo "    $cur was written by install.sh and changed since install; it will be moved into the backup folder (your edits are kept only in that copy)"
        elif [ -n "$r" ]; then
          echo "    $cur was written by install.sh and is unchanged since; it will be moved into the backup folder"
        else
          echo "    $cur did not exist before the install; it will be moved into the backup folder (a copy is kept there)"
        fi
        show_changes "$ud"
      elif [ -n "$r" ] && [ "$(sha256 "$cur")" = "$r" ]; then
        echo "    $cur was written by install.sh and is unchanged since; it will be moved into the backup folder"
      elif [ -n "$r" ]; then
        echo "    $cur was written by install.sh and changed since install; it stays"
      else
        echo "    $cur was not written by install.sh; it stays"
      fi
    fi
  done
  echo "    the current files are saved in the backup folder as <name>.before-uninstall-<timestamp> first"
  if [ -d "$BACKUP/workbench-created" ] && [ "$BACKUP" != "$ORIGINAL" ]; then
    echo "  install records ($CREATED): put back as they were in the backup"
  elif [ -d "$CREATED" ]; then
    echo "  install records ($CREATED): removed where they no longer apply"
  fi
else
  echo "  no workbench backup in $BACKUPS; settings.json, CLAUDE.md and agents/Explore.md stay as they are"
fi
if [ -n "$RETIRED" ]; then
  echo "  agents that install.sh --replace-old retired:"
  printf '%s\n' "$RETIRED" | while IFS="$(printf '\t')" read -r live rel; do
    if [ -e "$CLAUDE_DIR/$live" ]; then
      echo "    $CLAUDE_DIR/$live exists again; it stays (the retired copy is $BACKUPS/$rel)"
    elif [ -f "$BACKUPS/$rel" ]; then
      echo "    $CLAUDE_DIR/$live will be restored from $BACKUPS/$rel"
    else
      echo "    $CLAUDE_DIR/$live: its retired copy $BACKUPS/$rel is missing, so it cannot be restored"
    fi
  done
fi
[ "$ARCHIVE_ORIGINAL" = 1 ] && echo "  backups: $ORIGINAL and the timestamped backups are archived as workbench-original.restored-<timestamp>, so a later install takes a fresh snapshot"

if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: nothing changed."
  exit 0
fi
if [ "$YES" = 0 ]; then
  if [ -t 0 ]; then
    printf "Go ahead? [y/N] "
    answer=""
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES|Yes) ;;
      *) echo "Nothing changed."; exit 0 ;;
    esac
  else
    echo "No terminal to ask on, so nothing changed. Re-run with --yes to go ahead."
    exit 0
  fi
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
[ -n "$BACKUP" ] || { [ "$KEEP" = 1 ] && [ -d "$ORIGINAL" ]; } || SAVE_DIR="$BACKUPS/workbench-uninstall-$STAMP"
mkdir -p "$SAVE_DIR/agents" || die "cannot write to $SAVE_DIR; nothing was changed"
for name in $NAMES; do
  [ -e "$CLAUDE_DIR/$name" ] || continue
  cp -p "$CLAUDE_DIR/$name" "$SAVE_DIR/$name.before-uninstall-$STAMP" \
    || die "could not save the current $name; nothing was changed"
done
# The copy to put back is built next to the live one first, so the swap below is two renames.
COPY_TMP=""
if [ -n "$COPY_BACK" ]; then
  COPY_TMP="$CLAUDE_DIR/.workbench-kit.tmp-$$"
  rm -rf "$COPY_TMP"
  cp -Rp "$COPY_BACK" "$COPY_TMP" || { rm -rf "$COPY_TMP"; die "could not copy $COPY_BACK; nothing else was changed"; }
fi

if [ "$PLUGIN_STAYS" = 1 ]; then
  :
elif [ "$CLI" = 1 ]; then
  cli plugin uninstall "$PLUGIN_ID" || echo "  (plugin uninstall reported an error; it may not have been installed)"
  cli plugin marketplace remove workbench || echo "  (marketplace remove reported an error; it may not have been added)"
else
  echo "The claude CLI is not on PATH. In a Claude Code session run:"
  echo "    /plugin uninstall $PLUGIN_ID"
  echo "    /plugin marketplace remove workbench"
fi

if [ -n "$COPY_TMP" ]; then
  moved=1
  if [ -e "$COPY" ] || [ -L "$COPY" ]; then
    mv "$COPY" "$SAVE_DIR/workbench-kit.before-uninstall-$STAMP" || moved=0
  fi
  if [ "$moved" = 1 ] && mv "$COPY_TMP" "$COPY"; then
    echo "Put back the installed copy from $COPY_BACK (the replaced one is in $SAVE_DIR)"
  else
    echo "  (could not put $COPY_BACK back at $COPY; it is still in the backup, and $COPY_TMP holds a copy)" >&2
  fi
elif [ "$COPY_PLAN" = away ] && [ -d "$COPY" ]; then
  mv "$COPY" "$SAVE_DIR/workbench-kit.before-uninstall-$STAMP" \
    && echo "Moved the installed copy $COPY into $SAVE_DIR" \
    || echo "  (could not move $COPY into $SAVE_DIR; remove it by hand)" >&2
fi

restore_retired() {
  [ -n "$RETIRED" ] || return 0
  printf '%s\n' "$RETIRED" | while IFS="$(printf '\t')" read -r live rel; do
    if [ -e "$CLAUDE_DIR/$live" ]; then
      echo "Left $CLAUDE_DIR/$live in place (it exists again; the retired copy is $BACKUPS/$rel)"
    elif [ -f "$BACKUPS/$rel" ]; then
      mkdir -p "$(dirname "$CLAUDE_DIR/$live")" && cp -p "$BACKUPS/$rel" "$CLAUDE_DIR/$live" \
        && echo "Restored $CLAUDE_DIR/$live (retired by install.sh --replace-old)"
    fi
  done
}
drop_empty_records() {
  [ -d "$CREATED/agents" ] && rmdir "$CREATED/agents" 2>/dev/null
  [ -d "$CREATED" ] && rmdir "$CREATED" 2>/dev/null
  return 0
}
archive_original() {
  ARCHIVE="$ORIGINAL.restored-$STAMP"
  n=2
  while [ -e "$ARCHIVE" ]; do ARCHIVE="$ORIGINAL.restored-$STAMP-$n"; n=$((n + 1)); done
  mv "$ORIGINAL" "$ARCHIVE" || die "could not rename $ORIGINAL; rename it before the next install"
  for d in "$BACKUPS"/workbench-[0-9]*; do
    [ -d "$d" ] && { mv "$d" "$ARCHIVE/" || echo "  (could not move $d into $ARCHIVE)"; }
  done
  echo "Archived this install's backups in $ARCHIVE (the pre-uninstall copies and the installed copy are there too)"
}

if [ "$KEEP" = 1 ]; then
  if [ -n "$HOOKS_BACK" ]; then
    out="$(unpy writeback "$ORIGINAL/settings.json" "$SETTINGS" apply)"
    rc=$?
    if [ $rc = 10 ]; then echo "Wrote the old hook entries back into $SETTINGS:"; echo "$out"
    else echo "  (could not write the old hook entries back into $SETTINGS)" >&2; fi
  fi
  restore_retired
  # settings.json is no longer as install.sh left it (the plugin is out); the fragment record stays, so a later
  # install still leaves out the kit entries you removed.
  rm -f "$RETIRED_RECORD" "$SETTINGS_RECORD"
  drop_empty_records
  [ "$ARCHIVE_ORIGINAL" = 1 ] && archive_original
elif [ -n "$BACKUP" ]; then
  for name in $NAMES; do
    if [ -f "$BACKUP/$name" ]; then
      cmp -s "$BACKUP/$name" "$CLAUDE_DIR/$name" && continue   # matches the backup copy; the plan says it stays
      mkdir -p "$(dirname "$CLAUDE_DIR/$name")"
      # cp writes through a symlinked dotfile instead of replacing the link
      cp "$BACKUP/$name" "$CLAUDE_DIR/$name" || die "restoring $name failed; the pre-uninstall copy is in $SAVE_DIR"
      echo "Restored $CLAUDE_DIR/$name"
    elif [ -f "$BACKUP/$name.absent" ] && [ -e "$CLAUDE_DIR/$name" ]; then
      if removable "$name"; then
        rm -f "$CLAUDE_DIR/$name"   # its copy was saved above as $name.before-uninstall-$STAMP
        rm -f "$(record_of "$name")"
        echo "Moved $CLAUDE_DIR/$name aside (it did not exist before the install; a copy is kept as $name.before-uninstall-$STAMP)"
      else
        echo "Left $CLAUDE_DIR/$name in place (not written by install.sh, or changed since install)"
      fi
    fi
  done
  restore_retired
  if [ "$BACKUP" = "$ORIGINAL" ]; then
    # Back to the pre-kit state: the records of what install.sh wrote no longer apply, so the next install
    # starts with a full merge and a fresh snapshot.
    rm -f "$FRAG_RECORD" "$SETTINGS_RECORD" "$RETIRED_RECORD"
  elif [ -d "$BACKUP/workbench-created" ]; then
    rm -rf "$CREATED" && cp -Rp "$BACKUP/workbench-created" "$CREATED" \
      && echo "Put install.sh's records back as they were in $BACKUP"
  elif [ -f "$BACKUP/workbench-created.absent" ]; then
    rm -rf "$CREATED"
  fi
  drop_empty_records
  # The original is used up: archive it with this cycle's timestamped backups, so the next install.sh --apply
  # snapshots the state as it is then, and --latest never reaches back into an earlier cycle.
  [ "$ARCHIVE_ORIGINAL" = 1 ] && archive_original
fi

# --latest kept the plugin: say what claude plugin list now shows, not what the backup implies.
report_plugin() {
  if [ "$CLI" = 0 ]; then
    echo "The plugin $PLUGIN_ID was left installed (the restored settings.json has enabled: $BACKUP_ENABLED); the claude"
    echo "  CLI is not on PATH, so whether it loads is unchecked: /plugin in a session shows it."
    return 0
  fi
  st="$(unpy state "$(cli plugin list --json 2>/dev/null)")"
  case "$st" in
    ok) echo "The plugin $PLUGIN_ID is enabled and loads (claude plugin list shows no errors); run /reload-plugins in open sessions." ;;
    disabled)
      was=""; [ "$BACKUP_ENABLED" = false ] && was=", as it was before the last --apply"
      echo "The plugin $PLUGIN_ID is installed but disabled$was, so no workbench hook runs."
      echo "  claude plugin enable $PLUGIN_ID --scope user turns the hooks on." ;;
    missing)
      echo "The plugin $PLUGIN_ID is not installed, so no workbench hook runs."
      echo "  Run bash $KIT_DIR/install.sh --apply to set it up again." ;;
    failed*)
      echo "The plugin $PLUGIN_ID is installed but fails to load, so no workbench hook runs: ${st#failed: }"
      echo "  Fix that in the checkout, then run bash $KIT_DIR/install.sh --apply." ;;
    *) echo "claude plugin list did not run, so the state of the plugin $PLUGIN_ID is unchecked." ;;
  esac
}
[ "$PLUGIN_STAYS" = 1 ] && report_plugin
echo "Kept: $WB_JSON, memory folders, audits and every backup."
exit 0
