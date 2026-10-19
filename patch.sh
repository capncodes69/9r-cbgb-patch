#!/usr/bin/env bash
# 9r-cbgb-patch — fixes two CodeBuddy (cbai/*) defects in a 9router checkout.
#
# Usage, from the root of your 9router source checkout:
#
#   bash patch.sh
#
# Or without cloning anything first:
#
#   curl -fsSL https://raw.githubusercontent.com/capncodes69/9r-cbgb-patch/main/patch.sh | bash
#
# It applies the patch, installs dependencies and builds. Run it again any time —
# it detects an already-applied patch and only rebuilds.
#
# Requirements: node >= 22.5, npm, git. ~10 minutes and ~1 GB of disk.

set -euo pipefail

REPO="capncodes69/9r-cbgb-patch"
PATCH_URL="https://raw.githubusercontent.com/${REPO}/main/patches/9r-cbgb-fix.patch"
# Full SHA: `git fetch <ref>` only resolves a full object id or a ref name.
UPSTREAM_REF="87a74e1bda3677193c6f71a7e2100c90311f0689"

# Testing hook: use a patch bundle from disk instead of the published one.
LOCAL_PATCH="${NINEROUTER_LOCAL_PATCH:-}"

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s  xx%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
dim()  { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_OFF"; }

log "9r-cbgb-patch"
dim "two fixes for CodeBuddy (cbai/*): conversation headers, WAF backoff"

# ── Where are we? ───────────────────────────────────────────────────────────
# Two ways in: already inside a checkout, or piped from curl with no repo around.
if [[ -f package.json ]] && grep -q '"9router-app"' package.json 2>/dev/null; then
  REPO_DIR="$PWD"
  ok "9router checkout: $REPO_DIR"
elif [[ -f "$(dirname "$0")/package.json" ]] \
  && grep -q '"9router-app"' "$(dirname "$0")/package.json" 2>/dev/null; then
  REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
  ok "9router checkout: $REPO_DIR"
else
  # Piped from curl, or run from elsewhere: fetch the pinned upstream commit.
  REPO_DIR="${NINEROUTER_HOME:-$PWD/9router}"
  warn "no 9router checkout here — fetching it into $REPO_DIR"
  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" fetch -q --depth 1 origin "$UPSTREAM_REF" || die "git fetch failed"
    git -C "$REPO_DIR" checkout -q --force FETCH_HEAD || die "checkout failed"
  else
    command -v git >/dev/null 2>&1 || die "git not found"
    mkdir -p "$REPO_DIR"
    git init -q "$REPO_DIR"
    git -C "$REPO_DIR" remote add origin https://github.com/decolua/9router.git
    git -C "$REPO_DIR" fetch -q --depth 1 origin "$UPSTREAM_REF" \
      || die "cannot fetch 9router at $UPSTREAM_REF"
    git -C "$REPO_DIR" checkout -q FETCH_HEAD || die "checkout failed"
  fi
  ok "checkout at $(git -C "$REPO_DIR" rev-parse --short HEAD)"
fi

cd "$REPO_DIR"

# Keep npm's cache local. A shared ~/.npm that another user already wrote to
# fails with EACCES partway through the install, far from the real cause.
export npm_config_cache="${NINEROUTER_NPM_CACHE:-$REPO_DIR/.npm-cache}"

# ── Requirements ────────────────────────────────────────────────────────────
command -v npm >/dev/null 2>&1 || die "npm not found. Install Node.js 22.5+ first."
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
NODE_MINOR=$(node -p 'process.versions.node.split(".")[1]' 2>/dev/null || echo 0)
if (( NODE_MAJOR < 22 || (NODE_MAJOR == 22 && NODE_MINOR < 5) )); then
  warn "Node $(node -v): 9router needs >= 22.5 for node:sqlite; older Node falls back to sql.js."
fi
ok "node $(node -v)"

# ── Apply ───────────────────────────────────────────────────────────────────
log "Applying the patch…"
TMP_PATCH=$(mktemp)
trap 'rm -f "$TMP_PATCH"' EXIT
if [[ -n "$LOCAL_PATCH" ]]; then
  cp "$LOCAL_PATCH" "$TMP_PATCH" || die "cannot read $LOCAL_PATCH"
else
  curl -fsSL "$PATCH_URL" -o "$TMP_PATCH" || die "cannot download the patch"
fi

# A patch that does not apply cleanly is the one failure worth refusing: a
# half-applied build has some fixes and not others, which is harder to diagnose
# than a clean stop.
if git apply --reverse --check "$TMP_PATCH" 2>/dev/null; then
  ok "already applied — rebuilding only"
elif git apply --check "$TMP_PATCH" 2>/dev/null; then
  git apply "$TMP_PATCH" || die "patch failed"
  ok "patch applied"
else
  die "the patch does not apply to this checkout. Upstream has probably moved; check for a newer bundle."
fi

# Confirm both fixes are in the tree before spending minutes building.
grep -q 'X-Conversation-ID' open-sse/executors/codebuddy-intl.js \
  || die "verification failed: header family missing"
grep -q 'request illegal' open-sse/config/errorConfig.js \
  || die "verification failed: WAF rule missing"
grep -q 'providerId' open-sse/services/combo.js \
  || die "verification failed: combo provider passthrough missing"
ok "both fixes verified in the tree"

# ── Build ───────────────────────────────────────────────────────────────────
log "Installing dependencies (3-8 min)…"
# --legacy-peer-deps: upstream's tree has a peer conflict npm 7+ treats as fatal
# (@dnd-kit/modifiers wants @dnd-kit/core ^6.3.0; the project pins a newer one).
#
# Remove node_modules first. A previous interrupted install leaves a partial tree,
# and npm then aborts with ENOTEMPTY while trying to reconcile it — a failure that
# looks like a dependency problem but is just debris. package-lock.json is left
# alone, so the resolution is unchanged.
if [[ -d node_modules ]]; then
  rm -rf node_modules || die "cannot clear node_modules"
  dim "cleared a previous node_modules"
fi
npm install --no-audit --no-fund --legacy-peer-deps --loglevel=error \
  || die "npm install failed"

log "Building…"
npm run build || die "build failed"

[[ -f .next/standalone/custom-server.js ]] || die "build produced no standalone server"
ok "build complete: .next/standalone"

# ── Install into the CLI, when one is present ───────────────────────────────
NPM_ROOT=$(npm root -g 2>/dev/null || true)
CLI_DIR=""
for candidate in \
  "${NINEROUTER_CLI_DIR:-}" \
  "${NPM_ROOT:-/nonexistent}/9router" \
  "$HOME/.npm-global/lib/node_modules/9router" \
  "/usr/local/lib/node_modules/9router" \
  "/opt/homebrew/lib/node_modules/9router"; do
  [[ -n "$candidate" && -d "$candidate" ]] && { CLI_DIR="$candidate"; break; }
done

if [[ -z "$CLI_DIR" ]]; then
  echo
  ok "Done — built at $REPO_DIR/.next/standalone"
  dim "No global '9router' CLI found, so nothing was swapped in."
  dim "Start it from here:  cd $REPO_DIR && npm start"
  exit 0
fi

log "Installing into the CLI at $CLI_DIR…"
BACKUP="$CLI_DIR/app.bak-$(date +%Y%m%d-%H%M%S)"
if [[ -d "$CLI_DIR/app" ]]; then
  mv "$CLI_DIR/app" "$BACKUP" || die "cannot back up $CLI_DIR/app (try sudo)"
  ok "backup: $BACKUP"
fi
cp -R .next/standalone "$CLI_DIR/app" || die "cannot install into $CLI_DIR/app (try sudo)"
ok "installed"

# Record what was installed so uninstall.sh can undo exactly this run rather than
# guessing from a timestamp. Lives beside app/ so it travels with the CLI.
cat > "$CLI_DIR/.9r-cbgb-patch.json" <<JSON
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sourceRepo": "$REPO_DIR",
  "sourceCommit": "$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)",
  "patchRepo": "$REPO",
  "backup": "$BACKUP",
  "hadPreviousApp": $([[ -d "$BACKUP" ]] && echo true || echo false)
}
JSON
ok "recorded in $CLI_DIR/.9r-cbgb-patch.json"

echo
log "Done."
echo "  Start it the usual way:  9router"
echo
echo "  To undo everything:"
echo "    curl -fsSL https://raw.githubusercontent.com/$REPO/main/uninstall.sh | bash"
echo
dim "Your data in ~/.9router was not touched."
