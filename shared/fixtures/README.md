# Shared fixtures

Responses that both platforms' tests read, so Android and Xteink agree on the same input.
Each file is shaped like the real response; prefer recording one (with secrets and personal data
removed) over writing one by hand.

| File | Response | Read by |
|---|---|---|
| `github/orbify-releases.json` | GitHub `GET /repos/Fledgewing/Orbify/releases`: Android (`android-v`, `v`) and firmware (`xteink-v`) releases mixed, stable and pre-release | `android/companion` `UpdatePolicyTest`, `android/koreader-patch/test/test_logic.lua`, `xteink/test/ota_release_pick_test.cpp` |

BookOrbit server responses go under `bookorbit/`, named after the route, when a test needs one.
