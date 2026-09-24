#!/bin/zsh
# Builds, signs and packages a release of Swift Shift Plus and adds it to the fork's own Sparkle
# feed (appcast-plus.xml). Nothing is published unless you pass --publish.
#
#   scripts/release-fork.sh             build, sign, zip, and add the release to appcast-plus.xml
#   scripts/release-fork.sh --publish   ...then create the GitHub release and push the feed
#                                       (from `main`: GitHub Pages serves the feed from there)
#
# One-time setup:
#   - a code-signing certificate named "SwiftShift Local" in the login keychain (Keychain Access ›
#     Certificate Assistant › Create a Certificate…, type "Code Signing"). Signing every build with
#     the same certificate keeps macOS's Accessibility permission across updates, unlike ad-hoc
#     signing, whose identity changes with every build. Override the name with SIGN_IDENTITY.
#   - a Sparkle EdDSA key: run Sparkle's `generate_keys` once. The private half stays in the login
#     keychain; the public half is SUPublicEDKey in Swift-Shift-Info.plist. Back the private half up
#     (`generate_keys -x file`): without it, installed copies can never be updated.
#
# There is no notarization (that needs a paid Apple Developer account), so a first install still has
# to be opened with right-click › Open, or `xattr -dr com.apple.quarantine`. Updates through Sparkle
# are not affected.
set -euo pipefail

APP_NAME="Swift Shift Plus"
ZIP_BASENAME="SwiftShiftPlus"
REPO="Liotou/SwiftShift"
APPCAST="appcast-plus.xml"
IDENTITY_NAME="${SIGN_IDENTITY:-SwiftShift Local}"

ROOT="${0:A:h:h}"
cd "$ROOT"

publish=false
[[ "${1:-}" == "--publish" ]] && publish=true

if $publish && [[ "$(git branch --show-current)" != "main" ]]; then
  echo "Error: --publish must be run from 'main' (GitHub Pages serves $APPCAST from there)." >&2
  exit 1
fi

# --- Sparkle's command-line tools ---------------------------------------------------------------

find_sparkle_bin() {
  local candidate
  for candidate in "${SPARKLE_BIN:-}" \
                   "$ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin" \
                   ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin(N); do
    [[ -n "$candidate" && -x "$candidate/sign_update" ]] && { echo "$candidate"; return 0; }
  done
  return 1
}

sparkle_bin="$(find_sparkle_bin || true)"
if [[ -z "$sparkle_bin" ]]; then
  echo "→ Fetching Sparkle's tools (resolving Swift packages)…"
  xcodebuild -resolvePackageDependencies -scheme "Swift Shift" -derivedDataPath "$ROOT/build/DerivedData" > /dev/null
  sparkle_bin="$(find_sparkle_bin || true)"
fi
[[ -n "$sparkle_bin" ]] || { echo "Error: could not find Sparkle's sign_update. Set SPARKLE_BIN." >&2; exit 1; }

# --- Signing identity ---------------------------------------------------------------------------

# `find-identity` without -v also lists certificates macOS doesn't trust, which is what a
# self-signed one is; codesign signs with it regardless.
identity="$(security find-identity -p codesigning | awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }')"
[[ -n "$identity" ]] || { echo "Error: no code-signing identity named '$IDENTITY_NAME' in your keychain." >&2; exit 1; }

# --- Build --------------------------------------------------------------------------------------

echo "→ Building…"
xcodebuild -scheme "Swift Shift" -configuration Release -destination "platform=macOS" build \
  SYMROOT="$ROOT/build" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO > /dev/null

built="$ROOT/build/Release/$APP_NAME.app"
[[ -d "$built" ]] || { echo "Error: $built was not produced." >&2; exit 1; }

plist="$built/Contents/Info.plist"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
min_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"

# --- Sign and package ---------------------------------------------------------------------------

# Copy without extended attributes first: a build inside an iCloud-synced folder (Desktop) carries
# Finder metadata that codesign refuses to sign over.
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr --noqtn "$built" "$stage/$APP_NAME.app"

echo "→ Signing with '$IDENTITY_NAME'…"
codesign --force --deep --sign "$identity" "$stage/$APP_NAME.app"
codesign --verify --deep --strict "$stage/$APP_NAME.app"

release_dir="$ROOT/build/release"
mkdir -p "$release_dir"
zip="$release_dir/$ZIP_BASENAME-$short_version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$stage/$APP_NAME.app" "$zip"

# --- Sparkle feed -------------------------------------------------------------------------------

echo "→ Signing the update…"
signature_attrs="$("$sparkle_bin/sign_update" "$zip")"   # sparkle:edSignature="…" length="…"

url="https://github.com/$REPO/releases/download/v$short_version/$(basename "$zip")"
pub_date="$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"

python3 - "$APPCAST" "$short_version" "$build_version" "$min_system" "$url" "$pub_date" "$signature_attrs" <<'PY'
import sys, pathlib
appcast, short_version, build_version, min_system, url, pub_date, attrs = sys.argv[1:]
path = pathlib.Path(appcast)
xml = path.read_text()
if f"<sparkle:version>{build_version}</sparkle:version>" in xml:
    sys.exit(f"Error: {appcast} already has version {build_version}. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION first.")
item = f"""        <item>
            <title>{short_version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build_version}</sparkle:version>
            <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
            <enclosure url="{url}" type="application/octet-stream" {attrs}/>
        </item>
"""
marker = "</title>\n"
head, sep, tail = xml.partition(marker)
path.write_text(head + sep + item + tail)
PY
xmllint --noout "$APPCAST"

echo
echo "✓ $APP_NAME $short_version (build $build_version)"
echo "  package: $zip"
echo "  feed:    $APPCAST (new entry added)"

# --- Publish ------------------------------------------------------------------------------------

if $publish; then
  echo "→ Publishing…"
  gh release create "v$short_version" "$zip" --repo "$REPO" --title "$APP_NAME $short_version" \
    --notes "$APP_NAME $short_version. Not notarized: on first install, right-click › Open, or run \`xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\"\`."
  git add "$APPCAST"
  git commit -m "Release $short_version"
  git push
  echo "✓ Published. Installed copies will see it through the feed once GitHub Pages redeploys (a minute or two)."
else
  echo
  echo "Not published. To publish: switch to main, commit, and run  scripts/release-fork.sh --publish"
  echo "(or upload the package to a GitHub release yourself, and commit $APPCAST)."
fi
