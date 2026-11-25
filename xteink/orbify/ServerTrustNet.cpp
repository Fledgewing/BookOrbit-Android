#include "ServerTrustNet.h"

#if CROSSINK_TAILNET_ORBIFY_SERVER_TLS && !defined(SIMULATOR)
#include <Arduino.h>
#include <BookOrbitCredentialStore.h>
#include <HalStorage.h>
#include <I18n.h>
#include <Logging.h>
#include <SecureHttpClient.h>
#include <WiFi.h>
#include <mbedtls/sha256.h>
#include <wolfssl/ssl.h>

#include "Tailnet.h"
#include "core/ServerTrust.h"
#include "network/HttpRedirectPolicy.h"

namespace {
using namespace orbify::server_trust;

// The certificate the user trusted, kept beside the BookOrbit settings.
constexpr char ANCHOR_PATH[] = "/.crosspoint/bookorbit-server-cert.txt";
constexpr uint32_t PROBE_TIMEOUT_MS = 15000;

// Built-in roots: ISRG Root X1 (RSA) and X2 (ECDSA), Let's Encrypt's, which also issue
// `tailscale cert` certificates. Any other server is trusted by its fingerprint (trust on first use).
constexpr char BUILT_IN_ROOTS[] =
    "-----BEGIN CERTIFICATE-----\n"
    "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\n"
    "-----END CERTIFICATE-----\n"
    "-----BEGIN CERTIFICATE-----\n"
    "MIICGzCCAaGgAwIBAgIQQdKd0XLq7qeAwSxs6S+HUjAKBggqhkjOPQQDAzBPMQsw\n"
    "CQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2gg\n"
    "R3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMjAeFw0yMDA5MDQwMDAwMDBaFw00\n"
    "MDA5MTcxNjAwMDBaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBT\n"
    "ZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgyMHYw\n"
    "EAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0HttwW\n"
    "+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9\n"
    "ItgKbppbd9/w+kHsOdx1ymgHDB/qo0IwQDAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0T\n"
    "AQH/BAUwAwEB/zAdBgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwCgYIKoZI\n"
    "zj0EAwMDaAAwZQIwe3lORlCEwkSHRhtFcP9Ymd70/aTSVaYgLXTWNLxBo1BfASdW\n"
    "tL4ndQavEi51mI38AjEAi/V3bNTIZargCyzuFJ0nN6T5U6VR5CmD1/iQMVtCnwr1\n"
    "/q4AaOeMSQ+2b1tbFfLn\n"
    "-----END CERTIFICATE-----\n"
;

bool loaded = false;
bool haveAnchor = false;
Anchor anchor;
bool havePending = false;
Anchor pending;
// What SecureHttpClient::setCACert() points at: the roots plus the trusted certificate, rebuilt
// when the server's host changes. It must outlive the connection, so it is never a temporary.
std::string trustPem;
std::string trustHost;

void loadAnchor() {
  if (loaded) return;
  loaded = true;
  std::string text;
  if (Storage.exists(ANCHOR_PATH) && Storage.readFileToString("TLS", ANCHOR_PATH, 8192, text)) {
    haveAnchor = parse(text, anchor);
    if (!haveAnchor) LOG_ERR("TLS", "Ignoring a damaged %s", ANCHOR_PATH);
  }
}

const char* trustFor(const std::string& host) {
  loadAnchor();
  if (trustPem.empty() || trustHost != host) {
    trustPem = BUILT_IN_ROOTS;
    if (haveAnchor && anchor.host == host) trustPem += anchor.pem;
    trustHost = host;
  }
  return trustPem.c_str();
}

// The probe's view of the handshake: the top certificate of the chain the server sent.
std::string* capture = nullptr;

int captureTop(int /*preverify*/, WOLFSSL_X509_STORE_CTX* store) {
  if (capture != nullptr && capture->empty() && store != nullptr && store->certs != nullptr && store->totalCerts > 0) {
    const WOLFSSL_BUFFER_INFO& top = store->certs[store->totalCerts - 1];
    capture->assign(reinterpret_cast<const char*>(top.buffer), top.length);
  }
  return 0;  // never completes: the probe only reads the certificates
}

int probeSend(WOLFSSL*, char* buf, int sz, void* ctx) {
  auto* t = static_cast<WiFiClient*>(ctx);
  const int n = t->write(reinterpret_cast<const uint8_t*>(buf), sz);
  if (n > 0) return n;
  return t->connected() ? WOLFSSL_CBIO_ERR_WANT_WRITE : WOLFSSL_CBIO_ERR_CONN_CLOSE;
}

int probeRecv(WOLFSSL*, char* buf, int sz, void* ctx) {
  auto* t = static_cast<WiFiClient*>(ctx);
  if (t->available() == 0) return t->connected() ? WOLFSSL_CBIO_ERR_WANT_READ : WOLFSSL_CBIO_ERR_CONN_CLOSE;
  const int n = t->read(reinterpret_cast<uint8_t*>(buf), sz);
  return n > 0 ? n : WOLFSSL_CBIO_ERR_WANT_READ;
}

// Handshakes with host:port only far enough to read its certificates; sends no request.
bool presentedCertificate(const std::string& host, uint16_t port, std::string& der) {
  der.clear();
  WiFiClient tcp;
  tcp.setConnectionTimeout(PROBE_TIMEOUT_MS);
  if (!tcp.connect(host.c_str(), port)) return false;
  WOLFSSL_CTX* ctx = wolfSSL_CTX_new(wolfSSLv23_client_method());
  if (ctx == nullptr) return false;
  wolfSSL_CTX_set_verify(ctx, WOLFSSL_VERIFY_PEER, captureTop);
  wolfSSL_SetIORecv(ctx, probeRecv);
  wolfSSL_SetIOSend(ctx, probeSend);
  WOLFSSL* ssl = wolfSSL_new(ctx);
  if (ssl != nullptr) {
    wolfSSL_SetIOReadCtx(ssl, &tcp);
    wolfSSL_SetIOWriteCtx(ssl, &tcp);
    wolfSSL_UseSNI(ssl, WOLFSSL_SNI_HOST_NAME, host.c_str(), host.size());
#if defined(WOLFSSL_TLS13) && defined(HAVE_CURVE25519)
    wolfSSL_UseKeyShare(ssl, WOLFSSL_ECC_X25519);  // as SecureClient: no P-256 bignum temporaries
#endif
    capture = &der;
    const uint32_t deadline = millis() + PROBE_TIMEOUT_MS;
    int ret;
    while ((ret = wolfSSL_connect(ssl)) != WOLFSSL_SUCCESS && der.empty()) {
      const int err = wolfSSL_get_error(ssl, ret);
      if (err != WOLFSSL_ERROR_WANT_READ && err != WOLFSSL_ERROR_WANT_WRITE) break;
      if (static_cast<int32_t>(millis() - deadline) >= 0) break;
      delay(5);
    }
    capture = nullptr;
    wolfSSL_free(ssl);
  }
  wolfSSL_CTX_free(ctx);
  tcp.stop();
  return !der.empty();
}

}  // namespace

void orbifyServerTrust(freeink::SecureHttpClient& http, const std::string& url) {
  const std::string server = BOOKORBIT_STORE.getBaseUrl();
  if (modeFor(true, url, server, tailnet_enabled()) == Mode::Unverified) {
    http.setInsecure();
    return;
  }
  http.setCACert(trustFor(hostOf(url)));
}

namespace orbify::server_tls {

bool offer(Offer& out) {
  havePending = false;
  const std::string server = BOOKORBIT_STORE.getBaseUrl();
  if (modeFor(true, server, server, tailnet_enabled()) == Mode::Unverified) return false;
  HttpRedirectPolicy::Url url;
  if (!HttpRedirectPolicy::parseUrl(server, url)) return false;
  std::string der;
  if (!presentedCertificate(url.host, url.port, der)) {
    LOG_ERR("TLS", "No certificate read from %s", url.host.c_str());
    return false;
  }
  uint8_t fingerprint[32];
  mbedtls_sha256(reinterpret_cast<const uint8_t*>(der.data()), der.size(), fingerprint, 0);
  loadAnchor();
  const std::string host = hostOf(server);
  const PinState state = compare(haveAnchor ? &anchor : nullptr, host, fingerprint);
  if (state == PinState::Trusted) return false;  // the trusted certificate failed for another reason
  pending.host = host;
  memcpy(pending.fingerprint, fingerprint, sizeof(fingerprint));
  pending.pem = derToPem(reinterpret_cast<const uint8_t*>(der.data()), der.size());
  havePending = true;
  out.firstUse = state == PinState::FirstUse;
  out.fingerprint = formatFingerprint(fingerprint);
  out.title = out.firstUse ? tr(STR_ORBIFY_TLS_UNKNOWN) : tr(STR_ORBIFY_TLS_CHANGED);
  out.hint = tr(STR_ORBIFY_TLS_COMPARE);
  out.trustLabel = tr(STR_ORBIFY_TLS_TRUST);
  LOG_INF("TLS", "%s presents %s certificate %s", host.c_str(), out.firstUse ? "an unknown" : "a changed",
          out.fingerprint.c_str());
  return true;
}

bool acceptOffer() {
  if (!havePending) return false;
  Storage.ensureDirectoryExists("/.crosspoint");
  if (!Storage.writeFile(ANCHOR_PATH, String(serialize(pending).c_str()))) {
    LOG_ERR("TLS", "Could not save %s", ANCHOR_PATH);
    return false;
  }
  anchor = pending;
  haveAnchor = true;
  loaded = true;
  havePending = false;
  trustPem.clear();
  LOG_INF("TLS", "Trusted %s for %s", formatFingerprint(anchor.fingerprint).c_str(), anchor.host.c_str());
  return true;
}

}  // namespace orbify::server_tls
#endif

