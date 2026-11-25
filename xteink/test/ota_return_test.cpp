// SPDX-License-Identifier: GPL-3.0-or-later
#include <AppVersion.h>
#include <HalStorage.h>
#include "OtaReturn.h"
#include <cassert>
#include <cstdio>
#define CHECK(value) assert(value)
int main() {
  CHECK(!OrbifyOtaReturn::pending());
  OrbifyOtaReturn::installed();
  CHECK(HalFile::bytes == AppVersion::version());
  // Simulate the firmware reboot: SD survives; the application version changes.
  AppVersion::current = "2.0.0.2";
  CHECK(OrbifyOtaReturn::pending());
  CHECK(OrbifyOtaReturn::consume());
  CHECK(!OrbifyOtaReturn::pending() && !OrbifyOtaReturn::consume());
  // A rollback / same-version reboot must not claim a successful update.
  OrbifyOtaReturn::installed();
  CHECK(!OrbifyOtaReturn::pending() && HalFile::bytes.empty());
  HalFile::bytes.assign(65, 'x');
  CHECK(!OrbifyOtaReturn::pending());
  puts("ota-return: passed");
  return 0;
}
