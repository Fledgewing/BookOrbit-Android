#pragma once
// Orbify (patch 0037): when the sleep sync's watcher ends the sync itself. The sync checks Power
// only between its steps, and on a starved heap one step blocked for 82 s (X4 Pro, rc3). Header
// only, so the watcher (src/util/PowerButtonWakeWatcher) and the host test share it.
// millis() arithmetic: unsigned differences, so a wrap of the counter changes nothing.

namespace orbify::sleepsync {

enum class Exit { None, Wake, Sleep };

struct Deadlines {
  unsigned long armedAt = 0;
  unsigned long wakeGraceMs = 0;    // a press the sync has not acted on by then wakes the device
  unsigned long budgetMs = 0;       // 0 = no budget (disarmed: the sync is going to sleep itself)
  unsigned long budgetGraceMs = 0;  // past the budget, the sync's own stop at its next step
};

// pressedAt: when the wake press was recognised, 0 = none yet (callers store it with bit 0 set).
inline Exit check(const Deadlines& d, const unsigned long now, const unsigned long pressedAt) {
  if (pressedAt != 0 && now - pressedAt >= d.wakeGraceMs) return Exit::Wake;
  if (d.budgetMs != 0 && now - d.armedAt >= d.budgetMs + d.budgetGraceMs) return Exit::Sleep;
  return Exit::None;
}

// The sync's own stop: its budget is spent, so the next step sees sleepSyncWakeRequested().
inline bool outOfTime(const Deadlines& d, const unsigned long now) {
  return d.budgetMs != 0 && now - d.armedAt >= d.budgetMs;
}

}  // namespace orbify::sleepsync
