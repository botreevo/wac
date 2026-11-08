"""git's own smart-HTTP server, `git http-backend`, behind the least web server that can run it.

    python3 bench/http_backend.py <root> <port>

This is the baseline the wac server is measured against: git's CGI program, exactly as Apache or nginx would
run it, with each request's body read whole (chunked bodies decoded, since CGI wants a length) and its answer
sent whole — which is also what the wac server does, so the comparison is between the two programs and not
between two ways of buffering. `http-backend` does its own gzip decoding and runs `git upload-pack` and
`git receive-pack` as children, so the server's CPU time includes theirs.

Pushing is allowed to anyone (`http.receivepack` is set per repository by the benchmark), to match
`gitserve --anonymous-push`.
"""

import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            out = bytearray()
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip(), 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return bytes(out)
                out += self.rfile.read(size)
                self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def run(self):
        path, _, query = self.path.partition("?")
        data = self.body()
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GIT_PROJECT_ROOT": ROOT,
            "GIT_HTTP_EXPORT_ALL": "1",
            "GIT_HTTP_MAX_REQUEST_BUFFER": "1000M",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(data)),
            "REMOTE_ADDR": self.client_address[0],
            "SERVER_PROTOCOL": "HTTP/1.1",
            "GATEWAY_INTERFACE": "CGI/1.1",
        }
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        out = subprocess.run(["git", "http-backend"], input=data, env=env, capture_output=True).stdout
        sep = out.find(b"\r\n\r\n")
        cut = 4
        if sep < 0:
            sep, cut = out.find(b"\n\n"), 2
        head, payload = out[:sep].decode("latin-1"), out[sep + cut:]
        status, headers = 200, []
        for line in head.splitlines():
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.strip().split()[0])
            elif name:
                headers.append((name, value.strip()))
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    do_GET = run
    do_POST = run


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
