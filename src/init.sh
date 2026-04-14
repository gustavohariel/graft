#!/usr/bin/env bash
# graft installer — https://github.com/gustavohariel/graft
#
# Configures any git repo so `claude --worktree <name>` creates a worktree
# at an external location instead of inside .claude/worktrees/, with
# gitignored files copied, shared dirs symlinked, and a user-owned scaffold
# script run on creation.

set -euo pipefail

GRAFT_VERSION="0.1.0"
INSTALLER_URL="${GRAFT_INSTALLER_URL:-https://gustavohariel.github.io/graft/bin/install}"

# ─── detectors (inlined from src/lib/detectors.sh by build.sh) ───────────────
__GRAFT_DETECTORS__
# ─── end detectors ───────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
  C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_RESET=
fi

say()  { printf '%s\n' "$*"; }
warn() { printf '%s%s%s\n' "${C_YELLOW}" "$*" "${C_RESET}" >&2; }
die()  { printf '%s%s%s\n' "${C_RED}" "$*" "${C_RESET}" >&2; exit 1; }
ok()   { printf '  %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }

# Parse args first so non-interactive flags (--help, --version) exit before
# we even think about reaching for /dev/tty.
FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --force|-f) FORCE=1 ;;
    --version|-V) echo "graft ${GRAFT_VERSION}"; exit 0 ;;
    --help|-h)
      cat <<'EOF'
graft — external worktrees for Claude Code

Usage:
  curl -fsSL https://gustavohariel.github.io/graft/bin/install | bash
  curl -fsSL https://gustavohariel.github.io/graft/bin/install | bash -s -- --force

Options:
  --force, -f    Overwrite existing graft-hook.sh and graft-scaffold.sh
  --version, -V  Print version
  --help, -h     Show this message
EOF
      exit 0 ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

# When we were piped to (curl | bash), our stdin is the script itself, so
# any `read` would consume the script instead of prompting the user. Re-exec
# via process substitution so the script lives on a file descriptor and
# stdin is free for interactive input. Skip this dance if we already re-exec'd
# once (tracked via GRAFT_REEXEC) to avoid a loop.
if [[ ! -t 0 ]] && [[ -z "${GRAFT_REEXEC:-}" ]]; then
  if ! { : </dev/tty; } 2>/dev/null; then
    die "graft: no controlling terminal — installation needs an interactive tty. Run from a real terminal."
  fi
  if ! command -v curl >/dev/null 2>&1; then
    die "graft: curl not found — please install curl first, or download bin/install manually."
  fi
  export GRAFT_REEXEC=1
  exec </dev/tty bash <(curl -fsSL "${INSTALLER_URL}") "$@"
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "${REPO_ROOT}" ]] && die "graft must be run inside a git repository"
REPO_NAME="$(basename "${REPO_ROOT}")"
cd "${REPO_ROOT}"

cat <<EOF

${C_BOLD}graft${C_RESET} ${C_DIM}v${GRAFT_VERSION}${C_RESET} — external worktrees for Claude Code
${C_DIM}repo: ${REPO_ROOT}${C_RESET}

EOF

ask() {
  local prompt="$1" default="$2" reply
  if [[ -n "${default}" ]]; then
    printf '%s %s[%s]%s ' "${prompt}" "${C_DIM}" "${default}" "${C_RESET}" >&2
  else
    printf '%s ' "${prompt}" >&2
  fi
  IFS= read -r reply </dev/tty || reply=""
  echo "${reply:-${default}}"
}

ask_yn() {
  local prompt="$1" default="$2" reply yn
  if [[ "${default}" == "y" ]]; then yn="[Y/n]"; else yn="[y/N]"; fi
  printf '%s %s ' "${prompt}" "${yn}" >&2
  IFS= read -r reply </dev/tty || reply=""
  reply="${reply:-${default}}"
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# 1. worktree root
say ""
say "${C_DIM}Where should new worktrees live? Placing them outside the main repo${C_RESET}"
say "${C_DIM}keeps file watchers, bundlers, and IDE indexers from seeing duplicate${C_RESET}"
say "${C_DIM}copies of your code.${C_RESET}"
DEFAULT_ROOT="~/.worktrees/${REPO_NAME}"
WORKTREE_ROOT="$(ask "Worktree root" "${DEFAULT_ROOT}")"

# 2. symlink dirs
DETECTED_SYMLINKS=()
for d in "${GRAFT_DETECT_SYMLINK_DIRS[@]}"; do
  [[ -d "${REPO_ROOT}/${d}" ]] && DETECTED_SYMLINKS+=("${d}")
done
DEFAULT_SYMLINKS=""
if [[ ${#DETECTED_SYMLINKS[@]} -gt 0 ]]; then
  DEFAULT_SYMLINKS="$(IFS=,; echo "${DETECTED_SYMLINKS[*]}")"
fi
say ""
say "${C_DIM}Which directories should be symlinked back to the main repo? Use this${C_RESET}"
say "${C_DIM}for folders too large to duplicate per worktree, or coupled to tooling${C_RESET}"
say "${C_DIM}that breaks when watched from multiple paths — build outputs, dependency${C_RESET}"
say "${C_DIM}caches, platform-specific project folders.${C_RESET}"
say "${C_DIM}Comma-separated. Leave blank for none.${C_RESET}"
SYMLINKS_INPUT="$(ask "Symlink dirs" "${DEFAULT_SYMLINKS}")"

# 3. files to copy
DETECTED_COPY=()
for f in "${GRAFT_DETECT_COPY_FILES[@]}"; do
  [[ -f "${REPO_ROOT}/${f}" ]] && DETECTED_COPY+=("${f}")
done
DEFAULT_COPY=""
if [[ ${#DETECTED_COPY[@]} -gt 0 ]]; then
  DEFAULT_COPY="$(IFS=,; echo "${DETECTED_COPY[*]}")"
fi
say ""
say "${C_DIM}Which gitignored files should be copied into each new worktree? A fresh${C_RESET}"
say "${C_DIM}worktree won't include anything that isn't tracked by git — env files,${C_RESET}"
say "${C_DIM}local credentials, version pins — so graft copies them in for you.${C_RESET}"
say "${C_DIM}Comma-separated. Leave blank for none.${C_RESET}"
COPY_INPUT="$(ask "Files to copy" "${DEFAULT_COPY}")"

# 4. scaffold commands — auto-detected, not prompted
SCAFFOLD_LINES=()
DETECTED_LOCKFILE=""
for entry in "${GRAFT_DETECT_INSTALL[@]}"; do
  lockfile="${entry%%|*}"
  install_command="${entry#*|}"
  if [[ -f "${REPO_ROOT}/${lockfile}" ]]; then
    SCAFFOLD_LINES+=("${install_command}")
    DETECTED_LOCKFILE="${lockfile}"
    break
  fi
done

say ""
say "${C_BOLD}Summary${C_RESET}"
say "  worktree root:  ${WORKTREE_ROOT}"
say "  symlink dirs:   ${SYMLINKS_INPUT:-(none)}"
say "  copy files:     ${COPY_INPUT:-(none)}"
if [[ ${#SCAFFOLD_LINES[@]} -gt 0 ]]; then
  say "  scaffold:       ${SCAFFOLD_LINES[0]} ${C_DIM}(detected from ${DETECTED_LOCKFILE})${C_RESET}"
else
  say "  scaffold:       ${C_DIM}(nothing detected)${C_RESET}"
fi
say "                  ${C_DIM}↳ tip: add more steps (codegen, db setup, asset linking)${C_RESET}"
say "                  ${C_DIM}  by editing .claude/graft-scaffold.sh after install.${C_RESET}"
say ""

if ! ask_yn "Write configuration to ${REPO_ROOT}/.claude/?" y; then
  die "aborted"
fi

mkdir -p "${REPO_ROOT}/.claude"

# Trim leading/trailing whitespace and shell-escape (single-quote with
# embedded-quote handling) each comma-separated entry, emitting them as
# a bash array body: 'ios' 'android'
to_shell_array() {
  local input="$1" item out=""
  [[ -z "${input}" ]] && { printf ''; return; }
  IFS=',' read -ra items <<< "${input}"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -z "${item}" ]] && continue
    out+=" '${item//\'/\'\\\'\'}'"
  done
  printf '%s' "${out# }"
}

# Escape for inclusion inside double-quoted shell string (preserves ~).
shell_dq_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$/\\\$}"
  s="${s//\`/\\\`}"
  printf '%s' "${s}"
}

SYMLINKS_ARR="$(to_shell_array "${SYMLINKS_INPUT}")"
COPY_ARR="$(to_shell_array "${COPY_INPUT}")"
WORKTREE_ROOT_ESC="$(shell_dq_escape "${WORKTREE_ROOT}")"

cat > "${REPO_ROOT}/.claude/graft.config" <<EOF
# graft.config — sourced by .claude/graft-hook.sh
# Edit freely. Re-run the installer with --force to regenerate.

GRAFT_WORKTREE_ROOT="${WORKTREE_ROOT_ESC}"
GRAFT_SYMLINK_DIRS=(${SYMLINKS_ARR})
GRAFT_COPY_FILES=(${COPY_ARR})
GRAFT_SCAFFOLD=".claude/graft-scaffold.sh"

# Dirs to always copy instead of symlink (comma-separated). Useful when your
# toolchain can't follow symlinks (e.g. React Native / Metro). Env var of the
# same name overrides this per invocation.
GRAFT_COPY_DIRS=""
EOF
ok "wrote .claude/graft.config"

HOOK_PATH="${REPO_ROOT}/.claude/graft-hook.sh"
if [[ -f "${HOOK_PATH}" ]] && [[ ${FORCE} -eq 0 ]]; then
  warn "  skipping .claude/graft-hook.sh (exists; use --force to overwrite)"
else
  cat > "${HOOK_PATH}" <<'GRAFT_HOOK_EOF'
__GRAFT_HOOK_TEMPLATE__
GRAFT_HOOK_EOF
  chmod +x "${HOOK_PATH}"
  ok "wrote .claude/graft-hook.sh"
fi

SCAFFOLD_PATH="${REPO_ROOT}/.claude/graft-scaffold.sh"
if [[ -f "${SCAFFOLD_PATH}" ]] && [[ ${FORCE} -eq 0 ]]; then
  warn "  skipping .claude/graft-scaffold.sh (exists; use --force to overwrite)"
else
  {
    cat <<'GRAFT_SCAFFOLD_EOF'
__GRAFT_SCAFFOLD_TEMPLATE__
GRAFT_SCAFFOLD_EOF
    for line in "${SCAFFOLD_LINES[@]}"; do
      printf '%s\n' "${line}"
    done
  } > "${SCAFFOLD_PATH}"
  chmod +x "${SCAFFOLD_PATH}"
  ok "wrote .claude/graft-scaffold.sh"
fi

# Drop a Claude Code skill file so any agent working in this repo understands
# what graft is, where worktrees live, and how to use the config files.
SKILL_DIR="${REPO_ROOT}/.claude/skills/graft"
SKILL_PATH="${SKILL_DIR}/SKILL.md"
if [[ -f "${SKILL_PATH}" ]] && [[ ${FORCE} -eq 0 ]]; then
  warn "  skipping .claude/skills/graft/SKILL.md (exists; use --force to overwrite)"
else
  mkdir -p "${SKILL_DIR}"
  cat > "${SKILL_PATH}" <<'GRAFT_SKILL_EOF'
__GRAFT_SKILL_TEMPLATE__
GRAFT_SKILL_EOF
  ok "wrote .claude/skills/graft/SKILL.md"
fi

SETTINGS="${REPO_ROOT}/.claude/settings.json"

# Returns "none", "graft", or "other:<cmd1>\x1f<cmd2>..."
# The \x1f (ASCII unit separator) is used as the join delimiter because
# command strings can theoretically contain any character except \x1f.
detect_existing_worktree_hook() {
  [[ ! -f "${SETTINGS}" ]] && { echo "none"; return; }
  if command -v jq >/dev/null 2>&1; then
    local cmds
    if ! cmds="$(jq -r '[.hooks.WorktreeCreate[]?.hooks[]?.command] | .[]' "${SETTINGS}" 2>/dev/null)"; then
      warn "  .claude/settings.json is not valid JSON; skipping hook conflict detection"
      echo "none"
      return
    fi
    if [[ -z "${cmds}" ]]; then
      echo "none"
    elif echo "${cmds}" | grep -qxF ".claude/graft-hook.sh"; then
      echo "graft"
    else
      printf 'other:%s\n' "$(echo "${cmds}" | tr '\n' $'\x1f')"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "${SETTINGS}" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except FileNotFoundError:
    print("none"); sys.exit(0)
except json.JSONDecodeError:
    print("invalid"); sys.exit(0)
wc = data.get("hooks", {}).get("WorktreeCreate", []) or []
cmds = [h.get("command", "") for entry in wc for h in entry.get("hooks", [])]
cmds = [c for c in cmds if c]
if not cmds:
    print("none")
elif ".claude/graft-hook.sh" in cmds:
    print("graft")
else:
    print("other:" + "\x1f".join(cmds))
PYEOF
  else
    echo "none"
  fi
}

REPLACE_HOOK=0
SKIP_HOOK_PATCH=0
EXISTING_HOOK="$(detect_existing_worktree_hook)"

if [[ "${EXISTING_HOOK}" == "invalid" ]]; then
  warn "  .claude/settings.json is not valid JSON; skipping hook conflict detection"
elif [[ "${EXISTING_HOOK}" == other:* ]]; then
  existing_list="${EXISTING_HOOK#other:}"
  say ""
  warn "An existing WorktreeCreate hook is already registered in .claude/settings.json:"
  IFS=$'\x1f' read -ra existing_cmds <<< "${existing_list}"
  for cmd in "${existing_cmds[@]}"; do
    [[ -z "${cmd}" ]] && continue
    warn "  - ${cmd}"
  done
  warn "Two WorktreeCreate hooks fighting over the same event would be confusing,"
  warn "so graft won't add itself alongside it without your say-so."
  say ""
  if ask_yn "Replace the existing hook with graft's?" y; then
    REPLACE_HOOK=1
  else
    SKIP_HOOK_PATCH=1
  fi
fi

patch_settings() {
  if command -v jq >/dev/null 2>&1; then
    local current="{}"
    [[ -f "${SETTINGS}" ]] && current="$(cat "${SETTINGS}")"
    if [[ ${REPLACE_HOOK} -eq 1 ]]; then
      printf '%s' "${current}" | jq '
        .hooks //= {} |
        .hooks.WorktreeCreate = [{
          "matcher": "",
          "hooks": [{ "type": "command", "command": ".claude/graft-hook.sh" }]
        }]
      ' > "${SETTINGS}.tmp"
    else
      printf '%s' "${current}" | jq '
        .hooks //= {} |
        .hooks.WorktreeCreate //= [] |
        if (
          [.hooks.WorktreeCreate[]?.hooks[]?.command] | index(".claude/graft-hook.sh")
        ) then
          .
        else
          .hooks.WorktreeCreate += [{
            "matcher": "",
            "hooks": [{ "type": "command", "command": ".claude/graft-hook.sh" }]
          }]
        end
      ' > "${SETTINGS}.tmp"
    fi
    mv "${SETTINGS}.tmp" "${SETTINGS}"
    ok "patched .claude/settings.json"
  elif command -v python3 >/dev/null 2>&1; then
    GRAFT_REPLACE_HOOK="${REPLACE_HOOK}" python3 - "${SETTINGS}" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
replace = os.environ.get("GRAFT_REPLACE_HOOK") == "1"
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except json.JSONDecodeError:
        data = {}
hooks = data.setdefault("hooks", {})
entry = {
    "matcher": "",
    "hooks": [{"type": "command", "command": ".claude/graft-hook.sh"}],
}
if replace:
    hooks["WorktreeCreate"] = [entry]
else:
    wc = hooks.setdefault("WorktreeCreate", [])
    already = any(
        h.get("command") == ".claude/graft-hook.sh"
        for e in wc
        for h in e.get("hooks", [])
    )
    if not already:
        wc.append(entry)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PYEOF
    ok "patched .claude/settings.json"
  else
    warn "  neither jq nor python3 found — add this to .claude/settings.json manually:"
    cat <<'EOF' >&2
{
  "hooks": {
    "WorktreeCreate": [
      { "matcher": "", "hooks": [{ "type": "command", "command": ".claude/graft-hook.sh" }] }
    ]
  }
}
EOF
  fi
}

if [[ ${SKIP_HOOK_PATCH} -eq 1 ]]; then
  warn "  skipped .claude/settings.json — your existing WorktreeCreate hook is unchanged"
  warn "  graft's hook script and config are still on disk; wire them in manually if needed"
else
  patch_settings
fi

# Append a line to a file, ensuring it sits on its own line (handles the
# common case where the file doesn't end with a trailing newline).
append_line() {
  local file="$1" line="$2"
  if [[ -s "${file}" ]] && [[ "$(tail -c1 "${file}" 2>/dev/null)" != "" ]]; then
    printf '\n' >> "${file}"
  fi
  printf '%s\n' "${line}" >> "${file}"
}

GITIGNORE="${REPO_ROOT}/.gitignore"
if [[ -f "${GITIGNORE}" ]] && ! grep -qxF ".claude/settings.local.json" "${GITIGNORE}"; then
  append_line "${GITIGNORE}" ".claude/settings.local.json"
  ok "added .claude/settings.local.json to .gitignore"
fi

# Detect if any graft files are gitignored — happens when a user has a broad
# pattern like `.claude/` or `.claude/*` in their .gitignore. Without this,
# graft would silently install but the files would never be committed.
check_ignored() {
  local out=()
  local file
  for file in .claude/graft.config .claude/graft-hook.sh .claude/graft-scaffold.sh .claude/settings.json .claude/skills/graft/SKILL.md; do
    if (cd "${REPO_ROOT}" && git check-ignore -q "${file}" 2>/dev/null); then
      out+=("${file}")
    fi
  done
  printf '%s\n' "${out[@]+"${out[@]}"}"
}

IGNORED=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && IGNORED+=("${line}")
done < <(check_ignored)

if [[ ${#IGNORED[@]} -gt 0 ]]; then
  say ""
  warn "Heads up: these files are matched by your .gitignore and won't be committed:"
  for f in "${IGNORED[@]}"; do
    warn "  - ${f}"
  done
  warn "graft works fine locally, but teammates won't inherit the setup until"
  warn "those files are tracked."
  say ""
  if ask_yn "Append un-ignore rules to .gitignore so graft files get tracked?" y; then
    cat >> "${GITIGNORE}" <<'GITIGNORE_EOF'

# graft — keep worktree setup tracked while leaving other .claude/ contents ignored
!.claude/
.claude/*
!.claude/graft.config
!.claude/graft-hook.sh
!.claude/graft-scaffold.sh
!.claude/settings.json
!.claude/skills/
!.claude/skills/graft/
!.claude/skills/graft/SKILL.md
GITIGNORE_EOF

    STILL_IGNORED=()
    while IFS= read -r line; do
      [[ -n "${line}" ]] && STILL_IGNORED+=("${line}")
    done < <(check_ignored)

    if [[ ${#STILL_IGNORED[@]} -eq 0 ]]; then
      ok "appended graft un-ignore rules to .gitignore"
    else
      warn "Couldn't fully un-ignore — you may have a more restrictive pattern."
      warn "Add these manually to .gitignore:"
      for f in "${STILL_IGNORED[@]}"; do warn "  !${f}"; done
    fi
  else
    warn "Skipped. Add !-rules manually if you want teammates to inherit the setup."
  fi
fi

say ""
printf '%s✓ graft is ready.%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}"
say ""
say "Try it:"
say "  ${C_DIM}claude --worktree my-feature${C_RESET}"
say ""
say "Your worktree will be created at:"
say "  ${C_BOLD}${WORKTREE_ROOT}/my-feature${C_RESET}"
say ""
say "Need more bootstrap steps (codegen, asset linking, db setup)?"
say "Edit ${C_BOLD}.claude/graft-scaffold.sh${C_RESET} — it's a plain bash script that runs"
say "after each worktree is created. graft won't touch it again."
say ""

offer_cwt() {
  local user_shell rc
  user_shell="$(basename "${SHELL:-bash}")"
  case "${user_shell}" in
    bash) rc="${HOME}/.bashrc" ;;
    zsh)  rc="${HOME}/.zshrc" ;;
    *) return 0 ;;
  esac

  if [[ -f "${rc}" ]] && grep -q '# >>> graft cwt helper >>>' "${rc}" 2>/dev/null; then
    return 0
  fi

  say "${C_BOLD}Bonus: cwt — fuzzy worktree switcher${C_RESET}"
  say "${C_DIM}A tiny shell function that lists every worktree git knows about,${C_RESET}"
  say "${C_DIM}lets you fzf-pick one, and cd's into it. Handy now that graft creates${C_RESET}"
  say "${C_DIM}worktrees outside your repo — you can jump back to them from anywhere.${C_RESET}"
  say ""
  local prompt_label="Append the cwt function to ${rc}?"
  if command -v fzf >/dev/null 2>&1; then
    say "  ${C_GREEN}✓${C_RESET} fzf is installed"
  else
    say "  ${C_YELLOW}!${C_RESET} fzf is not installed — cwt will not work until you install it."
    say "    ${C_DIM}macOS: brew install fzf  •  Debian/Ubuntu: apt install fzf${C_RESET}"
    prompt_label="Append cwt anyway (won't work until fzf is installed)?"
  fi
  say ""
  if ask_yn "${prompt_label}" n; then
    cat >> "${rc}" <<'CWT_EOF'

# >>> graft cwt helper >>>
# Fuzzy worktree switcher. Requires fzf.
cwt() {
  local root selection dir
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; return 1; }
  selection="$(
    git -C "$root" worktree list --porcelain | awk '
      /^worktree / { path = substr($0, 10) }
      /^branch /   { br = substr($0, 19); printf "%-40s %s\n", br, path; br="" }
      /^detached/  { printf "%-40s %s\n", "(detached)", path }
    ' | fzf --height=40% --reverse --header="worktrees" --prompt="cwt> "
  )" || return 1
  dir="$(printf '%s' "$selection" | awk '{print $NF}')"
  [ -n "$dir" ] && cd "$dir"
}
# <<< graft cwt helper <<<
CWT_EOF
    ok "appended cwt to ${rc}"
    say "  ${C_DIM}restart your shell or run: source ${rc}${C_RESET}"
    say ""
  fi
}
offer_cwt
