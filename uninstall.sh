#!/usr/bin/env bash
# 9r-cbgb-patch uninstaller — puts the stock 9router server back.
#
#   curl -fsSL https://raw.githubusercontent.com/capncodes69/9r-cbgb-patch/main/uninstall.sh | bash
#
# What it undoes: the patched app/ directory installed by patch.sh, restored from
# the backup that run made. Your data in ~/.9router is never touched.
#
# Two ways to restore:
#   1. From the backup recorded by patch.sh (exact previous state)
#   2. By reinstalling the stock build with npm (fallback, if no backup exists)
#
# Options:
#   NINEROUTER_UNINSTALL_NPM=1     force the npm reinstall path
#   NINEROUTER_DRY_RUN=1           show the plan, change nothing

set -euo pipefail

REPO="capncodes69/9r-cbgb-patch"

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

log "9r-cbgb-patch uninstaller"

# ── Find the CLI ────────────────────────────────────────────────────────────
command -v npm >/dev/null 2>&1 || die "npm not found."
NPM_ROOT=$(npm root -g 2>/dev/null || true)
CLI_DIR=""
# NINEROUTER_CLI_DIR overrides discovery — useful for a non-standard prefix
# (nvm, pnpm, a Homebrew keg) and for testing.
for candidate in \
  "${NINEROUTER_CLI_DIR:-}" \
  "${NPM_ROOT:-/nonexistent}/9router" \
  "$HOME/.npm-global/lib/node_modules/9router" \
  "/usr/local/lib/node_modules/9router" \
  "/opt/homebrew/lib/node_modules/9router"; do
  [[ -n "$candidate" && -d "$candidate" ]] && { CLI_DIR="$candidate"; break; }
done

if [[ -z "$CLI_DIR" ]]; then
  warn "no global '9router' install found — nothing to restore here."
  dim "If you built a patched checkout somewhere, delete it directly."
  exit 0
fi
ok "9router CLI: $CLI_DIR"

MANIFEST="$CLI_DIR/.9r-cbgb-patch.json"
BACKUP=""
if [[ -f "$MANIFEST" ]]; then
  # The manifest is written by patch.sh; read `backup` without requiring jq.
  BACKUP=$(sed -n 's/.*"backup": *"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)
  ok "found install record: $MANIFEST"
  [[ -n "$BACKUP" ]] && dim "backup: $BACKUP"
else
  # No manifest (patched by an older run, or the file was removed). Fall back to
  # the newest app.bak-* beside app/, which is the same thing patch.sh creates.
  BACKUP=$(ls -1d "$CLI_DIR"/app.bak-* 2>/dev/null | sort | tail -1 || true)
  if [[ -n "$BACKUP" ]]; then
    warn "no manifest — using the newest backup found: $(basename "$BACKUP")"
  else
    warn "no manifest and no app.bak-* backup found."
  fi
fi

if [[ "${NINEROUTER_DRY_RUN:-0}" == "1" ]]; then
  echo
  log "Dry run — nothing was changed."
  if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
    dim "would restore : $BACKUP -> $CLI_DIR/app"
  else
    dim "would reinstall: npm i -g 9router@latest"
  fi
  dim "would remove  : $MANIFEST"
  exit 0
fi

# ── Restore ─────────────────────────────────────────────────────────────────
if [[ "${NINEROUTER_UNINSTALL_NPM:-0}" != "1" && -n "$BACKUP" && -d "$BACKUP" ]]; then
  log "Restoring the pre-patch app from backup…"
  # Move the patched tree aside first rather than deleting it: if the copy fails
  # halfway the user still has a working server to move back.
  PATCHED="$CLI_DIR/app.patched-$(date +%Y%m%d-%H%M%S)"
  if [[ -d "$CLI_DIR/app" ]]; then
    mv "$CLI_DIR/app" "$PATCHED" || die "cannot move $CLI_DIR/app aside (try sudo)"
  fi
  mv "$BACKUP" "$CLI_DIR/app" || {
    # Put the patched tree back so the CLI is not left broken.
    [[ -d "$PATCHED" ]] && mv "$PATCHED" "$CLI_DIR/app"
    die "cannot restore $BACKUP (try sudo)"
  }
  ok "restored from $(basename "$BACKUP")"
  rm -rf "$PATCHED"
  rm -f "$MANIFEST"
  ok "removed the install record"
else
  # No usable backup: reinstall the published package. This is also the path that
  # picks up a newer upstream release, so it is not merely a fallback.
  log "Reinstalling stock 9router from npm…"
  npm install -g 9router@latest --no-audit --no-fund --loglevel=error \
    || die "npm install -g 9router failed (try with sudo)"
  ok "reinstalled"
  [[ -f "$MANIFEST" ]] && rm -f "$MANIFEST" && ok "removed the install record"
fi

echo
log "Done — 9router is back to stock."
dim "Your data in ~/.9router was not touched."
echo
echo "  Verify with:  9router --version"
