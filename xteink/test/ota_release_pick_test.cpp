// Host test for the "ota-tag-prefix" overlay patch: the firmware updater reads BookSync's
// mixed release list (shared/fixtures/github/booksync-releases.json) and offers only its own
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

// Feeds the list in small chunks, the way the HTTP client hands it over. retried: a first
// attempt is cut off part-way (the X3's timed-out check), then the updater resets the parser and
// the pick and reads the whole list again (OtaUpdater's retry, patch 0030).
static Pick pick(const char* prefix, bool pre, const char* device = "firmware-x4-pro", size_t chunk = 97,
                 bool retried = false, const std::string* body = nullptr) {
  const std::string& text = body ? *body : fixture;
  stem = device;
  Pick p;
  p.filter = {prefix, pre};
  ReleaseJsonParser parser(matchesDevice, visit, &p);
  if (retried) {
    const size_t cut = text.size() * 2 / 3;
    for (size_t i = 0; i < cut; i += chunk) parser.feed(text.data() + i, std::min<size_t>(chunk, cut - i));
    parser.reset();
    p.newest = ReleaseJsonParser::Release{};
  }
  for (size_t i = 0; i < text.size(); i += chunk) parser.feed(text.data() + i, std::min<size_t>(chunk, text.size() - i));
  CHECK(parser.isReleaseList());
  return p;
}

static std::string readFile(const char* path) {
  std::string out;
  FILE* f = std::fopen(path, "rb");
  if (!f) return out;
  char buf[4096];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
  std::fclose(f);
  return out;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s shared/fixtures/github/booksync-releases.json\n", argv[0]);
    return 2;
  }
  // @fixture github/booksync-releases.json
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
  // Newer than the last CrossInk-Tailnet build (the bridge) and an older BookSync build.
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

  // Any chunking, and a retry after a cut-off first read, pick the same release.
  for (const size_t chunk : {size_t(1), size_t(7), size_t(4096)}) {
    for (const bool retried : {false, true}) {
      CHECK(std::string(pick("xteink-v", true, "firmware-x3-x4", chunk, retried).newest.tagName) ==
            "xteink-v2.0.0.102+bookorbit.1-rc2");
      CHECK(std::string(pick("xteink-v", false, "firmware-x3-x4", chunk, retried).newest.firmwareUrl).find(
                "firmware-x3-x4-v1.6.1.101") != std::string::npos);
    }
  }

  // The feed the firmware reads (xteink/releases.json on the xteink-feed branch): the stable and
  // the pre-release entry, in GitHub's release format.
  if (argc > 2) {
    // @fixture github/xteink-feed.json
    const std::string feed = readFile(argv[2]);
    CHECK(!feed.empty());
    const Pick feedStable = pick("xteink-v", false, "firmware-x3-x4", 97, true, &feed);
    const Pick feedRc = pick("xteink-v", true, "firmware-x3-x4", 1, false, &feed);
    CHECK(feedStable.newest.tagFound && !feedStable.newest.prerelease);
    CHECK(feedRc.newest.tagFound && feedRc.newest.prerelease);
    CHECK(std::string(feedRc.newest.firmwareUrl).find("firmware-x3-x4-v2.") != std::string::npos);
    // The feed's digest pins the image: the updater then downloads it over wolfSSL.
    CHECK(std::strlen(feedRc.newest.firmwareSha256) == 64 && std::strlen(feedStable.newest.firmwareSha256) == 64);
    CHECK(firmware_version::compare(ota_release_pick::versionOf(feedRc.newest.tagName, "xteink-v"),
                                    ota_release_pick::versionOf(feedStable.newest.tagName, "xteink-v")) == 1);
  }

  std::printf("%d passed, %d failed\n", passed, failed);
  return failed == 0 ? 0 : 1;
}
