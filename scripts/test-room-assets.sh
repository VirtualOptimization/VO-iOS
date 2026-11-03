#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-room-assets.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$project_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'RoomPlanExporter/Views/Scan/RoomViewerView.swift').read_text()
actor = source[source.index('actor FurnitureAssetFiles {'):source.index('@MainActor\nprivate final class FurnitureModelTemplates')]
(build / 'AssetFiles.swift').write_text('import Foundation\nimport CryptoKit\n' + actor)
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/module-cache" \
  "$build_dir/AssetFiles.swift" "$project_dir/Tests/RoomViewer/AssetCacheTests.swift" -o "$build_dir/test-assets"
python3 - "$build_dir/test-assets" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread, Lock
import subprocess, json, time, sys
counts, active, maximum = {}, 0, 0
lock = Lock()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        global active, maximum
        if self.path == '/stats':
            with lock: data = json.dumps({'counts': counts, 'maximum': maximum}).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(data); return
        with lock:
            counts[self.path] = counts.get(self.path, 0) + 1
            active += 1; maximum = max(maximum, active)
        try:
            time.sleep(.08)
            self.send_response(503 if self.path == '/failure' else 200)
            self.send_header('Content-Length', '4096'); self.end_headers()
            self.wfile.write(b'x' * 4096)
        finally:
            with lock: active -= 1
with ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
    Thread(target=server.serve_forever, daemon=True).start()
    result = subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}'])
    server.shutdown()
    sys.exit(result.returncode)
PY
