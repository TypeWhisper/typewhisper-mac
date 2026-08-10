#!/usr/bin/env python3
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


port_path = pathlib.Path(sys.argv[1])
counter_path = pathlib.Path(sys.argv[2])
expected_token = sys.argv[3] if len(sys.argv) > 3 else ""
session_id = "typewhisper-http-fixture"


class MCPHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_arguments):
        return

    def authenticated(self):
        if not expected_token:
            return True
        if self.headers.get("Authorization") == "Bearer " + expected_token:
            return True
        self.send_response(401)
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def send_json(self, payload, status=200, include_session=True):
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if include_session:
            self.send_header("MCP-Session-Id", session_id)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != "/mcp":
            self.send_error(404)
            return
        if not self.authenticated():
            return
        data = b": connected\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/mcp":
            self.send_error(404)
            return
        if not self.authenticated():
            return

        length = int(self.headers.get("Content-Length", "0"))
        try:
            request = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self.send_error(400)
            return

        method = request.get("method")
        request_id = request.get("id")
        with counter_path.open("a", encoding="utf-8") as counter:
            counter.write((method or "unknown") + "\n")

        if method == "initialize":
            self.send_json({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": request["params"]["protocolVersion"],
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "TypeWhisper HTTP Fixture", "version": "0.1.0"},
                },
            })
        elif method == "notifications/initialized":
            self.send_response(202)
            self.send_header("MCP-Session-Id", session_id)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif method == "tools/list":
            self.send_json({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "tools": [{
                        "name": "create_task",
                        "description": "Create a fixture task over Streamable HTTP",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"title": {"type": "string"}},
                            "required": ["title"],
                        },
                        "annotations": {"readOnlyHint": False, "destructiveHint": False},
                    }]
                },
            })
        elif method == "tools/call":
            title = request.get("params", {}).get("arguments", {}).get("title", "")
            self.send_json({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "content": [{"type": "text", "text": "created:" + title}],
                    "isError": False,
                },
            })
        elif request_id is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_json({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": "Method not found"},
            })


server = ThreadingHTTPServer(("127.0.0.1", 0), MCPHandler)
port_path.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
