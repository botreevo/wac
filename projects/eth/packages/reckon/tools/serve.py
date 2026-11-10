#!/usr/bin/env python3
"""A static file server for mirrors and manifests, as a page or an extension needs them served (docs/discovery.md):
plain GETs of files, and `Access-Control-Allow-Origin: *` on every answer, so a browser page may read them.

    python3 tools/serve.py PORT [DIR]       (DIR defaults to the current directory; binds 127.0.0.1)

Any static host that adds that header does the same job; this one is for the tests and for trying it locally.
"""
import functools
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def log_message(self, *args):
        pass


port = int(sys.argv[1])
root = sys.argv[2] if len(sys.argv) > 2 else "."
http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=root)).serve_forever()
