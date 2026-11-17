#!/bin/bash
# workbench PreToolUse guard for Bash. It reasons per shell segment (cmdparse.py, which also splits the code that
# bash -c, eval, git submodule foreach, git rebase --exec and git bisect run run, and a script the same command
# wrote from a heredoc or here-string and then runs: cat > s.sh <<EOF ... EOF; bash s.sh, or ./s.sh unless its #!
# line names a non-shell), so words inside commit messages, heredocs or grep patterns never count. Rules 1-3 are
# always on; 4-5 come from workbench.json (missing key = off).
# Every deny is checked before the ask, so one denied segment blocks the whole command.
#   1. git stash -> deny (the stash is shared by every worktree of a repo)
#   2. a Claude trailer in a git commit, or in any gh pr|issue or glab mr|issue segment (body, comment, review,
#      title) -> deny. Looks at the segment's own text (with sed, grep, rg, awk and perl patterns inside its $(...)
#      left out), the heredoc and here-string bodies it reads, the text piped into it when it reads its message
#      from stdin (-F -, /dev/stdin, or a bare cat in its $(...) such as --body "$(cat)"), and every file the
#      message can come from: -F (also in a group like -aF), --file or --body-file; when it reads stdin, the < file
#      or the `cat F |` before it; and F in a $(cat F), `cat F` or $(<F).
#      Paths may start with ~, $HOME, $TMPDIR, $PWD or $(pwd); regular files only, first 1 MiB. When the segment
#      reads a file or stdin, or has a $VAR word, the text of every earlier segment of the command counts too
#      (cat > m <<EOF ... EOF && git commit -F m; MSG=...; git commit -m "$MSG"); of sed, grep, rg, awk and perl
#      only the heredoc and here-string bodies they read count, never their words.
#   3. git push, git subtree push, git lfs push, gh pr create|new|merge, glab mr create|new|for|merge|accept -> ask.
#      gh/glab options such as -R x are skipped.
#   4. pytest, py.test, python -m pytest or coverage run (-m pytest or .../pytest), also behind uv run, env X=1,
#      timeout N, nice or time, also uvx or uv tool run (pytest@8, pytest==8.3 included), with the segment's dir
#      under pytest_env_required.paths and no accept token in the segment, in an earlier segment that sets a
#      variable (export NAME=..., NAME=...), or in the NAME=value words in front of the bash -c, eval or git
#      command that runs it (T=x bash -c '...', env T=x git bisect run ...) -> deny
#   5. python, python3(.N), pip, pip3(.N) or a .venv/bin/ program as the command with the segment's dir under
#      uv_repos, or a bare or .venv/bin python or pip whose script or path operand is under uv_repos -> deny.
#      uv run python and /usr/bin/python3 pass, and so does a uv repo's .venv/bin tool run from outside the repo.
# A segment's dir follows cd, git -C and uv --directory or --project. "Under" a path means that path or inside it,
# or a worktree whose primary checkout is. The command must hold one of the rules' words (git, gh, glab, pytest,
# py.test, python, pip, .venv/bin) once quotes and backslashes are removed, or the guard exits after one jq call.
# A segment cmdparse marks unparsed (a shell reading stdin, eval of $X, bash -c of a bare $X, either of printed
# text) also gets whole-text regexes over its own text, heredoc bodies and what is piped into it (for eval or
# bash -c of $X, also the earlier X=... or export X=...), from its dir; they can only add findings. Their pytest
# accept-token check also reads the earlier segments that set a variable, as the per-segment rule does. When
# cmdparse cannot run (no python3), the regexes run over the whole command from the cwd.
# ponytail: a shell-like reading of the text, not a sandbox; a determined workaround can still slip past.
command -v jq >/dev/null 2>&1 || exit 0
case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
[ -f "$here/kitconf.sh" ] && . "$here/kitconf.sh"
type kit_get >/dev/null 2>&1 || { kit_get() { :; }; kit_paths() { :; }; kit_under() { return 1; }; }

in=$(cat)
# The request for cmdparse, or nothing when the command field holds no rule's word (cwd is not looked at). A quote
# or backslash between the letters still counts (gi''t): each word becomes g["\\']*i["\\']*t in one regex, which
# stays fast on a 1 MB heredoc, where removing the quotes with split and join does not.
req=$(jq -c '(.tool_input.command // "" | tostring) as $c
  | ("[\"\\\\" + ([39] | implode) + "]*") as $q
  | (["git", "gh", "glab", "pytest", "py.test", "python", "pip", ".venv/bin"]
     | map(split("") | map(if . == "." then "\\." else . end) | join($q)) | join("|")) as $kw
  | select($c | test($kw))
  | {command: $c, cwd: (.cwd // "" | tostring)}' <<<"$in" 2>/dev/null) || exit 0
[ -n "$req" ] || exit 0

TRAILER='co-authored-by:[[:space:]]*claude|noreply@anthropic\.com|generated with \[?claude'
US=$'\037'
NL=$'\n'
STASH_MSG="git stash is shared across worktrees. Commit to a WIP branch instead."
UV_MSG="Use uv run (e.g. uv run pytest, uv run python -m ...), not bare python, pip or .venv/bin."
stash=0; trailer=0; ask=0; pyt=""; uvd=""; fbd=""; acc=""

decide() {  # $1 = allow|deny|ask, $2 = reason shown to Claude
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  exit 0
}
deny_trailer() {
  local who
  who=$(kit_get .author)
  [ -n "$who" ] && decide deny "Commits are authored by $who alone. Drop the Claude trailer and any mention of Claude."
  decide deny "Commits and PR text carry no Claude attribution. Drop the Claude trailer and any mention of Claude."
}
deny_pytest() {  # $1 = newline-separated accept tokens
  local t list=""
  while IFS= read -r t; do [ -n "$t" ] && list="$list${list:+, }$t"; done <<EOF
$1
EOF
  decide deny "pytest here must name its test database, or it falls back to the default one. Add one of: $list"
}
ask_push() {
  local who
  who=$(kit_get .author)
  decide ask "Pushing, opening or merging a PR/MR needs ${who:-the user}'s go-ahead in this session."
}
accept_tokens() { kit_get '.pytest_env_required.accept[]? | strings | select(. != "")'; }
file_has_trailer() {  # $1 = absolute file name. Regular files only, first 1 MiB.
  [ -f "$1" ] && head -c 1048576 -- "$1" 2>/dev/null | grep -Eiq "$TRAILER"
}
under_any() {  # $1 = newline-separated dirs, $2 = newline-separated roots
  local d
  [ -n "$2" ] || return 1
  while IFS= read -r d; do
    [ -n "$d" ] && kit_under "$d" "$2" && return 0
  done <<EOF
$1
EOF
  return 1
}
verdict() {  # the strictest finding wins
  [ "$stash" = 1 ] && decide deny "$STASH_MSG"
  [ "$trailer" = 1 ] && deny_trailer
  [ -n "$pyt" ] && under_any "$pyt" "$(kit_paths '.pytest_env_required.paths[]?')" && deny_pytest "$acc"
  [ -n "$uvd" ] && under_any "$uvd" "$(kit_paths '.uv_repos[]?')" && decide deny "$UV_MSG"
  [ "$ask" = 1 ] && ask_push
  exit 0
}

scan_text() {  # $1 = text, $2 = newline-separated dirs, $3 = more text for the accept tokens. Whole-text regexes;
  # they only add findings.
  # The text is checked twice: with quotes and backslashes removed (gi''t), and with each quote as a line break,
  # so a quoted script (echo 'pip x' | bash) starts a line.
  local cmd tok ok
  cmd=$(printf '%s' "$1" | tr -d "\\\\\"'")$NL$(printf '%s' "$1" | tr "\"'" '\n\n')
  local G='(^|[^[:alnum:]_-])git([[:space:]].*)?[[:space:]]' E='([[:space:];&|)]|$)' W='(^|[^[:alnum:]_-])'
  grep -Eq "${G}stash$E" <<<"$cmd" && stash=1
  if grep -Eq "${G}commit$E|${W}(gh[[:space:]]+(pr|issue)|glab[[:space:]]+(mr|issue))$E" <<<"$cmd" &&
     grep -Eiq "$TRAILER" <<<"$cmd"; then
    trailer=1
  fi
  if grep -Eq "${W}(pytest|py\\.test)$E" <<<"$cmd"; then
    [ -n "$acc" ] || acc=$(accept_tokens)
    if [ -n "$acc" ]; then
      ok=0
      while IFS= read -r tok; do
        [ -n "$tok" ] && grep -Fq -- "$tok" <<<"$cmd$NL$3" && ok=1
      done <<EOF
$acc
EOF
      [ "$ok" = 1 ] || pyt=$pyt$2
    fi
  fi
  grep -Eq "(^|[;&|(][[:space:]]*)(python(3(\\.[0-9]+)?)?|pip(3(\\.[0-9]+)?)?|\\.venv/bin/[[:alnum:]_.-]+)$E" <<<"$cmd" &&
    uvd=$uvd$2
  grep -Eq "${G}push$E|${W}gh[[:space:]]+pr[[:space:]]+(create|new|merge)$E|${W}glab[[:space:]]+mr[[:space:]]+(create|new|for|merge|accept)$E" <<<"$cmd" &&
    ask=1
  return 0
}
whole() {  # $1 = why. Regexes over the whole command, from the cwd.
  echo "workbench guard: whole-text check ($1)" >&2
  scan_text "$(jq -r .command <<<"$req")" "$(jq -r .cwd <<<"$req")$NL"
  verdict
}

# One line per finding: kind<US>value. jq reads the segments.
CLASSIFY='
def base: sub(".*/"; "");
def pyexe: test("^python(3(\\.[0-9]+)?)?$");
def pyname: test("^(python(3(\\.[0-9]+)?)?|pip(3(\\.[0-9]+)?)?)$");
def venvbin: startswith(".venv/bin/") or contains("/.venv/bin/");
def setter: (.argv[0]? // "") == "export" or .assigns == true;
def mod($m): . as $a | any(range(0; length); $a[.] == "-m" + $m or ($a[.] == "-m" and $a[. + 1] == $m));
def runs_pytest: . as $a | ((.[0] // "") | base) as $p
  | $p == "pytest" or $p == "py.test"
    or (($p | pyexe) and ($a | mod("pytest")))
    or ((($p | test("^coverage[0-9.-]*$")) or (($p | pyexe) and ($a | mod("coverage"))))
        and any($a[]; . == "run")
        and (($a | mod("pytest")) or any($a[1:][]; base | IN("pytest", "py.test"))));
def words: reduce .[1:][] as $w ({skip: false, out: []};
    if .skip then .skip = false
    elif ($w | startswith("-")) then .skip = ($w | IN("-R", "--repo"))
    else .out += [$w] end) | .out;
. as $segs
| ($acc | split("\n") | map(select(. != ""))) as $tok
| range(0; $segs | length) as $k | $segs[$k] as $s | ($s.argv // []) as $a
| (($a[0] // "") | base) as $p | ($s.git.sub? // "") as $g
| (if $p == "gh" or $p == "glab" then $a | words else [] end) as $w
| (if $s.unparsed then "fb" + $us + $s.dir else empty end),
  (if $g == "stash" then "stash" else empty end),
  (if $g == "commit"
      or ($p == "gh" and ($w[0] | IN("pr", "issue")))
      or ($p == "glab" and ($w[0] | IN("mr", "issue")))
   then (if (($s.text // "") | test($tr; "i")) or ($s.stdin_msg and (($s.feed // "") | test($tr; "i")))
            or (($s.pretext // "") | test($tr; "i"))
         then "trailer" else empty end),
        ((($s.msgfiles // []) + ($s.subfiles // []))[] | "file" + $us + .)
   else empty end),
  (if $g == "push" or (($g == "subtree" or $g == "lfs") and any(($s.git.args // [])[]; . == "push"))
      or ($p == "gh" and $w[0] == "pr" and ($w[1] | IN("create", "new", "merge")))
      or ($p == "glab" and $w[0] == "mr" and ($w[1] | IN("create", "new", "for", "merge", "accept")))
   then "ask" else empty end),
  (if ($tok | length) > 0 and (($a | runs_pytest) or (($s.uv_run // []) | runs_pytest))
      and ([$s.raw, ($s.envpre // ""), ($segs[0:$k][] | select(setter) | .raw)]
           | any(.[]; . as $r | any($tok[]; . as $t | $r | contains($t))) | not)
   then "pytest" + $us + $s.dir else empty end),
  (if (($a[0] // "") | pyname or venvbin) then ($s.dir, ($s.pydirs // [])[]) | "uv" + $us + . else empty end)'

segs=$(/usr/bin/env python3 -I "$here/cmdparse.py" <<<"$req" 2>/dev/null) || whole "cmdparse.py did not run"
case $segs in *pytest*|*py.test*) acc=$(accept_tokens) ;; esac
plan=$(printf '%s\n' "$segs" | jq -rs --arg tr "$TRAILER" --arg acc "$acc" --arg us "$US" "$CLASSIFY" 2>/dev/null) ||
  whole "segment check failed"

while IFS=$US read -r kind a; do
  case $kind in
    stash) stash=1 ;;
    trailer) trailer=1 ;;
    file) [ "$trailer" = 1 ] || { file_has_trailer "$a" && trailer=1; } ;;
    ask) ask=1 ;;
    pytest) pyt=$pyt$a$NL ;;
    uv) uvd=$uvd$a$NL ;;
    fb) fbd=$fbd$a$NL ;;
  esac
done <<EOF
$plan
EOF

if [ -n "$fbd" ]; then
  echo "workbench guard: whole-text check (cannot split the command, or a segment runs code it cannot see)" >&2
  scan_text "$(printf '%s\n' "$segs" | jq -r 'select(.unparsed) | .fb // .raw' 2>/dev/null)" "$fbd" \
    "$(printf '%s\n' "$segs" | jq -rs '. as $s | ([range(length) | select($s[.].unparsed)] | max) as $u
      | ($s[0:$u][] | select((.argv[0]? // "") == "export" or .assigns == true) | .raw),
        ($s[] | select(.unparsed) | .envpre // empty)' 2>/dev/null)"
fi
verdict
