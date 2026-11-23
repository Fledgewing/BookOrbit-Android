# Shared fixtures

Responses that both platforms' tests read, so Android and Xteink agree on the same input.
Each file is shaped like the real response; prefer recording one (with secrets and personal data
removed) over writing one by hand.

| File | Response | Read by |
|---|---|---|
| `bookorbit/finish-cases.json` | Not a recording: the end-of-book tables (`docs/design/end-of-book/DESIGN.md` §3, §6, §7): the next/suggestion/author picker over the `catalog-book.*.json` details, the drain guard, error backoff and the stale-push hold | Android's end-of-book tests; `xteink/test/finish_test.cpp`, `xteink/test/end_of_book_test.cpp` |
| `bookorbit/finish-steps.json` | Not a recording: the Xteink drain request by request (book-states, match-check for a sideloaded book, guard, read-status, rating) with the job state after each answer | `xteink/test/finish_test.cpp` |
| `github/orbify-releases.json` | GitHub `GET /repos/Fledgewing/Orbify/releases`: Android (`android-v`, `v`) and firmware (`xteink-v`) releases mixed, stable and pre-release | `android/companion` `UpdatePolicyTest`, `android/koreader-patch/test/test_logic.lua`, `xteink/test/ota_release_pick_test.cpp` |

BookOrbit server responses go under `bookorbit/`, named after the route, when a test needs one.
