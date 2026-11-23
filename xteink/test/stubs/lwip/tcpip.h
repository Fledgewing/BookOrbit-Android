#pragma once
#include <stdbool.h>
typedef enum { LWIP_CORE_LOCK_QUERY_HOLDER, LWIP_CORE_LOCK_MARK_HOLDER, LWIP_CORE_LOCK_UNMARK_HOLDER } sys_thread_core_lock_t;
bool sys_thread_tcpip(sys_thread_core_lock_t type);
void stub_lock(void);
void stub_unlock(void);
#define LOCK_TCPIP_CORE() stub_lock()
#define UNLOCK_TCPIP_CORE() stub_unlock()
