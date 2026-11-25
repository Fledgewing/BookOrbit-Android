// Design-prototype UI checks only. No device or backend access.
// Use an isolated Playwright install; NODE_PATH=<install>/node_modules node tools/test/test-booksync-home-prototype.cjs
// Install its Chromium browser before running. Screenshots/artifacts are not written.
const { chromium } = require("playwright");
const assert = require("node:assert/strict");
const { resolve } = require("node:path");
const { pathToFileURL } = require("node:url");
const prototypeUrl = pathToFileURL(
  resolve(__dirname, "../../docs/design/booksync-home/prototype.html"),
).href;
async function flowChecks() {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 1300, height: 1100 },
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  await page.goto(prototypeUrl);
  console.log("load", await page.locator(".tile").count(), errors);
  assert.equal(await page.locator(".tile").count(), 4);
  const act = (a) => page.locator('#screen [data-act="' + a + '"]');
  const reset = () => page.locator("#demo-reset").click();
  // Local open and return.
  await page.locator('[data-act="book"][data-book="b1"]').click();
  await page.getByText("This synthetic reader demonstrates").waitFor();
  await act("back").first().click();
  // Download and cancel before completion, then retry and auto-open.
  await page.locator('[data-act="book"][data-book="b2"]').click();
  await page.locator('[data-transfer="b2"]').waitFor();
  await page.waitForTimeout(350);
  await page.locator('[data-act="cancel"][data-book="b2"]').click();
  assert.equal(await page.locator('[data-transfer="b2"]').count(), 0);
  await page.locator('[data-act="book"][data-book="b2"]').click();
  await page.getByText("This synthetic reader demonstrates").waitFor();
  await act("back").first().click();
  // Offline prompt does not queue before consent.
  await reset();
  await page.locator("#offline").check();
  await page.locator('[data-act="book"][data-book="b2"]').click();
  await page
    .getByRole("dialog", { name: "Not downloaded — connect to get it" })
    .waitFor();
  assert.equal(await page.locator("[data-transfer]").count(), 0);
  await act("close").click();
  await page.locator('[data-act="book"][data-book="b2"]').click();
  await act("connect").click();
  await page.getByText("This synthetic reader demonstrates").waitFor();
  await act("back").first().click();
  await reset();
  await page.locator("#offline").uncheck();
  // Actual pointer hold opens actions, details, mark-read and remove confirmation.
  const book = page.locator('[data-act="book"][data-book="b1"]');
  await book.hover();
  await page.mouse.down();
  await page.waitForTimeout(650);
  await page.mouse.up();
  await page.getByRole("dialog", { name: "The Lantern" }).waitFor();
  await act("detail").click();
  await page.getByText("Description", { exact: true }).waitFor();
  await act("book-menu").click();
  await act("mark").click();
  assert.match(
    await page.locator('[data-act="book"]').first().innerText(),
    /read/,
  );
  await act("book-menu").click();
  await act("remove-confirm").click();
  await page.getByRole("dialog", { name: "Remove this download?" }).waitFor();
  await act("remove").click();
  assert.match(
    await page.locator('[data-act="book"]').first().innerText(),
    /Server only/,
  );
  // Series exact next 3 and sequential bulk, no automatic open.
  await reset();
  await page
    .locator('[data-act="book"][data-book="b1"]')
    .dispatchEvent("contextmenu");
  await act("series").click();
  await act("bulk-preview").click();
  assert.deepEqual(await page.locator(".dialog li").allTextContents(), [
    "Glass Harbor",
    "The Small Tide",
    "The Last Light",
  ]);
  await act("bulk-start").click();
  await page.waitForFunction(
    () =>
      document
        .querySelector("#queue-summary")
        ?.textContent.includes("On device 3"),
    null,
    { timeout: 15000 },
  );
  assert.equal(await page.locator(".reader").count(), 0);
  await act("back").first().click();
  // Tabs, paging and every content widget can render.
  for (const t of ["Insights", "Library", "More", "Home"])
    await page.locator('[data-act="tab"][data-tab="' + t + '"]').click();
  await act("page").last().click();
  assert.match(await page.locator(".pagebar").innerText(), /2 \/ 2/);
  // Editor add/move/resize/remove/page operations and reset.
  await page.locator('[data-act="tab"][data-tab="More"]').click();
  await act("edit").click();
  await act("add-page").click();
  await act("picker").click();
  assert.match(
    await page.locator(".picker").innerText(),
    /coming in a later release/,
  );
  await page.locator('[data-widget="shelf"]').click();
  await page
    .locator('[data-act="step"][data-field="x"][data-step="1"]')
    .click();
  await page
    .locator('[data-act="step"][data-field="h"][data-step="1"]')
    .click();
  await page.locator("#show-json").check();
  let doc = JSON.parse(await page.locator("#layout-json").innerText());
  let custom = doc.pages
    .flatMap((p) => p.placements)
    .find((p) => p.instance.startsWith("custom-"));
  assert.equal(doc.overrides["android-tablet"][custom.instance].x, 1);
  assert.equal(doc.overrides["android-tablet"][custom.instance].h, 3);
  await act("settings").click();
  await page.locator("#tile-source").selectOption("unopened");
  await act("apply-source").click();
  await act("reorder").first().click();
  await act("remove-tile").click();
  assert.equal(await page.locator(".tile").count(), 0);
  await act("remove-page").click();
  await act("reset").click();
  await act("confirm-reset").click();
  await act("done").click();
  // Isolation card states and starter set.
  await page.locator("summary").click();
  await page.locator("#state-demo").selectOption("error");
  assert.match(
    await page.locator(".tile").first().innerText(),
    /could not load/,
  );
  assert.ok((await page.locator(".tile").count()) > 1);
  await act("retry").click();
  await page.locator("#preview").uncheck();
  await page.locator('[data-act="tab"][data-tab="Home"]').click();
  assert.equal(await page.locator(".preview").count(), 0);
  await page.locator("#preview").check();
  // X4 Pro touch and Classic virtual buttons: focus book, More, detail, Select open.
  await reset();
  await page.locator("#device").selectOption("x4");
  await page.locator('[data-act="book"][data-book="b1"]').click();
  await page.getByText("This synthetic reader demonstrates").waitFor();
  await page.locator('#virtual [data-key="back"]').click();
  await page.locator("#mode").selectOption("classic");
  await page.locator('[data-act="book"][data-book="b1"]').click();
  await page.locator('#virtual [data-key="more"]').click();
  await page.getByRole("dialog", { name: "The Lantern" }).waitFor();
  await page.locator('#virtual [data-key="next"]').click();
  await page.locator('#virtual [data-key="select"]').click();
  await page.getByText("Description", { exact: true }).waitFor();
  await page.locator('#virtual [data-key="back"]').click();
  // Classic edit movement uses only virtual keys once the tile is selected.
  await page.locator('[data-act="tab"][data-tab="More"]').click();
  await act("edit").click();
  await act("add-page").click();
  await act("picker").click();
  await page.locator('[data-widget="shelf"]').click();
  let before = JSON.parse(await page.locator("#layout-json").innerText());
  let id = before.pages
    .flatMap((p) => p.placements)
    .find((p) => p.instance.startsWith("custom-")).instance;
  await page.locator('#virtual [data-key="select"]').click();
  await page.locator('#virtual [data-key="next"]').click();
  let after = JSON.parse(await page.locator("#layout-json").innerText());
  assert.equal(after.overrides.x4[id].x, before.overrides.x4[id].x + 1);
  await page.locator('#virtual [data-key="more"]').click();
  await page.locator('#virtual [data-key="next"]').click();
  await page.locator('#virtual [data-key="back"]').click();
  assert.deepEqual(errors, []);
  console.log(
    "PASS: book open/download/cancel/offline, long press/menu/details/mark/remove, series exact bulk, all tabs/pages, editor operations, isolation, starter, X4 Pro/Classic controls; no console/page errors.",
  );
  await browser.close();
}
async function widgetChecks() {
  const b = await chromium.launch(),
    p = await b.newPage({ viewport: { width: 1300, height: 1050 } }),
    errors = [];
  p.on("pageerror", (e) => errors.push(String(e)));
  p.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  await p.goto(prototypeUrl);
  // Semantic catalog coverage: every declared widget and all seven shelf settings exist.
  let coverage = await p.evaluate(() => ({
    ids: new Set(layout.pages.flatMap((p) => p.placements.map((q) => q.widget)))
      .size,
    missing: catalog
      .filter(
        (w) =>
          !layout.pages.some((p) =>
            p.placements.some((q) => q.widget === w.id),
          ),
      )
      .map((w) => w.id),
    sources: layout.pages.flatMap((p) =>
      p.placements
        .filter((q) => q.widget === "shelf")
        .map((q) => q.settings.source),
    ),
  }));
  assert.deepEqual(coverage.missing, []);
  assert.equal(new Set(coverage.sources).size, 7);
  // Unknown fields/widget/version survive an edit save; invalid data rejected.
  let result = await p.evaluate(() => {
    layout.future = { keep: "opaque" };
    layout.pages[0].placements.push({
      instance: "future-one",
      widget: "future-widget",
      version: 9,
      x: 0,
      y: 9,
      w: 1,
      h: 2,
      settings: { keep: ["opaque"] },
      futureFlag: true,
    });
    validate(layout);
    const visible = tiles().some((q) => q.instance === "future-one");
    mutate(() => layout.revision++);
    let bad = structuredClone(layout);
    bad.pages[0].placements[0].w = 99;
    let rejected = false;
    try {
      validate(bad);
    } catch {
      rejected = true;
    }
    return {
      visible,
      preserved: layout.pages[0].placements.at(-1).settings.keep[0],
      rejected,
      opaque: layout.future.keep,
    };
  });
  assert.deepEqual(result, {
    visible: false,
    preserved: "opaque",
    rejected: true,
    opaque: "opaque",
  });
  // Fault in one renderer is contained; sibling book remains usable.
  await p.evaluate(() => {
    registry.shelf.renderers["android-tablet"] = () => {
      throw Error("synthetic widget fault");
    };
    render();
  });
  assert.ok(
    (await p
      .getByText("This widget could not load.", { exact: false })
      .count()) > 0,
  );
  await p.locator('[data-act="book"][data-book="b1"]').click();
  await p.locator(".reader").waitFor();
  await p.reload();
  // Data-stable sibling DOM is retained during transfer progress.
  await p.evaluate(
    () => (window.sibling = document.querySelector('[data-instance="tile-1"]')),
  );
  await p.locator('[data-act="book"][data-book="b2"]').click();
  await p.waitForTimeout(400);
  assert.equal(
    await p.evaluate(
      () =>
        window.sibling === document.querySelector('[data-instance="tile-1"]'),
    ),
    true,
  );
  await p.locator('[data-act="cancel"]').click();
  // All tab/page projections on both devices have bounded tile content and exact native canvas.
  for (const d of ["android-tablet", "x4"]) {
    await p.locator("#device").selectOption(d);
    assert.deepEqual(
      await p
        .locator("#screen")
        .evaluate((n) => [n.offsetWidth, n.offsetHeight]),
      d === "x4" ? [480, 800] : [1404, 1872],
    );
    for (const t of ["Home", "Insights", "Library", "More"]) {
      await p.locator('[data-tab="' + t + '"]').click();
      const n = await p.evaluate(() => pagesNow().length);
      for (let i = 0; i < n; i++) {
        const bad = await p.evaluate(() =>
          [...document.querySelectorAll(".tile")]
            .filter((n) => n.scrollHeight > n.clientHeight + 2)
            .map((n) => n.querySelector("h3").textContent),
        );
        assert.deepEqual(bad, [], d + " " + t + " " + i);
        await p.locator('[data-act="page"]').last().click();
      }
    }
  }
  // Button-only entry, operation list, picker, move, resize/error feedback.
  await p.locator("#demo-reset").click();
  await p.locator("#device").selectOption("x4");
  await p.locator("#mode").selectOption("classic");
  const key = (k) => p.locator('#virtual [data-key="' + k + '"]').click();
  async function chooseAction(a) {
    const steps = await p.evaluate((a) => {
      const ns = [...document.querySelectorAll(".dialog [data-focus]")];
      return ns.findIndex((n) => n.dataset.act === a);
    }, a);
    assert.ok(steps >= 0);
    for (let i = 0; i < steps; i++) await key("next");
    await key("select");
  }
  await key("more");
  const editIndex = await p.evaluate(() =>
    [...document.querySelectorAll("#screen [data-focus]")].findIndex(
      (n) => n.dataset.act === "edit",
    ),
  );
  for (let i = 0; i < editIndex; i++) await key("next");
  await key("select");
  await key("more");
  await chooseAction("add-page");
  await key("more");
  await chooseAction("picker");
  await key("next");
  await key("select");
  await key("select");
  await key("next");
  await key("more");
  await key("next");
  await key("more");
  await key("next");
  assert.match(await p.locator(".editbar").innerText(), /out of bounds/);
  await key("back");
  await key("more");
  await chooseAction("remove-tile");
  assert.equal(await p.locator(".tile").count(), 0);
  assert.deepEqual(errors, []);
  console.log(
    "PASS: 27 widgets/seven shelves, schema/unknown retention, renderer fault isolation, unchanged sibling DOM, all device/page tile bounds, Classic button-only add/remove/move and invalid resize, zero console errors.",
  );
  await b.close();
}
(async () => {
  await flowChecks();
  await widgetChecks();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
