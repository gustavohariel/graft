#!/usr/bin/env bash
# build.sh — produce a single self-contained installer at bin/install by
# inlining src/lib/detectors.sh and src/templates/* into src/init.sh at
# the marker lines.

set -euo pipefail
cd "$(dirname "$0")"

for f in \
  src/init.sh \
  src/lib/detectors.sh \
  src/templates/graft-hook.sh \
  src/templates/scaffold.sh \
  src/templates/skill.md; do
  if [[ ! -f "$f" ]]; then
    echo "build: missing required source file: $f" >&2
    exit 1
  fi
done

mkdir -p bin

sed \
  -e '/__GRAFT_DETECTORS__/{r src/lib/detectors.sh' -e 'd;}' \
  -e '/__GRAFT_HOOK_TEMPLATE__/{r src/templates/graft-hook.sh' -e 'd;}' \
  -e '/__GRAFT_SCAFFOLD_TEMPLATE__/{r src/templates/scaffold.sh' -e 'd;}' \
  -e '/__GRAFT_SKILL_TEMPLATE__/{r src/templates/skill.md' -e 'd;}' \
  src/init.sh > bin/install

# Verify all markers were replaced (otherwise we shipped a broken installer).
if grep -q '__GRAFT_\(DETECTORS\|HOOK_TEMPLATE\|SCAFFOLD_TEMPLATE\|SKILL_TEMPLATE\)__' bin/install; then
  echo "build: one or more template markers were not replaced — source files missing or empty?" >&2
  exit 1
fi

chmod +x bin/install

lines="$(wc -l < bin/install | tr -d ' ')"
echo "built bin/install (${lines} lines)"
