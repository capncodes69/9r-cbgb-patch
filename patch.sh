#!/usr/bin/env bash
# 9r-cbgb-patch — two fixes for CodeBuddy (cbai/*) in your 9router checkout.
#
# Run it from the root of a 9router repo:
#
#   bash patch.sh
#
# That is all. No install, no environment variables, no build step. It edits the
# source files in place; `npm run dev` and `npm run build` pick them up as usual.
#
# Undo with:  bash patch.sh --revert
# Check with: bash patch.sh --check

set -euo pipefail

REPO="capncodes69/9r-cbgb-patch"
PATCH_URL="https://raw.githubusercontent.com/${REPO}/main/patches/9r-cbgb-fix.patch"
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

MODE="apply"
case "${1:-}" in
  --revert|-r) MODE="revert" ;;
  --check|-c)  MODE="check" ;;
  --help|-h)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

# ── Platform ────────────────────────────────────────────────────────────────
# This script is POSIX sh/bash: Linux, macOS, and the Git Bash / WSL shells that
# ship with a Windows dev setup. On native Windows PowerShell or cmd, `bash` may
# not exist at all, so point at patch.ps1 rather than failing with a confusing
# "command not found" further down.
case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux*)                  PLATFORM="Linux" ;;
  Darwin*)                 PLATFORM="macOS" ;;
  MINGW*|MSYS*|CYGWIN*)    PLATFORM="Windows (Git Bash)" ;;
  *)                       PLATFORM="$(uname -s 2>/dev/null || echo unknown)" ;;
esac
dim "platform: $PLATFORM"

# ── Are we in a 9router checkout? ───────────────────────────────────────────
[[ -f package.json ]] || die "run this from the root of a 9router checkout (no package.json here)"
grep -q '"9router-app"' package.json 2>/dev/null \
  || die "this does not look like 9router (package.json has no \"9router-app\")"
[[ -f open-sse/executors/codebuddy-intl.js ]] \
  || die "open-sse/ not found — is this a complete checkout?"
ok "9router checkout: $PWD"

if ! command -v git >/dev/null 2>&1; then
  die "git not found — it is used to apply and revert the patch.
     Linux:   sudo apt install git     (or dnf/pacman)
     macOS:   xcode-select --install
     Windows: winget install Git.Git"
fi

# ── Load the patch ──────────────────────────────────────────────────────────
TMP_PATCH=$(mktemp)
trap 'rm -f "$TMP_PATCH"' EXIT
if [[ -n "$LOCAL_PATCH" ]]; then
  cp "$LOCAL_PATCH" "$TMP_PATCH" || die "cannot read $LOCAL_PATCH"
else
  curl -fsSL "$PATCH_URL" -o "$TMP_PATCH" || die "cannot download the patch"
fi

applied() { git apply --reverse --check "$TMP_PATCH" 2>/dev/null; }
appliable() { git apply --check "$TMP_PATCH" 2>/dev/null; }

# ── Modes ───────────────────────────────────────────────────────────────────
case "$MODE" in
  check)
    if applied; then
      ok "patched"
      exit 0
    elif appliable; then
      warn "not patched"
      exit 1
    else
      warn "not patched, and the patch would not apply (upstream has probably moved)"
      exit 2
    fi
    ;;

  revert)
    if applied; then
      git apply --reverse "$TMP_PATCH" || die "revert failed"
      ok "reverted — source is back to stock"
    else
      ok "nothing to revert (not patched)"
    fi
    exit 0
    ;;

  apply)
    if applied; then
      ok "already patched — nothing to do"
    elif appliable; then
      git apply "$TMP_PATCH" || die "patch failed"
      ok "patch applied"
    else
      die "the patch does not apply to this checkout. Upstream has probably moved; check for a newer bundle."
    fi
    ;;
esac

# ── Confirm both fixes are in the tree ──────────────────────────────────────
grep -q 'X-Conversation-ID' open-sse/executors/codebuddy-intl.js \
  || die "verification failed: header family missing"
grep -q 'request illegal' open-sse/config/errorConfig.js \
  || die "verification failed: WAF rule missing"
grep -q 'providerId' open-sse/services/combo.js \
  || die "verification failed: combo provider passthrough missing"
ok "both fixes present"

echo
log "Done."
echo "  Run it the usual way:"
echo "    npm run dev"
echo
echo "  To undo:  bash patch.sh --revert"
