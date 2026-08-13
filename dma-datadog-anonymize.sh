#!/bin/bash
# LINE ENDING FIX: Auto-detect and fix Windows CRLF line endings
# If you see "$'\r': command not found" errors, this block will auto-fix and re-run
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && grep -q $'\r' "$0" 2>/dev/null; then
    echo "Detected Windows line endings (CRLF). Converting to Unix (LF)..."
    sed -i.bak 's/\r$//' "$0" && rm -f "$0.bak"
    exec bash "$0" "$@"
fi

################################################################################
#
#  DMA DataDog Export Anonymizer v1.0.0
#
#  Pseudonymizes email addresses and user handles in a DataDog export archive
#  produced by dma-datadog-export.sh. Produces a new *_anonymized.tar.gz
#  archive that is safe to share with Dynatrace colleagues for migration
#  analysis — no customer PII remains.
#
#  Usage:
#    ./dma-datadog-anonymize.sh <archive.tar.gz | export-directory/> [--dry-run]
#
#  Pseudonymization method: SHA-256 of the original email (lowercase), first
#  8 hex characters.  Same email → same pseudonym across all runs and files.
#  No mapping table is stored; the transformation is not reversible from the
#  output alone.
#
#  Requirements: bash 3.2+, python3, tar, shasum (macOS) or sha256sum (Linux)
#
################################################################################

set -euo pipefail

# =============================================================================
# COLORS / LOGGING
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log() {
    local lvl=$1; shift
    case "$lvl" in
        INFO)    echo -e "${BLUE}  i $*${NC}" ;;
        SUCCESS) echo -e "${GREEN}  v $*${NC}" ;;
        WARNING) echo -e "${YELLOW}  ! $*${NC}" ;;
        ERROR)   echo -e "${RED}  x $*${NC}" >&2 ;;
    esac
}

print_header() {
    echo ""
    echo -e "${CYAN}$(printf '=%.0s' {1..80})${NC}"
    local pad=$(( (80 - ${#1}) / 2 ))
    printf "${CYAN}%*s${BOLD}%s${NC}\n" $pad "" "$1"
    echo -e "${CYAN}$(printf '=%.0s' {1..80})${NC}"
    echo ""
}

print_step() {
    echo ""
    echo -e "${BLUE}$(printf -- '-%.0s' {1..80})${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}$(printf -- '-%.0s' {1..80})${NC}"
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
    echo ""
    echo -e "${BOLD}DMA DataDog Export Anonymizer v1.0.0${NC}"
    echo ""
    echo "  Replaces email addresses and user handles in a DataDog export archive"
    echo "  (produced by dma-datadog-export.sh) with deterministic pseudonyms."
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 <archive.tar.gz | export-directory/> [--dry-run]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --dry-run   Report what would change without writing any files"
    echo "  --help      Show this help message"
    echo ""
    echo -e "${BOLD}Output:${NC}"
    echo "  archive input  →  <name>_anonymized.tar.gz + .sha256 sidecar"
    echo "  directory input →  <name>_anonymized/ directory"
    echo ""
}

# =============================================================================
# ARG PARSING
# =============================================================================

INPUT=""
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h) usage; exit 0 ;;
        -*)        echo "Unknown option: $arg"; usage; exit 1 ;;
        *)         INPUT="$arg" ;;
    esac
done

if [[ -z "$INPUT" ]]; then
    usage
    exit 1
fi

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

PYTHON3_CMD=""
if command -v python3 &>/dev/null; then
    PYTHON3_CMD="python3"
elif command -v python &>/dev/null && python --version 2>&1 | grep -q "Python 3"; then
    PYTHON3_CMD="python"
fi

if [[ -z "$PYTHON3_CMD" ]]; then
    log ERROR "python3 is required but was not found on PATH."
    log ERROR "Install Python 3.6+ and retry: https://www.python.org/downloads/"
    exit 1
fi

if ! command -v tar &>/dev/null; then
    log ERROR "tar is required but was not found on PATH."
    exit 1
fi

SHASUM_CMD=""
if command -v shasum &>/dev/null; then
    SHASUM_CMD="shasum -a 256"
elif command -v sha256sum &>/dev/null; then
    SHASUM_CMD="sha256sum"
else
    log WARNING "shasum / sha256sum not found — SHA-256 sidecar will be skipped."
fi

# =============================================================================
# RESOLVE INPUT → WORKING DIRECTORY
# =============================================================================

CLEANUP_TMPDIR=""

cleanup() {
    if [[ -n "$CLEANUP_TMPDIR" && -d "$CLEANUP_TMPDIR" ]]; then
        rm -rf "$CLEANUP_TMPDIR"
    fi
}
trap cleanup EXIT

INPUT_IS_ARCHIVE=false
WORK_EXPORT_DIR=""
OUTPUT_ARCHIVE=""
OUTPUT_NAME=""

if [[ "$INPUT" == *.tar.gz ]]; then
    if [[ ! -f "$INPUT" ]]; then
        log ERROR "Archive not found: $INPUT"
        exit 1
    fi
    INPUT_IS_ARCHIVE=true

    ARCHIVE_PARENT=$(cd "$(dirname "$INPUT")"; pwd)
    ARCHIVE_BASENAME=$(basename "$INPUT" .tar.gz)
    OUTPUT_NAME="${ARCHIVE_BASENAME}_anonymized"
    OUTPUT_ARCHIVE="${ARCHIVE_PARENT}/${OUTPUT_NAME}.tar.gz"

    print_step "Extracting Archive"
    CLEANUP_TMPDIR=$(mktemp -d)
    log INFO "Temp dir: $CLEANUP_TMPDIR"
    tar -xzf "$INPUT" -C "$CLEANUP_TMPDIR"

    # Find the single top-level directory produced by the export script
    EXPORT_DIR_NAME=$(ls "$CLEANUP_TMPDIR" | head -1)
    if [[ -z "$EXPORT_DIR_NAME" || ! -d "$CLEANUP_TMPDIR/$EXPORT_DIR_NAME" ]]; then
        log ERROR "Could not find an export directory inside the archive."
        exit 1
    fi
    log SUCCESS "Extracted: $EXPORT_DIR_NAME"

    # Rename to the anonymized name so the final archive contains the right dir
    mv "$CLEANUP_TMPDIR/$EXPORT_DIR_NAME" "$CLEANUP_TMPDIR/$OUTPUT_NAME"
    WORK_EXPORT_DIR="$CLEANUP_TMPDIR/$OUTPUT_NAME"

else
    if [[ ! -d "$INPUT" ]]; then
        log ERROR "Directory not found: $INPUT"
        exit 1
    fi

    INPUT_DIR="${INPUT%/}"
    INPUT_PARENT=$(cd "$(dirname "$INPUT_DIR")"; pwd)
    INPUT_BASENAME=$(basename "$INPUT_DIR")
    OUTPUT_NAME="${INPUT_BASENAME}_anonymized"
    WORK_EXPORT_DIR="${INPUT_PARENT}/${OUTPUT_NAME}"

    print_step "Copying Export Directory"
    if [[ -d "$WORK_EXPORT_DIR" ]]; then
        log WARNING "Output directory already exists and will be overwritten: $WORK_EXPORT_DIR"
        rm -rf "$WORK_EXPORT_DIR"
    fi
    cp -r "$INPUT_DIR" "$WORK_EXPORT_DIR"
    log SUCCESS "Copied to: $WORK_EXPORT_DIR"
fi

# =============================================================================
# ANONYMIZATION (Python 3)
# =============================================================================

print_step "Anonymizing PII"
[[ "$DRY_RUN" == "true" ]] && log WARNING "DRY RUN — no files will be written."

PY_SCRIPT=$(mktemp)
# The Python script is written to a temp file so bash variables are not
# expanded inside it (the heredoc uses single-quoted delimiter 'PYTHON_EOF').
cat > "$PY_SCRIPT" << 'PYTHON_EOF'
import sys, os, json, re, hashlib, datetime

EMAIL_RE = re.compile(
    r'[a-zA-Z0-9._%+\-]+@(?!anonymized\.example)[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}'
)

_count = [0]  # mutable counter (list avoids nonlocal in Py2-compatible syntax)


def tok(s):
    return hashlib.sha256(s.strip().lower().encode()).hexdigest()[:8]


def ae(s):
    if not s or 'anonymized.example' in s:
        return s
    _count[0] += 1
    return 'user-{}@anonymized.example'.format(tok(s))


def ah(s):
    return 'user-{}'.format(tok(s)) if s else s


def an(s):
    return 'User {}'.format(tok(s)) if s else s


def scrub(s):
    if not isinstance(s, str):
        return s
    def rep(m):
        _count[0] += 1
        return 'user-{}@anonymized.example'.format(tok(m.group(0)))
    return EMAIL_RE.sub(rep, s)


def transform_creator(obj):
    if not isinstance(obj, dict):
        return
    c = obj.get('creator')
    if not isinstance(c, dict):
        return
    if c.get('email'):
        c['email'] = ae(c['email'])
    if c.get('handle'):
        c['handle'] = ah(c['handle'])
    if c.get('name'):
        c['name'] = an(c['name'])


def process_file(path, rel, dry):
    parts = rel.replace('\\', '/').split('/')
    parent = parts[-2] if len(parts) >= 2 else ''
    name = parts[-1]

    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        return False

    changed = False

    if parent == 'users' and name == 'users.json':
        for item in (data.get('data') or []):
            a = item.get('attributes', {}) if isinstance(item, dict) else {}
            if isinstance(a, dict) and a.get('email'):
                a['email'] = ae(a['email'])
                if 'handle' in a:
                    a['handle'] = ah(a['handle'])
                if 'name' in a:
                    a['name'] = an(a['name'])
                changed = True

    elif parent == 'monitors':
        items = data if isinstance(data, list) else [data]
        for item in items:
            if not isinstance(item, dict):
                continue
            transform_creator(item)
            if 'message' in item:
                item['message'] = scrub(item['message'])
            changed = True

    elif parent == 'dashboards':
        if isinstance(data, dict):
            if data.get('author_handle'):
                data['author_handle'] = ah(data['author_handle'])
                changed = True
            if 'author_name' in data:
                data['author_name'] = an(data.get('author_name') or
                                         data.get('author_handle', ''))
                changed = True

    elif parent in ('slos', 'synthetics'):
        items = data if isinstance(data, list) else [data]
        for item in items:
            if isinstance(item, dict):
                transform_creator(item)
                changed = True

    elif parent == 'downtimes':
        items = data if isinstance(data, list) else [data]
        for item in items:
            if not isinstance(item, dict):
                continue
            for inc in (item.get('included') or []):
                if not isinstance(inc, dict):
                    continue
                a = inc.get('attributes', {})
                if isinstance(a, dict):
                    if a.get('email'):
                        a['email'] = ae(a['email'])
                    if a.get('handle'):
                        a['handle'] = ah(a['handle'])
                    changed = True

    elif parent == 'notebooks' and name == '_list.json':
        for item in (data.get('data') or []):
            if not isinstance(item, dict):
                continue
            attrs = item.get('attributes', {}) if isinstance(item, dict) else {}
            author = attrs.get('author', {}) if isinstance(attrs, dict) else {}
            if isinstance(author, dict):
                if author.get('email'):
                    author['email'] = ae(author['email'])
                if author.get('handle'):
                    author['handle'] = ah(author['handle'])
                changed = True

    elif parent == 'analytics':
        if name == 'dashboard_views.json' and isinstance(data, list):
            for item in data:
                if isinstance(item, dict) and isinstance(item.get('users'), list):
                    item['users'] = [ae(e) if isinstance(e, str) else e
                                     for e in item['users']]
                    changed = True
        elif name == 'monitor_modifications.json' and isinstance(data, list):
            for item in data:
                if isinstance(item, dict) and isinstance(item.get('modified_by'), list):
                    item['modified_by'] = [ae(e) if isinstance(e, str) else e
                                           for e in item['modified_by']]
                    changed = True

    if changed and not dry:
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
    return changed


def main():
    work_dir = sys.argv[1]
    dry = '--dry-run' in sys.argv

    files_n = 0
    for root, dirs, files in os.walk(work_dir):
        dirs[:] = sorted(d for d in dirs if not d.startswith('.'))
        for fn in sorted(files):
            if not fn.endswith('.json'):
                continue
            abs_p = os.path.join(root, fn)
            rel_p = os.path.relpath(abs_p, work_dir)
            if process_file(abs_p, rel_p, dry):
                files_n += 1

    # Patch manifest to record that data has been anonymized
    manifest_path = os.path.join(work_dir, 'manifest.json')
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path, encoding='utf-8') as f:
                manifest = json.load(f)
            manifest['anonymized'] = True
            manifest['anonymized_at'] = (
                datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
            )
            if not dry:
                with open(manifest_path, 'w', encoding='utf-8') as f:
                    json.dump(manifest, f, ensure_ascii=False, separators=(',', ':'))
        except Exception:
            pass

    print('files_processed={}'.format(files_n))
    print('emails_anonymized={}'.format(_count[0]))


main()
PYTHON_EOF

DRY_FLAG=""
[[ "$DRY_RUN" == "true" ]] && DRY_FLAG="--dry-run"

PYTHON_OUT=$($PYTHON3_CMD "$PY_SCRIPT" "$WORK_EXPORT_DIR" $DRY_FLAG)
rm -f "$PY_SCRIPT"

FILES_N=$(echo "$PYTHON_OUT" | grep 'files_processed=' | cut -d'=' -f2)
EMAILS_N=$(echo "$PYTHON_OUT" | grep 'emails_anonymized=' | cut -d'=' -f2)

log SUCCESS "Files with PII processed:  ${FILES_N:-0}"
log SUCCESS "Email addresses replaced:  ${EMAILS_N:-0}"

# =============================================================================
# RECREATE ARCHIVE
# =============================================================================

if [[ "$INPUT_IS_ARCHIVE" == "true" ]]; then
    print_step "Creating Anonymized Archive"

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[dry-run] Would create: $OUTPUT_ARCHIVE"
    else
        log INFO "Compressing: $(basename "$OUTPUT_ARCHIVE")"
        tar -czf "$OUTPUT_ARCHIVE" -C "$CLEANUP_TMPDIR" "$OUTPUT_NAME"
        ARCHIVE_SIZE=$(du -h "$OUTPUT_ARCHIVE" | cut -f1)
        log SUCCESS "Archive created: $(basename "$OUTPUT_ARCHIVE") ($ARCHIVE_SIZE)"

        if [[ -n "$SHASUM_CMD" ]]; then
            log INFO "Calculating SHA-256..."
            CHECKSUM=$($SHASUM_CMD "$OUTPUT_ARCHIVE" | cut -d' ' -f1)
            echo "$CHECKSUM  $(basename "$OUTPUT_ARCHIVE")" > "${OUTPUT_ARCHIVE}.sha256"
            log SUCCESS "Checksum: $CHECKSUM"
        fi
    fi
fi

# =============================================================================
# SUMMARY
# =============================================================================

print_header "Anonymization Complete"

if [[ "$INPUT_IS_ARCHIVE" == "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${CYAN}Output (dry-run):${NC} $OUTPUT_ARCHIVE"
    else
        echo -e "  ${CYAN}Output archive:${NC}   $OUTPUT_ARCHIVE"
        [[ -n "$SHASUM_CMD" ]] && echo -e "  ${CYAN}SHA-256 sidecar:${NC}  ${OUTPUT_ARCHIVE}.sha256"
    fi
else
    echo -e "  ${CYAN}Output directory:${NC} $WORK_EXPORT_DIR"
fi

echo -e "  ${CYAN}Files processed:${NC}  ${FILES_N:-0}"
echo -e "  ${CYAN}Emails replaced:${NC}  ${EMAILS_N:-0}"
echo ""
