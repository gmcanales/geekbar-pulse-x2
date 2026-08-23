/* App 1 — beacon.
 *
 * The minimum-risk first flash. It touches no GPIO at all: every pin is left
 * exactly as reset leaves it, which is the same state the chip is in before
 * any of our code runs. That matters because the coil driver pin is not yet
 * identified on the X2, and an unknown pin driven high is the one mistake
 * here that starts a fire.
 *
 * All it does is prove the chain works — build, flash, boot, run — and keep
 * SWD alive permanently by never sleeping. Verify with tools/beacon.sh.
 */

#include "beacon.h"
#include "platform.h"

#define APP_ID_BEACON 1

void beacon_init(uint32_t app_id);

int main(void)
{
  beacon_init(APP_ID_BEACON);
  systick_start();

  for (;;) {
    iwdg_kick();
    systick_poll(&g_beacon.ticks_lo, &g_beacon.ticks_hi);
    g_beacon.heartbeat++;
  }
}
