"""Protocol and process tests use fake executables; they never change Wi-Fi."""

import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from mcp import Client, StdioServerParameters

from server import WiFiCLI, create_server


class ServerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="wm", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.binary = Path(self.directory.name) / "wifi"
        self.log = self.binary.with_suffix(".log")
        self.write_binary(
            "import json, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "with pathlib.Path(__file__).with_suffix('.log').open('a') as log:\n"
            "    log.write(json.dumps(args) + '\\n')\n"
            "if 'scan' in args:\n"
            "    print(json.dumps({'ok': False, 'error': {'code': 'permission', 'message': 'Access denied'}, 'warnings': ['No identity access']}))\n"
            "    sys.exit(3)\n"
            "print(json.dumps({'ok': True, 'arguments': args, 'warnings': []}))\n"
        )

    def write_binary(self, body):
        self.binary.write_text(f"#!{sys.executable}\n{body}")
        self.binary.chmod(0o700)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    async def test_default_tools_are_read_only_and_cannot_mutate(self):
        async with Client(create_server(WiFiCLI(self.binary))) as client:
            tools = (await client.list_tools()).tools
            self.assertEqual({t.name for t in tools}, {"wifi_status", "wifi_scan", "wifi_permissions"})
            self.assertTrue(all(t.annotations.read_only_hint for t in tools))
            for name in ("wifi_join_open", "wifi_disconnect", "wifi_power"):
                self.assertTrue((await client.call_tool(name, {})).is_error)
        self.assertEqual(self.calls(), [])

    async def test_status_structured_output_preserves_json(self):
        async with Client(create_server(WiFiCLI(self.binary))) as client:
            response = await client.call_tool("wifi_status", {"interface": "en0"})
            self.assertFalse(response.is_error)
            self.assertEqual(json.loads(response.content[0].text), response.structured_content)
        self.assertEqual(self.calls(), [["--json", "--timeout", "45", "--interface", "en0", "status", "--"]])

    async def test_cli_errors_are_mcp_errors_with_details(self):
        async with Client(create_server(WiFiCLI(self.binary))) as client:
            response = await client.call_tool("wifi_scan", {})
            self.assertTrue(response.is_error)
            self.assertEqual(response.structured_content["error"]["code"], "permission")
            self.assertEqual(response.structured_content["warnings"], ["No identity access"])

    async def test_change_tools_require_explicit_real_execution(self):
        async with Client(create_server(WiFiCLI(self.binary), allow_changes=True)) as client:
            tools = (await client.list_tools()).tools
            changes = [t for t in tools if not t.annotations.read_only_hint]
            self.assertEqual(len(changes), 3)
            self.assertTrue(all(t.annotations.destructive_hint for t in changes))
            self.assertTrue(all("password" not in t.input_schema["properties"] for t in tools))
            for name, arguments in (("wifi_join_open", {"ssid": "Guest"}),
                                    ("wifi_disconnect", {}), ("wifi_power", {"on": False})):
                self.assertFalse((await client.call_tool(name, arguments)).is_error)
            self.assertFalse((await client.call_tool("wifi_disconnect", {"dry_run": False})).is_error)
        self.assertTrue(all("--dry-run" in args for args in self.calls()[:3]))
        self.assertNotIn("--dry-run", self.calls()[3])
        self.assertIn("--open", self.calls()[0])

    async def test_ssid_is_literal_and_never_shell_code(self):
        marker = Path(self.directory.name) / "x"
        ssid = f"--$(touch {marker})"
        self.assertLessEqual(len(ssid), 32)
        async with Client(create_server(WiFiCLI(self.binary), allow_changes=True)) as client:
            response = await client.call_tool("wifi_join_open", {"ssid": ssid})
            self.assertFalse(response.is_error)
        self.assertEqual(self.calls()[0][-3:], ["join", "--", ssid])
        self.assertFalse(marker.exists())

    async def test_schema_rejects_invalid_arguments_before_process_start(self):
        async with Client(create_server(WiFiCLI(self.binary), allow_changes=True)) as client:
            for name, arguments in (("wifi_status", {"interface": "en0\u0000"}),
                                    ("wifi_join_open", {"ssid": ""}),
                                    ("wifi_power", {"on": "false"}),
                                    ("wifi_disconnect", {"dry_run": "false"})):
                self.assertTrue((await client.call_tool(name, arguments)).is_error)
        self.assertEqual(self.calls(), [])

    async def test_invalid_response_is_not_reported_as_success(self):
        for output in ("not json", "[]", '{"ok": "true"}'):
            self.write_binary(f"print({output!r})\n")
            response = await WiFiCLI(self.binary).run("status")
            self.assertTrue(response.is_error)
            self.assertEqual(response.structured_content["error"]["code"], "protocol")

    async def test_nonzero_exit_cannot_report_success(self):
        self.write_binary('import sys\nprint(\'{"ok": true}\')\nsys.exit(1)\n')
        response = await WiFiCLI(self.binary).run("status")
        self.assertTrue(response.is_error)

    async def test_calls_are_serialized(self):
        self.write_binary(
            "import json, pathlib, time\n"
            "log = pathlib.Path(__file__).with_suffix('.log')\n"
            "with log.open('a') as f: f.write('start\\n')\n"
            "time.sleep(0.05)\n"
            "with log.open('a') as f: f.write('end\\n')\n"
            "print(json.dumps({'ok': True}))\n"
        )
        cli = WiFiCLI(self.binary)
        await asyncio.gather(cli.run("status"), cli.run("scan"))
        self.assertEqual(self.log.read_text().splitlines(), ["start", "end", "start", "end"])

    async def test_timeout_and_cancellation_reap_the_child(self):
        pid_file = self.binary.with_suffix(".pid")
        self.write_binary(
            "import os, pathlib, time\n"
            "pathlib.Path(__file__).with_suffix('.pid').write_text(str(os.getpid()))\n"
            "time.sleep(60)\n"
        )
        with patch("server.PROCESS_GRACE_SECONDS", 0):
            response = await WiFiCLI(self.binary, timeout=1).run("status")
        self.assertEqual(response.structured_content["error"]["code"], "timeout")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_file.read_text()), 0)
        pid_file.unlink()
        task = asyncio.create_task(WiFiCLI(self.binary).run("status"))
        for _ in range(100):
            if pid_file.exists():
                break
            await asyncio.sleep(0.01)
        self.assertTrue(pid_file.exists())
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_file.read_text()), 0)

    async def test_stdio_transport_with_official_client(self):
        params = StdioServerParameters(
            command=sys.executable,
            args=[str(Path(__file__).with_name("server.py")), "--wifi-bin", str(self.binary)],
        )
        for mode in ("auto", "legacy"):
            async with Client(params, mode=mode) as client:
                self.assertEqual(len((await client.list_tools()).tools), 3)
                self.assertFalse((await client.call_tool("wifi_status", {})).is_error)
                self.assertTrue((await client.call_tool("wifi_scan", {})).is_error)


if __name__ == "__main__":
    unittest.main()
