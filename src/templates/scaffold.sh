#!/usr/bin/env bash
# graft-scaffold.sh — runs after a worktree is created and gitignored files are copied.
#
# Args:
#   $1 — absolute path of the new worktree (also $PWD)
#   $2 — branch name
#
# Add any commands needed to bootstrap a fresh worktree (install deps,
# generate API types, link assets, etc.). This file is yours — graft will
# not touch it again unless you re-run init with --force.

set -euo pipefail

