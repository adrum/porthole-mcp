#!/usr/bin/env python3
"""Drive the Android demo through a porthole-mcp server, as an agent would.

    android/e2e.py <porthole-mcp binary> <demo-debug.apk>

Needs adb on PATH and one emulator or device. The server's hub maps the
device to itself with adb reverse; launch installs the APK. Exits non-zero
on the first failed step, printing what the tool said.
"""

import json
import subprocess
import sys
import threading
import queue


class Server:
    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1
        )
        self.replies = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        self.next_id = 0

    def _read(self):
        for line in self.proc.stdout:
            try:
                self.replies.put(json.loads(line))
            except ValueError:
                pass

    def request(self, method, params, timeout=300):
        self.next_id += 1
        mine = self.next_id
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": mine, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        while True:
            reply = self.replies.get(timeout=timeout)
            if reply.get("id") == mine:
                return reply

    def tool(self, name, /, **args):
        print(f"→ {name} {json.dumps(args)}", flush=True)
        reply = self.request("tools/call", {"name": name, "arguments": args})
        result = reply.get("result", {})
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError") or "error" in reply:
            sys.exit(f"✗ {name} failed:\n{text or reply}")
        return result, text


def main():
    binary, apk = sys.argv[1], sys.argv[2]
    s = Server(binary)
    s.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})

    # The Views screen.
    _, out = s.tool("launch", path=apk, timeout_ms=180000)
    print(out)
    _, tree = s.tool("inspect")
    print(tree)
    for id in ("#email", "#subscribe", "#save", "#status"):
        assert id in tree, f"{id} missing from the tree"
    s.tool("fill", target="#email", text="ada@example.com")
    s.tool("click", target="#subscribe")
    s.tool("click", target="#save")
    s.tool("wait_for", target='~"Saved ada@example.com (subscribed)"')
    result, _ = s.tool("screenshot")
    assert result["content"][0]["type"] == "image", "screenshot isn't an image"
    _, logs = s.tool("logs", grep="save tapped")
    assert "save tapped: ada@example.com" in logs, f"the app's log line is missing:\n{logs}"
    s.tool("run_hook", name="reset")
    s.tool("wait_for", target='"Not saved"')

    # The Compose screen, by testTag.
    s.tool("click", target="#open_compose")
    s.tool("wait_for", target="#count")
    s.tool("click", target="#add")
    s.tool("wait_for", target='"Count: 1"')
    s.tool("fill", target="#name", text="Ada")
    s.tool("wait_for", target='~"Hello, Ada"')
    _, tree = s.tool("inspect")
    print(tree)
    # A Compose button is named by the Text inside it, which isn't listed
    # again, and untagged elements keep their ids from one inspect to the next.
    assert 'button "Add" #add' in tree, "the Add button isn't named by its text"
    assert 'text "Add"' not in tree, "the button's own text is listed twice"
    _, again = s.tool("inspect")
    assert again == tree, f"ids changed between inspects:\n{tree}\n{again}"
    s.tool("click", target="#dark")
    _, a11y = s.tool("inspect", a11y=True)
    print(a11y)
    for fact in ("font=", "contrast="):
        assert fact in a11y, f"inspect a11y has no {fact} facts"

    print("✓ the Android demo was driven end to end")
    s.proc.terminate()


if __name__ == "__main__":
    main()
