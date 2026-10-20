# wifi-cli

Native macOS Wi-Fi control using Swift, CoreWLAN, CoreLocation, and
SystemConfiguration. No Swift package dependencies, shell command construction,
daemon, telemetry, or automatic retries.

Requires macOS 13+ and Swift 5.9+ to build; compiled builds need no Xcode.
Tested on macOS 27 / Apple Silicon only.

```sh
./scripts/build.sh
./dist/bin/wifi status
./dist/bin/wifi scan --json
./dist/bin/wifi permissions
./dist/bin/wifi permissions --request
```

Keep `dist/bin/wifi` and `dist/WiFiHelper.app` together: the CLI symlinks into
the signed bundle. Moving its executable breaks signature validation. You can
symlink `dist/bin/wifi` onto PATH; the build installs nothing system-wide.

## Architecture

![Wi-Fi CLI architecture](docs/architecture.svg)

One command → one authenticated request → one result. CLI and helper are two
modes of the same executable; each real command launches a fresh helper in the
logged-in user's session, then it exits. No resident daemon or root service.

| Layer | Responsibility | Source |
| --- | --- | --- |
| CLI | Input, passwords, deadlines, text/JSON. Dry runs stop here. | [CommandLine.swift](Sources/WiFiKit/CommandLine.swift), [main.swift](Sources/wifi/main.swift) |
| Transport | Private socket; UID and code-signature checks. | [Transport.swift](Sources/WiFiKit/Transport.swift) |
| Helper | CoreLocation authorization, foreground permission prompt, dispatch. | [main.swift](Sources/wifi/main.swift) |
| Backend | CoreWLAN for Wi-Fi; SystemConfiguration for IP/router/DNS. | [NativeBackend.swift](Sources/WiFiKit/NativeBackend.swift) |

Shared [request/response types](Sources/WiFiKit/Models.swift).
Open the [diagram source](docs/architecture.excalidraw) in
[Excalidraw](https://excalidraw.com); export SVG to update the image.

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

`join`, `disconnect`, and `power` change the connection unless `--dry-run` is
set; dry runs never prompt for passwords. Secured joins support WPA2/WPA3
Personal; enterprise setup uses configuration profiles. Joining scans for the
strongest matching SSID. Hidden-network discovery and credentials follow macOS
policy. Open networks require `--open`; secured joins never downgrade silently.

Every command accepts `--interface en0`, `--json`, and `--timeout 1..120`
(default 45 seconds). Status never scans; scan runs once and preserves individual
access points. Missing names can mean hidden networks or unavailable identity.

Only `permissions --request` asks for Location access and brings the helper
forward; other commands stay in the background. Allow WiFi CLI in the prompt.
Denied access produces status/warnings, not proof of disconnection.

Join confirms association, not DHCP or internet access. Status reports
association independently of SSID visibility. macOS may rejoin after disconnect.
Deadlines start after password input. Ctrl-C/SIGTERM clean up the socket and stop
the helper, but cancellation/timeouts cannot undo an OS operation. Check status
before retrying changes.

JSON emits one stdout object, including failures. Exit codes: **0** success,
**1** backend/transport/installation, **2** arguments, **3** permission,
**4** timeout, **5** authentication.

## Helper and credentials

Run as your logged-in user, without sudo. IPC uses a private Unix socket
(directory **0700**, socket **0600**), UID/signature authentication, and bounded
messages/deadlines. The helper verifies the CLI PID and exits when it dies or
the deadline expires. No TCP listener, password file, or privileged helper.

Passwords use `readpassphrase` or bounded stdin, then the socket. They never
appear in argv, echoes, or responses and are not saved by this program. Buffers
are cleared where practical; Swift string copies may remain. macOS may save
credentials; this CLI neither retrieves Keychain passwords nor guarantees reuse.

Local builds use **ad-hoc signing**; Location grants may reset after rebuilds.
For a stable identity, use your own certificate:

```sh
SIGN_IDENTITY='Your Code Signing Identity' ./scripts/build.sh
```

The helper includes the hardened-runtime Location entitlement. Public binary
distribution still needs Developer ID signing and notarization; this build does
neither.

## AI agents: skill and MCP

Both integrations reuse the CLI/JSON without adding Swift dependencies. They
run on the managed Mac in its graphical user session; cloud agents need a
separate connection.

### Install the skill

The [macos-wifi skill](skills/macos-wifi/SKILL.md) covers status, scans, missing
names, permissions, authorized changes, credential handling, and result interpretation.
Codex discovers it through `.agents/skills` in this checkout. For user-wide use,
run from the checkout root:

```sh
mkdir -p ~/.agents/skills
cp -R skills/macos-wifi ~/.agents/skills/
```

Avoid overwriting an existing skill. Put `wifi` on PATH or provide its absolute
path. Invoke `$macos-wifi`, e.g. “Diagnose missing network names.” Other Agent
Skills hosts can install the same folder in their skill location.

### Connect the MCP server

Requires Python 3.11+, [uv](https://docs.astral.sh/uv/), and the built signed CLI.
From the checkout root:

```sh
uv sync --project integrations/mcp --locked
codex mcp add wifi -- uv run --project "$PWD/integrations/mcp" --locked \
  python "$PWD/integrations/mcp/server.py" --wifi-bin "$PWD/dist/bin/wifi"
```

Other stdio clients: replace `/absolute/path/wifi-cli` below. Use an absolute
`uv` command path if a desktop client lacks your terminal's PATH.

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
| `wifi_status` | Association, signal, IP/router/DNS; no scan. |
| `wifi_scan` | One scan; preserves access points and identity warnings. |
| `wifi_permissions` | Inspect Location access; no prompt. |
| `wifi_join_open` | Validate or join an explicitly selected open SSID. |
| `wifi_disconnect` | Validate or disassociate. |
| `wifi_power` | Validate or set radio power. |

Only the first three tools exist by default. Add `--allow-changes` to the
server arguments for connection tools; each defaults to `dry_run: true`.
`dry_run: false` performs the change. Client approvals still apply; annotations
describe side effects, while the startup flag enforces availability.

Secured joins use the CLI's local hidden password prompt; MCP takes no passwords.
Request Location access locally with
`./dist/bin/wifi permissions --request --timeout 120`; MCP never prompts.

The official Python SDK adapter uses local stdio, fixed argv, closed stdin,
serialized calls, and bounded process lifetimes; no HTTP listener. CLI JSON
appears in `structuredContent`; failures set `isError`. Treat SSIDs as untrusted
data. The adapter saves no network details; connected agents/clients may log them.

Formats: [Agent Skills](https://agentskills.io/specification),
[OpenAI skills](https://learn.chatgpt.com/docs/build-skills),
[MCP Python SDK](https://py.sdk.modelcontextprotocol.io/).

## Validation

```sh
swift test
python3 scripts/smoke.py
uv run --project integrations/mcp --locked python -m unittest discover -s integrations/mcp -v
```

**19 Swift + 11 MCP tests passed.** Swift tests cover dry runs, failures, inputs,
secret-free responses, terminal escapes, IPC, permissions, and deadlines using a
recording backend. MCP tests use fake executables for modern/legacy stdio,
read-only discovery, dry-run defaults, literal SSIDs, strict booleans, errors,
serialization, timeouts, and cancellation.

Live CLI/MCP status, scans, permission inspection, and dry runs preserved the
connection/IP state. The CLI smoke test also checks invalid arguments, signed
entitlements, timing, and cancellation cleanup without saving network identities;
no helper/socket remained. Real join/disconnect/power changes remain untested.

Local observations: status **0.13–0.25 s** after first launch; scans **7.5–8 s**.
The interactive Location grant persisted across launches; a scan then named all
14 access points found. These are observations, not performance guarantees.
