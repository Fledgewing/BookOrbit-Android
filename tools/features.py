#!/usr/bin/env python3
"""Render the source-audited support matrix; JSON is the editable source of truth."""
import argparse
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYMBOLS = {"supported": "✅", "partial": "🟡", "missing": "❌", "not_applicable": "➖"}


def citations(items):
    return ", ".join(
        f"[{e['path']}:{e['line']}]"
        f"({'https://github.com/' + e['repository'] + '/blob/' + e['revision'] + '/' if 'repository' in e else '../'}{e['path']}#L{e['line']})"
        for e in items
    )


def render(data):
    platforms = data["platforms"]
    out = ["# Orbify feature support matrix", "",
           f"Source audit at `{data['audited_revision']}`. {data['scope']}", "",
           "Generated from [`shared/features.json`](../shared/features.json) by `python3 tools/features.py`. "
           "Edit the JSON and regenerate; `python3 tools/test/test-features.py` checks schema coverage, citations and document parity.", "",
           "✅ shipped in the cited version; 🟡 partial (details in the cell); ❌ missing; ➖ not applicable. "
           "Versions are verified presence baselines, not first introduction dates. Xteink 2.x is a release candidate, "
           "not a claim that the stable 1.6 readers have these features. Every partial/missing cell states a hardware constraint, "
           "a specific deferral or **gap — no reason**. A macro cut proves exclusion, not that enabling it is impossible.", ""]
    for name, text in data["release_evidence"].items():
        out.append(f"- **{name}:** {text}")
    out += ["", "## Counts", "", "Counts include settings exposure as separate rows; they are not feature quality scores.", "",
            "| Platform | ✅ | 🟡 | ❌ | ➖ |", "|---|---:|---:|---:|---:|"]
    for p, meta in platforms.items():
        counts = Counter(f["platforms"][p]["status"] for f in data["features"])
        out.append("| " + meta["label"] + " | " + " | ".join(str(counts[s]) for s in SYMBOLS) + " |")
    for category in dict.fromkeys(f["category"] for f in data["features"]):
        out += ["", "## " + category, ""]
        if category == "Settings exposure":
            out += ["Every key in `shared/settings/schema.json` appears below. ✅ means an exposed control or native equivalent, "
                    "not merely a stored value. Wire names can differ. Android rows are conditional on their schema parent and device capability; "
                    "the internal `recommended_choice` key is deliberately hidden. Companion-only controls need not also appear in KOReader.", ""]
        out += ["| Feature / behaviour | Android (M8C / Boox) | X4 Pro | X4 classic | X3 |", "|---|---|---|---|---|"]
        for f in data["features"]:
            if f["category"] != category:
                continue
            cells = []
            for p in platforms:
                c = f["platforms"][p]
                version = f" ({c['version']})" if c["status"] == "supported" else ""
                reason = f"; **{c['reason']}**" if c.get("reason") else ""
                cells.append(f"{SYMBOLS[c['status']]}{version} {c['note']}{reason}. {citations(c['evidence'])}".replace("|", "\\|"))
            out.append("| " + f["feature"] + " | " + " | ".join(cells) + " |")
    c = data["constraints"]
    out += ["", "## Measured constraints", "",
            f"[CI run {c['run_id']}]({c['url']}), started {c['created_at']}, commit `{c['revision']}`. {c['qualification']}", "",
            f"Each application slot is {c['flash_slot_bytes']:,} bytes; CI stops at 99.5%. These are final application summaries, "
            "excluding the misleading small intermediate ESP-IDF image. Raw remaining bytes include the reserved 0.5%; only the gate margin is spendable.", "",
            "| Device / build | MCU / PSRAM | Flash used | Raw flash remaining | Below 99.5% gate | Static RAM used / total | Static RAM remainder |",
            "|---|---|---:|---:|---:|---:|---:|"]
    for p, d in c["devices"].items():
        out.append(f"| {platforms[p]['label']} / `{d['env']}` | {d['mcu']} / {d['psram_bytes']:,} B | "
                   f"{d['flash_used_bytes']:,} B ({d['flash_percent']}%) | {c['flash_slot_bytes']-d['flash_used_bytes']:,} B | "
                   f"{d['under_gate_bytes']:,} B | {d['static_ram_used_bytes']:,} / {d['static_ram_total_bytes']:,} B | "
                   f"{d['static_ram_total_bytes']-d['static_ram_used_bytes']:,} B |")
    out += ["", "Build selection and generated `CrossInkTailnetCuts.h` inputs: " + citations(c["evidence"]) + ". "
            "The header is added by patch 0004; the per-environment SWITCHES table supplies explicit values. "
            "Both S3 readers have PSRAM but limited application flash; X3 has neither PSRAM nor room for the current open-book TLS path.", ""]
    for hardware in data["hardware"]:
        out.append(f"- **{platforms[hardware['platform']]['label']}:** {hardware['description']}. {citations(hardware['evidence'])}")
    out += ["", "Upstream citations use the CrossInk commit in `tools/upstreams.lock` and its pinned FreeInk SDK gitlink, "
            "not moving upstream branches.", "", "| Feature cost / bound | Evidence and interpretation |", "|---|---|"]
    for cost in c["costs"]:
        out.append(f"| {cost['feature']} | {cost['cost']} {citations(cost['evidence'])} |")
    out += ["", "## Prioritised parity bugs", "",
            "Only unexplained UI/behaviour gaps are prioritised here. Sizes are engineering estimates (S: about 1–2 days; "
            "M: several days), not measured binary deltas. X3 fit is a candidate assessment, never a build guarantee. "
            "No changes to firmware or UI are authorised by this audit; design and mockup approval still apply.", "",
            "| Priority | Gap / outcome | Platforms | Rough size | X3 fit |", "|---|---|---|---|---|"]
    for gap in data["gaps"]:
        out.append(f"| {gap['priority']} | {gap['outcome']} (rows: {', '.join(gap['features'])}) | "
                   f"{', '.join(platforms[p]['label'] for p in gap['platforms'])} | {gap['size']} | {gap['x3_fit']} |")
    out += ["", "Approved/deferred work is separate: " + "; ".join(
        f"**{d['feature']}** — [ROADMAP {d['roadmap']}](../ROADMAP.md): {d['note']}" for d in data["deferred"]) + ".", "",
        "## Scope and interpretation", ""]
    out += ["- " + s for s in data["limitations"]]
    out += ["", "Server behaviour behind the overlays: [finish threshold](server-contract.md#progress-finishes-a-book-only-at-the-librarys-threshold), "
            "[stale-push guard](server-contract.md#the-stale-push-guard-compares-send-times), "
            "[metadata/file hashes](server-contract.md#a-metadata-write-changes-the-file-hash). "
            "Shared executable examples: [bulk catalog](../shared/fixtures/catalog/bulk-refresh/catalog.json), "
            "[position sync](../shared/fixtures/orbismart/cases.json), [reading gate](../shared/fixtures/reading-quiet/cases.json), "
            "[sleep layout](../shared/fixtures/sleep/cases.json). Fixtures support tests; they do not prove a disabled device feature ships.", ""]
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    data = json.loads((ROOT / "shared/features.json").read_text())
    output = render(data)
    path = ROOT / "docs/FEATURES.md"
    if args.check:
        if path.read_text() != output:
            raise SystemExit("docs/FEATURES.md is stale; run python3 tools/features.py")
    else:
        path.write_text(output)


if __name__ == "__main__":
    main()
