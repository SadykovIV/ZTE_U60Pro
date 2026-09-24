#!/bin/bash
# Local demo: dashboard on :8080 + mock agent on :9090 (no device needed).
#   bash tools/demo.sh        start (foreground; Ctrl-C stops both)
#   bash tools/demo.sh stop   stop a backgrounded demo
set -e
cd "$(dirname "$0")/.."

stop() {
  [ -f /tmp/u60-mock-agent.pid ] && kill "$(cat /tmp/u60-mock-agent.pid)" 2>/dev/null && echo "mock agent stopped"
  [ -f /tmp/u60-preview.pid ] && kill "$(cat /tmp/u60-preview.pid)" 2>/dev/null && echo "preview stopped"
  rm -f /tmp/u60-mock-agent.pid /tmp/u60-preview.pid
}

if [ "${1:-}" = "stop" ]; then stop; exit 0; fi

npm run build >/dev/null

python3 tools/mock_agent.py --port 9090 >/tmp/u60-mock-agent.log 2>&1 &
echo $! > /tmp/u60-mock-agent.pid

npm run preview -- --port 8080 --strictPort >/tmp/u60-preview.log 2>&1 &
echo $! > /tmp/u60-preview.pid

sleep 2
echo "──────────────────────────────────────────────"
echo "  Dashboard:  http://localhost:8080"
echo "  Mock agent: http://localhost:9090"
echo "  Sign in with any password (e.g. 'demo')"
echo "  Stop with Ctrl-C or: bash tools/demo.sh stop"
echo "──────────────────────────────────────────────"

trap 'stop' INT TERM
wait
