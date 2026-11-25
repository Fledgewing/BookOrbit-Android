#!/usr/bin/env python3
"""Supply-chain rules for .github/ (docs/design/release-signing.md, AGENTS.md "Releases"):

1. Every action is pinned by a full commit SHA, or is a local ./ action.
2. Every checkout leaves no credentials behind (persist-credentials: false).
3. A job that runs a build tool (pio, gradlew) holds no write permission, no secret and no
   token: those jobs run upstream or dependency code.
4. Workflow-level permissions are read-only; only named jobs may write.

Plain text checks, no YAML library, so it runs anywhere: python3 tools/test/test-workflows.py
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[2]
files = sorted((root / ".github/workflows").glob("*.yml")) + sorted((root / ".github/actions").glob("*/action.yml"))
errors = []

PINNED = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}(\s+#.*)?$")
BUILD_TOOL = re.compile(r"(^|[\s;&|(])(pio run|\./gradlew)\b")
WRITE = re.compile(r"^\s+(contents|packages|id-token|attestations|actions|deployments|pull-requests|issues|statuses|checks):\s*write\b", re.M)


def jobs_of(text):
    """{job name: job text} for a workflow's top-level jobs."""
    m = re.search(r"^jobs:\n", text, re.M)
    if not m:
        return {}
    body = text[m.end():]
    parts = re.split(r"^  ([A-Za-z0-9_-]+):\s*$", body, flags=re.M)
    return {parts[i]: parts[i + 1] for i in range(1, len(parts) - 1, 2)}


for f in files:
    rel = f.relative_to(root)
    text = f.read_text()
    lines = text.splitlines()
    for n, line in enumerate(lines, 1):
        m = re.match(r"^\s*(?:-\s+)?uses:\s*(\S+(?:\s+#.*)?)\s*$", line)
        if not m:
            continue
        ref = m.group(1)
        if ref.startswith("./"):
            continue
        if not PINNED.match(ref):
            errors.append(f"{rel}:{n}: action not pinned by commit SHA: {ref}")
        if ref.startswith("actions/checkout@"):
            block = []
            for nxt in lines[n:]:
                if re.match(r"^\s*-\s", nxt) or (nxt.strip() and len(nxt) - len(nxt.lstrip()) <= len(line) - len(line.lstrip()) and not nxt.lstrip().startswith("with:")):
                    break
                block.append(nxt)
            if not any(re.match(r"^\s+persist-credentials:\s*false\s*$", b) for b in block):
                errors.append(f"{rel}:{n}: checkout without persist-credentials: false")

    if f.parent.name != "workflows":
        continue
    top = text.split("\njobs:", 1)[0]
    top_perms = re.search(r"^permissions:\n((?:  .*\n)+)", top + "\n", re.M)
    if top_perms and WRITE.search(top_perms.group(1)):
        errors.append(f"{rel}: workflow-level permissions grant write; grant it per job")
    for job, body in jobs_of(text).items():
        if not BUILD_TOOL.search(body):
            continue
        if WRITE.search(body):
            errors.append(f"{rel}: job {job} runs a build tool and holds a write permission")
        if "secrets." in body:
            errors.append(f"{rel}: job {job} runs a build tool and reads a secret")
        if "github.token" in body or "GITHUB_TOKEN" in body:
            errors.append(f"{rel}: job {job} runs a build tool and puts the token in its environment")

# Every signing step must check its output before publishing, and missing secrets must fail
# when enforcement is on (including feed_only runs, which bypass the image publish job).
for workflow, step in [("release.yml", "Sign the plugin zip"), ("xteink.yml", "Sign the images"),
                       ("xteink.yml", "Sign the feed")]:
    workflow_text = (root / ".github/workflows" / workflow).read_text()
    block = workflow_text.split(f"      - name: {step}\n", 1)[1].split("\n      - ", 1)[0]
    if "feed-keys verify --tag" not in block or "jq -e '.enforce'" not in block:
        errors.append(f"{workflow}: {step} must verify signatures and require a key when enforced")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"workflows: {len(files)} files pass the supply-chain rules")
