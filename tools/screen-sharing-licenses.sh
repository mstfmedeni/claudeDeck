#!/bin/sh
# Writes Support/SCREEN_SHARING_LICENSES.txt: the license texts of everything the iOS app's
# screen tab ships (open-screen-sharing, its Go modules, its Swift packages). Run after every
# bump of the Vendor/open-screen-sharing submodule (and after an iOS build, which fetches the
# Swift packages into build/xcode-ios-device/SourcePackages).
set -eu
cd "$(dirname "$0")/.."

OUT=Support/SCREEN_SHARING_LICENSES.txt
VENDOR=Vendor/open-screen-sharing
PACKAGES=build/xcode-ios-device/SourcePackages/checkouts
GO="${GO:-/usr/local/go/bin/go}"

[ -d "$VENDOR/libsharing" ] || { echo "❌ $VENDOR missing (git submodule update --init)" >&2; exit 1; }
[ -d "$PACKAGES" ] || { echo "❌ $PACKAGES missing: build the iOS app once first" >&2; exit 1; }

section() { # title, license file
  printf '\n================================================================\n%s\n================================================================\n\n' "$1"
  cat "$2"
  printf '\n'
}

{
  echo "The Mac Screen tab of ClaudeDeck for iPhone and iPad is built on open-screen-sharing"
  echo "(GPL-3.0, https://github.com/nekohasekai/open-screen-sharing; this build uses the fork"
  echo "https://github.com/mstfmedeni/open-screen-sharing, branch claudedeck) and the software below."
  echo "The full GNU General Public License v3 is in GPL-3.0.txt next to this file."

  section "open-screen-sharing — https://github.com/nekohasekai/open-screen-sharing" "$VENDOR/LICENSE"

  # Go modules linked into Libsharing (the standard library is under Go's BSD license).
  (cd "$VENDOR" && "$GO" list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Version}} {{.Dir}}{{end}}{{end}}' ./libsharing) \
    | sort -u | while read -r path version dir; do
      [ -n "$dir" ] || continue
      file=$(ls "$dir" | grep -i -m1 -E '^(license|licence|copying)' || true)
      [ -n "$file" ] && section "$path $version" "$dir/$file"
    done
  section "Go standard library — https://go.dev" "$("$GO" env GOROOT)/LICENSE"

  # Swift packages compiled into ScreenSharingKit.
  for pkg in GRDB.swift swift-perception swift-atomics swift-issue-reporting; do
    file=$(ls "$PACKAGES/$pkg" | grep -i -m1 -E '^(license|licence)' || true)
    [ -n "$file" ] && section "$pkg" "$PACKAGES/$pkg/$file"
  done
} > "$OUT"

echo "✅ $OUT ($(grep -c '^================================================================$' "$OUT" | awk '{print $1/2}') components)"
