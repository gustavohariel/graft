# graft

> External worktrees for Claude Code. Zero-install. Pure shell.

Claude Code's `--worktree` flag creates worktrees inside `<repo>/.claude/worktrees/`. For anything with an aggressive file watcher (Metro, Watchman, webpack, IDE indexers), that causes cache collisions and wedged bundlers even when you symlink shared native dirs back.

`graft` registers a `WorktreeCreate` hook that places worktrees at an **external location** (default `~/.worktrees/<repo>/<name>`), copies your gitignored config files, symlinks shared dirs back, and runs a user-owned bootstrap script. After a one-time install, vanilla `claude --worktree my-feature` just works.

## Install

```bash
bash <(curl -fsSL https://gustavohariel.github.io/graft/bin/install)
```

No npm, no bun, no node, no python. One bash script, ~30 seconds. The runtime hook has **zero dependencies**; the installer only needs `jq` or `python3` if your `.claude/settings.json` already has prior content to merge.

### Platform support

| Platform                  | Supported | Notes                                                                                                            |
| ------------------------- | :-------: | ---------------------------------------------------------------------------------------------------------------- |
| macOS / Linux             |     ✅     | First-class.                                                                                                     |
| Windows + WSL 2           |     ✅     | Run `claude` and `graft` from inside WSL.                                                                        |
| Windows native (Git Bash) |     ❌     | `ln -s` silently degrades to a copy unless Developer Mode is on. Use WSL instead.                                |

## Usage

```bash
claude --worktree my-feature
```

Creates the worktree at `~/.worktrees/<repo>/my-feature`, copies your `.env` / secrets, symlinks your shared dirs, and runs the install step the wizard detected (`bun install`, `cargo fetch`, …).

**Isolate a shared dir for one worktree** — when you need a real copy instead of a symlink (e.g. for a destructive `gradle clean` or native-module upgrade):

```bash
GRAFT_COPY_DIRS=android claude --worktree test-upgrade
GRAFT_COPY_DIRS=android,ios claude --worktree full-rebuild
```

## What it writes

Five files, all committed so teammates inherit the setup without installing graft:

| File                                | Purpose                                                                                            |
| ----------------------------------- | -------------------------------------------------------------------------------------------------- |
| `.claude/graft.config`              | Shell-sourced: worktree root, dirs to symlink, files to copy, scaffold path.                       |
| `.claude/graft-hook.sh`             | The `WorktreeCreate` hook. ~110 lines of pure bash. Not regenerated unless you pass `--force`.     |
| `.claude/graft-scaffold.sh`         | Your bootstrap script. Seeded once, then yours forever.                                            |
| `.claude/settings.json`             | One entry merged into `hooks.WorktreeCreate`. Existing content preserved.                          |
| `.claude/skills/graft/SKILL.md`     | A Claude Code skill that teaches any agent working in the repo what graft is and how to use it.    |

Example `graft.config`:

```bash
GRAFT_WORKTREE_ROOT="~/.worktrees/my-app"
GRAFT_SYMLINK_DIRS=('ios' 'android')
GRAFT_COPY_FILES=('.env' 'google-services.json')
GRAFT_SCAFFOLD=".claude/graft-scaffold.sh"
```

Edit any file by hand — graft re-reads them on every hook invocation.

## Environment variables

| Variable              | Effect                                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------------------------- |
| `GRAFT_COPY_DIRS`     | Comma list of dirs to copy instead of symlink for this invocation only. Must already be in `GRAFT_SYMLINK_DIRS`. |
| `GRAFT_INSTALLER_URL` | Override the installer URL used for auto-reexec under `curl \| bash`. For mirrors / forks.                 |

## Installer flags

```bash
bash <(curl -fsSL https://gustavohariel.github.io/graft/bin/install) [--force] [--version] [--help]
```

`--force` overwrites existing `graft-hook.sh` and `graft-scaffold.sh`. Without it, re-runs preserve your edits.

The wizard also:

- Detects and asks before clobbering an existing non-graft `WorktreeCreate` hook.
- Detects and offers to fix broad `.claude/` gitignore patterns that would swallow graft's files.
- Optionally installs a `cwt` zsh/bash helper — an fzf worktree switcher. Opt-in, skipped if fzf isn't installed or the shell is unsupported.

## Extending ecosystem detection

graft's auto-detect lists live in [`src/lib/detectors.sh`](src/lib/detectors.sh) — one file, three arrays: `GRAFT_DETECT_COPY_FILES`, `GRAFT_DETECT_SYMLINK_DIRS`, `GRAFT_DETECT_INSTALL` (`"lockfile|command"` pairs). Adding Deno, Zig, or whatever is a one-line PR.

## Development

```bash
git clone https://github.com/gustavohariel/graft
cd graft
./build.sh           # inlines src/ → bin/install
bash ./bin/install   # try it in a scratch git repo
```

Layout:

```
graft/
├── src/                      # sources you edit
│   ├── init.sh               # wizard
│   ├── lib/detectors.sh      # ecosystem detection lists
│   └── templates/
│       ├── graft-hook.sh     # runtime hook (inlined at build time)
│       └── scaffold.sh       # user-owned scaffold template
├── build.sh                  # concatenates src/ → bin/install via sed
├── bin/install               # built artifact, committed, served by Pages
└── README.md
```

`build.sh` concatenates `src/init.sh` + `src/lib/detectors.sh` + `src/templates/*` via `sed … r` into a single `bin/install` file. The built file is committed so GitHub Pages can serve it directly — no build server, no release workflow.

## License

MIT
