#!/bin/sh
# Builds TailscaleKit.xcframework (iOS device + simulator) for ClaudeDeckRemote's in-app Tailscale.
#
#   Vendor/TailscaleKit/build.sh          builds when missing or out of date
#   Vendor/TailscaleKit/build.sh --force  always rebuilds
#
# Source: Tailscale's libtailscale (BSD-3-Clause, git submodule at Vendor/libtailscale, pinned),
# plus the patches in Vendor/TailscaleKit/patches (applied to a copy; the submodule stays clean):
#   0001-advertise-tags.patch  tailscale_set_advertise_tags / Configuration.advertiseTags, so the
#                              node registers with an ACL tag (tsnet.Server.AdvertiseTags).
# Needs Go (https://go.dev/dl, or Homebrew) and Xcode. The Go part cross-compiles tsnet for iOS:
# the first build takes a few minutes, later ones use Go's build cache.
set -eu
cd "$(dirname "$0")/../.."

fail() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

OUT=Vendor/TailscaleKit/TailscaleKit.xcframework
STAMP=Vendor/TailscaleKit/.built-from
WORK=build/tailscalekit
SRC="$WORK/src"

git submodule update --init --quiet Vendor/libtailscale
[ -f Vendor/libtailscale/tailscale.go ] || fail "Vendor/libtailscale is empty (git submodule update --init Vendor/libtailscale)."

# What this build is made of: the submodule's commit and the patches.
WANT="$(git -C Vendor/libtailscale rev-parse HEAD) $(cat Vendor/TailscaleKit/patches/*.patch | shasum -a 256 | cut -d' ' -f1)"
if [ "${1:-}" != "--force" ] && [ -d "$OUT" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT" ]; then
  echo "TailscaleKit.xcframework is up to date."
  exit 0
fi

PATH="$PATH:/usr/local/go/bin:/opt/homebrew/bin"
command -v go >/dev/null 2>&1 || fail "Go is needed to build TailscaleKit (https://go.dev/dl or 'brew install go')."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

rm -rf "$WORK"
mkdir -p "$SRC"
git -C Vendor/libtailscale archive HEAD | tar -x -C "$SRC"
for patch in Vendor/TailscaleKit/patches/*.patch; do
  patch -s -p1 -d "$SRC" < "$patch" || fail "Patch $patch doesn't apply."
done

echo "▸ libtailscale (Go → iOS, iOS Simulator)…"
(cd "$SRC" && make c-archive-ios c-archive-ios-sim) > "$WORK/go.log" 2>&1 \
  || { tail -20 "$WORK/go.log" >&2; fail "libtailscale build failed (log: $WORK/go.log)."; }

# TailscaleKit's project says iOS 18.1; ClaudeDeckRemote supports 18.0.
for scheme in "TailscaleKit (iOS)|generic/platform=iOS" "TailscaleKit (Simulator)|generic/platform=iOS Simulator"; do
  echo "▸ ${scheme%%|*}…"
  xcodebuild build -project "$SRC/swift/TailscaleKit.xcodeproj" -scheme "${scheme%%|*}" -configuration Release \
    -destination "${scheme#*|}" -derivedDataPath "$WORK/dd" IPHONEOS_DEPLOYMENT_TARGET=18.0 CODE_SIGNING_ALLOWED=NO \
    > "$WORK/xcodebuild.log" 2>&1 \
    || { grep -E "error:" "$WORK/xcodebuild.log" | head -20 >&2; fail "TailscaleKit build failed (log: $WORK/xcodebuild.log)."; }
done

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -framework "$WORK/dd/Build/Products/Release-iphoneos/TailscaleKit.framework" \
  -framework "$WORK/dd/Build/Products/Release-iphonesimulator/TailscaleKit.framework" \
  -output "$OUT" > /dev/null
echo "$WANT" > "$STAMP"
echo "✅ $OUT"
