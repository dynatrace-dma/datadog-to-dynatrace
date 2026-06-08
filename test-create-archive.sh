#!/usr/bin/env bash
# =============================================================================
# Test: create_archive() writes a valid SHA-256 checksum sidecar
# =============================================================================
# Regression guard for the bug where `cd "$EXPORT_DIR"` (EXPORT_DIR is relative
# by default, ./datadog-export) changed the shell cwd and silently invalidated
# every relative path below it -- so the .tar.gz was produced but the sibling
# .tar.gz.sha256 was never written.
#
# This test extracts the REAL create_archive() function from
# dma-datadog-export.sh (not a copy), stubs its logging/helper dependencies,
# runs it against a populated export dir referenced by a RELATIVE path, and
# asserts the checksum file exists and validates with `shasum -a 256 -c`.
#
# Usage: ./test-create-archive.sh   (exit 0 = pass, non-zero = fail)
# =============================================================================
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/dma-datadog-export.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$TARGET" ]] || fail "cannot find $TARGET"
command -v shasum >/dev/null 2>&1 || fail "shasum not available; cannot run test"

# --- Extract the real create_archive() function from the script -------------
# Pull lines from `create_archive() {` up to and including the first line that
# is a lone `}` at column 0 (the function's closing brace).
func_src="$(awk '/^create_archive\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$TARGET")"
[[ -n "$func_src" ]] || fail "could not extract create_archive() from $TARGET"
echo "$func_src" | grep -q 'sha256' || fail "extracted function lacks the sha256 block"

# --- Stub the dependencies create_archive() relies on -----------------------
log()           { :; }   # silence INFO/SUCCESS/ERROR logging
print_step()    { :; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Bring the real function into this shell.
eval "$func_src"

# --- Arrange a populated export dir under a RELATIVE EXPORT_DIR --------------
WORK="$(mktemp -d)"
trap 'cd /; rm -rf "$WORK"' EXIT
cd "$WORK" || fail "cannot cd into work dir"

EXPORT_DIR="./datadog-export"          # relative on purpose -> reproduces the bug
EXPORT_NAME="datadog-export-testts"
OUTPUT_DIR="$EXPORT_DIR/$EXPORT_NAME"
LOG_FILE="$OUTPUT_DIR/export.log"
mkdir -p "$OUTPUT_DIR"
: > "$LOG_FILE"
echo '{"hello":"world"}' > "$OUTPUT_DIR/data.json"

archive_path="$EXPORT_DIR/$EXPORT_NAME.tar.gz"
sha_path="$archive_path.sha256"

# --- Act --------------------------------------------------------------------
create_archive >/dev/null 2>&1 || fail "create_archive returned non-zero"

# Confirm the shell cwd was NOT changed as a side effect (root cause guard).
[[ "$(pwd)" == "$WORK" ]] || fail "create_archive changed the shell cwd to $(pwd)"

# --- Assert -----------------------------------------------------------------
[[ -f "$archive_path" ]] || fail "archive not created at $archive_path"
[[ -f "$sha_path" ]]     || fail "checksum sidecar NOT written at $sha_path (the bug)"

# The sidecar must reference the archive by basename and validate.
grep -q "  ${EXPORT_NAME}.tar.gz$" "$sha_path" \
    || fail "checksum file does not reference the archive basename: $(cat "$sha_path")"

# Operator's verification step: run from inside the output dir.
( cd "$EXPORT_DIR" && shasum -a 256 -c "$(basename "$sha_path")" ) >/dev/null 2>&1 \
    || fail "shasum -a 256 -c did not return OK"

# Negative check: corrupt the archive and confirm verification now fails.
echo "corruption" >> "$archive_path"
if ( cd "$EXPORT_DIR" && shasum -a 256 -c "$(basename "$sha_path")" ) >/dev/null 2>&1; then
    fail "checksum verification passed against a corrupted archive"
fi

echo "PASS: create_archive writes a valid .tar.gz.sha256 that verifies with 'shasum -a 256 -c'"
