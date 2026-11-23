#!/usr/bin/env python3
"""Track 2: a Foundry agent that operates Azure through the remote Azure MCP Server.

Commands:
  create   create a new version of the agent and point the agent's endpoint at it
  chat     interactive chat; you approve or reject each change the agent wants to make
  demo     run the scripted demo prompts (use cases A-D) with the same approval prompts

Options:
  --auto-approve   approve every request without asking (for rehearsals and smoke tests)

Run with the project venv:  agents/.venv/bin/python agents/foundry_agent.py demo
Settings come from `terraform output` in infra/foundry, so no .env file is needed.
"""
import argparse
import json
import pathlib
import subprocess
import sys

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    AgentEndpointConfig,
    FixedRatioVersionSelectionRule,
    MCPTool,
    MCPToolFilter,
    MCPToolRequireApproval,
    PromptAgentDefinition,
    ProtocolConfiguration,
    ResponsesProtocolConfiguration,
    VersionSelector,
)
from azure.identity import AzureCliCredential

ROOT = pathlib.Path(__file__).resolve().parent.parent
AGENT_NAME = "azure-ops-agent"

# Tools the agent may call without asking.
READ_TOOLS = [
    "group_resource_list",
    "storage_account_get",
    "role_assignment_list",
    "appconfig_kv_get",
    "appservice_webapp_get",
    "appservice_webapp_settings_get-appsettings",
]
# Tools that change something: a person must approve every call.
# storage_account_create is included only to show RBAC blocking it (use case D).
WRITE_TOOLS = [
    "appconfig_kv_set",
    "appconfig_kv_lock_set",
    "appservice_webapp_settings_update-appsettings",
    "appservice_webapp_change-state",
    "storage_account_create",
]

INSTRUCTIONS = """You are an Azure operations assistant for the resource group {rg}.
Use the Azure MCP tools to answer questions and make changes. Never guess values you can look up.
Defaults: resource group {rg}, App Configuration store {appconfig}, web app {webapp}.
Before changing anything, say briefly what you will change.
If a tool call fails, report the error code and the reason in one or two sentences.
Never work around a lock or a permission error (for example, don't unlock a key) unless the user explicitly asks.
Keep answers short; use a small table when listing resources or settings."""

DEMO_PROMPTS = [
    ("A. Explore", "What's deployed in the resource group?"),
    ("B. Audit", "Does the storage account allow public blob access, and is HTTPS-only traffic enforced? "
                 "List the role assignments in the resource group."),
    ("C. Change", "In App Configuration, set Checkout:NewUI to true and Checkout:MaxRetries to 5, then lock both keys "
                  "because we're in a change freeze. Also set LOG_LEVEL to debug on the web app."),
    ("D1. Guardrail: lock", "Change Checkout:MaxRetries to 10."),
    ("D2. Guardrail: RBAC", "Create a new storage account called stmcpdemoextra001 in eastus2 in the resource group."),
]


def tf_output(stack, name):
    return subprocess.check_output(
        ["terraform", f"-chdir={ROOT / 'infra' / stack}", "output", "-raw", name], text=True).strip()


def settings():
    return {
        "endpoint": tf_output("foundry", "project_endpoint"),
        "model": tf_output("foundry", "model_deployment_name"),
        "connection": tf_output("foundry", "mcp_connection_name"),
        "server_url": tf_output("foundry", "mcp_server_url"),
        "rg": tf_output("data", "resource_group_name"),
        "appconfig": tf_output("data", "app_configuration_name"),
        "webapp": tf_output("data", "web_app_name"),
    }


def create_agent(project, cfg):
    tool = MCPTool(
        server_label="azure",
        server_url=cfg["server_url"],
        project_connection_id=cfg["connection"],
        allowed_tools=READ_TOOLS + WRITE_TOOLS,
        require_approval=MCPToolRequireApproval(
            always=MCPToolFilter(tool_names=WRITE_TOOLS),
            never=MCPToolFilter(tool_names=READ_TOOLS),
        ),
    )
    version = project.agents.create_version(
        agent_name=AGENT_NAME,
        definition=PromptAgentDefinition(
            model=cfg["model"],
            instructions=INSTRUCTIONS.format(**cfg),
            tools=[tool],
        ),
        description="Operates rg-azuremcp through the remote Azure MCP Server",
    )
    project.agents.update_details(
        agent_name=AGENT_NAME,
        agent_endpoint=AgentEndpointConfig(
            version_selector=VersionSelector(version_selection_rules=[
                FixedRatioVersionSelectionRule(agent_version=version.version, traffic_percentage=100)]),
            protocol_configuration=ProtocolConfiguration(responses=ResponsesProtocolConfiguration()),
        ),
    )
    print(f"Agent {AGENT_NAME} version {version.version} created, model {cfg['model']}")


def _short(value, limit=300):
    text = value if isinstance(value, str) else json.dumps(value)
    return text if len(text) <= limit else text[:limit] + "..."


def _status(item):
    """Azure MCP reports Azure errors inside the tool result, so read its status field too."""
    if getattr(item, "error", None):
        return f"ERROR {_short(item.error)}"
    try:
        status = json.loads(item.output or "{}").get("status")
    except (json.JSONDecodeError, AttributeError):
        return "ok"
    return "ok" if status in (None, 200, 201) else f"FAILED (Azure returned {status})"


def run_turn(client, prompt, previous_id, auto_approve):
    """Send one user prompt, handle approval requests until the agent answers. Returns the last response id."""
    # Omit previous_response_id on the first turn: the service rejects an explicit null.
    response = client.responses.create(input=prompt, **({"previous_response_id": previous_id} if previous_id else {}))
    while True:
        approvals = []
        for item in response.output:
            if item.type == "mcp_call":
                print(f"  [tool] {item.name}({_short(item.arguments, 160)}) -> {_status(item)}")
            elif item.type == "mcp_approval_request":
                print(f"  [approval needed] {item.name}({_short(item.arguments, 200)})")
                if auto_approve:
                    approve = True
                    print("    auto-approved")
                else:
                    approve = input("    Approve? [y/N] ").strip().lower() == "y"
                approvals.append({"type": "mcp_approval_response", "approval_request_id": item.id, "approve": approve})
        if not approvals:
            break
        response = client.responses.create(input=approvals, previous_response_id=response.id)
    print(f"\nAgent: {response.output_text}\n")
    return response.id


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["create", "chat", "demo"])
    parser.add_argument("--auto-approve", action="store_true")
    args = parser.parse_args()

    cfg = settings()
    with AzureCliCredential() as credential, AIProjectClient(endpoint=cfg["endpoint"], credential=credential) as project:
        if args.command == "create":
            create_agent(project, cfg)
            return

        with project.get_openai_client(agent_name=AGENT_NAME) as client:
            previous_id = None
            if args.command == "demo":
                for title, prompt in DEMO_PROMPTS:
                    print(f"=== {title}\nYou: {prompt}")
                    previous_id = run_turn(client, prompt, previous_id, args.auto_approve)
                return

            print(f"Chatting with {AGENT_NAME} (empty line to quit)")
            while prompt := input("You: ").strip():
                previous_id = run_turn(client, prompt, previous_id, args.auto_approve)


if __name__ == "__main__":
    sys.exit(main())
