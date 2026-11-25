#pragma once
// Orbify: who the BookOrbit server's HTTPS connections trust (docs/design/server-tls.md).
//
// A request to the configured BookOrbit server over https is verified: its certificate chain must
// lead to one of a few public roots (the Let's Encrypt roots, which also issue Tailscale's
// *.ts.net certificates) or to the certificate the user trusted for this server ("trust on first
// use"). The trusted certificate is the top of the chain the server presented, kept with the
// server's host, so a self-signed or private-CA server works once the user accepts its
// fingerprint, and a changed certificate asks again ("re-trust").
//
// Not verified, as before: tailnet hosts (100.64.0.0/10, *.ts.net, and single-label MagicDNS
// names while Tailscale is on), whose traffic WireGuard already authenticates, and every host that
// is not the BookOrbit server. A connection that fails verification never sends the request, so
// the server's credentials never travel over it.
//
// Pure logic: the device side (src/orbify/ServerTrust.cpp) does the TLS, hashing and storage.
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace orbify::server_trust {

// Lower-cased host of an http(s) URL, without port, userinfo or IPv6 brackets; "" if none.
std::string hostOf(std::string_view url);
bool isHttps(std::string_view url);

// 100.64.0.0/10 literals, *.ts.net names, and single-label names when Tailscale is on.
bool isTailnetHost(std::string_view host, bool tailnetOn);

enum class Mode {
  Unverified,  // as before: no certificate check (switch off, not https, not the server, tailnet)
  Verify,      // the chain must reach a built-in root or the trusted certificate
};
// url: the request; serverUrl: the configured BookOrbit server (BookOrbitCredentialStore::getBaseUrl).
Mode modeFor(bool enabled, std::string_view url, std::string_view serverUrl, bool tailnetOn);

// The certificate trusted for one server: its host and the certificate (PEM) with its fingerprint.
struct Anchor {
  std::string host;
  uint8_t fingerprint[32] = {};  // SHA-256 of the certificate's DER
  std::string pem;
};

enum class PinState {
  Trusted,   // the presented certificate is the one trusted for this host
  FirstUse,  // nothing trusted for this host yet: ask the user once
  Changed,   // another certificate is trusted for this host: show the new fingerprint, ask again
};
// stored: the saved anchor, or nullptr when none. A saved anchor for another host counts as none.
PinState compare(const Anchor* stored, std::string_view host, const uint8_t presented[32]);

// "AB:CD:...": the 32 bytes as colon-separated upper-case hex (95 characters).
std::string formatFingerprint(const uint8_t fingerprint[32]);

// The saved form: "orbify-server-trust 1\n<host>\n<fingerprint hex>\n<PEM>". parse() refuses
// anything else, so a damaged file trusts nothing.
std::string serialize(const Anchor& anchor);
bool parse(std::string_view text, Anchor& out);

// One DER certificate as PEM, 64 base64 characters a line.
std::string derToPem(const uint8_t* der, size_t length);

}  // namespace orbify::server_trust
