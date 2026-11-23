// orbify/core/CopyCheck: the update step's "is this copy the library file" check (book 1207,
// 11-22: the server called a copy older after it rewrote its own file).
#include <cstdio>

#include "CopyCheck.h"

using orbify::copy::compare;
using orbify::copy::Verdict;

static int passed = 0, failed = 0;
#define CHECK(c)                                              \
  do {                                                        \
    if (c) {                                                  \
      ++passed;                                               \
    } else {                                                  \
      ++failed;                                               \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); \
    }                                                         \
  } while (0)

int main() {
  const char* device = "3dcf3eb3c005357c54c1f8a27320bf98";
  CHECK(compare(device, "3dcf3eb3c005357c54c1f8a27320bf98") == Verdict::Same);
  CHECK(compare(device, "3DCF3EB3C005357C54C1F8A27320BF98") == Verdict::Same);
  CHECK(compare(device, "3dcf3eb3c005357c54c1f8a27320bf99") == Verdict::Differs);
  CHECK(compare(device, "0dcf3eb3c005357c54c1f8a27320bf98") == Verdict::Differs);
  // Missing or malformed on either side: no verdict, so the update goes ahead as before.
  CHECK(compare(device, "") == Verdict::Unknown);
  CHECK(compare(device, nullptr) == Verdict::Unknown);
  CHECK(compare(nullptr, device) == Verdict::Unknown);
  CHECK(compare(device, "3dcf3eb3c005357c54c1f8a27320bf9") == Verdict::Unknown);
  CHECK(compare(device, "3dcf3eb3c005357c54c1f8a27320bf980") == Verdict::Unknown);
  CHECK(compare(device, "3dcf3eb3c005357c54c1f8a27320bfzz") == Verdict::Unknown);
  CHECK(compare("", "") == Verdict::Unknown);
  std::printf("copy-check: %d passed, %d failed\n", passed, failed);
  return failed ? 1 : 0;
}
