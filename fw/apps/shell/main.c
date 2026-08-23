/* App 2 — SWD-poke shell.
 *
 * Turns the beacon into a remote-control shell driven entirely over SWD: the
 * host writes cmd/arg0/arg1 into RAM, bumps cmd_seq, and reads back ret0/ret1
 * and status. No reflash per experiment.
 *
 * This is what makes the two open hardware questions tractable — verifying
 * that the BD0061 (Pulse X Jam) pin mapping actually carries over to the X2,
 * and bit-walking the segment map of the LED panel. Both are dozens of small
 * experiments, and a build/flash cycle for each would be miserable.
 *
 * Two hard guarantees, both enforced below rather than by convention:
 *
 *   1. PA13/PA14 cannot be touched. Every pin command refuses them
 *      (ST_PIN_LOCKED), and the raw-register escape hatch refuses writes to
 *      GPIOA's config registers outright. Losing SWD on a sealed unit means
 *      losing the unit.
 *
 *   2. CMD_PIN_PULSE always returns the pin to input when it finishes, so a
 *      discovery sweep cannot leave an unidentified pin — possibly the coil
 *      driver — parked in a driven state.
 */

#include "beacon.h"
#include "platform.h"

#define APP_ID_SHELL 2

void beacon_init(uint32_t app_id);

static void field2_write(volatile uint32_t *reg, uint32_t pin, uint32_t val)
{
  uint32_t shift = pin * 2u;
  *reg = (*reg & ~(3u << shift)) | ((val & 3u) << shift);
}

/* Resolve a pinref into port/pin, rejecting bad ports, out-of-range pins and
 * the SWD pair. Returns 0 and sets *st on refusal. */
static GPIO_TypeDef *resolve(uint32_t pinref, uint32_t *pin_out, uint32_t *st)
{
  uint32_t port = (pinref >> 8) & 0xFFu;
  uint32_t pin  = pinref & 0xFFu;
  GPIO_TypeDef *g = gpio_port(port);

  if (!g)                        { *st = ST_BAD_PORT;   return 0; }
  if (pin > 15u)                 { *st = ST_BAD_PIN;    return 0; }
  if (pin_is_locked(port, pin))  { *st = ST_PIN_LOCKED; return 0; }

  *pin_out = pin;
  return g;
}

static void handle_cmd(void)
{
  uint32_t cmd  = g_beacon.cmd;
  uint32_t arg0 = g_beacon.arg0;
  uint32_t arg1 = g_beacon.arg1;
  uint32_t st   = ST_OK;
  uint32_t r0 = 0, r1 = 0;
  uint32_t pin;
  GPIO_TypeDef *g;

  switch (cmd) {
    case CMD_NOP:
      break;

    case CMD_PING:
      r0 = 0x00C0FFEEUL;
      r1 = g_beacon.boot_count;
      break;

    case CMD_IOP_EN:
      RCC->IOPENR |= RCC_IOPENR_GPIOAEN | RCC_IOPENR_GPIOBEN | RCC_IOPENR_GPIOFEN;
      r0 = RCC->IOPENR;
      break;

    case CMD_PIN_MODE:
      if ((g = resolve(arg0, &pin, &st)) != 0) {
        field2_write(&g->MODER, pin, arg1);
        r0 = g->MODER;
      }
      break;

    case CMD_PIN_PULL:
      if ((g = resolve(arg0, &pin, &st)) != 0) {
        field2_write(&g->PUPDR, pin, arg1);
        r0 = g->PUPDR;
      }
      break;

    case CMD_PIN_WRITE:
      if ((g = resolve(arg0, &pin, &st)) != 0) {
        g->BSRR = arg1 ? (1u << pin) : (1u << (pin + 16u));
        r0 = g->ODR;
      }
      break;

    case CMD_PIN_READ:
      if ((g = resolve(arg0, &pin, &st)) != 0) {
        r0 = (g->IDR >> pin) & 1u;
        r1 = g->IDR;
      }
      break;

    case CMD_PORT_READ:
      if ((g = gpio_port(arg0)) != 0) {
        r0 = g->IDR;
        r1 = g->ODR;
      } else {
        st = ST_BAD_PORT;
      }
      break;

    case CMD_PIN_PULSE:
      if ((g = resolve(arg0, &pin, &st)) != 0) {
        uint32_t n = arg1 > 100000u ? 100000u : arg1;
        field2_write(&g->MODER, pin, 1u);        /* output */
        for (uint32_t i = 0; i < n; i++) {
          g->BSRR = (1u << pin);
          delay_loop(200);
          g->BSRR = (1u << (pin + 16u));
          delay_loop(200);
          iwdg_kick();
        }
        /* Leave low, then hand the pin back to input — never park an
         * unidentified pin in a driven state. */
        g->BSRR = (1u << (pin + 16u));
        field2_write(&g->MODER, pin, 0u);
        r0 = n;
      }
      break;

    case CMD_REG_READ:
      if (arg0 & 3u) {
        st = ST_ADDR_DENIED;
      } else {
        r0 = *MMIO32(arg0);
        r1 = arg0;
      }
      break;

    case CMD_REG_WRITE:
      if (!addr_writable(arg0)) {
        st = ST_ADDR_DENIED;
      } else {
        *MMIO32(arg0) = arg1;
        r0 = *MMIO32(arg0);
      }
      break;

    case CMD_GPIO_SNAP:
      if ((g = gpio_port(arg0)) != 0) {
        r0 = g->MODER;
        r1 = g->PUPDR;
      } else {
        st = ST_BAD_PORT;
      }
      break;

    default:
      st = ST_BAD_CMD;
      break;
  }

  g_beacon.ret0   = r0;
  g_beacon.ret1   = r1;
  g_beacon.status = st;
}

#ifndef HOST_TEST
int main(void)
{
  beacon_init(APP_ID_SHELL);
  systick_start();

  for (;;) {
    iwdg_kick();
    systick_poll(&g_beacon.ticks_lo, &g_beacon.ticks_hi);
    g_beacon.heartbeat++;

    /* The host bumps cmd_seq last, after cmd/arg0/arg1 are in place, so a
     * mismatch means a fully-written command is waiting. */
    uint32_t seq = g_beacon.cmd_seq;
    if (seq != g_beacon.ack_seq) {
      handle_cmd();
      g_beacon.ack_seq = seq;
    }
  }
}
#endif /* HOST_TEST */
