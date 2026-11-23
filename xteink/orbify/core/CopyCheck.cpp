#include "CopyCheck.h"

namespace orbify::copy {

namespace {
int hexValue(const char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

bool wellFormed(const char* hash) {
  if (!hash) return false;
  int n = 0;
  for (; hash[n]; ++n) {
    if (n >= 32 || hexValue(hash[n]) < 0) return false;
  }
  return n == 32;
}
}  // namespace

Verdict compare(const char* deviceHash, const char* libraryHash) {
  if (!wellFormed(deviceHash) || !wellFormed(libraryHash)) return Verdict::Unknown;
  for (int i = 0; i < 32; ++i) {
    if (hexValue(deviceHash[i]) != hexValue(libraryHash[i])) return Verdict::Differs;
  }
  return Verdict::Same;
}

const char* verdictName(const Verdict verdict) {
  switch (verdict) {
    case Verdict::Same:
      return "same";
    case Verdict::Differs:
      return "differs";
    case Verdict::Unknown:
    default:
      return "unknown";
  }
}

}  // namespace orbify::copy
