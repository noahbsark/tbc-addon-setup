#!/usr/bin/env python3
"""Open a reviewable release PR from already tested, verified workflow artifacts."""
import base64
import json
import os
from pathlib import Path
import subprocess

from package_rating_addon import ROOT, verify


def api(path, payload=None):
    command = ["gh", "api", path]
    if payload is not None:
        command += ["--method", "POST", "--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else None


def release_paths(version):
    return [f"nightslayer-rating/downloads/NightslayerRating-{version}-{flavor}.zip"
            for flavor in ("AddonOnly", "Windows")] + [
                "nightslayer-rating/latest.json", "nightslayer-rating/checksums.txt", "nightslayer-rating/index.html"]


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Run the Prepare rating release workflow in GitHub Actions")
    repo = os.environ["GITHUB_REPOSITORY"]
    if repo != "noahbsark/tbc-addon-setup":
        raise RuntimeError("Unexpected release repository")
    version = verify()
    prefix = f"repos/{repo}"
    main_sha = api(f"{prefix}/git/ref/heads/main")["object"]["sha"]
    source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    # The release includes the selected source branch, with current main as an
    # ancestor. Never silently publish a bundle built against superseded source.
    subprocess.run(["git", "merge-base", "--is-ancestor", main_sha, source_sha], check=True)
    old_file = api(f"{prefix}/contents/nightslayer-rating/latest.json?ref={main_sha}")
    old = json.loads(base64.b64decode(old_file["content"]))
    if tuple(map(int, version.split("."))) <= tuple(map(int, old["version"].split("."))):
        raise RuntimeError("Bump the TOC, Options.lua and updater version above the released version before preparing a release")
    tree_sha = api(f"{prefix}/git/commits/{source_sha}")["tree"]["sha"]
    elements = []
    for path in release_paths(version):
        content = base64.b64encode((ROOT / path).read_bytes()).decode("ascii")
        blob = api(f"{prefix}/git/blobs", {"content": content, "encoding": "base64"})
        elements.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    tree = api(f"{prefix}/git/trees", {"base_tree": tree_sha, "tree": elements})
    commit = api(f"{prefix}/git/commits", {"message": f"Package Nightslayer Rating {version}",
                                         "tree": tree["sha"], "parents": [source_sha]})
    run_id = os.environ["GITHUB_RUN_ID"]
    attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    if not run_id.isdigit() or not attempt.isdigit():
        raise RuntimeError("Invalid workflow run identifier")
    branch = f"release/nsr-{version}-{run_id}-{attempt}"
    if api(f"{prefix}/git/ref/heads/main")["object"]["sha"] != main_sha:
        raise RuntimeError("Main changed during packaging; update the source branch and rerun")
    api(f"{prefix}/git/refs", {"ref": f"refs/heads/{branch}", "sha": commit["sha"]})
    run_url = f"https://github.com/{repo}/actions/runs/{run_id}"
    body = (f"Prepares Nightslayer Rating {version} from `{source_sha}`.\n\n"
            "Both ZIPs share one rating snapshot and pass source parity, TOC dependency, bootstrap and checksum validation. "
            "This PR updates the download page and the Windows upgrade manifest together. "
            "It includes the selected source branch's changes.\n\n"
            f"Lua and Windows tests passed in the [preparation run]({run_url}). "
            "A separate validation run is dispatched for this generated commit. "
            "Merge after review and in-game verification; merging publishes the downloads.\n")
    pr = api(f"{prefix}/pulls", {"title": f"Release Nightslayer Rating {version}", "head": branch,
                                "base": "main", "body": body})
    # GITHUB_TOKEN-created PRs do not automatically trigger another workflow.
    api(f"{prefix}/actions/workflows/test-rating-addon.yml/dispatches", {"ref": branch})
    print(pr["html_url"])
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a") as stream:
            stream.write(f"Prepared [release PR #{pr['number']}]({pr['html_url']}). Nothing was merged.\n")


if __name__ == "__main__":
    main()
