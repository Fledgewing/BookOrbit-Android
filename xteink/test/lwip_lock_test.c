// Host test for the dns_clear_cache wrapper (tailnet/shim/TailnetLwipLock.c): the real cache clear
// always runs with the lwIP core lock held, taken once by the wrapper when the caller does not
// hold it, and never taken twice (the core lock is not recursive).
#include <stdbool.h>
#include <stdio.h>

#include "lwip/tcpip.h"

void __wrap_dns_clear_cache(void);

static bool holder = false;
static int locks = 0, unlocks = 0, clears = 0, clearsUnlocked = 0, doubleLocks = 0;

bool sys_thread_tcpip(sys_thread_core_lock_t type) { return type == LWIP_CORE_LOCK_QUERY_HOLDER && holder; }
void stub_lock(void) {
  if (holder) doubleLocks++;
  holder = true;
  locks++;
}
void stub_unlock(void) {
  holder = false;
  unlocks++;
}
void __real_dns_clear_cache(void) {
  clears++;
  if (!holder) clearsUnlocked++;
}

static int failed = 0, passed = 0;
#define CHECK(c) ((c) ? (void)passed++ : (void)(failed++, printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c)))

int main(void) {
  // An app task (hostByName): the wrapper locks around the clear and releases.
  __wrap_dns_clear_cache();
  CHECK(clears == 1 && clearsUnlocked == 0);
  CHECK(locks == 1 && unlocks == 1 && !holder);
  // tcpip_thread or esp_netif_tcpip_exec (TrustedTime, Tailnet.cpp): already locked, not again.
  holder = true;
  __wrap_dns_clear_cache();
  CHECK(clears == 2 && clearsUnlocked == 0);
  CHECK(locks == 1 && unlocks == 1 && holder && doubleLocks == 0);
  printf("lwip-lock: %d passed, %d failed\n", passed, failed);
  return failed ? 1 : 0;
}
