#!/bin/bash
# workbench PreToolUse cap on headless browser launches. Register with matcher
# "Bash|mcp__playwright.*|mcp__Claude_Browser__.*|mcp__claude-in-chrome__.*".
# Bash is covered because the worst blowup came from Playwright e2e runs started through Bash.
# Cap: $CLAUDE_BROWSER_PROC_MAX, else workbench.json browser_proc_max, else 25. Denies when the count is above it.
# An MCP browser tool counts by its name. A Bash call counts only when one of its segments (cmdparse.py, after
# wrappers and uv run) launches a browser: playwright itself, npx/bunx/pnpx with any word naming playwright,
# npm/pnpm/yarn/bun with exec|dlx|x and later a playwright package, or run|run-script and later a word holding
# e2e or playwright (so option values such as --prefix X or -w web never hide the script), pnpm/yarn/bun with any
# word holding e2e or playwright unless one is a package verb (add, install, ...), or a script whose file name
# holds e2e, playwright or predeploy_gate, run by path or by a shell. node, nodejs, deno, tsx, ts-node, bun,
# python and python3(.N) count, also behind uv run (uv run X.py runs python X.py), uv tool run, uvx,
# npx/bunx/pnpx [options], npm|pnpm|yarn|bun exec|dlx|x [--] (a version on the runner word, tsx@4, is dropped) or
# pnpm|yarn RUNNER: when a non-option word holds playwright, e2e or predeploy_gate (bun: under the bun rule
# above); when -e, -p, --eval or -c code names playwright or a browser .launch(; when their own heredoc or an
# earlier segment's heredoc or here-string in the same command does; when an earlier segment wrote or edited their
# script (> or >>, tee, sed -i, perl -i) with such text, also text piped into it (echo CODE | tee F); when they
# read a pipe with no script and what is piped names it; and behind uv run or uvx when a --with or --from value
# names playwright. A shell running a script after such a heredoc counts; a program run by path counts when its
# own heredoc does, or when such a heredoc was written to a file it names (cat > x.sh <<EOF ... EOF; ./run.sh x.sh;
# also cat <<EOF | tee x.sh). A script written from a heredoc and run in the same command (bash x.sh, ./x.sh) is
# also read as its own segments (cmdparse.py). A browser .launch( is one right after chromium, firefox, webkit,
# puppeteer or browser (chromium.launch(, require('puppeteer').launch(), or any .launch( in text that names
# puppeteer (puppeteer-core included: pp.launch()); Gradio's demo.launch() is not one. The heredocs of git
# commit, gh and glab segments (also in their $(...))
# never count, nor do grep, git log, pgrep and words in messages. A segment cmdparse cannot see into (a shell
# reading stdin) counts when its text names one of those words; without python3 the whole command is read that way.
# The command is parsed only when it names a word (or .launch() and the count is already above the cap.
# ponytail: counts headless browser processes, not agents; tune the cap after a week of normal use.
command -v jq >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1 || exit 0
case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
[ -f "$here/kitconf.sh" ] && . "$here/kitconf.sh"
type kit_get >/dev/null 2>&1 || kit_get() { :; }

KW='playwright|predeploy_gate|e2e'
KWL="$KW|\\.launch\\("   # the prefilter also looks for .launch(
in=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$in" 2>/dev/null) || exit 0
if [ "$tool" = "Bash" ]; then
  jq -r '.tool_input.command // ""' <<<"$in" 2>/dev/null | tr -d "\\\\\"'" | grep -Eq "$KWL" || exit 0
fi

int='^-?[0-9]+$'
MAX=${CLAUDE_BROWSER_PROC_MAX:-}
[[ $MAX =~ $int ]] || MAX=$(kit_get .browser_proc_max)
[[ $MAX =~ $int ]] || MAX=25

# Count real browsers only: Playwright launches Chrome with --remote-debugging-pipe; its bundled headless
# build is chrome-headless-shell. Never match --headless: idle MCP server processes carry it too.
n=$(pgrep -f 'chrome-headless-shell|--remote-debugging-pipe' 2>/dev/null | wc -l | tr -d ' ')
[ "${n:-0}" -gt "$MAX" ] || exit 0

LAUNCH='
def base: sub(".*/"; "");
def pw: test("^(@playwright/test|playwright)(@|$)");
def named: base | test($kw);
def after($a; verbs; f): any(range(1; $a | length); . as $i | ($a[$i] | verbs) and any($a[$i + 1:][]; f));
def code: test("playwright|(chromium|firefox|webkit|puppeteer|browser)[A-Za-z0-9_$\"\\x27\\])]*\\.launch\\(")
  or (test("puppeteer") and test("\\.launch\\("));
def runner: IN("node", "nodejs", "deno", "tsx", "ts-node", "bun") or test("^python(3(\\.[0-9]+)?)?$");
def shell: IN("sh", "bash", "zsh", "dash", "ksh");
def codeopt: IN("-e", "-p", "--eval", "--print", "-c");
def valopt: IN("--prefix", "-p", "--package", "-w", "--workspace", "-C", "--dir", "--filter", "-F", "--cwd", "--cache",
               "--userconfig", "--registry");
def runval: IN("-r", "--require", "--import", "--loader", "--experimental-loader", "--conditions", "-W", "-X", "-m");
def commitlike: .inmsg or (.git.sub? // "") == "commit" or ((.argv[0]? // "") | base | IN("gh", "glab"));
def runner_hit($a; $p; $near):
  ($p != "bun" and any(range(1; $a | length); . as $i
      | ($a[$i] | startswith("-") | not) and ($a[$i - 1] | codeopt | not) and ($a[$i] | test($kw))))
  or any(range(1; $a | length); . as $i | ($a[$i] | codeopt) and (($a[$i + 1] // "") | code))
  or any($a[1:][]; (startswith("--eval=") or startswith("--print=")) and code)
  or $near;
def script($a): first(range(1; $a | length) | select(($a[.] | startswith("-") | not)
  and ($a[. - 1] | codeopt or runval | not)) | $a[.]) // "";
def runs($a; $p; $c): runner_hit($a; $p; $c.near)
  or (($c.paths[script($a)] // null) as $f | $f != null and any($c.ew[]; . == $f))
  or ($c.pipe and ([$a[1:][] | select((startswith("-") | not) or codeopt or startswith("--eval=")
                                       or startswith("--print="))] | length) == 0);
def via: . as $a | (($a[0] // "") | base) as $p
  | [range(1; $a | length) | select(($a[.] | startswith("-") | not) and ($a[. - 1] | valopt | not))] as $o
  | (if ($p | IN("npx", "bunx", "pnpx")) then [$o[0], true]
     elif ($p | IN("npm", "pnpm", "yarn", "bun")) and ($a[$o[0] // 0] | IN("exec", "dlx", "x")) then [$o[1], true]
     elif ($p | IN("pnpm", "yarn")) then [$o[0], false] else [null, false] end) as [$k, $pkg]
  | (if $k == null then "" elif $pkg then $a[$k] | sub("(?<=.)@.*$"; "") else $a[$k] end) as $w  # tsx@4 is tsx
  | if $w | base | runner then [$w] + $a[$k + 1:] else [] end;
def launches($c): . as $a | (($a[0] // "") | base) as $p | [$a[1:][] | select(startswith("-") | not)] as $o
  | ($a | via) as $v
  | $p == "playwright"
    or (($p | runner) and runs($a; $p; $c))
    or (($v | length) > 0 and runs($v; $v[0] | base; $c))
    or (($p | IN("npx", "bunx", "pnpx")) and any($o[]; test("playwright")))
    or (($p | IN("npm", "pnpm", "yarn", "bun"))
        and (after($a; IN("run", "run-script"); test("e2e|playwright"))
             or after($a; IN("exec", "dlx", "x"); pw)
             or ($p != "npm" and any($o[]; test("e2e|playwright"))
                 and (any($o[]; IN("add", "install", "i", "remove", "rm", "uninstall", "update", "upgrade", "up",
                                   "why", "info", "view", "list", "ls", "outdated", "init", "create")) | not))))
    or (($p | shell) and (($o[0] // "") | named))
    or ((($a[0] // "") | contains("/"))
        and (($p | named) or $c.own or any(([$a[0]] + $o)[]; ($c.paths[.] // null) as $f
                                                              | $f != null and any($c.hw[]; . == $f))))
    or ($c.near and ($p | shell) and ($o | length) > 0 and ([$a[1:][] | select(test("^-[^-]*c"))] | length) == 0);
def uvprog: (.uv_run // []) | if ((.[0] // "") | endswith(".py")) then ["python"] + . else . end;  # uv run X.py
def uvwith: (.uv_run // []) as $u | (.argv // []) as $a | $a[0:($a | length) - ($u | length)] as $w
  | ($u | length) > 0 and (uvprog[0] | base | runner)
    and any(range(0; $w | length); . as $i
      | (($w[$i] | IN("--with", "-w", "--from")) and (($w[$i + 1] // "") | test("playwright")))
        or ($w[$i] | test("^--(with|from)=.*playwright")));
. as $r
| [$r[] | if commitlike then {h: false, e: false}
          else {h: ((.bodies // "") | code), e: (((.raw // "") + "\n" + (.bodies // "")) | code)} end] as $hit
| ([range(0; $r | length) | select($hit[.].h)] | first) as $first
| [foreach range(0; $r | length) as $j ({e: [], h: []};
    ($r[$j].writes // []) as $w | (($r[$j].argv[0]? // "") | base | IN("cp", "mv")) as $cp
    | [($r[$j].paths // {})[]] as $src | [($r[$j].up // [])[] | $hit[.]] as $fed  # the records piped into it
    | .e += (if $hit[$j].e or any($fed[]; .e) or ($cp and any(.e[]; IN($src[]))) then $w else [] end)
    | .h += (if $hit[$j].h or any($fed[]; .h) or ($cp and any(.h[]; IN($src[]))) then $w else [] end))] as $hot
| any(range(0; $r | length); . as $i | $r[$i]
  | if .unparsed then ((.fb // .raw) | explode | map(select(IN(34, 39, 92) | not)) | implode | test($kw) or code)
    else {own: $hit[$i].h, near: (($first != null and $first < $i) or $hit[$i].h), paths: (.paths // {}),
          ew: (if $i > 0 then $hot[$i - 1].e else [] end), hw: (if $i > 0 then $hot[$i - 1].h else [] end),
          pipe: any((.up // [])[]; $hit[.].e)} as $c
      | ((.argv // []) | launches($c)) or (uvprog | launches($c)) or uvwith end)'

if [ "$tool" = "Bash" ]; then
  req=$(jq -c '{command: (.tool_input.command // "" | tostring), cwd: (.cwd // "" | tostring), bodies: true}' \
    <<<"$in" 2>/dev/null)
  if segs=$(/usr/bin/env python3 -I "$here/cmdparse.py" <<<"$req" 2>/dev/null); then
    hit=$(printf '%s\n' "$segs" | jq -rs --arg kw "$KW" "$LAUNCH" 2>/dev/null) || hit=true
    [ "$hit" = true ] || exit 0
  fi
fi
jq -n --arg r "$n headless browser processes already running (cap $MAX). Browser work runs one agent at a time: wait, or pkill -f chrome-headless-shell after checking nothing else needs it." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
