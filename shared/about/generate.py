"""Generate small two-line firmware rows from the shared About notice."""
import json
from pathlib import Path
import textwrap


def rows(credits):
    return [line for paragraph in [*credits["paragraphs"][:2], credits["url"], *credits["paragraphs"][2:]]
            for line in textwrap.wrap(paragraph, width=48, break_long_words=False, break_on_hyphens=False)]


def generate(source, output):
    credits = json.loads(Path(source).read_text())
    lines = rows(credits)
    text = "// Generated from shared/about/credits.json; do not edit.\n#pragma once\n"
    text += "namespace OrbifyCredits {\n#if CROSSINK_TAILNET_ABOUT_CREDIT\nstatic constexpr const char* rows[] = {\n"
    text += "".join("  " + json.dumps(line) + ",\n" for line in lines)
    text += """};
static constexpr unsigned lineCount = sizeof(rows) / sizeof(rows[0]);
static constexpr unsigned count = (lineCount + 1) / 2;
template <typename Index, typename Item>
bool provideRow(Index& index, Item& item) {
  if (index < count) {
    item.label = rows[index * 2];
    item.subtitle = index * 2 + 1 < lineCount ? rows[index * 2 + 1] : "";
    return true;
  }
  index -= count;
  return false;
}
#else
static constexpr unsigned count = 0;
#endif
}
"""
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.read_text() != text:
        output.write_text(text)


if __name__ == "__main__":
    import sys
    generate(*sys.argv[1:])
