/* Host-side tests for the firmware safety guards.
 *
 * These rules are what keep a pin-discovery session from costing us SWD
 * access or setting a coil off, and -Os inlines them out of the disassembly,
 * so verify the logic here where it can actually be asserted.
 *
 *   cc -o /tmp/tg tools/test_guards.c -Icommon && /tmp/tg
 */
#include <stdio.h>
#include "guards.h"

static int fails = 0;

static void chk(const char *what, int got, int want)
{
  if (got != want) {
    printf("  FAIL  %-52s got %d want %d\n", what, got, want);
    fails++;
  } else {
    printf("  ok    %-52s\n", what);
  }
}

int main(void)
{
  puts("SWD pins are locked against every pin command:");
  chk("PA13 (SWDIO) locked",              pin_is_locked(0, 13), 1);
  chk("PA14 (SWCLK) locked",              pin_is_locked(0, 14), 1);
  chk("PA12 (LED_DI) not locked",         pin_is_locked(0, 12), 0);
  chk("PA15 (LED_ENABLE) not locked",     pin_is_locked(0, 15), 0);
  chk("PA11 (LED_CLK) not locked",        pin_is_locked(0, 11), 0);
  chk("PB13 not locked (port B, not A)",  pin_is_locked(1, 13), 0);
  chk("PF13 not locked (port F, not A)",  pin_is_locked(5, 13), 0);

  puts("\nRaw writes cannot reconfigure GPIOA (would drop SWD):");
  chk("GPIOA MODER   0x50000000 denied",  addr_writable(0x50000000), 0);
  chk("GPIOA OTYPER  0x50000004 denied",  addr_writable(0x50000004), 0);
  chk("GPIOA OSPEEDR 0x50000008 denied",  addr_writable(0x50000008), 0);
  chk("GPIOA PUPDR   0x5000000C denied",  addr_writable(0x5000000C), 0);
  chk("GPIOA AFR[1]  0x50000024 denied",  addr_writable(0x50000024), 0);
  chk("GPIOA BSRR    0x50000018 allowed", addr_writable(0x50000018), 1);
  chk("GPIOA ODR     0x50000014 allowed", addr_writable(0x50000014), 1);

  puts("\nOther ports stay fully writable:");
  chk("GPIOB MODER   0x50000400 allowed", addr_writable(0x50000400), 1);
  chk("GPIOF MODER   0x50001400 allowed", addr_writable(0x50001400), 1);

  puts("\nFirmware cannot erase itself:");
  chk("FLASH ACR     0x40022000 denied",  addr_writable(0x40022000), 0);
  chk("FLASH KEYR    0x40022008 denied",  addr_writable(0x40022008), 0);
  chk("FLASH CR      0x40022010 denied",  addr_writable(0x40022010), 0);
  chk("last of flash range 0x400223FC",   addr_writable(0x400223FC), 0);
  chk("just past it 0x40022400 allowed",  addr_writable(0x40022400), 1);

  puts("\nEverything outside the peripheral apertures is refused:");
  chk("RAM      0x20000000 denied",       addr_writable(0x20000000), 0);
  chk("flash    0x08000000 denied",       addr_writable(0x08000000), 0);
  chk("opt byte 0x1FFF0E80 denied",       addr_writable(0x1FFF0E80), 0);
  chk("SCB      0xE000ED00 denied",       addr_writable(0xE000ED00), 0);
  chk("past IOPORT 0x50001800 denied",    addr_writable(0x50001800), 0);
  chk("unaligned 0x40000001 denied",      addr_writable(0x40000001), 0);
  chk("unaligned 0x40000002 denied",      addr_writable(0x40000002), 0);

  puts("\nLegitimate peripheral writes still work:");
  chk("RCC IOPENR 0x40021034 allowed",    addr_writable(0x40021034), 1);
  chk("APB base   0x40000000 allowed",    addr_writable(0x40000000), 1);

  printf("\n%s (%d failure%s)\n", fails ? "FAILED" : "all guards hold",
         fails, fails == 1 ? "" : "s");
  return fails != 0;
}
