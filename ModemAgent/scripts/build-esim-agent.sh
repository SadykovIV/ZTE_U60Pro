#!/bin/sh
# Build the complete public physical-eUICC runtime. Never deploys to a modem.
set -eu
cd "$(dirname "$0")/../.."
exec python3 tools/build.py --modem-only --tests
