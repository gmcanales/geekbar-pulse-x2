# Writing custom firmware for the Geek Bar Pulse X2

A walkthrough of what we built, why it's shaped the way it is, what testing
found, and how code actually gets onto the chip. Written assuming no firmware
background — terms are defined on first use, and there's a glossary up front
you can skip if you already know it.

Companion to `geekbar-pulse-x2-salvage.md` (the hardware investigation) and
`fw/README.md` (the terse operational reference).

---

## The one-paragraph version

Inside the vape is a small computer — a **microcontroller** — running a
program burned into its memory at the factory. We found a way to talk to it
through the USB-C charge port, copied that program out, and now want to
replace it with our own. This document covers writing that replacement, the
rules that keep the vape recoverable if we get it wrong, how we tested code
that hasn't touched hardware yet, and the mechanics of actually burning it in.

---

# Part 0 — Vocabulary

## The chip

**MCU (microcontroller unit)** — a whole computer on one chip: processor,
memory, and hardware peripherals (timers, pin controllers, etc.). Ours is a
**Puya PY32F030x8**. Unlike your laptop's CPU it has no operating system; your
program *is* the only software running.

**ARM Cortex-M0+** — the processor design inside it. ARM licenses the core
design; Puya builds it into their chip. "M0+" is the smallest, cheapest tier —
32-bit, no floating-point hardware, runs at a few MHz.

**Bare metal** — programming with no operating system underneath. Your code
starts at power-on and owns everything. There is no `printf`, no files, no
memory allocator unless you write one.

**Flash** — non-volatile memory holding your program. Survives power loss.
Ours: **64 KB** starting at address `0x08000000`. Slow to write, fast to read.

**RAM** — volatile working memory, erased on power loss. Ours: **8 KB** at
`0x20000000`. That is genuinely tiny — a single 4K JPEG wouldn't fit.

**Register** — a named slot of memory that *is* a hardware control. Writing to
one physically does something: sets a pin high, starts an erase. They live at
fixed addresses (**memory-mapped I/O**, or **MMIO**), so controlling hardware
looks exactly like writing to memory.

**Peripheral** — a hardware block with its own registers. **GPIO** (General
Purpose Input/Output) controls physical pins. **SysTick** is a countdown timer
built into the ARM core. **RCC** (Reset and Clock Control) manages clocks.
**IWDG** (Independent Watchdog) resets the chip if not periodically "fed".

**Option bytes** — a small factory/user-configurable area separate from your
program, setting things like default clock speed and readout protection. Read
by hardware at power-on, before any of your code runs.

## Getting code onto it

**SWD (Serial Wire Debug)** — a two-wire ARM protocol for controlling a chip
from outside: read/write any memory, halt the processor, single-step. Two
signals plus ground:

| Signal | Meaning | On our USB-C port |
|---|---|---|
| `SWDIO` | Serial Wire Data In/Out — bidirectional data | **B5** (`CC2`) |
| `SWCLK` | Serial Wire Clock — the clock | **A5** (`CC1`) |
| `GND` | Ground reference | the one populated ground pin |

**Debug probe** — the hardware adapter between USB and SWD. Ours is a
**Raspberry Pi Debug Probe**, which speaks **CMSIS-DAP** (a standard USB
protocol for debug adapters). **DAP** = Debug Access Port, the block inside
the chip that SWD talks to.

**OpenOCD (Open On-Chip Debugger)** — the PC-side program that drives the
probe. Scripted in **Tcl**, an old and slightly odd scripting language.
OpenOCD embeds **Jim Tcl**, a compact reimplementation which differs from real
Tcl in ways that bit us (see Part 4).

**Brick** — to render a device unresponsive and unrecoverable. Usually means
flashing something broken *and* losing the ability to flash again. Avoiding
this shapes nearly every decision below.

## How code is laid out

**Toolchain** — the programs that turn source into a chip image. Ours is
`arm-none-eabi-gcc`: a **cross-compiler**, meaning it runs on x86 Linux but
emits ARM code. The name reads as *target ARM, no operating system, Embedded
ABI*.

**Linker** — combines compiled pieces and decides what lives at which address.
The **linker script** (`.ld`) is the map telling it where flash and RAM are and
what goes in each.

**Sections** — categories the linker sorts your program into:

| Section | Holds | Lives in |
|---|---|---|
| `.text` | executable code | flash |
| `.rodata` | constants (`const`, string literals) | flash |
| `.data` | initialised variables | RAM, copied from flash at boot |
| `.bss` | zero-initialised variables | RAM, zeroed at boot |

**Vector table** — a list of addresses at the very start of flash. The
hardware reads it directly. Entry 0 is the initial **stack pointer**; entry 1
is the address of the first instruction to run. The rest are handlers for
interrupts and faults.

**Reset handler** — that first function. It sets up `.data` and `.bss`, then
calls `main()`. On a PC the C library does this invisibly; bare metal, you
write it.

**Stack pointer / MSP (Main Stack Pointer)** — where the call stack starts.
Grows *downward*, so it's initialised to the **top** of RAM: `0x20002000`
(= `0x20000000` + 8 KB).

**`.elf` vs `.bin`** — the linker emits an `.elf`, a rich file with symbol
names and debug info. Stripping all that leaves a `.bin`: the raw bytes as
they'll sit in flash. The chip gets the `.bin`.

**WFI / WFE (Wait For Interrupt / Event)** — ARM instructions that put the
processor to sleep to save power. **STOP mode** is a deep sleep that also
**switches off the debug port** — which is the single most important fact in
this whole project (Part 1).

## Flash memory specifics

Flash can't be freely overwritten. Physically, **erasing sets bits to 1**
(a blank byte reads `0xFF`) and **programming can only clear bits to 0**. To
change a `0` back to a `1` you must erase.

**Page** — the smallest erasable unit. Ours: **128 bytes**.
**Sector** — a larger erase unit. Ours: **4096 bytes**.

Erase granularity is why you can't just poke one byte: to change it you erase
its whole 128-byte page (destroying the other 127) and rewrite all of it.

---

# Part 1 — Architecture

## The hard rule everything follows from

The stock firmware calls `HAL_PWR_EnterSTOPMode` — it goes into deep sleep
when idle. **STOP mode disables the debug port.** That is the complete
explanation for a symptom that cost hours during the hardware investigation:
SWD only responded while the vape was charging, because charging kept it awake.

So:

> **Whatever we flash first must preserve SWD access.**
> Lose it on a sealed unit and the unit is gone.

Everything below is downstream of that sentence.

**Neither of our apps sleeps at all.** No `WFI`, no `WFE`, no STOP — the main
loops are plain busy loops, and the build *verifies* this by scanning the
compiled image for those instructions. Once ours is flashed, the debug port is
up whenever the battery is, and the charging dance disappears entirely.

## Why bare metal, not the vendor HAL

**HAL (Hardware Abstraction Layer)** is the vendor's C library wrapping the
registers in friendlier functions. We have Puya's, vendored in `firmware/` from
the VapeRE project. We use it as a *reference* — reading it to learn the
correct register sequences — but don't link against it.

Reason: our first image needs to be auditable line by line, because a bug in it
could cost a unit. The HAL is tens of thousands of lines. Our `beacon` app is
**480 bytes** of machine code and can be read end to end in a sitting.

## Memory map

```
0x08000000  ┌───────────────────────────┐
            │ vector table (64 entries) │  MSP, reset handler, fault handlers
            │ .text   — our code        │
            │ .rodata — constants       │
0x080001E0  ├───────────────────────────┤  ← beacon app ends here (480 B)
            │ erased (0xFF)             │
0x08010000  └───────────────────────────┘  64 KB total

0x20000000  ┌───────────────────────────┐
            │ .beacon — 64 bytes        │  ← pinned here on purpose
            │ .data / .bss              │
            │ ...free...                │
            │ stack (grows downward)    │
0x20002000  └───────────────────────────┘  8 KB total, MSP starts here
```

## What happens at power-on

1. Hardware reads **entry 0** of the vector table into the stack pointer, and
   **entry 1** into the program counter, then starts executing.
2. Our reset handler runs, in this order:
   - **Feed the watchdog immediately.** If the option bytes happen to enable
     the IWDG in hardware mode, it is *already counting down* by the time our
     code runs. Feeding a watchdog that isn't running is a no-op, so this costs
     nothing — but if one *is* running, an unfed one resets us forever and
     looks exactly like a failed flash.
   - Set **VTOR** (Vector Table Offset Register) so the core knows where our
     vectors are.
   - Copy `.data` from flash into RAM; zero `.bss`.
   - **Deliberately skip the beacon** — see below.
   - Call `main()`.

## The beacon — how we see inside a running chip

There's no console. The PY32F030 has no USB peripheral, the USB-C data pins go
nowhere, and the only pins reachable through the charge port are physically the
SWD pins. So we can't `printf`.

Instead: a **64-byte struct pinned at exactly `0x20000000`**, the first bytes
of RAM. The firmware writes its state there; the host reads that address over
SWD. That's the entire debug channel.

| Offset | Field | Purpose |
|---|---|---|
| `+0x00` | `magic` | `0x32584247` (`"GBX2"`) — proves our code is running |
| `+0x08` | `app_id` | which app is flashed |
| `+0x0C` | `boot_count` | survives a warm reset — counts reboots |
| `+0x10` | `heartbeat` | increments every loop; proves it hasn't hung |
| `+0x14` | `ticks_lo/hi` | raw SysTick count |
| `+0x20` | `cmd`/`cmd_seq` | host writes commands here |
| `+0x28` | `ack_seq` | firmware echoes when done |
| `+0x2C` | `arg0`/`arg1`/`ret0`/`ret1`/`status` | parameters and results |

Two details that matter:

**Why it survives reset.** The section is marked `NOLOAD` and the reset handler
skips it, so RAM contents persist across a warm reset. That's how `boot_count`
works — if the magic is already there, we've booted before.

**Why the host writes `cmd_seq` last.** The host writes `cmd`, `arg0`, `arg1`,
*then* bumps `cmd_seq`. The firmware only acts when `cmd_seq != ack_seq`. Since
the bump is what makes a command visible, a half-written command can never
execute. (This pattern is called a *sequence lock*.)

**Why raw SysTick ticks, not milliseconds.** We deliberately don't configure
the clock — fewer things to misconfigure. But that means we don't *know* the
speed: it's set by an option byte (`HSIFS`) selecting 4, 8, 16, 22.12 or
24 MHz. So rather than guess, the firmware exports a raw counter and the host
measures it against wall-clock across two reads. Guessing would have been
easier and wrong.

## The two apps

### `beacon` (480 bytes) — the minimum-risk first flash

**Touches no GPIO at all.** Every pin stays exactly as reset leaves it, which
is the same state the chip is in before any of our code runs.

That's not caution for its own sake. **We have not yet identified which pin
fires the coil.** An unknown pin driven high is the one mistake in this project
that starts a fire. So the first image is provably incapable of driving any
pin — the build checks the compiled binary contains zero references to the
GPIO address range.

All it proves is that build → flash → boot → run works. That's worth a whole
firmware, because when the *next* one misbehaves you already know the chain is
good.

### `shell` (1080 bytes) — pin discovery without reflashing

Reads commands from the beacon struct and executes them, so the host can poke
pins over SWD with no rebuild per experiment. Two open hardware questions —
confirming the pin map, and bit-walking the display's segment map — are dozens
of small experiments each. A flash cycle per experiment would be miserable.

Two guarantees, enforced in code rather than by convention:

1. **PA13/PA14 (the SWD pins) cannot be touched.** Every pin command refuses
   them. The raw-register escape hatch refuses writes to GPIOA's *configuration*
   registers outright, while leaving the level registers writable — those move
   pin voltages but can't change what a pin *is*.
2. **`PIN_PULSE` returns the pin to input when it finishes.** A discovery sweep
   cannot leave an unidentified pin — possibly the coil driver — parked driven.

The write allowlist also excludes the flash controller, so the shell can never
erase the firmware running it.

---

# Part 2 — How the firmware gets built

```
  main.c ──┐
startup.c ─┼─► arm-none-eabi-gcc ─► .o files ─┐
beacon.c ──┘        (compile)                 │
                                              ▼
              py32f030x8.ld ───────────► ld (link) ─► .elf ─► objcopy ─► .bin
              (the memory map)                        │                   │
                                              symbols, debug        raw bytes
                                                                    for flash
```

Flags worth understanding:

- `-mcpu=cortex-m0plus -mthumb` — target this core, using **Thumb** (ARM's
  compact 16-bit instruction encoding; M0+ runs *only* Thumb).
- `-Os` — optimise for size.
- `-ffreestanding -nostdlib` — no operating system, no standard C library.
- `-ffunction-sections -fdata-sections` + `--gc-sections` — put each function
  in its own section and discard unreferenced ones. This is why 480 bytes.

Result:

| App | Flash used | RAM used |
|---|---|---|
| `beacon` | 480 B of 64 KB (0.73%) | 64 B of 8 KB (0.78%) |
| `shell` | 1080 B of 64 KB (1.65%) | 64 B of 8 KB (0.78%) |

---

# Part 3 — Testing code that has never run

Nothing has touched hardware. Everything below runs on the laptop.

## Tier 1 — host tests (101 assertions)

The firmware compiles for x86 under a `HOST_TEST` flag, swapping the real
register definitions for a **fake register map** (`test/fake_hw.h`) — plain
structs in laptop memory. The test seeds registers, runs the *real* firmware
logic, and inspects what changed.

- **30 assertions** on the safety rules in isolation.
- **71 assertions** on the command dispatcher that applies them.

This tier catches what actually goes wrong in code this size. Example: setting
pin PA11 to output means writing `01` into bits 22–23 of a register where every
pin owns two bits. Get the shift wrong and you configure the wrong pin. The
test asserts PA11's bits changed **and** that PA13/PA14's bits didn't.

Why not just read the assembly? Because `-Os` **inlines** the guard functions —
they vanish as distinct code. So the rules live in a hardware-free header and
get asserted directly.

## Tier 2 — image verification

Checks against the **linked binary**, not the source. The source is what we
*meant*; the image is what ships.

- No `WFI`/`WFE` anywhere → STOP mode is unreachable
- `g_beacon` really is at `0x20000000`
- Initial MSP is `0x20002000` (top of RAM)
- Reset vector points into flash with the Thumb bit set
- `beacon` references no GPIO addresses at all
- Image fits in 64 KB

## Tier 3 — flash driver simulation (30 assertions)

The flash driver is Tcl running inside OpenOCD, so we test it by running the
**real driver** against a **simulated flash controller**, inside OpenOCD's own
interpreter. The simulator models what actually bites on this part: dummy-write
erase, the 32-word page buffer, `PGSTRT` ordering, lock enforcement, mandatory
timing registers, and *programming can only clear bits* — so writing over
un-erased flash silently ANDs rather than failing loudly.

## What we deliberately did not do

**Firmadyne** was suggested and is the wrong shape — it unpacks a Linux root
filesystem and boots it under an emulated kernel. There's no OS, no filesystem
and no kernel here; 8 KB of RAM doesn't run Linux.

**Renode** would be the right emulator — it models arbitrary memory-mapped
peripherals from a platform description. Held off for now: for a 480-byte busy
loop, faithfully modelling the peripherals costs more than the host tests did,
and a *mis*-modelled peripheral produces confident wrong answers. It earns its
keep when there's timing-sensitive protocol code — the display bus will be
exactly that.

---

# Part 4 — Bugs and findings

## From the hardware investigation

**`VCC` on the breakout board is not the CC pins.** Every early measurement
used pins silkscreened `VCC`, which turned out to be bonded to the VBUS
(power) group. The real CC pins were unlabelled `A5`/`B5`. Hours lost.

**SWDIO and SWCLK were reversed** from what the original notes assumed. The
working assignment is `SWDIO→B5`, `SWCLK→A5`.

**Two facts that looked contradictory were both true.** Measuring 0.43 V on CC2
is a textbook USB-C pulldown, which looked like conclusive proof the pin was
doing normal USB duty and *not* SWD. The schematic later showed 5.1 kΩ
pulldowns on the CC lines **and** SWD on the same pins. Both true at once. The
lesson: a measurement consistent with one explanation isn't proof against
another.

**PY32 puts GPIO at `0x50000000`,** not `0x48000000` where ST's similar chips
put it. Searching the firmware dump for the wrong address found nothing and
implied the wrong conclusion.

## From building and testing

**`uint32_t`-to-pointer truncation.** The raw-register commands cast an address
to a pointer. Fine on a 32-bit ARM; on a 64-bit test host it silently chops the
top half off a real pointer. It also made the code untestable. Fixed with an
`MMIO32()` seam — a plain cast on the chip, a lookup on the host — which made
the *allowed* write path testable too, not just the refusals.

**Jim Tcl's `switch` compares strings, not numbers.** `switch $addr { 0x40022010 {...} }`
never matched, because `$addr` had already been evaluated to decimal. Silent
wrong behaviour, no error.

**Jim Tcl's `expr` returns hex literals verbatim.** `expr {0x40021004}` yields
the *string* `"0x40021004"`, not the number `1073876996`. Used as a dictionary
key that's a completely different slot from the same address computed
arithmetically. This one took a debug session to isolate; the fix is forcing
arithmetic with `expr {$v + 0}`.

Both Tcl bugs were in the *test simulator*, not the driver — but they're the
same class of trap the driver's own address handling could fall into, which is
part of why writing the simulator was worth it.

## Findings about the chip

**The stock firmware leaves 27 KB of flash blank.** Real code ends around
`0x0800849C`; everything up to `0x0800F000` reads `0xFF`. There's a 128-byte
factory calibration page at `0x0800F000`, then blank again to the end. That
blank region turns out to be extremely useful (Part 5).

**No readout protection.** We dumped the full 64 KB with no resistance, so we
have a complete recovery image.

**Flash timing registers are mandatory and non-obvious.** More below — this was
the single most important discovery for the write path.

---

# Part 5 — The flashing process

## Why OpenOCD couldn't do it out of the box

Reading flash needs no special support — it's just memory reads. **Writing
does.** OpenOCD normally needs a *flash driver*: a chip-specific routine it
uploads into the target's RAM and runs, because on most chips the CPU can't
execute from flash while flash is being programmed. OpenOCD 0.12 has no PY32
driver.

The documented alternative is **pyOCD** plus Puya's **DFP** (Device Family
Pack — a vendor bundle containing, among other things, a prebuilt flash
algorithm). That needs `pip3`, which isn't installed here.

**The realization that avoided all of it:** the vendor HAL marks its
programming routine `__RAM_FUNC` — "run this from RAM" — precisely because the
CPU can't fetch instructions from flash mid-program. But if we **halt the CPU**
and let the debug probe do the writes, the CPU isn't fetching anything at all.
That constraint doesn't apply to us. So the host can drive the flash controller
directly, no uploaded algorithm needed.

## How the PY32 flash controller works

Three quirks, all read out of the vendor HAL source rather than guessed:

**1. Erase is triggered by a dummy write.** Not a start bit — you set the
`PER` (Page Erase) bit in the control register, then write *any value* to any
address inside the target page. That write is the trigger.

```
CR = PER            # arm page erase
*(page address) = 0xFF   # anything; the write itself triggers it
wait for BSY to clear
CR = 0
```

**2. Programming is page-at-a-time, with a commit.** You write exactly 32 words
(128 bytes) into a buffer, set `PGSTRT` after the 31st, and the 32nd write
commits the whole page.

```
CR = PG                   # arm programming
write words 0..30         # fills the page buffer
CR = PG | PGSTRT          # arm the commit
write word 31             # this write commits all 32
wait for BSY to clear
```

**3. Flash timing registers must be loaded first — and this one can damage the
chip.** Nine registers (`TS0`, `TS1`, `TS2P`, `TPS3`, `TS3`, `PERTPE`,
`SMERTPE`, `PRGTPE`, `PRETPE`) control the physical pulse timings of the erase
and program operations. They must match the current clock speed. Wrong values
mean pulses of the wrong duration, which can damage flash cells.

The correct values aren't constants — they're **factory-calibrated per chip**
and stored in a read-only info area. The HAL keeps a lookup table:

```c
const uint32_t _FlashTimmingParam[8] = {0x1FFF0F1C,  // 4 MHz
                                        0x1FFF0F30,  // 8 MHz
                                        0x1FFF0F44,  // 16 MHz
                                        0x1FFF0F58,  // 22.12 MHz
                                        0x1FFF0F6C,  // 24 MHz
                                        ...};
```

You read the current clock setting from `RCC_ICSCR` bits 13–15, index that
table, read the 20-byte block it points at, unpack it into the nine registers.

This is the part that would have been easy to miss — the HAL calls it from
inside `HAL_FLASH_Erase`, so it's invisible if you only read the top-level API.
Our driver **refuses to erase or program** if the factory block reads as
erased, on the grounds that programming with garbage timings is worse than not
programming.

## The full sequence

```
halt the CPU                          ← no instruction fetch from flash
unlock: KEYR = 0x45670123
        KEYR = 0xCDEF89AB             ← two magic values, in order
verify CR.LOCK is now clear
read RCC_ICSCR → clock index
read the factory timing block → load 9 timing registers
  for each 128-byte page:
    erase  (PER + dummy write, wait for BSY)
    program (PG, 31 words, PGSTRT, final word, wait for BSY)
lock: CR.LOCK = 1
read everything back and compare
resume
```

The status register is checked after every operation for `WRPERR` (write
protection violation) and `OPTVERR` (option byte mismatch).

## The write guard — why we can't brick it by accident

By default, **every write is confined to `0x08009000`–`0x0800F000`** — inside
that blank region the stock firmware never uses. The stock firmware itself and
the factory calibration page are refused outright, unless `py32_arm_live` is
called explicitly. `flash-app` and `restore` additionally require
`CONFIRM=yes` in the environment.

## Proving the write path without risking anything

This is the part that replaces buying a development board.

Because 27 KB of flash sits blank and unused, we can run **the complete write
path** — unlock, timing load, erase, program, verify, re-erase — in a page
there **while the vape keeps running normally**. Same silicon, same
factory-calibrated timings, same marginal hand-held SWD link. If it fails,
nothing is lost and the unit is untouched.

```bash
./tools/x2.sh flash-info        # pure reads: protection, timing, clock
./tools/x2.sh flash-selftest    # the real question — does writing work?
```

`flash-info` also answers something never yet checked: whether `WRPR` or `SDKR`
have any write protection enabled. If they do, that changes the plan *before*
we spend a unit.

## The one thing still unproven

The vendor fills that 32-word page buffer from RAM at full clock speed. We fill
it over SWD at 100 kHz — roughly a thousand times slower. **If the page buffer
has an undocumented timeout, programming will fail.** No amount of simulation
answers this; only the chip can.

`flash-selftest` is precisely where it surfaces, harmlessly, on a blank page.
The fallback if it does: a small RAM-resident stub doing the 32 writes at full
speed, driven the same way — which is what pyOCD's flash algorithm would have
been anyway.

---

# Part 6 — Recovery

Layers, cheapest first:

1. **Our firmware never sleeps**, so SWD stays alive permanently. Reflashing a
   bad image is just flashing again. This is the main defence and the reason
   for the hard rule in Part 1.
2. **`x2_flash_dump.bin`** — a verified full copy of the factory firmware.
   `./tools/x2.sh restore` puts it back. **Dump this yourself before you
   write anything** — it is not in this repo (it is Geek Bar's firmware, not
   ours to ship), and it is your only cheap way back.
3. **BOOT0** — pin PF4 on the MCU, wired through a 1 kΩ resistor. Pulling it
   high at reset boots Puya's factory bootloader instead of your program,
   which works even if flash contains garbage. Requires opening the case.
4. **A pile of spare units.**

The realistic worst case is *not* an unrecoverable brick — it's a unit that
needs its case opened, which is a nuisance rather than a loss.

---

# Part 7 — Actually running it

```bash
cd fw
make check          # 131 assertions + both images + image verification
```

Rig: vape seated in the breakout, charger in the female side, **actively
charging** (stock firmware sleeps otherwise — this stops mattering once ours is
flashed). Probe GND / `SWDIO`→B5 / `SWCLK`→A5, held steady.

```bash
# reads — safe against stock firmware, nothing is written
./tools/x2.sh gpio A            # decode pin configuration
./tools/x2.sh flash-info        # flash protection / timing / clock report
./tools/x2.sh dump out.bin      # re-dump the 64 KB

# writes — scratch flash only, stock firmware keeps running
./tools/x2.sh flash-selftest

# writes — replaces the stock firmware
CONFIRM=yes ./tools/x2.sh flash-app beacon
./tools/x2.sh beacon            # read firmware state
./tools/x2.sh alive             # confirm it runs, measure the real clock

# undo
CONFIRM=yes ./tools/x2.sh restore
```

Suggested order for the first hardware session: `flash-info` → `flash-selftest`
→ `gpio A`. All three are cheap, and the first two answer whether the plan is
viable before anything irreversible happens.

---

# Appendix — Register reference

**Flash controller** — base `0x40022000`

| Offset | Name | Purpose |
|---|---|---|
| `+0x00` | `ACR` | access control / latency |
| `+0x08` | `KEYR` | unlock keys: `0x45670123` then `0xCDEF89AB` |
| `+0x10` | `SR` | status: `EOP`=0, `WRPERR`=4, `OPTVERR`=15, `BSY`=16 |
| `+0x14` | `CR` | control: `PG`=0, `PER`=1, `MER`=2, `SER`=11, `PGSTRT`=19, `LOCK`=31 |
| `+0x20` | `OPTR` | option bytes |
| `+0x24` | `SDKR` | SDK-protected area |
| `+0x2C` | `WRPR` | write-protected sectors (`0xFFFFFFFF` = none) |
| `+0x100`–`+0x120` | `TS0`…`PRETPE` | the nine timing registers |

**GPIO** — `GPIOA` `0x50000000`, `GPIOB` `0x50000400`, `GPIOF` `0x50001400`

| Offset | Name | Purpose |
|---|---|---|
| `+0x00` | `MODER` | 2 bits/pin: 00 input, 01 output, 10 alt-function, 11 analog |
| `+0x0C` | `PUPDR` | 2 bits/pin: pull-up / pull-down |
| `+0x10` | `IDR` | live input levels |
| `+0x14` | `ODR` | output levels |
| `+0x18` | `BSRR` | atomic set (bits 0–15) / reset (bits 16–31) |
| `+0x20`/`+0x24` | `AFR[0]`/`AFR[1]` | alternate-function selection |

**Other**

| Address | Name | Purpose |
|---|---|---|
| `0x40021004` | `RCC_ICSCR` | bits 13–15 = `HSI_FS`, the clock-speed selector |
| `0x1FFF0F1C`+ | factory info | flash timing blocks, 20 bytes each |
| `0xE000ED00` | `CPUID` | reads `0x410CC601` = Cortex-M0+ r0p1 |

**Geometry** — flash 64 KB @ `0x08000000` · RAM 8 KB @ `0x20000000` ·
page 128 B · sector 4096 B
