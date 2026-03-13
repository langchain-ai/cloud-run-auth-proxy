"""Example ext_authz sidecar for Anthropic.

This is the provider-specific component of the auth proxy. It reads
the LLM provider API key from the LLM_PROVIDER_API_KEY env var and
injects the headers required by the Anthropic Messages API.

To support a different LLM provider, copy this file and change the
headers in do_any() to match your provider's requirements. For example:
  - OpenAI: inject "Authorization: Bearer <key>"
  - Azure OpenAI: inject "api-key: <key>"
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import os

API_KEY = os.environ["LLM_PROVIDER_API_KEY"]


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    def do_any(self):
        self.send_response(200)
        # --- Anthropic-specific headers ---
        self.send_header("x-api-key", API_KEY)
        self.send_header("anthropic-version", "2023-06-01")
        # Strip the LangSmith JWT header before forwarding to the provider
        self.send_header("x-envoy-auth-headers-to-remove", "x-langsmith-llm-auth")
        self.end_headers()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_any

    def log_message(self, format, *args):
        print(f"ext_authz: {args[0]}", flush=True)


if __name__ == "__main__":
    # Must bind 0.0.0.0 — Cloud Run health checks can't reach 127.0.0.1.
    # Port 10002 is not exposed externally; only the ingress container's port is public.
    server = ThreadedHTTPServer(("0.0.0.0", 10002), Handler)
    print("ext_authz listening on :10002", flush=True)
    server.serve_forever()
