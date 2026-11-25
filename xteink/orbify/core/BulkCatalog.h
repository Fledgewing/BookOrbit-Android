// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <ArduinoJson.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

namespace orbify::bulk {
// The same engine runs on the reader and in the host/simulator tests. Only the
// storage/transport adapter knows about FreeRTOS, credentials or HalStorage.
struct Files {
  virtual ~Files() = default;
  virtual bool read(const std::string& path, std::string& out) = 0;
  virtual bool write(const std::string& path, const std::string& body) = 0;
  virtual bool erase(const std::string& path) = 0;
  virtual bool exists(const std::string& path) = 0;
  virtual bool room(size_t) { return true; }
  virtual bool readJson(const std::string& path, JsonDocument& out) {
    std::string body; return read(path,body) && !deserializeJson(out,body);
  }
  virtual bool writeJson(const std::string& path, JsonVariantConst value) {
    std::string body; serializeJson(value,body); return write(path,body);
  }
  virtual bool readIds(const std::string& path, void* out, size_t length) {
    std::string body; if(!read(path,body)||body.size()!=length)return false;
    if(length)std::memcpy(out,body.data(),length);return true;
  }
  virtual size_t size(const std::string& path) { std::string body;return read(path,body)?body.size():0; }
  virtual bool writeBytes(const std::string& path,const void* data,size_t length) {
    return write(path,std::string(static_cast<const char*>(data),length));
  }
};
// Numeric catalog indexes may outgrow internal SRAM; the firmware adapter supplies
// a PSRAM allocator. Rich JSON is always one page or one requested window.
template<class T> struct IndexAllocator {
  using value_type = T;
  ArduinoJson::Allocator* arena = nullptr;
  IndexAllocator() = default;
  explicit IndexAllocator(ArduinoJson::Allocator* a) : arena(a) {}
  template<class U> IndexAllocator(const IndexAllocator<U>& a) : arena(a.arena) {}
  T* allocate(size_t n) { return static_cast<T*>(arena ? arena->allocate(n*sizeof(T)) : ::operator new(n*sizeof(T))); }
  void deallocate(T* p, size_t) { if(arena) arena->deallocate(p); else ::operator delete(p); }
  template<class U> bool operator==(const IndexAllocator<U>& a) const { return arena == a.arena; }
  template<class U> bool operator!=(const IndexAllocator<U>& a) const { return !(*this == a); }
};
using Ids = std::vector<int64_t, IndexAllocator<int64_t>>;
struct Stats {
  uint64_t requests = 0, bytes = 0, seriesRequests = 0, rows = 0;
  size_t peakPageBytes = 0, peakJsonBytes = 0;
};
class Catalog {
 public:
  using Fetch = std::function<bool(const std::string&, JsonDocument&)>;
  Catalog(Files& files, ArduinoJson::Allocator* arena = nullptr);
  // identity includes server/account/device/variant. An interrupted generation is
  // resumed only with this exact identity. The published pointer moves last.
  bool refresh(const std::string& identity, const Fetch& fetch,
               const std::function<bool()>& cancelled,
               const std::function<void(unsigned)>& progress, bool fresh = false);
  // False means outside the finite offline inventory or no complete generation.
  bool reply(const std::string& path, JsonDocument& out);
  static bool recognizes(const std::string& path);
  bool patch(int64_t id, JsonObjectConst fields);
  bool active() const;
  Stats stats;
  std::string error;
 private:
  Files& fs;
  ArduinoJson::Allocator* arena;
  std::string generation, previous, identity;
  Fetch fetch;
  std::function<bool()> cancelled;
  std::function<void(unsigned)> progress;
  unsigned shown = 0;
  Ids ids;
  bool ask(const std::string& path, JsonDocument& out);
  bool save(const std::string& path, JsonVariantConst value);
  bool load(const std::string& path, JsonDocument& out);
  bool readIds(const std::string& path, Ids& out);
  bool writeIds(const std::string& path, const Ids& values);
  bool book(int64_t id, JsonDocument& out, const std::string& gen = "");
  bool pages(const std::string& endpoint, const std::string& query, const std::string& key,
             const std::function<bool(JsonObjectConst, size_t)>& row);
  bool manifest();
  bool rich(JsonObjectConst row, bool freshState = false);
  bool metadata();
  bool sources();
  bool derive();
  bool secondary();
  bool seriesNames();
  bool indexes();
  bool members(const std::string& key, int64_t id);
  std::string root(const std::string& gen = "") const;
  std::string record(int64_t id, const std::string& gen = "") const;
  void tick(unsigned value);
};
std::string encode(const std::string& value);
}  // namespace orbify::bulk
