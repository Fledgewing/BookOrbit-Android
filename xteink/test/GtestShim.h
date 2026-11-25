#pragma once
// The few GoogleTest macros a test written for CrossInk's CTest suite uses, on top of
// TestSupport.h's counters, so such a test runs in run-host-tests.sh unchanged apart from its
// includes. EXPECT_* count and go on; ASSERT_* count and leave the test. Each TEST registers
// itself; GTEST_SHIM_MAIN(name) runs them all and reports.
#include <cmath>
#include <cstring>
#include <vector>

#include "TestSupport.h"

namespace gtest_shim {
struct Case {
  const char* name;
  void (*fn)();
};
inline std::vector<Case>& cases() {
  static std::vector<Case> all;
  return all;
}
struct Add {
  Add(const char* name, void (*fn)()) { cases().push_back({name, fn}); }
};
}  // namespace gtest_shim

#define TEST(suite, name)                                                         \
  static void suite##_##name();                                                   \
  static gtest_shim::Add suite##_##name##_add(#suite "." #name, &suite##_##name); \
  static void suite##_##name()

#define EXPECT_TRUE(c) CHECK(c)
#define EXPECT_FALSE(c) CHECK(!(c))
#define EXPECT_EQ(a, b) CHECK((a) == (b))
#define EXPECT_NE(a, b) CHECK((a) != (b))
#define EXPECT_NEAR(a, b, tol) CHECK(std::fabs(static_cast<double>(a) - static_cast<double>(b)) <= (tol))
#define EXPECT_STREQ(a, b) CHECK(std::strcmp((a), (b)) == 0)
#define GTEST_SHIM_ASSERT(c)                    \
  do {                                          \
    const int before_ = test_support::failed;   \
    CHECK(c);                                   \
    if (test_support::failed != before_) return; \
  } while (0)
#define ASSERT_TRUE(c) GTEST_SHIM_ASSERT(c)
#define ASSERT_NE(a, b) GTEST_SHIM_ASSERT((a) != (b))

#define GTEST_SHIM_MAIN(suite)                                    \
  int main() {                                                    \
    for (const gtest_shim::Case& c : gtest_shim::cases()) c.fn(); \
    return report(suite);                                         \
  }
