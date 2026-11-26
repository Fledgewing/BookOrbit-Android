# BookSync Home design checks

These are the revision-14 (critic rounds 2–9) browser probes and screenshot tools.
They test the HTML simulation, not native firmware, real accounts or backend APIs.
The approved presentation is `docs/design/booksync-home/prototype.html` and its
companion `DESIGN-NOTES.md`. The existing `DESIGN.md` retains native integration,
adapter and flash evidence; revision 14 supersedes its earlier visual prototype.
The maintainer signed off on 2026-11-25 and authorized Android-first
implementation on `feature/0.12`; this bundle remains design artifacts.

Install Playwright in an isolated directory outside the checkout, then install its
Chromium browser with that installation's `playwright install chromium` command.
Set `NODE_PATH` to that installation's `node_modules`. `PWX` optionally selects a
Chromium executable; otherwise Playwright uses its installed browser.

Every runnable probe takes **prototype filename, output directory**, then any
probe-specific arguments. Run from the repository root, for example:

```sh
node tools/design-checks/pwtools/verify.js docs/design/booksync-home/prototype.html /tmp/booksync-review
node tools/design-checks/pwtools/sweep.js docs/design/booksync-home/prototype.html /tmp/booksync-review
node tools/design-checks/r3/flows3.js docs/design/booksync-home/prototype.html /tmp/booksync-review
node tools/design-checks/r3/focus.js docs/design/booksync-home/prototype.html /tmp/booksync-review
node tools/design-checks/run-suite.js docs/design/booksync-home/prototype.html /tmp/booksync-review
```

`run-suite.js` runs the functional/layout checks, saves diagnostic logs outside the
checkout, and returns a nonzero status for assertion errors, logged failures,
overflow, weak focus or browser errors. Earlier critic probes are diagnostic:
`measure.js` and `r2/m2.js` print target/overflow counts, `r2/fuzz.js` prints invalid
layout counts, and the Classic probes print focus traversal. Inspect these logs
as well as the formal flow/focus results. Set `DEV=x4pro` to repeat `m2.js` for Pro.
No browser probe should contact a server; all data is synthetic.

## Regenerate screenshots

```sh
DSF=2 node tools/design-checks/pwtools/shoot.js docs/design/booksync-home/prototype.html /tmp/booksync-shots m8c
node tools/design-checks/pwtools/shoot.js docs/design/booksync-home/prototype.html /tmp/booksync-shots x4pro
node tools/design-checks/pwtools/shoot.js docs/design/booksync-home/prototype.html /tmp/booksync-shots x4c
node tools/design-checks/r3/flows3.js docs/design/booksync-home/prototype.html /tmp/booksync-shots
node tools/design-checks/r3/focus.js docs/design/booksync-home/prototype.html /tmp/booksync-shots
```

M8C uses device scale factor 2 for native 1404×1872 captures; X4 captures are
480×800. `r3/shots.js` takes a device followed by pairs of screenshot name and
JavaScript setup expression; it is a trusted local development tool, not an
input endpoint. `v4.js` makes a full-browser screenshot named `screen.png`.
`dbg.js`, `r2/st.js` and `r2/smoke.js` are supplementary diagnostic captures.
All outputs go under the supplied directory. Do not commit generated logs or
browser dependencies.

The requested source bundle also includes **non-runnable prototype fragments**:
`pwtools/widgets.js`, `pwtools/r2/{battery,booklist,settings}.js` and `r3/filter.js`.
They document the reviewed prototype's construction, refer to its globals and
are already incorporated in the self-contained HTML; do not run them as Node
programs or concatenate them into the final artifact again. `critic-shots/`
keeps the original critic probe grouping; `r3/` contains the later flow/focus
checks supplied alongside `pwtools`. Only path/dependency/output portability
changes were made to the imported probes; the suite runner and compatibility
test entry point are new.

All 182 supplied PNG screenshots are retained as lossless WebP (about 5.7 MiB)
in `docs/design/booksync-home/shots/`; none was omitted. `mockups.html` is the
browseable gallery. Pixel equivalence and absence of copied metadata were
checked against the supplied PNGs. Scripts regenerate PNG; convert those to
lossless WebP for publishing. These captures cover M8C, X4 Pro and X4 Classic;
X3's text fallbacks are specified in the notes rather than simulated as a fourth
device. The prior native integration audit remains a design constraint.

## Rounds 5–6

The current filter is one screen of nine rows, with separate picker screens.
`r3/flows3.js` now has 137 assertions covering picker navigation, counts from the
other filters, zero-count ordering, retained ticked values, matching footer/list
totals, and absent one-page navigation. `r3/focus.js` checks 137 steps, including
15 dark controls. `critic-shots/r5/*.js` adds the supplied picker, count, battery
and Classic traversal diagnostics; `pwtools/sweep.js` now checks “at your usual
use” at every battery-widget size. All are included in the suite.

The earlier `critic-shots/r3/{dark,filt,filt2}.js` probes are retained as historical
review evidence, but exercise the superseded inline/paged filter controls and
are no longer current acceptance checks. Their coverage is replaced by the
updated assertion-based flow/focus checks and the round-5/6 picker probes; the
other earlier checks still run. The suite also rejects missing sheets, clipped
or out-of-bounds picker diagnostics. The imported `r3` update was supplied beside
`pwtools`, rather than inside the design artifact directory.

## Rounds 7–9 and final sign-off

Revision 14 is the signed-off final prototype. The updated `r3/flows3.js` has
303 assertions covering login origins, the independent account/sync/OPDS forms,
selective sign-out, phone-code flows/errors, stats labels and channel dropdown.
The r8/r9 exploratory probes preserve the supplied review evidence. Run the
portable full-check entry point with the same two arguments:

```sh
bash tools/design-checks/r3/all.sh docs/design/booksync-home/prototype.html /tmp/booksync-review
```

It delegates to the failure-reporting suite instead of the original workstation
shell environment and tail-only pipeline. All review artifacts go under the
supplied output directory. The round-8 `si.js` Two-step branch and `form.js`
last Sign-in-again probe can print “cannot reach” because the current phone flow
already signs in and the signed-out page has no old Sign-in-again row. `so.js`
uses the retained-own-logins state, where Home correctly stays Synced. These are
exploratory traces, not failed assertions; `flows3.js` tests the current behavior.
The supplied updated baseline browser probes are ported for the new controls.
Fictional reader-derived usernames in origin tests distinguish independently
set login credentials; they identify no person or real account.
