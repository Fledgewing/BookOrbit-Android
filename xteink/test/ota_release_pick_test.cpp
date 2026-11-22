// Host test for the "ota-tag-prefix" overlay patch: the firmware updater reads Orbify's
// mixed release list (shared/fixtures/github/orbify-releases.json) and offers only its own
// xteink-v releases. Built by run-host-tests.sh against a CrossInk checkout with the overlay
// applied (it compiles CrossInk's own parser and version code).
#include <cstdio>
#include <cstring>
#include <string>

#include "FirmwareVersion.h"
#include "OtaReleasePick.h"
#include "ReleaseJsonParser.h"

static int passed = 0, failed = 0;
#define CHECK(cond)                                                     \
  do {                                                                  \
    if (cond) {                                                         \
      ++passed;                                                         \
    } else {                                                            \
      ++failed;                                                         \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
    }                                                                   \
  } while (0)

static std::string fixture;
static const char* stem = "firmware-x4-pro";

static bool matchesDevice(const char* name) {
  const size_t n = strlen(stem);
  return strncmp(name, stem, n) == 0 && name[n] == '-' && strstr(name, ".bin") != nullptr;
}

struct Pick {
  ReleaseJsonParser::Release newest{};
  ota_release_pick::Filter filter;
};

static void visit(void* ctx, const ReleaseJsonParser::Release& r) {
  auto* p = static_cast<Pick*>(ctx);
  ota_release_pick::keep(p->newest, r, p->filter);
}

// Feeds the list in small chunks, the way the HTTP client hands it over.
static Pick pick(const char* prefix, bool pre, const char* device = "firmware-x4-pro") {
  stem = device;
  Pick p;
  p.filter = {prefix, pre};
  ReleaseJsonParser parser(matchesDevice, visit, &p);
  for (size_t i = 0; i < fixture.size(); i += 97) parser.feed(fixture.data() + i, std::min<size_t>(97, fixture.size() - i));
  CHECK(parser.isReleaseList());
  return p;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s shared/fixtures/github/orbify-releases.json\n", argv[0]);
    return 2;
  }
  FILE* f = std::fopen(argv[1], "rb");
  if (!f) {
    std::perror(argv[1]);
    return 2;
  }
  char buf[4096];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) fixture.append(buf, n);
  std::fclose(f);

  // Stable channel: the newest xteink-v release that is not a pre-release.
  Pick stable = pick("xteink-v", false);
  CHECK(stable.newest.tagFound);
  CHECK(std::string(stable.newest.tagName) == "xteink-v1.6.1.101+bookorbit.8");
  CHECK(!stable.newest.prerelease);
  CHECK(std::string(stable.newest.firmwareUrl).find("firmware-x4-pro-v1.6.1.101") != std::string::npos);
  CHECK(std::string(ota_release_pick::versionOf(stable.newest.tagName, "xteink-v")) == "1.6.1.101+bookorbit.8");
  // Newer than the last CrossInk-Tailnet build (the bridge) and an older Orbify build.
  CHECK(firmware_version::compare("1.6.1.101+bookorbit.8", "1.6.1.46-bookorbit.8-x4-pro") == 1);
  CHECK(firmware_version::compare("1.6.1.101+bookorbit.8", "1.6.1.101-bookorbit.8-x4-pro") == 0);

  // Release candidates on: the rc2 build, with its full tag (48-byte tagName, no truncation).
  Pick rc = pick("xteink-v", true);
  CHECK(std::string(rc.newest.tagName) == "xteink-v2.0.0.102+bookorbit.1-rc2");
  CHECK(rc.newest.prerelease);

  // The X3/X4 (C3) build matches its own asset in the same release.
  Pick c3 = pick("xteink-v", false, "firmware-x3-x4");
  CHECK(std::string(c3.newest.firmwareUrl).find("firmware-x3-x4-v1.6.1.101") != std::string::npos);

  // Android releases never qualify: no firmware asset, and not the prefix.
  CHECK(ota_release_pick::versionOf("android-v0.7.1", "xteink-v") == nullptr);
  CHECK(ota_release_pick::versionOf("v0.7.0", "xteink-v") == nullptr);
  // Upstream behaviour without a prefix is unchanged.
  CHECK(std::string(ota_release_pick::versionOf("v1.6.1+bookorbit.8", "")) == "v1.6.1+bookorbit.8");

  std::printf("%d passed, %d failed\n", passed, failed);
  return failed == 0 ? 0 : 1;
}
