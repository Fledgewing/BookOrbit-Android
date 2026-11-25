// Host test for the BookOrbit server's TLS trust (xteink/orbify/core/ServerTrust): which requests
// are verified, the trust-on-first-use pin (first use, match, change, re-trust) and its saved form.
#include <cstring>
#include <string>

#include "ServerTrust.h"
#include "TestSupport.h"

using namespace orbify::server_trust;

int main(int, char**) {
  // Hosts.
  CHECK(hostOf("https://Books.Example.org:8443/api/v1?x=1") == "books.example.org");
  CHECK(hostOf("https://user:pw@books.example.org/") == "books.example.org");
  CHECK(hostOf("https://[fd7a::1]:443/") == "fd7a::1");
  CHECK(hostOf("https://books.example.org./") == "books.example.org");
  CHECK(hostOf("books.example.org") == "");
  CHECK(isHttps("HTTPS://x") && !isHttps("http://x"));

  // Tailnet hosts stay unverified: WireGuard authenticates them.
  CHECK(isTailnetHost("100.64.0.1", true));
  CHECK(!isTailnetHost("100.64.0.1", false));
  CHECK(isTailnetHost("100.127.255.254", true));
  CHECK(!isTailnetHost("100.128.0.1", false));
  CHECK(!isTailnetHost("100.63.255.255", false));
  CHECK(isTailnetHost("bookorbit.tail1234.ts.net", true));
  CHECK(!isTailnetHost("bookorbit.tail1234.ts.net", false));
  CHECK(!isTailnetHost("ts.net", false));
  CHECK(isTailnetHost("bookorbit", true));    // MagicDNS short name while Tailscale is on
  CHECK(!isTailnetHost("bookorbit", false));  // a LAN name otherwise
  CHECK(!isTailnetHost("192.168.1.10", true));
  CHECK(!isTailnetHost("books.example.org", true));

  const char* server = "https://books.example.org";
  CHECK(modeFor(true, "https://books.example.org/api/v1/books", server, false) == Mode::Verify);
  CHECK(modeFor(true, "https://BOOKS.example.org:443/x", server, false) == Mode::Verify);
  CHECK(modeFor(false, "https://books.example.org/x", server, false) == Mode::Unverified);  // switch off
  CHECK(modeFor(true, "http://books.example.org/x", server, false) == Mode::Unverified);   // not TLS
  CHECK(modeFor(true, "https://objects.example.net/cover.jpg", server, false) == Mode::Unverified);  // another host
  CHECK(modeFor(true, "https://100.101.102.103/x", "https://100.101.102.103", true) == Mode::Unverified);
  CHECK(modeFor(true, "https://bookorbit.tail1234.ts.net/x", "https://bookorbit.tail1234.ts.net", true) ==
        Mode::Unverified);
  CHECK(modeFor(true, "https://bookorbit/x", "https://bookorbit", true) == Mode::Unverified);
  CHECK(modeFor(true, "https://bookorbit/x", "https://bookorbit", false) == Mode::Verify);
  CHECK(modeFor(true, "https://192.168.1.10/x", "https://192.168.1.10", true) == Mode::Verify);
  CHECK(modeFor(true, "https://books.example.org/x", "", false) == Mode::Unverified);

  CHECK(modeFor(true, "https://100.64.0.1/x", "https://100.64.0.1", false) == Mode::Verify);
  CHECK(modeFor(true, "https://bookorbit.tail1234.ts.net/x", "https://bookorbit.tail1234.ts.net", false) == Mode::Verify);

  // The pin.
  uint8_t first[32], second[32];
  for (int i = 0; i < 32; ++i) {
    first[i] = static_cast<uint8_t>(i);
    second[i] = static_cast<uint8_t>(0xF0 + (i & 15));
  }
  CHECK(compare(nullptr, "books.example.org", first) == PinState::FirstUse);  // first use
  Anchor stored;
  stored.host = "books.example.org";
  std::memcpy(stored.fingerprint, first, 32);
  stored.pem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n";
  CHECK(compare(&stored, "books.example.org", first) == PinState::Trusted);     // match
  CHECK(compare(&stored, "books.example.org", second) == PinState::Changed);    // mismatch
  CHECK(compare(&stored, "other.example.org", first) == PinState::FirstUse);    // another server: not its pin
  // Re-trust: accepting the changed certificate replaces the pin; the old one is then the stranger.
  std::memcpy(stored.fingerprint, second, 32);
  CHECK(compare(&stored, "books.example.org", second) == PinState::Trusted);
  CHECK(compare(&stored, "books.example.org", first) == PinState::Changed);

  const std::string fp = formatFingerprint(first);
  CHECK(fp.size() == 95);
  CHECK(fp.rfind("00:01:02:03", 0) == 0);
  CHECK(fp.substr(fp.size() - 5) == "1E:1F");

  // Saved form round trip; anything damaged trusts nothing.
  Anchor back;
  CHECK(parse(serialize(stored), back));
  CHECK(back.host == stored.host && back.pem == stored.pem && std::memcmp(back.fingerprint, second, 32) == 0);
  std::string damaged = serialize(stored);
  damaged[damaged.find("\n", 22) + 3] = 'z';  // inside the fingerprint
  Anchor none;
  CHECK(!parse(damaged, none));
  CHECK(!parse("", none));
  CHECK(!parse("orbify-server-trust 1\nbooks.example.org\n", none));
  std::string noPem = serialize(stored);
  noPem.resize(noPem.find("-----BEGIN"));
  CHECK(!parse(noPem + "garbage", none));

  // PEM: base64 with padding, 64 characters a line.
  const uint8_t der[] = {0x30, 0x82, 0x01};
  CHECK(derToPem(der, 3) == "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n");
  CHECK(derToPem(der, 2) == "-----BEGIN CERTIFICATE-----\nMII=\n-----END CERTIFICATE-----\n");
  uint8_t big[60] = {};
  const std::string pem = derToPem(big, sizeof(big));
  CHECK(pem.find("\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\nAAAAAAAAAAAAAAAA\n") != std::string::npos);

  return report("server-trust");
}
