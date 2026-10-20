# wifi-cli

A small native macOS Wi-Fi CLI built with Swift, CoreWLAN, CoreLocation, and
SystemConfiguration. No package dependencies, shell command construction,
background daemon, telemetry, or automatic connection retries.

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

## Validation

```sh
swift test
python3 scripts/smoke.py
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
