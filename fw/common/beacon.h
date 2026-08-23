/* Beacon: a fixed-address struct at 0x20000000 that the host reads (and for
 * the shell app, writes) over SWD. It is the entire debug channel — there is
 * no UART available while the case is sealed, so this stands in for one. */
#ifndef BEACON_H
#define BEACON_H

#include <stdint.h>

#define BEACON_ADDR   0x20000000UL
#define BEACON_MAGIC  0x32584247UL  /* "GBX2" little-endian */

/* Bumped whenever the layout below changes, so a host script reading a stale
 * build can tell. */
#define BEACON_VERSION 1

/* --- shell commands (app "shell" only; app "beacon" ignores all of these) --- */
#define CMD_NOP        0x00
#define CMD_PING       0x01  /* -> ret0 = 0x00C0FFEE                          */
#define CMD_IOP_EN     0x02  /* enable GPIOA/B/F clocks                       */
#define CMD_PIN_MODE   0x03  /* arg0 = pinref, arg1 = 0 in / 1 out / 2 af / 3 analog */
#define CMD_PIN_PULL   0x04  /* arg0 = pinref, arg1 = 0 none / 1 up / 2 down  */
#define CMD_PIN_WRITE  0x05  /* arg0 = pinref, arg1 = 0 / 1                   */
#define CMD_PIN_READ   0x06  /* arg0 = pinref -> ret0 = level                 */
#define CMD_PORT_READ  0x07  /* arg0 = port   -> ret0 = IDR, ret1 = ODR       */
#define CMD_PIN_PULSE  0x08  /* arg0 = pinref, arg1 = count (toggle pairs)    */
#define CMD_REG_READ   0x09  /* arg0 = addr   -> ret0 = *(u32*)addr           */
#define CMD_REG_WRITE  0x0A  /* arg0 = addr, arg1 = value (allowlisted ranges)*/
#define CMD_GPIO_SNAP  0x0B  /* arg0 = port -> ret0/ret1 = MODER / PUPDR      */

/* pinref = (port << 8) | pin ; port 0 = A, 1 = B, 5 = F  (matches GPIOx_BASE stride) */
#define PINREF(port, pin) (((port) << 8) | (pin))
#define PORT_A 0
#define PORT_B 1
#define PORT_F 5

/* --- status codes --- */
#define ST_OK          0x00
#define ST_BAD_CMD     0x01
#define ST_BAD_PORT    0x02
#define ST_BAD_PIN     0x03
#define ST_PIN_LOCKED  0x04  /* refused: pin is SWDIO/SWCLK */
#define ST_ADDR_DENIED 0x05  /* refused: write outside the allowlist */

typedef struct {
  volatile uint32_t magic;        /* +0x00  BEACON_MAGIC once running       */
  volatile uint32_t version;      /* +0x04  BEACON_VERSION                  */
  volatile uint32_t app_id;       /* +0x08  1 = beacon, 2 = shell           */
  volatile uint32_t boot_count;   /* +0x0C  survives warm reset             */
  volatile uint32_t heartbeat;    /* +0x10  ++ every main-loop pass         */
  volatile uint32_t ticks_lo;     /* +0x14  free-running SysTick, low word  */
  volatile uint32_t ticks_hi;     /* +0x18  ...high word                    */
  volatile uint32_t reset_cause;  /* +0x1C  RCC_CSR latched at boot         */
  volatile uint32_t cmd;          /* +0x20  host writes                     */
  volatile uint32_t cmd_seq;      /* +0x24  host increments to fire         */
  volatile uint32_t ack_seq;      /* +0x28  fw echoes when done             */
  volatile uint32_t arg0;         /* +0x2C                                  */
  volatile uint32_t arg1;         /* +0x30                                  */
  volatile uint32_t ret0;         /* +0x34                                  */
  volatile uint32_t ret1;         /* +0x38                                  */
  volatile uint32_t status;       /* +0x3C  ST_*                            */
} beacon_t;

extern beacon_t g_beacon;

#endif /* BEACON_H */
