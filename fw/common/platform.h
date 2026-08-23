#ifndef PLATFORM_H
#define PLATFORM_H

#include <stdint.h>
#ifdef HOST_TEST
#include "fake_hw.h"
#else
#include "py32f0xx.h"
#endif
#include "guards.h"

/* Kicking a stopped IWDG is a no-op, so this is unconditionally safe. We do
 * it anyway because we cannot yet rule out that the option bytes enable IWDG
 * in hardware mode — if they do, an un-kicked watchdog would reset us in a
 * loop and look exactly like a bricked flash. */
static inline void iwdg_kick(void)
{
  IWDG->KR = 0xAAAAu;
#ifdef HOST_TEST
  extern unsigned long fake_iwdg_kicks;
  fake_iwdg_kicks++;
#endif
}

static inline GPIO_TypeDef *gpio_port(uint32_t port)
{
  switch (port) {
    case 0: return GPIOA;
    case 1: return GPIOB;
    case 5: return GPIOF;
    default: return 0;
  }
}

/* Free-running 24-bit SysTick, no interrupt. We deliberately do not configure
 * the clock tree, so the core frequency is whatever the HSIFS option byte
 * selects (4 / 8 / 16 / 22.12 / 24 MHz). Rather than guess, we export a raw
 * tick count and let the host calibrate it against wall-clock across two
 * reads. */
static inline void systick_start(void)
{
  SysTick->LOAD = 0x00FFFFFFu;
  SysTick->VAL  = 0;
  SysTick->CTRL = SysTick_CTRL_CLKSOURCE_Msk | SysTick_CTRL_ENABLE_Msk;
}

/* Call often enough that a full 24-bit wrap cannot be missed. Worst case
 * (24 MHz) a wrap takes ~0.7 s, and the main loop runs many orders of
 * magnitude faster than that. */
static inline void systick_poll(volatile uint32_t *lo, volatile uint32_t *hi)
{
  if (SysTick->CTRL & SysTick_CTRL_COUNTFLAG_Msk) {
    if (++(*lo) == 0) {
      (*hi)++;
    }
  }
}

/* Raw register access for CMD_REG_READ/CMD_REG_WRITE. On target this is just
 * a cast; under HOST_TEST it routes through a translation the test supplies,
 * so the raw path can be exercised without a 32-bit address space. */
#ifdef HOST_TEST
volatile uint32_t *host_mmio(uint32_t addr);
#define MMIO32(a) host_mmio(a)
#else
#define MMIO32(a) ((volatile uint32_t *) (uintptr_t) (a))
#endif

static inline void delay_loop(volatile uint32_t n)
{
  while (n--) {
    __asm volatile("nop");
  }
}

#endif /* PLATFORM_H */
