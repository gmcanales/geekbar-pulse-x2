# Geek Bar Pulse X2 — salvage and custom firmware

A disposable vape has a rechargeable battery, an OLED, buttons and an ARM
Cortex-M0+ in it. This repo is what happened after taking one apart: SWD
brought up on the stock MCU, the factory firmware dumped and analysed, and
then ~2,400 lines of bare-metal firmware written to run on the part instead.

The device is a **Geek Bar Pulse X2**. The MCU is a **Puya PY32F030x8** —
Cortex-M0+, 64 KB flash, 8 KB RAM. It ships with **no readout protection**,
so nothing here involved defeating a protection mechanism; it was a matter of
finding the pads and talking to the part.

## What's here

| path | what |
|---|---|
| [`fw/`](fw/) | **The firmware.** Bare-metal, no HAL, no newlib — CMSIS headers only. Two apps, a host test suite, and image verification. Start at [`fw/README.md`](fw/README.md). |
| [`geekbar-pulse-x2-salvage.md`](geekbar-pulse-x2-salvage.md) | Teardown, pad locations, SWD bring-up, the flash dump and what is in it. |
| [`firmware-guide.md`](firmware-guide.md) | Working guide: toolchain, flashing, and how not to brick the unit. |
| `firmware/` | Vendored PY32 support (Tube Time, MIT) + ARM CMSIS headers. Not my code — see [LICENSE](LICENSE). |
| `tools/` | `md2html.py`, which renders the guide. |

## The firmware

Two applications, both small enough to read end to end:

| app | flash | RAM | what it does |
|---|---|---|---|
| `beacon` | 480 B (0.73%) | 64 B (0.78%) | Publishes a known structure at a pinned RAM address and counts cold vs warm boots. The minimum thing that proves the part is alive and that resets behave. |
| `shell` | ~1.1 KB (1.67%) | 64 B (0.78%) | A register poke/peek shell over SWD, with a guard layer that refuses writes to anything that could make the unit unrecoverable. |

```
make            # build beacon
make APP=shell  # build the shell
make test       # 101 host assertions, no hardware needed
make check      # host tests + both images + image verification  <- pre-flash gate
make verify     # structural checks on a built image
make disasm     # annotated disassembly
```

### The part worth looking at

The interesting constraint is that a mistake is expensive: flash the wrong
image and the unit may stop answering SWD, at which point recovery means
opening the case and pulling BOOT0. So the design is built around staying
recoverable:

- **The firmware never sleeps.** No `WFI`, no stop mode — `make verify`
  asserts that zero sleep instructions made it into the image. SWD therefore
  stays alive permanently, and a bad flash is just another flash.
- **A guard layer**, not a free-for-all. `shell` refuses register writes that
  could reconfigure the SWD pins, touch the flash controller, or write RAM —
  and the host test suite is mostly assertions that each denial actually
  denies. That is where most of the 101 assertions go.
- **`make check` is a gate, not a report.** Host tests, both images, and
  structural verification (correct initial MSP, reset vector in flash with
  the thumb bit set, image fits in flash) all have to pass before anything
  is written to hardware.

## Build requirements

- `arm-none-eabi-gcc` (tested on 14.2.1) for the firmware
- any host `cc` for `make test`
- `openocd` and an SWD probe for flashing

## The stock firmware image is not in this repo

`x2_flash_dump.bin` is Geek Bar's copyrighted firmware. Dumping a unit you own
is lawful and the steps are in the salvage writeup, but redistributing their
image is not mine to do, so it is absent here.

Everything that reads it still works — dump your own to `x2_flash_dump.bin`
and `fw/tools/x2.sh` will find it, or point `STOCK` at wherever you put it.
The script checks your dump against the sha256 published in the salvage
writeup, so you can confirm it is byte-identical to the image those documents
analyse.

**Dump your unit before you write anything to it.** It is the cheap way back.

## Status

Nothing has been flashed to a unit yet. Both images build and pass
verification; `restore` is written but unproven, and proving it is the next
step, before it is ever actually needed.
