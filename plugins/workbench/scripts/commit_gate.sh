#!/bin/bash
# workbench PreToolUse on Bash: before a `git commit`, run the checks workbench.json lists for the repo's origin
# on the changed files, and deny the commit when one fails. A commit is a segment whose git subcommand is commit
# (cmdparse.py), run in that segment's dir, so `git log | grep commit` is no commit and `git -C a status;
# git -C b commit` gates b. That includes a commit inside bash -c, eval, git rebase --exec, git submodule foreach
# or git bisect run. A segment cmdparse cannot see into (a shell reading stdin, eval of $X) gates only
# when its own text holds a git ... commit, from its dir (or the git -C / cd in that text). The gate is
# commit_gates[], the first entry whose "remote" equals the origin URL's owner/repo path (scheme, user@host: and
# .git removed, case ignored). Works from any worktree; uv checks fall back to the primary checkout's .venv.
# Uses only tools already installed; never installs.
# Skips quietly when config, repo or origin are missing. Skips a check, with a note Claude sees (additionalContext;
# also on stderr), when its tool is missing (exit 127, or output saying "command not found" or "Failed to spawn"),
# unless the gate sets "on_missing_tool": "deny"; and when the repo tracks files under .venv (a uv or .venv/
# check) or node_modules (a node_modules/, npx, npm, pnpm, yarn or bun check), whose tools would run unprompted.
# File names are untrusted: each one is shell-quoted (printf %q) before it replaces {files}, and a name that
# starts with - gets a ./ prefix so it cannot pass as an option. So write {files} bare in a check, never in quotes.
# A check with {files} runs once per chunk of about 100 kB of names, so a large change set never hits the
# argument size limit; a check without {files} runs once.
# Checks share one time budget ($WORKBENCH_GATE_TIMEOUT seconds, default 170, under the 180 s hook timeout).
# Output goes to a file in one private mktemp -d dir, not a pipe, so a check that leaves a child running cannot
# hang the hook; the check's whole process group is killed when it ends or runs out of time. Out of time = commit
# allowed (fail open), with a note. Without python3, or for a command cmdparse cannot split, the commit is found
# by regex.
# ponytail: checks every changed file in the tree, not just the staged ones, because `git add && git commit`
# arrive as one command; an unrelated dirty file can block a commit. Slow suites (pytest, build) stay in CI.
command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || exit 0
case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
[ -f "$here/kitconf.sh" ] || exit 0
. "$here/kitconf.sh"

in=$(cat)
req=$(jq -c '{command: (.tool_input.command // "" | tostring), cwd: (.cwd // "" | tostring)}' <<<"$in" 2>/dev/null) ||
  exit 0
case $req in *commit*) ;; *) exit 0 ;; esac
NL=$'\n'

regex_dirs() {  # $1 = text, $2 = its dir. Round-1 reading: a git ... commit anywhere; dir from the first git -C,
  # else the first cd, else $2
  local cmd=$1 dir=$2 d word re_C re_cd
  grep -Eq '(^|[^[:alnum:]_-])git([[:space:]].*)?[[:space:]]commit([[:space:];&|)]|$)' <<<"$cmd" || return 0
  word="\"[^\"]*\"|'[^']*'|[^[:space:];&|]+"
  re_C="git[[:space:]]+-C[[:space:]]+($word)"
  re_cd="(^|[;&|$NL][[:space:]]*)cd[[:space:]]+($word)"
  if [[ $cmd =~ $re_C ]]; then d=${BASH_REMATCH[1]}; elif [[ $cmd =~ $re_cd ]]; then d=${BASH_REMATCH[2]}; else d=""; fi
  case $d in \"*\") d=${d#\"}; d=${d%\"} ;; \'*\') d=${d#\'}; d=${d%\'} ;; esac
  case $d in
    "~"|'$HOME'|'${HOME}') d=$HOME ;;
    "~/"*) d=$HOME/${d#"~/"} ;;
    '$HOME/'*) d=$HOME/${d#'$HOME/'} ;;
    '${HOME}/'*) d=$HOME/${d#'${HOME}/'} ;;
  esac
  if [ -n "$d" ]; then case $d in /*) dir=$d ;; *) dir=$dir/$d ;; esac; fi
  printf '%s\n' "$dir"
}

if segs=$(/usr/bin/env python3 -I "$here/cmdparse.py" <<<"$req" 2>/dev/null) &&
   dirs=$(printf '%s\n' "$segs" | jq -r 'select(.git.sub? == "commit") | .dir' 2>/dev/null); then
  case $segs in
    *'"unparsed": true'*)
      while IFS= read -r u; do
        [ -n "$u" ] && dirs=$dirs$NL$(regex_dirs "$(jq -r .fb <<<"$u")" "$(jq -r .dir <<<"$u")")
      done <<EOF
$(printf '%s\n' "$segs" | jq -c 'select(.unparsed) | {fb: (.fb // .raw), dir}' 2>/dev/null)
EOF
      ;;
  esac
else
  dirs=$(regex_dirs "$(jq -r .command <<<"$req")" "$(jq -r .cwd <<<"$req")")
fi
dirs=$(printf '%s\n' "$dirs" | sed '/^$/d' | sort -u)
[ -n "$dirs" ] || exit 0

remote_path() {  # origin URL -> owner/repo, lower case: scheme://[user@]host[:port]/p, [user@]host:p or a path
  local u=$1
  case $u in
    *://*) u=${u#*://}; case $u in */*) u=${u#*/} ;; *) u="" ;; esac ;;
    *) case ${u%%/*} in *:*) u=${u#*:} ;; esac ;;
  esac
  u=${u%/}; u=${u%.git}; u=${u#/}
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

tmpd=""; pid=""; dog=""; notes=""
cleanup() {
  [ -n "$pid" ] && kill -TERM -- "-$pid" 2>/dev/null
  [ -n "$dog" ] && kill -TERM -- "-$dog" 2>/dev/null
  [ -n "$tmpd" ] && rm -rf "$tmpd"
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP

note() {  # a skipped check: on stderr, and collected for Claude
  echo "workbench commit gate: $1" >&2
  notes=$notes${notes:+$NL}$1
}
finish() {  # allow the commit; Claude sees the notes, if any
  [ -n "$notes" ] && jq -n --arg c "workbench commit gate: $notes" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
  exit 0
}
deny() {  # $1 = reason header. Shows the first 25 non-blank lines of the check's output.
  local o
  o=$(sed '/^[[:space:]]*$/d' "$tmpd/out" | head -25)
  jq -n --arg r "$1
$o" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

limit=${WORKBENCH_GATE_TIMEOUT:-170}
case $limit in ''|*[!0-9]*) limit=170 ;; esac
CHUNK=100000   # bytes of quoted names per run: under Linux's 128 KiB cap on one argument and macOS's 1 MiB ARG_MAX

run() {  # $1 = command, $2 = UV_PROJECT_ENVIRONMENT or empty. Output lands in $tmpd/out; late=1 when out of time.
  local left=$((limit - SECONDS)) rc
  late=1
  [ "$left" -gt 0 ] || return 1
  late=0
  rm -f "$tmpd/late"
  set -m   # each background job gets its own process group, so it can be killed with all its children
  if [ -n "$2" ]; then
    UV_PROJECT_ENVIRONMENT=$2 "${BASH:-bash}" -c "$1" >"$tmpd/out" 2>&1 </dev/null &
  else
    "${BASH:-bash}" -c "$1" >"$tmpd/out" 2>&1 </dev/null &
  fi
  pid=$!
  { sleep "$left"; : >"$tmpd/late"; kill -TERM -- "-$pid"; } >/dev/null 2>&1 </dev/null &
  dog=$!
  set +m
  wait "$pid"; rc=$?
  kill -TERM -- "-$pid" 2>/dev/null   # anything the check left running
  kill -TERM -- "-$dog" 2>/dev/null
  pid=""; dog=""
  [ -e "$tmpd/late" ] && late=1
  return "$rc"
}

select_files() {  # $1 = regex. Fills q with the quoted matching names and cs/cn with chunk starts and counts.
  # In the C locale, so %q escapes every non-ASCII byte and ${#f} counts bytes.
  local LC_ALL=C f len=0 s=0 k=0
  q=(); cs=(); cn=()
  for f in "${files[@]}"; do
    [[ $f =~ $1 ]] || continue   # an invalid regex matches nothing
    case $f in -*) f=./$f ;; esac
    printf -v f '%q' "$f"
    q[${#q[@]}]=$f
    if [ "$k" -gt 0 ] && [ $((len + ${#f} + 1)) -gt "$CHUNK" ]; then
      cs[${#cs[@]}]=$s; cn[${#cn[@]}]=$k; s=$((s + k)); k=0; len=0
    fi
    k=$((k + 1)); len=$((len + ${#f} + 1))
  done
  [ "$k" -gt 0 ] && { cs[${#cs[@]}]=$s; cn[${#cn[@]}]=$k; }
  return 0
}

gate() {  # $1 = the commit's dir. Denies (and exits) on the first failing check.
  local root url main gi g need n i c re name venv out rest f rc onmiss tvenv tnode j sel cc
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  url=$(git -C "$root" remote get-url origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  WB_REMOTE=$(remote_path "$url")
  export WB_REMOTE
  gi=$(kit_get 'first(.commit_gates | to_entries[] | .value.remote as $r
    | select(($r | type) == "string" and $r != ""
      and ($r | ascii_downcase | ltrimstr("/") | rtrimstr("/") | rtrimstr(".git")) == env.WB_REMOTE)) | .key')
  unset WB_REMOTE
  case $gi in ''|*[!0-9]*) return 0 ;; esac
  g=".commit_gates[$gi]"

  need=$(kit_get "$g.require | strings")
  if [ -n "$need" ]; then
    case $need in /*) ;; *) need=$root/$need ;; esac
    [ -e "$need" ] || return 0
  fi
  n=$(kit_get "$g.checks | length")
  case $n in ''|*[!0-9]*) return 0 ;; esac
  onmiss=$(kit_get "$g.on_missing_tool | strings")
  main=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && main=$(dirname "$main")
  cd "$root" || return 0
  tvenv=$(git ls-files -- .venv 2>/dev/null | head -1)
  tnode=$(git ls-files -- node_modules 2>/dev/null | head -1)

  # Changed files: tracked changes against HEAD plus untracked non-ignored, existing files only. NUL-separated,
  # so names with spaces, quotes or newlines survive intact.
  files=()
  while IFS= read -r -d '' f; do
    [ -f "$f" ] && files[${#files[@]}]=$f
  done < <( { git diff --name-only -z HEAD; git ls-files --others --exclude-standard -z; } 2>/dev/null | sort -zu )
  [ ${#files[@]} -gt 0 ] || return 0
  [ -n "$tmpd" ] || tmpd=$(mktemp -d "${TMPDIR:-/tmp}/workbench-gate.XXXXXX") || return 0

  i=0
  while [ "$i" -lt "$n" ]; do
    c=$(kit_get "$g.checks[$i].cmd | strings")
    re=$(kit_get "$g.checks[$i].files | strings")
    name=$(kit_get "$g.checks[$i].name | strings")
    i=$((i + 1))
    name=${name:-check $i}
    [ -n "$c" ] && [ -n "$re" ] || continue   # missing cmd or files = check off

    select_files "$re"
    [ ${#q[@]} -gt 0 ] || continue
    case $c in *"{files}"*) ;; *) cs=(0); cn=(0) ;; esac   # no {files}: one run

    case $c in
      "uv "*|*.venv/*)
        if [ -n "$tvenv" ]; then
          note "$name skipped: the repo tracks files under .venv, so its tools are not run."
          continue
        fi ;;
    esac
    case $c in
      *node_modules/*|npx\ *|npm\ *|pnpm\ *|yarn\ *|bun\ *|bunx\ *)
        if [ -n "$tnode" ]; then
          note "$name skipped: the repo tracks files under node_modules, so its tools are not run."
          continue
        fi ;;
    esac

    venv=""
    case $c in
      "uv "*)
        if [ ! -d "$root/.venv" ]; then
          [ -n "$main" ] && [ -d "$main/.venv" ] || continue   # no environment anywhere: skip, never create one
          venv=$main/.venv
        fi ;;
    esac

    j=0
    while [ "$j" -lt ${#cs[@]} ]; do
      sel=""
      if [ "${cn[$j]}" -gt 0 ]; then
        printf -v sel '%s ' "${q[@]:${cs[$j]}:${cn[$j]}}"
        sel=${sel% }
      fi
      j=$((j + 1))
      # Replace every {files} with the quoted list. Done by hand, not with ${c//pat/rep}: how rep's & and
      # backslashes are treated differs across bash versions (5.2 patsub_replacement), and that could undo %q.
      out=""; rest=$c
      while case $rest in *"{files}"*) true ;; *) false ;; esac; do
        out=$out${rest%%"{files}"*}$sel
        rest=${rest#*"{files}"}
      done
      cc=$out$rest

      run "$cc" "$venv"; rc=$?
      if [ "$late" = 1 ]; then
        note "$name ran out of time (${limit}s budget); commit allowed."
        finish
      fi
      [ "$rc" = 0 ] && continue
      if [ "$rc" = 127 ] || grep -Eq 'command not found|Failed to spawn' "$tmpd/out" 2>/dev/null; then
        [ "$onmiss" = deny ] &&
          deny "Commit gate ($name) could not run: a tool it needs is missing (exit $rc), and this gate sets on_missing_tool to deny. Install the tool, then commit again:"
        note "$name skipped, a tool it runs is missing (exit $rc)."
        break
      fi
      deny "Commit gate ($name) failed, mirroring CI. Fix these, then commit again:"
    done
  done
  return 0
}

while IFS= read -r d; do
  [ -n "$d" ] && gate "$d"
done <<EOF
$dirs
EOF
finish
