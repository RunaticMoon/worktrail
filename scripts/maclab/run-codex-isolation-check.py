#!/usr/bin/env python3
"""Check WorkLog's tool isolation using Codex >= 0.163.0 and a local fake API.

Usage: python3 scripts/maclab/run-codex-isolation-check.py [--codex /path/to/codex]
No real account, token, Keychain, API key, or inference service is used. Child
processes receive an allowlisted environment and temporary HOME/CODEX_HOME.
Only pass a trusted Codex executable. The fixture model name does not cause a
real model request: its provider points exclusively to the local HTTP server.
"""

import argparse
import http.server
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


class CheckFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CheckFailure(message)


def production_arguments():
    """Fail closed if the production argument builder changes shape."""
    source = (Path(__file__).resolve().parents[2] /
              "Sources/WorkLogCore/AI/CodexAppServerProvider.swift").read_text()
    builder = re.search(r"static let processArguments: \[String\] = \{(.*?)return result", source, re.S)
    require(builder is not None, "Cannot find production Codex argument builder")
    initial = re.search(r"var result = (\[.*?\])", builder.group(1), re.S)
    features = re.search(r"for feature in (\[.*?\]) \{", builder.group(1), re.S)
    require(initial is not None and features is not None, "Production argument builder changed; update this check")
    arguments = json.loads(initial.group(1))
    for feature in json.loads(features.group(1)):
        arguments += ["-c", "features." + feature + "=false"]
    for extra in re.findall(r"result \+= (\[.*?\])", builder.group(1), re.S):
        if r"\(feature)" not in extra:
            arguments += json.loads(extra)
    require('"environments": .array([])' in source and
            '"selectedCapabilityRoots": .array([])' in source,
            "Production thread no longer disables environments/capability roots")
    require('"mcp_servers": .object(disabledServers)' in source,
            "Production thread no longer disables inherited MCP servers")
    return arguments


def stop_process(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
    for stream in (process.stdin, process.stdout):
        if stream:
            stream.close()


def check(codex, timeout):
    deadline = time.monotonic() + timeout

    def remaining():
        value = deadline - time.monotonic()
        require(value > 0, "Fixture exceeded its total timeout")
        return value

    with tempfile.TemporaryDirectory(prefix="worklog-codex-isolation-") as directory:
        root = Path(directory)
        home, codex_home, tmp = root / "home", root / "codex", root / "tmp"
        for path in (home, codex_home, tmp):
            path.mkdir(mode=0o700)
        # Construct from scratch: no API keys, auth tokens, proxy variables, or
        # caller CODEX_HOME/AGENTS configuration enter the child environment.
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": str(home), "CODEX_HOME": str(codex_home), "TMPDIR": str(tmp),
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TERM": "dumb",
        }
        version = subprocess.run([codex, "--version"], env=environment, cwd=root,
                                 capture_output=True, text=True, timeout=remaining(), check=True)
        match = re.search(r"\b(\d+)\.(\d+)\.(\d+)\b", version.stdout)
        require(match is not None, "Cannot determine the Codex version")
        version_numbers = tuple(int(value) for value in match.groups())
        require(version_numbers >= (0, 163, 0), "Codex CLI 0.163.0 or newer is required")

        received = queue.Queue()

        class FakeAPI(http.server.BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"data":[]}')

            def do_POST(self):
                self.connection.settimeout(2)
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    require(0 < size <= 4 * 1024 * 1024, "Unexpected fake API request size")
                    payload = json.loads(self.rfile.read(size))
                    received.put((self.path, bool(self.headers.get("Authorization")), payload))
                    data = (b'data: {"type":"response.completed","response":'
                            b'{"id":"fixture-response","status":"completed","output":[]}}\n\n')
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except (ValueError, OSError, CheckFailure):
                    received.put(("invalid", False, {}))

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeAPI)
        server.daemon_threads = True
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        process = None
        try:
            endpoint = "http://127.0.0.1:%d/v1" % server.server_port
            marker = root / "mcp-started"
            (codex_home / "config.toml").write_text(
                'cli_auth_credentials_store="file"\nmcp_oauth_credentials_store="file"\n'
                'model_provider="fixture"\nmodel="gpt-5.4"\n'
                '[model_providers.fixture]\nname="fixture"\nbase_url=' + json.dumps(endpoint) + '\n'
                'wire_api="responses"\nrequires_openai_auth=false\n'
                '[mcp_servers.fixture]\ncommand="/usr/bin/touch"\nargs=[' + json.dumps(str(marker)) + ']\n')
            arguments = production_arguments() + [
                "-c", "cli_auth_credentials_store=\"file\"",
                "-c", "mcp_oauth_credentials_store=\"file\"",
                "-c", "features.remote_models=false",
                "-c", "analytics.enabled=false", "-c", "feedback.enabled=false",
                "-c", "otel.exporter=\"none\"", "-c", "otel.metrics_exporter=\"none\"",
            ]
            process = subprocess.Popen([codex] + arguments, cwd=root, env=environment,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, text=True, bufsize=1,
                                       start_new_session=True)
            messages = queue.Queue()

            def read_messages():
                try:
                    for line in process.stdout:
                        try:
                            messages.put(json.loads(line))
                        except ValueError:
                            messages.put(None)
                            return
                finally:
                    messages.put(None)

            threading.Thread(target=read_messages, daemon=True).start()

            def send(message):
                process.stdin.write(json.dumps(message) + "\n")
                process.stdin.flush()

            def request(identifier, method, params):
                send({"id": identifier, "method": method, "params": params})
                while True:
                    message = messages.get(timeout=remaining())
                    require(message is not None, "Codex protocol closed before " + method)
                    if message.get("id") == identifier:
                        require("error" not in message, "Codex rejected fixture method " + method)
                        return message["result"]

            request(1, "initialize", {"clientInfo": {"name": "worklog-fixture", "version": "0.1.0"},
                                      "capabilities": {"experimentalApi": True}})
            send({"method": "initialized"})
            config = request(2, "config/read", {"includeLayers": False, "cwd": str(root)})["config"]
            require(config.get("model_provider") == "fixture", "The fake provider is not active")
            require(config["model_providers"]["fixture"]["base_url"] == endpoint,
                    "The provider does not point to the local fake API")
            require(config.get("cli_auth_credentials_store") == "file", "File-only credentials are not active")
            names = list(config.get("mcp_servers", {}))
            require(names == ["fixture"], "Unexpected MCP configuration in isolated fixture")
            thread = request(3, "thread/start", {
                "model": "gpt-5.4", "cwd": str(root), "ephemeral": True,
                "sandbox": "read-only", "approvalPolicy": "never",
                "environments": [], "selectedCapabilityRoots": [],
                "baseInstructions": "Return JSON from the supplied fixture text only. Do not use tools.",
                "config": {"mcp_servers": {name: {"enabled": False} for name in names}},
            })
            request(4, "turn/start", {"threadId": thread["thread"]["id"],
                                      "input": [{"type": "text", "text": 'Return {"fixture":true}'}]})
            path, authenticated, payload = received.get(timeout=remaining())
            require(path == "/v1/responses", "Unexpected request to local fake API")
            require(not authenticated, "The fake inference unexpectedly used authorization")
            require(payload.get("tools", []) == [], "Codex exposed tools despite WorkLog isolation settings")
            require(not marker.exists(), "Codex started the disabled fake MCP server")
            print("PASS Codex %s: local fake API, no authorization, tools=[], MCP not started" %
                  ".".join(map(str, version_numbers)))
        finally:
            if process:
                stop_process(process)
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)
    print("PASS temporary HOME/CODEX_HOME and fixture files removed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"), help="Trusted Codex CLI executable (default: PATH)")
    parser.add_argument("--timeout", type=float, default=30, help="Total timeout in seconds (default: 30)")
    args = parser.parse_args()
    try:
        require(args.codex is not None, "Codex is not on PATH; supply --codex")
        require(0 < args.timeout <= 120, "Timeout must be between 0 and 120 seconds")
        codex = str(Path(args.codex).expanduser().resolve())
        require(os.access(codex, os.X_OK), "Codex executable is missing or not executable")
        check(codex, args.timeout)
    except (CheckFailure, OSError, ValueError, KeyError, queue.Empty, subprocess.SubprocessError) as error:
        # Never dump child configuration, environment, protocol traffic or stderr.
        reason = str(error) if isinstance(error, CheckFailure) else type(error).__name__
        print("FAIL: " + reason, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
