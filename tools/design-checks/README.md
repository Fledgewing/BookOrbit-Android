# BookSync Home design checks

These are the revision-8 (critic rounds 2–4) browser probes and screenshot tools.
They test the HTML simulation, not native firmware, real accounts or backend APIs.
The approved presentation is `docs/design/booksync-home/prototype.html` and its
companion `DESIGN-NOTES.md`. The existing `DESIGN.md` retains native integration,
adapter and flash evidence; revision 8 supersedes its earlier visual prototype.
Maintainer sign-off is still required before implementation or merge.

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

All 138 supplied PNG screenshots are retained as lossless WebP (about 4.6 MiB)
in `docs/design/booksync-home/shots/`; none was omitted. `mockups.html` is the
browseable gallery. Pixel equivalence and absence of copied metadata were
checked against the supplied PNGs. Scripts regenerate PNG; convert those to
lossless WebP for publishing. These captures cover M8C, X4 Pro and X4 Classic;
X3's text fallbacks are specified in the notes rather than simulated as a fourth
device. The prior native integration audit remains a design constraint.
