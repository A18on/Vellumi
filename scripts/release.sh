#!/usr/bin/env bash
#
# Reproducible release build for Molten.
#
#   script/release.sh            # build Release Universal .app → DMG + .app.zip in dist/
#   script/release.sh 0.3.0      # same, overriding the version label on the artifacts
#
# Produces an ad-hoc-signed, UN-NOTARIZED build (no paid Apple Developer account yet). First-run
# users must right-click → Open, or run:  xattr -dr com.apple.quarantine /Applications/Molten.app
#
# Notarization is intentionally left as a gated, commented step at the bottom: once a Developer ID
# certificate + notarytool credentials exist, uncomment it — no other change is needed (the app
# already builds with hardened runtime + sandbox entitlements).
set -euo pipefail

APP_NAME="Vellumi"
SCHEME="Vellumi"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/Vellumi.xcodeproj"
DERIVED="$ROOT_DIR/.build/release"
DIST="$ROOT_DIR/dist"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"

# Version: argument wins, else read MARKETING_VERSION from project.yml.
VERSION="${1:-$(grep -m1 'MARKETING_VERSION:' "$ROOT_DIR/project.yml" | sed 's/.*MARKETING_VERSION: *//')}"
echo "==> Releasing $APP_NAME $VERSION"

cd "$ROOT_DIR"

# The editor bundle is gitignored and Editor/build.mjs wipes dist/ before
# rebuilding. project.yml references Resources/dist as a FOLDER, so an empty
# or half-written dist copies silently and xcodebuild still returns 0 — the
# result is a DMG whose every document is a blank editor. Build it here and
# refuse to continue unless the artifacts exist.
echo "==> Building editor bundle"
"$ROOT_DIR/scripts/build-editor.sh"
for artifact in "$ROOT_DIR/Resources/dist/editor.js" "$ROOT_DIR/Resources/dist/index.html"; do
  test -s "$artifact" || { echo "ERROR: missing or empty $artifact" >&2; exit 1; }
done

xcodegen generate >/dev/null

echo "==> Building Release (Universal: arm64 + x86_64)"
rm -rf "$DERIVED"
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  build

echo "==> Verifying artifact"
test -d "$APP" || { echo "build product missing: $APP" >&2; exit 1; }
lipo -archs "$APP/Contents/MacOS/$APP_NAME"

echo "==> Re-signing embedded Sparkle with the app's (ad-hoc) identity"
# The SPM artifact ships Developer-ID-signed; the app is ad-hoc (no Team ID).
# dyld's library validation refuses to load a framework whose Team ID differs
# from the main executable's — v0.4.0 crashed AT LAUNCH on every other Mac.
# Uniform ad-hoc signatures (bottom-up, entitlements preserved) fix it.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  for nested in     "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"     "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"     "$SPARKLE_FW/Versions/B/Autoupdate"     "$SPARKLE_FW/Versions/B/Updater.app"; do
    if [ -e "$nested" ]; then
      codesign --force --sign - --preserve-metadata=entitlements "$nested"
    fi
  done
  codesign --force --sign - "$SPARKLE_FW"
fi
# Sign the app from the SOURCE entitlements rather than preserving whatever
# Xcode injected: --preserve-metadata=entitlements kept the debug-only
# com.apple.security.get-task-allow (any process of this user could attach a
# debugger to an app holding the user's security-scoped folder bookmarks) and,
# because an explicit preserve list replaces the defaults, dropped the hardened
# runtime flag. Both are required for notarization later anyway.
codesign --force --sign - --options runtime \
  --entitlements "$ROOT_DIR/$APP_NAME.entitlements" "$APP"

codesign --verify --deep --strict "$APP" && echo "code signature OK (uniform ad-hoc)"

# Belt-and-braces assertions — each of these has shipped broken at least once.
if codesign -dvv "$SPARKLE_FW" 2>&1 | grep -q "^TeamIdentifier=[^n]"; then
  echo "ERROR: Sparkle framework still carries a Team ID" >&2
  exit 1
fi
APP_FLAGS="$(codesign -dvv "$APP" 2>&1 | grep -m1 '^CodeDirectory' || true)"
if ! printf '%s' "$APP_FLAGS" | grep -q "runtime"; then
  echo "ERROR: app is missing the hardened runtime flag" >&2
  echo "       codesign reported: $APP_FLAGS" >&2
  exit 1
fi
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "ERROR: get-task-allow leaked into the release build" >&2
  exit 1
fi
# Sparkle's sandboxed installer needs all three mach services (-spki/-spks/
# -spkp). A missing one does not fail the build or the launch — it stalls the
# UPDATE, which is only discovered by a user who never gets the new version.
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
for tag in spki spks spkp; do
  printf '%s' "$SIGNED_ENTITLEMENTS" | grep -q -- "-$tag" \
    || { echo "ERROR: entitlements are missing the Sparkle mach service -$tag" >&2; exit 1; }
done

for artifact in editor.js index.html; do
  test -s "$APP/Contents/Resources/dist/$artifact" \
    || { echo "ERROR: $artifact missing from the built app bundle" >&2; exit 1; }
done

mkdir -p "$DIST"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
ZIP="$DIST/$APP_NAME-$VERSION.app.zip"

echo "==> Building DMG"
STAGE="$DERIVED/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> Building .app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- Notarization (gated: requires a Developer ID + notarytool credentials) -------------------
# Once available, store credentials once with:
#   xcrun notarytool store-credentials molten-notary --apple-id <id> --team-id <team> --password <app-specific-pw>
# then uncomment:
# echo "==> Notarizing"
# xcrun notarytool submit "$DMG" --keychain-profile molten-notary --wait
# xcrun stapler staple "$DMG"
# xcrun stapler staple "$APP"
# ----------------------------------------------------------------------------------------------

echo "==> Done:"
ls -lh "$DMG" "$ZIP" | awk '{print "    "$5"  "$9}'
# Version gate BEFORE regenerating the appcast — comparing afterwards would
# measure this build against the entry it just wrote for itself.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
PREVIOUS_MAX="$(grep -oE '<sparkle:version>[0-9]+' "$ROOT_DIR/appcast.xml" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)"
if [ -n "$PREVIOUS_MAX" ] && [ "$BUILD_NUMBER" -le "$PREVIOUS_MAX" ]; then
  echo "ERROR: CFBundleVersion $BUILD_NUMBER must exceed the newest appcast entry $PREVIOUS_MAX" >&2
  echo "       (bump CURRENT_PROJECT_VERSION in project.yml)" >&2
  exit 1
fi

# Sparkle: EdDSA-sign the update archives and regenerate appcast.xml at the
# repo root (served raw from GitHub; SUFeedURL points at master).
# Look inside THIS build's derived data first. The old global search under
# ~/Library/Developer/Xcode/DerivedData missed entirely on a clean machine (we
# build into a private .build/release) and could otherwise pick another
# project's Sparkle version; the appcast was then silently skipped and every
# installed user stopped receiving updates.
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -1)"
fi
if [ -n "$SPARKLE_BIN" ] && [ -x "$SPARKLE_BIN/generate_appcast" ]; then
  # Sparkle rejects two archives with the same version — feed it the zip only.
  APPCAST_STAGE="$(mktemp -d)"
  cp "$ZIP" "$APPCAST_STAGE/"
  "$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/SUDAcyber/Vellumi/releases/download/v$VERSION/" \
    -o "$ROOT_DIR/appcast.xml" "$APPCAST_STAGE" \
    && echo "==> appcast.xml regenerated (EdDSA-signed)"
  rm -rf "$APPCAST_STAGE"
else
  echo "ERROR: Sparkle tools not found; appcast would be stale and no installed" >&2
  echo "       user would ever receive this release. Refusing to continue." >&2
  exit 1
fi


echo "    (un-notarized: first run via right-click → Open, or xattr -dr com.apple.quarantine)"
