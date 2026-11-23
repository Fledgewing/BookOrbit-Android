// lwIP calls made outside tcpip_thread without the core lock (CONFIG_LWIP_TCPIP_CORE_LOCKING with
// CONFIG_LWIP_CHECK_THREAD_SAFETY: the check asserts and the reader panics).
//
// dns_clear_cache(): Arduino's NetworkManager::hostByName() (libraries/Network, compiled from
// source) calls it from the caller's task whenever the device's IPv4/IPv6 state changed since
// the last lookup, i.e. on the first lookup after WiFi joins. With another task's lookup in
// flight (MicroLink's STUN servers, resolving in parallel) the cache clear finishes that lookup
// (dns_call_found) and frees its random-port UDP PCB: udp_remove() off tcpip_thread.
// Seen on an X4 Pro, xteink-v2.0.0.141, catalog boot after "Restarting into the catalog":
//   W ml_stun: DNS resolve failed for derp9.tailscale.com
//   assert failed: udp_remove udp.c:1199 (Required to lock TCPIP core functionality!)
//   backtrace: udp_remove <- dns_call_found <- dns_clear_cache <- NetworkManager::hostByName
//              <- freeink::hostResolves <- SecureClient::connect <- ... fetchBookDetail
// The link wraps dns_clear_cache (tailnet_build.py); this wrapper takes the core lock unless the
// caller already holds it (tcpip_thread, or CrossInk's TrustedTime via esp_netif_tcpip_exec).
#include "lwip/opt.h"
#include "lwip/dns.h"
#include "lwip/tcpip.h"

void __real_dns_clear_cache(void);

void __wrap_dns_clear_cache(void) {
#if LWIP_TCPIP_CORE_LOCKING
  if (sys_thread_tcpip(LWIP_CORE_LOCK_QUERY_HOLDER)) {
    __real_dns_clear_cache();
    return;
  }
  LOCK_TCPIP_CORE();
  __real_dns_clear_cache();
  UNLOCK_TCPIP_CORE();
#else
  __real_dns_clear_cache();
#endif
}
