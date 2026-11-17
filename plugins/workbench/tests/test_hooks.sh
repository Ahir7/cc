#!/bin/bash
# workbench hook self-test. Sandbox only: HOME, WORKBENCH_CONFIG, TMPDIR and every git repo live under one
# mktemp -d /tmp/workbench-test-* dir, and only that dir is removed on exit; the live ~/.claude is never read or
# written. Prints ok/FAIL per case and exits 1 on any failure. Needs bash, git, jq and python3.
# Usage: bash plugins/workbench/tests/test_hooks.sh
S=$(cd "$(dirname "$0")/../scripts" && pwd -P) || exit 1
T=$(mktemp -d /tmp/workbench-test-XXXXXX) || exit 1
T=$(cd "$T" && pwd -P)
case $T in /tmp/workbench-test-*|/private/tmp/workbench-test-*) ;; *) echo "unexpected sandbox: $T"; exit 1 ;; esac
trap 'rm -rf "$T"' EXIT

export HOME=$T/home WORKBENCH_CONFIG=$T/home/.claude/workbench.json TMPDIR=$T/tmp
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=wb GIT_AUTHOR_EMAIL=wb@example.invalid GIT_COMMITTER_NAME=wb GIT_COMMITTER_EMAIL=wb@example.invalid
unset CLAUDE_BROWSER_PROC_MAX WORKBENCH_GATE_TIMEOUT UV_PROJECT_ENVIRONMENT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE \
  XDG_CONFIG_HOME CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude" "$T/bin-pgrep" "$T/bin-uv" "$T/bin-nopy" "$T/empty" "$T/repos" "$TMPDIR"

# Fake tools. pgrep prints $FAKE_PROCS pids; uv logs its args, echoes the env it got and exits $FAKE_UV_RC (1).
cat >"$T/bin-pgrep/pgrep" <<'EOF'
#!/bin/bash
i=0; while [ "$i" -lt "${FAKE_PROCS:-0}" ]; do echo $((1000 + i)); i=$((i + 1)); done
EOF
cat >"$T/bin-uv/uv" <<'EOF'
#!/bin/bash
[ -n "$FAKE_UV_LOG" ] && printf 'uv %s\n' "$*" >>"$FAKE_UV_LOG"
echo "uv-env=${UV_PROJECT_ENVIRONMENT:-unset}"
echo "uv-args=$*"
exit "${FAKE_UV_RC:-1}"
EOF
chmod +x "$T/bin-pgrep/pgrep" "$T/bin-uv/uv"
# Everything the hooks need except python3, for the no-python fallback.
for tool in jq grep git cat dirname sed head tr sort mktemp sleep rm wc; do
  ln -s "$(command -v "$tool")" "$T/bin-nopy/$tool"
done

PY=$T/repos/pyproj
write_config() {
  jq -n --arg log "$T/args.log" --arg many "$T/many.log" --arg py "$PY" '{
    author: "Test Author",
    uv_repos: ["~/code/api", "~/code/svc", $py],
    pytest_env_required: {
      paths: ["~/code/svc", "~/code/svc-worktrees", "~/svc-worktrees"],
      accept: ["--env-file", "TEST_DATABASE_URL="]},
    browser_proc_max: 2,
    commit_gates: [
      {remote: "acme/backend", checks: [
        {name: "args", files: "\\.py$", cmd: ("printf \"[%s]\\n\" {files} > " + ($log | @sh))},
        {name: "nobad", files: "\\.py$", cmd: "if grep -Hn BAD {files}; then exit 1; fi"},
        {name: "nofiles", cmd: "echo nofiles ran; exit 1"},
        {name: "badregex", files: "([", cmd: "echo badregex ran; exit 1"},
        {name: "uv-env", files: "^svc/.*\\.py$", cmd: "uv run --no-sync --quiet probe {files}"}]},
      {remote: "acme/frontend", require: "node_modules/.bin/tsc", checks: [
        {name: "nobad-ts", files: "\\.(ts|tsx)$", cmd: "if grep -Hn BAD {files}; then exit 1; fi"}]},
      {remote: "acme/slow", checks: [
        {name: "slow", files: ".", cmd: "sleep 47.31"}]},
      {remote: "acme/leaky", checks: [
        {name: "leaky", files: ".", cmd: "(sleep 48.31 &); i=0; while [ $i -lt 40 ]; do i=$((i+1)); echo \"line $i\"; echo; done; exit 1"}]},
      {remote: "acme/tools", checks: [
        {name: "missing", files: "\\.py$", cmd: "./node_modules/.bin/eslint {files}"},
        {name: "notfound", files: "\\.py$", cmd: "echo \"sh: eslint: command not found\"; exit 1"},
        {name: "spawn", files: "\\.py$", cmd: "echo \"error: Failed to spawn: ruff\" >&2; exit 2"},
        {name: "nobad-tools", files: "\\.py$", cmd: "if grep -Hn BAD {files}; then exit 1; fi"}]},
      {remote: "acme/strict", on_missing_tool: "deny", checks: [
        {name: "missing", files: "\\.py$", cmd: "./node_modules/.bin/eslint {files}"}]},
      {remote: "acme/tracked", checks: [
        {name: "node-tracked", files: "\\.py$", cmd: "node_modules/.bin/lint {files}"},
        {name: "uv-tracked", files: "\\.py$", cmd: "uv run --no-sync --quiet probe {files}"}]},
      {remote: "acme/many", checks: [
        {name: "count", files: "\\.ts$", cmd: ("printf \"%s\\n\" {files} >> " + ($many | @sh))},
        {name: "nobad-many", files: "\\.ts$", cmd: "if grep -l BAD {files}; then exit 1; fi"}]}
    ]}' >"$WORKBENCH_CONFIG"
}
write_config

mkrepo() {  # dir [origin]: one commit holding .gitignore and ok.py
  mkdir -p "$1" && git -C "$1" init -q -b main &&
    printf '.venv/\nnode_modules/\n' >"$1/.gitignore" && printf 'x = 1\n' >"$1/ok.py" &&
    git -C "$1" add -A && git -C "$1" commit -qm init || { echo "fixture failed: $1"; exit 1; }
  [ -z "$2" ] || git -C "$1" remote add origin "$2"
}

passes=0; fails=0
report() {  # want got label
  if [ "$1" = "$2" ]; then passes=$((passes + 1)); r=ok; else fails=$((fails + 1)); r=FAIL; fi
  printf '%-4s want=%-5s got=%-5s %s\n' "$r" "$1" "$2" "$3"
}
expect() {  # label actual expected
  if [ "$2" = "$3" ]; then passes=$((passes + 1)); printf 'ok   %s\n' "$1"
  else fails=$((fails + 1)); printf 'FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$3" "$2"; fi
}
has() {  # label haystack needle
  case $2 in *"$3"*) expect "$1" yes yes ;; *) expect "$1" "missing; text was: $(printf '%s' "$2" | head -3)" "contains: $3" ;; esac
}
gone() {  # label pgrep-pattern: waits up to 2 s for every matching process to exit
  local k=0
  while pgrep -f "$2" >/dev/null 2>&1 && [ $k -lt 10 ]; do sleep 0.2; k=$((k + 1)); done
  expect "$1" "$(pgrep -f "$2" 2>/dev/null | wc -l | tr -d ' ')" 0
}
decision() {  # stdout rc
  [ "$2" = 0 ] || { echo "exit$2"; return; }
  [ -n "$1" ] || { echo pass; return; }
  printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null || echo badjson
}
reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
payload() { jq -n --arg c "$1" --arg w "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$w}'; }
oneline() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-110; }

echo "== scripts are executable"
for f in kitconf.sh guard.sh browser_cap.sh commit_gate.sh format_py.sh cmdparse.py; do
  expect "chmod +x $f" "$([ -x "$S/$f" ] && echo yes || echo no)" yes
done

echo "== kitconf.sh"
kc() { ( . "$S/kitconf.sh"; "$@"; echo "rc=$?" ); }
expect "kit_get .author" "$(kc kit_get .author)" "Test Author
rc=0"
expect "kit_paths expands ~/" "$(kc kit_paths '.uv_repos[]?')" "$HOME/code/api
$HOME/code/svc
$PY
rc=0"
expect "kit_get on a missing key prints nothing" "$(kc kit_get .nope)" "rc=0"
printf '%s\n' '{"p": ["~", "$HOME/x", "${HOME}/y/", "/abs/", "rel/z", 3, null]}' >"$T/alt.json"
expect "kit_paths: ~, \$HOME, \${HOME}, trailing /, relative and non-strings" \
  "$(WORKBENCH_CONFIG=$T/alt.json kc kit_paths '.p[]')" "$HOME
$HOME/x
$HOME/y
/abs
rc=0"
expect "missing config: nothing, status 0" "$(WORKBENCH_CONFIG=$T/none.json kc kit_get .author)" "rc=0"
printf '{not json' >"$T/bad.json"
expect "malformed config: nothing, status 0" "$(WORKBENCH_CONFIG=$T/bad.json kc kit_paths '.uv_repos[]')" "rc=0"
mkdir -p "$T/cfgdir"; printf '{"author": "From Config Dir"}\n' >"$T/cfgdir/workbench.json"
kc2() { env "$@" /bin/bash -c '. "$0/kitconf.sh"; kit_get .author' "$S"; }
expect "kitconf (r3 P3): no WORKBENCH_CONFIG reads \$CLAUDE_CONFIG_DIR/workbench.json" \
  "$(kc2 -u WORKBENCH_CONFIG CLAUDE_CONFIG_DIR="$T/cfgdir")" "From Config Dir"
expect "kitconf (r3 P3): neither set reads \$HOME/.claude/workbench.json" "$(kc2 -u WORKBENCH_CONFIG)" "Test Author"
expect "kitconf (r3 P3): WORKBENCH_CONFIG wins over CLAUDE_CONFIG_DIR" "$(kc2 CLAUDE_CONFIG_DIR="$T/cfgdir")" \
  "Test Author"

echo "== cmdparse.py"
P=$HOME/code/svc; B=$HOME/code/api; F=$HOME/code/web
NL=$'\n'
cp_() {  # command [cwd]: one line per segment, dir|argv|git sub (|U when unparsed)
  jq -n --arg c "$1" --arg w "${2:-/w}" '{command:$c,cwd:$w}' | /usr/bin/env python3 -I "$S/cmdparse.py" |
    jq -r '[.dir, (.argv | join(" ")), (.git.sub? // "-")] + (if .unparsed then ["U"] else [] end) | join("|")'
}
expect "cmdparse: cd moves later segments, a subshell's cd ends at ), git -C is per segment" \
  "$(cp_ 'cd sub && (cd deeper && git status) && git -C /x commit -m y; git log')" "/w|cd sub|-
/w/sub|cd deeper|-
/w/sub/deeper|git status|status
/x|git -C /x commit -m y|commit
/w/sub|git log|log"
expect "cmdparse: ~ and \$HOME in cd" "$(cp_ 'cd ~/a; cd $HOME/b; cd; cd "$X"; git status')" "/w|cd ~/a|-
$HOME/a|cd \$HOME/b|-
$HOME/b|cd|-
$HOME|cd \$X|-
$HOME|git status|status"
expect "cmdparse: assignments and wrappers dropped" \
  "$(cp_ 'FOO=1 time nohup env -u X BAR=2 command git --no-pager -c a=b status')" "/w|git --no-pager -c a=b status|status"
expect "cmdparse: uv run --directory and uv --directory set the dir" \
  "$(cp_ 'uv run --with a --directory d pytest -q; uv --directory /e run x' | cut -d'|' -f1)" "/w/d
/e"
expect "cmdparse: heredoc body and # comment are not commands" \
  "$(cp_ "cat > f <<'EOF'${NL}git stash${NL}it's${NL}EOF${NL}ls # ; git stash")" "/w|cat|-
/w|ls|-"
expect "cmdparse: \$(...), backticks and bash -c are parsed as their own segments" \
  "$(cp_ 'echo "$(git stash)" `git push`; bash -c "git status"' | cut -d'|' -f2)" "git stash
git push
echo \$(git stash) \$(git push)
git status
bash -c git status"
expect "cmdparse: quoted or escaped ; is a word, not a separator" "$(cp_ 'echo ";" git stash \; x' | cut -d'|' -f2)" \
  "echo ; git stash ; x"
expect "cmdparse: unbalanced quote = one unparsed record" "$(cp_ "echo 'x; git stash")" "/w||-|U"
expect "cmdparse: bad JSON input prints nothing, exit 0" \
  "$(printf 'nope' | /usr/bin/env python3 -I "$S/cmdparse.py"; echo "rc=$?")" "rc=0"
cpx_() {  # command [cwd]: one line per segment, argv|U or -|stdin files|subfiles
  jq -n --arg c "$1" --arg w "${2:-/w}" '{command:$c,cwd:$w}' | /usr/bin/env python3 -I "$S/cmdparse.py" |
    jq -r '[(.argv | join(" ")), (if .unparsed then "U" else "-" end), ((.stdin // []) | join(",")),
      ((.subfiles // []) | join(","))] | join("|")'
}
expect "cmdparse (r3 S5): an operator glued to a redirection still ends the segment (;> &&< |>)" \
  "$(cp_ 'true;>/dev/null git stash; true&&</dev/null git push; git status|>/dev/null git stash' | cut -d'|' -f2,3)" \
  "true|-
git stash|stash
true|-
git push|push
git status|status
git stash|stash"
expect "cmdparse (r3 S5): the fd number of a redirection is not a word" \
  "$(cp_ 'git 2>/dev/null stash 2>&1' | cut -d'|' -f2,3)" "git stash|stash"
expect "cmdparse (r3 S6): bash -c -- STRING parses STRING" "$(cp_ "bash -c -- 'git stash'" | cut -d'|' -f2,3)" \
  "git stash|stash
bash -c -- git stash|-"
expect "cmdparse (r4 HS-2): a shell reading stdin, eval or bash -c of \$X, and source of printed text are unparsed" \
  "$(cpx_ "bash <<'EOF'${NL}git stash${NL}EOF${NL}echo x | sh -s; bash - <f; zsh /dev/stdin; eval \"\$C\"; source <(echo x); . \"\$F\"; bash -c \"\$C\"" |
    cut -d'|' -f1,2)" "bash|U
echo x|-
sh -s|U
bash -|U
zsh /dev/stdin|U
\$C|-
eval \$C|U
echo x|-
source <(echo x)|U
. \$F|-
\$C|-
bash -c \$C|U"
expect "cmdparse (r4 HS-2): source of a \$VAR path and eval or bash -c of a \$(...) that prints nothing visible are parsed" \
  "$(cpx_ 'source "$HOME/.nvm/nvm.sh"; eval "$(ssh-agent -s)"; \. "$NVM_DIR/nvm.sh"; source <(direnv hook bash); bash -c "$(curl -fsSL u)"; eval "$(echo ls)"; bash -c "$(printf ls)"' |
    cut -d'|' -f1,2)" "source \$HOME/.nvm/nvm.sh|-
ssh-agent -s|-
eval \$(ssh-agent -s)|-
. \$NVM_DIR/nvm.sh|-
direnv hook bash|-
source <(direnv hook bash)|-
curl -fsSL u|-
bash -c \$(curl -fsSL u)|-
echo ls|-
eval \$(echo ls)|U
printf ls|-
bash -c \$(printf ls)|U"
expect "cmdparse (r4 HS-2): fb holds only the unparsed segment's text, its heredoc body and what is piped into it" \
  "$(jq -n --arg c "git commit -m 'drop pip'; eval \"\$X\"; cat <<'EOF' | bash -s${NL}ls -la${NL}EOF" '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r 'select(.unparsed) | .fb' | tr -d "'\"")" "eval \$X

bash -s

cat << EOF
ls -la"
expect "cmdparse (r4 HS-7): text leaves out sed, grep, rg, awk and perl inside \$( ); feed starts after the last filter" \
  "$(jq -n --arg c 'git commit -m "$(rg -v y m)" --amend -m "$(git log -1 --format=%B | sed "/x/d")"; cat m | sed /x/d | printf y | git commit -F - <<< "here"' '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r 'select(.text) | [.text, (.feed // "-")] | join("|")')" \
  "git commit -m  --amend -m git log -1 --format=%B|-
git commit -F -${NL}here|printf y"
expect "cmdparse (r4 HS-6): message files expand \$TMPDIR, \${PWD} and \$(pwd); other \$VARs are skipped" \
  "$(jq -n --arg c 'cd /s && git -C /g commit -F "$TMPDIR/m" -F "${PWD}/n" -F "$(pwd)/o" -F "$X/p" -F q --file=~/r' '{command:$c,cwd:"/w"}' |
    TMPDIR=/tt/ /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r 'select(.msgfiles) | .msgfiles[]')" "/tt/m
/s/n
/s/o
/g/q
$HOME/r"
expect "cmdparse (r4 FI-8, r6 HR-2): uv run --project X moves the dir; pydirs name the script or path python or pip runs, never the program's own dir" \
  "$(jq -n --arg c 'uv run --project /e pytest; uv run --project=/f pytest; cd /t && python3 -I ~/r/x.py; pip install -r /r/req.txt -e /r/pkg; /r/.venv/bin/python -m x; python3 -c "x" /r/y.py; /r/.venv/bin/python /r/s.py; /r/.venv/bin/pip install -e /r/pkg; /r/.venv/bin/ruff check' '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r '[.dir, (.pydirs // [] | join(","))] | join("|")')" "/e|
/f|
/w|
/t|$HOME/r
/t|/r/req.txt,/r/pkg
/t|
/t|
/t|/r
/t|/r/pkg
/t|"
expect "cmdparse (r4): a here-string is not read as a heredoc" \
  "$(cp_ "cat <<<\"EOF\"${NL}git stash${NL}EOF" | cut -d'|' -f2,3)" "cat|-
git stash|stash
EOF|-"
expect "cmdparse (r3 S3): a script operand, a literal eval or source, and bash -c 'x' stay parsed" \
  "$(cpx_ "bash ./x.sh <<'EOF'${NL}git stash${NL}EOF${NL}eval 'ls'; source ./env.sh; sh -c 'ls'" | cut -d'|' -f1,2)" \
  "bash ./x.sh|-
ls|-
eval ls|-
source ./env.sh|-
ls|-
sh -c ls|-"
expect "cmdparse (r3 S4): < files and cat F | feed stdin (shell dir, not git -C); cat F and <F in \$( ) are subfiles" \
  "$(cpx_ 'git -C /x commit -F - < m.txt; cat a.txt | git commit -F -; git commit -m "$(cat b.txt)" -m "$(< c.txt)"')" \
  "git -C /x commit -F -|-|/w/m.txt|
cat a.txt|-||
git commit -F -|-|/w/a.txt|
cat b.txt|-||
|-|/w/c.txt|
git commit -m \$(cat b.txt) -m \$(< c.txt)|-||/w/b.txt,/w/c.txt"
expect "cmdparse (r3): \$(...) and backticks in an unquoted heredoc body are segments; quoted or escaped ones are not" \
  "$(cp_ "cat > /dev/null <<EOF${NL}\$(git stash) \\\$(git log) \`git push\`${NL}EOF${NL}cat <<'EOF'${NL}\$(git stash)${NL}EOF" |
    cut -d'|' -f2,3)" "git stash|stash
git push|push
cat|-
cat|-"
expect "cmdparse (r3 S2): uv run drops wrappers before the program" \
  "$(jq -n '{command:"uv run env X=1 timeout 300 nice -n 5 time coverage run -m pytest",cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r '.uv_run | join(" ")')" "coverage run -m pytest"
expect "cmdparse (r5 HF-4): \$'...' is one word, \\' does not end it, and ; inside it splits nothing" \
  "$(cp_ "echo \$'a\\'b; c' x; git commit -m \$'it\\'s'" | cut -d'|' -f2,3)" "echo a'b; c x|-
git commit -m it's|commit"
expect "cmdparse (r5 HF-1): a reader (-F, \$VAR) gets the text of earlier segments as pretext, filters left out" \
  "$(jq -n --arg c 'printf one > m; grep -v two m > n; MSG=three; git commit -F n; git commit -m x; git commit -m "$MSG"' '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r 'select(.git.sub? == "commit") | .pretext // "-" | gsub("\n"; "/")')" \
  "printf one/MSG=three
-
printf one/MSG=three/git commit -F n/git commit -m x"
expect "cmdparse (r5 HF-3): fb of eval or bash -c of \$NAME adds the earlier NAME=... or export NAME=... and its value" \
  "$(jq -n --arg c 'A=1; export C="ls -la"; B=2 true; eval "$C"; bash -c "${A}"; eval "$B"' '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r 'select(.unparsed) | .fb | gsub("\n+"; "/")' | tr -d "'\"")" \
  "export C=ls -la/ls -la/eval \$C/
A=1/1/bash -c \${A}/
eval \$B/"
expect "cmdparse (r6 HR-5): the commands of git submodule foreach, rebase --exec/-x and bisect run are segments in that dir; function NAME { splits after the brace" \
  "$(cp_ "git -C /x submodule foreach --recursive 'git st''ash list'; git rebase -x 'make t' --exec='uv run pytest' main; git bisect run ./t.sh a; function f { git push; }; git submodule update")" \
  "/x|git stash list|stash
/x|git -C /x submodule foreach --recursive git stash list|submodule
/w|make t|-
/w|uv run pytest|-
/w|git rebase -x make t --exec=uv run pytest main|rebase
/w|./t.sh a|-
/w|git bisect run ./t.sh a|bisect
/w|git push|push
/w|}|-
/w|git submodule update|submodule"
expect "cmdparse (r6 HR-5): uvx and uv tool run unwrap like uv run" \
  "$(jq -n --arg c 'uvx --from a b c; uv tool run --with x env Y=1 pytest -q; uv tool install z; uvx -- ruff; uv run py' '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r '(.uv_run // ["-"]) | join(" ")')" "b c
pytest -q
-
ruff
py"
expect "cmdparse (r6 HR-3): bash -c is unparsed only for a bare \$VAR or \${VAR}; a literal script holding a \$ is parsed" \
  "$(cpx_ "bash -c 'echo \$HOME && wc -c'; bash -c \"\$X\"; sh -c '\${Y}'; bash -c '\$A \$B'; bash -c \"ls \$D\"" | cut -d'|' -f1,2)" \
  "echo \$HOME|-
wc -c|-
bash -c echo \$HOME && wc -c|-
\$X|-
bash -c \$X|U
\${Y}|-
sh -c \${Y}|U
\$A \$B|-
bash -c \$A \$B|U
ls \$D|-
bash -c ls \$D|-"
expect "cmdparse (r6 HR-3): assigns marks NAME=... alone and export or declare NAME=..., not a prefix assignment or echo" \
  "$(jq -n --arg c 'A=1; export B=2; C=3 true; declare D=4; echo E=5' '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r '[(.argv | join(" ")), (if .assigns then "A" else "-" end)] | join("|")')" \
  "|A
export B=2|A
true|-
declare D=4|A
echo E=5|-"
expect "cmdparse (r6 HR-4): a filter's heredoc and here-string bodies count in feed, pretext and \$( ) text; its words do not" \
  "$(jq -n --arg c "grep -v x <<<\"one\" | git commit -F -; sed s/a/b/ > m <<'EOF'${NL}two${NL}EOF${NL}git commit -F m; git commit -m \"\$(awk 1 <<<\"three\")\" -m \"\$(sed /four/d f)\"" '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r 'select(.git.sub? == "commit") | [.text, .feed // "-", .pretext // "-"] | map(gsub("\n"; "/")) | join("|")')" \
  "git commit -F -|one|one
git commit -F m|-|one/git commit -F -/two/
git commit -m three -m |-|-"
expect "cmdparse (r6 HR-1): bodies holds a record's heredoc and here-string text, only when the request asks" \
  "$(for want in true false; do jq -n --arg c "cat > m <<'EOF'${NL}x${NL}EOF${NL}node m <<< y" --argjson b $want '{command:$c,cwd:"/w",bodies:$b}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r '.bodies // "-" | gsub("\n"; "/")'; done)" "x/
y
-
-"
expect "cmdparse (r7 R6H-1): several git submodule foreach words and git bisect run words keep each word's quoting" \
  "$(cp_ "git submodule foreach sh -c 'git st''ash list'; git bisect run sh -c 'make t && git push'")" \
  "/w|git stash list|stash
/w|sh -c git stash list|-
/w|git submodule foreach sh -c git stash list|submodule
/w|make t|-
/w|git push|push
/w|sh -c make t && git push|-
/w|git bisect run sh -c make t && git push|bisect"
expect "cmdparse (r7 R6H-3): NAME=value words in front of bash -c, eval or git reach the nested records as envpre" \
  "$(jq -n --arg c "T=1 git bisect run uv run pytest; env U=2 sh -c 'V=3 bash -c \"ls\"'; W=4 eval 'ls'; X=5 ls" '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r '[(.argv | join(" ")), (.envpre // "-" | gsub("\n"; "/"))] | join("|")')" \
  "uv run pytest|T=1
git bisect run uv run pytest|-
ls|U=2/V=3
bash -c ls|U=2
sh -c V=3 bash -c \"ls\"|-
ls|W=4
eval ls|-
ls|-"
expect "cmdparse (r7 R6H-4): a bare cat in the \$( ) of a commit or gh segment reads its stdin; cat F, a heredoc or a pipe into cat does not" \
  "$(jq -n --arg c 'printf x | git commit -m "$(cat)"; printf y | gh pr comment 1 --body "$(cat -)"; printf z | gh pr comment 1 --body "$(cat f)"; printf w | gh pr comment 1 --body "$(echo v | cat)"; printf u | git commit -m "$(cat <<<t)"' '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r 'select(.git.sub? == "commit" or .argv[0] == "gh") | [.argv[0], (.stdin_msg // false | tostring), .feed // "-"] | join("|")')" \
  "git|true|printf x
gh|true|printf y
gh|false|-
gh|false|-
git|false|-"
expect "cmdparse (r7 R6H-5): uvx and uv tool run drop a version or extras spec from the tool word" \
  "$(jq -n --arg c "uvx pytest@8 tests; uvx --python 3.12 pytest@latest -q; uv tool run pytest==8.3.0 -q; uvx 'black[jupyter]>=24' x; uvx 'pytest>=8' -q; uv run -w playwright python x.py" '{command:$c,cwd:"/w"}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" | jq -r '(.uv_run // ["-"]) | join(" ")')" "pytest tests
pytest -q
pytest -q
black x
pytest -q
python x.py"
expect "cmdparse (r7 R6H-2, R6H-6): with bodies, records carry the files they write (> >> tee sed -i perl -i), the records piped into them, and inmsg inside a commit's \$( )" \
  "$(jq -n --arg c "echo a > o.txt; printf b | tee -a t.log | node; sed -i.bak s/x/y/ s.js; perl -pi -e 1 p.js; git commit -m \"\$(cat <<<m)\"" '{command:$c,cwd:"/w",bodies:true}' |
    /usr/bin/env python3 -I "$S/cmdparse.py" |
    jq -r '[(.argv | join(" ")), ((.writes // []) | map(select(test("[.](txt|log|js)$"))) | join(",")),
      ((.up // []) | map(tostring) | join(",")), (if .inmsg then "M" else "-" end), (.paths["s.js"] // "-")] | join("|")')" \
  "echo a|/w/o.txt||-|-
printf b|||-|-
tee -a t.log|/w/t.log|1|-|-
node||1,2|-|-
sed -i.bak s/x/y/ s.js|/w/s.js||-|/w/s.js
perl -pi -e 1 p.js|/w/p.js||-|-
cat|||M|-
git commit -m \$(cat <<<m)|||-|-"

echo "== guard.sh: the live test_guard.sh cases, on sandbox paths"
mkrepo "$B"
WT1=$HOME/code/api-worktrees/wt1
git -C "$B" worktree add -q "$WT1" -b wt1 || { echo "fixture failed: worktree"; exit 1; }
mkdir -p "$HOME/code/api-old"
fb=0
t() {  # want cwd command [PATH]; fb counts the cases the guard checked with its whole-text fallback
  out=$(payload "$3" "$2" | PATH=${4:-$PATH} /bin/bash "$S/guard.sh" 2>"$T/guard.err"); rc=$?
  grep -q 'workbench guard: whole-text check' "$T/guard.err" && fb=$((fb + 1))
  report "$1" "$(decision "$out" $rc)" "guard: $(oneline "$3")"
}
t ask  "$B" "git push origin feat/x"
t ask  "$F" "git -C . push"
t ask  "$P" "cd x && git push --force-with-lease"
t pass "$P" "git log --oneline | grep pushed"
t pass "$P" "git status"
t deny "$B" "git stash push -m wip"
t deny "$P" "git stash list"
t pass "$P" "echo stash"
t deny "$B" "git commit -m \"fix: x${NL}${NL}Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\""
t pass "$B" "git commit -m \"fix(x-1): guard the null id\""
t deny "$P" "uv run pytest tests/test_x.py -q"
t pass "$P" "uv run --env-file .env.lane3 pytest tests/test_x.py -q"
t pass "$P" "TEST_DATABASE_URL=postgresql://x uv run pytest -q"
t pass "$B" "uv run pytest -q"
t deny "$P" "python -m pytest tests"
t deny "$B" "cd app && .venv/bin/python -m alembic upgrade head"
t deny "$B" "pip install requests"
t pass "$P" "uv run python -m app.seed"
t pass "$P" "/usr/bin/python3 -I script.py"
t pass "$F" "python -m http.server"
t pass "$F" "npm run build"
t ask  "$B" "gh pr create --title x --body y"
t pass "$B" "gh pr view 48"
t deny "$F" "gh pr edit 76 --body \"done${NL}Generated with [Claude Code](https://claude.com/claude-code)\""

echo "== guard.sh: config-driven extras"
t deny "$WT1" "pip install requests"
t pass "$HOME/code/api-old" "pip install requests"
t deny "$P/sub/dir" "python manage.py migrate"
t deny "$HOME/svc-worktrees/lane3" "uv run pytest -q"
t pass "$HOME/svc-worktrees/lane3" "uv run pytest -q --env-file .env.lane3"
t pass "$HOME/code/svc-old" "uv run pytest -q"
t ask  "$F" "glab mr merge 12"
t deny "$F" "git -C . stash pop"
out=$(payload "git push" "$B" | bash "$S/guard.sh")
has "guard: ask reason names the configured author" "$(reason "$out")" "Test Author's go-ahead"
out=$(payload "uv run pytest -q" "$P" | bash "$S/guard.sh")
has "guard: pytest reason joins the accept tokens with commas" "$(reason "$out")" \
  "Add one of: --env-file, TEST_DATABASE_URL="
out=$(payload "git push" "$B" | "$S/guard.sh"); rc=$?
report ask "$(decision "$out" $rc)" "guard: runs when executed directly (no bash prefix)"
out=$(cd "$S" && payload "pip install requests" "$B" | bash guard.sh); rc=$?
report deny "$(decision "$out" $rc)" "guard: finds kitconf.sh and cmdparse.py when started as 'bash guard.sh' from its own dir"
mv "$WORKBENCH_CONFIG" "$T/workbench.json.off"
t deny "$P" "git stash"
t ask  "$B" "git push"
t pass "$P" "uv run pytest -q"
t pass "$B" "pip install requests"
out=$(payload "git commit -m \"x${NL}Co-Authored-By: Claude <noreply@anthropic.com>\"" "$B" | bash "$S/guard.sh")
has "guard: no config still denies a Claude trailer" "$(reason "$out")" "carry no Claude attribution"
printf '{not json' >"$WORKBENCH_CONFIG"
t pass "$P" "uv run pytest -q"
t deny "$B" "git stash"
mv "$T/workbench.json.off" "$WORKBENCH_CONFIG"
out=$(payload "git stash" "$B" | PATH=$T/empty /bin/bash "$S/guard.sh"); rc=$?
expect "guard: fails open without jq" "rc=$rc out=[$out]" "rc=0 out=[]"
expect "guard: every case above was decided per segment, none by the whole-text fallback" "$fb" 0

echo "== guard.sh: round-2 repros (one segment at a time)"
TR="Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
GW="Generated with [Claude Code](https://claude.com/claude-code)"
t deny "$B" "git commit -m \"fix: x${NL}${NL}$TR\" && git push"
t deny "$B" "gh pr create --title x --body \"y${NL}${NL}$GW\""
t deny "$B" "glab mr create --title x --description \"$TR\""
printf 'fix: x\n\n%s\n' "$TR" >"$B/msg_bad.txt"; printf 'fix: x\n' >"$B/msg_ok.txt"
t deny "$B" "git commit -F msg_bad.txt"
t deny "$B" "git commit --file=msg_bad.txt"
t deny "$B" "git commit -Fmsg_bad.txt"
t deny "$T" "git -C $B commit -F msg_bad.txt"
t deny "$B" "gh pr create --title x --body-file msg_bad.txt"
t deny "$B" "gh pr create --title x -F msg_bad.txt"
t pass "$B" "git commit -F msg_ok.txt"
t pass "$B" "git commit -F missing.txt"
t ask  "$B" "gh pr create --title x --body-file msg_ok.txt"
t pass "$B" "git commit -m \"chore: drop stash from deploy script\""
t pass "$B" "git commit -m \"ask before push\""
t pass "$B" "git grep -n stash"
t pass "$B" "git log -S stash --oneline"
t pass "$B" "git log --oneline | grep commit"
t deny "$T" "git stash;"
t deny "$T" "(git stash)"
t deny "$T" "echo \"\$(git stash)\""
t deny "$T" "echo \`git stash list\`"
t deny "$T" "bash -c 'git stash'"
t deny "$T" "if git diff --quiet; then git stash; fi"
t deny "$T" "ls -d */ | xargs -I{} git -C {} stash"
t ask  "$T" "git status && git push"
t pass "$B" "git commit -m \"\$(cat <<'EOF'${NL}fix: drop the stash step, it's \"push\" now${NL}EOF${NL})\""
t deny "$B" "git commit -m \"\$(cat <<'EOF'${NL}fix: x${NL}${NL}$TR${NL}EOF${NL})\" && git push"
t pass "$B" "cat > notes.md <<'EOF'${NL}pip install foo${NL}git stash is shared${NL}EOF"
t deny "$T" "cd $B && pip install x"
t deny "$T" "cd ~/code/svc && uv run pytest -q"
t deny "$T" "uv run --directory $P pytest -q"
t deny "$T" "uv --directory $P run pytest -q"
t pass "$T" "uv run --directory $P pytest -q --env-file .env.lane3"
t deny "$P" "echo --env-file; uv run pytest -q"
t pass "$P" "export TEST_DATABASE_URL=postgresql://x && uv run pytest -q"
t deny "$P" "timeout 600 uv run --with pytest-xdist pytest -n 4"
t deny "$B" "PYTHONPATH=. python -m app.seed"
t deny "$B" "python3.12 -m pip install x"
t deny "$B" "pip3.12 install x"
t deny "$B" "time python x.py"
t deny "$B" "$B/.venv/bin/python -m x"
t deny "$T" "env -C $B pip install x"
t pass "$B" "command -v python3"
t pass "$B" "grep -rn 'pip install' docs"
expect "guard: every round-2 case was decided per segment, none by the whole-text fallback" "$fb" 0

echo "== guard.sh: fallback when the command cannot be split, or there is no python3"
t deny "$T" "git stash 'oops"
t ask  "$T" "git push 'oops"
t deny "$B" "pip install x 'oops"
t deny "$B" "git commit -m \"x${NL}$TR\" 'oops"
t pass "$T" "echo 'oops"
t deny "$T" "git stash list" "$T/bin-nopy"
t ask  "$T" "git push" "$T/bin-nopy"
t deny "$B" "pip install x" "$T/bin-nopy"
t pass "$T" "git status" "$T/bin-nopy"
expect "guard: the 8 cases with a git/pip word above used the whole-text fallback" "$fb" 8

echo "== guard.sh: round-3 repros, decided per segment"
fb=0
LANE=$HOME/svc-worktrees/lane3   # under pytest_env_required.paths, not under uv_repos
# S2: wrapped pytest
t deny "$LANE" "uv run coverage run -m pytest -q"
t deny "$LANE" "uv run env X=1 pytest -q"
t deny "$LANE" "uv run timeout 300 pytest -q"
t deny "$LANE" "uv run nice -n 5 time pytest -q"
t deny "$LANE" "uv run python -m coverage run -m pytest"
t deny "$LANE" "coverage run --source=app .venv/bin/pytest -q"
t deny "$LANE" "uv run python -m coverage run --branch .venv/bin/py.test"
t deny "$LANE" "timeout 300 env X=1 python3.12 -m pytest"
t pass "$LANE" "uv run coverage run -m pytest -q --env-file .env.lane3"
t pass "$LANE" "uv run coverage report"
t pass "$LANE" "uv run coverage run -m app.seed"
# S4: trailer from files (msg_bad.txt and msg_ok.txt are in $B)
{ head -c 1048576 /dev/zero | tr '\0' '\n'; printf '%s\n' "$TR"; } >"$B/msg_late.txt"
{ printf '%s\n' "$TR"; head -c 2097152 /dev/zero | tr '\0' '\n'; } >"$B/msg_big.txt"
t deny "$B" "git commit -m \"\$(cat msg_bad.txt)\""
t deny "$B" "git commit -m \"\`cat msg_bad.txt\`\""
t deny "$B" "git commit -m \"\$(< msg_bad.txt)\""
t deny "$B" "git commit -aF msg_bad.txt"
t deny "$B" "git commit -aFmsg_bad.txt"
t deny "$B" "git commit -F - < msg_bad.txt"
t deny "$B" "git commit --file=- <msg_bad.txt"
t deny "$B" "git commit -F /dev/stdin < msg_bad.txt"
t deny "$B" "cat msg_bad.txt | git commit -F -"
t deny "$T" "cd $B && git commit -F - < msg_bad.txt"
t deny "$T" "git -C $B commit -F - < $B/msg_bad.txt"
t deny "$B" "gh pr create --title x --body-file - < msg_bad.txt"
t deny "$B" "gh pr create --title x --body \"\$(cat msg_bad.txt)\""
t deny "$B" "glab mr note 3 -m \"\$(cat msg_bad.txt)\""
t deny "$B" "git commit -F msg_big.txt"
t pass "$B" "git commit -F msg_late.txt"
t pass "$B" "git commit -F - < msg_ok.txt"
t pass "$B" "git commit -m \"\$(cat msg_ok.txt)\""
t pass "$B" "cat msg_bad.txt | grep -c x && git commit -m fix"
t pass "$B" "echo \"\$(cat msg_bad.txt)\" && git commit -m fix"
# S5: an operator glued to a redirection
t deny "$T" "true;>/dev/null git stash"
t ask  "$T" "true&&</dev/null git push origin main"
t deny "$T" "git status|>/dev/null git stash"
t deny "$T" "git 2>/dev/null stash"
# S6
t deny "$T" "bash -c -- 'git stash'"
# S7: quotes in a keyword; gh and glab options before the action
t deny "$T" "gi''t stash"
t deny "$T" "g\\it stash"
t deny "$B" "pyth''on x.py"
t ask  "$B" "gh pr -R o/r create --title x --body y"
t ask  "$B" "gh pr --repo=o/r merge 3"
t ask  "$B" "glab mr -R g/p merge 1"
t deny "$B" "gh pr --repo o/r create --title x --body \"$TR\""
t pass "$B" "gh pr -R o/r view 3"
# S3: a script operand is not stdin
t pass "$T" "bash ./x.sh <<'EOF'${NL}git stash${NL}EOF"
# Reviewer probe (r2_probe.py): an unquoted heredoc body runs its $(...)
t deny "$T" "cat > /dev/null <<EOF${NL}\$(git stash)${NL}EOF"
t deny "$B" "git commit -F - <<EOF${NL}\$(cat msg_bad.txt)${NL}EOF"
t pass "$T" "cat > notes.md <<'EOF'${NL}\$(git stash)${NL}EOF"
t pass "$T" "cat > notes.md <<EOF${NL}\\\$(git stash)${NL}EOF"
# S1 support: the skills' fixed commands pass in a uv repo; a bare python call there is still denied
SK=$T/github/workbench/plugins/workbench/skills/link-repos/link_repos.py
t pass "$B" "\"$SK\" --group demo a b"
t pass "$B" "\"\${CLAUDE_SKILL_DIR}/link_repos.py\" --group demo a b"
t pass "$B" "jq empty $HOME/.claude/settings.json && jq -e .enabledPlugins $HOME/.claude/settings.json"
t deny "$B" "/usr/bin/env python3 -I \"$SK\" --group demo a b"
expect "guard: every round-3 case above was decided per segment, none by the whole-text fallback" "$fb" 0
# I4: the keyword check reads the command only, not cwd
mkdir -p "$T/github-gh-pip"
out=$(payload "ls -la" "$T/github-gh-pip" | PATH=$T/bin-nopy /bin/bash "$S/guard.sh" 2>"$T/guard.err"); rc=$?
expect "guard (r3 I4): a cwd holding git/gh/pip words does not start a check (no python3, no fallback note)" \
  "rc=$rc out=[$out] err=[$(cat "$T/guard.err")]" "rc=0 out=[] err=[]"

echo "== guard.sh: round-3 S3, code fed to a shell on stdin (whole-text fallback)"
fb=0
t deny "$T" "bash <<'EOF'${NL}git stash${NL}EOF"
t ask  "$T" "sh <<EOF${NL}git push${NL}EOF"
t deny "$T" "echo 'git stash' | bash"
t deny "$B" "echo 'pip install x' | bash"
t deny "$T" "cat <<'EOF' | bash -s${NL}git stash list${NL}EOF"
t deny "$T" "eval \"\$(cat <<'EOF'${NL}git stash${NL}EOF${NL})\""
t deny "$T" "source <(echo 'git stash')"
t deny "$T" "bash -c \"\$(cat <<'EOF'${NL}git stash${NL}EOF${NL})\""
t deny "$T" "cd $B && cat <<'EOF' | bash${NL}pip install x${NL}EOF"
t pass "$T" "echo 'git status' | bash"
expect "guard: the 10 shell-stdin cases above used the whole-text fallback" "$fb" 10

echo "== guard.sh: round-4 repros (U-A)"
fb=0
# HS-2: a source or eval whose code is invisible either way no longer hides the message files of the commit
t deny "$B" "source \"\$HOME/.nvm/nvm.sh\" && git commit -F msg_bad.txt"
t deny "$B" "export NVM_DIR=\"\$HOME/.nvm\"; \\. \"\$NVM_DIR/nvm.sh\"; git commit -F msg_bad.txt"
t deny "$B" "eval \"\$(ssh-agent -s)\" && git commit -m \"\$(cat msg_bad.txt)\""
# HS-4: words in a message or a grep pattern next to such a segment
t pass "$B" "source \"\$HOME/.nvm/nvm.sh\"; git commit -m \"Drop the stash fallback\""
t pass "$B" "source \"\$HOME/.nvm/nvm.sh\" && git log --oneline | grep -i stash"
t pass "$B" "eval \"\$(direnv export bash)\"; git commit -m 'drop pip from Makefile; python3 now via uv'"
t pass "$B" "eval \"\$(direnv export bash)\"; git commit -m 'Fix push notification retries'"
expect "guard (r4 HS-2): the 7 cases above were decided per segment, none by the whole-text fallback" "$fb" 0
# HS-2, HS-4: a segment that stays unparsed (eval of \$X) adds its own text only; parsed segments still decide
t deny "$B" "eval \"\$X\"; git commit -F msg_bad.txt"
t pass "$B" "eval \"\$X\"; git commit -m \"Drop the stash fallback\""
t pass "$B" "eval \"\$X\"; git commit -F - <<'EOF'${NL}fix: x${NL}${NL}pip install foo; git stash${NL}EOF"
t deny "$B" "eval \"\$X\"; echo 'git stash' | bash"
t ask  "$B" "eval \"\$X\"; git push"
expect "guard (r4 HS-2): the 5 cases with an eval of \$X used the fallback for that segment" "$fb" 5
fb=0
# HS-1, FI-1, FI-5: gh/glab aliases, every text-carrying gh/glab subcommand, git subtree/lfs push
t ask  "$B" "gh pr new --title x --body y"
t ask  "$B" "glab mr new -t x -d y"
t ask  "$B" "glab mr accept 12"
t ask  "$B" "glab mr for 12"
t ask  "$B" "git subtree push --prefix=dist origin gh-pages"
t ask  "$B" "git lfs push origin main"
t pass "$B" "git lfs pull"
t pass "$B" "git subtree split --prefix=dist"
t deny "$B" "gh pr new -t x -b \"$GW\""
t deny "$B" "glab mr comment 12 -m \"$GW\""
t deny "$B" "gh pr review 12 --comment -b \"Looks good. $GW\""
t deny "$B" "gh pr close 12 --comment \"Superseded by #13. $TR\""
t deny "$B" "gh pr merge 12 --squash --body \"$TR\""
t deny "$B" "gh issue create --title x --body \"$TR\""
t deny "$B" "gh issue comment 3 --body-file msg_bad.txt"
t deny "$B" "gh issue -R o/r edit 3 --title \"$GW\""
t deny "$B" "glab issue note 3 -m \"$TR\""
t pass "$B" "gh issue view 3"
t pass "$B" "gh pr view 3 --comments"
# HS-6: message files named through \$TMPDIR, \$PWD or \$(pwd)
printf 'fix: x\n\n%s\n' "$TR" >"$TMPDIR/commit_msg.txt"
t deny "$B" "git commit -F \"\$TMPDIR/commit_msg.txt\""
t deny "$B" "git commit -F \"\${TMPDIR}/commit_msg.txt\""
t deny "$B" "git commit -m \"\$(cat \"\$TMPDIR/commit_msg.txt\")\""
t deny "$B" "git commit -F - < \"\$TMPDIR/commit_msg.txt\""
t deny "$B" "gh pr create --title x --body-file \"\$TMPDIR/commit_msg.txt\""
t deny "$B" "git commit -F \"\$PWD/msg_bad.txt\""
t deny "$B" "git commit -F \"\$(pwd)/msg_bad.txt\""
t deny "$T" "cd $B && git commit -F \"\${PWD}/msg_bad.txt\""
t pass "$B" "git commit -F \"\$OTHER/msg_bad.txt\""
rm -f "$TMPDIR/commit_msg.txt"
# HS-7: a sed, grep, rg, awk or perl pattern that names the trailer is not a trailer
t pass "$B" "git commit --amend -m \"\$(git log -1 --format=%B | sed '/Co-Authored-By: Claude/d')\""
t pass "$B" "grep -qi 'co-authored-by: claude' msg_ok.txt || git commit -F msg_ok.txt"
t pass "$B" "git log -1 --format=%B | grep -v 'noreply@anthropic.com' > $T/m.txt && git commit --amend -F $T/m.txt"
t pass "$B" "git log -1 --format=%B | sed '/Co-Authored-By: Claude/d' | git commit --amend -F -"
t pass "$B" "awk '!/noreply@anthropic.com/' msg_bad.txt > clean.txt && git commit -F clean.txt"
t pass "$B" "perl -ne 'print unless /Co-Authored-By: Claude/' msg_bad.txt | git commit -F -"
t pass "$B" "rg -v 'Generated with \\[Claude' msg_bad.txt > clean.txt; git commit -F clean.txt"
t pass "$B" "echo '$TR' >> notes.md && git commit -m x"
t deny "$B" "printf 'fix: x\\n\\n$TR\\n' | git commit -F -"
t deny "$B" "cat <<'EOF' | git commit -F -${NL}fix: x${NL}${NL}$TR${NL}EOF"
t deny "$B" "git commit -F - <<'EOF'${NL}fix: x${NL}${NL}$TR${NL}EOF"
t deny "$B" "git commit -F - <<< \"$TR\""
# FI-8: uv run --project, and a bare python or pip that runs a uv repo's file from elsewhere
mkdir -p "$WT1/scripts"
t deny "$P" "cd /tmp && uv run --project $P pytest -q"
t deny "$T" "uv run --project=$P pytest -q"
t pass "$T" "uv run --project $P pytest -q --env-file .env.lane3"
t deny "$B" "cd $T && python3 $B/scripts/x.py"
t deny "$T" "python3 -I ~/code/api/scripts/x.py"
t deny "$HOME/code" "python3 api/scripts/x.py"
t deny "$T" "python3 $WT1/scripts/x.py"
t deny "$T" "pip install -r $B/requirements.txt"
t pass "$T" "$B/.venv/bin/python -m x"   # r6 HR-2: was deny; the program's own dir no longer counts
t pass "$T" "python3 $T/x.py"
t pass "$T" "/usr/bin/python3 $B/scripts/x.py"
t pass "$T" "python3 -c 'print(1)' $B/x.py"
expect "guard (r4): every alias, file, filter and dir case above was decided per segment" "$fb" 0
t ask  "$T" "gh pr new -t x 'oops"
t ask  "$T" "glab mr accept 3 'oops"
t ask  "$T" "git lfs push origin main 'oops"
expect "guard (r4 HS-1): the 3 unsplittable alias cases used the whole-text fallback" "$fb" 3

echo "== guard.sh: round-5 repros (V-A)"
fb=0
# HF-1: the message is written by an earlier segment of the same command (the files do not exist yet)
t deny "$B" "cat > \"\$TMPDIR/m1.txt\" <<'EOF'${NL}Fix x${NL}${NL}$TR${NL}EOF${NL}git commit -F \"\$TMPDIR/m1.txt\""
t deny "$B" "printf '%s\\n' 'Fix x' '' '$TR' > \"\$TMPDIR/m2.txt\" && git commit -F \"\$TMPDIR/m2.txt\""
t deny "$B" "printf 'fix: x\\n\\n$TR\\n' > m.txt; git commit -F m.txt"
t deny "$B" "MSG=\$(cat <<'EOF'${NL}Fix x${NL}${NL}$TR${NL}EOF${NL})${NL}git commit -m \"\$MSG\""
t deny "$B" "MSG=\"fix: x${NL}${NL}$TR\"; git commit -m \"\$MSG\""
t deny "$B" "git log -1 --format=%B > \"\$TMPDIR/m4.txt\" && git interpret-trailers --in-place --trailer '$TR' \"\$TMPDIR/m4.txt\" && git commit --amend -F \"\$TMPDIR/m4.txt\""
t deny "$B" "cat > \"\$TMPDIR/b.md\" <<'EOF'${NL}Summary${NL}${NL}$GW${NL}EOF${NL}gh pr comment 12 --body-file \"\$TMPDIR/b.md\""
t deny "$B" "cat > body.md <<'EOF'${NL}Summary${NL}${NL}$GW${NL}EOF${NL}gh pr create --title x --body-file body.md"
t deny "$B" "BODY=\"Summary. $GW\"; gh pr create --title x --body \"\$BODY\""
t deny "$B" "tee m.txt >/dev/null <<'EOF'${NL}fix: x${NL}${NL}$TR${NL}EOF${NL}git commit -m \"\$(cat m.txt)\""
t pass "$B" "git log -1 --format=%B | sed '/Co-Authored-By: Claude/d' > m.txt && git commit --amend -F m.txt"
t pass "$B" "printf 'fix: x\\n' > m.txt && git commit -F m.txt"
t pass "$B" "MSG='fix: x'; git commit -m \"\$MSG\""
t pass "$B" "echo '$TR' >> notes.md && git -C \"\$PWD\" commit -m x"
t ask  "$B" "BODY='Summary'; gh pr create --title x --body \"\$BODY\""
# HF-4: ANSI-C quoting, where \' does not end the word
t pass "$B" "git commit -m \$'Don\\'t use git stash'"
t pass "$B" "git commit -m \$'Don\\'t retry the push'"
t pass "$B" "eval \"\$(direnv export bash)\"; git commit -m \$'Don\\'t use git stash'"
t pass "$B" "git commit -m \$'Fix\\n\\nuse git stash later'"
t deny "$B" "git commit -m \$'Fix\\n\\n$TR'"
t deny "$B" "git commit -m \$'It\\'s done' && git stash"
t ask  "$B" "git commit -m \$'It\\'s done' && git push"
expect "guard (r5 HF-1, HF-4): the 22 cases above were decided per segment, none by the whole-text fallback" "$fb" 0
# HF-3: eval or bash -c of a variable set earlier in the command
t deny "$B" "CMD=\"git stash list\"; eval \"\$CMD\""
t deny "$B" "X=\"git stash list\"; bash -c \"\$X\""
t deny "$B" "export CMD='git stash list'; eval \"\$CMD\""
t ask  "$B" "P='git push origin main'; eval \"\${P}\""
t deny "$B" "X='pip install foo'; bash -c \"\$X\""
t pass "$B" "CMD='git status'; eval \"\$CMD\""
t pass "$B" "OTHER='git stash list'; eval \"\$CMD\""
expect "guard (r5 HF-3): the 7 eval or bash -c of \$X cases used the fallback for that segment" "$fb" 7

echo "== guard.sh: round-6 repros (W-A)"
fb=0
# HR-2: a uv repo's .venv/bin tool run by absolute path from outside the repo passes; its script and pip path
# operands still count, and a segment whose dir is in the repo still denies
t pass "$F" "$B/.venv/bin/python -m pytest tests/test_x.py -q 2>&1 | tail -5"
t pass "$T" "$B/.venv/bin/python build_decks.py merge"
t pass "$B" "cd $T && $B/.venv/bin/python gen_flow.py x"
t pass "$T" "$B/.venv/bin/ruff check app/routers 2>&1 | tail -20"
t pass "$T" "$B/.venv/bin/mypy app --strict 2>&1 | tail -3"
t pass "$T" "uv run --project $B python build_decks.py merge"
t deny "$T" "$B/.venv/bin/python $B/scripts/x.py"
t deny "$T" "$B/.venv/bin/pip install -e $B"
t deny "$B" "$B/.venv/bin/ruff check app"
# HR-3: bash -c of a literal script holding a $ is parsed; an accept token from an earlier export or NAME= counts
E6="export TEST_DATABASE_URL=postgresql://x"
t pass "$P" "$E6 && bash -c 'uv run pytest \$(cat tests.txt | tr \"\\n\" \" \") -p no:cacheprovider -q 2>&1 | tail -3'"
t pass "$P" "$E6 && bash -c 'for f in tests/test_*.py; do uv run pytest \"\$f\" -q; done'"
t deny "$P" "bash -c 'uv run pytest \$(cat tests.txt) -q'"
t pass "$P" "TEST_DATABASE_URL=postgresql://x; uv run pytest -q"
t deny "$P" "echo TEST_DATABASE_URL=postgresql://x; uv run pytest -q"
# HR-4: a heredoc or here-string fed to a filter whose output is the message still counts
t deny "$B" "grep -v '^#' <<'EOF' | git commit -F -${NL}Fix x${NL}# a comment${NL}${NL}$TR${NL}EOF"
t deny "$B" "sed 's/[[:space:]]*\$//' > \"\$TMPDIR/m6.txt\" <<'EOF'${NL}Fix x${NL}${NL}$TR${NL}EOF${NL}git commit -F \"\$TMPDIR/m6.txt\""
t deny "$B" "awk 'NF || p; {p = NF}' <<'EOF' | gh pr create --title x --body-file -${NL}## Summary${NL}${NL}$GW${NL}EOF"
t deny "$B" "git commit -m \"\$(sed 's/ *\$//' <<'EOF'${NL}Fix x${NL}${NL}$TR${NL}EOF${NL})\""
t deny "$B" "grep -v '^#' <<< \"$TR\" | git commit -F -"
t pass "$B" "grep -v '^#' <<'EOF' | git commit -F -${NL}Fix x${NL}# a comment${NL}EOF"
t pass "$B" "sed '/Co-Authored-By: Claude/d' <<'EOF' | git commit -F -${NL}Fix x${NL}EOF"
# HR-5: commands git runs for you, uvx and uv tool run, and function NAME { bodies
t deny "$P" "git submodule foreach git stash"
t deny "$P" "git submodule foreach --recursive 'git stash list'"
t deny "$P" "function f { git -C \"\$1\" stash list; }; f web"
t ask  "$P" "function p { git push origin HEAD; }; p"
t deny "$P" "uvx pytest tests -q"
t deny "$P" "uv tool run pytest -q"
t deny "$P" "git rebase --exec 'uv run pytest -q' origin/main"
t deny "$P" "git rebase -x 'uv run pytest -q' origin/main"
t deny "$P" "git bisect run uv run pytest -q"
t ask  "$P" "git submodule foreach 'git push'"
t pass "$P" "uvx pytest tests -q --env-file .env.lane3"
t pass "$P" "uvx ruff check ."
t pass "$P" "git submodule update --init --recursive"
t pass "$P" "git rebase -i origin/main"
t pass "$P" "git rebase --exec 'make lint' origin/main"
t pass "$P" "function f { echo stash; }; f"
expect "guard (r6 HR-2..5): the 37 cases above were decided per segment, none by the whole-text fallback" "$fb" 0
# HR-3: the fallback for an eval of a word holding \$T reads the accept token from an earlier export or NAME=
t pass "$P" "$E6 && T=\$(grep -rl x tests | sort -u | tr '\\n' ' ') && eval \"uv run pytest \$T -p no:cacheprovider -q\" 2>&1 | tail -2"
t pass "$P" "TEST_DATABASE_URL=postgresql://x; eval \"uv run pytest \$T -q\""
t deny "$P" "eval \"uv run pytest \$T -q\""
t deny "$P" "echo TEST_DATABASE_URL=postgresql://x; eval \"uv run pytest \$T -q\""
expect "guard (r6 HR-3): the 4 eval cases above used the fallback for that segment" "$fb" 4

echo "== guard.sh: round-7 repros (X-A)"
fb=0
# R6H-1: git runs several submodule foreach words and the bisect run words as an argv, so sh -c '...' stays one word
t deny "$P" "git submodule foreach sh -c 'git stash list'"
t ask  "$P" "git submodule foreach --recursive bash -c 'git push origin HEAD'"
t deny "$P" "git bisect run bash -c 'uv run pytest tests/test_x.py -q'"
t deny "$P" "git bisect run sh -c 'git stash && make test'"
t deny "$P" "git bisect run sh -c \"uv run pytest -q tests/test_x.py || exit 125\""
t pass "$P" "git bisect run sh -c 'export TEST_DATABASE_URL=postgresql://x; uv run pytest -q'"
# R6H-3: NAME=value or env NAME=value in front of bash -c, eval or git is in the nested pytest's environment
t pass "$P" "TEST_DATABASE_URL=postgresql://x git bisect run uv run pytest tests/test_x.py -q"
t pass "$P" "TEST_DATABASE_URL=postgresql://x git rebase --exec 'uv run pytest -q' main"
t pass "$P" "TEST_DATABASE_URL=postgresql://x git submodule foreach 'uv run pytest -q'"
t pass "$P" "TEST_DATABASE_URL=postgresql://x bash -c 'uv run pytest -q 2>&1 | tail -3'"
t pass "$P" "env TEST_DATABASE_URL=postgresql://x sh -c 'uv run pytest tests -q'"
t pass "$P" "timeout 900 env TEST_DATABASE_URL=postgresql://x bash -c 'uv run pytest -x -q'"
t pass "$P" "TEST_DATABASE_URL=postgresql://x eval 'uv run pytest -q'"
t deny "$P" "FOO=1 bash -c 'uv run pytest -q'"
t deny "$P" "bash -c 'TEST_DATABASE_URL=x true; uv run pytest -q'"
# R6H-4: a bare cat in the $( ) of a commit, gh or glab segment reads the text piped into that segment
t deny "$B" "cat <<'EOF' | gh pr comment 12 --body \"\$(cat)\"${NL}LGTM${NL}${NL}$GW${NL}EOF"
t deny "$B" "cat <<'EOF' | glab mr note 12 --message \"\$(cat)\"${NL}LGTM${NL}${NL}$GW${NL}EOF"
t deny "$B" "printf 'fix: x\\n\\n$TR\\n' | git commit -m \"\$(cat -)\""
t pass "$B" "cat <<'EOF' | gh pr comment 12 --body \"\$(cat)\"${NL}LGTM${NL}EOF"
t pass "$B" "echo '$GW' | gh pr comment 12 --body \"\$(echo LGTM | cat)\""
# R6H-5: uvx and uv tool run with a versioned tool
t deny "$P" "uvx pytest@8 tests -q"
t deny "$P" "uvx --python 3.12 pytest@latest tests -q"
t deny "$P" "uvx pytest==8.3.0 -q"
t deny "$P" "uv tool run 'pytest>=8' -q"
t pass "$P" "uvx pytest@8 tests -q --env-file .env.lane3"
t pass "$P" "uvx ruff@0.6 check ."
expect "guard (r7 X-A 1, 4-6): the 26 cases above were decided per segment, none by the whole-text fallback" "$fb" 0

echo "== guard.sh: round-8 repros (Y-A)"
fb=0
# R7H-1: a script an earlier segment wrote from a heredoc or here-string and a shell or a path then runs is parsed
# as nested code in the running segment's dir
t ask  "$B" "cat > F3-push.sh <<'EOF'${NL}set -e${NL}git -C $P push origin HEAD${NL}EOF${NL}bash F3-push.sh 2>&1 | tail -12"
t deny "$T" "cat > runall.sh <<'EOF'${NL}set -x${NL}cd $P${NL}uv run pytest tests -q${NL}EOF${NL}bash runall.sh > runall.log 2>&1"
t deny "$T" "cat > s.sh <<'EOF'${NL}git stash${NL}EOF${NL}sh s.sh"
t deny "$T" "cat > s.sh <<'EOF'${NL}git stash push -m wip${NL}EOF${NL}chmod +x s.sh && ./s.sh"
t deny "$T" "cat <<'EOF' | tee s.sh >/dev/null${NL}git stash list${NL}EOF${NL}bash -e s.sh"
t ask  "$T" "tee p.sh <<< 'git push origin HEAD' >/dev/null && bash p.sh"
t deny "$T" "cat > \"\$TMPDIR/r.sh\" <<'EOF'${NL}pip install requests${NL}EOF${NL}cd $B && bash \"\$TMPDIR/r.sh\""
t deny "$B" "cat > t.py <<'EOF'${NL}#!/usr/bin/env python3${NL}pip = 1${NL}EOF${NL}bash t.py"
t pass "$B" "cat > t.py <<'EOF'${NL}#!/usr/bin/env python3${NL}pip = 1${NL}EOF${NL}chmod +x t.py && ./t.py"
t pass "$T" "cat > s.sh <<'EOF'${NL}git stash${NL}EOF${NL}cat s.sh"
t pass "$T" "cat > a.sh <<'EOF'${NL}git stash${NL}EOF${NL}bash b.sh"
t pass "$T" "cat > \"\$TMPDIR/r.sh\" <<'EOF'${NL}pip install requests${NL}EOF${NL}bash \"\$TMPDIR/r.sh\""
expect "guard (r8 Y-A 1): the 12 cases above were decided per segment, none by the whole-text fallback" "$fb" 0

echo "== browser_cap.sh"
b() {  # want tool command cap procs (procs empty = the real pgrep)
  local p=$PATH
  [ -n "$5" ] && p=$T/bin-pgrep:$PATH
  out=$(jq -n --arg t "$2" --arg c "$3" '{tool_name:$t,tool_input:{command:$c}}' |
    PATH=$p FAKE_PROCS=$5 CLAUDE_BROWSER_PROC_MAX=$4 bash "$S/browser_cap.sh"); rc=$?
  report "$1" "$(decision "$out" $rc)" "browser: cap=${4:-unset} procs=${5:-real} $2 $3"
}
b pass Bash "uv run pytest -q" -1 ""
b deny Bash "npx playwright test --workers=1" -1 ""
b deny Bash "bash scripts/predeploy_gate.sh" -1 ""
b pass Bash "npx playwright test --workers=1" 40 3
b deny mcp__playwright1__browser_navigate "" -1 ""
b deny Bash "npm run e2e" -1 ""
b deny mcp__Claude_Browser__navigate "" -1 ""
b deny mcp__claude-in-chrome__computer "" -1 ""
b deny mcp__playwright1__browser_click "" "" 3
has "browser: deny reason states count and cap" "$(reason "$out")" "3 headless browser processes already running (cap 2)"
b pass mcp__playwright1__browser_click "" "" 2
b pass mcp__playwright1__browser_click "" 5 3
b pass mcp__playwright1__browser_click "" abc 1
mv "$WORKBENCH_CONFIG" "$T/workbench.json.off"
b pass mcp__playwright1__browser_click "" "" 25
b deny mcp__playwright1__browser_click "" "" 26
mv "$T/workbench.json.off" "$WORKBENCH_CONFIG"
out=$(jq -n '{tool_name:"mcp__playwright1__browser_click",tool_input:{}}' |
  PATH=$T/empty CLAUDE_BROWSER_PROC_MAX=-1 /bin/bash "$S/browser_cap.sh"); rc=$?
expect "browser: fails open without jq or pgrep" "rc=$rc out=[$out]" "rc=0 out=[]"
# r4 HS-8, DS-4: over the cap, a Bash call counts only when a segment launches a browser
b pass Bash "pgrep -f playwright-mcp | wc -l" -1 ""
b pass Bash "git log --oneline -- playwright.config.ts" -1 ""
b pass Bash "grep -rn e2e docs/" -1 ""
b pass Bash "git commit -m \"fix e2e flake in checkout\"" -1 ""
b pass Bash "cat e2e/README.md && npm run build" -1 ""
b deny Bash "cd web && npx playwright test" -1 ""
b deny Bash "pnpm dlx playwright test" -1 ""
b deny Bash "bunx playwright test --workers=1" -1 ""
b deny Bash "./node_modules/.bin/playwright test" -1 ""
b deny Bash "yarn run test:e2e" -1 ""
b deny Bash "pnpm e2e" -1 ""
b deny Bash "CI=1 npm run e2e -- --headed" -1 ""
b deny Bash "./scripts/run_e2e.sh" -1 ""
b deny Bash "echo 'npx playwright test' | bash" -1 ""
out=$(jq -n '{tool_name:"Bash",tool_input:{command:"pgrep -f playwright-mcp | wc -l"}}' |
  PATH=$T/bin-pgrep:$T/bin-nopy FAKE_PROCS=3 CLAUDE_BROWSER_PROC_MAX=1 /bin/bash "$S/browser_cap.sh"); rc=$?
report deny "$(decision "$out" $rc)" "browser (r4): without python3, a browser word anywhere still counts"
# r5 HF-2: an option value before the script or package name does not hide it
b deny Bash "npm --prefix ~/code/web run test:e2e" -1 ""
b deny Bash "npx --prefix ~/code/web playwright test" -1 ""
b deny Bash "npm run --prefix ~/code/web test:e2e" -1 ""
b deny Bash "npm -w web run test:e2e" -1 ""
b deny Bash "pnpm -C web e2e" -1 ""
b deny Bash "pnpm --filter web e2e" -1 ""
b deny Bash "yarn --cwd web test:e2e" -1 ""
b deny Bash "pnpm --dir web test:e2e" -1 ""
b deny Bash "bun --cwd web x playwright test" -1 ""
b deny Bash "npm --prefix web exec -- playwright test" -1 ""
b pass Bash "npm --prefix web run build" -1 ""
b pass Bash "pnpm --filter web add -D @playwright/test" -1 ""
b pass Bash "yarn --cwd e2e install" -1 ""
# r6 HR-1: node, deno, bun, tsx, ts-node and python launches
b deny Bash 'MAP_URL="http://127.0.0.1:8870/" node web/node_modules/@playwright/test/cli.js test -c scripts/e2e/playwright.config.js --workers=1 > var/e2e-run1.log 2>&1; pkill -f chrome-headless-shell' -1 ""
b deny Bash "node node_modules/@playwright/test/cli.js test --workers=1" -1 ""
b deny Bash "node -e \"const pw=require('@playwright/test'); (async()=>{const b=await pw.chromium.launch(); await b.close()})()\"" -1 ""
b deny Bash "cat > shots.mjs <<'EOF'${NL}import { chromium } from 'playwright';${NL}const b = await chromium.launch(); await b.close();${NL}EOF${NL}node shots.mjs \"\$PWD/preview.html\"" -1 ""
b deny Bash "node e2e/run-smoke.mjs" -1 ""
b deny Bash "python3 scripts/predeploy_gate.py" -1 ""
b deny Bash "uv run python scripts/e2e_x.py" -1 ""
b deny Bash "python3 - <<'EOF'${NL}from playwright.sync_api import sync_playwright${NL}EOF" -1 ""
b deny Bash "python3 -c 'from playwright.sync_api import sync_playwright'" -1 ""
b deny Bash "deno run -A e2e/smoke.ts" -1 ""
b deny Bash "tsx e2e/x.ts" -1 ""
b deny Bash "ts-node --transpile-only e2e/x.ts" -1 ""
b deny Bash "node --eval=\"require('puppeteer').launch()\"" -1 ""
b deny Bash "cat <<'EOF' | node${NL}const b = await require('puppeteer').launch()${NL}EOF" -1 ""
b pass Bash "grep -rn x e2e" -1 ""
b pass Bash "git log -- e2e" -1 ""
b pass Bash "npx eslint e2e/x.spec.ts" -1 ""
b pass Bash "node scripts/build.js" -1 ""
b pass Bash "echo e2e && node scripts/build.js" -1 ""
b pass Bash "node -e \"console.log(1)\"" -1 ""
b pass Bash "node -e \"console.log('e2e')\"" -1 ""
b pass Bash "bun add -D @playwright/test" -1 ""
b deny Bash "cat > pw.sh <<'EOF'${NL}node node_modules/@playwright/test/cli.js test${NL}EOF${NL}\$SP/cycle.sh pw.sh" -1 ""
b deny Bash "cat > pw.sh <<'EOF'${NL}npx playwright test${NL}EOF${NL}bash pw.sh" -1 ""
b pass Bash "cat > shots.mjs <<'EOF'${NL}const b = await chromium.launch();${NL}EOF${NL}echo written" -1 ""
b pass Bash "cat > pw.sh <<'EOF'${NL}npx playwright test${NL}EOF${NL}bash -c 'echo hi'" -1 ""
# r7 R6H-2: a runner behind npx, npm exec or pnpm/yarn; uv --with playwright; code piped in; a launch file edited
W7="cat > shoot.ts <<'EOF'${NL}import { chromium } from 'playwright';${NL}const b = await chromium.launch(); await b.close();${NL}EOF"
b deny Bash "$W7${NL}npx tsx shoot.ts" -1 ""
b deny Bash "npx tsx e2e/smoke.ts" -1 ""
b deny Bash "npm exec -- tsx e2e/smoke.ts" -1 ""
b deny Bash "yarn node -e \"require('puppeteer').launch()\"" -1 ""
b deny Bash "uv run --with playwright python scripts/shots.py" -1 ""
b deny Bash "uvx --with playwright python shots.py" -1 ""
b deny Bash "uv run -w playwright python scripts/shots.py" -1 ""
b deny Bash "echo \"const {chromium}=require('playwright'); chromium.launch().then(b=>b.close())\" | node" -1 ""
b deny Bash "sed -i '' 's|chromium.launch()|chromium.launch({executablePath: process.env.EXE})|' t.cjs && EXE=\$(ls -d ~/x/chrome-headless-shell) node t.cjs" -1 ""
b deny Bash "printf 'await require(\"puppeteer\").launch()\\n' >> t.cjs; node t.cjs" -1 ""
b pass Bash "echo e2e && npx tsx scripts/build.ts" -1 ""
b pass Bash "cat e2e/notes.md | node" -1 ""
b pass Bash "sed -i '' 's/e2e/smoke/' t.cjs && node t.cjs" -1 ""
b pass Bash "sed -i '' 's|chromium.launch()|x|' t.cjs && node other.cjs" -1 ""
b pass Bash "uv run --with playwright-stealth ruff check ." -1 ""
b deny Bash "sed -i '' 's#chromium.launch()#chromium.launch({ executablePath: process.env.CHS })#' ../tools/probe.mjs && cp ../tools/probe.mjs ./zz.mjs && node zz.mjs" -1 ""
b pass Bash "sed -i '' 's#chromium.launch()#x#' ../tools/probe.mjs && cp ../tools/other.mjs ./zz.mjs && node zz.mjs" -1 ""
# r7 R6H-6: .launch( counts only right after a browser word; commit and PR heredocs never count; a program run by
# path after a heredoc counts only when it names the file the heredoc wrote
b pass Bash "git commit -F - <<'EOF'${NL}Use chromium.launch() in the smoke test${NL}EOF${NL}./scripts/verify_dev.sh" -1 ""
b pass Bash "python3 - <<'EOF'${NL}import gradio as gr${NL}demo = gr.Interface(fn=str, inputs='text', outputs='text')${NL}demo.launch(share=False, inbrowser=True)${NL}EOF" -1 ""
b pass Bash "git commit -m \"\$(cat <<'EOF'${NL}test: drive chromium.launch() through playwright${NL}EOF${NL})\" && node scripts/build.js" -1 ""
b pass Bash "cat > n.md <<'EOF'${NL}playwright notes${NL}EOF${NL}./scripts/build.sh" -1 ""
b pass Bash "sh -s <<'EOF'${NL}demo.launch(share=True)${NL}EOF" -1 ""
b deny Bash "cat > x.sh <<'EOF'${NL}npx playwright test${NL}EOF${NL}./run.sh x.sh" -1 ""
b deny Bash "cat > \$SP/pw.sh <<'EOF'${NL}npx playwright test${NL}EOF${NL}chmod +x \$SP/pw.sh && \$SP/cycle.sh \$SP/pw.sh m12" -1 ""
b pass Bash "cat > \$SP/pw.sh <<'EOF'${NL}npx playwright test${NL}EOF${NL}\$SP/cycle.sh \$SP/other.sh" -1 ""
b deny Bash "cat > run.sh <<'EOF'${NL}const b = await chromium.launch()${NL}EOF${NL}chmod +x run.sh && ./run.sh" -1 ""
b deny Bash "node -e \"const b = await require('puppeteer').launch()\"" -1 ""
b deny Bash "python3 - <<'EOF'${NL}b = p.chromium.launch()${NL}EOF" -1 ""
b deny Bash "sh -s <<'EOF'${NL}await chromium.launch()${NL}EOF" -1 ""
# r8 R7H-2: .launch( also counts in text that names puppeteer (puppeteer-core included)
b deny Bash "S=\$TMPDIR; cat > \$S/shot.cjs <<'EOF'${NL}const pp = require('puppeteer-core');${NL}(async () => { const b = await pp.launch({ headless: 'new' }); await b.close(); })();${NL}EOF${NL}node \$S/shot.cjs" -1 ""
b deny Bash "cat > shot.mjs <<'EOF'${NL}import pptr from 'puppeteer';${NL}const b = await pptr.launch(); await b.close();${NL}EOF${NL}node shot.mjs" -1 ""
b deny Bash "node -e \"const pp = require('puppeteer'); pp.launch().then(b => b.close())\"" -1 ""
b deny Bash "node -e \"require('puppeteer-core').launch({headless: 'new'}).then(b => b.close())\"" -1 ""
b pass Bash "node -e \"require('puppeteer').connect({browserWSEndpoint: process.env.WS})\"" -1 ""
# r8 R7H-3: a writer fed by a pipe (cat <<EOF | tee F, echo CODE | tee F) writes launch text too
b deny Bash "cat <<'EOF' | tee run.sh${NL}npx playwright test --workers=1${NL}EOF${NL}chmod +x run.sh && ./run.sh" -1 ""
b deny Bash "cat <<'EOF' | tee x.sh >/dev/null${NL}npx playwright test${NL}EOF${NL}./run.sh x.sh" -1 ""
b deny Bash "echo \"require('playwright').chromium.launch()\" | tee t.js && node t.js" -1 ""
b deny Bash "printf '%s\\n' \"require('playwright').chromium.launch()\" | tee -a t.js >/dev/null; node t.js" -1 ""
b pass Bash "echo \"require('playwright').chromium.launch()\" | tee t.js && node other.js" -1 ""
b pass Bash "cat <<'EOF' | tee x.sh >/dev/null${NL}npx playwright test${NL}EOF${NL}./run.sh other.sh" -1 ""
# r8 R7H-7: uv run X.py runs X.py with python, and --with playwright counts for it
b deny Bash "uv run --with playwright shots.py" -1 ""
b deny Bash "uv run e2e/smoke.py" -1 ""
b deny Bash "cat > shot.py <<'EOF'${NL}from playwright.sync_api import sync_playwright${NL}with sync_playwright() as p:${NL}    b = p.chromium.launch()${NL}EOF${NL}uv run shot.py" -1 ""
b pass Bash "echo e2e && uv run scripts/build_pdf.py" -1 ""
# r8 Y-A 5: npx/bunx/pnpx (and npm|pnpm|yarn|bun exec|dlx|x) drop a version from the runner word
b deny Bash "npx tsx@4 e2e/smoke.ts" -1 ""
b deny Bash "bunx tsx@latest e2e/smoke.ts" -1 ""
b deny Bash "npm exec -- tsx@4 e2e/smoke.ts" -1 ""
b deny Bash "npx node@20 e2e/run.js" -1 ""
b pass Bash "echo e2e && npx tsx@4 scripts/build.ts" -1 ""
b pass Bash "npx eslint@9 e2e/x.spec.ts" -1 ""
# r8 Y-A 6: the real pgrep count. One fake process (bash running sleep, no browser) carries --remote-debugging-pipe
# in its argv ('; :' keeps bash from exec-ing sleep); with the cap at 0 it alone is above the cap. Killed by PID.
bash -c 'sleep 20; :' wbfake --remote-debugging-pipe & fake=$!
k=0
until ps -p "$fake" -o args= 2>/dev/null | grep -q -- '--remote-debugging-pipe' || [ $k -ge 20 ]; do
  sleep 0.1; k=$((k + 1))
done
b deny Bash "npx playwright test --workers=1" 0 ""
b deny mcp__playwright1__browser_navigate "" 0 ""
pkill -P "$fake" 2>/dev/null; kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
expect "browser (r8 Y-A 6): the fake process is gone" "$(kill -0 "$fake" 2>/dev/null && echo alive || echo gone)" gone

echo "== commit_gate.sh"
A=$T/repos/backend
mkrepo "$A" "git@example.invalid:acme/backend.git"
c() {  # want cwd command [label]; leaves $out, $why and $T/gate.err for has()
  out=$(payload "$3" "$2" | PATH="$T/bin-uv:$PATH" bash "$S/commit_gate.sh" 2>"$T/gate.err"); rc=$?
  why=$(reason "$out")
  report "$1" "$(decision "$out" $rc)" "gate: ${4:-$3}"
}
printf 'x = "BAD"\n' >"$A/bad.py"
c deny "$A" 'git commit -m "x"' "deny on a failing check, target from cwd"
has "gate: reason names the failing check" "$why" "Commit gate (nobad) failed, mirroring CI. Fix these, then commit again:"
has "gate: reason carries the check output" "$why" 'bad.py:1:x = "BAD"'
c deny "$T" "git -C $A commit -m x" "deny, target from git -C"
c deny "$T" "git -C \"$A\" commit -m x" "deny, target from quoted git -C"
c deny "$T" "cd $A && git add -A && git commit -m x" "deny, target from cd X &&"
c deny "$HOME" "cd ~/../repos/backend && git commit -m x" "deny, target from cd ~/..."
c pass "$A" "git status" "non-commit command ignored"
c pass "$A" "git log --oneline -3" "non-commit git command ignored"
c pass "$A" "git log --oneline | grep commit" "commit as a grep word is no commit"
c pass "$A" "echo commit" "commit as an echo word is no commit"
c deny "$T" "git -C $T/repos status; git -C $A commit -m x" "the commit segment's git -C wins, not the first one"
c deny "$A" "git commit -m \"x\" 'oops" "unsplittable command: regex fallback still gates"
c deny "$A" "true;>/dev/null git commit -m x" "(r3 S5) an operator glued to a redirection still ends the segment"
c deny "$A" "bash <<'EOF'${NL}git commit -m x${NL}EOF" "(r3 S3) a commit in a script fed to bash on stdin: regex fallback gates"
rm "$A/bad.py"
c pass "$A" 'git commit -m "x"' "pass with nothing changed"

mkdir -p "$A/sub"
printf 'y = 1\n' >"$A/good.py"; printf 'z = 1\n' >"$A/sub/two.py"; printf 'BAD\n' >"$A/notes.txt"; rm "$A/ok.py"
rm -f "$T/args.log"
c pass "$A" 'git commit -m "x"' "pass when clean (BAD only in a non-matching file; checks without files or with a bad regex skipped)"
expect "gate: {files} = changed existing matching files, deleted ok.py left out" "$(cat "$T/args.log" 2>/dev/null)" "[good.py]
[sub/two.py]"
git -C "$A" checkout -q -- ok.py; rm -rf "$A/good.py" "$A/sub" "$A/notes.txt"

# Hostile names: each would run a command if {files} were pasted in unquoted.
mkdir -p "$A/\$(touch .."
names=('$(touch pwned).py' '`touch pwned2`.py' 'semi;touch pwned3;.py' 'a b.py' '-x.py' '$(touch ../pwned4).py' $'nl\nx.py' "q'uote\".py" 'amp&touch pwned5&.py')
for nm in "${names[@]}"; do printf 'q = 1\n' >"$A/$nm"; done
rm -f "$T/args.log"
c pass "$A" 'git commit -m "x"' "hostile file names: checks run and pass"
want=$(for nm in "${names[@]}"; do case $nm in (-*) nm=./$nm ;; esac; printf '[%s]\n' "$nm"; done | LC_ALL=C sort)
expect "gate: every hostile name reaches the check as one literal argument (-x.py as ./-x.py)" \
  "$(LC_ALL=C sort "$T/args.log" 2>/dev/null)" "$want"
printf 'BAD\n' >"$A/\$(touch pwned).py"
c deny "$A" 'git commit -m "x"' "hostile file names: a failing check still denies"
has "gate: hostile name shown literally in the reason" "$why" '$(touch pwned).py:1:BAD'
for m in "$A/pwned" "$A/pwned2" "$A/pwned3" "$T/repos/pwned4" "$A/pwned5"; do
  expect "gate: nothing executed from file names (${m#"$T"/} absent)" "$([ -e "$m" ] && echo created || echo absent)" absent
done
for nm in "${names[@]}"; do rm -f "$A/$nm"; done; rm -rf "$A/\$(touch .."

# uv checks: worktree without .venv falls back to the primary checkout's; neither = skip.
WT=$T/repos/backend-wt
git -C "$A" worktree add -q "$WT" -b wt || { echo "fixture failed: worktree"; exit 1; }
mkdir -p "$WT/svc"; printf 's = 1\n' >"$WT/svc/s.py"
c pass "$WT" 'git commit -m x' "uv check skipped when no .venv exists anywhere"
mkdir "$A/.venv"
c deny "$WT" 'git commit -m x' "uv check in a worktree with no .venv runs on the primary's"
has "gate: UV_PROJECT_ENVIRONMENT points at the primary .venv" "$why" "uv-env=$A/.venv"
has "gate: {files} reaches the uv command" "$why" "uv-args=run --no-sync --quiet probe svc/s.py"
mkdir "$WT/.venv"
c deny "$WT" 'git commit -m x' "uv check with the worktree's own .venv"
has "gate: own .venv means no UV_PROJECT_ENVIRONMENT override" "$why" "uv-env=unset"
rm -rf "$A/.venv" "$WT/.venv" "$WT/svc"

FE=$T/repos/frontend
mkrepo "$FE" "https://example.invalid/acme/frontend.git"
printf 'const x = "BAD";\n' >"$FE/x.ts"
c pass "$FE" 'git commit -m x' "skip when require (node_modules/.bin/tsc) is missing"
mkdir -p "$FE/node_modules/.bin"; : >"$FE/node_modules/.bin/tsc"
c deny "$FE" 'git commit -m x' "runs once require exists"
has "gate: frontend reason names its check" "$why" "Commit gate (nobad-ts) failed"

# Remote match: the origin's owner/repo must equal "remote" exactly (scheme, host, .git and case ignored).
R=$T/repos/remotes
mkrepo "$R" "git@example.invalid:acme/backend-infra.git"; printf 'BAD\n' >"$R/bad.py"
c pass "$R" 'git commit -m x' "remote acme/backend does not match acme/backend-infra"
for u in "https://example.invalid/Acme/Backend.git" "ssh://git@example.invalid:2222/acme/backend.git" \
         "https://example.invalid/acme/backend/" "git@example.invalid:acme/backend"; do
  git -C "$R" remote set-url origin "$u"
  c deny "$R" 'git commit -m x' "remote acme/backend matches $u"
done
for u in "https://example.invalid/other/acme/backend.git" "https://example.invalid/acme/backend2.git" \
         "git@example.invalid:acme"; do
  git -C "$R" remote set-url origin "$u"
  c pass "$R" 'git commit -m x' "remote acme/backend does not match $u"
done

mkrepo "$T/repos/other" "https://example.invalid/acme/other.git"; printf 'BAD\n' >"$T/repos/other/bad.py"
c pass "$T/repos/other" 'git commit -m x' "skip for an unknown remote"
mkrepo "$T/repos/noorigin"; printf 'BAD\n' >"$T/repos/noorigin/bad.py"
c pass "$T/repos/noorigin" 'git commit -m x' "skip when there is no origin"
c pass "$T" "git -C $T/repos/missing commit -m x" "skip when the target is not a repo"

# A check whose tool is missing is skipped with a note, and later checks still run.
TL=$T/repos/tools
mkrepo "$TL" "git@example.invalid:acme/tools.git"; printf 'y = 1\n' >"$TL/new.py"
c pass "$TL" 'git commit -m x' "missing tools: exit 127, 'command not found', 'Failed to spawn' all skip"
for n in missing notfound spawn; do
  has "gate: skip note for $n on stderr" "$(cat "$T/gate.err")" "workbench commit gate: $n skipped"
  has "gate (r4 FI-6): skip note for $n reaches Claude as additionalContext" "$(ctx "$out")" \
    "$n skipped, a tool it runs is missing"
done
ST=$T/repos/strict
mkrepo "$ST" "git@example.invalid:acme/strict.git"; printf 'y = 1\n' >"$ST/new.py"
c deny "$ST" 'git commit -m x' "(r4 FI-6) on_missing_tool deny: a missing tool denies the commit"
has "gate (r4 FI-6): the deny names the check and the missing tool" "$why" \
  "Commit gate (missing) could not run: a tool it needs is missing (exit 127)"
printf 'BAD\n' >"$TL/new.py"
c deny "$TL" 'git commit -m x' "missing tools skipped, the next check still denies"
has "gate: the denying check is the one after the skips" "$why" "Commit gate (nobad-tools) failed"

# r4 HS-9: a check whose tools live in a tracked .venv or node_modules is skipped, with a note
TK=$T/repos/tracked
mkrepo "$TK" "git@example.invalid:acme/tracked.git"
mkdir -p "$TK/.venv/bin" "$TK/node_modules/.bin"
for tool in .venv/bin/probe node_modules/.bin/lint; do
  printf '#!/bin/sh\necho "%s ran" >>"%s"\nexit 1\n' "$tool" "$T/tracked.log" >"$TK/$tool"; chmod +x "$TK/$tool"
done
git -C "$TK" add -f .venv/bin/probe node_modules/.bin/lint && git -C "$TK" commit -qm tools
printf 'y = 1\n' >"$TK/new.py"
c pass "$TK" 'git commit -m x' "(r4 HS-9) checks skipped while the repo tracks .venv and node_modules"
has "gate (r4 HS-9): node check skip note reaches Claude" "$(ctx "$out")" \
  "node-tracked skipped: the repo tracks files under node_modules"
has "gate (r4 HS-9): uv check skip note reaches Claude" "$(ctx "$out")" \
  "uv-tracked skipped: the repo tracks files under .venv"
expect "gate (r4 HS-9): no tracked tool ran" "$(cat "$T/tracked.log" 2>/dev/null)" ""
git -C "$TK" rm -rq --cached .venv node_modules && git -C "$TK" commit -qm untrack
c deny "$TK" 'git commit -m x' "(r4 HS-9) the same checks run once nothing under .venv or node_modules is tracked"

# r4 HS-3: an opaque segment makes no commit out of a non-commit command
printf 'x = "BAD"\n' >"$A/bad.py"
c pass "$A" "source \"\$HOME/.nvm/nvm.sh\" && git log --oneline -5 | grep -i commit" "(r4 HS-3) source \$HOME/x && git log | grep commit"
c pass "$A" "eval \"\$(brew shellenv)\"; cat > NOTES.md <<'EOF'${NL}Run git commit only after lint.${NL}EOF" \
  "(r4 HS-3) eval \$(...) then a heredoc that mentions git commit"
c pass "$A" "eval \"\$X\"; cat > NOTES.md <<'EOF'${NL}Run git commit only after lint.${NL}EOF" \
  "(r4 HS-3) eval \$X then a heredoc that mentions git commit: the fallback reads only the eval"
c deny "$A" "eval \"\$X\"; git commit -m x" "(r4 HS-3) eval \$X; git commit: the parsed commit still gates"
c deny "$T" "bash <<'EOF'${NL}cd $A && git commit -m x${NL}EOF" "(r4 HS-3) a commit inside a script on stdin gates the dir it cds to"
c deny "$A" "X='git commit -m x'; eval \"\$X\"" "(r5 HF-3) eval of \$X set to a commit earlier in the command gates"
c pass "$A" "X='git log -1'; eval \"\$X\"; echo 'git commit later'" "(r5 HF-3) eval of \$X set to a non-commit does not gate"
c deny "$A" "git rebase -x 'git commit --amend --no-edit' HEAD~1" "(r6 HR-5) a commit that git rebase --exec runs gates"
c deny "$T" "git -C $A submodule foreach 'git commit -am x'" "(r6 HR-5) a commit that git submodule foreach runs gates, in that dir"
c pass "$A" "git rebase -x 'make lint' HEAD~1" "(r6 HR-5) git rebase --exec of a non-commit does not gate"
c deny "$T" "git -C $A submodule foreach sh -c 'git commit -am x'" "(r7 R6H-1) a commit in a multi-word submodule foreach sh -c string gates"
c deny "$A" "git bisect run sh -c 'git commit -am x'" "(r7 R6H-1) a commit in git bisect run sh -c '...' gates"
rm "$A/bad.py"

# r4 HS-5: 5,000 changed files with 1.2 MB of names run in chunks, under the argument size limits
MANY=$T/repos/many
mkrepo "$MANY" "git@example.invalid:acme/many.git"
D=$MANY/src/$(printf 'd%.0s' $(seq 1 200))
mkdir -p "$D" && (cd "$D" && seq 1 5000 | sed 's/.*/generated_component_number_&.ts/' | xargs touch)
rm -f "$T/many.log"; start=$SECONDS
c pass "$MANY" 'git add -A && git commit -m x' "(r4 HS-5) 5,000 changed files: every chunk passes"
el=$((SECONDS - start))
expect "gate (r4 HS-5): all 5,000 names reached the check" "$(wc -l <"$T/many.log" 2>/dev/null | tr -d ' ')" 5000
expect "gate (r4 HS-5): 5,000 files gated within 20 s" "$([ $el -le 20 ] && echo yes || echo "no (${el}s)")" yes
printf 'BAD\n' >"$D/generated_component_number_999.ts"
c deny "$MANY" 'git commit -m x' "(r4 HS-5) a failing file in a later chunk still denies"
has "gate (r4 HS-5): the deny shows the failing file" "$why" "generated_component_number_999.ts"
rm -rf "$MANY"

printf 'x = "BAD"\n' >"$A/bad.py"
mv "$WORKBENCH_CONFIG" "$T/workbench.json.off"
c pass "$A" 'git commit -m x' "no workbench.json: gate off"
printf '{not json' >"$WORKBENCH_CONFIG"
c pass "$A" 'git commit -m x' "malformed workbench.json: gate off"
mv "$T/workbench.json.off" "$WORKBENCH_CONFIG"
out=$(payload 'git commit -m x' "$A" | PATH=$T/empty /bin/bash "$S/commit_gate.sh"); rc=$?
expect "gate: fails open without jq" "rc=$rc out=[$out]" "rc=0 out=[]"
out=$(payload 'git commit -m x' "$A" | PATH=$T/bin-nopy /bin/bash "$S/commit_gate.sh" 2>/dev/null); rc=$?
report deny "$(decision "$out" $rc)" "gate: without python3 the regex fallback still gates"
rm "$A/bad.py"

SL=$T/repos/slow
mkrepo "$SL" "https://example.invalid/acme/slow.git"; printf 'a\n' >"$SL/new.txt"
start=$SECONDS
out=$(payload 'git commit -m x' "$SL" | WORKBENCH_GATE_TIMEOUT=2 bash "$S/commit_gate.sh" 2>"$T/slow.err"); rc=$?
el=$((SECONDS - start))
report pass "$(decision "$out" $rc)" "gate: a check over the time budget fails open"
expect "gate: over-budget check returns within 8 s" "$([ $el -le 8 ] && echo yes || echo "no (${el}s)")" yes
has "gate: over-budget note on stderr" "$(cat "$T/slow.err")" "slow ran out of time"
gone "gate: over-budget check killed" 'sleep 47[.]31'

LK=$T/repos/leaky
mkrepo "$LK" "https://example.invalid/acme/leaky.git"; printf 'a\n' >"$LK/new.txt"
start=$SECONDS
c deny "$LK" 'git commit -m x' "a check that leaves a child holding its output still returns"
el=$((SECONDS - start))
expect "gate: leaky check returns within 8 s" "$([ $el -le 8 ] && echo yes || echo "no (${el}s)")" yes
expect "gate: reason = header + first 25 non-blank lines" \
  "$(printf '%s\n' "$why" | wc -l | tr -d ' ') $(printf '%s\n' "$why" | tail -1)" "26 line 25"
gone "gate: child left by the check killed" 'sleep 48[.]31'
expect "gate: every temp dir removed (TMPDIR empty)" "$(ls -A "$TMPDIR")" ""

echo "== format_py.sh"
mkrepo "$PY"; printf '[tool.ruff]\nline-length = 100\n' >"$PY/pyproject.toml"; mkdir "$PY/.venv"
fmt() {  # label file want-log
  rm -f "$T/uv.log"
  out=$(jq -n --arg f "$2" '{tool_name:"Edit",tool_input:{file_path:$f}}' |
    PATH="$T/bin-uv:$PATH" FAKE_UV_LOG="$T/uv.log" FAKE_UV_RC=0 bash "$S/format_py.sh"); rc=$?
  expect "format: $1" "rc=$rc out=[$out] log=[$(cat "$T/uv.log" 2>/dev/null)]" "rc=0 out=[] log=[$3]"
}
fmt "formats then fixes a .py in a ruff project with .venv" "$PY/ok.py" "uv run --no-sync --quiet ruff format -q $PY/ok.py
uv run --no-sync --quiet ruff check --fix -q $PY/ok.py"
fmt "ignores non-.py files" "$PY/pyproject.toml" ""
fmt "skips a missing file" "$PY/nope.py" ""
printf 'x = 1\n' >"$T/loose.py"
fmt "skips a file outside git" "$T/loose.py" ""
rmdir "$PY/.venv"
fmt "skips when the project has no .venv" "$PY/ok.py" ""
mkdir "$PY/.venv"; printf '[project]\nname = "x"\n' >"$PY/pyproject.toml"
fmt "skips when pyproject does not mention ruff" "$PY/ok.py" ""
printf '[tool.ruff]\n' >"$PY/pyproject.toml"
mkdir -p "$PY/.venv/bin"; printf '#!/bin/sh\n' >"$PY/.venv/bin/ruff"
git -C "$PY" add -f .venv/bin/ruff
fmt "skips when .venv is committed (git ls-files .venv lists it)" "$PY/ok.py" ""
git -C "$PY" rm -q --cached .venv/bin/ruff
fmt "formats again once .venv is untracked" "$PY/ok.py" "uv run --no-sync --quiet ruff format -q $PY/ok.py
uv run --no-sync --quiet ruff check --fix -q $PY/ok.py"
PY2=$T/repos/notuv
mkrepo "$PY2"; printf '[tool.ruff]\n' >"$PY2/pyproject.toml"; mkdir "$PY2/.venv"
fmt "skips a ruff project with .venv outside uv_repos" "$PY2/ok.py" ""

echo "== names (r4 DS-10)"
pat='h[a]rsh|a[h]ir|e[r]p-|E[R]P_|p[c]kg|t[e]nant'
expect "names: the hook scripts, hooks.json and this test hold no personal or project-specific names" \
  "$(grep -liE "$pat" "$S"/* "$S/../hooks/hooks.json" "$0" 2>/dev/null)" ""
expect "names: hooks.json says workbench.json is in the Claude config folder, not a fixed path" \
  "$(grep -c '~/.claude/workbench.json' "$S/../hooks/hooks.json")/$(grep -c 'workbench.json in the Claude config folder' "$S/../hooks/hooks.json")" "0/1"

echo "== guard.sh timing (informational)"
/usr/bin/env python3 -I - "$S/guard.sh" "$B" <<'EOF'
import json, statistics, subprocess, sys, time
guard, cwd = sys.argv[1], sys.argv[2]
for cmd in ("ls -la", "git status", "git commit -m \"fix: x\" && git log --oneline -3", "pip install requests"):
    data = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd})
    runs = []
    for _ in range(21):
        t0 = time.perf_counter()
        subprocess.run(["bash", guard], input=data, capture_output=True, text=True)
        runs.append((time.perf_counter() - t0) * 1000)
    print("     median %5.1f ms over 21 calls: %s" % (statistics.median(runs), cmd))
EOF

echo
printf '%d passed, %d failed\n' "$passes" "$fails"
[ "$fails" = 0 ]
