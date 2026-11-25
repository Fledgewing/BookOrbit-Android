// SPDX-License-Identifier: GPL-3.0-or-later
#include "OtaReturn.h"
#include <HalStorage.h>
#include "AppVersion.h"
#include <cstring>
namespace {
constexpr char PATH[] = "/.crosspoint/orbify_ota_return";
}
namespace OrbifyOtaReturn {
void installed() {
  HalFile file;
  if (!Storage.openFileForWrite("ORB", PATH, file)) return;
  const char* version = AppVersion::version();
  file.write(reinterpret_cast<const uint8_t*>(version), strlen(version));
  file.sync();
  file.close();
}
bool pending() {
  HalFile file;
  if (!Storage.exists(PATH) || !Storage.openFileForRead("ORB", PATH, file)) return false;
  char old[64] = {};
  const size_t size = file.fileSize();
  const int n = size > 0 && size < sizeof(old) ? file.read(reinterpret_cast<uint8_t*>(old), size) : 0;
  file.close();
  if (n != static_cast<int>(size) || !size || size >= sizeof(old) || strcmp(old, AppVersion::version()) == 0) {
    Storage.remove(PATH);
    return false;
  }
  return true;
}
bool consume() {
  if (!pending()) return false;
  Storage.remove(PATH);
  return true;
}
}
