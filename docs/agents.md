# AI agents: skill and MCP

The optional integrations reuse the CLI and its JSON responses. They add no
dependencies to the Swift build. They run on the Mac being managed, in its
logged-in graphical user session; a cloud agent cannot reach this local adapter
without a separate connection you provide.

### Install the skill

The portable [macos-wifi skill](../skills/macos-wifi/SKILL.md) teaches agents when to
inspect status, scan, diagnose missing names, handle Location Services, and make
an authorized change. It keeps passwords out of chat and distinguishes
association from IP configuration and internet access.

Codex discovers it automatically in this checkout through `.agents/skills`.
To use it across repositories, run the following from the checkout root:

```sh
mkdir -p ~/.agents/skills
cp -R skills/macos-wifi ~/.agents/skills/
```

Choose a different destination if a skill with that name is already installed.
Keep `wifi` on PATH or give the agent the absolute path to `dist/bin/wifi`.
Invoke it with `$macos-wifi`, for example: “Use $macos-wifi to diagnose why my
scan has no network names.” Other Agent Skills hosts can install the same
`skills/macos-wifi` folder using their own skill location.

### Connect the MCP server

Requires Python 3.11+ and [uv](https://docs.astral.sh/uv/). Build the signed CLI
first. From the checkout root, install the locked optional dependencies:

```sh
uv sync --project integrations/mcp --locked
```

For Codex CLI, register the local stdio server:

```sh
codex mcp add wifi -- uv run --project "$PWD/integrations/mcp" --locked \
  python "$PWD/integrations/mcp/server.py" --wifi-bin "$PWD/dist/bin/wifi"
```

For other stdio MCP clients, use this configuration and replace every
`/absolute/path/wifi-cli` with your checkout path. Use an absolute path to `uv`
as `command` if a desktop client does not inherit your terminal's PATH.

```json
{
  "mcpServers": {
    "wifi": {
      "command": "uv",
      "args": [
        "run", "--project", "/absolute/path/wifi-cli/integrations/mcp", "--locked",
        "python", "/absolute/path/wifi-cli/integrations/mcp/server.py",
        "--wifi-bin", "/absolute/path/wifi-cli/dist/bin/wifi"
      ]
    }
  }
}
```

| Tool | Behavior |
| --- | --- |
| `wifi_status` | Read association, signal, IP, router and DNS state without scanning. |
| `wifi_scan` | Perform one scan, preserving access points and identity warnings. |
| `wifi_permissions` | Inspect Location Services without showing a prompt. |
| `wifi_join_open` | With `--allow-changes`: validate or join an explicitly selected open SSID. |
| `wifi_disconnect` | With `--allow-changes`: validate or request disassociation. |
| `wifi_power` | With `--allow-changes`: validate or set radio power. |

By default, only the three inspection tools are registered. Append
`--allow-changes` to the server's arguments to expose connection tools. Each
connection tool defaults to `dry_run: true`; `dry_run: false` performs the real
operation. Client approval settings still apply. Tool annotations describe side
effects; the server's startup flag enforces which tools exist.

Secured joins use the CLI's local hidden password prompt; MCP has no password
parameter. Request Location Services interactively with
`./dist/bin/wifi permissions --request --timeout 120` before using scans that
need network identities. The server never requests permission itself.

The adapter uses the official MCP Python SDK, local stdio, fixed subprocess
arguments, disconnected stdin, serialized CLI calls, and bounded subprocess
lifetimes. There is no HTTP listener. Results include the CLI JSON as MCP
`structuredContent`; failures also set `isError`. Treat SSIDs as untrusted data.
Network details are visible to the connected agent/client, which may retain
conversation or tool logs. The adapter does not write those details to disk.

The formats follow the [Agent Skills specification](https://agentskills.io/specification),
[OpenAI skill guidance](https://learn.chatgpt.com/docs/build-skills), and
[official MCP Python SDK](https://py.sdk.modelcontextprotocol.io/).

