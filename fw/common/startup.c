/* Minimal startup for PY32F030x8. No newlib, no HAL, no SystemInit.
 *
 * Design rules, all of them in service of never losing SWD:
 *   - The clock tree is left at its reset default. Fewer moving parts, and
 *     nothing that can leave the core running from a dead oscillator.
 *   - No sleep, no STOP, no WFI anywhere in this firmware. STOP mode is what
 *     kills the debug port on the stock firmware.
 *   - Fault handlers spin instead of resetting, so a crash leaves the core
 *     halted-but-attachable rather than in a reset loop.
 */

#include <stdint.h>
#include "py32f0xx.h"
#include "beacon.h"
#include "platform.h"

extern uint32_t __etext, __data_start__, __data_end__, __bss_start__, __bss_end__;
extern uint32_t __StackTop;

int main(void);

/* Not in .bss (see linker script): startup must not clear it, so boot_count
 * survives a warm reset. */
__attribute__((section(".beacon"), used)) beacon_t g_beacon;

void Reset_Handler(void);

/* Spin rather than reset — keeps the core attachable for a post-mortem. */
static void Fault_Handler(void) { for (;;) { iwdg_kick(); } }
static void Default_Handler(void) { for (;;) { iwdg_kick(); } }

void NMI_Handler(void)       __attribute__((weak, alias("Default_Handler")));
void HardFault_Handler(void) __attribute__((weak, alias("Fault_Handler")));
void SVC_Handler(void)       __attribute__((weak, alias("Default_Handler")));
void PendSV_Handler(void)    __attribute__((weak, alias("Default_Handler")));
void SysTick_Handler(void)   __attribute__((weak, alias("Default_Handler")));

__attribute__((section(".vectors"), used))
void (* const g_vectors[16 + 32])(void) = {
  (void (*)(void)) &__StackTop,
  Reset_Handler,
  NMI_Handler,
  HardFault_Handler,
  0, 0, 0, 0, 0, 0, 0,
  SVC_Handler,
  0, 0,
  PendSV_Handler,
  SysTick_Handler,
  /* 32 external IRQs, none enabled by this firmware */
  [16 ... 47] = Default_Handler,
};

void Reset_Handler(void)
{
  /* Before anything else. If the option bytes put IWDG in hardware mode it is
   * already counting down by the time we get here. */
  iwdg_kick();

  /* Vectors live in flash. The chip aliases flash to 0x00000000 on a normal
   * boot, but set this explicitly so we are correct either way. */
  SCB->VTOR = (uint32_t) &g_vectors;

  for (uint32_t *src = &__etext, *dst = &__data_start__; dst < &__data_end__; ) {
    *dst++ = *src++;
  }
  for (uint32_t *dst = &__bss_start__; dst < &__bss_end__; ) {
    *dst++ = 0;
  }
  /* .beacon is intentionally skipped by both loops above. */

  main();

  for (;;) { iwdg_kick(); }
}
