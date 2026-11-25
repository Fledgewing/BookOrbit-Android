// The sleep sync's watcher deadlines (orbify/core/SleepSyncDeadline.h).
#include <cstdint>

#include "SleepSyncDeadline.h"
#include "TestSupport.h"

using namespace orbify::sleepsync;

static Deadlines device(const unsigned long armedAt) {
  Deadlines d;
  d.armedAt = armedAt;
  d.wakeGraceMs = 2000;
  d.budgetMs = 240000;
  d.budgetGraceMs = 20000;
  return d;
}

static void wakePress() {
  const Deadlines d = device(1000);
  CHECK(check(d, 5000, 0) == Exit::None);
  // The rc3 device log: a press at 30 s while a catalog reply waited 82 s. The sync answers it
  // between steps; if it has not within 2 s, the watcher wakes the device itself.
  CHECK(check(d, 31000, 30001) == Exit::None);
  CHECK(check(d, 31999, 30001) == Exit::None);
  CHECK(check(d, 32001, 30001) == Exit::Wake);
  // A press wins over the budget: past both, the device wakes, it does not go back to sleep.
  CHECK(check(d, 1000 + 300000, 1000 + 290001) == Exit::Wake);
}

static void pressInTheSameTick() {
  // The watcher stores a press as now | 1 and checks the deadlines in the same 10 ms tick. On an
  // even millisecond the stored time is now + 1: the sync must still get its 2 s (.167 restarted
  // at once on every such press).
  const Deadlines d = device(1000);
  for (unsigned long now : {1574UL, 1575UL, 30000UL, 30001UL}) {
    const unsigned long stored = now | 1UL;
    CHECK(check(d, now, stored) == Exit::None);
    CHECK(check(d, now + 10, stored) == Exit::None);
    CHECK(check(d, pressTime(stored) + 1999, stored) == Exit::None);
    CHECK(check(d, pressTime(stored) + 2000, stored) == Exit::Wake);
  }
}

static void budget() {
  const Deadlines d = device(1000);
  CHECK(!outOfTime(d, 1000 + 239999));
  CHECK(outOfTime(d, 1000 + 240000));  // every step stops from here; the sync sleeps on its own
  CHECK(check(d, 1000 + 259999, 0) == Exit::None);
  CHECK(check(d, 1000 + 260000, 0) == Exit::Sleep);  // still stuck in a request: restart to sleep
  // Disarmed when the sync draws its sleep screen: no budget exit, a press still wakes.
  Deadlines off = d;
  off.budgetMs = 0;
  CHECK(!outOfTime(off, 1000 + 900000));
  CHECK(check(off, 1000 + 900000, 0) == Exit::None);
  CHECK(check(off, 1000 + 900000, 1000 + 897001) == Exit::Wake);
}

static void counterWrap() {
  // millis() is 32 bits on the device and wraps after ~49 days; the watcher's differences are
  // taken in its own unsigned long, so a sync armed just before the wrap keeps its budget.
  if (sizeof(unsigned long) != 4) return;  // the host's long is wider; the device's is not
  const unsigned long armedAt = 0xFFFFFFFFUL - 1000UL;
  const Deadlines d = device(armedAt);
  CHECK(!outOfTime(d, armedAt + 239999UL));
  CHECK(outOfTime(d, armedAt + 240000UL));
  CHECK(check(d, armedAt + 1000UL, 0) == Exit::None);
}

int main() {
  wakePress();
  pressInTheSameTick();
  budget();
  counterWrap();
  return report("sleep-sync-deadline");
}
