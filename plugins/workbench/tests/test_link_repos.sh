#!/bin/bash
# Sandbox test for skills/link-repos/link_repos.py. Never touches the real HOME, ~/.claude or ~/.claude.json:
# HOME points at a temp dir and every repo is a temp git repo under /tmp/workbench-test-*. Bash 3.2 compatible.
# Conditions are single-quoted and run through eval by check(), so the variables they use look unused to shellcheck,
# and "~/..." is a literal the script under test expands itself.
# shellcheck disable=SC2016,SC2034,SC2088
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
LINK="$HERE/../skills/link-repos/link_repos.py"
PY="/usr/bin/env python3 -I"

TMP=$(mktemp -d /tmp/workbench-test-link.XXXXXX) || exit 1
TMP=$(cd "$TMP" && pwd -P)   # physical path (macOS /tmp is a symlink); the script records real paths
cleanup() { case "$TMP" in */workbench-test-link.*) rm -rf "$TMP" ;; esac; }   # only this run's own dir
trap cleanup EXIT

export HOME="$TMP/home"
unset WORKBENCH_CONFIG XDG_CONFIG_HOME GIT_DIR GIT_WORK_TREE
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "ok   $1"; }
bad()  { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }   # $1 name, $2 shell condition

mkrepo() {  # $1 dir; remaining args: files to create and commit
  local dir=$1; shift
  mkdir -p "$dir"
  git -C "$dir" -c init.defaultBranch=main init -q
  local f
  for f in "$@"; do mkdir -p "$(dirname "$dir/$f")"; echo "# $f of $(basename "$dir")" > "$dir/$f"; done
  git -C "$dir" add -A
  git -C "$dir" -c commit.gpgsign=false commit -q --allow-empty -m init
}

# Snapshot every file under a dir (path, size, mtime_ns, sha256), skipping .git internals except info/exclude.
snapshot() {
  $PY - "$1" <<'EOF'
import hashlib, os, sys
root = sys.argv[1]
walk = [(os.path.dirname(root), [], [os.path.basename(root)])] if os.path.isfile(root) else os.walk(root)
for base, dirs, files in walk:
    if ".git" in dirs:
        dirs.remove(".git")
        ex = os.path.join(base, ".git", "info", "exclude")
        if os.path.isfile(ex):
            files = files + [os.path.join(".git", "info", "exclude")]
    for name in sorted(files):
        p = os.path.join(base, name)
        if os.path.islink(p):
            print(p, "->", os.readlink(p)); continue
        st = os.stat(p)
        print(p, st.st_size, st.st_mtime_ns, oct(st.st_mode), hashlib.sha256(open(p, "rb").read()).hexdigest())
    dirs.sort()
EOF
}

# Evaluate a Python expression with `d` bound to the parsed JSON file $1; exit 0 when truthy.
jtrue() {
  $PY - "$1" "$2" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)
EOF
}

R="$TMP/repos"
A="$R/alpha"; B="$R/beta"; C="$R/gamma"
mkrepo "$A" CLAUDE.md
mkrepo "$B" CLAUDE.md CLAUDE.local.md
mkrepo "$C"
# B's CLAUDE.local.md is committed above only so the tree starts clean; git still records it as tracked, which is
# fine: link_repos reads siblings' files, it never writes CLAUDE.local.md.

# Existing user settings in alpha that must survive the merge (left untracked, so ignore it via exclude first).
mkdir -p "$A/.claude"
printf '{\n  "model": "sonnet",\n  "permissions": {\n    "allow": ["Bash(ls *)"],\n    "additionalDirectories": ["/existing/dir"]\n  }\n}\n' > "$A/.claude/settings.local.json"
echo ".claude/settings.local.json" >> "$A/.git/info/exclude"
chmod 640 "$A/.claude/settings.local.json"
umask 022

# Sandbox ~/.claude.json with unrelated keys that must survive.
cat > "$HOME/.claude.json" <<EOF
{
  "numStartups": 3,
  "projects": {
    "/some/other/project": {"allowedTools": ["Read"]},
    "$A": {"hasTrustDialogAccepted": true}
  }
}
EOF
chmod 600 "$HOME/.claude.json"

MEM="~/mem/test-memory"
link() { $PY "$LINK" --home "$HOME" "$@"; }

# 1. dry run writes nothing
before=$(snapshot "$TMP")
out=$(link --group test --memory-dir "$MEM" "$A" "$B" "$C" 2>&1); rc=$?
after=$(snapshot "$TMP")
check "dry run exits 0" '[ $rc -eq 0 ]'
check "dry run writes nothing" '[ "$before" = "$after" ]'
check "dry run says nothing written" 'echo "$out" | grep -q "Dry run: nothing written"'
check "dry run lists planned settings merge" 'echo "$out" | grep -q "permissions.additionalDirectories += \"$B\""'
check "dry run lists rule imports" 'echo "$out" | grep -q "| @$B/CLAUDE.local.md"'
check "dry run hints at import approval" 'echo "$out" | grep -q "approve-imports"'
check "memory dir not created by dry run" '[ ! -e "$HOME/mem" ]'

# 2. apply creates the expected files and settings
cj_before=$(snapshot "$HOME/.claude.json")
out=$(link --group test --memory-dir "$MEM" "$A" "$B" "$C" --apply 2>&1); rc=$?
check "apply exits 0" '[ $rc -eq 0 ]'
check "apply reports applied" 'echo "$out" | grep -q "change(s) applied"'
SA="$A/.claude/settings.local.json"; SB="$B/.claude/settings.local.json"; SC="$C/.claude/settings.local.json"
check "alpha keeps model key" 'jtrue "$SA" "d[\"model\"] == \"sonnet\""'
check "alpha keeps allow rules" 'jtrue "$SA" "d[\"permissions\"][\"allow\"] == [\"Bash(ls *)\"]"'
check "alpha dirs: existing kept, siblings added once, in order" \
  'jtrue "$SA" "d[\"permissions\"][\"additionalDirectories\"] == [\"/existing/dir\", \"$B\", \"$C\"]"'
check "alpha memory dir in ~/ form" 'jtrue "$SA" "d[\"autoMemoryDirectory\"] == \"~/mem/test-memory\""'
check "merged settings keep their file mode (0640)" '[ "$(ls -l "$SA" | cut -c1-10)" = "-rw-r-----" ]'
check "new files get the umask default (0644)" '[ "$(ls -l "$SB" | cut -c1-10)" = "-rw-r--r--" ]'
check "beta settings list alpha and gamma" 'jtrue "$SB" "d[\"permissions\"][\"additionalDirectories\"] == [\"$A\", \"$C\"]"'
check "gamma settings has memory dir" 'jtrue "$SC" "d[\"autoMemoryDirectory\"] == \"~/mem/test-memory\""'

RA="$A/.claude/rules/linked-repos.md"; RB="$B/.claude/rules/linked-repos.md"; RC="$C/.claude/rules/linked-repos.md"
check "alpha rule imports beta CLAUDE.md" 'grep -qx "@$B/CLAUDE.md" "$RA"'
check "alpha rule imports beta CLAUDE.local.md" 'grep -qx "@$B/CLAUDE.local.md" "$RA"'
check "alpha rule has no gamma import (gamma has no files)" '! grep -q "^@$C/" "$RA"'
check "gamma rule imports alpha and beta" 'grep -qx "@$A/CLAUDE.md" "$RC" && grep -qx "@$B/CLAUDE.md" "$RC" && grep -qx "@$B/CLAUDE.local.md" "$RC"'
check "gamma rule skips missing alpha CLAUDE.local.md" '! grep -q "^@$A/CLAUDE.local.md" "$RC"'
check "no rule imports itself" '! grep -q "^@$A/" "$RA" && ! grep -q "^@$B/" "$RB"'
check "no rule imports a linked-repos.md (no cycles)" '! grep -h "^@" "$RA" "$RB" "$RC" | grep -q "linked-repos.md"'
check "every import line is absolute, one per line" '! grep -h "@" "$RA" "$RB" "$RC" | grep -v "^@/[^ ]*$" | grep -q "^@"'
check "exclude has rule, CLAUDE.local.md, .worktreeinclude" \
  '( for f in .claude/rules/linked-repos.md CLAUDE.local.md .worktreeinclude; do grep -qx "$f" "$C/.git/info/exclude" || exit 1; done )'
check "alpha exclude has no duplicate settings line" '[ $(grep -cx ".claude/settings.local.json" "$A/.git/info/exclude") -eq 1 ]'
check "repos stay clean in git status" \
  '[ -z "$(git -C "$A" status --porcelain)" ] && [ -z "$(git -C "$B" status --porcelain)" ] && [ -z "$(git -C "$C" status --porcelain)" ]'
check "worktreeinclude has both lines" 'grep -qx "CLAUDE.local.md" "$C/.worktreeinclude" && grep -qx ".claude/rules/linked-repos.md" "$C/.worktreeinclude"'
check "worktreeinclude has no .env line" '! grep -qx ".env" "$A/.worktreeinclude" "$B/.worktreeinclude" "$C/.worktreeinclude"'
check "memory index created" '[ -f "$HOME/mem/test-memory/MEMORY.md" ] && grep -q "Memory Index" "$HOME/mem/test-memory/MEMORY.md"'
check ".claude.json untouched without --approve-imports" '[ "$cj_before" = "$(snapshot "$HOME/.claude.json")" ]'

# 3. a second apply changes nothing
before=$(snapshot "$TMP")
out=$(link --group test --memory-dir "$MEM" "$A" "$B" "$C" --apply 2>&1); rc=$?
after=$(snapshot "$TMP")
check "second apply exits 0" '[ $rc -eq 0 ]'
check "second apply reports 0 changes" 'echo "$out" | grep -q "Summary: 0 change(s) applied"'
check "second apply leaves every file byte- and mtime-identical" '[ "$before" = "$after" ]'

# 4. --from-config reads the same group and finds nothing to do
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/workbench.json" <<EOF
{"repo_groups": [{"name": "test", "memory_dir": "~/mem/test-memory", "repos": ["$A", "$B", "$C"]}]}
EOF
out=$(link --from-config test 2>&1); rc=$?
check "--from-config dry run exits 0 with 0 changes" '[ $rc -eq 0 ] && echo "$out" | grep -q "Summary: 0 change(s) planned"'
out=$(link --from-config nope 2>&1); rc=$?
check "--from-config unknown group refused" '[ $rc -eq 2 ]'
cat > "$TMP/alt-config.json" <<EOF
{"repo_groups": [{"name": "alt", "memory_dir": "~/mem/test-memory", "repos": ["$A", "$B", "$C"]}]}
EOF
out=$(WORKBENCH_CONFIG="$TMP/alt-config.json" link --from-config alt 2>&1); rc=$?
check "WORKBENCH_CONFIG overrides the config path" '[ $rc -eq 0 ] && echo "$out" | grep -q "^Group alt: 3 repos"'
out=$(link --from-config alt 2>&1); rc=$?
check "without WORKBENCH_CONFIG the default config is read" '[ $rc -eq 2 ] && echo "$out" | grep -q "workbench.json"'

# 5. --approve-imports sets the flags and keeps every other key and the 0600 mode
out=$(link --group test --memory-dir "$MEM" "$A" "$B" "$C" --apply --approve-imports 2>&1); rc=$?
CJ="$HOME/.claude.json"
check "approve-imports exits 0" '[ $rc -eq 0 ]'
check "approval flags set for all three" \
  'jtrue "$CJ" "all(d[\"projects\"][p].get(k) is True for p in [\"$A\", \"$B\", \"$C\"] for k in [\"hasClaudeMdExternalIncludesApproved\", \"hasClaudeMdExternalIncludesWarningShown\"])"'
check "other top-level keys kept" 'jtrue "$CJ" "d[\"numStartups\"] == 3"'
check "other project entry kept" 'jtrue "$CJ" "d[\"projects\"][\"/some/other/project\"] == {\"allowedTools\": [\"Read\"]}"'
check "existing project keys kept" 'jtrue "$CJ" "d[\"projects\"][\"$A\"][\"hasTrustDialogAccepted\"] is True"'
check ".claude.json mode stays 0600" '[ "$(ls -l "$CJ" | cut -c1-10)" = "-rw-------" ]'
check "no temp files left in HOME" '[ -z "$(ls -a "$HOME" | grep "\.tmp$")" ]'
before=$(snapshot "$TMP")
out=$(link --group test --memory-dir "$MEM" "$A" "$B" "$C" --apply --approve-imports 2>&1); rc=$?
check "approve-imports again is a no-op" '[ $rc -eq 0 ] && [ "$before" = "$(snapshot "$TMP")" ] && echo "$out" | grep -q "Summary: 0 change"'

# 6. refusals (exit 2, nothing written)
git -C "$A" worktree add -q "$TMP/alpha-wt" -b wt-branch 2>/dev/null
before=$(snapshot "$TMP")
out=$(link --group test "$TMP/alpha-wt" "$B" --apply 2>&1); rc=$?
check "linked worktree refused with exit 2" '[ $rc -eq 2 ] && echo "$out" | grep -q "primary checkout"'
check "refused worktree run wrote nothing" '[ "$before" = "$(snapshot "$TMP")" ]'
mkdir -p "$TMP/plain"
out=$(link --group test "$TMP/plain" "$B" --apply 2>&1); rc=$?
check "non-git dir refused with exit 2" '[ $rc -eq 2 ]'
out=$(link --group test "$A/.claude" "$B" --apply 2>&1); rc=$?
check "subdirectory of a repo refused with exit 2" '[ $rc -eq 2 ]'
out=$(link --group test "$A" --apply 2>&1); rc=$?
check "one repo refused with exit 2" '[ $rc -eq 2 ] && echo "$out" | grep -q "at least two"'
out=$(link --group test "$A" "$A/" --apply 2>&1); rc=$?
check "same repo twice refused with exit 2" '[ $rc -eq 2 ]'
check "refusals wrote nothing" '[ "$before" = "$(snapshot "$TMP")" ]'

# 7. symlinks that leave the repo are never followed
mkrepo "$R/delta"; mkrepo "$R/epsilon"
mkdir -p "$TMP/outside"
ln -s "$TMP/outside" "$R/delta/.claude"
before=$(snapshot "$TMP")
out=$(link --group sym "$R/delta" "$R/epsilon" --apply 2>&1); rc=$?
check "symlinked .claude pointing outside refused" '[ $rc -eq 2 ] && echo "$out" | grep -q "outside the repo"'
check "nothing written through or beside the symlink" '[ "$before" = "$(snapshot "$TMP")" ] && [ -z "$(ls -A "$TMP/outside")" ]'
rm "$R/delta/.claude"
mkdir -p "$TMP/home2"
echo '{"keep": 1}' > "$TMP/real-claude.json"; chmod 600 "$TMP/real-claude.json"
ln -s "$TMP/real-claude.json" "$TMP/home2/.claude.json"
out=$($PY "$LINK" --home "$TMP/home2" --group sym "$R/delta" "$R/epsilon" --apply --approve-imports 2>&1); rc=$?
check "symlinked .claude.json refused" '[ $rc -eq 2 ] && [ -L "$TMP/home2/.claude.json" ] && [ "$(cat "$TMP/real-claude.json")" = "{\"keep\": 1}" ]'
check "refusal happened before any repo write" '[ ! -e "$R/delta/.claude" ] && [ ! -e "$R/epsilon/.worktreeinclude" ]'

# 8. tracked team files are left alone; unparsable settings are not clobbered
mkrepo "$R/zeta" .worktreeinclude; mkrepo "$R/eta"
wti_before=$(cat "$R/zeta/.worktreeinclude")
out=$(link --group team "$R/zeta" "$R/eta" --apply 2>&1); rc=$?
check "tracked .worktreeinclude left unchanged" '[ $rc -eq 0 ] && [ "$wti_before" = "$(cat "$R/zeta/.worktreeinclude")" ] && echo "$out" | grep -q "tracked by git"'
check "tracked-file repo still clean" '[ -z "$(git -C "$R/zeta" status --porcelain)" ]'
mkdir -p "$R/eta/.claude"; echo '{not json' > "$R/eta/.claude/settings.local.json"
out=$(link --group team "$R/zeta" "$R/eta" --apply 2>&1); rc=$?
check "unparsable settings refused, file kept" '[ $rc -eq 2 ] && [ "$(cat "$R/eta/.claude/settings.local.json")" = "{not json" ]'

# 9. paths with spaces are escaped in imports
mkrepo "$R/with space" CLAUDE.md; mkrepo "$R/theta"
out=$(link --group sp "$R/with space" "$R/theta" --apply 2>&1); rc=$?
check "import path with a space is backslash-escaped" '[ $rc -eq 0 ] && grep -qxF "@$R/with\\ space/CLAUDE.md" "$R/theta/.claude/rules/linked-repos.md"'
check "escaped sibling import is recognized as the bridge, not external" '! echo "$out" | grep -q "^\[external\]"'

# 10. external imports: listed in every plan; --approve-imports refuses (exit 3) until --allow-external names each
I="$R/iota"; K="$R/kappa"
mkrepo "$I"; mkrepo "$K"
mkdir -p "$I/docs" "$I/.claude/rules" "$K/.claude/rules" "$K/sub" "$HOME/.aws"
printf '%s\n' '# iota' 'See @docs/inside.md for the layout.' 'Keys live in @~/.aws/credentials.' \
  'Mention without importing: `@~/in-span.md`.' 'Mail someone@example.com about it.' \
  "Hand-built bridge: @$K/CLAUDE.md" '```' '@/etc/in-fence.md' '```' > "$I/CLAUDE.md"
printf '%s\n' 'Nested: @~/nested-secret.md' 'Shared: @shared.md' > "$I/docs/inside.md"
echo 'shared notes' > "$TMP/outside-shared.md"
ln -s "$TMP/outside-shared.md" "$I/docs/shared.md"
echo 'Old: @~/stale.md' > "$I/.claude/rules/linked-repos.md"   # stale generated rule; it gets rewritten
echo '# kappa' > "$K/CLAUDE.md"
echo 'Team rules: @../../../shared/team-rules.md' > "$K/.claude/rules/team.md"
echo "Sub: @$TMP/nested-target.md" > "$K/sub/CLAUDE.md"
echo 'Mine: @~/personal.md' > "$K/CLAUDE.local.md"
echo 'outside rule' > "$TMP/outside-rule.md"
ln -s "$TMP/outside-rule.md" "$K/.claude/rules/link.md"
git -C "$K" add CLAUDE.md sub/CLAUDE.md .claude/rules/team.md
git -C "$K" -c commit.gpgsign=false commit -q -m ext
printf '%s\n' '[default]' 'aws_secret_access_key = SECRETVALUE123 @~/never-read.md' > "$HOME/.aws/credentials"
chmod 600 "$HOME/.aws/credentials"
ALLOW_SOME=(--allow-external "~/.aws/credentials" --allow-external "~/nested-secret.md"
  --allow-external "$TMP/outside-shared.md" --allow-external "$R/shared/team-rules.md"
  --allow-external "$TMP/outside-rule.md" --allow-external "$TMP/nested-target.md")
ext_lines() { echo "$out" | grep '^\[external\]'; }

before=$(snapshot "$TMP")
out=$(link --group ext "$I" "$K" 2>&1); rc=$?
check "ext: dry run without --approve-imports exits 0 and writes nothing" '[ $rc -eq 0 ] && [ "$before" = "$(snapshot "$TMP")" ]'
check "ext: exactly 7 [external] lines" '[ "$(ext_lines | wc -l | tr -d " ")" -eq 7 ]'
check "ext: home import listed with file:line and resolved target" \
  'ext_lines | grep -qF "[external] $I/CLAUDE.md:3: @~/.aws/credentials. -> $HOME/.aws/credentials"'
check "ext: import reached through an in-repo import is listed (missing now)" \
  'ext_lines | grep -F "$I/docs/inside.md:1: @~/nested-secret.md -> $HOME/nested-secret.md" | grep -q "missing now"'
check "ext: in-repo symlink to an outside file is listed by its real target" \
  'ext_lines | grep -qF "$I/docs/inside.md:2: @shared.md -> $TMP/outside-shared.md"'
check "ext: relative ../ import in a rule file is listed" 'ext_lines | grep -qF "$K/.claude/rules/team.md:1: @../../../shared/team-rules.md -> $R/shared/team-rules.md"'
check "ext: rule symlink leaving the repo is listed" 'ext_lines | grep -qF "$K/.claude/rules/link.md: symlink -> $TMP/outside-rule.md"'
check "ext: tracked nested CLAUDE.md is scanned" 'ext_lines | grep -qF "$K/sub/CLAUDE.md:1: @$TMP/nested-target.md -> $TMP/nested-target.md"'
check "ext: CLAUDE.local.md is scanned" 'ext_lines | grep -qF "$K/CLAUDE.local.md:1: @~/personal.md -> $HOME/personal.md"'
check "ext: code span, fence, e-mail, bridge and stale rule are not listed" \
  '! ext_lines | grep -qE "in-span|in-fence|example.com|stale.md|-> $K/CLAUDE.md|-> $I/CLAUDE.md|linked-repos.md"'
check "ext: outside files are never opened (secret not printed)" '! echo "$out" | grep -qE "SECRETVALUE123|never-read"'
check "ext: plan hints that --approve-imports needs --allow-external" 'echo "$out" | grep -q "refuses until --allow-external names each target"'

before=$(snapshot "$TMP")
out=$(link --group ext "$I" "$K" --approve-imports 2>&1); rc=$?
check "ext: dry run with --approve-imports refuses with exit 3" '[ $rc -eq 3 ] && echo "$out" | grep -q "^refused: --approve-imports would also approve 7 external"'
check "ext: refused dry run still lists the plan" '[ "$(ext_lines | wc -l | tr -d " ")" -eq 7 ] && echo "$out" | grep -q "set hasClaudeMdExternalIncludesApproved"'
out=$(link --group ext "$I" "$K" --apply --approve-imports "${ALLOW_SOME[@]}" 2>&1); rc=$?
check "ext: --apply with one target not allowed refuses with exit 3" '[ $rc -eq 3 ] && echo "$out" | grep -q "approve 1 external"'
check "ext: refused runs wrote nothing (repos, memory, .claude.json)" '[ "$before" = "$(snapshot "$TMP")" ]'

out=$(link --group ext "$I" "$K" --apply --approve-imports "${ALLOW_SOME[@]}" --allow-external "~/personal.md" \
  --allow-external "~/not-imported.md" 2>&1); rc=$?
check "ext: every target allowed: apply exits 0" '[ $rc -eq 0 ] && echo "$out" | grep -q "change(s) applied"'
check "ext: each [external] line is marked allowed" '[ "$(ext_lines | grep -c "allowed by --allow-external")" -eq 7 ]'
check "ext: an --allow-external that matches nothing is noted" 'echo "$out" | grep -q "note: --allow-external ~/not-imported.md matches no"'
check "ext: approval flags set for iota and kappa" \
  'jtrue "$CJ" "all(d[\"projects\"][p].get(k) is True for p in [\"$I\", \"$K\"] for k in [\"hasClaudeMdExternalIncludesApproved\", \"hasClaudeMdExternalIncludesWarningShown\"])"'
check "ext: earlier projects and keys kept" 'jtrue "$CJ" "d[\"numStartups\"] == 3 and d[\"projects\"][\"$A\"][\"hasTrustDialogAccepted\"] is True"'
check "ext: stale rule rewritten without the old import" '! grep -q "stale.md" "$I/.claude/rules/linked-repos.md" && grep -qx "@$K/CLAUDE.md" "$I/.claude/rules/linked-repos.md"'

before=$(snapshot "$TMP")
out=$(link --group ext "$I" "$K" 2>&1); rc=$?
check "ext: after approval, a plain dry run warns the imports load without asking" \
  '[ $rc -eq 0 ] && [ "$(ext_lines | grep -c "approval is already recorded")" -eq 7 ]'
out=$(link --group ext "$I" "$K" --apply --approve-imports 2>&1); rc=$?
check "ext: recorded approval does not bypass the refusal" '[ $rc -eq 3 ] && [ "$before" = "$(snapshot "$TMP")" ]'
out=$(link --group ext "$I" "$K" --apply --approve-imports "${ALLOW_SOME[@]}" --allow-external "~/personal.md" 2>&1); rc=$?
check "ext: second fully allowed apply is a no-op" '[ $rc -eq 0 ] && echo "$out" | grep -q "Summary: 0 change" && [ "$before" = "$(snapshot "$TMP")" ]'

# 11. S1: skills call the script by path; no skill body runs python (the guard hook refuses it in uv repos)
SK="$HERE/../skills"
py_calls() { grep -nE '(^|[`$(;|&])[[:space:]]*(/usr/bin/env[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?python[0-9.]*([[:space:]]|$)|env[[:space:]]+(-[A-Za-z]+[[:space:]]+)*python|json\.tool' "$SK/link-repos/SKILL.md" "$SK/config-audit/SKILL.md"; }
check "S1: neither SKILL.md runs python/python3/env python3/json.tool" '! py_calls'
check "S1: py_calls detector catches the old form" 'echo "   /usr/bin/env python3 -I \"\${X}/link_repos.py\" --group a" | grep -qE "env[[:space:]]+(-[A-Za-z]+[[:space:]]+)*python"'
check "S1: link-repos SKILL.md calls the script by path" 'grep -qE "^ +\"\\$\{CLAUDE_SKILL_DIR\}/link_repos.py\" --group" "$SK/link-repos/SKILL.md"'
check "S1: config-audit SKILL.md calls the script by path" 'grep -qE "^ +\"\\$\{CLAUDE_PLUGIN_ROOT\}/skills/link-repos/link_repos.py\" --from-config" "$SK/config-audit/SKILL.md"'
check "S1: config-audit checks JSON with jq" 'grep -q "jq empty" "$SK/config-audit/SKILL.md"'
check "S1: link_repos.py keeps its exec bit and isolated shebang" '[ -x "$LINK" ] && [ "$(head -1 "$LINK")" = "#!/usr/bin/env -S python3 -I" ]'
out=$("$LINK" --home "$HOME" --group direct "$A" "$B" 2>&1); rc=$?
check "S1: the script runs when called by path" '[ $rc -eq 0 ] && echo "$out" | grep -q "^Group direct: 2 repos"'

# 12. S8: a scanned file over SCAN_MAX_BYTES is listed as [unscanned] and --approve-imports refuses (exit 3)
U1="$R/upsilon"; U2="$R/phi"
mkrepo "$U1"; mkrepo "$U2"
$PY - "$U1/CLAUDE.md" <<'EOF2'
import sys
with open(sys.argv[1], "w") as f:
    f.write("\n" * (1 << 20) + "@~/.aws/credentials\n")
EOF2
size=$(wc -c < "$U1/CLAUDE.md" | tr -d ' ')
before=$(snapshot "$TMP")
out=$(link --group big "$U1" "$U2" 2>&1); rc=$?
check "S8: plain dry run exits 0 and lists the file as [unscanned] with its size" \
  '[ $rc -eq 0 ] && echo "$out" | grep -qF "[unscanned] $U1/CLAUDE.md: $size bytes over the scan cap"'
check "S8: the padded import is not reported as [external] (it was not scanned)" '! echo "$out" | grep -q "^\[external\]"'
out=$(link --group big "$U1" "$U2" --approve-imports 2>&1); rc=$?
check "S8: --approve-imports refuses with exit 3 and names the cap" \
  '[ $rc -eq 3 ] && echo "$out" | grep -q "^refused: --approve-imports refused: 1 instruction file" && echo "$out" | grep -qF "[unscanned] $U1/CLAUDE.md"'
out=$(link --group big "$U1" "$U2" --apply --approve-imports --allow-external "~/.aws/credentials" 2>&1); rc=$?
check "S8: --allow-external cannot override an unscanned file; nothing written" '[ $rc -eq 3 ] && [ "$before" = "$(snapshot "$TMP")" ]'
# A file exactly at the cap is still scanned.
$PY - "$U1/CLAUDE.md" <<'EOF2'
import sys
with open(sys.argv[1], "w") as f:
    f.write("@~/.aws/credentials\n" + "\n" * ((1 << 20) - 20))
EOF2
out=$(link --group big "$U1" "$U2" 2>&1); rc=$?
check "S8: a file exactly at the cap is scanned (external found, no [unscanned])" \
  '[ $rc -eq 0 ] && echo "$out" | grep -q "^\[external\]" && ! echo "$out" | grep -q "^\[unscanned\]"'

# 13. P3: default config and .claude.json follow CLAUDE_CONFIG_DIR (docs: code.claude.com/docs/en/claude-directory)
P1="$R/chi"; P2="$R/psi"
mkrepo "$P1" CLAUDE.md; mkrepo "$P2"
CCD="$TMP/cfgdir"; mkdir -p "$CCD"
printf '{"repo_groups":[{"name":"cfgd","repos":["%s","%s"]}]}\n' "$P1" "$P2" > "$CCD/workbench.json"
out=$(CLAUDE_CONFIG_DIR="$CCD" $PY "$LINK" --from-config cfgd 2>&1); rc=$?
check "P3: --from-config reads \$CLAUDE_CONFIG_DIR/workbench.json when no --home and no WORKBENCH_CONFIG" \
  '[ $rc -eq 0 ] && echo "$out" | grep -q "^Group cfgd: 2 repos"'
out=$(CLAUDE_CONFIG_DIR="$CCD" WORKBENCH_CONFIG="$TMP/alt-config.json" $PY "$LINK" --from-config alt 2>&1); rc=$?
check "P3: WORKBENCH_CONFIG still wins over CLAUDE_CONFIG_DIR" '[ $rc -eq 0 ] && echo "$out" | grep -q "^Group alt: 3 repos"'
out=$(CLAUDE_CONFIG_DIR="$CCD" $PY "$LINK" --from-config cfgd --apply --approve-imports 2>&1); rc=$?
check "P3: approvals go to \$CLAUDE_CONFIG_DIR/.claude.json" \
  '[ $rc -eq 0 ] && jtrue "$CCD/.claude.json" "d[\"projects\"][\"$P1\"][\"hasClaudeMdExternalIncludesApproved\"] is True"'
check "P3: the real-HOME .claude.json is not touched by that run" 'jtrue "$HOME/.claude.json" "\"$P1\" not in d[\"projects\"]"'
rm -rf "$P1/.claude" "$P1/.worktreeinclude" "$P2/.claude" "$P2/.worktreeinclude"
out=$(CLAUDE_CONFIG_DIR="$CCD" $PY "$LINK" --home "$HOME" --group cfgh "$P1" "$P2" --apply --approve-imports 2>&1); rc=$?
check "P3: an explicit --home wins over CLAUDE_CONFIG_DIR" \
  '[ $rc -eq 0 ] && jtrue "$HOME/.claude.json" "d[\"projects\"][\"$P1\"][\"hasClaudeMdExternalIncludesApproved\"] is True"'
rm -rf "$P1/.claude" "$P1/.worktreeinclude" "$P2/.claude" "$P2/.worktreeinclude"
rm -f "$HOME/.claude.json"
out=$(env -u CLAUDE_CONFIG_DIR $PY "$LINK" --group nocfg "$P1" "$P2" --apply --approve-imports 2>&1); rc=$?
check "P3: with neither --home nor CLAUDE_CONFIG_DIR, \$HOME/.claude.json is used" \
  '[ $rc -eq 0 ] && jtrue "$HOME/.claude.json" "d[\"projects\"][\"$P1\"][\"hasClaudeMdExternalIncludesApproved\"] is True"'

# Runs link_repos.py under a watchdog, so a read that blocks on a FIFO or streams /dev/zero fails the case instead of
# hanging the suite. $1 seconds, $2 --home dir, rest: arguments. Sets out and rc (137 when killed).
limited() {
  local secs=$1 home=$2; shift 2
  ( exec $PY "$LINK" --home "$home" "$@" ) > "$TMP/limited.out" 2>&1 &
  local pid=$!
  ( n=0; while [ $n -lt $((secs * 10)) ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    kill -9 "$pid" 2>/dev/null ) > /dev/null 2>&1 &
  local dog=$!
  wait "$pid"; rc=$?
  wait "$dog" 2>/dev/null
  out=$(cat "$TMP/limited.out")
}
no_trace() { ! echo "$out" | grep -q "Traceback"; }

# 14. DS-1: only regular files are read, after resolving symlinks, with a cap on every read. FIFOs and devices are
# [unscanned] and refuse approval; an outside target is never opened.
Z1="$R/dz1"; Z2="$R/dz2"
mkrepo "$Z1" CLAUDE.md; mkrepo "$Z2"
ln -s /dev/zero "$Z2/CLAUDE.md"
git -C "$Z2" add CLAUDE.md && git -C "$Z2" -c commit.gpgsign=false commit -q -m link   # a teammate's commit
limited 5 "$HOME" --group dz "$Z1" "$Z2"
check "DS-1: committed CLAUDE.md -> /dev/zero: the dry run finishes and exits 0" '[ $rc -eq 0 ] && no_trace'
check "DS-1: the /dev/zero symlink is [external] and the device is [unscanned]" \
  'echo "$out" | grep -qF "[external] $Z2/CLAUDE.md: symlink -> /dev/zero" && echo "$out" | grep -qF "[unscanned] /dev/zero: a character device, not a regular file"'
limited 5 "$HOME" --group dz "$Z1" "$Z2" --apply --approve-imports --allow-external /dev/zero
check "DS-1: a device target refuses approval even when --allow-external names it (exit 3)" \
  '[ $rc -eq 3 ] && echo "$out" | grep -q "^refused: --approve-imports refused: 1 instruction file"'

F1="$R/ff1"; F2="$R/ff2"
mkrepo "$F1" CLAUDE.md; mkrepo "$F2" CLAUDE.md
mkfifo "$TMP/outside-pipe"
ln -s "$TMP/outside-pipe" "$F2/CLAUDE.local.md"
mkdir -p "$F2/.claude"; mkfifo "$F2/.claude/CLAUDE.md"
before=$(snapshot "$R/ff1")
limited 10 "$HOME" --group ff "$F1" "$F2"; out_ff=$out
check "DS-1: FIFO instruction files (in the repo and as a symlink target) do not block the dry run" '[ $rc -eq 0 ] && no_trace'
check "DS-1: the in-repo FIFO is [unscanned]" 'echo "$out" | grep -qF "[unscanned] $F2/.claude/CLAUDE.md: a FIFO, not a regular file"'
check "DS-1: the outside FIFO is [external] and [unscanned]" \
  'echo "$out" | grep -qF "[external] $F2/CLAUDE.local.md: symlink -> $TMP/outside-pipe" && echo "$out" | grep -qF "[unscanned] $TMP/outside-pipe: a FIFO, not a regular file"'
limited 10 "$HOME" --group ff "$F1" "$F2" --apply --approve-imports --allow-external "$TMP/outside-pipe"
check "DS-1: FIFOs refuse approval (exit 3) and nothing is written" \
  '[ $rc -eq 3 ] && echo "$out" | grep -q "^refused: --approve-imports refused: 2 instruction file" && [ "$before" = "$(snapshot "$R/ff1")" ]'
check "DS-1: the bridge imports the sibling's regular CLAUDE.md, not its FIFO CLAUDE.local.md" \
  'echo "$out_ff" | grep -qF "| @$F2/CLAUDE.md" && ! echo "$out_ff" | grep -qF "| @$F2/CLAUDE.local.md"'

L1="$R/pm1"; L2="$R/pm2"
mkrepo "$L1" CLAUDE.md; mkrepo "$L2"
echo 'locked notes' > "$TMP/locked.md"; chmod 000 "$TMP/locked.md"
mkdir -p "$TMP/outside-dir" "$L2/.claude"
ln -s "$TMP/locked.md" "$L2/CLAUDE.md"
ln -s "$TMP/outside-dir" "$L2/.claude/CLAUDE.md"
mkdir -p "$L2/CLAUDE.local.md"
limited 10 "$HOME" --group pm "$L1" "$L2"
check "DS-1: unreadable or directory instruction files (outside or in the repo) do not crash; exit 0" '[ $rc -eq 0 ] && no_trace'
check "DS-1: the unreadable outside target is listed, not opened" 'echo "$out" | grep -qF "[external] $L2/CLAUDE.md: symlink -> $TMP/locked.md"'
check "DS-1: an outside directory target is [external]; directories are never [unscanned]" \
  '[ $rc -eq 0 ] && echo "$out" | grep -qF "[external] $L2/.claude/CLAUDE.md: symlink -> $TMP/outside-dir" && ! echo "$out" | grep -q "^\[unscanned\]"'
chmod 600 "$TMP/locked.md"

mkfifo "$TMP/config-pipe"
WORKBENCH_CONFIG="$TMP/config-pipe" limited 10 "$HOME" --from-config any
check "DS-1: a workbench config that is a FIFO is refused (exit 2), not read" \
  '[ $rc -eq 2 ] && echo "$out" | grep -qF "$TMP/config-pipe is a FIFO, not a regular file"'
mkrepo "$R/big1"; mkrepo "$R/big2"
mkdir -p "$R/big1/.claude"
$PY - "$R/big1/.claude/settings.local.json" <<'EOF2'
import sys
with open(sys.argv[1], "wb") as f:   # sparse: 17 MiB of size, almost no disk
    f.seek(17 << 20)
    f.write(b"\n")
EOF2
echo ".claude/settings.local.json" >> "$R/big1/.git/info/exclude"
limited 10 "$HOME" --group big "$R/big1" "$R/big2" --apply
check "DS-1: a settings file over the read cap is refused (exit 2) without being read" \
  '[ $rc -eq 2 ] && echo "$out" | grep -q "over the 16777216 byte read cap" && [ ! -e "$R/big2/.claude" ]'

# 15. DS-2: bytes that are not UTF-8 never crash; files the script rewrites keep them unchanged
N1="$R/u1"; N2="$R/u2"
mkrepo "$N1" CLAUDE.md; mkrepo "$N2"
printf '# u2\nCaf\xe9 notes\n' > "$N2/CLAUDE.md"   # one Latin-1 byte, as a Windows editor writes it
git -C "$N2" add CLAUDE.md && git -C "$N2" -c commit.gpgsign=false commit -q -m latin1
limited 10 "$HOME" --group utf "$N1" "$N2"
check "DS-2: a Latin-1 byte in a sibling CLAUDE.md: the dry run exits 0" '[ $rc -eq 0 ] && no_trace && echo "$out" | grep -q "^Group utf: 2 repos"'
printf '{"repo_groups":[{"name":"utf","repos":["%s","%s"]}]}\n' "$N1" "$N2" > "$TMP/utf-config.json"
WORKBENCH_CONFIG="$TMP/utf-config.json" limited 10 "$HOME" --from-config utf --approve-imports
check "DS-2: audit check 5 (--from-config NAME --approve-imports) survives it" \
  '[ $rc -eq 0 ] && no_trace && echo "$out" | grep -q "set hasClaudeMdExternalIncludesApproved"'
printf 'Mine: @~/caf\xe9.md\n' > "$N1/CLAUDE.local.md"
limited 10 "$HOME" --group utf "$N1" "$N2"
check "DS-2: an import token with a Latin-1 byte is listed, not a crash" \
  '[ $rc -eq 0 ] && no_trace && echo "$out" | grep -q "^\[external\] $N1/CLAUDE.local.md:1: @~/caf"'
rm "$N1/CLAUDE.local.md"
H3="$TMP/home3"; mkdir -p "$H3" "$N1/.claude"
printf '{"projects": {"/other": {"note": "Caf\xe9"}}}\n' > "$H3/.claude.json"
printf '{"note": "Caf\xe9"}\n' > "$N1/.claude/settings.local.json"
printf '# Caf\xe9 patterns\n.claude/settings.local.json\n' >> "$N1/.git/info/exclude"
latin1() { LC_ALL=C grep -c "$(printf 'Caf\xe9')" "$1" 2>/dev/null; }
limited 10 "$H3" --group utf "$N1" "$N2" --apply --approve-imports
check "DS-2: apply with Latin-1 bytes in settings, exclude and .claude.json exits 0" '[ $rc -eq 0 ] && no_trace'
check "DS-2: settings.local.json keeps its byte and gains the sibling" \
  '[ "$(latin1 "$N1/.claude/settings.local.json")" = 1 ] && grep -qF "\"$N2\"" "$N1/.claude/settings.local.json"'
check "DS-2: .git/info/exclude keeps its byte and gains the rule line" \
  '[ "$(latin1 "$N1/.git/info/exclude")" = 1 ] && grep -qx ".claude/rules/linked-repos.md" "$N1/.git/info/exclude"'
check "DS-2: .claude.json keeps its byte and records the approvals" \
  '[ "$(latin1 "$H3/.claude.json")" = 1 ] && grep -qF "\"$N1\"" "$H3/.claude.json" && grep -q "hasClaudeMdExternalIncludesApproved" "$H3/.claude.json"'
G1="$R/g1"; G2="$R/g2"
mkrepo "$G1" CLAUDE.md; mkrepo "$G2" CLAUDE.md
blob=$(git -C "$G2" hash-object -w --stdin < /dev/null)
git -C "$G2" update-index --add --cacheinfo "100644,$blob,$(printf 'caf\xe9.md')" 2>/dev/null   # index only
limited 10 "$HOME" --group gl "$G1" "$G2"
check "DS-2: a tracked file name that is not UTF-8 does not crash the git ls-files decoding" \
  '[ "$(git -C "$G2" ls-files | grep -c caf)" = 1 ] && [ $rc -eq 0 ] && no_trace'

# 16. Round 4 doc fixes (DS-3, DS-5, DS-8, FI-3, FI-7, DS-10)
AUD="$SK/config-audit/SKILL.md"; REV="$HERE/../agents/reviewer.md"
section() { awk -v n="$2" '$0 ~ "^"n"\\. " {on=1; print; next} on && /^[0-9]+\. / {exit} on {print}' "$1"; }
check "DS-3: MCP check reads the user-scope top-level mcpServers of the state file" \
  'section "$AUD" 7 | grep -q "top-level .mcpServers. keys of the global state file"'
check "DS-3: MCP check lists plugin-provided servers from claude plugin list --json" \
  'section "$AUD" 7 | grep -q "Plugin scope" && section "$AUD" 7 | grep -q "claude plugin list --json"'
check "DS-3: the Baseline line records MCP names with their scope" 'grep -q "MCP server$" "$AUD" && grep -q "^  names with their scope (user, local, project or plugin)" "$AUD"'
example_from=$(grep -o 'so `/[^`]*` becomes' "$AUD" | sed 's/^so `//; s/` becomes$//')
example_to=$(grep -A1 'so `/[^`]*` becomes' "$AUD" | tail -1 | grep -o '`-[^`]*`' | head -1 | tr -d '`')
check "DS-5: per-project folder rule: every non-alphanumeric character becomes -" \
  'section "$AUD" 4 | grep -q "every character other than A-Z, a-z and 0-9 turned into" && ! grep -q "slashes turned into dashes" "$AUD"'
check "DS-5: the documented example matches that rule" \
  '[ -n "$example_from" ] && [ "$(printf "%s" "$example_from" | sed "s/[^A-Za-z0-9]/-/g")" = "$example_to" ]'
check "DS-5: names over 200 characters: cut, hash suffix, list prefix candidates" \
  'section "$AUD" 4 | grep -q "longer than 200 characters" && section "$AUD" 4 | grep -q "hash" && section "$AUD" 4 | grep -q "starts with those 200 characters"'
check "DS-8: plugin check FAILs on failed to load (errors list or text Status)" \
  'section "$AUD" 6 | grep -q "failed" && section "$AUD" 6 | grep -q "non-empty .errors. list" && section "$AUD" 6 | grep -q "Status:"'
check "DS-8: plugin check FAILs when the marketplace installLocation is missing" \
  'section "$AUD" 6 | grep -q "installLocation" && section "$AUD" 6 | grep -q "claude plugin marketplace list --json"'
check "FI-3: permissions check verifies an ask rule covers <cfg>/workbench-kit/**" \
  'section "$AUD" 1 | grep -q "ask (or deny) rule" && section "$AUD" 1 | grep -qF "Edit(~/.claude/workbench-kit/**)"'
check "FI-7: reviewer names the invariants the repo's CLAUDE.md lists, migrations on every database" \
  'grep -qF "the invariants the repo'"'"'s CLAUDE.md lists, such as tenant isolation, money, and migrations applied to every database it lists" "$REV"'
# DS-10, IN-4: the names come from the author's own config (private/*.workbench.json in the checkout, git-ignored),
# so this file names nobody; the installed copy and a clone of the published kit have no private/, so there the check
# is skipped.
EXDIR="$HERE/../../../private"
own_names() {
  jq -r '[(.author // "" | ., splits(" +")),
      (((.uv_repos // [])[], (.pytest_env_required.paths // [])[], ((.repo_groups // [])[] | .repos[]?, .memory_dir)) | strings | split("/") | last),
      ((.commit_gates // [])[].remote | strings | split("/") | .[], (.[0] | split("-")[0])), ((.repo_groups // [])[].name | strings),
      ((.pytest_env_required.accept // [])[] | select(test("^[A-Za-z]")) | rtrimstr("="))]
    | map(select(length > 2)) | unique | .[]' "$EXDIR"/*.workbench.json 2>/dev/null
}
# Short lowercase names (a group like "abc") match as whole words, case-sensitive; the rest anywhere, any case.
NAMES_CI=""; NAMES_CS=""
while IFS= read -r n; do
  [ -n "$n" ] || continue
  n="$(printf '%s' "$n" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
  case "$n" in
    [a-z][a-z][a-z]|[a-z][a-z][a-z][a-z]) NAMES_CS="${NAMES_CS:+$NAMES_CS|}$n" ;;
    *) NAMES_CI="${NAMES_CI:+$NAMES_CI|}$n" ;;
  esac
done <<EOF
$(own_names)
EOF
DS10=("$SK/link-repos/SKILL.md" "$LINK" "$AUD" "$REV" "$HERE/../agents/gate-runner.md" "$HERE/test_link_repos.sh")
if ls "$EXDIR"/*.workbench.json >/dev/null 2>&1; then
  check "DS-10: the name list is read from private/*.workbench.json" '[ -n "$NAMES_CI" ]'
  check "DS-10: no personal or ERP names in the link-repos, config-audit, agent and test files" \
    '{ grep -niE "$NAMES_CI" "${DS10[@]}"; [ -z "$NAMES_CS" ] || grep -nwE "$NAMES_CS" "${DS10[@]}"; } | { ! grep -q .; }'
else
  echo "skip DS-10: no private/*.workbench.json next to this plugin (an installed copy or a published clone)"
fi
check "IN-6: hook self-test: a missing test file means an incomplete or old copy; re-sync with install.sh --apply" \
  'section "$AUD" 3 | tr "\n" " " | tr -s " " | grep -q "(an incomplete copy, or one from before tests/ shipped)" && section "$AUD" 3 | grep -q "install.sh --apply" && ! grep -q "leaves tests out" "$AUD"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
