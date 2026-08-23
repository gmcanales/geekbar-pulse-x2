# Geek Bar Pulse X2 — Salvage & Reverse Engineering

Handoff notes. Context: a friend is discarding a quantity of Geek Bar Pulse X2
disposables. Goal is to divert them from e-waste by reusing the electronics.

---

## Goals

Two separate projects. They do **not** depend on each other.

### Project A — Display reuse (primary goal, low risk)
Override the vape's segment display and drive it from an external MCU.
Stretch goal: synchronize animations across multiple units.

### Project B — SWD / firmware access (rabbit hole, optional)
Determine whether the vape's own MCU is accessible over SWD via the USB-C
sideband pins, and if so, dump firmware.

> **Note:** Project A does not require Project B. If SWD turns out to be a dead
> end, desolder the panel and drive it from an ESP32. That path is known to work.

---

## Project A — Display

The Pulse X screen is **not** a framebuffer TFT (unlike Raz/Kraze, which use an
80x160 ST7735S). It's a segmented LED display on a shift-register-style bus.

### Interface
Four pads: `GND`, `VIN`, `CLK`, `DIN` — sometimes silkscreened `G`, `V`, `C`, `D`.

| Pad | Connect to |
|-----|-----------|
| GND | GND |
| VIN | 3.3V |
| CLK | MCU SCK |
| DIN | MCU MOSI |

No chip select. No reset line.

**Board revision gotcha:** on some revisions the `VIN` pad is not actually
connected. In that case, feed 3.3V to the `C2` pad instead.

### Reference implementation
`https://github.com/sm2013-vapehack/geekbar_pulse_x_screen_reuse`

Arduino sketches with serial commands:
- `set X Y` / `clr X Y` — toggle individual byte/bit
- `all 1` — light every segment
- `displayNumber()` — drives the six 7-segment digits

### Open task: segment map for the X2
The published map was derived from the **original Pulse X**. The repo author
notes that even special editions of the Pulse X need remapped segment tables,
so treat the **X2 as an unknown panel**.

Mapping procedure:
1. Wire one panel to an MCU running `general_use.ino`.
2. Walk every bit index with `set X Y`.
3. Photograph each state.
4. Build the table.

One evening of tedium. Worth contributing back upstream to the repo.

### Multi-unit synchronization
No CS line, so don't try to bus them.

- **Preferred:** shared CLK across all panels, separate DIN GPIO per panel.
  Bit-bang frames in lockstep. An ESP32 has ample pins for 6–8 panels.
- **Untested:** daisy-chaining. Scope the last pin on the flex while shifting
  past frame length to see if the driver passes overflow bits out. Don't count on it.
- **Physically separate units:** one ESP32 each + ESP-NOW gives sub-millisecond
  alignment with no router.

---

## Project B — SWD over USB-C

> **SUPERSEDED — see "Project B — RESOLVED" below.** SWD works; firmware is
> dumped. The planning notes in this section are kept for context, but some
> guesses in them turned out wrong — in particular the SWDIO/SWCLK assignment
> in "Wire it up" is backwards, and the `dap init` command doesn't work as
> written. Follow the RESOLVED section, not this one.

### Background
On these devices USB-C is a **power port with a debug port smuggled into the
sideband pins** — not a data port.

| Pins | Function |
|------|----------|
| VBUS + GND | Feeds a TP4056-class charge IC. MCU typically senses VBUS to show the charging animation. |
| D+ / D− | Usually dead. These MCUs generally cannot speak USB at all. |
| CC1 / CC2 | Should be 5.1k pulldowns. **Frequently repurposed as SWDIO / SWCLK.** |

Prior art (Raz/Kraze color-TFT models): SWD brought out on CC pins, firmware
readable with **no readout protection enabled**. Custom cable + J-Link was
sufficient to talk to the MCU in situ.

**Caveat:** that finding is from the TFT family. The Pulse X uses a segment LED
panel and a different board design — likely a different MCU with different pin
choices. Unverified for the X2.

### Why a full 24-pin breakout is required
A normal USB-C **cable** plug only carries one CC line; the other position
becomes VCONN. Probing through an ordinary cable can only ever reach one of the
vape's two CC pins. A full 24-pin male plug breaks out both A5 and B5.

---

## Hardware

| Item | Status |
|------|--------|
| Raspberry Pi Pico USB Debug Probe kit (RP2040, 3-pin cable, case) | ordered |
| USB 3.1 Type-C male-to-female 24P test board, 2.54mm headers, 2pcs | ordered |
| Dupont jumpers M-F / M-M / F-F, 120pcs | ordered |
| Multimeter | on hand |
| Soldering iron + fine tip + flux | ? — needed for header install |

**Why CMSIS-DAP over ST-Link:** OpenOCD treats ST-Link as a high-level adapter
(HLA) — firmware handles the SWD transactions, so no custom line resets,
arbitrary DP sequences, or multi-drop/dormant-wake tricks. Against an
unidentified target those tricks occasionally matter. The Debug Probe is
CMSIS-DAP: raw SWD, no vendor restrictions.

---

## Measurements so far

### Breakout board validation
- A5 ↔ B5: high, fluctuating resistance; 0V — **PASS**, CC1 and CC2 are not
  bridged. (Open circuit on a high range drifts like this; the meter is reading
  noise across megohms.)

### Vape CC pins to GND (male plug inserted, cell connected)
- CC1: **660** — unit ambiguous in notes, recorded as "mohms"
- CC2: **60** — same ambiguity

**UNRESOLVED: confirm whether these are kΩ or MΩ.**
- If MΩ — both pins effectively open, asymmetry is likely leakage/noise.
- If kΩ — real paths to ground exist, an order of magnitude apart.

Either way the headline holds: **neither pin reads 5.1k, and they are not
matched.** A standard USB-C sink shows ~5.1k on both, near-identical. These
pins are doing something else, and asymmetry is consistent with two
functionally different signals (SWDIO idles pulled up; SWCLK sits low or floats).

Caveat: this is an ohm reading on a live circuit — the MCU is powered and
driving these pins. Treat as a rough signal. Re-measure in both meter
polarities if anything looks odd; a protection diode into the rail reads very
differently one way versus the other.

### Still to measure
- [ ] **DC volts, each CC pin to GND**, cell connected, nothing else attached.
      One near 3.3V and one near 0V is a clean SWDIO/SWCLK signature.
- [ ] Continuity: breakout GND header pin → vape battery negative. **If this
      doesn't beep, every other reading is meaningless.**
- [ ] Charger test: 5V brick charges but PD charger refuses → hint that CC
      isn't doing standard pulldown duty.

---

## Next steps

### 1. Identify breakout pins functionally
Don't trust silkscreen. The board is a straight pass-through (male, female, and
headers all on the same nets), and double-sided boards often print identical
silkscreen on both faces — which reads mirrored when flipped. Same pin, same
function, reversed reading order.

Using continuity:
1. Sweep every header pin against every other. One group of four shorted
   together = GND. Another group of four = VBUS.
2. Distinguish: GND group shows continuity to the connector shell on most
   boards; VBUS group doesn't. Confirm by plugging a 5V charger into the female
   side — VBUS reads 5V to GND.
3. CC1 / CC2 are single isolated pins immediately inboard of the VBUS pins.
   Already confirmed not bridged.
4. Positive CC confirmation: plug a USB-C charger cable into the female side,
   measure DC volts on candidates. Active CC sits ~3.3V from the charger's
   pull-up. Flip the cable — the other one goes live.

### 2. Wire it up

```
Debug Probe GND   -> breakout GND   (use two leads: A1 and B12, redundancy is free)
Debug Probe SWDIO -> breakout CC1
Debug Probe SWCLK -> breakout CC2
```

- Leave the female side of the breakout **empty**.
- Keep the vape's cell connected — SWD needs the target powered, and the MCU
  runs off the battery.
- Do **not** feed 5V into VBUS. Unnecessary variable.
- Use GND *pins* (A1, A12, B1, B12), not the shell — shield and signal ground
  are often joined only through a resistor or cap, or not at all.
- Keep leads short. If nothing responds, drop clock speed before concluding the
  target is dead.

### 3. Read the IDCODE

Start at 100kHz. Dupont leads and an unknown target are not the place for speed.

```bash
openocd -f interface/cmsis-dap.cfg \
        -c "transport select swd" \
        -c "adapter speed 100" \
        -f target/swj-dp.tcl \
        -c "init; dap init"
```

pyOCD gives friendlier output against unknown targets:

```bash
pyocd list --probes
pyocd cmd -t cortex_m --no-init
```

**Four combinations total:** SWDIO/SWCLK either way × plug orientation either
way. (Flipping the plug doesn't add cases beyond relabeling which physical vape
pin lands on A5 vs B5.)

**Success:** a non-zero, non-`0xFFFFFFFF` IDCODE. `0x0BC11477` or similar
indicates a Cortex-M0/M0+ DAP, matching what's been found in other vape boards.

### 4. If IDCODE responds
- Dump flash (expect small — tens of KB).
- Check readout protection status.
- Identify the MCU. Likely candidates in this space: Puya PY32, Nations N32, or
  similar ST-clone-adjacent parts.
- Load into Ghidra.

### 5. If IDCODE does not respond
Stop. Fall back to Project A — desolder the panel, drive from ESP32. This is
the path that actually ships.

---

## Project B — RESOLVED: SWD confirmed working, flash dumped

Full writeup of what actually worked, after a long debug session. Keep this
before repeating the investigation.

### The breakout board lies about pin names
This specific 24-pin test board silkscreens a pin group as `VCC` — **that is
not CC1/CC2.** The real CC1/CC2 are at spec positions `A5`/`B5`, unlabeled on
this board. Confirmed by plugging a charger into the breakout's female side
(nothing on the male side) and watching for the orientation-dependent ~5V
swap between A5 and B5 as the cable was flipped — the `VCC`-labeled pins
stayed constant (they're bonded to the VBUS group), A5/B5 swapped cleanly.
**Do not trust any pin labeled `VCC` on this board for CC work.**

Also: of the four GND-spec positions per side, only **one is actually
populated** on this board. Identify it by continuity from a breakout GND pin
to the outer shell of the male plug — but only while the male plug is
seated in the vape (the shell only becomes live via the vape's own ground
plane once mated; standalone the breakout's shell is isolated from all
signal pins).

### Working wiring
```
Debug Probe GND   -> the one verified-good GND pin (see above)
Debug Probe SWDIO -> breakout B5
Debug Probe SWCLK -> breakout A5
```
This is the opposite SWDIO/SWCLK assignment from this doc's original guess
further up. Both plug orientations were tested; this pin/role assignment
combined with the correct orientation is what responded.

### Critical: target only answers SWD while actively charging
Cell-power-only (nothing on the breakout's female side) never got a
response, in any wiring/orientation/speed combination — including with the
device's own power switch held down and the display lit. SWD only responded
with a charger simultaneously plugged into the breakout's **female** side
(charger → breakout → vape, all three connected at once) while the vape was
actively in a charging cycle. Once the battery hit 100% and the charge
animation stopped, SWD access stopped too, even with the charger still
physically connected — the charge *state machine* needs to be active, not
just VBUS present. If you need to reopen this later and the pack is full,
drain it a little first (see the overheat-risk note below on doing this
safely) so a real charge cycle kicks in again.

### Physical connection quality matters more than anything else
Hand-held dupont leads pressed by hand are enough for a quick connect/halt,
but will fault partway through anything longer (a full flash read is
thousands of transactions). Symptoms of a bad connection are either total
silence (`cannot read IDR`) or, worse, garbled/inconsistent DPIDR values on
successive attempts — that second pattern means real bit errors, not just a
dead link. **Use alligator clips or tape the connector housings down** for
anything beyond a one-shot ID check. If a long read still faults partway,
OpenOCD's `dump_image` writes out everything it read before the fault —
retrying from the last successful offset and concatenating chunks works and
is much more reliable than hoping for one unbroken transfer.

### Target identification
- `SWD DPIDR 0x0bc11477`
- `CPUID 0x410cc601` → **ARM Cortex-M0+ r0p1**
- Matches the Cortex-M0+ core used in the Puya PY32F030EK28 parts that
  VapeRE documents on the GeekBar Pulse 15000 and Pulse X Jam (sibling
  boards, same debug-on-CC scheme). The X2 itself isn't in VapeRE's table —
  this closes that gap and is worth contributing upstream.

### Flash dump
`x2_flash_dump.bin` (in this repo, sha256
`dca474276128d86739b3dc5c5951b7c0919d7dcd95fe6c62396e38050182fa99`) — full
64KB read from `0x08000000`, verified clean at both chunk-reassembly seams.
- **No readout protection** — flash was freely readable.
- Real code occupies roughly the first ~33KB (`0x08000000`–`~0x0800849c`).
- A small structured block at offset `0xF000` (`aa55 aa55 ... 12345678 ...`)
  looks like factory calibration data, not garbage.
- The rest is erased (`0xFF`) — 64KB is very likely the chip's actual total
  flash size (consistent with the PY32F030x8 density: 64KB flash).

### Reproducing the connection
```bash
openocd -f interface/cmsis-dap.cfg \
        -c "transport select swd" \
        -c "adapter speed 100" \
        -f target/swj-dp.tcl \
        -c "swj_newdap unknown cpu -expected-id 0x0" \
        -c "dap create unknown.dap -chain-position unknown.cpu" \
        -c "target create unknown.target cortex_m -dap unknown.dap" \
        -c "init" \
        -c "halt" \
        -c "dump_image out.bin 0x08000000 0x10000" \
        -c "resume" \
        -c "shutdown"
```
Note `target/swj-dp.tcl` only *defines* the `swj_newdap` helper on OpenOCD
0.12 — it doesn't call it. The `swj_newdap` / `dap create` / `target create`
lines above are required; the doc's original plain `dap init` command
doesn't create a DAP object by itself and will silently do nothing.

---

## Project C — Custom firmware (in progress)

> **New to firmware?** `firmware-guide.md` is a from-scratch walkthrough of the
> architecture, the testing, and the flashing process, with every term and
> acronym defined. This section assumes that background; the guide supplies it.

Decision: build and verify firmware first; **do not flash yet.** Several units
are available, so sacrificing one is acceptable, but there's no reason to
spend one before the code is ready.

### Build environment — working
`firmware/` is VapeRE's PY32F030 codebase (from `STW2915/firmware`, written
for the Lost Mary MO20000 Pro). It is fully self-contained — CMSIS and the
Puya HAL are vendored, nothing external to fetch.

Only prerequisite: `sudo apt-get install gcc-arm-none-eabi`.

Builds clean out of the box (gcc 13.2.1):
```
FLASH:  23332 B /  64 KB  (35.60%)
RAM:      916 B /   8 KB  (11.18%)
```
The `_close/_lseek/_read/_write is not implemented` linker warnings are
benign newlib syscall stubs, not a problem.

### Chip identity — confirmed three ways
`PY32F030x8`: 64KB flash @ `0x08000000`, 8KB RAM @ `0x20000000`.
- Live SWD read: Cortex-M0+ r0p1, CPUID `0x410cc601`
- Stack pointer read from the running chip (`0x20000aa8`) falls inside the
  8KB RAM region — corroborates the density
- Our dump is exactly 64KB with erased flash after ~33KB
- VapeRE's Makefile targets `PY32F030x8` with `py32f030xx8.ld` — same part

### Why SWD dies when idle — solved, and it's fixable
From VapeRE's `src/main.c`:
```c
// Note that this will not work while using the JTAG debugger.
HAL_PWR_EnterSTOPMode(PWR_LOWPOWERREGULATOR_ON, PWR_STOPENTRY_WFI);
```
**STOP mode disables the debug port.** That is the whole explanation for the
"only responds while charging" behavior — charging keeps the MCU out of STOP.
On wake, that code re-inits PA13 as SWDIO (`GPIO_MODE_AF_PP`), independently
confirming PA13/PA14 = SWDIO/SWCLK.

**Brick-risk mitigation:** custom firmware that never enters STOP mode (or
gates it behind a long delay / held button) keeps SWD alive permanently.
Reflashing then needs no charging dance and no case opening. Whatever we
flash *first* must preserve debug access — that is the one hard rule.

### Pinout from BD0061 (Pulse X Jam) — closest documented sibling
`VapeRE/BD0061/BD0061.pdf`. **Assumed to match the X2; not yet verified.**

USB-C (`J1`, a `USB_C_Receptacle_PowerOnly_6P` — only 6 pins wired):

| USB-C pin | Net |
|-----------|-----|
| A5 / CC1  | SWCLK |
| B5 / CC2  | SWDIO |
| A9        | VBUS |
| A12       | GND |

Exactly the mapping we found empirically. Note `R1`/`R2` are **5.1k on both
CC lines** — so the CC pins carry real USB-C Rd pulldowns *and* SWD on the
same pins. That reconciles the two findings that looked contradictory during
the investigation: the 0.43V charger reading (genuine Rd divider) and working
SWD are both true simultaneously.

MCU (`U2`) connections:

| Pin | Net | Purpose |
|-----|-----|---------|
| PA11 | `LED_CLK` | Display clock |
| PA12 | `LED_DI` | Display data |
| PA15 | `LED_ENABLE` | Gates `Q17` P-MOSFET feeding +BATT to the LED array |
| PA13 / PA14 | SWDIO / SWCLK | Debug |
| PA3 | switch net | 3-position slide switch (`SW1A`/`SW1B`) via resistor divider — likely ADC-read |
| PB4 / PB5 / PB6 | `CHG_EN` / `CHRG` / `STBY` | LP5112 charge IC control + status |
| PF4 | BOOT0 (via `R14` 1K) | Factory bootloader — recovery path once the case is open |

`LED_CLK` + `LED_DI` with no chip select matches this doc's own description
of the X2 panel bus. `CN1` is a 16-pin flex split into "TO LCD?" and "TO LED
ARRAY" groups. Schematic note: *"INSTALL R22 TO USE I2C LED DRIVER INSTEAD
OF SPI."*

**No LDO — the MCU runs directly off +BATT** (`R7` 2Ω + `C5` into VCC), so it
operates at ~3.7–4.2V, not 3.3V. External power for recovery goes to the
+BATT node, and SWD lines swing at battery voltage rather than a clean 3.3V.

### Custom firmware — written, builds, not yet flashed
`fw/` is a fresh bare-metal project (no HAL, no newlib — only the CMSIS
headers from `firmware/`, as headers). Two apps, both small enough to audit
end to end:

| app | flash | RAM | what it does |
|---|---|---|---|
| `beacon` | 480 B | 64 B | proves build → flash → boot → run. Touches no GPIO at all. |
| `shell` | 1080 B | 64 B | executes commands written over SWD, so pin discovery needs no reflash. |

```
cd fw && make both     # guard tests + both apps
```

Everything follows from the rule above — first flash must preserve SWD:

- **Neither app sleeps.** The build audits clean for `wfi`/`wfe`, so STOP mode
  is unreachable. Once flashed, the charging dance goes away entirely and the
  debug port is up whenever the battery is.
- **Clock tree left at reset defaults.** Nothing to misconfigure. The cost is
  not knowing the core frequency up front (`HSIFS` is an option byte: 4 / 8 /
  16 / 22.12 / 24 MHz), so the firmware exports a raw SysTick count and
  `x2.sh alive` measures the real clock against wall-clock instead of guessing.
- **`IWDG` kicked unconditionally**, in the reset handler and every loop.
  Kicking a stopped watchdog is a no-op, so it costs nothing; if the option
  bytes enable IWDG in hardware mode, an un-kicked watchdog would reset
  forever and look exactly like a bad flash.
- **Fault handlers spin instead of resetting** — a crash stays attachable.
- **`beacon` references zero GPIO registers**, verified in the built image.
  This matters because the coil driver pin is still unidentified on the X2,
  and an unknown pin driven high is the one mistake here that starts a fire.

The `shell` guards PA13/PA14 against every pin command and refuses raw writes
to GPIOA's config registers and to the flash controller — so it can neither
drop the debug link nor erase the firmware running it. `CMD_PIN_PULSE` hands
the pin back to input when it finishes, so a discovery sweep can't park an
unknown pin in a driven state. `-Os` inlines all of that out of the
disassembly, so the guards live in a hardware-free `common/guards.h` and are
asserted on the host instead.

**Testing, since none of this can be flashed yet.** The firmware compiles for
x86 under `HOST_TEST` against a fake register map, so the logic runs natively:
**101 assertions** across the guard rules in isolation (30) and the dispatcher
that applies them (71) — register bit math, pulse teardown, argument
validation, boot counting across a warm reset. On top of that
`tools/verify_image.sh` checks the *linked binary* rather than the source: no
`wfi`/`wfe`, beacon pinned at `0x20000000`, MSP at top of RAM, valid reset
vector, and zero GPIO references in `beacon`. `make check` is the gate.

Emulation was considered and mostly declined. Firmadyne-class tools are the
wrong shape — they unpack a squashfs rootfs and boot a QEMU Linux kernel, and
8KB of RAM runs no Linux. Renode could model a PY32-shaped machine properly
and will be worth it for the LED panel's shift-register bus, but for a
480-byte busy loop, modelling the peripherals faithfully costs more than the
host tests did — and a mismodelled peripheral gives confident wrong answers.

**Highest-value untested link: the flash write path itself.** A bare
PY32F030 dev board is about a dollar, has exposed BOOT0, and can be bricked
freely — shaking out pyOCD + the Puya DFP pack there would make the first
write to an actual vape the first boring one.

Protocol: a 64-byte struct pinned at `0x20000000`. Host writes
`cmd`/`arg0`/`arg1`, then bumps `cmd_seq` **last** — the bump is what makes a
command visible, so a half-written command can never run. This stands in for
the serial console we can't have.

### Next step: verify the pinout against the actual X2
Static analysis of the dump was inconclusive — linear disassembly of a
stripped binary interleaves code and data. One useful correction though:
**PY32 puts GPIO at `IOPORT_BASE = 0x50000000`**, not STM32's `0x48000000`
(GPIOA `0x50000000`, GPIOB `0x50000400`, GPIOF `0x50001400`).

`fw/tools/x2.sh gpio A` does this now, and it works **against the stock
firmware** — it's a pure read, same risk class as the dump, no flashing
required. It decodes MODER/PUPDR/IDR/ODR/AFR into a per-pin table. If PA11/PA12
come back as output or SPI-AF and PA15 as a plain output, the X Jam mapping
carries over to the X2.

Rig for it, unchanged: vape seated in the breakout, charger in the female
side, actively charging, probe GND / SWDIO→B5 / SWCLK→A5 held steady.

### Known gap: the display driver
VapeRE's `lcd.c` drives an **ST7789 SPI LCD** (the Lost Mary's panel). The X2
uses a **segmented LED panel on a shift-register bus** — different hardware
entirely. That code is not reusable for the X2 display; the panel driver has
to be written, and it needs the segment map that this doc already flags as an
unknown requiring a bit-walk session.

So the first flashed firmware should probably **not** target the display.
Better first targets: toggle a GPIO observable on a meter, or bring up
VapeRE's UART console. Either proves build → flash → boot works without
depending on unmapped hardware.

### Flashing toolchain — built, using OpenOCD alone
OpenOCD 0.12 has **no PY32 flash driver**, and reads worked only because reads
need no flash algorithm. Rather than take on pyOCD + Puya's DFP pack (and
`pip3`, still not installed), `fw/tools/py32_flash.tcl` drives the flash
controller directly from the host with the core halted — with the CPU stopped
there is no instruction fetch from flash during a program cycle, which is the
whole reason the vendor HAL marks its programming routine `__RAM_FUNC`.

Sequence taken from the vendor HAL, not guessed. Three quirks:
- **Erase is triggered by a dummy write** into the target page, not a start bit.
- **Programming is page-at-a-time**: exactly 32 words (128 B), `CR.PGSTRT` set
  after the 31st, and the final word commits the page.
- **Flash timing registers are mandatory.** `FLASH->TS0..PRETPE` load from a
  per-clock factory block in the info area selected by `RCC_ICSCR.HSI_FS`
  (`_FlashTimmingParam[]`: `0x1FFF0F1C` @4 MHz … `0x1FFF0F6C` @24 MHz). Wrong
  values can damage cells, so the driver refuses to proceed if the block reads
  erased.

Flash geometry: **128-byte pages**, 4 KB sectors, 64 KB total. Unlock keys
`0x45670123` / `0xCDEF89AB`.

**Tested without hardware:** `make flashtest` runs the real driver against a
simulated flash controller inside OpenOCD's own Jim interpreter — 30
assertions covering timing-field extraction, erase/program sequencing, the
write guard, and multi-page writes with a short final page. The simulator
models dummy-write erase, the page buffer, PGSTRT ordering, LOCK enforcement,
and program-can-only-clear-bits.

**Tested on hardware without risk:** the stock image leaves
`0x0800849C–0x0800F000` erased — 27 KB nothing depends on. `flash-selftest`
does unlock → timing → erase → program → verify → re-erase in a page there
**while the vape keeps running normally**. This replaces buying a dev board.
The write guard enforces it: writes are confined to `0x08009000–0x0800F000`
by default, and the stock firmware region and the 128-byte factory calibration
page at `0x0800F000` are refused until `py32_arm_live` is called explicitly.

**Still unproven:** the vendor fills the page buffer from RAM at full speed;
we fill it over SWD at 100 kHz. If the buffer has an undocumented timeout,
programming fails — and `flash-selftest` is exactly where that surfaces,
harmlessly, on a blank page. Fallback is a small RAM-resident stub doing the
32 writes at full clock.

### On getting a serial console without the debug probe
Not really available while the case is sealed. The PY32F030 has no USB
peripheral, and D+/D− go nowhere (`J1` is power-only). The only pins reachable
through the charge port are CC1/CC2 — which are physically PA13/PA14, the SWD
pins. PA14 can be remapped to USART1_TX, so a console over the charge port is
*possible*, but it costs the SWD pins, which are the only recovery path.
Bad trade while sealed; moot once the case is open, where real UART pins,
BOOT0, and direct battery access are all exposed.

---

## Also worth harvesting

- **Battery** — LiPo pouch, roughly 650–1000mAh depending on model.
  **Ships with no protection circuitry.** A short dissipates uncontrolled power;
  real fire and injury risk. To reuse, budget a few dollars per cell for a
  TP4056 module with the **DW01+ protection variant** (the one with the extra
  8-pin IC — buy protected, not bare charger).
  - Check resting voltage first. Discard anything below ~2.5V or visibly puffed.
  - Don't parallel cells from different units with different histories.
- USB-C receptacle and charge IC
- MEMS microphone / pressure sensor (usable as a breath or sound sensor)
- Neodymium magnets (some cartridge designs)

---

## Safety

- **Nitrile gloves and ventilation.** Residual e-liquid is concentrated nicotine
  salt, absorbed through skin. This is the step people skip and regret.
- Pry along the long seam with a plastic tool.
- Remove the cotton/tank assembly **before** bringing a soldering iron near the PCB.
- Unprotected lithium cells: no shorting, no puncturing, no charging unattended.

---

## References

- `https://github.com/sm2013-vapehack/geekbar_pulse_x_screen_reuse` — Pulse X
  display driver sketches and segment map
- `https://github.com/schlae/VapeRE/` — per-board documentation: pinouts, which
  models expose UART test points, Bluetooth presence, heater driver topology.
  **Check whether the X2 board is documented here before reverse engineering
  anything by hand.**
- r/streetlithium — community for this exact hobby
- Jason Gin (ginbot86) and Praetorian teardowns — SWD-on-CC findings for the
  color-TFT vape family

### Known time sinks
- Inadequate ground connection presenting as a dead target. Praetorian lost
  significant time to this exact failure before realizing the improvised ground
  was the problem.
- Firmware updates bricking ST-Link clones (not applicable — using CMSIS-DAP).
