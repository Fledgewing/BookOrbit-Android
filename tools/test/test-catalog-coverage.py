#!/usr/bin/env python3
"""Compare the shared refresh inventory with the pinned browser and server source.
Run tools/upstreams sync bookorbit first. --write updates the reviewable inventory.
"""
import hashlib
import json
import re
import sys
from urllib.parse import parse_qsl
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def inventory(upstream):
    plugin = upstream / "koreader-plugin/bookorbit.koplugin"
    def read(name):
        return (plugin / ("bookorbit_" + name + ".lua")).read_text()
    def table(text, name):
        match = re.search(r"(?:local |CatalogUtil\.)" + name + r" = \{(.*?)\n\}", text, re.S)
        assert match, name
        return match[1]
    def params(text):
        return dict(re.findall(r'(\w+) = "([^"\n]+)"', text))
    server = (upstream / "server/src/modules/koreader/koreader-catalog.service.ts").read_text()
    root = re.search(r"const ROOT_SECTIONS:.*?= \[(.*?)\n\];", server, re.S)[1]
    root_books = {}
    for entry in re.findall(r"\{([^{}]*(?:\$\{CATALOG_BASE\}[^{}]*)?)\}", root, re.S):
        kind = re.search(r"section: '([^']+)'", entry)
        href = re.search(r"booksHref: `\$\{CATALOG_BASE\}/books\?([^`]+)`", entry)
        if kind and href:
            root_books[kind[1]] = dict(parse_qsl(href[1]))
    assert root_books, "server book rows not extracted"
    sections = re.findall(r"section: '([^']+)'", root)
    board = read("catalog_board")
    shelves = {key: params(value) for key, value in re.findall(r'\["([^"\n]+)"\] = \{([^}]+)\}', table(board, "SHELF_PARAMS"))}
    util = read("catalog_util")
    lists = read("catalog_lists")
    section_keys = re.findall(r"case '([^']+)':", server.split("async getSectionEntries(")[1].split("async getBooksPage(")[0])
    endpoint_types = re.findall(r'\["([^"\n]+)"\] = true', table(read("dashboard_sections"), "SECTION_ENDPOINT_TYPES"))
    section_sheet = lists.split('local by_books =', 1)[1].split('function CatalogLists:', 1)[0]
    api = read("api")
    selectors = {}
    entry_params = read("catalog").split("function BookOrbitCatalog:paramsForEntry", 1)[1].split("\nend", 1)[0]
    for section, body in re.findall(r'(?:if|elseif) section == "([^"\n]+)" then(.*?)(?=elseif section|\n    end)', entry_params, re.S):
        selectors[section] = list(dict.fromkeys(re.findall(r'params\.(\w+) =', body)))
    return {
        "schema": 1,
        # Fail closed on a new navigation/control path, even if it is not recognized by the
        # extractors yet. Re-pins require reviewing routing before regenerating this fixture.
        "source_sha256": {name: hashlib.sha256(read(name).encode()).hexdigest() for name in
                          ["catalog", "catalog_board", "catalog_lists", "catalog_dashboard", "catalog_util", "dashboard_sections", "api"]},
        "root_sections": sections,
        "root_books": root_books,
        "sections": section_keys,
        "selectors": selectors,
        "home_books": shelves,
        "dashboard_sections": endpoint_types,
        "book_sorts": re.findall(r'id = "([^"\n]+)"', table(util, "SORTS")),
        "list_sorts": re.findall(r'"([^"\n]+)"', re.search(r"local SORT_IDS = \{([^}]+)\}", lists)[1]),
        "series_sorts": re.findall(r'id = "([^"\n]+)"', table(lists, "SERIES_SORTS")),
        "read_statuses": re.findall(r'id = "([^"\n]+)"', table(util, "READ_STATUS_FILTERS")),
        "formats": re.findall(r'"([^"\n]+)"', re.search(r"CatalogUtil.COMMON_FORMATS = \{([^}]+)\}", util)[1]),
        "section_sorts": [re.search(r'local sort = opts.sort or "([^"\n]+)"', lists)[1], *re.findall(r's\.sort == "([^"\n]+)"', section_sheet)],
        "section_filters": re.findall(r's\.filter == "([^"\n]+)"', section_sheet),
        "orders": sorted(set(re.findall(r'(asc|desc) =', table(util, "DIRECTION_LABELS")))),
        "local_limits": {key.lower(): int(value) for key, value in re.findall(r'CatalogUtil\.(ON_DEVICE_MAX_IDS|NOT_ON_DEVICE_MAX_IDS|NOT_ON_DEVICE_SCAN_PAGES|NOT_ON_DEVICE_SCAN_SIZE) = (\d+)', util)},
        "local_lists": ["on-device", "not-on-device"],
        "entries": [re.search(r'request\("GET", "/koreader/plugin/catalog/([^"\n]+)"', api.split("function BookOrbitApi:" + name + "()", 1)[1])[1]
                    for name in ["catalogRoot", "catalogDashboard", "catalogDiscover"]],
    }

if __name__ == "__main__":
    upstream = Path(next((a for a in sys.argv[1:] if a != "--write"), ROOT / "upstream/bookorbit"))
    pin = next(line.split()[3] for line in (ROOT / "tools/upstreams.lock").read_text().splitlines() if line.startswith("bookorbit "))
    import subprocess
    assert subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip() == pin, "coverage must use the pinned source"
    got = inventory(upstream)
    fixture = ROOT / "shared/fixtures/catalog/sections.json"
    if "--write" in sys.argv:
        fixture.write_text(json.dumps(got, indent=2) + "\n")
    else:
        assert json.loads(fixture.read_text()) == got, "Browsable catalog changed: update sections.json AND the Full refresh coverage tests"
        print("catalog coverage: shared inventory matches pinned server index and browser routing/controls")
