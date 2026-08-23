/* Behavioural tests for the shell's command dispatcher, run on the host
 * against a fake register map (test/fake_hw.h).
 *
 * test_guards.c proves the *rules* are right in isolation. This proves the
 * dispatcher actually applies them, and that the bit math around
 * MODER/PUPDR/BSRR/pinref is correct — the kind of off-by-a-shift bug that
 * would otherwise be found by watching a vape misbehave.
 *
 * The .c is #included rather than linked so the tests can reach the static
 * handlers directly. main() is compiled out by HOST_TEST.
 */
#include <stdio.h>
#include <stdint.h>

#include "fake_hw.h"
#include "beacon.h"

GPIO_TypeDef  fake_gpioa, fake_gpiob, fake_gpiof;
RCC_TypeDef   fake_rcc;
IWDG_TypeDef  fake_iwdg;
SysTick_Type  fake_systick;
unsigned long fake_iwdg_kicks;

beacon_t g_beacon;   /* on hardware this is pinned at 0x20000000 by the linker */

/* Translation for the raw-register path. A handful of real peripheral
 * addresses are backed by fake registers; everything else lands in a scratch
 * word so a stray access is visible rather than fatal. */
static volatile uint32_t mmio_scratch;
volatile uint32_t *host_mmio(uint32_t addr)
{
  switch (addr) {
    case 0x40000000: return &mmio_scratch;              /* generic APB probe */
    case 0x40021034: return &fake_rcc.IOPENR;           /* RCC IOPENR        */
    case 0x50000400: return &fake_gpiob.MODER;          /* GPIOB MODER       */
    case 0x50000414: return &fake_gpiob.ODR;            /* GPIOB ODR         */
    default:         return &mmio_scratch;
  }
}

#include "../common/beacon.c"
#include "../apps/shell/main.c"

static int fails = 0;

static void chk(const char *what, uint32_t got, uint32_t want)
{
  if (got != want) {
    printf("  FAIL  %-54s got 0x%08x want 0x%08x\n", what, got, want);
    fails++;
  } else {
    printf("  ok    %-54s\n", what);
  }
}

/* One command, the way the firmware's loop would run it. */
static uint32_t run(uint32_t cmd, uint32_t a0, uint32_t a1)
{
  g_beacon.cmd = cmd;
  g_beacon.arg0 = a0;
  g_beacon.arg1 = a1;
  g_beacon.cmd_seq++;
  if (g_beacon.cmd_seq != g_beacon.ack_seq) {
    handle_cmd();
    g_beacon.ack_seq = g_beacon.cmd_seq;
  }
  return g_beacon.status;
}

#define PA(n) PINREF(PORT_A, n)
#define PB(n) PINREF(PORT_B, n)

int main(void)
{
  /* Reset leaves PA13/PA14 in alternate-function mode — that is SWD, and it
   * is the state every test below must not disturb. */
  const uint32_t SWD_AF = (2u << 26) | (2u << 28);

  puts("dispatcher basics:");
  fake_hw_reset();
  chk("PING status",              run(CMD_PING, 0, 0),   ST_OK);
  chk("PING ret0 magic",          g_beacon.ret0,         0x00C0FFEE);
  chk("unknown command refused",  run(0xFF, 0, 0),       ST_BAD_CMD);
  chk("ack_seq echoes cmd_seq",   g_beacon.ack_seq,      g_beacon.cmd_seq);

  chk("IOP_EN status",            run(CMD_IOP_EN, 0, 0), ST_OK);
  chk("IOP_EN enables A+B+F",     fake_rcc.IOPENR,
      RCC_IOPENR_GPIOAEN | RCC_IOPENR_GPIOBEN | RCC_IOPENR_GPIOFEN);

  puts("\nSWD pins survive every pin command:");
  fake_hw_reset();
  fake_gpioa.MODER = SWD_AF;
  chk("PIN_MODE PA13 refused",    run(CMD_PIN_MODE, PA(13), 1), ST_PIN_LOCKED);
  chk("PIN_MODE PA14 refused",    run(CMD_PIN_MODE, PA(14), 1), ST_PIN_LOCKED);
  chk("PIN_PULL PA13 refused",    run(CMD_PIN_PULL, PA(13), 2), ST_PIN_LOCKED);
  chk("PIN_WRITE PA13 refused",   run(CMD_PIN_WRITE, PA(13), 1), ST_PIN_LOCKED);
  chk("PIN_READ PA14 refused",    run(CMD_PIN_READ, PA(14), 0), ST_PIN_LOCKED);
  chk("PIN_PULSE PA13 refused",   run(CMD_PIN_PULSE, PA(13), 5), ST_PIN_LOCKED);
  chk("  MODER untouched",        fake_gpioa.MODER,      SWD_AF);
  chk("  BSRR untouched",         fake_gpioa.BSRR,       0);

  puts("\nreconfiguring a neighbour pin does not disturb SWD:");
  fake_hw_reset();
  fake_gpioa.MODER = SWD_AF;
  chk("PA11 -> output",           run(CMD_PIN_MODE, PA(11), 1), ST_OK);
  chk("  PA11 MODER = output",    (fake_gpioa.MODER >> 22) & 3u, 1u);
  chk("  PA13 still AF",          (fake_gpioa.MODER >> 26) & 3u, 2u);
  chk("  PA14 still AF",          (fake_gpioa.MODER >> 28) & 3u, 2u);
  chk("PA12 -> alt-fn",           run(CMD_PIN_MODE, PA(12), 2), ST_OK);
  chk("  PA12 MODER = AF",        (fake_gpioa.MODER >> 24) & 3u, 2u);
  chk("  SWD bits intact",        fake_gpioa.MODER & SWD_AF,     SWD_AF);
  chk("PA15 -> output",           run(CMD_PIN_MODE, PA(15), 1), ST_OK);
  chk("  PA15 MODER = output",    (fake_gpioa.MODER >> 30) & 3u, 1u);

  puts("\npull configuration:");
  fake_hw_reset();
  chk("PB6 -> pull-up",           run(CMD_PIN_PULL, PB(6), 1),  ST_OK);
  chk("  PB6 PUPDR = up",         (fake_gpiob.PUPDR >> 12) & 3u, 1u);
  chk("PB6 -> pull-down",         run(CMD_PIN_PULL, PB(6), 2),  ST_OK);
  chk("  PB6 PUPDR = down",       (fake_gpiob.PUPDR >> 12) & 3u, 2u);
  chk("  no other bits set",      fake_gpiob.PUPDR & ~(3u << 12), 0u);

  puts("\nlevel writes hit the right BSRR half:");
  fake_hw_reset();
  chk("PA15 high",                run(CMD_PIN_WRITE, PA(15), 1), ST_OK);
  chk("  BSRR set bit 15",        fake_gpioa.BSRR,       1u << 15);
  chk("PA15 low",                 run(CMD_PIN_WRITE, PA(15), 0), ST_OK);
  chk("  BSRR reset bit 31",      fake_gpioa.BSRR,       1u << 31);

  puts("\nreads decode the right bit:");
  fake_hw_reset();
  fake_gpioa.IDR = (1u << 3) | (1u << 11);
  chk("PA3 reads high",           run(CMD_PIN_READ, PA(3), 0),  ST_OK);
  chk("  ret0",                   g_beacon.ret0,         1u);
  chk("PA4 reads low",            run(CMD_PIN_READ, PA(4), 0),  ST_OK);
  chk("  ret0",                   g_beacon.ret0,         0u);
  chk("  ret1 = whole IDR",       g_beacon.ret1,         (1u << 3) | (1u << 11));
  fake_gpiob.IDR = 0xBEEF; fake_gpiob.ODR = 0xF00D;
  chk("PORT_READ B",              run(CMD_PORT_READ, PORT_B, 0), ST_OK);
  chk("  ret0 = IDR",             g_beacon.ret0,         0xBEEF);
  chk("  ret1 = ODR",             g_beacon.ret1,         0xF00D);
  chk("GPIO_SNAP A",              run(CMD_GPIO_SNAP, PORT_A, 0), ST_OK);

  puts("\npulse never parks a pin driven (the coil-pin safeguard):");
  fake_hw_reset();
  chk("pulse PA11 x4",            run(CMD_PIN_PULSE, PA(11), 4), ST_OK);
  chk("  count echoed",           g_beacon.ret0,         4u);
  chk("  pin back to input",      (fake_gpioa.MODER >> 22) & 3u, 0u);
  chk("  last write was a reset", fake_gpioa.BSRR,       1u << (11 + 16));
  chk("  watchdog fed in loop",   fake_iwdg_kicks >= 4,  1u);
  fake_hw_reset();
  chk("absurd count clamped",     run(CMD_PIN_PULSE, PA(11), 0xFFFFFFFF), ST_OK);
  chk("  clamped to 100000",      g_beacon.ret0,         100000u);

  puts("\nbad arguments are rejected, not silently applied:");
  fake_hw_reset();
  chk("port 2 (no GPIOC) refused",   run(CMD_PIN_MODE, PINREF(2, 0), 1), ST_BAD_PORT);
  chk("port 9 refused",              run(CMD_PORT_READ, 9, 0),           ST_BAD_PORT);
  chk("pin 16 refused",              run(CMD_PIN_MODE, PA(16), 1),       ST_BAD_PIN);
  chk("pin 255 refused",             run(CMD_PIN_MODE, PA(255), 1),      ST_BAD_PIN);
  chk("  nothing was written",       fake_gpioa.MODER,                   0u);

  puts("\nraw register access:");
  fake_hw_reset();
  mmio_scratch = 0x12345678;
  chk("REG_READ",                   run(CMD_REG_READ, 0x40000000, 0),     ST_OK);
  chk("  ret0",                     g_beacon.ret0,        0x12345678);
  chk("REG_READ unaligned refused", run(CMD_REG_READ, 0x40000001, 0),     ST_ADDR_DENIED);
  chk("REG_WRITE GPIOA MODER denied", run(CMD_REG_WRITE, 0x50000000, ~0u), ST_ADDR_DENIED);
  chk("REG_WRITE GPIOA PUPDR denied", run(CMD_REG_WRITE, 0x5000000C, ~0u), ST_ADDR_DENIED);
  chk("REG_WRITE GPIOA AFRH denied",  run(CMD_REG_WRITE, 0x50000024, ~0u), ST_ADDR_DENIED);
  chk("REG_WRITE FLASH CR denied",    run(CMD_REG_WRITE, 0x40022010, ~0u), ST_ADDR_DENIED);
  chk("REG_WRITE RAM denied",         run(CMD_REG_WRITE, 0x20000000, ~0u), ST_ADDR_DENIED);
  chk("REG_WRITE GPIOB MODER allowed", run(CMD_REG_WRITE, 0x50000400, 0x55), ST_OK);
  chk("  value landed",               fake_gpiob.MODER,     0x55);
  chk("REG_WRITE GPIOA ODR allowed",  run(CMD_REG_WRITE, 0x50000414, 0x99), ST_OK);

  puts("\nbeacon bookkeeping:");
  fake_hw_reset();
  g_beacon.magic = 0;                       /* cold boot: RAM is garbage */
  beacon_init(2);
  chk("magic published",          g_beacon.magic,        BEACON_MAGIC);
  chk("version",                  g_beacon.version,      BEACON_VERSION);
  chk("app_id",                   g_beacon.app_id,       2);
  chk("cold boot count = 1",      g_beacon.boot_count,   1);
  beacon_init(2);                           /* warm reset: RAM survives */
  chk("warm boot count = 2",      g_beacon.boot_count,   2);
  beacon_init(2);
  chk("warm boot count = 3",      g_beacon.boot_count,   3);
  chk("reset flags cleared",      fake_rcc.CSR & RCC_CSR_RMVF, RCC_CSR_RMVF);

  printf("\n%s (%d failure%s)\n", fails ? "FAILED" : "dispatcher behaves",
         fails, fails == 1 ? "" : "s");
  return fails != 0;
}
