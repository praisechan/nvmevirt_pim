// SPDX-License-Identifier: GPL-2.0-only

#ifndef _NVMEVIRT_INFLASH_PIM_H
#define _NVMEVIRT_INFLASH_PIM_H

#define INFLASH_PIM_OPCODE 0x91
#define INFLASH_PIM_MAX_PAGES 512
#define COMPUTE_RESULT_SIZE 64

/* Upper bound on NAND channels, used to size the device-side per-channel
 * sensed histogram that verifies even FTL-aware distribution. */
#define INFLASH_PIM_MAX_CHANNELS 64

#endif
