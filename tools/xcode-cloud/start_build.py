#!/usr/bin/env python3
"""Start an Xcode Cloud build through the App Store Connect API.

Standard library only. The ES256 signature for the API token is produced by
the system `openssl` binary, so no PyJWT / cryptography install is needed.

Flow (all documented App Store Connect API endpoints):
  GET  /v1/ciProducts?include=app                 -> the product for our bundle id
  GET  /v1/ciProducts/{id}/workflows              -> its workflows
  GET  /v1/ciWorkflows/{id}/repository            -> the SCM repository
  GET  /v1/scmRepositories/{id}/gitReferences     -> the branch's reference id
  POST /v1/ciBuildRuns                            -> start the run
  GET  /v1/ciBuildRuns/{id}                       -> (--watch) poll progress
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"


# --- token -----------------------------------------------------------------

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_to_raw(der: bytes, size: int = 32) -> bytes:
    """Convert an ASN.1 DER ECDSA signature (SEQUENCE of two INTEGERs) to the
    fixed-width r||s form JWS requires."""
    if der[0] != 0x30:
        raise ValueError("not a DER SEQUENCE")
    idx = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[idx] != 0x02:
            raise ValueError("expected DER INTEGER")
        length = der[idx + 1]
        value = der[idx + 2 : idx + 2 + length]
        idx += 2 + length
        parts.append(value.lstrip(b"\x00").rjust(size, b"\x00"))
    return b"".join(parts)


def mint_token(issuer_id: str, key_id: str, key_path: str, ttl_seconds: int = 900) -> str:
    """ES256 JWT per Apple's 'Generating Tokens for API Requests'. Max TTL is
    20 minutes; we use 15."""
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + ttl_seconds,
        "aud": "appstoreconnect-v1",
    }
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + _b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input.encode("ascii"),
        capture_output=True,
        check=True,
    ).stdout
    return signing_input + "." + _b64url(_der_to_raw(der))


# --- http ------------------------------------------------------------------

class Client:
    def __init__(self, token: str):
        self.token = token

    def request(self, method: str, path: str, body: dict | None = None, params: dict | None = None) -> dict:
        url = path if path.startswith("http") else API + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            sys.exit(f"error: {method} {path} -> HTTP {e.code}\n{detail}")
        return json.loads(raw) if raw else {}

    def get_all(self, path: str, params: dict | None = None) -> list[dict]:
        """Follow `links.next` so a long branch list is fully read."""
        out: list[dict] = []
        page = self.request("GET", path, params=params)
        while True:
            out.extend(page.get("data", []))
            nxt = page.get("links", {}).get("next")
            if not nxt:
                return out
            page = self.request("GET", nxt)


# --- resolution ------------------------------------------------------------

def find_product(client: Client, bundle_id: str) -> dict:
    page = client.request("GET", "/v1/ciProducts", params={"filter[productType]": "APP", "include": "app", "limit": 200})
    apps = {inc["id"]: inc for inc in page.get("included", []) if inc.get("type") == "apps"}
    products = page.get("data", [])
    for p in products:
        app_id = p.get("relationships", {}).get("app", {}).get("data", {}).get("id")
        if app_id and apps.get(app_id, {}).get("attributes", {}).get("bundleId") == bundle_id:
            return p
    if len(products) == 1:
        return products[0]
    names = ", ".join(p["attributes"].get("name", p["id"]) for p in products) or "(none)"
    sys.exit(f"error: no Xcode Cloud product for {bundle_id}; products visible to this key: {names}")


def pick_workflow(workflows: list[dict], wanted: str | None) -> dict:
    enabled = [w for w in workflows if w["attributes"].get("isEnabled", True)]
    if wanted:
        for w in workflows:
            if w["attributes"]["name"] == wanted:
                return w
        sys.exit(f"error: no workflow named {wanted!r}; have: " + ", ".join(w["attributes"]["name"] for w in workflows))
    if len(enabled) == 1:
        return enabled[0]
    if not enabled:
        sys.exit("error: the product has no enabled workflows")
    sys.exit("error: several enabled workflows, pass --workflow NAME: " + ", ".join(w["attributes"]["name"] for w in enabled))


def find_branch_ref(client: Client, repo_id: str, branch: str) -> dict:
    refs = client.get_all(f"/v1/scmRepositories/{repo_id}/gitReferences", params={"limit": 200})
    for r in refs:
        a = r["attributes"]
        if a.get("kind") == "BRANCH" and a.get("name") == branch:
            return r
    sys.exit(f"error: branch {branch!r} not found in the Xcode Cloud repository (has it been pushed?)")


# --- commands --------------------------------------------------------------

def cmd_list(client: Client, product: dict) -> None:
    pa = product["attributes"]
    print(f"product  {pa.get('name')}  ({product['id']})")
    workflows = client.get_all(f"/v1/ciProducts/{product['id']}/workflows")
    for w in workflows:
        a = w["attributes"]
        flag = "" if a.get("isEnabled", True) else "  [disabled]"
        print(f"workflow {a['name']}  ({w['id']}){flag}")
    runs = client.request(
        "GET", f"/v1/ciProducts/{product['id']}/buildRuns",
        params={"limit": 5, "sort": "-number", "fields[ciBuildRuns]": "number,createdDate,executionProgress,completionStatus,sourceCommit"},
    ).get("data", [])
    for r in runs:
        a = r["attributes"]
        sha = (a.get("sourceCommit") or {}).get("commitSha", "")[:7]
        print(f"run #{a.get('number')}  {a.get('createdDate','')[:16]}  {a.get('executionProgress','')}/{a.get('completionStatus') or '-'}  {sha}")


def cmd_start(client: Client, product: dict, branch: str, workflow_name: str | None, dry_run: bool, watch: bool) -> None:
    workflows = client.get_all(f"/v1/ciProducts/{product['id']}/workflows")
    workflow = pick_workflow(workflows, workflow_name)
    repo = client.request("GET", f"/v1/ciWorkflows/{workflow['id']}/repository")["data"]
    ref = find_branch_ref(client, repo["id"], branch)
    print(f"workflow {workflow['attributes']['name']}  branch {branch}  ref {ref['id']}")
    if dry_run:
        print("dry run: not starting")
        return
    body = {
        "data": {
            "type": "ciBuildRuns",
            "relationships": {
                "workflow": {"data": {"type": "ciWorkflows", "id": workflow["id"]}},
                "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": ref["id"]}},
            },
        }
    }
    run = client.request("POST", "/v1/ciBuildRuns", body=body)["data"]
    number = run["attributes"].get("number")
    print(f"started build run #{number}  ({run['id']})")
    print(f"https://appstoreconnect.apple.com/teams/xcode-cloud/  (Xcode → Report navigator → Cloud shows it too)")
    if watch:
        watch_run(client, run["id"])


def watch_run(client: Client, run_id: str) -> None:
    last = None
    while True:
        run = client.request("GET", f"/v1/ciBuildRuns/{run_id}")["data"]["attributes"]
        state = f"{run.get('executionProgress')}/{run.get('completionStatus') or '-'}"
        if state != last:
            print(f"{time.strftime('%H:%M:%S')}  {state}")
            last = state
        if run.get("executionProgress") == "COMPLETE":
            status = run.get("completionStatus")
            sys.exit(0 if status == "SUCCEEDED" else f"build finished with {status}")
        time.sleep(60)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--branch", default=os.environ.get("XCODE_CLOUD_DEFAULT_BRANCH", "main"))
    ap.add_argument("--workflow", help="workflow name (needed only if the product has several enabled)")
    ap.add_argument("--list", action="store_true", help="list product, workflows, and recent runs")
    ap.add_argument("--watch", action="store_true", help="poll the run until it completes")
    ap.add_argument("--dry-run", action="store_true", help="resolve ids, start nothing")
    args = ap.parse_args()

    token = mint_token(os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_ID"], os.environ["ASC_KEY_PATH"])
    client = Client(token)
    product = find_product(client, os.environ.get("TAILSPOT_BUNDLE_ID", "com.landesberg.Tailspot"))
    if args.list:
        cmd_list(client, product)
    else:
        cmd_start(client, product, args.branch, args.workflow, args.dry_run, args.watch)


if __name__ == "__main__":
    main()
