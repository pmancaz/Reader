#!/usr/bin/env python3
"""Local-only QA server; never touches ReaderData. Ctrl-C to stop."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=8766)
parser.add_argument('--port-file', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1] / 'Tests' / 'Fixtures'

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)
    def do_GET(self):
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/article.html')
            self.end_headers()
        elif self.path == '/unavailable':
            self.send_error(503, 'Fixture temporarily unavailable')
        elif self.path == '/unsupported':
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.end_headers()
            self.wfile.write(b'Not an article or PDF')
        else:
            super().do_GET()

server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
if args.port_file:
    args.port_file.write_text(str(server.server_port))
print(f'Fixture article: http://127.0.0.1:{server.server_port}/article.html', flush=True)
server.serve_forever()
