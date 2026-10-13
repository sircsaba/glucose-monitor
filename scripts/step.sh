#!/usr/bin/env bash
# Runs a build command. If it fails, the last lines of its output are shown
# as an error note on the GitHub run page (easier to read than the full log).
# Usage: scripts/step.sh "Step name" command args...
name="$1"
shift
log="$(mktemp)"
set -o pipefail
"$@" 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
if [ "$code" -ne 0 ]; then
  msg="$(tail -n 40 "$log" | sed -e 's/\x1b\[[0-9;]*m//g' | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')"
  echo "::error title=${name} failed::${msg}"
  # Also show the lines that mention an error anywhere in the output.
  errs="$(grep -iE 'error|failed|exception|could not|unable' "$log" | grep -v '^\s*$' | tail -n 25 | sed -e 's/\x1b\[[0-9;]*m//g' | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')"
  if [ -n "$errs" ]; then
    echo "::error title=${name} - error lines::${errs}"
  fi
fi
exit "$code"
