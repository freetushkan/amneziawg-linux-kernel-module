// SPDX-License-Identifier: GPL-2.0
/*
 * Per-peer protocol fallback for older AmneziaWG versions and WireGuard.
 * See awg_fallback.h for the overview.
 */

#include "awg_fallback.h"

#include <linux/moduleparam.h>

unsigned int awg_compat_mode = AWG_COMPAT_ON;
module_param_named(compat, awg_compat_mode, uint, 0644);
MODULE_PARM_DESC(compat, "Fallback for peers running older protocol versions: 0 - off (upstream behaviour), 1 - detect AmneziaWG 1.x/2.x peers (default), 2 - also probe vanilla WireGuard when initiating to an unknown peer");
