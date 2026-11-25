#!/usr/bin/env python3
"""Source identities, passing-test receipts and selective BookSync releases."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import re
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PLATFORMS = ("app", "plugin", "x4-pro", "x4-classic", "default")
FIRMWARE = {"x4-pro": "firmware-x4-pro", "x4-classic": "firmware-x4-classic", "default": "firmware-x3-x4"}
COMMON = ("shared/", "tools/releases/", "tools/booksync-version.py", "tools/e2e/",
          ".github/workflows/release-tests.yml", ".gitmodules", "tools/test/",
          ".github/actions/script-checks/")
INPUTS = {
    "app": ("android/companion/", ".github/actions/android-setup/", ".github/workflows/android.yml",
            ".github/workflows/release.yml"),
    "plugin": ("android/koreader/", ".github/actions/plugin-tests/", ".github/workflows/android.yml",
               ".github/workflows/release.yml", "tools/upstreams.lock"),
}
for platform in FIRMWARE:
    INPUTS[platform] = ("xteink/", "tools/upstreams.lock", ".github/actions/pio-setup/",
                        ".github/workflows/xteink.yml", "tools/xteink-feed.py")

def fingerprints(root=ROOT):
    entries = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=root).split(b"\0")
    hashes = {p: hashlib.sha256(("booksync-inputs-v1\0" + p).encode()) for p in PLATFORMS}
    for entry in sorted(e for e in entries if e):
        info, raw_path = entry.split(b"\t", 1)
        mode, oid, stage = info.split()
        if stage != b"0":
            raise ValueError("Cannot fingerprint unresolved inputs")
        path = raw_path.decode()
        if path == "shared/version.json":
            continue
        consumers = [p for p in PLATFORMS if any(
            path.startswith(prefix) if prefix.endswith("/") else path == prefix
            for prefix in COMMON + INPUTS[p])]
        if not consumers:
            continue
        file = root / path
        content = oid if mode == b"160000" else (
            os.readlink(file).encode() if mode == b"120000" else file.read_bytes())
        for platform in consumers:
            relevant = content
            if path == "tools/upstreams.lock":
                pin = b"koreader" if platform == "plugin" else b"crossink-v2.0"
                relevant = b"\n".join(line for line in content.splitlines()
                                       if line.split() and line.split()[0] == pin)
                if not relevant:
                    raise ValueError("Missing upstream pin for " + platform)
            blob = hashlib.sha256(relevant).digest()
            hashes[platform].update(mode + b"\0" + raw_path + b"\0" + blob)
    return {p: h.hexdigest() for p, h in hashes.items()}

def make_plan(version, current, history, force=False):
    """Only actual published builds affect preview selection; evidence never selects builds."""
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-(?:preview|rc)\.[1-9]\d*|-0\.test\.[1-9]\d*)?", version):
        raise ValueError("Unsupported BookSync version")
    rows = {}
    preview = "-preview." in version
    for p, fp in current.items():
        previous = history.get("builds", {}).get(p)
        build = force or not preview or not previous or previous["fingerprint"] != fp
        reuse = {}
        for scope in ("component", "release"):
            found = next((r for r in history.get("evidence", [])
                          if r.get("platform") == p and r.get("fingerprint") == fp
                          and r.get("scope") == scope and r.get("result") == "passed"), None)
            reuse[scope] = found["tag"] if found and not force else None
        rows[p] = dict(fingerprint=fp, build=build, previous=previous, reuse=reuse)
    # Android is one installed platform: workers and plugin require the same version.
    # Keep separate identities/evidence, but close publication over their dependency.
    android_build = rows["app"]["build"] or rows["plugin"]["build"]
    rows["app"]["build"] = rows["plugin"]["build"] = android_build
    return dict(schema=1, version=version, platforms=rows)

def receipt(platforms, scope, tag, root=ROOT):
    fps = fingerprints(root)
    return [dict(platform=p, fingerprint=fps[p], scope=scope, result="passed", tag=tag,
                 sha=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
                 run=os.environ.get("GITHUB_RUN_ID", "local")) for p in platforms]

def published(plan, platforms, tag):
    builds, evidence = {}, []
    for p in platforms:
        row = plan["platforms"][p]
        if row["build"]:
            builds[p] = dict(fingerprint=row["fingerprint"], version=plan["version"], tag=tag)
            for scope, source in row["reuse"].items():
                evidence.append(dict(platform=p, fingerprint=row["fingerprint"], scope=scope,
                                     result="passed", tag=source or tag,
                                     recorded_sha=os.environ.get("GITHUB_SHA", "local"),
                                     run=os.environ.get("GITHUB_RUN_ID", "local")))
        elif row["previous"]:
            builds[p] = row["previous"]
    return dict(schema=1, builds=builds, evidence=evidence)

def notes(plan, publishing=PLATFORMS):
    lines = ["<!-- booksync-builds -->", "", "| Platform | Current build | Tests |", "|---|---|---|"]
    for p, row in plan["platforms"].items():
        previous = row["previous"]
        built = row["build"] and p in publishing
        current = plan["version"] if built else (previous["version"] if previous else "none")
        unchanged = " (pending)" if row["build"] and not built else (
            " (unchanged)" if not built and current != plan["version"] else "")
        details = [f"tests: reused from {tag} ({scope})" if tag else f"{scope}: full tests"
                   for scope, tag in row["reuse"].items()]
        tests = "; ".join(details) if built else "previous build"
        lines.append(f"| {p} | BookSync {current}{unchanged} | {tests} |")
    return "\n".join(lines + ["<!-- /booksync-builds -->"]) + "\n"

def refresh_notes(body, plan):
    return re.sub(r"<!-- booksync-builds -->.*?<!-- /booksync-builds -->\n?",
                  lambda _: notes(plan), body, flags=re.S)

def require_android(plan):
    """Firmware must follow the Android publication, including on manual dispatch."""
    for platform in ("app", "plugin"):
        row = plan["platforms"][platform]
        previous = row["previous"]
        if not previous or previous["fingerprint"] != row["fingerprint"]:
            raise ValueError("Publish the matching Android pair through release.yml first")
        if "-preview." not in plan["version"] and previous["version"] != plan["version"]:
            raise ValueError("RC/stable requires the matching Android version first")


def gh(*args, binary=False):
    return subprocess.check_output(["gh", *args], text=not binary)

def collect(repo):
    """Immutable published receipts plus successful trusted Actions evidence; misses run tests."""
    history = dict(builds={}, evidence=[])
    releases = json.loads(gh("api", f"repos/{repo}/releases?per_page=100"))
    for release in sorted(releases, key=lambda r: r["created_at"], reverse=True):
        if release["draft"]:
            continue
        for asset in release["assets"]:
            if asset["name"] not in ("RELEASE-INPUTS.json", "FIRMWARE-INPUTS.json"):
                continue
            data = json.loads(gh("api", f"repos/{repo}/releases/assets/{asset['id']}",
                                 "-H", "Accept: application/octet-stream"))
            for p, build in data["builds"].items():
                history["builds"].setdefault(p, build)
            history["evidence"].extend(data["evidence"])
    artifacts = json.loads(gh("api", f"repos/{repo}/actions/artifacts?per_page=100"))["artifacts"]
    runs = {}
    for artifact in artifacts:
        if artifact["expired"] or not artifact["name"].startswith("passed-inputs-"):
            continue
        run_id = artifact["workflow_run"]["id"]
        if run_id not in runs:
            runs[run_id] = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}"))
        run = runs[run_id]
        # PR/fork artifacts are recorded but cannot authorize a release's test bypass.
        trusted_paths = {f".github/workflows/{name}.yml" for name in
                         ("android", "xteink", "release", "release-tests")}
        if run.get("path", "").split("@")[0] not in trusted_paths:
            continue
        if run["conclusion"] != "success" or run["event"] in ("pull_request", "pull_request_target"):
            continue
        if run["head_repository"]["full_name"] != repo:
            continue
        data = gh("api", f"repos/{repo}/actions/artifacts/{artifact['id']}/zip", binary=True)
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for name in archive.namelist():
                if name.endswith(".json"):
                    history["evidence"].extend(json.loads(archive.read(name)))
    return history

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fingerprints", "collect", "plan", "receipt", "published", "notes", "matrix", "outputs", "require-android", "refresh-notes"))
    parser.add_argument("--version")
    parser.add_argument("--notes")
    parser.add_argument("--history")
    parser.add_argument("--plan")
    parser.add_argument("--platforms", default=",".join(PLATFORMS))
    parser.add_argument("--scope", default="component", choices=("component", "release"))
    parser.add_argument("--tag", default=(os.environ.get("GITHUB_REF_NAME") if os.environ.get("GITHUB_REF_TYPE") == "tag"
                                         else os.environ.get("GITHUB_SHA", "local")))
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    platforms = args.platforms.split(",") if args.platforms else []
    plan = json.loads(Path(args.plan).read_text()) if args.plan else None
    if args.command == "fingerprints":
        out = fingerprints()
    elif args.command == "collect":
        out = collect(args.repo)
    elif args.command == "plan":
        history = json.loads(Path(args.history).read_text()) if args.history else {}
        out = make_plan(args.version, fingerprints(), history, args.force)
    elif args.command == "receipt":
        out = receipt(platforms, args.scope, args.tag)
    elif args.command == "published":
        out = published(plan, platforms, args.tag)
    elif args.command == "notes":
        print(notes(plan, platforms)); return
    elif args.command == "require-android":
        require_android(plan); return
    elif args.command == "refresh-notes":
        print(refresh_notes(Path(args.notes).read_text(), plan)); return
    elif args.command == "matrix":
        out = [dict(environment=p, firmware=FIRMWARE[p],
                    component_tests=not bool(plan["platforms"][p]["reuse"]["component"]))
               for p in FIRMWARE if plan["platforms"][p]["build"]]
    elif args.command == "outputs":
        rows = plan["platforms"]
        values = {
            "android_build": rows["app"]["build"],
            "app_tests": not bool(rows["app"]["reuse"]["component"]),
            "plugin_tests": not bool(rows["plugin"]["reuse"]["component"]),
            "android_release_tests": any(rows[p]["build"] and not rows[p]["reuse"]["release"] for p in ("app", "plugin")),
            "firmware_release_tests": any(rows[p]["build"] and not rows[p]["reuse"]["release"] for p in FIRMWARE),
            "firmware_build": any(rows[p]["build"] for p in FIRMWARE),
        }
        for key, value in values.items():
            print(f"{key}={str(value).lower()}")
        print("profiles=" + json.dumps([{"x4-pro": "x4-pro", "x4-classic": "x4-classic", "default": "x3"}[p]
              for p in FIRMWARE if rows[p]["build"] and not rows[p]["reuse"]["release"]], separators=(",", ":")))
        return
    print(json.dumps(out, indent=2))

if __name__ == "__main__":
    main()
