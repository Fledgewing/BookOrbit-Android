# Shared fixtures

Responses that both platforms' tests read, so Android and Xteink agree on the same input.
Each file is shaped like the real response; prefer recording one (with secrets and personal data
removed) over writing one by hand.

| File | Response | Read by |
|---|---|---|
| `bookorbit/finish-cases.json` | Not a recording: the end-of-book tables (`docs/design/end-of-book/DESIGN.md` §3, §6, §7): the next/suggestion/author picker over the `catalog-book.*.json` details, the drain guard, error backoff and the stale-push hold | Android's end-of-book tests; `xteink/test/finish_test.cpp`, `xteink/test/end_of_book_test.cpp` |
| `bookorbit/finish-steps.json` | Not a recording: the Xteink drain request by request (book-states, match-check for a sideloaded book, guard, read-status, rating) with the job state after each answer | `xteink/test/finish_test.cpp` |
| `github/orbify-releases.json` | GitHub `GET /repos/Fledgewing/Orbify/releases`: Android (`android-v`, `v`) and firmware (`xteink-v`) releases mixed, stable and pre-release | `android/companion` `UpdatePolicyTest`, `android/koreader-patch/test/test_logic.lua`, `xteink/test/ota_release_pick_test.cpp` |
| `bookorbit/catalog-dashboard-section.want-to-read.json` | `GET …/catalog/dashboard/sections/want-to-read`, recorded from the e2e server (synthetic library) | the plugin's sleep-screen pool tests (`android/koreader/test/test_logic.lua`) |
| `sleep/cases.json` | Not a recording: the sleep screen's rotation rule and fallbacks (`docs/design/lock-screen.md` R4, F1, F4) | `android/companion` `SleepScreenLogicTest`; later the Xteink `SleepPick` host test |
| `opds/recent-feed.xml` | `GET /api/v1/opds/recent` as BookOrbit v3.9.0 writes it (synthetic books, made-up cover token): one book without a cover, one with image links | `android/companion` `SharpCoversLogicTest`, `SharpCoversTest` |
| `e2e/library.json` | Not a recording: the synthetic library the emulated release tests seed into a real BookOrbit server (series, authors, standalones, a want-to-read shelf, books by role) | `tools/e2e/kit.py`, `xteink/test/e2e/run.py` |
| `e2e/faults/*.json` | Not a recording: fault-proxy rule sets (`{"rules": [...]}`, `tools/e2e/bofault.py`), e.g. `offline.json` drops every connection | `xteink/test/e2e/run.py`, `tools/e2e/test_kit.py` |

BookOrbit server responses go under `bookorbit/`, named after the route, when a test needs one.
