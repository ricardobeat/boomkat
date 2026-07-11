#!/usr/bin/env bash
# Run a single test262 test through the canonical batch_test_vm --worker path.
#
# Usage:
#   run_single_test.sh <test_file_path>           # canonical batch verifier
#   run_single_test.sh <test_file_path> --debug   # concat harness + duktape_c3 (for lldb)
#   run_single_test.sh <test_file_path> --keep     # --debug mode, prints combined file path
#
# Default mode pipes the absolute path to batch_test_vm --worker — the same
# binary and harness path the suite measures.  --debug concatenates assert.js,
# sta.js, and includes into a single file and runs under duktape_c3 (the old
# behaviour); --keep prints the temp file path instead of deleting it (useful
# for `just run` / `just lldb` / --trace-vm debugging).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
test_file="$1"
mode="${2:-}"
batch_bin="$PROJECT_DIR/out/batch_test_vm"
debug_bin="$PROJECT_DIR/out/duktape_c3"

# Resolve a path relative to test262/test/ if the file doesn't exist as given.
# Accept both "language/…" and "test/language/…" forms.
if [ ! -f "$test_file" ]; then
  if [ -f "$PROJECT_DIR/test262/test/$test_file" ]; then
    test_file="$PROJECT_DIR/test262/test/$test_file"
  elif [ -f "$PROJECT_DIR/test262/$test_file" ]; then
    test_file="$PROJECT_DIR/test262/$test_file"
  fi
fi
# A missing test file must be an error, never a harness-only false PASS.
if [ ! -f "$test_file" ]; then
  echo "ERROR: test file not found: $test_file" >&2
  exit 2
fi

# Make path absolute for the batch worker (it resolves relative to its own cwd)
test_file="$(cd "$(dirname "$test_file")" && pwd)/$(basename "$test_file")"

# ── Debug mode: old concat-harness + duktape_c3 path ────────────────────────
if [ "$mode" = "--debug" ] || [ "$mode" = "--keep" ]; then
  combined="${TMPDIR:-/tmp}/t262_$$_${RANDOM}.js"
  cat "$PROJECT_DIR/test262/harness/assert.js" "$PROJECT_DIR/test262/harness/sta.js" > "$combined"

  # Pull in harness files from `includes: [a.js, b.js]` metadata
  includes=$(awk '/^includes:/{gsub(/.*\[|\].*/,""); gsub(/,/," "); print; exit}' "$test_file")
  for inc in $includes; do
    cat "$PROJECT_DIR/test262/harness/$inc" >> "$combined"
  done

  cat "$test_file" >> "$combined"

  if [ "$mode" = "--keep" ]; then
    echo "$combined"
    exit 0
  fi

  if timeout 10 "$debug_bin" "$combined" > "${combined}.out" 2>&1; then
    echo "PASS  $test_file"
  else
    echo "FAIL  $test_file (exit $?)"
    head -5 "${combined}.out" | sed 's/^/    /'
  fi
  rm -f "$combined" "${combined}.out"
  exit 0
fi

# ── Default mode: canonical batch_test_vm --worker path ──────────────────────
if [ ! -f "$batch_bin" ]; then
  echo "ERROR: $batch_bin not found. Build with: make out/batch_test_vm" >&2
  exit 2
fi

result=$(echo "$test_file" | "$batch_bin" --worker 2>/dev/null)
if [ -z "$result" ]; then
  echo "FAIL  $test_file (no output from worker)"
  exit 1
fi

# Worker prints "PASS <path>", "FAIL <path>", or "COMPILE_ERROR <path>"
echo "$result"
