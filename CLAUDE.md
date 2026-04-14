# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo ships

A single bash installer at `bin/install` that users `curl | bash` to configure external git worktrees for Claude Code. After running it once per project, `claude --worktree <name>` creates worktrees at `~/.worktrees/<repo>/<name>` instead of inside the repo. Everything else in this repo exists to produce that one file.

## Build

```bash
./build.sh          # produces bin/install from src/
bash bin/install    # try it in a scratch git repo
```

`build.sh` is a `sed`-based concatenator — no toolchain, no Node, no Bun. It inlines three source files into `src/init.sh` at three markers:

- `__GRAFT_DETECTORS__` ← `src/lib/detectors.sh`
- `__GRAFT_HOOK_TEMPLATE__` ← `src/templates/graft-hook.sh`
- `__GRAFT_SCAFFOLD_TEMPLATE__` ← `src/templates/scaffold.sh`

**`bin/install` is committed alongside its source** and must be rebuilt + committed whenever anything under `src/` changes. GitHub Pages serves it directly from the default branch at `https://gustavohariel.github.io/graft/bin/install`; there is no build server, no release workflow, and no CI that rebuilds on your behalf. If you edit `src/` and forget `./build.sh`, the hosted installer drifts from source.

## Two-phase execution model

This is the essential mental model before changing anything.

**Install time** (`src/init.sh`, runs once per project). An interactive bash wizard that reads the user's repo to pre-fill defaults from `src/lib/detectors.sh`, asks 3 questions, and writes four artifacts to the user's `.claude/`:
- `graft.config` (shell-sourced, read by the hook at runtime)
- `graft-hook.sh` (the runtime hook, inlined from `src/templates/graft-hook.sh`)
- `graft-scaffold.sh` (user-owned bootstrap; graft seeds it once and never touches it again without `--force`)
- A structured merge into `settings.json` adding `hooks.WorktreeCreate`

It also detects existing non-graft `WorktreeCreate` hooks (offering replace/keep) and broad `.claude/` gitignore patterns (offering to append un-ignore rules).

**Runtime** (`src/templates/graft-hook.sh`, runs on every `claude --worktree <name>`). Claude Code fires the `WorktreeCreate` hook event, which invokes the committed `graft-hook.sh`. The hook sources `graft.config`, parses Claude Code's JSON stdin payload with `sed`, runs `git worktree add` at the external location, copies files, symlinks dirs, runs the scaffold script, and echoes the final worktree path on stdout (Claude Code's WorktreeCreate hook contract).

## Runtime zero-dep constraint

**The runtime hook MUST NOT require jq, python, node, or any runtime other than `bash + git + sed`.** This is load-bearing: teammates who `git pull` a repo with graft installed must be able to run `claude --worktree` without installing anything. Breaking this invalidates the whole premise.

The install-time wizard MAY reach for `jq` (with `python3` as fallback) for structured `settings.json` merging — but only when an existing settings.json needs merging. Fresh repos install without either.

When editing `src/templates/graft-hook.sh`, if you find yourself wanting jq or python, stop and find another way. The current code parses Claude's payload with `sed`, reads config with `source`, and handles arrays with plain bash — keep it that way. Verify by running the hook under `env -i PATH="/usr/bin:/bin" bash .claude/graft-hook.sh`.

## Adding support for a new ecosystem

One file: `src/lib/detectors.sh`. Three arrays:
- `GRAFT_DETECT_COPY_FILES` — gitignored files worktrees commonly need.
- `GRAFT_DETECT_SYMLINK_DIRS` — dirs too heavy to duplicate. **Only include unambiguous names.** `build/` was removed because it overlaps with Gradle, Next, and committed assets; `.venv`/`venv` were removed because sharing a virtualenv breaks per-worktree dependency isolation.
- `GRAFT_DETECT_INSTALL` — ordered `"lockfile|command"` pairs; first match wins.

After editing, `./build.sh` and commit both `src/lib/detectors.sh` and `bin/install`.

## Testing

No automated test suite. Smoke-test by running `bash bin/install` in a throwaway git repo and verifying the four artifacts are written correctly. For the interactive wizard specifically, drive the prompts with `expect` (the installer reads from `/dev/tty`, not stdin).

Hook-only testing pattern (no wizard, no Claude Code):
```bash
echo '{"worktree_path":"/path/.claude/worktrees/test","branch":"worktree-test","detach":false}' \
  | ./.claude/graft-hook.sh
```

To prove runtime zero-dep, wrap with `env -i HOME="$HOME" PATH="/usr/bin:/bin"`.

## Things to know

- `bin/install` auto-re-execs itself when stdin isn't a tty (handles `curl | bash` by switching to `bash <(curl …)` form so interactive prompts still work).
- The wizard writes its own `.gitignore` un-ignore block using the `!.claude/` + `.claude/*` + `!<specific file>` pattern so graft's files become trackable without un-ignoring the whole `.claude/` directory.
- `.nojekyll` at the repo root is required — without it GitHub Pages would try to run files through Jekyll.
- Platform support is macOS + Linux + WSL. Native Windows (Git Bash) is deliberately unsupported because `ln -s` silently degrades to a copy without Developer Mode.
