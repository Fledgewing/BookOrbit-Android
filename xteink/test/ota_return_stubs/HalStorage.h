// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <cstring>
#include <string>
struct HalFile {
  inline static std::string bytes;
  size_t fileSize() const { return bytes.size(); }
  size_t write(const uint8_t* data, size_t size) { bytes.assign(reinterpret_cast<const char*>(data), size); return size; }
  int read(uint8_t* data, size_t size) { memcpy(data, bytes.data(), size); return size; }
  void sync() {}
  void close() {}
};
struct StorageStub {
  bool exists(const char*) { return !HalFile::bytes.empty(); }
  bool openFileForRead(const char*, const char*, HalFile&) { return true; }
  bool openFileForWrite(const char*, const char*, HalFile&) { return true; }
  void remove(const char*) { HalFile::bytes.clear(); }
};
inline StorageStub Storage;
