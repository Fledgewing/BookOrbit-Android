#pragma once
// BookSync: the BookOrbit server's HTTPS connections verify the server (core/ServerTrust.h,
// docs/design/server-tls.md). Device side: the certificate check on each request, the
// trust-on-first-use prompt's data and the saved certificate. Switch CROSSINK_TAILNET_ORBIFY_SERVER_TLS
// (tailnet_build.py); off, every request stays unverified as before.
#ifndef CROSSINK_TAILNET_ORBIFY_SERVER_TLS
#define CROSSINK_TAILNET_ORBIFY_SERVER_TLS 0
#endif

#include <string>

namespace freeink {
class SecureHttpClient;
}

// Sets `http`'s certificate check for a request to `url`, before begin(): verified for the
// BookOrbit server (built-in roots plus the certificate the user trusted), unverified otherwise.
void orbifyServerTrust(freeink::SecureHttpClient& http, const std::string& url);

namespace orbify::server_tls {

// What the server presented when its certificate was not accepted.
struct Offer {
  bool firstUse = true;       // nothing trusted yet; false: the trusted certificate changed
  std::string fingerprint;    // SHA-256, "AB:CD:..."
  const char* title = "";     // "Unknown server certificate" / "Server certificate changed"
  const char* hint = "";      // what to compare the fingerprint with
  const char* trustLabel = "";  // the button that trusts it
};

// After a failed connection to the BookOrbit server: reads the certificate it presents and offers
// it for trust. False when there is nothing to offer: the switch is off, the server is not
// verified (tailnet, http), it can't be reached, or it presents the certificate already trusted.
bool offer(Offer& out);

// Trusts the certificate the last offer() found, for this server only. False if it can't be saved.
bool acceptOffer();

}  // namespace orbify::server_tls
