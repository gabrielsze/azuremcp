#!/usr/bin/env python3
"""Smoke test for the local Azure MCP server used in Track 1 (VS Code).

Starts the server with the same command and env as .vscode/mcp.json, then over stdio:
  1. lists the exposed tools
  2. calls a read-only command against rg-azuremcp to prove auth and subscription are right

Run before a demo: python3 scripts/03-test-local-mcp.py
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
server = json.loads(re.sub(r"^\s*//.*$", "", (ROOT / ".vscode/mcp.json").read_text(), flags=re.M))["servers"]["azure-mcp-demo"]

proc = subprocess.Popen(
    [server["command"], *server["args"]],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    env={**__import__("os").environ, **server.get("env", {})},
)
_next_id = 0


def rpc(method, params=None, notify=False):
    global _next_id
    msg = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if not notify:
        _next_id += 1
        msg["id"] = _next_id
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    if notify:
        return None
    while True:
        line = proc.stdout.readline()
        if not line:
            sys.exit("server exited unexpectedly")
        resp = json.loads(line)
        if resp.get("id") == _next_id:
            if "error" in resp:
                sys.exit(f"{method} failed: {resp['error']}")
            return resp["result"]


def call(tool, arguments):
    text = rpc("tools/call", {"name": tool, "arguments": arguments})["content"][0]["text"]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        sys.exit(f"{tool} returned: {text[:300]}")


try:
    info = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "smoke-test", "version": "1"}})
    rpc("notifications/initialized", notify=True)
    print(f"server: {info['serverInfo']['name']} {info['serverInfo']['version']}")

    tools = [t["name"] for t in rpc("tools/list")["tools"]]
    print(f"tools:  {', '.join(sorted(tools))}")

    res = call("group_resource_list", {"resource-group": "rg-azuremcp"})
    if res.get("status") != 200:
        sys.exit(f"group_resource_list failed: {str(res.get('message', res))[:300]}")
    names = [r["name"] for r in res["results"]["resources"]]
    print(f"rg-azuremcp resources ({len(names)}): {', '.join(sorted(names))}")
    print("OK")
finally:
    proc.kill()
