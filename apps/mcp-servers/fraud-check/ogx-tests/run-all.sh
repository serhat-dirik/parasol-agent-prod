#!/usr/bin/env bash
# Run checks 1-6 against the test OGX server (setup.sh first). Exit code = number of failed checks.
cd "$(dirname "$0")"
failed=0
for t in ./[1-6]-*.sh; do echo "### $t"; "$t" || failed=$((failed + 1)); done
echo "failed checks: $failed"; exit "$failed"
