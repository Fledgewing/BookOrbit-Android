#pragma once
// Orbify (patch 0038): the last step a boot or a sleep reached, kept in RTC memory so the next
// boot can say where a silent device stopped. X4 Pro, .167: after a sleep sync the reader did not
// wake; USB came and went with no log line for five minutes and a USB reset was the only way out.
// The serial log ends at the sleep screen's redraw, so it cannot tell a hang on the way into deep
// sleep from a wake that stopped before its first line. Each step below stores one word; the next
// boot logs the word it finds ("Last boot stopped at ..." when it is not a finished sleep).
// Header only: main.cpp and HalPowerManager (lib/hal) store the steps, the host test checks them.
#include <cstdint>

namespace orbify::boottrail {

// Stored as MAGIC | step: RTC_NOINIT memory holds noise after a power-on, which reads as None.
constexpr uint32_t MAGIC = 0x0B7A1100u;

enum class Step : uint8_t {
  None = 0,
  SetupStarted,       // first line of setup(), before the serial port
  SerialUp,           // the serial port is up; the boot logs from here
  WakeChecked,        // a power-button wake held long enough (or not a button wake)
  SetupDone,          // setup() returned; loop() runs
  SleepStarted,       // enterDeepSleep() / the sleep sync's end committed to sleeping
  SleepScreenDrawn,   // the sleep screen is on the panel
  StorageStopped,     // the SD card is flushed and stopped
  DisplayAsleep,      // the panel controller has its deep-sleep command
  SerialEnded,        // the USB serial port is torn down: nothing logs after this
  ReleaseWait,        // waiting for Power to be let go before arming the wake
  SleepEntered,       // esp_deep_sleep_start() called: a finished sleep
  // Patch 0040, between "wake checked" and "setup done" (X4 Pro, .194: "Last run stopped at: wake
  // checked" on the boot after the catalog's panic, with the device idle on USB). Added after the
  // sleep steps so the words an earlier build stored keep their meaning.
  ClockRead,          // the tilt sensor and the RTC (I2C) answered; the wall clock is set
  StorageReady,       // the SD card is mounted and the last panic's report is checked
  StateLoaded,        // settings, app state, translations and the theme are loaded
  ActivityStarted,    // the boot's first activity is chosen; its first paint is next
  Count
};

inline uint32_t pack(const Step s) { return MAGIC | static_cast<uint8_t>(s); }

inline Step unpack(const uint32_t word) {
  if ((word & 0xFFFFFF00u) != MAGIC) return Step::None;
  const uint8_t s = static_cast<uint8_t>(word & 0xFFu);
  return s < static_cast<uint8_t>(Step::Count) ? static_cast<Step>(s) : Step::None;
}

inline const char* name(const Step s) {
  switch (s) {
    case Step::SetupStarted: return "setup started (before the serial port)";
    case Step::SerialUp: return "serial port up";
    case Step::WakeChecked: return "wake checked";
    case Step::SetupDone: return "setup done";
    case Step::SleepStarted: return "going to sleep";
    case Step::SleepScreenDrawn: return "sleep screen drawn";
    case Step::StorageStopped: return "SD card stopped";
    case Step::DisplayAsleep: return "display asleep";
    case Step::SerialEnded: return "serial port closed for sleep";
    case Step::ReleaseWait: return "waiting for Power to be released";
    case Step::SleepEntered: return "deep sleep entered";
    case Step::ClockRead: return "clock read";
    case Step::StorageReady: return "SD card ready";
    case Step::StateLoaded: return "settings loaded";
    case Step::ActivityStarted: return "first screen started (its paint not done)";
    default: return "nothing recorded";
  }
}

// The reset that started the run the steps belong to (esp_reset_reason_t), in its own RTC word: a
// run that stopped early after a panic reset is the boot that followed a crash. -1: not recorded.
constexpr uint32_t RESET_MAGIC = 0x0B7A1200u;
inline uint32_t packReset(const int reason) { return RESET_MAGIC | static_cast<uint8_t>(reason); }
inline int unpackReset(const uint32_t word) {
  return (word & 0xFFFFFF00u) == RESET_MAGIC ? static_cast<int>(word & 0xFFu) : -1;
}

// Whether the step a boot finds is where the last run stopped: a run ends in deep sleep, or in
// loop() (setup done) until something resets it. A restart the firmware made itself (the sleep
// sync's, the network boots') can leave any step behind, so it never counts.
inline bool stoppedEarly(const Step last, const bool firmwareRestart) {
  if (firmwareRestart) return false;
  return last != Step::None && last != Step::SetupDone && last != Step::SleepEntered;
}

// The crash record (the core dump partition) outlives the build that wrote it: nothing erases it,
// so a dump read off the X4 Pro after the .167 hang was .141's lwIP panic, fixed two builds before.
// The dump names its build by the first characters of the app ELF's SHA-256 (9 on these builds);
// the record is this build's when they start the running app's.
inline bool sameBuild(const char* dumpSha, const char* runningSha) {
  if (dumpSha == nullptr || runningSha == nullptr || dumpSha[0] == '\0') return false;
  for (; *dumpSha != '\0'; ++dumpSha, ++runningSha) {
    if (*dumpSha != *runningSha) return false;
  }
  return true;
}

}  // namespace orbify::boottrail
