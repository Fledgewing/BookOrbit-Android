// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
namespace OrbifyOtaReturn {
// A one-shot SD marker survives firmware changes, unlike RTC addresses.
void installed();
bool pending();
bool consume();
}
