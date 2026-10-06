#!/usr/bin/env bash
#
# release.sh — the opinionated release. One command ships:
#
#   scripts/release.sh <patch|minor|major>            # full release
#   scripts/release.sh <patch|minor|major> dry         # build + verify only
#
#   NOTES=path/to/file.md                              # custom release notes
#                                                      # (verbatim; without it the
#                                                      # notes auto-generate from
#                                                      # the commits since the tag)
#
# Stages (each checks current state first, so re-running after a failure
# skips what's done and resumes where it stopped — the version resumes too:
# a tagged bump commit on HEAD means "finish that release", not "roll the
# next one"):
#   1. guards     — clean tree, on main, synced with origin, tooling present
#   2. bump       — Info.plist's CFBundleShortVersionString (the version source)
#   3. build      — ./build.sh, packaged as build/Superpaint.app.tar.gz, then
#                   verified: the tarball roots at Superpaint.app and carries
#                   the binary
#   4. publish    — commit v<next>, tag, push
#   5. release    — gh release with the tarball
#                   (this is the moment the curl install path goes live);
#                   notes auto-generated from the commits since the last tag
#   6. install    — the live curl one-liner must serve exactly this release's
#                   bytes. The site is versionless by design (install.sh
#                   downloads releases/latest/...), so a release never edits
#                   or deploys the site — it only proves the path is live
#   7. receipt    — everything printed, one line each
#
# There is no signing and no update channel: Superpaint has no network code,
# so a release is just the tarball on GitHub Releases.
# The FIRST release is special: with no tags in the repo, the version ships
# as-is (no bump) — v1.0.0 ships 1.0.0.

set -euo pipefail

# ---- args ------------------------------------------------------------------

MODE=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    dry|dry-run|--dry-run) DRY_RUN=1 ;;
    patch|minor|major) MODE="$arg" ;;
    *) echo "usage: scripts/release.sh <patch|minor|major> [dry]" >&2; exit 1 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: scripts/release.sh <patch|minor|major> [dry]" >&2; exit 1; }

cd "$(dirname "$0")/.."

REPO="faraz-35/superpaint"
SITE_URL="https://getsuperpaint.vercel.app"
PLIST="Info.plist"
TARGZ="build/Superpaint.app.tar.gz"

# ---- resolve the version ---------------------------------------------------

CUR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
# Resume rule: a release that died mid-publish leaves its bump commit as HEAD,
# tagged — re-running must finish THAT version. But a FULLY SHIPPED release
# (tag on HEAD, gh release live) that gets re-run is a request for the NEXT
# one, not a resume — without this, the first re-run after any successful
# release would re-ship the same version forever.
TAG_ON_HEAD=0
RESUME=0
if [ "$(git rev-parse -q --verify "refs/tags/v$CUR" 2>/dev/null || true)" = "$(git rev-parse HEAD)" ]; then
  TAG_ON_HEAD=1
fi
SHIPPED=0
if [ "$TAG_ON_HEAD" = 1 ] && gh release view "v$CUR" --repo "$REPO" > /dev/null 2>&1; then
  SHIPPED=1
fi
FIRST=0
if [ -z "$(git tag)" ]; then
  FIRST=1            # no tags yet: the current version ships as-is
  NEXT="$CUR"
elif [ "$TAG_ON_HEAD" = 1 ] && [ "$SHIPPED" = 0 ]; then
  NEXT="$CUR"; RESUME=1
else
  NEXT="$(MODE="$MODE" CUR="$CUR" python3 -c 'import os
c = os.environ["CUR"].split(".")
i = {"patch": 2, "minor": 1, "major": 0}[os.environ["MODE"]]
c[i] = str(int(c[i]) + 1)
for j in range(i + 1, 3): c[j] = "0"
print(".".join(c))')"
fi
TAG="v$NEXT"
PREV_TAG="$(git tag --sort=-v:refname | grep -v "^$TAG$" | head -1 || true)"

LOG_DIR="$HOME/Library/Logs/com.faraz.superpaint"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/release-$TAG.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "✗ release $TAG failed (line $LINENO) — fix the cause and re-run; finished stages skip themselves"' ERR

say() { echo "▸ $*"; }
die() { echo "✗ $*" >&2; exit 1; }

say "release $CUR → $TAG ($MODE)$([ "$DRY_RUN" = 1 ] && echo ', DRY RUN')$([ "$FIRST" = 1 ] && echo ', first release — version ships as-is') — log: $LOG"

# ---- 1. guards -------------------------------------------------------------

say "guards"
for tool in gh python3 shasum; do
  command -v "$tool" > /dev/null || die "$tool not on PATH"
done
[ "$(git branch --show-current)" = "main" ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
git fetch origin --quiet
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main out of sync with origin"
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  [ "$(git rev-parse "refs/tags/$TAG")" = "$(git rev-parse HEAD)" ] \
    || die "tag $TAG already exists and points elsewhere"
  say "tag $TAG already on HEAD (resuming)"
fi

# ---- 2. bump ---------------------------------------------------------------

say "bump $CUR → $NEXT"
if [ "$DRY_RUN" = 0 ] && [ "$NEXT" != "$CUR" ]; then
  if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" | grep -q "^$NEXT$"; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" "$PLIST"
    # CFBundleVersion just has to change every release — wall-clock does that
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$PLIST"
  fi
fi

# ---- 3. build + verify -----------------------------------------------------

# Artifact reuse is resume-only: on a resume the source is exactly the tagged
# state, so present artifacts are the right bytes. A fresh version always
# builds — otherwise a `dry` run's leftover artifacts would let a later
# release of the same version ship stale bytes with newer commits inside.
if [ -f "$TARGZ" ] && { [ "$RESUME" = 1 ] || [ "$NEXT" = "$CUR" ]; }; then
  say "build — artifact for $NEXT already present, skipping the build"
else
  if [ "$DRY_RUN" = 1 ]; then
    say "DRY RUN build — building the real next version with the version overridden in the bundle only"
  fi
  ./build.sh
  if [ "$DRY_RUN" = 1 ]; then
    # dry: stamp the NEXT version into the bundle's copy only — the repo's
    # Info.plist stays untouched, so the tree stays clean
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" Superpaint.app/Contents/Info.plist
  fi
  say "packaging"
  mkdir -p build
  tar -czf "$TARGZ" Superpaint.app
fi

say "verify"
[ -f "$TARGZ" ] || die "no tarball at $TARGZ"
tar -tzf "$TARGZ" | grep -q "^Superpaint.app/Contents/MacOS/Superpaint$" \
  || die "tarball does not root at Superpaint.app with the binary inside"
TARGZ_SHA="$(shasum -a 256 "$TARGZ" | cut -d' ' -f1)"
say "verified — tar.gz sha256 $TARGZ_SHA"

# ---- release notes (custom NOTES=path override, else auto-generated) ------

if [ -n "${NOTES:-}" ] && [ ! -f "$NOTES" ]; then
  die "NOTES=$NOTES does not exist"
fi
NOTESFILE="$(mktemp)"
trap 'rm -f "$NOTESFILE" 2>/dev/null' EXIT
if [ -n "${NOTES:-}" ]; then
  cp "$NOTES" "$NOTESFILE"
  say "notes: custom ($NOTES)"
else
  {
    echo "## Changes"
    echo
    git log "${PREV_TAG:-$TAG}"..HEAD --format='- %s' | grep -v '^- v[0-9]' || echo "- initial release"
  } > "$NOTESFILE"
  say "notes: auto-generated (commits since ${PREV_TAG:-the first tag})"
fi

if [ "$DRY_RUN" = 1 ]; then
  say "DRY RUN — everything above is real; a full run would now publish:"
  say "  commit v$NEXT + tag $TAG, gh release v$NEXT (1 asset)"
  say "  notes: $(head -1 "$NOTESFILE")"
  say "  install path: the live curl one-liner must serve $TAG's bytes"
  say "DRY RUN complete — artifact left in $TARGZ for inspection"
  exit 0
fi

# ---- 4. publish the repo ---------------------------------------------------

if [ -n "$(git status --porcelain)" ]; then
  git add "$PLIST"
  git commit -m "v$NEXT"
  say "committed v$NEXT"
fi
if ! git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  git tag "$TAG"
  say "tagged $TAG"
fi
git push origin main "$TAG"
say "pushed main + $TAG"

# ---- 5. gh release ---------------------------------------------------------

if gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1; then
  gh release upload "$TAG" "$TARGZ" --repo "$REPO" --clobber
  say "release $TAG updated (asset re-uploaded)"
else
  gh release create "$TAG" "$TARGZ" \
    --repo "$REPO" --title "Superpaint $TAG" --notes-file "$NOTESFILE"
  say "release $TAG created"
fi

# ---- 6. install path --------------------------------------------------------

# The site's install story is one versionless curl one-liner: install.sh
# downloads releases/latest/download/Superpaint.app.tar.gz, so a release has
# nothing to edit or deploy — the site's own sessions own its deploys. This
# gate proves the path end to end: the live script must carry the
# always-latest URL, and that URL must return exactly this release's bytes.

say "install path check"
INSTALL_OK=0
for _ in 1 2 3 4 5 6; do
  SCRIPT="$(curl -fsL "$SITE_URL/install.sh" 2>/dev/null || true)"
  URL="$(printf '%s' "$SCRIPT" | grep -o 'https://[^"]*releases/latest/download/Superpaint\.app\.tar\.gz' | head -1 || true)"
  if [ -n "$URL" ]; then
    GOT_SHA="$(curl -fsL "$URL" 2>/dev/null | shasum -a 256 | cut -d' ' -f1 || true)"
    if [ "$GOT_SHA" = "$TARGZ_SHA" ]; then INSTALL_OK=1; break; fi
  fi
  sleep 10
done
[ "$INSTALL_OK" = 1 ] || die "the curl install path doesn't serve $TAG's bytes — check $SITE_URL/install.sh"
say "curl install serves $TAG"

# ---- 7. receipt ------------------------------------------------------------

NOTES_COUNT="$(grep -c '^- ' "$NOTESFILE" 2>/dev/null || echo 0)"
say "shipped $TAG:"
say "  release  https://github.com/$REPO/releases/tag/$TAG"
say "  install  $SITE_URL/install.sh (verified: serves $TAG's bytes)"
if [ -n "${NOTES:-}" ]; then
  say "  notes    custom ($NOTES)"
else
  say "  notes    $NOTES_COUNT changes since ${PREV_TAG:-the first tag}"
fi
