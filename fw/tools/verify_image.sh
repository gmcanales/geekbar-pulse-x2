#!/usr/bin/env bash
# Structural checks on a built image. These are the properties that keep a
# unit recoverable, asserted against the actual linked binary rather than
# against the source — the source is what we *meant*, this is what ships.
set -uo pipefail
app="${1:?usage: verify_image.sh <beacon|shell>}"
elf="build/$app/x2-$app.elf"
bin="build/$app/x2-$app.bin"
fails=0

ok()   { printf "  ok    %s\n" "$1"; }
bad()  { printf "  FAIL  %s\n" "$1"; fails=$((fails+1)); }
want() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got $2 want $3"; }

echo "verifying $app:"

# STOP mode is what kills the debug port on the stock firmware. If a sleep
# instruction ever reaches an image, a sealed unit stops answering.
n=$(arm-none-eabi-objdump -d "$elf" | grep -Ec '\b(wfi|wfe)\b' || true)
want "no sleep instructions" "$n" "0"

# The host reads firmware state from this exact address with no .elf to hand.
a=$(arm-none-eabi-nm "$elf" | awk '$3=="g_beacon"{print $1}')
want "g_beacon pinned" "0x$a" "0x20000000"

# A bad stack pointer or reset vector means it never reaches main, and on a
# sealed unit that is indistinguishable from a failed flash.
msp=$(od -An -tx4 -N4 -j0 "$bin" | tr -d ' ')
rst=$(od -An -tx4 -N4 -j4 "$bin" | tr -d ' ')
want "initial MSP = top of 8K RAM" "0x$msp" "0x20002000"
case "$rst" in
  08*[13579bdf]) ok "reset vector in flash, thumb bit set (0x$rst)" ;;
  *)             bad "reset vector looks wrong: 0x$rst" ;;
esac

# The coil driver pin is still unidentified on the X2. The first thing we
# flash must be incapable of driving any pin at all.
if [ "$app" = "beacon" ]; then
  n=$(arm-none-eabi-objdump -d "$elf" | grep -Ec '0x5000[0-9a-f]{4}' || true)
  want "beacon touches no GPIO" "$n" "0"
fi

sz=$(stat -c%s "$bin")
[ "$sz" -le 65536 ] && ok "image fits in 64K flash ($sz B)" || bad "image too large: $sz B"

[ "$fails" -eq 0 ] && echo "  -> $app image verified" || { echo "  -> $app FAILED"; exit 1; }
