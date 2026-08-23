# Geek Bar Pulse X2 — custom firmware

Bare-metal PY32F030x8 firmware. No HAL, no newlib — only the CMSIS headers
vendored under `../firmware`, and only as headers. Both apps are small enough
to read end to end in a sitting, which is the point: this is the code that
decides whether a unit stays recoverable.

```
make            # build the beacon app
make APP=shell  # build the SWD-poke shell
make check      # host tests + both images + image verification  <- pre-flash gate
make test       # host tests only (101 assertions, no hardware)
make verify     # structural checks on a built image
make disasm     # annotated disassembly
```

| | flash | RAM |
|---|---|---|
| `beacon` | 480 B (0.73%) | 64 B (0.78%) |
| `shell`  | 1080 B (1.65%) | 64 B (0.78%) |

Nothing here has been flashed to hardware yet.

## The one hard rule

**Whatever we flash first must preserve SWD.** The stock firmware calls
`HAL_PWR_EnterSTOPMode`, and STOP mode disables the debug port — that is the
entire reason SWD only responds while the unit is charging. Neither app here
sleeps at all: `make` audits clean for `wfi`/`wfe`, and the main loops are
plain busy loops. Once either app is flashed, the charging dance goes away and
the debug port is up whenever the battery is.

Everything else follows from that rule:

- **The clock tree is left at reset defaults.** Nothing to misconfigure, and no
  way to end up running from a dead oscillator. The cost is that we don't know
  the core frequency up front — `HSIFS` is an option byte selecting 4 / 8 / 16 /
  22.12 / 24 MHz — so the firmware exports a raw SysTick count and
  `x2.sh alive` measures the real clock against wall-clock instead.
- **`IWDG` is kicked unconditionally**, in the reset handler before anything
  else and in every loop. Kicking a stopped watchdog is a no-op, so this is
  free; if the option bytes turn out to enable IWDG in hardware mode, an
  un-kicked watchdog would reset us forever and look exactly like a bad flash.
- **Fault handlers spin, they don't reset.** A crash leaves the core
  halted-but-attachable for a post-mortem instead of in a reset loop.

## `beacon` — the minimum-risk first flash

Touches no GPIO whatsoever. Every pin stays exactly as reset leaves it, which
is the same state the chip is in before any of our code runs. That matters
because **the coil driver pin is not yet identified on the X2**, and an
unknown pin driven high is the one mistake here that starts a fire. The build
verifies this: the image contains zero references to the `0x5000xxxx` GPIO
aperture.

All it proves is that build → flash → boot → run works. That is worth a whole
firmware on its own, because when the next one misbehaves you want to already
know the chain is good.

## `shell` — pin discovery without reflashing

Reads commands out of the beacon struct and executes them, so the host can
poke pins over SWD with no build/flash cycle per experiment. That's what makes
the two open hardware questions tractable — confirming the BD0061 (Pulse X Jam)
pin mapping carries over to the X2, and bit-walking the LED panel's segment
map — since both are dozens of small experiments.

Two guarantees, enforced in code rather than by convention:

1. **PA13/PA14 cannot be touched.** Every pin command refuses them
   (`ST_PIN_LOCKED`), and the raw-register escape hatch refuses writes to
   GPIOA's config registers outright (`ST_ADDR_DENIED`). `BSRR`/`ODR` stay
   writable since they move levels but cannot change pin mode. On a sealed
   unit, losing SWD means losing the unit.
2. **`CMD_PIN_PULSE` returns the pin to input when it finishes.** A discovery
   sweep cannot leave an unidentified pin — possibly the coil driver — parked
   in a driven state.

The write allowlist also carves out the flash controller, so the shell can
never erase the firmware running it.

`-Os` inlines all of this out of the disassembly, so the guards live in
`common/guards.h` with no hardware dependency and are asserted on the host —
see Testing below.

**Still do pin discovery with the coil disconnected where you can.** The
guards protect the debug link; they can't know which pin fires the atomizer.

## Protocol

A 64-byte struct pinned at `0x20000000` (`common/beacon.h`). It's `NOLOAD` and
skipped by startup, so `boot_count` survives a warm reset. The host writes
`cmd`/`arg0`/`arg1` and then bumps `cmd_seq` last — the sequence bump is what
makes a command visible, so a partially-written command can never run. The
firmware executes it, publishes `ret0`/`ret1`/`status`, and echoes `ack_seq`.

This stands in for a serial console, which isn't available: the PY32F030 has no
USB peripheral, D+/D− go nowhere, and the only pins reachable through the
charge port are physically the SWD pins.

## Host tools

`tools/x2.sh` wraps OpenOCD. Rig: vape seated in the breakout, charger in the
female side, actively charging (until the beacon is flashed), probe GND /
SWDIO→**B5** / SWCLK→**A5**, held steady.

```bash
./tools/x2.sh gpio A       # decode GPIO config — safe against stock fw too
./tools/x2.sh beacon       # read firmware state
./tools/x2.sh alive        # confirm the loop runs, measure the core clock
./tools/x2.sh ping         # shell smoke test
./tools/x2.sh cmd 3 0x00B 1   # PA11 -> output
./tools/x2.sh dump out.bin # re-dump flash
```

`gpio` works right now against the stock firmware — it's a pure read, same
risk class as the flash dump — so the pinout can be verified *before*
anything is flashed.

## Testing before it ever reaches a vape

Three tiers, cheapest first. `make check` runs the first two and is the gate
before anything is flashed.

**1. Host tests — 101 assertions, no hardware.** The firmware compiles for x86
under `HOST_TEST` against a fake register map (`test/fake_hw.h`), so the logic
runs natively:

- `tools/test_guards.c` (30) — the safety rules in isolation: SWD pins locked,
  GPIOA config registers and the flash controller unwritable, everything
  outside the peripheral apertures refused.
- `test/test_shell.c` (71) — the dispatcher that *applies* those rules, plus
  the bit math around MODER/PUPDR/BSRR/pinref, the pulse teardown, argument
  validation, and boot counting across a warm reset. It `#include`s the shell
  source so it can drive the static handlers directly.

This tier catches what actually goes wrong in code this size: an off-by-a-shift
in a register field, a BSRR set/reset bit swapped, a guard that reads right but
is applied to the wrong argument. Finding those by watching a vape misbehave
would be miserable.

**2. Image verification — `tools/verify_image.sh`.** Structural checks against
the *linked binary*, not the source, because the source is what we meant and
the image is what ships: no `wfi`/`wfe` anywhere, `g_beacon` pinned at
`0x20000000`, initial MSP is the top of 8K RAM, reset vector in flash with the
thumb bit set, `beacon` references no GPIO aperture at all, image fits in 64K.

**3. A sacrificial PY32F030 board — not done, and the highest-value next
step.** Our C is now well covered; the genuinely untested thing is the *flash
write path* (pyOCD + Puya DFP), and that risk lives in the toolchain, not in
this code. A bare PY32F030 dev board costs about a dollar and can be bricked
and recovered freely over its exposed BOOT0. Shaking the toolchain out there
means the first write to a vape is the first *boring* write.

### On emulation

Firmadyne and its relatives (FAT, EMBA) are the wrong shape for this — they
unpack a squashfs root filesystem and boot it under a QEMU Linux kernel. There
is no OS, no filesystem and no kernel here; 8KB of RAM does not run Linux.

The right tool for a Cortex-M blob would be **Renode**, which takes a custom
platform description and can model arbitrary memory-mapped peripherals, so a
PY32-shaped machine could be declared and the real `.elf` booted end to end.
Plain QEMU is a poor fit: no machine model has peripherals at PY32's
`0x40000000`/`0x50000000`, so every register access would fault straight into
the HardFault handler.

Renode is worth it once there is timing-dependent or protocol-heavy code to
exercise — the LED panel's shift-register bus is the obvious candidate. For
a 480-byte busy loop it would cost more to model the peripherals faithfully
than the tier-1 tests cost to write, and a mismodelled peripheral produces
confident wrong answers. Nothing is installed for it yet (no `renode`, no
`qemu-system-arm`).

## The write path

OpenOCD 0.12 ships no PY32 flash algorithm. Rather than take on pyOCD plus
Puya's DFP pack (and `pip3`, which isn't installed), `tools/py32_flash.tcl`
drives the flash controller directly from the host with the core halted. With
the CPU stopped there is no instruction fetch from flash during a program
cycle — which is the reason the vendor HAL marks its programming routine
`__RAM_FUNC`, and that constraint simply doesn't apply to us.

The sequence is lifted from the vendor HAL, not guessed. Three quirks of this
part drive the design:

- **Erase is triggered by a dummy write** into the target page, not a start
  bit. Set `CR.PER`, write anything into the page, poll `SR.BSY`.
- **Programming is page-at-a-time**: exactly 32 words, with `CR.PGSTRT` set
  after the 31st. The final word write commits the page.
- **Flash timing registers must be loaded first.** `FLASH->TS0..PRETPE` come
  from a per-clock-speed factory block in the info area, selected by
  `RCC_ICSCR.HSI_FS` (`_FlashTimmingParam[]` in the HAL: `0x1FFF0F1C` for
  4 MHz through `0x1FFF0F6C` for 24 MHz). Wrong values can damage cells, so
  the driver refuses to erase or program if the block reads as erased.

### Testing it without hardware

`make flashtest` runs the real driver against a simulated flash controller
inside OpenOCD's own Jim interpreter — so the code under test is the actual
shipping Tcl, not a transcription. The simulator models what bites on this
part: dummy-write erase, the 32-word page buffer, PGSTRT ordering, `LOCK`
enforcement, mandatory timing registers, and the fact that programming can
only clear bits (so writing over un-erased flash silently ANDs rather than
failing loudly). **30 assertions**, covering the timing field extraction,
erase/program sequencing, the write guard, and multi-page image writes with a
short final page.

### Testing it on hardware without risking anything

The stock image leaves `0x0800849C–0x0800F000` erased — 27KB of flash nothing
depends on. `flash-selftest` exercises unlock, timing load, erase, program,
verify and re-erase in a page there, **while the vape keeps running normally**.
A failure costs nothing and the unit is untouched.

That is what replaces buying a dev board. The write guard enforces it: by
default every write is confined to `0x08009000–0x0800F000`, and anything
touching the stock firmware or the 128-byte factory calibration page at
`0x0800F000` is refused until `py32_arm_live` is called explicitly.

```bash
./tools/x2.sh flash-info        # pure reads: protection, timing, clock
./tools/x2.sh flash-selftest    # prove the write path, harm nothing
./tools/x2.sh flash-app beacon  # replace stock fw (needs CONFIRM=yes)
./tools/x2.sh restore           # put the stock dump back
```

### The one thing still unproven

The vendor fills the page buffer from RAM at full clock speed; we fill it over
SWD at 100 kHz, roughly a thousand times slower. If the buffer has an
undocumented timeout, programming will fail — and `flash-selftest` is exactly
where that shows up, harmlessly, on a blank page. The fallback if it does is a
small RAM-resident stub doing the 32 writes at full speed, driven the same way.

## Not done yet

Nothing has been flashed. `../x2_flash_dump.bin` remains the only recovery
image, and proving `restore` works is worth doing before it is ever needed.
