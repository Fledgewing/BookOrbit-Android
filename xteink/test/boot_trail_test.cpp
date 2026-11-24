// The boot trail and the crash record's build check (orbify/core/BootTrail.h, patch 0038).
#include <cstdint>
#include <cstring>

#include "BootTrail.h"
#include "TestSupport.h"

using namespace orbify::boottrail;

static void roundTrip() {
  for (uint8_t s = 0; s < static_cast<uint8_t>(Step::Count); ++s) {
    CHECK(unpack(pack(static_cast<Step>(s))) == static_cast<Step>(s));
    CHECK(std::strcmp(name(static_cast<Step>(s)), "") != 0);
  }
  // RTC_NOINIT memory after a power-on holds noise: it reads as nothing recorded.
  CHECK(unpack(0) == Step::None);
  CHECK(unpack(0xFFFFFFFFu) == Step::None);
  CHECK(unpack(0xDEADBE05u) == Step::None);
  CHECK(unpack(MAGIC | 0xFFu) == Step::None);  // our magic, a step this build does not know
  CHECK(std::strcmp(name(Step::None), "nothing recorded") == 0);
}

static void verdicts() {
  // The .167 hang: the log ends at the sleep screen's redraw, USB went away, and a USB reset
  // (not the firmware's own restart) was the way out. Each step before deep sleep names itself.
  for (Step s : {Step::SetupStarted, Step::SerialUp, Step::WakeChecked, Step::SleepStarted, Step::SleepScreenDrawn,
                 Step::StorageStopped, Step::DisplayAsleep, Step::SerialEnded, Step::ReleaseWait}) {
    CHECK(stoppedEarly(s, false));
    CHECK(!stoppedEarly(s, true));  // the sleep sync's and the network boots' restarts leave steps behind
  }
  // Ordinary ends: deep sleep, or loop() until a reset.
  CHECK(!stoppedEarly(Step::SleepEntered, false));
  CHECK(!stoppedEarly(Step::SetupDone, false));
  CHECK(!stoppedEarly(Step::None, false));
}

static void crashRecordBuild() {
  // The dump read after the .167 hang carried "f59b92e94": the first 9 characters of the
  // crashing app's ELF SHA-256 (a .141 build). The running app's full digest starts with them or not.
  CHECK(sameBuild("f59b92e94", "f59b92e94c0ffee0"));
  CHECK(!sameBuild("f59b92e94", "a01b92e94c0ffee0"));
  CHECK(!sameBuild("f59b92e94", "f59b92e9"));  // a running digest shorter than the dump's
  CHECK(!sameBuild("", "f59b92e94c0ffee0"));     // no summary: never this build
  CHECK(!sameBuild(nullptr, "f59b92e94c0ffee0"));
  CHECK(!sameBuild("f59b92e94", nullptr));
}

int main() {
  roundTrip();
  verdicts();
  crashRecordBuild();
  return report("boot-trail");
}
