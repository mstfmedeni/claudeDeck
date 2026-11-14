#!/bin/sh
# Prints the license notices of everything TailscaleKit links (libtailscale and the Go modules
# compiled into it for iOS), for Support/THIRD_PARTY_LICENSES.txt. Run after build.sh (it uses
# build.sh's patched copy of the source); paste the output over that file's Tailscale part.
set -eu
cd "$(dirname "$0")/../../build/tailscalekit/src"
PATH="$PATH:/usr/local/go/bin:/opt/homebrew/bin"

GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go list -tags ios -deps -f '{{with .Module}}{{.Dir}}|{{.Path}}|{{.Version}}{{end}}' . \
  | sort -u -t'|' -k2,2 | while IFS='|' read -r dir path version; do
    license=$(ls "$dir" | grep -iE '^(LICENSE|LICENCE|COPYING)' | head -1)
    printf '================================================================\n'
    [ "$path" = "github.com/tailscale/libtailscale" ] && printf '%s (TailscaleKit)\n' "$path" || printf '%s %s\n' "$path" "$version"
    printf '================================================================\n\n'
    sed -e 's/[[:space:]]*$//' "$dir/$license"
    printf '\n'
done
