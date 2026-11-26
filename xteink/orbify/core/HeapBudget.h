// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#define BOOKSYNC_WIFI_FREE (60 * 1024u)
#define BOOKSYNC_WIFI_BLOCK (24 * 1024u)
#define BOOKSYNC_CATALOG_FREE (24 * 1024u)
#define BOOKSYNC_CATALOG_BLOCK (4 * 1024u)
#ifdef __cplusplus
namespace orbify::heap {
// Internal, byte-addressable RAM only: PSRAM cannot satisfy the PHY/DMA needs.
constexpr uint32_t WIFI_FREE = BOOKSYNC_WIFI_FREE, WIFI_BLOCK = BOOKSYNC_WIFI_BLOCK;
constexpr uint32_t CATALOG_FREE = BOOKSYNC_CATALOG_FREE, CATALOG_BLOCK = BOOKSYNC_CATALOG_BLOCK;
inline bool wifiFits(uint32_t free, uint32_t largest) {
  return free >= WIFI_FREE && largest >= WIFI_BLOCK;
}
inline bool catalogFits(uint32_t free, uint32_t largest) {
  return free >= CATALOG_FREE && largest >= CATALOG_BLOCK;
}
}  // namespace orbify::heap

#endif
