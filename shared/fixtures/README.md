# Shared fixtures

Responses that both platforms' tests read, so Android and Xteink agree on the same input.
Each file is shaped like the real response; prefer recording one (with secrets and personal data
removed) over writing one by hand.

`REGISTRY.json` lists every table here: the rule each section holds, who owns the rule, and which
test suites must read it (`kt` the companion, `lua` the plugin, `cpp` the Xteink host tests, `py`
the e2e kit). A test that reads a section carries the mark `@fixture <file>#<section>` (or
`@fixture <file>` for a whole file). Each suite fails when a section names it and none of its
tests carries the mark, or when it marks a section the registry does not give it; the plugin's
suite also fails on a file or section with no row. A new table, or a rule that moves to another
owner, changes its row in the same change.

| File | Response |
|---|---|
| `bookorbit/finish-cases.json` | Not a recording: the end-of-book tables (`docs/design/end-of-book/DESIGN.md` §3, §6, §7): the next/suggestion/author picker over the `catalog-book.*.json` details, the drain guard, error backoff and the stale-push hold |
| `bookorbit/finish-steps.json` | Not a recording: the Xteink drain request by request (book-states, match-check for a sideloaded book, guard, read-status, rating) with the job state after each answer |
| `github/orbify-releases.json` | GitHub `GET /repos/Fledgewing/Orbify/releases`: Android (`android-v`, `v`) and firmware (`xteink-v`) releases mixed, stable and pre-release |
| `bookorbit/catalog-dashboard-section.want-to-read.json` | `GET …/catalog/dashboard/sections/want-to-read`, recorded from the e2e server (synthetic library) |
| `bookorbit/catalog-sections.smart-scopes.json`, `bookorbit/catalog-sections.collections.json` | `GET …/catalog/sections/smart-scopes` and `/collections` in the server's shape (`{section, items}`, ids as strings, no `count` on scopes past the shelf-extras cap); made up: 12 scopes, 1 collection |
| `status/format.json` | W17 shared page/progress and 12/24-hour clock format examples |
| `orbismart/cases.json` | BookSync position sync shared decisions, application moments and behind-hold (`docs/design/position-sync.md` §3) |
| `sleep/cases.json` | Not a recording: the sleep screen's rotation rule and fallbacks (`docs/design/lock-screen.md` R4, F1, F4) |
| `opds/recent-feed.xml` | `GET /api/v1/opds/recent` as BookOrbit v3.9.0 writes it (synthetic books, made-up cover token): one book without a cover, one with image links |
| `e2e/library.json` | Not a recording: the synthetic library the emulated release tests seed into a real BookOrbit server (series, authors, standalones, a want-to-read shelf, books by role) |
| `e2e/faults/*.json` | Not a recording: fault-proxy rule sets (`{"rules": [...]}`, `tools/e2e/bofault.py`), e.g. `offline.json` drops every connection |

BookOrbit server responses go under `bookorbit/`, named after the route, when a test needs one.
