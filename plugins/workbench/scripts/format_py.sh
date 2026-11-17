#!/bin/bash
# workbench PostToolUse on Edit|Write: format an edited .py file with the repo's own ruff. Never blocks.
# Acts only in a repo under uv_repos in workbench.json (or a worktree of one), whose pyproject mentions ruff and that
# already has a .venv. Skips a repo that commits .venv: uv run puts .venv/bin first on PATH, so a committed
# .venv/bin/ruff would run without a prompt.
command -v jq >/dev/null 2>&1 || exit 0
case $0 in */*) here=${0%/*} ;; *) here=. ;; esac
[ -f "$here/kitconf.sh" ] || exit 0
. "$here/kitconf.sh"
f=$(jq -r '.tool_input.file_path // ""' 2>/dev/null)
case "$f" in *.py) ;; *) exit 0 ;; esac
[ -f "$f" ] || exit 0
root=$(cd "$(dirname "$f")" && git rev-parse --show-toplevel 2>/dev/null) || exit 0
kit_under "$root" "$(kit_paths '.uv_repos[]?')" || exit 0
grep -q 'ruff' "$root/pyproject.toml" 2>/dev/null || exit 0
# Only where an environment already exists: uv run would otherwise create one (and --no-sync stops it installing).
[ -d "$root/.venv" ] || exit 0
[ -z "$(git -C "$root" ls-files -- .venv 2>/dev/null | head -1)" ] || exit 0
cd "$root" && uv run --no-sync --quiet ruff format -q "$f" >/dev/null 2>&1 && uv run --no-sync --quiet ruff check --fix -q "$f" >/dev/null 2>&1
exit 0
