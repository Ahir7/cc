---
name: config-audit
description: Read-only monthly audit of the Claude Code setup (settings, hooks, memory size, linked repos and their external imports, plugins, stray browsers, stale worktrees) driven by the workbench config (default ${CLAUDE_CONFIG_DIR:-~/.claude}/workbench.json). Use when the user or the monthly scheduled audit prompt asks for a config audit. Writes one report to the config dir's audits/ folder and changes nothing else.
---
# Monthly Claude Code config audit

This audit is READ-ONLY. Change no setting, hook, skill, plugin, memory file, repo or worktree, and never pass
`--apply` to a workbench script. Never print secrets, tokens or env values from any config file: report key names and
counts only. The one file you may write is the report described at the end.

It exists because a broken settings file once went unnoticed for seven weeks. Catch drift like that early.

## Inputs

- Config root: `$CLAUDE_CONFIG_DIR` if set, else `~/.claude`. Below, `<cfg>` means that root. Global state file:
  `$CLAUDE_CONFIG_DIR/.claude.json` if the variable is set, else `~/.claude.json`.
- Config: `$WORKBENCH_CONFIG` if set, else `<cfg>/workbench.json`. Expand a leading `~/` to `$HOME`. The repos to
  check are the union of `uv_repos`, every `repo_groups[].repos` entry, and every `pytest_env_required.paths` entry
  that is a git repo. The expected memory dirs are `repo_groups[].memory_dir`. If the file is missing or does not
  parse, record FAIL for check 1 and audit the user-level setup only.
- Baseline: the newest earlier report in `<cfg>/audits/` (any `YYYY-MM.md` before this month). Compare counts and
  names against its Baseline section. With no earlier report, this run sets the baseline and nothing counts as new.
- Workbench tools: `${CLAUDE_PLUGIN_ROOT}/tests/test_hooks.sh` and
  `${CLAUDE_PLUGIN_ROOT}/skills/link-repos/link_repos.py`.

## Checks

Record each as PASS, WARN or FAIL with the number behind it.

1. **Settings parse.** Each of these parses as JSON (`jq empty FILE`):
   `<cfg>/settings.json`, the workbench config, `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json`, and each repo's
   `.claude/settings.json` and `.claude/settings.local.json` when present. FAIL on any parse error. Report the
   user-level `permissions` allow/ask/deny counts, the `env` key names, and the hook events registered at user level.
   FAIL unless `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` is wired as install.sh checks it: every key under `hooks`
   is a hook event Claude Code knows (`claude plugin validate "${CLAUDE_PLUGIN_ROOT}"` warns `unknown hook event`
   for any other; any warning it lists that starts with `hooks` is a FAIL too, though it exits 0); the
   `PreToolUse` groups whose matcher matches `Bash` run `guard.sh`, `commit_gate.sh` and `browser_cap.sh` between
   them; the `PreToolUse` groups matching `mcp__playwright__browser_navigate`, `mcp__Claude_Browser__navigate` and
   `mcp__claude-in-chrome__navigate` run `browser_cap.sh`; and the `PostToolUse` groups matching `Edit` and `Write`
   run `format_py.sh`, each as a `command` hook under `${CLAUDE_PLUGIN_ROOT}/scripts/`. Read matchers as the CLI
   does: a matcher that is missing, empty or `*` matches every tool; for `PreToolUse` and `PostToolUse` one made
   only of letters, digits, `_`, `|`, commas, spaces and `-` is a list of exact tool names split on `|` or `,`, each
   name trimmed (`Edit, Write` lists two tools, and `mcp__playwright` alone names no MCP tool); anything else is a
   regular expression that must match somewhere in the tool name. Name each tool and script that is not wired: no
   new session runs that hook. FAIL too when a `PreToolUse` hook that runs `guard.sh`, `commit_gate.sh` or
   `browser_cap.sh` sets `async`, `asyncRewake` or `once` (the CLI does not wait for its decision, or drops the hook
   after one run), or when the `commit_gate.sh` hook's `timeout` is 170 or less (the gate's own budget for its
   checks; no `timeout` means the CLI's 600 s). Then run each `command` string the way Claude Code runs it
   (`bash -c`, with `CLAUDE_PLUGIN_ROOT` set) on a harmless request, with `HOME` pointing at a folder that does not
   exist so no config is read and nothing is written:

   ```bash
   H="${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json"
   jq -r '.hooks.PreToolUse[]?.hooks[]?.command // empty' "$H" | sort -u | while IFS= read -r C; do
     printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status"},"cwd":"/tmp"}' \
       | env -i HOME=/nonexistent PATH="$PATH" CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" bash -c "$C" >/dev/null
     echo "exit $? for $C"
   done
   ```

   and the same for `.hooks.PostToolUse` with the request `{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.txt"}}`.
   FAIL on any exit code other than 0, naming the command and the last line it wrote to stderr: a typo in the
   command itself (`bahs` for `bash`, a lost quote) means the hook never starts, and the CLI then lets the action
   through. The action for any of these: fix `hooks/hooks.json` in the workbench checkout, then run
   `bash install.sh --apply` there (it runs the same checks before it swaps the copy in).
   WARN on any growth in allow rules since the baseline (one-off approvals piling up) and list the new rules.
   WARN if user-level hooks still point at `<cfg>/hooks/guard.sh`, `browser_cap.sh`, `commit_gate.sh` or
   `format_py.sh` while the workbench plugin (`workbench@workbench`) is enabled: each hook then fires twice.
   WARN unless an ask (or deny) rule in `<cfg>/settings.json` covers edits to `<cfg>/workbench-kit/**`, the installed
   copy of the kit the plugin runs from: `Edit(~/.claude/workbench-kit/**)` for the default folder, and with
   `CLAUDE_CONFIG_DIR` set the same path written `~/REL/workbench-kit/**` (a folder under home) or
   `//ABS/workbench-kit/**`. A broader rule such as `Edit(~/.claude/**)` counts. Without one, a session can edit the
   enforcement scripts without a prompt.
2. **claude doctor.** Run `claude doctor </dev/null` from each repo. FAIL if any output lists "Invalid settings".
   Note whether the CLI is signed in.
3. **Hook self-test.** `bash "${CLAUDE_PLUGIN_ROOT}/tests/test_hooks.sh"` must exit 0. It runs in a sandbox HOME and
   temp repos. Report its pass and fail counts and the names of failing cases. If the file does not exist (an
   incomplete copy, or one from before tests/ shipped), record WARN with that reason, not FAIL, and recommend
   running `bash install.sh --apply` from the workbench checkout, which re-syncs the installed copy, tests included.
4. **Memory size.** Check each group's `memory_dir/MEMORY.md` first, then every `<cfg>/projects/*/memory/MEMORY.md`.
   Report bytes and lines for each. FAIL above 25,000 bytes or 200 lines (Claude Code stops loading the index past
   that); WARN above 15,000 bytes. Report index links that point at missing files and topic files missing from the
   index. For each repo in a group, WARN if its default per-project memory folder under `<cfg>/projects/` has topic
   files newer than the baseline report: writes are going to the wrong place. That folder is named after the repo's
   real path with every character other than A-Z, a-z and 0-9 turned into `-`, so `/Users/jane.doe/my_app` becomes
   `-Users-jane-doe-my-app`. A name longer than 200 characters is cut to its first 200 and gets a `-` and hash
   suffix, so when there is no exact match, list every folder that starts with those 200 characters as a candidate.
5. **Linked-repo wiring.** For each `repo_groups` entry, run the link script as a dry run (it writes nothing):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/link-repos/link_repos.py" --from-config NAME --approve-imports
   ```

   Call it by path, never through `python` or `python3` (the guard hook refuses those in uv repos).

   PASS when it ends with `Summary: 0 change(s) planned`. FAIL when the plan changes a `.claude/settings.local.json`
   (the unified session or the shared memory is broken) or the script exits 2 (quote the `refused:` line). WARN for
   anything else it plans: a stale `linked-repos.md` after a sibling gained a CLAUDE.md, missing exclude or
   `.worktreeinclude` lines, or import approvals not yet recorded. List what it planned and every `note:` line.
   An `[unscanned]` line is an instruction file over the 1 MiB scan cap, or one that is not a regular file (a FIFO
   or device, in the repo or as an import target): WARN and list it (exit 3 also covers it).
   Exit 3 means the repos hold external imports (`[external]` lines: an `@` path or rule symlink that leaves its repo
   and is not the sibling bridge), which the one-per-project approval flag would also approve. The audit passes no
   `--allow-external`, so exit 3 is expected whenever any exist. List each `[external]` line (file:line and target;
   never open the target, it may hold secrets). WARN on any target not in the baseline's external imports, and FAIL
   when such a new target carries the "approval is already recorded" WARNING (it loads without asking). With no
   baseline, WARN and list them all once.
6. **Plugins, skills, agents.** `claude plugin list --json` (if that errors, the text form `claude plugin list`),
   `claude plugin marketplace list --json`, the number of user skills (`<cfg>/skills/*/SKILL.md`) and user agents
   (`<cfg>/agents/*.md`). FAIL if the `workbench@workbench` plugin is missing, disabled (`enabled: false`) or failed
   to load (a non-empty `errors` list; in the text form a `Status:` line saying `failed to load` or `disabled`), or
   if the `installLocation` of the `workbench` marketplace does not exist (`test -d`). The action for any of these:
   run `bash install.sh --apply` from the kit's current folder. WARN on any plugin, skill or agent not in the baseline,
   with its name.
7. **MCP servers.** Names and scope only, never a command, argument, URL, header or env value. User scope: the
   top-level `mcpServers` keys of the global state file (`jq -r '.mcpServers // {} | keys[]' FILE`); these load in
   every project. Local scope: `projects[<repo>].mcpServers` in the same file. Project scope: each repo's
   `.mcp.json`. Plugin scope, when the `claude` CLI is on PATH: the `mcpServers` keys of each plugin in
   `claude plugin list --json`. Do not run `claude mcp list`: it connects to every server. WARN on any server not in
   the baseline, with its scope.
8. **Stray processes.** Count `pgrep -f playwright-mcp | wc -l` and
   `pgrep -f 'chrome-headless-shell|--remote-debugging-pipe' | wc -l` (never match on `--headless`: that also counts
   idle MCP servers). WARN if more than 6 MCP processes, or any headless browser while no browser work is running.
   Report the cap in force (`CLAUDE_BROWSER_PROC_MAX`, else `browser_proc_max`, else 25).
9. **CLI version.** `claude --version`. If the desktop app bundles its own copy (on macOS, the newest folder under
   `~/Library/Application Support/Claude/claude-code/`), WARN when the terminal CLI is more than 20 patch releases
   behind it.
10. **Stale worktrees.** For each repo, `git -C REPO worktree list --porcelain`. List worktrees whose HEAD commit is
    older than 30 days (`git -C WORKTREE log -1 --format=%cs`) and any marked prunable. List only; never remove,
    prune or switch anything.
11. **Interactive checks.** `/doctor` and `/usage` only run inside a session. Remind the user to run them.

## Report

Write `<cfg>/audits/<YYYY-MM>.md` for the current month (create the folder if needed; replace this month's file if
the audit already ran). Plain text, no em dashes:

- A 3-line summary at the top: overall status (the worst status of any check), the worst finding, the one action to
  take.
- A table with one row per check: check, status, number, detail.
- "Compared with last month", when a baseline report exists: what changed in the counts and names.
- "Recommended actions": at most three, most important first. Apply none of them.
- "Baseline" for next month: the allow/ask/deny counts and the allow rules (replace any token-like string of 20 or
  more letters and digits with `<redacted>`), env key names, hook events, plugin, skill and agent names, MCP server
  names with their scope (user, local, project or plugin), the memory index sizes, and the external import targets
  from check 5 (paths only).

Finish by giving the same 3-line summary as your final message.
