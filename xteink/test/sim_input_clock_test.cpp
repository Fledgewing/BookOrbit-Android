// SPDX-License-Identifier: MIT
#include <cassert>
#include <cstdio>
#include "orbify_sim_input.h"

int main() {
  // CI regression: settings setup finished at 3877 ms, after the old script's
  // 2500..2620 ms Power press. Both edges expired before the first input poll.
  orbify_sim_input::Clock absolute;
  assert(absolute.elapsed(3900, false) > 2620);

  orbify_sim_input::Clock ready;
  assert(ready.elapsed(3900, true) == 0);
  assert(ready.elapsed(6399, true) < 2500);
  assert(ready.elapsed(6400, true) == 2500); // down
  assert(ready.elapsed(6519, true) < 2620);  // still held
  assert(ready.elapsed(6520, true) == 2620); // up, 120 ms later
  assert(absolute.elapsed(6520, false) == 6520); // legacy scripts unchanged
  assert(setenv("ORBIFY_SIM_INPUT_FROM_POLL", "1", 1) == 0);
  assert(orbify_sim_input::now(3900) == 0);
  assert(orbify_sim_input::now(6399) < 2500);
  assert(orbify_sim_input::now(6400) == 2500);
  assert(orbify_sim_input::now(6520) == 2620);
  std::puts("sim-input-clock: passed (late boot preserves the 120 ms press)");
}
