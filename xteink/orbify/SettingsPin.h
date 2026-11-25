// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of BookSync's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#pragma once

#include <CrossInkTailnetCuts.h>

#include <cstdint>
#include <functional>

class Activity;

// CrossInk-Tailnet settings PIN (hooked in by the settings-pin patch). An optional 4-digit PIN that keeps
// Settings, firmware updates, network and Tailscale setup and the web settings out of
// reach until it is entered. A kid-proof lock, not security: the settings files are on the
// SD card. The PIN lives in NVS as a salted SHA-256, so deleting the settings file keeps it;
// /.crossink/unlock-settings on the card clears it at the next boot.
//
// Unlocked lasts while a PIN-gated screen is open (ActivityManager relocks once none is)
// and never past sleep. It survives the silent restarts into a network boot, so a screen
// that restarts into one (OTA, Tailscale login) does not ask again.
namespace SettingsPin {

constexpr int DIGITS = 4;

#if CROSSINK_TAILNET_SETTINGS_PIN
// Boot, after the SD card and settings are up: the recovery file, the restart carry-over,
// and hidden files kept off while locked.
void boot();

bool isSet();
// A PIN is set and has not been entered since the last lock.
bool locked();
void unlock();
// Back to locked; hidden files go off again (in RAM; the file keeps the user's choice).
void relock();

bool verify(const uint8_t (&digits)[DIGITS]);
bool store(const uint8_t (&digits)[DIGITS]);
void clear();

// For an action inside a screen that is not gated as a whole (adding a WiFi network): calls
// `done(true)` at once when unlocked, else once the PIN prompt over `from` closes, with
// whether the right PIN was entered. It does not unlock Settings.
void ask(Activity& from, std::function<void(bool granted)> done);
#else
constexpr bool locked() { return false; }
#endif

}  // namespace SettingsPin
