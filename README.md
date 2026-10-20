# wifi-cli

A small native macOS Wi-Fi CLI built with Swift, CoreWLAN, CoreLocation, and
SystemConfiguration. The Swift CLI has no package dependencies, shell command
construction, background daemon, telemetry, or automatic connection retries.

Requires macOS 13+ and Swift 5.9+ to build. Only macOS 27 / Apple Silicon has
been exercised so far. A compiled build uses the frameworks included with macOS;
end users do not need Xcode.

```sh
./scripts/build.sh
./dist/bin/wifi status
./dist/bin/wifi scan --json
./dist/bin/wifi permissions
./dist/bin/wifi permissions --request
```

Keep `dist/bin/wifi` and `dist/WiFiHelper.app` together. The CLI is a symlink to
the executable inside the signed app bundle; moving the executable out breaks
signature validation. You can symlink `dist/bin/wifi` into a directory on PATH.
No system installation is performed by the build script.

## Architecture

One command is one bounded request to macOS. The CLI handles input and output;
the signed helper provides the app identity macOS needs for Wi-Fi access and
Location Services. Public Apple frameworks perform the actual network work.

![Sketch of the Wi-Fi CLI architecture: terminal and scripts call the Swift CLI, which exchanges an authenticated request and response with a signed helper that uses CoreWLAN, CoreLocation, and SystemConfiguration.](docs/architecture.svg)

Open the [editable source](docs/architecture.excalidraw) in
[Excalidraw](https://excalidraw.com) and export SVG to update this image.

| Layer | Responsibility | Code |
| --- | --- | --- |
| CLI | Parse and validate commands, read passwords securely, enforce deadlines, emit text or JSON. Dry runs stop here. | [CommandLine.swift](Sources/WiFiKit/CommandLine.swift), [main.swift](Sources/wifi/main.swift) |
| Local transport | Carry one request and response over a private Unix socket; authenticate the user's UID and signed peer identity. | [Transport.swift](Sources/WiFiKit/Transport.swift) |
| Signed helper | Run in the logged-in user's app session, use CoreLocation for identity authorization and its prompt, dispatch the operation, then exit. | [main.swift](Sources/wifi/main.swift) |
| Native backend | Use CoreWLAN for Wi-Fi and SystemConfiguration for IP/router/DNS state. | [NativeBackend.swift](Sources/WiFiKit/NativeBackend.swift) |

The CLI and helper are two modes of the same bundled executable. Each real
command launches a fresh helper; there is no resident daemon or root service.
CoreLocation authorization is handled by the helper rather than the backend.
Both sides share typed [requests and responses](Sources/WiFiKit/Models.swift).

## Connection commands

```sh
./dist/bin/wifi join 'My Wi-Fi'            # hidden password prompt
./dist/bin/wifi join 'Guest Wi-Fi' --open
./dist/bin/wifi join 'My Wi-Fi' --password-stdin < /path/to/protected/input
./dist/bin/wifi join 'My Wi-Fi' --dry-run
./dist/bin/wifi disconnect --dry-run
./dist/bin/wifi power off --dry-run
./dist/bin/wifi power on
```

`join`, `disconnect`, and `power` change the real connection unless `--dry-run`
is present. The CLI never asks for a password during a dry run. Secured joins
support WPA2/WPA3 Personal; enterprise setup belongs in a configuration profile.
A directed scan selects the strongest matching SSID before association. Hidden
network discovery and credentials remain subject to macOS policy. An open join
requires `--open`; there is no silent downgrade to an open network.

All commands accept `--interface en0`, `--json`, and `--timeout 1..120` (default
45 seconds). Status does not scan. Scan performs one scan and exits. There is no
persistent helper. Permission is requested only by `permissions --request`.
That command brings WiFi CLI to the foreground for the macOS permission prompt;
other commands run their helper in the background. Allow WiFi CLI when prompted.
The operation deadline starts after password input. Ctrl-C/SIGTERM clean up the
socket and stop the helper; they cannot undo an operation already sent to macOS.

Association, an assigned IP address, and internet access are different states.
Status reports association evidence independently of SSID visibility and does
not claim that the internet is reachable. Join confirms the CoreWLAN association
call, not DHCP or internet connectivity. macOS can automatically reconnect after
disassociation. A timeout does not roll back an OS operation; check status before
retrying a change.

## Helper and credentials

Each real operation launches the bundled app in the logged-in user's session.
The peers use a private Unix socket (directory mode 0700, socket mode 0600), verify
the peer's UID and code-signing requirement, and apply message-size and time
limits. The helper also verifies the CLI PID and exits when the CLI exits or its
deadline expires. There is no TCP listener, password file, or privileged helper.

Passwords are read through `readpassphrase` or bounded stdin and sent over the
socket. They are never accepted as positional arguments, echoed, included in
responses, or saved by this program. Temporary input/transport buffers are cleared
where practical; Swift strings may have copies in memory and are not guaranteed
to be erased. macOS may save credentials as part of normal association. This
version does not retrieve saved Keychain passwords or promise silent reuse.

Local builds default to **ad-hoc signing**. That is sufficient for testing signed
peer identity, but Location Services grants can be lost across rebuilds. To use
your own stable certificate:

```sh
SIGN_IDENTITY='Your Code Signing Identity' ./scripts/build.sh
```

Public distribution still needs a suitable Developer ID signature and notarization.
These are not performed by the local build. Permission denial produces useful
status/warnings; it does not mean the Wi-Fi interface is disconnected.
The signed helper includes the Location entitlement required by hardened runtime.

## AI agents: skill and MCP

The optional integrations reuse the CLI and its JSON responses. They add no
dependencies to the Swift build. They run on the Mac being managed, in its
logged-in graphical user session; a cloud agent cannot reach this local adapter
without a separate connection you provide.

### Install the skill

The portable [macos-wifi skill](skills/macos-wifi/SKILL.md) teaches agents when to
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

## Validation

```sh
swift test
python3 scripts/smoke.py
uv run --project integrations/mcp --locked python -m unittest discover -s integrations/mcp -v
```

Unit tests use a recording backend for connection changes and cover dry-run
isolation, failure behavior, input validation, secret-free responses, terminal
escape handling, IPC framing, permissions, and deadlines. The smoke script runs
only status, scan, permission inspection, invalid arguments, and dry runs. It
checks that the active interface and IP state survive, prints timing summaries,
verifies cancellation cleanup, and does not save network names or addresses.
It also checks the entitlement embedded in the signed helper.
Real joining/disconnection/power changes have not been exercised on the
development machine.

The MCP suite has 11 tests using fake executables, including modern and legacy
stdio clients, read-only tool discovery, dry-run defaults, literal SSIDs, strict
boolean inputs, structured errors, serialization, timeout, and cancellation.
Live MCP status/scan/permission inspection and all three default dry runs also
passed against the signed CLI, with the connection and IP state unchanged.

Validated locally: 19 unit tests passed, signed-helper status/scan/permission
inspection passed, and cancellation left no helper or socket behind. Status
took roughly 0.13–0.25 seconds after the first launch; full scans took 7.5–8
seconds. These are local observations, not performance guarantees. The Location
permission prompt was tested interactively: authorization persisted across helper
launches, and a subsequent scan returned names for all 14 access points found.
Real connection changes still need an interactive test.

JSON output is one object on stdout, including failures. Exit codes: 0 success,
1 backend/transport/installation error, 2 invalid arguments, 3 permission error,
4 timeout, 5 authentication error. Scan results preserve individual access points;
a missing name can mean a hidden network or unavailable identity data.
