#!/usr/bin/env python3
"""Smoke test for the remote Azure MCP Server (infra/mcp).

Signs in as you via the Azure CLI (pre-authorized for the server's delegated scope), then checks:
  1. a request without a token is rejected (401)
  2. the server lists its tools
  3. reads work: group_resource_list, appconfig_kv_get, appservice_webapp_settings_get-appsettings
  4. an allowed write works: appconfig_kv_set (rewrites Banner:Message with its current value)
  5. RBAC blocks what the server's managed identity isn't allowed to do: storage_account_create -> 403

The remote server runs with --dangerously-disable-elicitation (stateless HTTP can't ask the client to
confirm destructive tools), so approval for writes happens in the client, e.g. Foundry tool approvals.

Outgoing Azure calls always use the container app's managed identity, not your account,
so this tests the same permissions the Foundry agent will have.

Run: python3 scripts/04-test-remote-mcp.py
"""
import json
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent


def tf_output(stack, name):
    return subprocess.check_output(
        ["terraform", f"-chdir={ROOT / 'infra' / stack}", "output", "-raw", name], text=True)


URL = tf_output("mcp", "mcp_server_url").rstrip("/") + "/"
SCOPE = tf_output("mcp", "entra_app_identifier_uri") + "/Mcp.Tools.ReadWrite"
RG = tf_output("data", "resource_group_name")
APPCONFIG = tf_output("data", "app_configuration_name")


def post(body, token=None, session=None):
    """POST one JSON-RPC message; the reply may be plain JSON or a server-sent event stream."""
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read().decode()
        sid = resp.headers.get("Mcp-Session-Id") or session
    if not raw.strip():
        return None, sid
    if raw.lstrip().startswith("{"):
        return json.loads(raw), sid
    msgs = [json.loads(line[5:]) for line in raw.splitlines() if line.startswith("data:")]
    return next((m for m in msgs if "id" in m), None), sid


def check(label, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {label}{'  ' + detail if detail else ''}")
    if not ok:
        sys.exit(1)


print(f"server: {URL}")

init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "smoke-test", "version": "1"}}}

try:
    post(init)
    check("unauthenticated request rejected", False, "server accepted a request without a token")
except urllib.error.HTTPError as e:
    check("unauthenticated request rejected", e.code == 401, f"HTTP {e.code}")

token = subprocess.check_output(
    ["az", "account", "get-access-token", "--scope", SCOPE, "--query", "accessToken", "-o", "tsv"], text=True).strip()

res, session = post(init, token)
check("initialize", res and "result" in res, res["result"]["serverInfo"]["version"] if res else "")
post({"jsonrpc": "2.0", "method": "notifications/initialized"}, token, session)

next_id = 1


def call(tool, args):
    global next_id
    next_id += 1
    res, _ = post({"jsonrpc": "2.0", "id": next_id, "method": "tools/call",
                   "params": {"name": tool, "arguments": args}}, token, session)
    text = res["result"]["content"][0]["text"]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"status": None, "message": text}


next_id += 1
tools, _ = post({"jsonrpc": "2.0", "id": next_id, "method": "tools/list"}, token, session)
names = {t["name"] for t in tools["result"]["tools"]}
check("tools/list", "appconfig_kv_set" in names, f"{len(names)} tools")

r = call("group_resource_list", {"resource-group": RG})
check("read: group_resource_list", r.get("status") == 200,
      f"{len(r.get('results', {}).get('resources', []))} resources" if r.get("status") == 200 else str(r.get("message"))[:200])

r = call("appconfig_kv_get", {"account": APPCONFIG})
check("read: appconfig_kv_get", r.get("status") == 200,
      f"{len(r.get('results', {}).get('settings', []))} keys" if r.get("status") == 200 else str(r.get("message"))[:200])

WEBAPP = tf_output("data", "web_app_name")
r = call("appservice_webapp_settings_get-appsettings", {"app": WEBAPP, "resource-group": RG})
check("read: appservice_webapp_settings_get-appsettings", r.get("status") == 200,
      f"LOG_LEVEL={r.get('results', {}).get('AppSettings', {}).get('LOG_LEVEL')}" if r.get("status") == 200 else str(r.get("message"))[:200])

current = next(kv["value"] for kv in call("appconfig_kv_get", {"account": APPCONFIG})["results"]["settings"]
               if kv["key"] == "Banner:Message")
r = call("appconfig_kv_set", {"account": APPCONFIG, "key": "Banner:Message", "value": current})
check("write: appconfig_kv_set allowed", r.get("status") == 200, str(r.get("message"))[:200])

r = call("storage_account_create", {"account": "stmcpshouldfail001", "resource-group": RG, "location": "eastus2"})
check("RBAC: storage_account_create denied", r.get("status") == 403 or "AuthorizationFailed" in str(r.get("message")),
      f"status {r.get('status')}: {str(r.get('message'))[:300]}")
print("OK")
