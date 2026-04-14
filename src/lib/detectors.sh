# detectors.sh — defaults the init wizard suggests to the user.
#
# These are *suggestions only*. The wizard pre-fills its prompts with whatever
# matches in the user's repo; the user can accept, edit, or replace them.
# Add a new entry here when graft should know about a new ecosystem.
#
# Inlined into docs/init at build time. Not used at runtime by the hook.

# ─── Gitignored files that worktrees usually need copies of ──────────────────
GRAFT_DETECT_COPY_FILES=(
  # env files (any framework)
  .env
  .env.local
  .env.development
  .env.production
  .env.test

  # mobile firebase
  google-services.json
  GoogleService-Info.plist

  # private package registries
  .npmrc
  .yarnrc.yml

  # language version pins
  .python-version
  .ruby-version
  .nvmrc
  .tool-versions
)

# ─── Directories worth symlinking back to the main repo ──────────────────────
# These tend to be either huge (so re-creating per worktree wastes disk) or
# coupled to native tooling that breaks when watched from multiple paths.
#
# Only include entries that are unambiguous — e.g. don't suggest "build"
# because it overlaps with Gradle, Next.js, committed assets, etc. Don't
# suggest "venv" / ".venv" either: sharing a virtualenv across worktrees
# breaks per-worktree dependency isolation.
GRAFT_DETECT_SYMLINK_DIRS=(
  # React Native / Expo native projects
  ios
  android

  # JS framework build caches
  .next
  .nuxt
  .svelte-kit
  .turbo

  # Rust / Gradle build artifacts
  target
  .gradle
)

# ─── Package manager → install command (ordered by priority) ─────────────────
# Format: "lockfile|command". The first lockfile that exists wins.
GRAFT_DETECT_INSTALL=(
  # JavaScript
  "bun.lock|bun install"
  "bun.lockb|bun install"
  "pnpm-lock.yaml|pnpm install --frozen-lockfile"
  "yarn.lock|yarn install --frozen-lockfile"
  "package-lock.json|npm ci"

  # Rust
  "Cargo.lock|cargo fetch"

  # Go
  "go.sum|go mod download"

  # Ruby
  "Gemfile.lock|bundle install"

  # Python
  "uv.lock|uv sync"
  "poetry.lock|poetry install"
  "Pipfile.lock|pipenv install --deploy"

  # PHP
  "composer.lock|composer install"

  # Elixir
  "mix.lock|mix deps.get"
)
