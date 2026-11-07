#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/vo-optimization-tests.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$project_dir" "$build_dir" <<'PYMODELS'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'RoomPlanExporter/ViewModels/ScanViewModel+RoomScan.swift').read_text()
waiter = source[source.index('enum OptimizationPolling {'):source.index('// MARK: - 방 스캔 업로드')]
service = (root / 'RoomPlanExporter/Services/RoomOptimizerService.swift').read_text()
errors = service[service.index('enum OptimizerError:'):]
(build / 'Polling.swift').write_text('import Foundation\n' + waiter + errors)
PYMODELS
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/module-cache" \
  "$build_dir/Polling.swift" "$project_dir/Tests/Optimization/OptimizationPollingTests.swift" \
  -o "$build_dir/test-polling"
"$build_dir/test-polling"
