/* Safety guards, deliberately kept free of any CMSIS/hardware dependency so
 * they can be compiled and tested on the host (see tools/test_guards.c).
 *
 * These are the rules that stand between a discovery session and an
 * unrecoverable unit, so they get actual tests rather than a code review. */
#ifndef GUARDS_H
#define GUARDS_H

#include <stdint.h>

/* PA13 = SWDIO, PA14 = SWCLK — the only route back into a sealed unit. */
#define SWD_PORT     0            /* GPIOA */
#define SWD_PIN_MASK ((1u << 13) | (1u << 14))

static inline int pin_is_locked(uint32_t port, uint32_t pin)
{
  return (port == SWD_PORT) && ((1u << pin) & SWD_PIN_MASK) != 0u;
}

/* Raw register writes are confined to the peripheral apertures, minus two
 * carve-outs: the flash controller (so the shell can never erase the
 * firmware running it) and GPIOA's config registers (so it can never
 * reconfigure the SWD pins out from under us). GPIOA IDR/ODR/BSRR/BRR stay
 * writable — they move pin levels but cannot change pin mode. */
static inline int addr_writable(uint32_t a)
{
  if (a & 3u) {
    return 0;  /* unaligned */
  }
  if (a >= 0x40022000UL && a < 0x40022400UL) {
    return 0;  /* flash controller — self-erase guard */
  }
  if ((a >= 0x50000000UL && a <= 0x5000000CUL) || a == 0x50000024UL) {
    return 0;  /* GPIOA MODER/OTYPER/OSPEEDR/PUPDR + AFR[1] — SWD guard */
  }
  if (a >= 0x40000000UL && a < 0x40030000UL) {
    return 1;  /* APB + AHB peripherals */
  }
  if (a >= 0x50000000UL && a < 0x50001800UL) {
    return 1;  /* IOPORT */
  }
  return 0;
}

#endif /* GUARDS_H */
