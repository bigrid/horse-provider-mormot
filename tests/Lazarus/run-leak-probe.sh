#!/usr/bin/env bash
# ===========================================================================
#  run-leak-probe.sh - compile AND RUN HorseMormotLeakProbe with Free Pascal
#  (Linux x86_64 / WSL). Unlike build-fpc.sh (a compile-only gate) this one
#  executes the binary so you get the heap-delta table (and, with --heaptrc,
#  the heaptrc exit dump).
#
#  Usage:
#    run-leak-probe.sh [--heaptrc] [-- warmup measure chunk]
#      --heaptrc    add -gl -gh: heaptrc replaces the memory manager and prints
#                   an unfreed-blocks report at exit (run (b), the cross-check).
#      warmup measure chunk  passed through to the probe (defaults in the .lpr).
#
#  Environment (same contract as build-fpc.sh):
#    FPC PROVIDER_DIR HORSE_DIR MORMOT2_DIR FPC_UNITS OUT
#
#  WSL2 NETWORKING WARNING: mirrored networking injects RSTs on loopback and
#  fakes ~50% reply loss, which makes the probe's /echo assertion throw. Run
#  under NAT networking (.wslconfig: networkingMode=NAT), or run on Windows
#  via Lazarus. (reference: WSL2 mirrored-networking RST note.)
# ===========================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)

HEAPTRC=0
LEAKCTL=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --heaptrc) HEAPTRC=1; shift ;;
    --leak)    LEAKCTL=1; shift ;;   # positive control: build -dPROBE_LEAK (MUST show growth)
    --) shift; ARGS=("$@"); break ;;
    *)  ARGS+=("$1"); shift ;;
  esac
done

# This script lives at <provider>/tests/Lazarus/, so the provider repo root is
# two levels up and the repos parent one more - same derivation as build-fpc.sh.
SCRIPT_ROOT=$(cd "$HERE/../.." && pwd)
PROVIDER_DIR=${PROVIDER_DIR:-$SCRIPT_ROOT}
REPOS=$(dirname "$SCRIPT_ROOT")
HORSE_DIR=${HORSE_DIR:-$REPOS/horse}
MORMOT2_DIR=${MORMOT2_DIR:-$REPOS/mORMot2}
FPC=${FPC:-/usr/bin/fpc}
OUT=${OUT:-$(mktemp -d /tmp/mormot-leak.XXXXXX)}
STATIC=$MORMOT2_DIR/static/x86_64-linux

PROGRAM="$PROVIDER_DIR/tests/Lazarus/HorseMormotLeakProbe.lpr"
[ -f "$PROGRAM" ] || PROGRAM="$HERE/HorseMormotLeakProbe.lpr"

fail() { echo "VOID - $1"; exit 2; }
[ -x "$FPC" ] || fail "no compiler at $FPC (set FPC=...)"
[ -f "$PROGRAM" ] || fail "no probe .lpr at $PROGRAM"
[ -f "$HORSE_DIR/src/Horse.pas" ] || fail "no Horse at $HORSE_DIR"
[ -d "$MORMOT2_DIR/src/net" ] || fail "no mORMot2 at $MORMOT2_DIR"
[ -f "$STATIC/libdeflatepas.a" ] || fail "no mORMot2 static libs at $STATIC"

FPC_VER=$("$FPC" -iV); FPC_TARGET="$("$FPC" -iTP)-$("$FPC" -iTO)"
if [ -z "${FPC_UNITS:-}" ]; then
  for c in "$(dirname "$(dirname "$FPC")")/lib/fpc/$FPC_VER/units/$FPC_TARGET" \
           "/usr/lib/x86_64-linux-gnu/fpc/$FPC_VER/units/$FPC_TARGET" \
           "/usr/lib/fpc/$FPC_VER/units/$FPC_TARGET"; do
    [ -f "$c/rtl/system.ppu" ] && FPC_UNITS=$c && break
  done
fi
[ -n "${FPC_UNITS:-}" ] && [ -f "$FPC_UNITS/rtl/system.ppu" ] || \
  fail "no RTL for fpc $FPC_VER ($FPC_TARGET) - set FPC_UNITS"

UNIT_PATHS=("-Fu$FPC_UNITS/*" "-Fu$HORSE_DIR/src" "-Fu$PROVIDER_DIR/src")
for d in "$MORMOT2_DIR"/src/*/; do UNIT_PATHS+=("-Fu${d%/}"); done
LIB_PATHS=("-Fl$STATIC")
for d in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do [ -d "$d" ] && LIB_PATHS+=("-Fl$d"); done
command -v gcc >/dev/null 2>&1 && LIB_PATHS+=("-Fl$(dirname "$(gcc -print-libgcc-file-name)")")

DBG=()
[ "$HEAPTRC" -eq 1 ] && DBG=(-gl -gh)
LEAKDEF=""
[ "$LEAKCTL" -eq 1 ] && LEAKDEF="-dPROBE_LEAK"

mkdir -p "$OUT"
echo "=== building HorseMormotLeakProbe (heaptrc=$HEAPTRC leak-control=$LEAKCTL) ==="
echo "fpc=$FPC $FPC_VER  out=$OUT"
"$FPC" -n -B -Mdelphi -dHORSE_PROVIDER_MORMOT $LEAKDEF -vew "${DBG[@]}" \
  "${UNIT_PATHS[@]}" \
  "-Fi$MORMOT2_DIR/src" "-Fi$MORMOT2_DIR/src/core" \
  "${LIB_PATHS[@]}" \
  "-FU$OUT" "-FE$OUT" \
  "$PROGRAM" 2>&1 | tee "$OUT/build.log"
RC=${PIPESTATUS[0]}
[ "$RC" -eq 0 ] || { echo "BUILD FAILED (fpc $RC) - read the FIRST error in $OUT/build.log"; exit "$RC"; }

BIN="$OUT/$(basename "${PROGRAM%.lpr}")"
echo "=== running $BIN ${ARGS[*]:-} ==="
"$BIN" "${ARGS[@]:-}"
