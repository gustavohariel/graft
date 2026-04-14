#!/usr/bin/env bash
# graft-hook.sh — invoked by Claude Code's WorktreeCreate hook.
#
# Reads .claude/graft.config (shell-sourced), creates a worktree at the
# configured external location, copies gitignored files, sets up symlinks
# back to the main repo, then runs the user's scaffold script.
#
# Pure bash + git. No jq, python, or other runtimes required.
#
# This file lives in your repo and is yours to edit. To regenerate it:
#   curl -fsSL https://gustavohariel.github.io/graft/bin/install | bash -s -- --force

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG="${REPO_ROOT}/.claude/graft.config"

if [[ ! -f "${CONFIG}" ]]; then
  echo "graft: config not found at ${CONFIG}" >&2
  exit 1
fi

GRAFT_WORKTREE_ROOT=""
GRAFT_SYMLINK_DIRS=()
GRAFT_COPY_FILES=()
GRAFT_SCAFFOLD=""
# GRAFT_COPY_DIRS: env var wins over config default, so capture env first.
_ENV_COPY_DIRS="${GRAFT_COPY_DIRS:-}"
GRAFT_COPY_DIRS=""
# shellcheck disable=SC1090
source "${CONFIG}"
if [[ -n "${_ENV_COPY_DIRS}" ]]; then
  GRAFT_COPY_DIRS="${_ENV_COPY_DIRS}"
fi

if [[ -z "${GRAFT_WORKTREE_ROOT}" ]]; then
  echo "graft: GRAFT_WORKTREE_ROOT is not set in ${CONFIG}" >&2
  exit 1
fi

INPUT="$(cat)"

# Parse Claude Code's flat JSON payload. Values are paths / branch names —
# no embedded quotes, no nested JSON — so a greedy sed pattern is safe here.
get_str() {
  printf '%s' "${INPUT}" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}
get_bool() {
  printf '%s' "${INPUT}" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" | head -n1
}

# Claude Code's current WorktreeCreate payload is minimal: session_id,
# transcript_path, cwd, hook_event_name, and `name` (the worktree name the
# user requested). Everything else is up to the hook. We also read fields
# from older Claude Code formats so users on previous versions keep working:
#
#   current  : name
#   earlier  : worktree_name + new_branch + source_branch
#   earliest : worktree_path + branch + detach

NAME="$(get_str name)"
[[ -z "${NAME}" ]] && NAME="$(get_str worktree_name)"

if [[ -z "${NAME}" ]]; then
  LEGACY_PATH="$(get_str worktree_path)"
  if [[ -n "${LEGACY_PATH}" ]]; then
    # Strip the .claude/worktrees/ prefix so sub-paths like feat/foo stay intact.
    NAME="${LEGACY_PATH#*/.claude/worktrees/}"
  fi
fi

if [[ -z "${NAME}" ]]; then
  echo "graft: could not find name/worktree_name/worktree_path in hook input" >&2
  echo "graft: raw payload follows (for debugging):" >&2
  printf '%s\n' "${INPUT}" >&2
  exit 1
fi

# Branch: the current payload doesn't carry one, so default to the worktree
# name verbatim. Older payloads sent branch/new_branch/source_branch; honor
# those if present.
BRANCH="$(get_str new_branch)"
[[ -z "${BRANCH}" ]] && BRANCH="$(get_str branch)"
[[ -z "${BRANCH}" ]] && BRANCH="${NAME}"

SOURCE_BRANCH="$(get_str source_branch)"
LEGACY_DETACH="$(get_bool detach)"

WORKTREE_ROOT="${GRAFT_WORKTREE_ROOT/#\~/$HOME}"
TARGET="${WORKTREE_ROOT}/${NAME}"

mkdir -p "$(dirname "${TARGET}")"

if [[ "${LEGACY_DETACH}" == "true" ]]; then
  (cd "${REPO_ROOT}" && git worktree add --detach "${TARGET}" >&2)
elif (cd "${REPO_ROOT}" && git show-ref --verify --quiet "refs/heads/${BRANCH}"); then
  # Branch already exists — attach the worktree to it.
  (cd "${REPO_ROOT}" && git worktree add "${TARGET}" "${BRANCH}" >&2)
elif [[ -n "${SOURCE_BRANCH}" ]]; then
  # New branch from an explicitly requested source.
  (cd "${REPO_ROOT}" && git worktree add -b "${BRANCH}" "${TARGET}" "${SOURCE_BRANCH}" >&2)
else
  # New branch, base it on whatever HEAD currently points at in the main repo.
  (cd "${REPO_ROOT}" && git worktree add -b "${BRANCH}" "${TARGET}" >&2)
fi

for file in ${GRAFT_COPY_FILES[@]+"${GRAFT_COPY_FILES[@]}"}; do
  [[ -z "${file}" ]] && continue
  src="${REPO_ROOT}/${file}"
  dst="${TARGET}/${file}"
  if [[ -e "${src}" ]]; then
    mkdir -p "$(dirname "${dst}")"
    cp -R "${src}" "${dst}"
  fi
done

# Dirs listed in GRAFT_COPY_DIRS get a full copy instead of a symlink.
# Set as a repo-wide default in graft.config (e.g. GRAFT_COPY_DIRS="android")
# when symlinks don't work for your toolchain (React Native/Metro), or as a
# per-invocation env var to override for one worktree:
#   e.g. GRAFT_COPY_DIRS=android claude --worktree test-upgrade
OVERRIDE_COPY=()
if [[ -n "${GRAFT_COPY_DIRS:-}" ]]; then
  IFS=',' read -ra OVERRIDE_COPY <<< "${GRAFT_COPY_DIRS}"
fi
is_copy_override() {
  local target="$1" d
  for d in ${OVERRIDE_COPY[@]+"${OVERRIDE_COPY[@]}"}; do
    d="${d# }"; d="${d% }"
    [[ "${d}" == "${target}" ]] && return 0
  done
  return 1
}

for dir in ${GRAFT_SYMLINK_DIRS[@]+"${GRAFT_SYMLINK_DIRS[@]}"}; do
  [[ -z "${dir}" ]] && continue
  src="${REPO_ROOT}/${dir}"
  dst="${TARGET}/${dir}"
  if [[ -e "${src}" ]]; then
    rm -rf "${dst}"
    mkdir -p "$(dirname "${dst}")"
    if is_copy_override "${dir}"; then
      if [[ "$(uname)" == "Darwin" ]]; then
        cp -cR "${src}" "${dst}"
      else
        cp -R "${src}" "${dst}"
      fi
    else
      ln -s "${src}" "${dst}"
    fi
  fi
done

if [[ -n "${GRAFT_SCAFFOLD}" ]]; then
  SCAFFOLD="${REPO_ROOT}/${GRAFT_SCAFFOLD}"
  if [[ -x "${SCAFFOLD}" ]]; then
    (cd "${TARGET}" && "${SCAFFOLD}" "${TARGET}" "${BRANCH}" >&2)
  fi
fi

echo "${TARGET}"
