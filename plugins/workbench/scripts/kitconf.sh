#!/bin/bash
# workbench shared config reader. Source it from a hook; it defines these functions and never errors.
#   WB_CONFIG            ${WORKBENCH_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/workbench.json}
#   kit_get FILTER       prints the jq result raw (strings unquoted), or nothing when the file, key or jq is missing
#   kit_paths FILTER     prints each string result as an absolute path, one per line: ~ and $HOME expanded,
#                        one trailing / dropped, relative entries skipped
#   kit_under DIR ROOTS  true when DIR, its physical path, or the primary checkout of the linked worktree it is in
#                        is one of the newline-separated ROOTS or inside one (each root also tried with symlinks
#                        resolved)
# Example: kit_under "$dir" "$(kit_paths '.uv_repos[]?')"
WB_CONFIG=${WORKBENCH_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/workbench.json}

kit_get() {
  [ -r "$WB_CONFIG" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r "($1)"' // empty' "$WB_CONFIG" 2>/dev/null
  return 0
}

kit_paths() {
  [ -r "$WB_CONFIG" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg h "$HOME" "($1)"' // empty | strings
    | if . == "~" or . == "$HOME" or . == "${HOME}" then $h
      elif startswith("~/") then $h + .[1:]
      elif startswith("$HOME/") then $h + .[5:]
      elif startswith("${HOME}/") then $h + .[7:]
      else . end
    | rtrimstr("/") | select(startswith("/"))' "$WB_CONFIG" 2>/dev/null
  return 0
}

kit_inside() {  # $1 = absolute dir, $2 = newline-separated roots
  local p pp
  [ -n "$1" ] || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$1/" in "$p"/*) return 0 ;; esac
    pp=$(cd "$p" 2>/dev/null && pwd -P)
    [ -n "$pp" ] && case "$1/" in "$pp"/*) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

kit_under() {  # $1 = dir, $2 = newline-separated roots
  local real main
  [ -n "$1" ] && [ -n "$2" ] || return 1
  kit_inside "$1" "$2" && return 0
  real=$(cd "$1" 2>/dev/null && pwd -P) && kit_inside "$real" "$2" && return 0
  main=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  kit_inside "$(dirname "$main")" "$2"
}
