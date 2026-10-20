#!/usr/bin/env python3
"""Read-only integration checks. Never joins, disconnects, or changes power."""
import json
from pathlib import Path
import plistlib
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "dist/bin/wifi"


def run(*args, expected=0, timeout=55):
    started = time.monotonic()
    result = subprocess.run([str(CLI), *args, "--json"], capture_output=True,
                            text=True, timeout=timeout)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    response = json.loads(result.stdout)
    assert response["ok"] == (expected == 0), args
    assert not result.stderr, (args, result.stderr)
    elapsed = time.monotonic() - started
    print(f"{' '.join(args)}: {elapsed:.3f}s; exit={result.returncode}")
    return response, elapsed


def main():
    signed = subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml",
                                      str(ROOT / "dist/WiFiHelper.app")], stderr=subprocess.PIPE)
    assert plistlib.loads(signed).get("com.apple.security.personal-information.location") is True
    print("signed helper includes Location Services entitlement")
    before, _ = run("status")
    assert before["status"]["interface"]
    for _ in range(2):
        run("status")
    permission, _ = run("permissions")
    assert permission["permission"] in {"authorized", "denied", "restricted", "notDetermined", "unknown"}
    scan, elapsed = run("scan")
    assert isinstance(scan["networks"], list)
    named = sum(bool(network.get("ssid")) for network in scan["networks"])
    print(f"scan returned {len(scan['networks'])} access-point results; {named} have names")
    assert elapsed < 50
    for args in [("join", "nonexistent-test-network", "--dry-run"),
                 ("disconnect", "--dry-run"), ("power", "off", "--dry-run")]:
        response, _ = run(*args)
        assert "no backend operation" in response["message"]
    response, _ = run("join", "example", "not-a-real-password", expected=2)
    assert "not-a-real-password" not in json.dumps(response)
    run("status", "--interface", "invalid;interface", expected=2)
    missing, _ = run("status", "--interface", "en999", expected=1)
    assert missing["error"]["code"] == "interface"
    check_cancellation()
    after, _ = run("status")
    for key in ("interface", "poweredOn", "association", "addresses"):
        assert before["status"][key] == after["status"][key], f"{key} changed during read-only checks"
    print("PASS: read-only integration and dry runs; interface and IP state preserved")


def check_cancellation():
    before = set(Path("/private/tmp").glob("wifi-cli.*"))
    process = subprocess.Popen([str(CLI), "permissions", "--json"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and process.poll() is None:
            if set(Path("/private/tmp").glob("wifi-cli.*")) - before:
                process.send_signal(signal.SIGINT)
                break
            time.sleep(0.001)
        process.communicate(timeout=3)
        assert process.returncode == 130, process.returncode
        time.sleep(0.8)  # Helper's parent watchdog runs every 0.5 seconds.
        assert not set(Path("/private/tmp").glob("wifi-cli.*")) - before
        commands = subprocess.check_output(["ps", "-axo", "command="], text=True)
        assert f"--client-pid {process.pid} " not in commands
        print("cancellation: socket cleaned; helper exited")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
