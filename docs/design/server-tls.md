# The BookOrbit server's certificate on Xteink readers

**Status:** shipped on the X4 Pro and X4 Classic (switch `CROSSINK_TAILNET_ORBIFY_SERVER_TLS`,
overlay patch 0051). Not on the X3: see the table at the end.

## Problem

CrossInk's wolfSSL transport has no CA bundle. So every HTTPS request skips the certificate check
(`setInsecure()`), including the catalog, downloads and sync to the BookOrbit server. Those requests
carry the user's BookOrbit credentials (Basic auth, `x-auth-user`/`x-auth-key`).

Over Tailscale this is harmless, because WireGuard authenticates the peer. But when a reader reaches
a public HTTPS URL, anyone on the same Wi-Fi could pose as the server, collect the password and
change the books that are downloaded.

## Design

Only requests to the configured BookOrbit server's host, over `https`, are verified.

`SecureHttpClient::setCACert()` replaces `setInsecure()` for those requests. It takes:

1. **Built-in roots:** ISRG Root X1 and X2 (Let's Encrypt). Most self-hosted servers use them, and so
   do `tailscale cert` certificates. With one of these, nothing changes for the user.
2. **The certificate the user trusted (trust on first use).** When the BookOrbit login on the reader
   (**Settings > BookOrbit > Authenticate**) gets no answer, the reader runs a handshake with the
   server that sends no request. From it, the reader reads the top certificate of the chain the server
   presents and shows its SHA-256 fingerprint:
   - **Unknown server certificate**: the first use;
   - **Server certificate changed**: another certificate is trusted for this server already, so this
     is the re-trust step.

   **Confirm** trusts it, and the login runs again. **Back** trusts nothing. The certificate is kept
   with its host in `/.crosspoint/bookorbit-server-cert.txt`. A file for another host, or a damaged
   one, trusts nothing.

wolfSSL also checks the host name (`wolfSSL_check_domain_name`). So a certificate must name the host
in the server URL, even when it is trusted by fingerprint.

**Not verified, as before:**
- tailnet hosts: `100.64.0.0/10`, `*.ts.net`, and single-label MagicDNS names while Tailscale is on.
  WireGuard already authenticates them;
- `http://` URLs;
- every other host: OPDS catalogs, fonts and firmware downloads. Firmware has its own checks:
  the feed's digest and signatures.

**Credentials:** a check that fails ends the handshake before the request is sent. So the
credentials never go over a connection that wasn't verified.

The pure logic (which requests are verified, the pin states, the saved form) is
`xteink/orbify/core/ServerTrust`. It has a host test, `xteink/test/server_trust_test.cpp`, which
covers:
- the first use;
- a match and a mismatch;
- the re-trust step;
- the exemption for tailnet hosts.

The device side is `xteink/orbify/ServerTrustNet.cpp`.

## Per reader

| Reader | Server check | Why |
|---|---|---|
| X4 Pro, X4 Classic | on | |
| X3 / X4 (`default`) | off: unverified, as before | It costs ~9.6 KB of flash (the code, the two roots and wolfSSL's chain checks). The X3 had 7.7 KB left under the 99.5% gate. |

**X3 users with a public HTTPS BookOrbit URL:** reach the server over Tailscale (the recommended
setup). Don't sign in over a public HTTPS URL on shared
Wi-Fi.
