// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Fledgewing. Part of BookSync's Xteink firmware code (xteink/README.md "License"):
// it builds into CrossInk-Bookorbit, so it is GPL-3.0-or-later, unlike the MIT overlay around it.
#include "SettingsPin.h"

#if CROSSINK_TAILNET_SETTINGS_PIN

#include <HalStorage.h>
#include <Logging.h>
#include <esp_attr.h>
#include <esp_random.h>
#include <esp_system.h>
#include <mbedtls/sha256.h>
#include <nvs.h>

#include <cstring>
#include <memory>

#include "CrossPointSettings.h"
#include "activities/Activity.h"
#include "SettingsPinActivity.h"

extern GfxRenderer renderer;
extern MappedInputManager mappedInputManager;

namespace SettingsPin {
namespace {
constexpr const char* NVS_NAMESPACE = "crossink_pin";
constexpr const char* NVS_KEY = "v1";
constexpr const char* RECOVERY_FILE = "/.crossink/unlock-settings";
constexpr uint32_t UNLOCKED_MAGIC = 0x50494E55;  // "PINU"

struct Record {
  uint8_t salt[16];
  uint8_t hash[32];
};

// Kept through software restarts (network boots); boot() drops it after any other reset.
RTC_NOINIT_ATTR uint32_t unlockedMagic;
int8_t setCache = -1;  // -1 = not read yet

bool hashPin(const uint8_t (&salt)[16], const uint8_t (&digits)[DIGITS], uint8_t (&out)[32]) {
  uint8_t input[sizeof(salt) + DIGITS];
  memcpy(input, salt, sizeof(salt));
  for (int i = 0; i < DIGITS; i++) input[sizeof(salt) + i] = static_cast<uint8_t>('0' + digits[i]);
  return mbedtls_sha256(input, sizeof(input), out, 0) == 0;
}

bool readRecord(Record& record) {
  nvs_handle_t handle;
  if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &handle) != ESP_OK) return false;
  size_t length = sizeof(record);
  const bool ok = nvs_get_blob(handle, NVS_KEY, &record, &length) == ESP_OK && length == sizeof(record);
  nvs_close(handle);
  return ok;
}
}  // namespace

bool isSet() {
  if (setCache < 0) {
    Record record;
    setCache = readRecord(record) ? 1 : 0;
  }
  return setCache == 1;
}

bool locked() { return isSet() && unlockedMagic != UNLOCKED_MAGIC; }

void unlock() { unlockedMagic = UNLOCKED_MAGIC; }

void relock() {
  if (unlockedMagic != UNLOCKED_MAGIC) return;
  unlockedMagic = 0;
  if (isSet() && SETTINGS.showHiddenFiles) {
    LOG_INF("PIN", "Settings locked: hidden files hidden again");
    SETTINGS.showHiddenFiles = 0;
  } else {
    LOG_INF("PIN", "Settings locked");
  }
}

bool verify(const uint8_t (&digits)[DIGITS]) {
  Record record;
  uint8_t hash[32];
  if (!readRecord(record) || !hashPin(record.salt, digits, hash)) return false;
  uint8_t diff = 0;
  for (size_t i = 0; i < sizeof(hash); i++) diff |= hash[i] ^ record.hash[i];
  return diff == 0;
}

bool store(const uint8_t (&digits)[DIGITS]) {
  Record record;
  esp_fill_random(record.salt, sizeof(record.salt));
  if (!hashPin(record.salt, digits, record.hash)) return false;
  nvs_handle_t handle;
  if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) return false;
  const bool ok = nvs_set_blob(handle, NVS_KEY, &record, sizeof(record)) == ESP_OK && nvs_commit(handle) == ESP_OK;
  nvs_close(handle);
  setCache = -1;
  LOG_INF("PIN", "Settings PIN %s", ok ? "set" : "could not be saved");
  return ok;
}

void clear() {
  nvs_handle_t handle;
  if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &handle) == ESP_OK) {
    nvs_erase_key(handle, NVS_KEY);
    nvs_commit(handle);
    nvs_close(handle);
  }
  setCache = 0;
  LOG_INF("PIN", "Settings PIN removed");
}

void boot() {
  if (esp_reset_reason() != ESP_RST_SW) unlockedMagic = 0;
  if (Storage.exists(RECOVERY_FILE)) {
    clear();
    const bool removed = Storage.remove(RECOVERY_FILE);
    LOG_INF("PIN", "Recovery file %s found: settings PIN cleared%s", RECOVERY_FILE,
            removed ? ", file deleted" : "; could not delete the file");
  }
  if (locked() && SETTINGS.showHiddenFiles) SETTINGS.showHiddenFiles = 0;
  LOG_INF("PIN", "Settings PIN %s", !isSet() ? "not set" : locked() ? "set, locked" : "set, unlocked");
}

void ask(Activity& from, std::function<void(bool)> done) {
  if (!locked()) {
    done(true);
    return;
  }
  from.startActivityForResult(
      std::make_unique<SettingsPinActivity>(renderer, mappedInputManager, SettingsPinActivity::Mode::Verify),
      [done = std::move(done)](const ActivityResult& result) { done(!result.isCancelled); });
}

}  // namespace SettingsPin

#endif  // CROSSINK_TAILNET_SETTINGS_PIN
