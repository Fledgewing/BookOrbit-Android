// SPDX-License-Identifier: GPL-3.0-or-later
#include <CrossInkTailnetCuts.h>
#if CROSSINK_TAILNET_ORBIFY_MIRROR
#include <HalStorage.h>
#include <OrbifySettingsChoices.h>

#include <cstdlib>
#include <cstring>
#include <mutex>

#include "Settings.h"
namespace OrbifySettings {
namespace {
std::mutex mutex;
std::string path(const char* key) { return std::string("/.crosspoint/orbify/") + key; }
const Choice* choice(const char* key) {
  for (const auto& item : choices)
    if (std::string(item.key) == key) return &item;
  return nullptr;
}
std::string read(const char* key, const Choice& c) {
  char value[32]{};
  if (Storage.exists(path(key).c_str())) Storage.readFileToBuffer(path(key).c_str(), value, sizeof(value));
  for (unsigned i = 0; i < c.count; ++i)
    if (c.values[i] == std::string(value)) return value;
  return c.initial;
}
}  // namespace
std::string get(const char* key) {
  std::lock_guard<std::mutex> guard(mutex);
  const auto* c = choice(key);
  return c ? read(key, *c) : "";
}
const char* title(const char* key) {
  const auto* c = choice(key);
  return c ? c->title : "";
}
std::string label(const char* key) {
  std::lock_guard<std::mutex> guard(mutex);
  const auto* c = choice(key);
  if (!c) return "";
  const auto value = read(key, *c);
  for (unsigned i = 0; i < c->count; ++i)
    if (value == c->values[i]) return c->labels[i];
  return "";
}
void cycle(const char* key) {
  std::lock_guard<std::mutex> guard(mutex);
  const auto* c = choice(key);
  if (!c) return;
  const auto value = read(key, *c);
  for (unsigned i = 0; i < c->count; ++i)
    if (value == c->values[i]) {
      Storage.mkdir("/.crosspoint/orbify");
      const auto tmp = path(key) + ".tmp";
      HalFile f;
      if (!Storage.openFileForWrite("ORB", tmp, f)) return;
      const char* next = c->values[(i + 1) % c->count];
      const bool ok = f.write(next, strlen(next)) == strlen(next) && f.sync();
      f.close();
      if (ok) {
        Storage.remove(path(key).c_str());
        Storage.rename(tmp.c_str(), path(key).c_str());
      }
      return;
    }
}
uint64_t storageBytes() { return strtoull(get("storage_limit_mb").c_str(), nullptr, 10) * 1024ULL * 1024; }
unsigned idleSeconds() { return strtoul(get("wifi_idle_min").c_str(), nullptr, 10) * 60; }
}  // namespace OrbifySettings
#endif
