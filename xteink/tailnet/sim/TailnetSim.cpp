// The Tailnet shim's API (Tailnet.h, TailnetNetPhase.h) for upstream's SDL simulator.
//
// Built only by tailnet_build.py's simulator mode (xteink/test/e2e/), never into a reader's
// firmware. Tailscale does not run on a host: the simulator reaches the test server directly, so
// every call reports "Tailscale off" and nothing parks. The firmware then takes the same paths it
// takes on a reader with Tailscale turned off in Settings.
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Tailnet.h"
#include "TailnetNetPhase.h"

namespace {
// ORBIFY_SIM_TAILSCALE=joined: the Tailscale settings screen of a reader that is on and logged in,
// for the layout scenario (xteink/test/e2e/run.py tailscale_layout). Nothing connects either way.
bool simJoined() {
  static const bool joined = [] {
    const char* v = std::getenv("ORBIFY_SIM_TAILSCALE");
    return v && std::strcmp(v, "joined") == 0;
  }();
  return joined;
}
}  // namespace

extern "C" {

tailnet_status_t tailnet_status(void) { return TAILNET_OFF; }
bool tailnet_login_url(char* buf, size_t len) {
  if (buf && len) buf[0] = '\0';
  return false;
}
uint32_t tailnet_ip(void) { return 0; }
uint32_t tailnet_generation(void) { return 0; }
bool tailnet_enabled(void) { return simJoined(); }
void tailnet_set_enabled(bool) {}
bool tailnet_joined(void) { return simJoined(); }
void tailnet_logout(void) {}
bool tailnet_wait_connected(uint32_t) { return false; }
bool tailnet_wait_connected_for(const char*, uint32_t) { return false; }
bool tailnet_ensure_peer(uint32_t, uint32_t) { return false; }
void tailnet_get_diag(tailnet_diag_t* out) {
  if (out) memset(out, 0, sizeof(*out));
}
tailnet_relay_mode_t tailnet_relay_mode(void) { return TAILNET_RELAY_AUTO; }
uint16_t tailnet_relay_fixed_region(void) { return 0; }
void tailnet_set_relay(tailnet_relay_mode_t, uint16_t) {}
int tailnet_relay_regions(uint16_t*, char (*)[8], int) { return 0; }
void tailnet_relay_code(uint16_t, char* out, size_t len) {
  if (out && len) out[0] = '\0';
}
bool tailnet_lite(void) { return false; }
void tailnet_permit_start(bool) {}
void tailnet_permit_on_demand(void) {}
bool tailnet_start_on_demand(const char*) { return false; }
tailnet_status_t tailnet_login_session(uint32_t) { return TAILNET_OFF; }
bool tailnet_saved_login_url(char* buf, size_t len) { return tailnet_login_url(buf, len); }
bool tailnet_wait_ready(uint32_t) { return false; }
void tailnet_wait_idle(uint32_t) {}
void tailnet_stop_before_wifi_off(uint32_t) {}
void tailnet_probe_permit_unparked(void) {}
void tailnet_probe_heap(const char*) {}
void tailnet_probe_window_begin(const char*) {}
void tailnet_probe_window_mark(const char*, const char*) {}
void tailnet_probe_window_end(const char*, const char*) {}
uint32_t tailnet_connect_count(void) { return 0; }
void tailnet_log_path(const char*) {}
bool tailnet_log_line(int, char* buf, size_t len) {
  if (buf && len) buf[0] = '\0';
  return false;
}
uint32_t tailnet_log_seq(void) { return 0; }
void tailnet_log_emit(const char* format, ...) {
  va_list ap;
  va_start(ap, format);
  std::vfprintf(stderr, format, ap);
  va_end(ap);
  std::fputc('\n', stderr);
}
void tailnet_log_install(void) {}
uint32_t tailnet_resolve(const char*) { return 0; }

// TailnetNetPhase.h: nothing parks, no boot runs Tailscale, the display is always ready. The
// login and BookOrbit authentication boots are the UI activities' own (tailnet/ui).
bool tailnet_koreader_upload_redirect(void) { return false; }
void tailnet_wifi_joined(void) {}
bool tailnet_boot_parks(void) { return false; }
bool tailnet_end_parked_network(void) { return false; }
void tailnet_network_phase_begin(uint32_t) {}
uint32_t tailnet_network_boot_target(void) { return 0; }
bool tailnet_wifi_parked_boot(uint32_t) { return false; }
bool tailnet_boot_runs_tailscale(void) { return false; }
bool tailnet_prompt_dropped_network(void) { return false; }
bool tailnet_download_progress_unpark(void) { return false; }
bool tailnet_display_render_gate(void) { return true; }
void tailnet_display_tick(void) {}
bool tailnet_display_ready(uint32_t) { return true; }
void tailnet_catalog_connect(bool) {}
int tailnet_catalog_result(void) { return TAILNET_CATALOG_REFUSED; }

}  // extern "C"
