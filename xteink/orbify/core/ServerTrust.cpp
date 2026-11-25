#include "ServerTrust.h"

#include <cstring>

namespace orbify::server_trust {
namespace {

char lower(char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c; }

bool startsWithNoCase(std::string_view s, std::string_view prefix) {
  if (s.size() < prefix.size()) return false;
  for (size_t i = 0; i < prefix.size(); ++i) {
    if (lower(s[i]) != prefix[i]) return false;
  }
  return true;
}

constexpr char HEX[] = "0123456789abcdef";

int hexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

constexpr char HEADER[] = "orbify-server-trust 1\n";

}  // namespace

std::string hostOf(std::string_view url) {
  const size_t scheme = url.find("://");
  if (scheme == std::string_view::npos) return "";
  std::string_view rest = url.substr(scheme + 3);
  rest = rest.substr(0, rest.find_first_of("/?#"));
  const size_t at = rest.rfind('@');
  if (at != std::string_view::npos) rest = rest.substr(at + 1);
  if (!rest.empty() && rest[0] == '[') {
    const size_t close = rest.find(']');
    if (close == std::string_view::npos) return "";
    rest = rest.substr(1, close - 1);
  } else {
    rest = rest.substr(0, rest.find(':'));
  }
  if (!rest.empty() && rest.back() == '.') rest.remove_suffix(1);
  std::string host(rest);
  for (char& c : host) c = lower(c);
  return host;
}

bool isHttps(std::string_view url) { return startsWithNoCase(url, "https://"); }

Mode modeFor(bool enabled, std::string_view url, std::string_view serverUrl) {
  if (!enabled || !isHttps(url)) return Mode::Unverified;
  const std::string host = hostOf(url);
  if (host.empty() || host != hostOf(serverUrl)) return Mode::Unverified;
  return Mode::Verify;
}

PinState compare(const Anchor* stored, std::string_view host, const uint8_t presented[32]) {
  if (stored == nullptr || stored->host.empty() || stored->host != host) return PinState::FirstUse;
  return std::memcmp(stored->fingerprint, presented, 32) == 0 ? PinState::Trusted : PinState::Changed;
}

std::string formatFingerprint(const uint8_t fingerprint[32]) {
  std::string out;
  out.reserve(95);
  for (int i = 0; i < 32; ++i) {
    if (i) out += ':';
    static constexpr char UPPER[] = "0123456789ABCDEF";
    out += UPPER[fingerprint[i] >> 4];
    out += UPPER[fingerprint[i] & 15];
  }
  return out;
}

std::string serialize(const Anchor& anchor) {
  std::string out = HEADER;
  out += anchor.host;
  out += '\n';
  for (uint8_t b : anchor.fingerprint) {
    out += HEX[b >> 4];
    out += HEX[b & 15];
  }
  out += '\n';
  out += anchor.pem;
  return out;
}

bool parse(std::string_view text, Anchor& out) {
  if (text.substr(0, sizeof(HEADER) - 1) != HEADER) return false;
  text.remove_prefix(sizeof(HEADER) - 1);
  const size_t hostEnd = text.find('\n');
  if (hostEnd == std::string_view::npos || hostEnd == 0) return false;
  Anchor a;
  a.host.assign(text.substr(0, hostEnd));
  text.remove_prefix(hostEnd + 1);
  if (text.size() < 65 || text[64] != '\n') return false;
  for (int i = 0; i < 32; ++i) {
    const int hi = hexValue(text[2 * i]);
    const int lo = hexValue(text[2 * i + 1]);
    if (hi < 0 || lo < 0) return false;
    a.fingerprint[i] = static_cast<uint8_t>(hi << 4 | lo);
  }
  text.remove_prefix(65);
  if (text.substr(0, 27) != "-----BEGIN CERTIFICATE-----" ||
      text.find("-----END CERTIFICATE-----") == std::string_view::npos) {
    return false;
  }
  a.pem.assign(text);
  out = std::move(a);
  return true;
}

std::string derToPem(const uint8_t* der, size_t length) {
  static constexpr char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string body;
  body.reserve((length + 2) / 3 * 4);
  for (size_t i = 0; i < length; i += 3) {
    const uint32_t n = static_cast<uint32_t>(der[i]) << 16 | (i + 1 < length ? der[i + 1] << 8 : 0) |
                       (i + 2 < length ? der[i + 2] : 0);
    body += B64[n >> 18 & 63];
    body += B64[n >> 12 & 63];
    body += i + 1 < length ? B64[n >> 6 & 63] : '=';
    body += i + 2 < length ? B64[n & 63] : '=';
  }
  std::string pem = "-----BEGIN CERTIFICATE-----\n";
  for (size_t i = 0; i < body.size(); i += 64) {
    pem.append(body, i, 64);
    pem += '\n';
  }
  pem += "-----END CERTIFICATE-----\n";
  return pem;
}

}  // namespace orbify::server_trust
