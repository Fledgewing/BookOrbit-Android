// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>

namespace ota_release_pick {
// Stored values: false -> Stable; the old true value migrates to Preview (2).
enum class Channel : uint8_t { Stable, RC, Preview };
}
