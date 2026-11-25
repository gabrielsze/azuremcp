#!/usr/bin/env python3
"""Self-run agent: this Python process runs the agent loop and calls the remote Azure MCP Server itself.

Compare with foundry_agent.py, where Foundry calls the MCP server for you:

  foundry_agent.py   you ──prompt──▶ Foundry agent ──MCP (project managed identity)──▶ MCP server
  local_agent.py     you ──prompt──▶ this script ──model──▶ gpt-6.1-sol
                                          └─────────MCP (your Entra token)────────▶ MCP server

Loop for each prompt:
  1. send the prompt and the MCP tool list to the model
  2. the model asks for tool calls; reads run directly, changes ask you to approve
  3. call the MCP server, send each result back to the model
  4. repeat until the model answers in text

Commands:  chat (type your own prompts) | demo (step through A-D; Enter sends, or type your own)
Options:  --auto-approve, --verbose (print each MCP request and response)
Run:  agents/.venv/bin/python agents/local_agent.py demo --verbose
"""
import argparse
import asyncio
import base64
import json
import subprocess

from azure.ai.projects import AIProjectClient
from azure.identity import AzureCliCredential
from mcp import ClientSession
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

from foundry_agent import DEMO_PROMPTS, INSTRUCTIONS, READ_TOOLS, WRITE_TOOLS, settings, tf_output


def get_mcp_token(verbose):
    """Token 1: you -> MCP server. Delegated scope, pre-authorized for the Azure CLI (infra/mcp)."""
    scope = tf_output("mcp", "entra_app_identifier_uri") + "/Mcp.Tools.ReadWrite"
    token = subprocess.check_output(
        ["az", "account", "get-access-token", "--scope", scope, "--query", "accessToken", "-o", "tsv"], text=True).strip()
    if verbose:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        print(f"[token] aud={claims['aud']} scp={claims.get('scp')} user={claims.get('preferred_username')}")
    return token


def _short(text, limit):
    return text if len(text) <= limit else text[:limit] + "..."


def _azure_status(text):
    """Azure MCP puts the Azure status code inside the tool result."""
    try:
        return json.loads(text).get("status")
    except (json.JSONDecodeError, AttributeError):
        return None


async def call_mcp(session, name, args, verbose):
    if verbose:
        print(f"    [mcp ->] tools/call {name} {json.dumps(args)}")
    result = await session.call_tool(name, args)
    text = "\n".join(c.text for c in result.content if getattr(c, "text", None))
    status = _azure_status(text)
    if verbose:
        print(f"    [mcp <-] is_error={result.is_error} azure_status={status} {_short(text, 300)}")
    label = "ok" if not result.is_error and status in (None, 200, 201) else f"FAILED (Azure returned {status})"
    print(f"  [tool] {name}({_short(json.dumps(args), 160)}) -> {label}")
    return text


async def run_turn(model_client, session, cfg, tools, prompt, previous_id, auto_approve, verbose):
    request = {"model": cfg["model"], "instructions": INSTRUCTIONS.format(**cfg), "tools": tools}
    # Omit previous_response_id on the first turn: the service rejects an explicit null.
    response = model_client.responses.create(
        input=prompt, **request, **({"previous_response_id": previous_id} if previous_id else {}))
    while calls := [item for item in response.output if item.type == "function_call"]:
        outputs = []
        for call in calls:
            args = json.loads(call.arguments or "{}")
            if call.name in WRITE_TOOLS:
                print(f"  [approval needed] {call.name}({_short(call.arguments, 200)})")
                approved = auto_approve or input("    Approve? [y/N] ").strip().lower() == "y"
                if auto_approve:
                    print("    auto-approved")
                if not approved:
                    outputs.append({"type": "function_call_output", "call_id": call.call_id,
                                    "output": "The user rejected this tool call. Do not retry it."})
                    continue
            output = await call_mcp(session, call.name, args, verbose)
            outputs.append({"type": "function_call_output", "call_id": call.call_id, "output": output})
        response = model_client.responses.create(input=outputs, previous_response_id=response.id, **request)
    print(f"\nAgent: {response.output_text}\n")
    return response.id


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["chat", "demo"])
    parser.add_argument("--auto-approve", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    cfg = settings()
    token = get_mcp_token(args.verbose)

    with AzureCliCredential() as credential, \
            AIProjectClient(endpoint=cfg["endpoint"], credential=credential) as project, \
            project.get_openai_client() as model_client:
        async with create_mcp_http_client(headers={"Authorization": f"Bearer {token}"}) as http, \
                streamable_http_client(cfg["server_url"], http_client=http) as (read, write), \
                ClientSession(read, write) as session:
            info = await session.initialize()
            listed = (await session.list_tools()).tools
            # Offer the model only the demo tools, described by the MCP server's own schemas.
            tools = [{"type": "function", "name": t.name, "description": t.description or "",
                      "parameters": t.input_schema, "strict": False}
                     for t in listed if t.name in READ_TOOLS + WRITE_TOOLS]
            print(f"Connected to {info.server_info.name} {info.server_info.version} at {cfg['server_url']}")
            print(f"Server offers {len(listed)} tools; giving the model {len(tools)}. Model: {cfg['model']}\n")

            previous_id = None
            if args.command == "demo":
                for title, prompt in DEMO_PROMPTS:
                    print(f"=== {title}\nNext: {prompt}")
                    if not args.auto_approve:
                        prompt = input("Press Enter to send, or type your own prompt: ").strip() or prompt
                    print(f"You: {prompt}")
                    previous_id = await run_turn(model_client, session, cfg, tools, prompt, previous_id,
                                                 args.auto_approve, args.verbose)
                return
            print("Chat (empty line to quit)")
            while prompt := input("You: ").strip():
                previous_id = await run_turn(model_client, session, cfg, tools, prompt, previous_id,
                                             args.auto_approve, args.verbose)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except* (KeyboardInterrupt, EOFError):  # the MCP client's task groups wrap these in an ExceptionGroup
        print("\nStopped.")
