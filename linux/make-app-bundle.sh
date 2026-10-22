#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# make-app-bundle.sh - our software as a signed RAUC "app bundle"
# (doc/network_update.md, phase 2).
#
#   ./linux/make-app-bundle.sh              rebuild fpgad + fpga-web in Buildroot,
#                                           then -> output/apps-<version>.raucb
#   ./linux/make-app-bundle.sh --no-build   bundle what Buildroot already built
#
# The bundle holds one artifact for the board's "apps" repository (type trees):
#
#   bin/fpgad bin/fpgactl bin/fpga-web bin/oled-status
#   lib/libcivetweb.so.1          civetweb with WebSocket support (fpga-web needs it)
#   manifest.json                 version, git, date, regmaps (register-map versions
#                                 this fpgad supports - appctl refuses an app set that
#                                 can't drive the FPGA design that will run)
#
# On the board, RAUC verifies and installs it and appctl trial-runs it: services
# restarted on the new set, health-checked, kept or rolled back. No reboot.
#
# Keys / tools / env: as linux/make-pl-bundle.sh.
#-----------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LINUX_BUILD_DIR:=$(dirname "$REPO")/zynqmini-linux}"
BR="$LINUX_BUILD_DIR/buildroot"
HOST="$BR/output/host/bin"
TGT="$BR/output/target"
KEYS="$LINUX_BUILD_DIR/rauc-keys"
COMPATIBLE=zynq-mini
CLEAN_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

if [ "${1:-}" != --no-build ]; then
    echo "rebuilding fpgad + fpga-web in Buildroot ..."
    env -i HOME="$HOME" PATH="$CLEAN_PATH" TERM="${TERM:-xterm}" \
        bash -c "cd '$BR' && make fpgad-rebuild fpga-web-rebuild >/dev/null 2>&1" \
        || die "Buildroot rebuild failed (run it by hand: cd $BR && make fpgad-rebuild fpga-web-rebuild)"
fi

[ -x "$HOST/rauc" ] || die "no $HOST/rauc - run linux/build-linux.sh"
[ -f "$KEYS/signing.cert.pem" ] && [ -f "$KEYS/signing.key.pem" ] \
    || die "no signing key in $KEYS - run linux/build-linux.sh"
for b in fpgad fpgactl fpga-web oled-status; do
    [ -f "$TGT/usr/lib/zynq-mini/bin/$b" ] || die "no $TGT/usr/lib/zynq-mini/bin/$b - rebuild the image (build-linux.sh)"
done
civet=$(readlink -f "$TGT/usr/lib/libcivetweb.so.1")
[ -f "$civet" ] || die "no libcivetweb in $TGT/usr/lib"

regmaps=$(sed -n 's/.*REGMAPS\[\] *= *{ *\([0-9, ]*\) *}.*/\1/p' "$REPO/linux/fpgad/fpgad.c" | tr -d ' ')
[ -n "$regmaps" ] || die "REGMAPS not found in linux/fpgad/fpgad.c"
git=$(git -C "$REPO" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)
now=$(date -u +%s)
date=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)
version="$(date -u -d "@$now" +%Y%m%d.%H%M%S)-$git"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
t="$work/tree"
mkdir -p "$t/bin" "$t/lib"
for b in fpgad fpgactl fpga-web oled-status; do
    install -m 0755 "$TGT/usr/lib/zynq-mini/bin/$b" "$t/bin/$b"
done
install -m 0755 "$civet" "$t/lib/libcivetweb.so.1"
cat > "$t/manifest.json" <<EOF
{"version":"$version","git":"$git","date":"$date","regmaps":[$regmaps]}
EOF

b="$work/bundle"
mkdir -p "$b"
tar -C "$t" --owner=0 --group=0 --numeric-owner -cf "$b/apps.tar" .
cat > "$b/manifest.raucm" <<EOF
[update]
compatible=$COMPATIBLE
version=$version
description=apps $git, built $date

[bundle]
format=verity

[image.apps/zynq-mini-apps]
filename=apps.tar
convert=tar-extract
EOF

out="$REPO/output/apps-$version.raucb"
PATH="$HOST:$PATH" "$HOST/rauc" bundle --cert="$KEYS/signing.cert.pem" --key="$KEYS/signing.key.pem" \
    "$b" "$out" >/dev/null 2>&1 || die "rauc bundle failed"
ln -sfn "$(basename "$out")" "$REPO/output/apps-latest.raucb"
echo "app bundle $version (regmaps [$regmaps]) -> $out"
