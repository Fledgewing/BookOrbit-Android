// SPDX-License-Identifier: GPL-3.0-or-later
#include <cassert>
#include "WifiHolds.h"
int main() {
  using namespace orbify::wifi;
  Holds h;
  h.acquire(Owner::Refresh);
  h.acquire(Owner::Catalog);
  h.acquire(Owner::OfflineMiss);
  h.acquire(Owner::Catalog);
  assert(!h.requestOff());
  assert(!h.release(Owner::OfflineMiss));
  assert(!h.release(Owner::Catalog));
  assert(!h.release(Owner::Refresh));
  assert(h.held() == 1);
  assert(h.release(Owner::Catalog));
  assert(h.held() == 0 && h.requestOff());
  assert(!h.release(Owner::Catalog));
}
