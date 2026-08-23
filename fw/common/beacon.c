#include "beacon.h"
#include "platform.h"

void beacon_init(uint32_t app_id)
{
  /* .beacon is NOLOAD and skipped by startup, so RAM contents survive a warm
   * reset. A matching magic therefore means "we have booted before". */
  uint32_t boots = (g_beacon.magic == BEACON_MAGIC) ? g_beacon.boot_count + 1 : 1;

  g_beacon.magic       = BEACON_MAGIC;
  g_beacon.version     = BEACON_VERSION;
  g_beacon.app_id      = app_id;
  g_beacon.boot_count  = boots;
  g_beacon.heartbeat   = 0;
  g_beacon.ticks_lo    = 0;
  g_beacon.ticks_hi    = 0;
  g_beacon.reset_cause = RCC->CSR;
  g_beacon.cmd         = CMD_NOP;
  g_beacon.cmd_seq     = 0;
  g_beacon.ack_seq     = 0;
  g_beacon.arg0        = 0;
  g_beacon.arg1        = 0;
  g_beacon.ret0        = 0;
  g_beacon.ret1        = 0;
  g_beacon.status      = ST_OK;

  /* Clear the latched reset flags so the next boot reports a fresh cause
   * rather than the accumulated history. */
  RCC->CSR |= RCC_CSR_RMVF;
}
