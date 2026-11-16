#!/usr/bin/env python3
"""Minimal OpenAguja webhook receiver — stdlib only.

Accepts the action POSTs described in docs/integrations/webhook.md,
checks the Bearer token, prints every event and answers 2xx
(including the "test" action used by the app's connection check).

Usage:
    python3 receiver.py [--host 0.0.0.0] [--port 8787] [--token SECRET]

Then set the app's action URL to http://<this-host>:8787/hook
(plus --token as the app's webhook token).
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    server_version = "OpenAgujaReceiver/1.0"
    token: str = ""

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Optional: serve daily telemetry summaries for the history UI.
        # The app calls GET <telemetryHistoryURL>?days=N and expects a
        # bare JSON array of day objects — return [] when you have none.
        if self.path.startswith("/history"):
            self._send(200, [])
        else:
            self._send(200, {"service": "openaguja-receiver"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""

        auth = self.headers.get("Authorization", "")
        if self.token:
            expected = f"Bearer {self.token}"
            if auth != expected:
                self._send(401, {"message": "unauthorized"})
                return

        try:
            event = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self._send(400, {"message": "invalid JSON"})
            return

        action = event.get("action", "?")
        extra = {k: v for k, v in event.items() if k != "action"}
        print(f"[event] action={action} {json.dumps(extra, ensure_ascii=False)}",
              flush=True)

        # 2xx for everything, including "test" — see docs/integrations/webhook.md.
        self._send(200, {"message": f"received {action}"})

    def log_message(self, fmt, *args):  # quieter default logging
        pass


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--token", default="", help="required Bearer token")
    args = ap.parse_args()

    Handler.token = args.token
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"OpenAguja receiver on http://{args.host}:{args.port}")
    print("POST any path (e.g. /hook) with {\"action\": ...}; GET /history → []")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
