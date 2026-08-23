/* Host-side stand-in for the PY32 register map.
 *
 * The CMSIS core headers are full of ARM inline asm and will not compile for
 * x86, so under HOST_TEST the firmware includes this instead of py32f0xx.h.
 * Peripherals become ordinary structs in host memory, which the test can seed
 * before a command and inspect after it.
 *
 * Only what the firmware actually touches is modelled. Register *offsets* are
 * not meaningful here — addr_writable() is tested separately against literal
 * addresses in test_guards.c, so nothing depends on this layout.
 *
 * One honest limitation: BSRR is inert. Real hardware folds it into ODR/IDR;
 * here it just records the last write, so tests assert on BSRR directly.
 */
#ifndef FAKE_HW_H
#define FAKE_HW_H

#include <stdint.h>
#include <string.h>

typedef struct {
  volatile uint32_t MODER, OTYPER, OSPEEDR, PUPDR, IDR, ODR, BSRR, LCKR;
  volatile uint32_t AFR[2];
  volatile uint32_t BRR;
} GPIO_TypeDef;

typedef struct { volatile uint32_t CSR, IOPENR; } RCC_TypeDef;
typedef struct { volatile uint32_t KR; } IWDG_TypeDef;
typedef struct { volatile uint32_t CTRL, LOAD, VAL, CALIB; } SysTick_Type;

#define RCC_CSR_RMVF          (1u << 23)
#define RCC_IOPENR_GPIOAEN    (1u << 0)
#define RCC_IOPENR_GPIOBEN    (1u << 1)
#define RCC_IOPENR_GPIOFEN    (1u << 5)

#define SysTick_CTRL_ENABLE_Msk    (1u << 0)
#define SysTick_CTRL_CLKSOURCE_Msk (1u << 2)
#define SysTick_CTRL_COUNTFLAG_Msk (1u << 16)

extern GPIO_TypeDef  fake_gpioa, fake_gpiob, fake_gpiof;
extern RCC_TypeDef   fake_rcc;
extern IWDG_TypeDef  fake_iwdg;
extern SysTick_Type  fake_systick;
extern unsigned long fake_iwdg_kicks;

#define GPIOA   (&fake_gpioa)
#define GPIOB   (&fake_gpiob)
#define GPIOF   (&fake_gpiof)
#define RCC     (&fake_rcc)
#define IWDG    (&fake_iwdg)
#define SysTick (&fake_systick)

static inline void fake_hw_reset(void)
{
  memset((void *) &fake_gpioa, 0, sizeof fake_gpioa);
  memset((void *) &fake_gpiob, 0, sizeof fake_gpiob);
  memset((void *) &fake_gpiof, 0, sizeof fake_gpiof);
  memset((void *) &fake_rcc, 0, sizeof fake_rcc);
  memset((void *) &fake_iwdg, 0, sizeof fake_iwdg);
  memset((void *) &fake_systick, 0, sizeof fake_systick);
  fake_iwdg_kicks = 0;
}

#endif /* FAKE_HW_H */
