#!/usr/bin/env bash
# Run all workflow logic tests
# Usage: ./tests/run.sh
set -euo pipefail

echo "Running workflow tests..."
echo ""

node --test tests/test_*.mjs

echo ""
echo "All tests passed."
