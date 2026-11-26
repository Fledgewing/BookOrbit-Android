// Host test for the "ota-tag-prefix" overlay patch: the firmware updater reads BookSync's
// mixed release list (shared/fixtures/github/booksync-releases.json) and offers only its own
// xteink-v releases. Built by run-host-tests.sh against a CrossInk checkout with the overlay
// applied (it compiles CrossInk's own parser and version code).
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <vector>
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
using Channel = ota_release_pick::Channel;

static Pick pick(const char* prefix, Channel channel, const char* device = "firmware-x4-pro", size_t chunk = 97,
                 bool retried = false, const std::string* body = nullptr) {
  const std::string& text = body ? *body : fixture;
  stem = device;
  Pick p;
  p.filter = {prefix, channel};
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

  // Obsolete entries without booksync_version are not supported by the channel picker.
  CHECK(!pick("xteink-v", Channel::Preview).newest.tagFound);
  if (argc > 2) {
    // @fixture github/xteink-feed.json
    std::string feed;
    FILE* input = std::fopen(argv[2], "rb");
    CHECK(input != nullptr);
    if (input) {
      while ((n = std::fread(buf, 1, sizeof buf, input)) > 0) feed.append(buf, n);
      std::fclose(input);
    }
    CHECK(!feed.empty());
    CHECK(!pick("xteink-v", Channel::Preview, "firmware-x3-x4", 1, true, &feed).newest.tagFound);
  }

  // W42: channel is determined only by BookSync identity, for every reader asset.
  const char* versions[] = {"0.12.0", "0.12.0-rc.1", "0.13.0-preview.1", "", "bad",
                            "0.12.0-0.test.1", "0.12.0-rc.0", "0.12.0-preview.01"};
  for (const char* device : {"firmware-x4-pro", "firmware-x4-classic", "firmware-x3-x4"}) {
    for (int i = 0; i < 8; ++i) for (bool githubPre : {false, true}) {
      const std::string body = std::string("[{\"tag_name\":\"xteink-v0.12.0+crossink.2.0.0.bookorbit.1-rc3\",") +
          "\"booksync_version\":\"" + versions[i] + "\",\"prerelease\":" + (githubPre ? "true" : "false") +
          ",\"assets\":[{\"name\":\"" + device + "-v-test.bin\",\"browser_download_url\":\"https://example.invalid/fw.bin\"}]}]";
      for (Channel channel : {Channel::Stable, Channel::RC, Channel::Preview}) {
        const bool expected = i == 0 || (i == 1 && channel != Channel::Stable) || (i == 2 && channel == Channel::Preview);
        for (size_t chunk : {size_t(1), size_t(7), size_t(4096)}) {
          CHECK(pick("xteink-v", channel, device, chunk, true, &body).newest.tagFound == expected);
        }
      }
    }
  }

  // The newest allowed version wins, irrespective of channel label or feed order.
  struct ChannelCase {
    Channel channel;
    std::initializer_list<const char*> versions;
    const char* expected;
    const char* installed = "0.11.0";
    bool install = true;
  };
  const ChannelCase channelCases[] = {
      {Channel::RC, {"0.12.0-rc.3", "0.12.0"}, "0.12.0"},
      {Channel::RC, {"0.12.0", "0.12.1-preview.2"}, "0.12.0"},
      {Channel::RC, {"0.12.1-rc.1", "0.12.0"}, "0.12.1-rc.1"},
      {Channel::Preview, {"0.12.1-preview.3", "0.12.1-rc.1", "0.12.1"}, "0.12.1"},
      {Channel::Stable, {"0.12.0", "0.12.1-rc.1", "0.12.1-preview.2"}, "0.12.0"},
      {Channel::Stable, {"0.12.1-rc.1", "0.12.1-preview.2"}, nullptr, "0.11.0", false},
      {Channel::RC, {"0.12.0", "0.12.1-preview.2"}, "0.12.0", "0.12.1-preview.3", false},
      {Channel::Stable, {"0.12.0", "0.12.1-rc.1"}, "0.12.0", "0.12.1-rc.1", false},
  };
  for (const auto& test : channelCases) for (bool reversed : {false, true}) {
    const std::vector<const char*> versions(test.versions);
    for (const char* device : {"firmware-x4-pro", "firmware-x4-classic", "firmware-x3-x4"}) {
      std::string body = "[";
      for (size_t i = 0; i < versions.size(); ++i) {
        const char* version = versions[reversed ? versions.size() - 1 - i : i];
        if (i) body += ",";
        body += std::string("{\"tag_name\":\"xteink-v") + version +
            "+crossink.2.0.0.bookorbit.1-rc3\",\"booksync_version\":\"" + version +
            "\",\"prerelease\":true,\"assets\":[{\"name\":\"" + device +
            "-v-test.bin\",\"browser_download_url\":\"https://example.invalid/fw.bin\"}]}";
      }
      body += "]";
      for (size_t chunk : {size_t(1), size_t(7), size_t(4096)}) {
        const auto selected = pick("xteink-v", test.channel, device, chunk, true, &body).newest;
        CHECK(selected.tagFound == (test.expected != nullptr));
        if (test.expected) CHECK(std::string(selected.booksyncVersion) == test.expected);
        // OtaUpdater uses this comparison to suppress downgrades after a channel switch.
        const bool install = selected.tagFound &&
            ota_release_pick::compare(selected.booksyncVersion, test.installed,
                                      selected.tagName, "") > 0;
        CHECK(install == test.install);
      }
    }
  }

  // W39: actual streaming parser + picker, for each firmware asset line.
  const char* chain[] = {"", "0.11.3-rc.17", "0.12.0-preview.1", "0.12.0-rc.1", "0.12.0"};
  const char* tags[] = {"2.0.0.373+bookorbit.1-rc3", "2.0.0.400+bookorbit.1-rc3",
                       "0.12.0-preview.1+crossink.2.0.0.bookorbit.1-rc3",
                       "0.12.0-rc.1+crossink.2.0.0.bookorbit.1-rc3",
                       "0.12.0+crossink.2.0.0.bookorbit.1-rc3"};
  // Before the bridge is installed, the old comparator must select it over both
  // the installed 2.x/1.6 lines and every lower-numbered unified release.
  CHECK(firmware_version::compare(tags[1], tags[0]) > 0);
  CHECK(firmware_version::compare(tags[1], "1.6.1.114+bookorbit.9") > 0);
  for (int i = 2; i < 5; ++i) CHECK(firmware_version::compare(tags[1], tags[i]) > 0);
  for (const char* device : {"firmware-x4-pro", "firmware-x4-classic", "firmware-x3-x4"}) {
    std::string releases = "[";
    for (int i = 0; i < 5; ++i) {
      if (i) releases += ",";
      releases += std::string("{\"tag_name\":\"xteink-v") + tags[i] +
          "\",\"booksync_version\":\"" + chain[i] + "\",\"prerelease\":" +
          (i == 4 ? "false" : "true") + ",\"assets\":[{\"name\":\"" + device +
          "-v-test.bin\",\"browser_download_url\":\"https://example.invalid/fw.bin\"}]}";
      const std::string partial = releases + "]";
      const Pick step = pick("xteink-v", Channel::Preview, device, 1, true, &partial);
      CHECK(std::string(step.newest.booksyncVersion) == chain[i]);
      if (i) CHECK(std::string(step.newest.tagName) == std::string("xteink-v") + tags[i]);
      else CHECK(!step.newest.tagFound);
      if (i) {
        CHECK(ota_release_pick::compare(chain[i], chain[i-1], tags[i], tags[i-1]) > 0);
        CHECK(ota_release_pick::compare(chain[i-1], chain[i], tags[i-1], tags[i]) < 0);
      }
      CHECK(ota_release_pick::compare(chain[i], chain[i], tags[i], tags[i]) == 0);
    }
    releases += "]";
    CHECK(std::string(pick("xteink-v", Channel::Stable, device, 7, false, &releases).newest.booksyncVersion) == "0.12.0");
  }
  // Selective previews: the latest tag can lack this reader entirely. It must
  // retain its actual prior build and compare equal after installation.
  {
    const std::string partial = R"([
      {"tag_name":"xteink-v0.12.0-preview.3","booksync_version":"0.12.0-preview.3","prerelease":true,
       "assets":[{"name":"firmware-x4-pro-v0.12.0-preview.3.bin","browser_download_url":"https://example.invalid/pro3.bin"}]},
      {"tag_name":"xteink-v0.12.0-preview.2","booksync_version":"0.12.0-preview.2","prerelease":true,
       "assets":[{"name":"firmware-x4-pro-v0.12.0-preview.2.bin","browser_download_url":"https://example.invalid/pro2.bin"},
                 {"name":"firmware-x4-classic-v0.12.0-preview.2.bin","browser_download_url":"https://example.invalid/classic2.bin"},
                 {"name":"firmware-x3-x4-v0.12.0-preview.2.bin","browser_download_url":"https://example.invalid/c3-2.bin"}]}])";
    for (const char* device : {"firmware-x4-pro", "firmware-x4-classic", "firmware-x3-x4"}) {
      const Pick selected = pick("xteink-v", Channel::Preview, device, 1, true, &partial);
      const char* expected = std::strcmp(device, "firmware-x4-pro") == 0 ? "0.12.0-preview.3" : "0.12.0-preview.2";
      CHECK(selected.newest.firmwareFound);
      CHECK(std::string(selected.newest.booksyncVersion) == expected);
      CHECK(ota_release_pick::compare(selected.newest.booksyncVersion, expected,
                                     selected.newest.tagName, selected.newest.tagName) == 0);
    }
  }
  {
    ReleaseJsonParser::Release newest{}, test{};
    std::strcpy(test.tagName, "xteink-v0.12.0-0.test.1");
    std::strcpy(test.booksyncVersion, "0.12.0-0.test.1");
    test.tagFound = test.firmwareFound = true;
    ota_release_pick::keep(newest, test, {"xteink-v", Channel::Preview});
    CHECK(!newest.tagFound);
  }
  CHECK(ota_release_pick::compare("0.12.0-preview.1", "0.12.0-0.test.999", "", "") > 0);
  CHECK(ota_release_pick::compare("0.12.0-0.test.2", "0.12.0-0.test.1", "", "") > 0);
  CHECK(ota_release_pick::compare("0.12.0-preview.10", "0.12.0-preview.2", "", "") > 0);
  CHECK(ota_release_pick::compare("0.12.0-rc.1", "0.12.0-preview.99", "", "") > 0);
  CHECK(ota_release_pick::compare("0.12.0+crossink.2", "0.12.0+crossink.3", "", "") == 0);
  CHECK(ota_release_pick::compare("0.11.3-rc.17", "0.11.3-rc.17",
        "2.0.0.401+bookorbit.1-rc3", "2.0.0.400-bookorbit.1-rc3-x4-pro") > 0);
  CHECK(ota_release_pick::compare("0.12.0", "0.12.0",
        "0.12.0+crossink.2.0.0.bookorbit.2", "0.12.0-crossink.2.0.0.bookorbit.1-x4-pro") == 0);
  for (const char* invalid : {"0.12.0-preview.0", "0.12.0-rc", "0.12.0.400", "0.12.0-preview.01",
                              "0.12.0-preview.999999999999999999999999999999", "0.12.0+", "0.12.0+."})
    CHECK(!ota_release_pick::validBookSync(invalid));

  std::printf("%d passed, %d failed\n", passed, failed);
  return failed == 0 ? 0 : 1;
}
