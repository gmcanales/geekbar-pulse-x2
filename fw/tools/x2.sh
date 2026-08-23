#!/usr/bin/env bash
# Talk to the Pulse X2 over SWD.
#
# reads — safe against stock firmware, no flashing involved:
#   ./tools/x2.sh linktest          sweep SWD speeds, check for corrupt reads
#   ./tools/x2.sh survey            full read battery, saved to a report file
#   ./tools/x2.sh gpio A|B|F        decode GPIO config (verifies the pinout)
#   ./tools/x2.sh flash-info        flash controller / protection / timing report
#   ./tools/x2.sh dump [file]       re-dump the 64K flash
#
# writes — scratch flash only, stock firmware keeps running:
#   ./tools/x2.sh flash-selftest    prove erase+program+verify on blank flash
#   ./tools/x2.sh flash <f> <addr>  write a .bin into the scratch region
#
# writes — replaces the stock firmware, needs CONFIRM=yes:
#   ./tools/x2.sh flash-app beacon|shell
#   ./tools/x2.sh restore [file]    put the stock dump back
#
# once our firmware is running:
#   ./tools/x2.sh beacon            read firmware state at 0x20000000
#   ./tools/x2.sh alive [ms]        confirm the loop runs; measure core clock
#   ./tools/x2.sh ping              shell smoke test
#   ./tools/x2.sh cmd N [a0] [a1]   send a shell command
#   ./tools/x2.sh raw "<tcl>"       arbitrary OpenOCD commands
#
# Rig: vape seated in the breakout, charger in the female side, actively
# charging (stock firmware drops into STOP when idle, which kills the debug
# port — our firmware never does, so this stops mattering once flashed).
# Probe GND / SWDIO->B5 / SWCLK->A5, held steady.
set -euo pipefail

cd "$(dirname "$0")/.."
CFG="-f tools/x2.cfg -f tools/x2.tcl -f tools/py32_flash.tcl -f tools/linktest.tcl"
TMP="${TMPDIR:-/tmp}/x2img.$$.tcl"
STOCK="../x2_flash_dump.bin"
STOCK_SHA="dca474276128d86739b3dc5c5951b7c0919d7dcd95fe6c62396e38050182fa99"
trap 'rm -f "$TMP"' EXIT

run() { openocd $CFG -c "init" "$@" -c "shutdown"; }

# Writing an image: convert to a Tcl word list (OpenOCD's Jim has no
# dependable binary file I/O), source it, then let the driver page it in.
write_image() {
  local file="$1" addr="$2" arm="${3:-}"
  [ -f "$file" ] || { echo "no such file: $file" >&2; exit 1; }
  ./tools/bin2tcl.py "$file" "$addr" > "$TMP"
  echo "$file -> $addr ($(stat -c%s "$file") bytes)"
  if [ -n "$arm" ]; then
    openocd $CFG -f "$TMP" -c "init" -c "py32_arm_live" -c "py32_write_image" -c "shutdown"
  else
    openocd $CFG -f "$TMP" -c "init" -c "py32_write_image" -c "shutdown"
  fi
}

confirm() {
  [ "${CONFIRM:-}" = "yes" ] && return 0
  echo "This overwrites the stock firmware on the connected unit." >&2
  echo "Recovery needs x2_flash_dump.bin and a working SWD link." >&2
  echo "Re-run with CONFIRM=yes to proceed." >&2
  exit 1
}

cmd="${1:-beacon}"; shift || true

case "$cmd" in
  beacon)     run -c "x2_beacon" ;;
  alive)      run -c "x2_alive ${1:-2000}" ;;
  gpio)       run -c "x2_gpio ${1:-A}" ;;
  cmd)        run -c "x2_cmd ${1:?need a command number} ${2:-0} ${3:-0}" ;;
  ping)       run -c "x2_cmd 1" ;;
  raw)        run -c "${1:?need a tcl snippet}" ;;

  linktest)   ./tools/bin2tcl.py "$STOCK" 0x08000000 --var REF --count 32 > "$TMP"
              openocd $CFG -f "$TMP" -c "init" \
                -c "x2_linktest {${1:-25 50 100 200 500 1000 2000}}" -c "shutdown" ;;

  survey)     rpt="survey-$(date +%Y%m%d-%H%M%S).txt"
              echo "writing $rpt"
              {
                echo "=== Pulse X2 survey — $(date -Is) ==="
                echo
                echo "--- link characterisation ---"
                ./tools/x2.sh linktest 2>&1
                echo
                echo "--- flash controller / protection ---"
                ./tools/x2.sh flash-info 2>&1
                for p in A B F; do
                  echo
                  echo "--- GPIO$p ---"
                  ./tools/x2.sh gpio $p 2>&1
                done
                echo
                echo "--- flash re-dump vs known-good ---"
                ./tools/x2.sh dump "$rpt.bin" 2>&1
                echo "expected: $STOCK_SHA"
                if [ "$(sha256sum "$rpt.bin" | cut -d" " -f1)" = "$STOCK_SHA" ]; then
                  echo "MATCH — flash is byte-identical to the original dump"
                else
                  echo "DIFFERS — compare with: cmp -l $rpt.bin $STOCK"
                fi
              } 2>&1 | tee "$rpt"
              echo
              echo "saved: $rpt" ;;

  flash-info)     run -c "py32_info" ;;
  flash-selftest) run -c "py32_selftest ${1:-0x0800C000}" ;;
  flash)          write_image "${1:?need a .bin}" "${2:?need an address}" ;;

  flash-app)  app="${1:?need beacon or shell}"
              bin="build/$app/x2-$app.bin"
              [ -f "$bin" ] || { echo "build it first: make APP=$app" >&2; exit 1; }
              make APP="$app" verify
              confirm
              write_image "$bin" 0x08000000 arm ;;

  restore)    confirm
              write_image "${1:-../x2_flash_dump.bin}" 0x08000000 arm ;;

  dump)       out="${1:-x2_flash_redump.bin}"
              run -c "halt" -c "dump_image $out 0x08000000 0x10000" -c "resume"
              sha256sum "$out" ;;

  *)          sed -n '2,32p' "$0" >&2; exit 2 ;;
esac
