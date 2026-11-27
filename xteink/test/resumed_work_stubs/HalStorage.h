// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
inline std::map<std::string, std::string> files;
inline bool writable = true, synced = true;
struct HalFile {
  std::string path;
  size_t fileSize() const { return files[path].size(); }
  size_t write(const uint8_t* p, size_t n) { files[path].assign(reinterpret_cast<const char*>(p), n); return n; }
  int read(uint8_t* p, size_t n) { n = std::min(n, files[path].size()); memcpy(p, files[path].data(), n); return n; }
  bool sync() { return synced; }
  void close() {}
};
struct StorageStub {
  bool mkdir(const char*) { return writable; }
  bool exists(const char* p) { return files.count(p); }
  bool openFileForRead(const char*, const char* p, HalFile& f) { f.path=p; return files.count(p); }
  bool openFileForWrite(const char*, const char* p, HalFile& f) { if(!writable)return false;f.path=p;files[p].clear();return true; }
  bool remove(const char* p) { return files.erase(p); }
  bool rename(const char* a, const char* b) { if(!files.count(a))return false;files[b]=files[a];files.erase(a);return true; }
};
inline StorageStub Storage;
