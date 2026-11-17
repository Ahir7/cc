---
name: link-repos
description: Link two or more git repos (for example a backend and its frontend) into one unified Claude Code session with shared auto memory. Shows a dry-run plan first and writes only after the user approves.
disable-model-invocation: true
---
# Link repos into one session

Arguments: $ARGUMENTS

Either a group name from `repo_groups` in the workbench config (`$WORKBENCH_CONFIG`, else
`${CLAUDE_CONFIG_DIR:-~/.claude}/workbench.json`), or
`--group NAME [--memory-dir DIR] REPO REPO ...`.

## The one fact that matters

Listing a repo under `permissions.additionalDirectories` in settings gives file access only. Claude Code loads no
CLAUDE.md, rules or skills from a settings-listed directory (only `--add-dir` / `/add-dir` directories get some of
that). So the siblings' instructions arrive through a bridge rule: a git-excluded `.claude/rules/linked-repos.md` in
each repo that `@`-imports each sibling's `CLAUDE.md` and `CLAUDE.local.md`. Those files live outside the repo, so they
are external imports, and Claude Code loads them only after a one-time approval per project. The app does not always
show that dialog, which is why the script can record the approval itself (`--approve-imports`, which sets
`hasClaudeMdExternalIncludesApproved` and `hasClaudeMdExternalIncludesWarningShown` for each repo in the global state file: `$CLAUDE_CONFIG_DIR/.claude.json`
when that variable is set, else `~/.claude.json`).

That approval is one flag per project, so it also approves every other external import in the repo: an `@~/...`,
`@/...` or `@../...` path in its CLAUDE.md, `.claude/CLAUDE.md`, CLAUDE.local.md, AGENTS.md or `.claude/rules/**/*.md`
(plus committed copies in subfolders and the in-repo files those import), or a rule symlink that leaves the repo. A
teammate's commit is enough to add one. The script therefore lists each of those as an `[external]` line in every
plan, and `--approve-imports` refuses with exit 3 until `--allow-external PATH` names each target. It never opens
files outside the repo, so it cannot see what an allowed target imports in turn. A file over the 1 MiB scan cap, or
one that is not a regular file (a FIFO or device, in the repo or as an import target), is not read either: it is
listed as `[unscanned]` and `--approve-imports` refuses with exit 3 until it is fixed. Bytes that are not UTF-8 do
not stop the script: it reads past them and keeps them unchanged in any file it rewrites.

## What the script changes, per repo

- `.claude/settings.local.json`: merges `autoMemoryDirectory` (when a memory dir is given) and adds every sibling to
  `permissions.additionalDirectories`. Existing keys are kept.
- `.claude/rules/linked-repos.md`: rewritten each run. One absolute `@` import line per sibling file that exists.
  It never imports a sibling's own `linked-repos.md`, so there are no cycles.
- `.git/info/exclude`: the local-only files above, unless git already ignores them.
- `.worktreeinclude`: `CLAUDE.local.md` and the rule file, so new worktrees get them. Never `.env`.
- The memory dir gets a `MEMORY.md` index if it has none.

Files git tracks are left alone (the script says so). Nothing outside the repos is touched except the memory dir and,
with `--approve-imports`, the global state file above (atomic write, mode kept).

## Steps

1. Work out the group. If the arguments are one word and the workbench config (`$WORKBENCH_CONFIG`, else
   `${CLAUDE_CONFIG_DIR:-~/.claude}/workbench.json`) has a `repo_groups` entry with that name, use `--from-config NAME`. Otherwise build
   `--group NAME --memory-dir DIR REPO REPO ...`. If anything is missing, ask for it: the group name, the repos
   (primary checkouts, not worktrees), and the shared memory dir (suggest `~/.claude/<group>-memory`; for repos that
   already have memories, offer to point at the existing dir instead).

2. Run the dry run. It writes nothing:

   ```bash
   "${CLAUDE_SKILL_DIR}/link_repos.py" --group NAME --memory-dir DIR REPO REPO
   ```

   Call the script by path: it is executable and its shebang runs the system python3 in isolated mode. Do not
   prefix it with `python` or `python3` (a repo guard hook refuses those in uv-managed repos); it is stdlib-only
   workbench tooling, not repo code.

3. Show the user the plan as printed: every file, every added line, every `[external]` and `[unscanned]` line, and every `note:` and
   `WARNING` (a WARNING on `autoMemoryDirectory` means the repo already uses a different memory dir, and switching
   hides those memories; a WARNING on an `[external]` line means the approval is already recorded, so that file loads
   today without asking). Then explain the one fact above in two sentences and ask two questions: apply this plan?
   and record the import approval in the global state file now (`--approve-imports`), or approve the dialog at the next
   session start? If there are `[external]` lines, ask about each target separately and suggest the user reads it
   first. Never open a target outside the repos yourself: it may hold secrets (for example `~/.aws/credentials`).

4. Only after the user says yes, run the same command with `--apply`, plus `--approve-imports` if they agreed to that,
   plus one `--allow-external PATH` per `[external]` target they approved (the path after `->`). If they declined a
   target, run without `--approve-imports` and let the in-app dialog decide. Then rerun the dry run with the same
   flags (minus `--apply`) and confirm it ends with `Summary: 0 change(s) planned`.

5. Tell the user to start a new session in any repo of the group (instructions and memory load at session start), and
   to check with `/memory` or `/context` that the siblings' files and the shared `MEMORY.md` loaded.

6. Suggest adding the group to `repo_groups` in the workbench config if it is not there, so `--from-config` and
   the monthly config audit know about it.

## When it refuses (exit 2 or 3)

Show the `refused:` message and stop; nothing was written. Do not work around it.

- Exit 2, the usual causes: a path that is a linked worktree or a subdirectory (link the primary checkout), fewer than
  two distinct repos, a symlink that would lead a write outside the repo, or a settings, config or global state file
  that does not parse, is not a regular file, is over 16 MiB or cannot be read (the user fixes it first; the script
  never clobbers it).
- Exit 3: `--approve-imports` was asked for while an `[external]` target is not named by `--allow-external`, or while
  an `[unscanned]` file exists. Go back to step 3 for those targets. Only the user decides to allow one; never add
  `--allow-external` on your own. An `[unscanned]` file cannot be allowed: the user shrinks it, or replaces a FIFO
  or device with a regular file, first.

## Notes

- A `note:` about a hand-built bridge means an existing CLAUDE.md or CLAUDE.local.md already imports a sibling. The
  generated rule covers it, so that file would load twice. Offer to remove the old import; do not edit it unasked.
- Rerun the skill when a sibling gains a CLAUDE.md or CLAUDE.local.md, or when a repo joins the group. Never hand-edit
  `linked-repos.md`.
- There is no unlink command. To undo, delete each repo's `.claude/rules/linked-repos.md` and remove the added keys
  from its `.claude/settings.local.json`; all of it is local and git-excluded.
