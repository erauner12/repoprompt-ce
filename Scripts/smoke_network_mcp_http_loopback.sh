#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else "ERROR: smoke_network_mcp_http_loopback.py requires Python 3.8+")'
exec python3 "$SCRIPT_DIR/smoke_network_mcp_http_loopback.py" "$@"
