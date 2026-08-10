#!/usr/bin/env python3
import json
import pathlib
import sys
import time


counter_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
mode = sys.argv[2] if len(sys.argv) > 2 else "normal"
marker_path = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
list_count = 0

if mode == "fail-init":
    sys.stderr.write("x" * 70000 + " fixture secret=fixture-super-secret\n")
    sys.stderr.flush()
    sys.exit(1)


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        continue

    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        if mode == "count-connection" and counter_path:
            with counter_path.open("a", encoding="utf-8") as counter:
                counter.write("initialize\n")
        if mode == "hang-init":
            continue
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": request["params"]["protocolVersion"],
                "capabilities": {"tools": {"listChanged": mode == "list-change"}},
                "serverInfo": {"name": "TypeWhisper MCP Fixture", "version": "0.1.0"},
            },
        })
    elif method == "tools/list":
        list_count += 1
        if mode == "count-connection" and counter_path:
            with counter_path.open("a", encoding="utf-8") as counter:
                counter.write("list\n")
        if mode == "list-change" and counter_path:
            with counter_path.open("a", encoding="utf-8") as counter:
                counter.write("list\n")
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "tools": [{
                    "name": "create_task",
                    "description": "Create a fixture task version " + str(list_count),
                    "inputSchema": {
                        "type": "object",
                        "properties": {"title": {"type": "string"}},
                        "required": ["title"],
                    },
                    "annotations": {"readOnlyHint": False, "destructiveHint": False},
                }]
            },
        })
        if mode == "list-change" and list_count == 1:
            send({
                "jsonrpc": "2.0",
                "method": "notifications/tools/list_changed",
            })
        if mode == "exit-after-first-list" and marker_path and not marker_path.exists():
            marker_path.write_text("exited", encoding="utf-8")
            time.sleep(0.1)
            sys.exit(0)
    elif method == "tools/call":
        if counter_path:
            with counter_path.open("a", encoding="utf-8") as counter:
                counter.write("1\n")
        title = request.get("params", {}).get("arguments", {}).get("title", "")
        if title == "crash-after-receive":
            sys.exit(0)
        if title == "hang":
            continue
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "content": [{"type": "text", "text": "created:" + title}],
                "isError": title == "fail",
            },
        })
    elif request_id is not None:
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": "Method not found"},
        })
