#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# make-pl-bundle.sh - turn the FPGA build into a signed RAUC "PL bundle"
# (doc/network_update.md, phase 1).
#
#   ./linux/make-pl-bundle.sh              -> output/pl-<version>.raucb
#   ./linux/make-pl-bundle.sh --tree DIR   -> only the design tree, in DIR
#                                             (build-linux.sh stages the first
#                                             good design into the image this way)
#
# The bundle holds one artifact for the board's "pl" repository (type trees):
#
#   design/zynq-mini-pl.bit.bin   bitstream as the FPGA manager wants it (bit2bin.py)
#   design/zynq-mini-pl.dtbo      linux/pl/zynq-mini-pl.dtso (zynq-mini-pl-hvhdl.dtso for a
#                                 PL_ETH=hvhdl build), compiled with dtc -@
#   design/manifest.json          version, build_id, regmap, git, date, sha256
#
# fpgad checks build_id and regmap against the loaded design's BUILD_ID and
# REGMAP registers (src/hdl/axi_regs.vhd).
#
# Inputs : output/arm_fpga_zynq_mini.bit + .build_id   (./build.sh)
# Tools  : Buildroot's host dtc and rauc   (<build dir>/buildroot/output/host/bin)
# Keys   : <build dir>/rauc-keys/signing.{cert,key}.pem   (build-linux.sh makes them;
#          never in this public repository)
# Env    : LINUX_BUILD_DIR (default <repo>/../zynqmini-linux)
#-----------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LINUX_BUILD_DIR:=$(dirname "$REPO")/zynqmini-linux}"
HOST="$LINUX_BUILD_DIR/buildroot/output/host/bin"
KEYS="$LINUX_BUILD_DIR/rauc-keys"
PROJECT=arm_fpga_zynq_mini
BIT="$REPO/output/$PROJECT.bit"
BUILD_ID_FILE="$REPO/output/$PROJECT.build_id"
# the overlay that belongs to the build's PL Ethernet variant (scripts/config.tcl,
# recorded by build.tcl): gem1 -> eth1 in the overlay, hvhdl -> the PL MAC, no gem1
PL_ETH=$(cat "$REPO/output/$PROJECT.pl_eth" 2>/dev/null || echo gem1)
case "$PL_ETH" in
    hvhdl) DEFAULT_DTSO="$REPO/linux/pl/zynq-mini-pl-hvhdl.dtso" ;;
    *)     DEFAULT_DTSO="$REPO/linux/pl/zynq-mini-pl.dtso" ;;
esac
DTSO="${PL_DTSO:-$DEFAULT_DTSO}"   # PL_DTSO: another overlay (tests)
COMPATIBLE=zynq-mini

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

tree_only=
if [ "${1:-}" = --tree ]; then
    [ -n "${2:-}" ] || die "usage: $0 [--tree DIR]"
    tree_only=$2
fi

[ -f "$BIT" ] || die "no $BIT - run ./build.sh"
[ -f "$BUILD_ID_FILE" ] || die "no $BUILD_ID_FILE - rebuild the FPGA (./build.sh) to get one"
[ -x "$HOST/dtc" ] || die "no $HOST/dtc - run linux/build-linux.sh once"

build_id=$(tr -d ' \r\n' < "$BUILD_ID_FILE")
regmap=$(sed -n 's/.*constant REGMAP_VERSION *: *integer *:= *\([0-9]*\);.*/\1/p' "$REPO/src/hdl/axi_regs.vhd")
[ -n "$regmap" ] || die "REGMAP_VERSION not found in src/hdl/axi_regs.vhd"
git=$(git -C "$REPO" describe --always --dirty --abbrev=7 2>/dev/null || echo unknown)
date=$(date -u -d "@$build_id" +%Y-%m-%dT%H:%M:%SZ)
version="$(date -u -d "@$build_id" +%Y%m%d.%H%M%S)-$git"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
d="$work/design"
mkdir -p "$d"
python3 "$REPO/linux/bit2bin.py" "$BIT" "$d/zynq-mini-pl.bit.bin" >/dev/null
"$HOST/dtc" -@ -q -I dts -O dtb -o "$d/zynq-mini-pl.dtbo" "$DTSO"
sha_bin=$(sha256sum "$d/zynq-mini-pl.bit.bin" | cut -d' ' -f1)
sha_dtbo=$(sha256sum "$d/zynq-mini-pl.dtbo" | cut -d' ' -f1)
cat > "$d/manifest.json" <<EOF
{"version":"$version","build_id":$build_id,"regmap":$regmap,"git":"$git","date":"$date",
 "sha256":{"zynq-mini-pl.bit.bin":"$sha_bin","zynq-mini-pl.dtbo":"$sha_dtbo"}}
EOF

if [ -n "$tree_only" ]; then
    mkdir -p "$tree_only"
    cp "$d"/* "$tree_only"/
    echo "PL design $version (build_id $build_id, regmap $regmap) -> $tree_only"
    exit 0
fi

[ -x "$HOST/rauc" ] || die "no $HOST/rauc - run linux/build-linux.sh (it enables host-rauc)"
[ -f "$KEYS/signing.cert.pem" ] && [ -f "$KEYS/signing.key.pem" ] \
    || die "no signing key in $KEYS - run linux/build-linux.sh (it creates the development keys)"

b="$work/bundle"
mkdir -p "$b"
# the artifact *is* the design directory: pack its contents, not a design/ folder
tar -C "$d" --owner=0 --group=0 --numeric-owner -cf "$b/design.tar" .
cat > "$b/manifest.raucm" <<EOF
[update]
compatible=$COMPATIBLE
version=$version
description=FPGA design $git, built $date

[bundle]
format=verity

[image.pl/design]
filename=design.tar
convert=tar-extract
EOF

out="$REPO/output/pl-$version.raucb"
rm -f "$out"
# host rauc runs mksquashfs/unsquashfs from Buildroot's host dir
PATH="$HOST:$PATH" "$HOST/rauc" bundle --cert="$KEYS/signing.cert.pem" --key="$KEYS/signing.key.pem" \
    "$b" "$out" >/dev/null
ln -sfn "$(basename "$out")" "$REPO/output/pl-latest.raucb"
echo "PL bundle $version (build_id $build_id, regmap $regmap, PL Ethernet $PL_ETH) -> $out"
