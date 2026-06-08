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
#  DMA DataDog Export Script v2.0.1
#
#  REST API-Only Data Collection for DataDog to Dynatrace Migration
#
#  This script collects configurations, dashboards, alerts, monitors, SLOs,
#  synthetic tests, log pipelines, and other observability data from your
#  DataDog environment via REST API to enable migration planning and execution
#  using the DMA (Dynatrace Migration Assistant) application.
#
#  IMPORTANT: This script is for DataDog SaaS only. DataDog does not offer
#  self-hosted versions.
#
################################################################################
#
#  ╔═══════════════════════════════════════════════════════════════════════════╗
#  ║                    PRE-FLIGHT CHECKLIST (DATADOG)                         ║
#  ╠═══════════════════════════════════════════════════════════════════════════╣
#  ║                                                                           ║
#  ║  BEFORE RUNNING THIS SCRIPT, VERIFY THE FOLLOWING:                        ║
#  ║                                                                           ║
#  ║  □ 1. SYSTEM REQUIREMENTS (your local machine)                            ║
#  ║     □ bash 3.2+        Run: bash --version (works on macOS default bash) ║
#  ║     □ curl installed   Run: curl --version                                ║
#  ║     □ jq installed     Run: jq --version (for JSON processing)            ║
#  ║       └─ Install: brew install jq (macOS) or apt-get install jq (Linux)  ║
#  ║     □ tar installed    Run: tar --version                                 ║
#  ║     □ Internet access to DataDog API endpoints                            ║
#  ║                                                                           ║
#  ║  □ 2. DATADOG API CREDENTIALS                                             ║
#  ║     □ API Key (DD-API-KEY)                                                ║
#  ║       └─ Generate at: Organization Settings → API Keys → New Key          ║
#  ║       └─ Key value: ____________________                                  ║
#  ║     □ Application Key (DD-APPLICATION-KEY)                                ║
#  ║       └─ Generate at: Organization Settings → Application Keys → New Key  ║
#  ║       └─ Key value: ____________________                                  ║
#  ║                                                                           ║
#  ║  □ 3. DATADOG API REGION                                                  ║
#  ║     Choose your DataDog site (region):                                    ║
#  ║     □ US1 (default)    api.datadoghq.com                                  ║
#  ║     □ US3              api.us3.datadoghq.com                              ║
#  ║     □ US5              api.us5.datadoghq.com                              ║
#  ║     □ EU               api.datadoghq.eu                                   ║
#  ║     □ AP1              api.ap1.datadoghq.com                              ║
#  ║     □ Custom/Mock      (e.g., http://localhost:3000 for testing)         ║
#  ║                                                                           ║
#  ║  □ 4. REQUIRED APPLICATION KEY PERMISSIONS                                ║
#  ║     The Application Key needs these scopes:                               ║
#  ║     □ dashboards_read         - Read dashboard configurations             ║
#  ║     □ monitors_read           - Read monitor/alert configurations         ║
#  ║     □ logs_read_config        - Read log pipeline configurations          ║
#  ║     □ synthetics_read         - Read synthetic test configurations        ║
#  ║     □ slos_read               - Read SLO configurations                   ║
#  ║     □ metrics_read            - Read metric metadata                      ║
#  ║     □ user_access_read        - Read user and role configurations         ║
#  ║     □ org_management          - Read organization settings                ║
#  ║                                                                           ║
#  ║  □ 5. NETWORK CONNECTIVITY TEST                                           ║
#  ║     Run this command to verify connectivity:                              ║
#  ║                                                                           ║
#  ║     curl -s -o /dev/null -w "%{http_code}" \                              ║
#  ║       -H "DD-API-KEY: your-key" \                                         ║
#  ║       -H "DD-APPLICATION-KEY: your-app-key" \                             ║
#  ║       https://api.datadoghq.com/api/v1/validate                           ║
#  ║                                                                           ║
#  ║     Expected result: 200 (authenticated successfully)                     ║
#  ║     If you get: 403 - Check API keys and permissions                      ║
#  ║     If you get: 000 - Check network/firewall                              ║
#  ║                                                                           ║
#  ║  □ 6. DATADOG RATE LIMITS (be aware)                                      ║
#  ║     □ API calls are rate limited per endpoint                             ║
#  ║     □ Monitor rate limit headers: X-RateLimit-*                           ║
#  ║     □ Script includes automatic retry with exponential backoff            ║
#  ║     □ Large exports may take significant time                             ║
#  ║                                                                           ║
#  ║  □ 7. INFORMATION TO GATHER BEFOREHAND                                    ║
#  ║     □ DataDog Site/Region: ___________________                            ║
#  ║     □ API Key: ____________________________________                       ║
#  ║     □ Application Key: ____________________________                       ║
#  ║     □ Export destination directory: _______________                       ║
#  ║                                                                           ║
#  ╚═══════════════════════════════════════════════════════════════════════════╝
#
#  QUICK CONNECTIVITY TEST:
#    curl -H "DD-API-KEY: your-key" \
#         -H "DD-APPLICATION-KEY: your-app-key" \
#         https://api.datadoghq.com/api/v1/validate
#
#  NON-INTERACTIVE MODE (for automation):
#    ./dma-datadog-export.sh \
#      --api-key "your-api-key" \
#      --app-key "your-application-key" \
#      --site us1 \
#      --output /path/to/export
#
################################################################################

set -o pipefail  # Fail on pipe errors
# Note: We don't use set -e because we want to handle errors gracefully

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

SCRIPT_VERSION="2.0.1"
SCRIPT_NAME="DMA DataDog Export"

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'

# Box drawing characters
BOX_TL="╔"
BOX_TR="╗"
BOX_BL="╚"
BOX_BR="╝"
BOX_H="═"
BOX_V="║"
BOX_T="╠"
BOX_B="╣"

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# DataDog connection
DATADOG_API_KEY=""
DATADOG_APP_KEY=""
DATADOG_SITE="app"          # default: app (US1)
DATADOG_API_URL=""          # Will be set based on site
SITE_EXPLICITLY_SET=false
CUSTOM_API_URL=""           # For mock API testing

# Export settings
EXPORT_DIR=""
EXPORT_NAME=""
TIMESTAMP=""
LOG_FILE=""
OUTPUT_DIR=""

# Environment info
DATADOG_ORG_NAME=""
DATADOG_ORG_ID=""

# Feature flags
SKIP_DASHBOARDS=false
SKIP_MONITORS=false
SKIP_LOGS=false
SKIP_SYNTHETICS=false
SKIP_SLOS=false
SKIP_METRICS=false
SKIP_USERS=false
COLLECT_USAGE=false
TEST_ACCESS=false

# Concurrency for endpoints that must be fetched one item at a time.
# Tuned to each endpoint's measured x-ratelimit-limit; the concurrent fetcher
# additionally self-paces via X-RateLimit-Reset on 429, so these are safe
# upper bounds rather than hard throttles. Override via environment if needed.
DASHBOARD_CONCURRENCY="${DASHBOARD_CONCURRENCY:-10}"    # limit 600/60s  (10/s)
SYNTHETICS_CONCURRENCY="${SYNTHETICS_CONCURRENCY:-10}"  # limit 1450/60s (24/s)
LOGS_CONCURRENCY="${LOGS_CONCURRENCY:-5}"               # limit 420/60s  (7/s)

# Progress tracking
TOTAL_STEPS=0
CURRENT_STEP=0
START_TIME=""
ERRORS_ENCOUNTERED=0

# API Response tracking
TOTAL_API_CALLS=0
SUCCESSFUL_API_CALLS=0
FAILED_API_CALLS=0

# Silent failure tracking (200 OK but empty results)
declare -a EMPTY_RESULTS_WARNINGS=()
SUSPICIOUS_EMPTY_COUNT=0

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Print colored message
print_color() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

# Print header box
print_header() {
    local text="$1"
    local width=80
    local padding=$(( (width - ${#text} - 2) / 2 ))

    echo ""
    echo -e "${CYAN}${BOX_TL}$(printf '%*s' $width '' | tr ' ' "${BOX_H}")${BOX_TR}${NC}"
    printf "${CYAN}${BOX_V}${NC}%*s${BOLD}${WHITE}%s${NC}%*s${CYAN}${BOX_V}${NC}\n" \
           $padding "" "$text" $padding ""
    echo -e "${CYAN}${BOX_BL}$(printf '%*s' $width '' | tr ' ' "${BOX_H}")${BOX_BR}${NC}"
    echo ""
}

# Print step header
print_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local step_text="[$CURRENT_STEP/$TOTAL_STEPS] $1"
    echo ""
    echo -e "${BLUE}${BOX_T}$(printf '%*s' 78 '' | tr ' ' "${BOX_H}")${BOX_B}${NC}"
    echo -e "${BLUE}${BOX_V}${NC} ${BOLD}${step_text}${NC}"
    echo -e "${BLUE}${BOX_BL}$(printf '%*s' 78 '' | tr ' ' "${BOX_H}")${BOX_BR}${NC}"
}

# Log message to file and console
log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Write to log file (skipped when LOG_FILE is not yet set, e.g. during --test-access)
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi

    # Print to console with color
    case "$level" in
        INFO)
            print_color "$BLUE" "  ℹ $message"
            ;;
        SUCCESS)
            print_color "$GREEN" "  ✓ $message"
            ;;
        WARNING)
            print_color "$YELLOW" "  ⚠ $message"
            ;;
        ERROR)
            print_color "$RED" "  ✗ $message"
            ERRORS_ENCOUNTERED=$((ERRORS_ENCOUNTERED + 1))
            ;;
        DEBUG)
            if [[ -n "$DEBUG" ]]; then
                print_color "$GRAY" "  [DEBUG] $message"
            fi
            ;;
    esac
}

# Progress bar
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))

    printf "\r${CYAN}Progress: [${NC}"
    printf "%${filled}s" '' | tr ' ' '█'
    printf "%${empty}s" '' | tr ' ' '░'
    printf "${CYAN}] ${WHITE}%d%%${NC}" $percentage
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check required commands
check_requirements() {
    local missing_commands=()

    if ! command_exists curl; then
        missing_commands+=("curl")
    fi

    if ! command_exists jq; then
        missing_commands+=("jq")
    fi

    if ! command_exists tar; then
        missing_commands+=("tar")
    fi

    if [ ${#missing_commands[@]} -gt 0 ]; then
        log ERROR "Missing required commands: ${missing_commands[*]}"
        log ERROR "Install with: brew install ${missing_commands[*]} (macOS)"
        log ERROR "           or: apt-get install ${missing_commands[*]} (Linux)"
        return 1
    fi

    return 0
}

# =============================================================================
# DATADOG API FUNCTIONS
# =============================================================================

# Get DataDog API URL based on site
get_api_url() {
    if [[ -n "$CUSTOM_API_URL" ]]; then
        echo "$CUSTOM_API_URL"
        return
    fi

    local site="$DATADOG_SITE"

    # Short-code aliases (backwards compat)
    case "$site" in
        app|us1) site="datadoghq.com" ;;
        us3)     site="us3.datadoghq.com" ;;
        us5)     site="us5.datadoghq.com" ;;
        eu)      site="datadoghq.eu" ;;
        ap1)     site="ap1.datadoghq.com" ;;
    esac

    # If a full URL was passed, strip the protocol
    if [[ "$site" == *"://"* ]]; then
        site="${site#*://}"
        site="${site%/}"
    fi

    # If value contains a dot, it's a domain — strip 'app.' prefix and build API URL
    if [[ "$site" == *"."* ]]; then
        site="${site#app.}"
        echo "https://api.$site"
        return
    fi

    # Unknown short code — warn the user; dedicated orgs on US1 should use --site app
    print_color "$YELLOW" "WARNING: Unknown site identifier '${DATADOG_SITE}'. Known codes: app/us1, us3, us5, eu, ap1."
    print_color "$YELLOW" "WARNING: If this is a dedicated org on US1 infrastructure, use --site app instead. Use --custom-url to set an explicit API URL."
    echo "https://api.${site}.datadoghq.com"
}

# Track suspicious empty results (200 OK but 0 items - likely missing scope)
track_empty_result() {
    local resource_type="$1"
    local scope_name="$2"

    SUSPICIOUS_EMPTY_COUNT=$((SUSPICIOUS_EMPTY_COUNT + 1))
    EMPTY_RESULTS_WARNINGS+=("$resource_type|$scope_name")

    log WARNING "⚠️  Found 0 ${resource_type} (API returned 200 OK)"
    log WARNING "    This often means the Application Key is missing the '${scope_name}' scope"
    log WARNING "    Run with --test-access to validate all required scopes"
}

# Make authenticated API call to DataDog
dd_api_call() {
    local method="$1"
    local endpoint="$2"
    local output_file="$3"
    local retry_count=0
    local max_retries=3
    local retry_delay=5

    TOTAL_API_CALLS=$((TOTAL_API_CALLS + 1))

    local url="${DATADOG_API_URL}${endpoint}"

    log DEBUG "API Call: $method $url"

    while [ $retry_count -lt $max_retries ]; do
        local response=$(curl -s -w "\n%{http_code}" \
            -X "$method" \
            -H "DD-API-KEY: ${DATADOG_API_KEY}" \
            -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
            -H "Content-Type: application/json" \
            "$url" 2>&1)

        local http_code=$(echo "$response" | tail -n1)
        local body=$(echo "$response" | sed '$d')

        case "$http_code" in
            200|201)
                SUCCESSFUL_API_CALLS=$((SUCCESSFUL_API_CALLS + 1))
                if [[ -n "$output_file" ]]; then
                    echo "$body" > "$output_file"
                fi
                log DEBUG "API call successful: $http_code"
                return 0
                ;;
            429)
                # Rate limited
                retry_count=$((retry_count + 1))
                local wait_time=$((retry_delay * retry_count))
                log WARNING "Rate limited (429). Retry $retry_count/$max_retries after ${wait_time}s..."
                sleep $wait_time
                ;;
            401|403)
                FAILED_API_CALLS=$((FAILED_API_CALLS + 1))
                log ERROR "Authentication failed ($http_code) for: $endpoint"
                log DEBUG "Response: $body"
                return 1
                ;;
            404)
                FAILED_API_CALLS=$((FAILED_API_CALLS + 1))
                log WARNING "Not found (404): $endpoint"
                return 1
                ;;
            500|502|503|504)
                # Server error - retry
                retry_count=$((retry_count + 1))
                log WARNING "Server error ($http_code). Retry $retry_count/$max_retries..."
                sleep $retry_delay
                ;;
            *)
                FAILED_API_CALLS=$((FAILED_API_CALLS + 1))
                log ERROR "API call failed ($http_code) for: $endpoint"
                log DEBUG "Response: $body"
                return 1
                ;;
        esac
    done

    FAILED_API_CALLS=$((FAILED_API_CALLS + 1))
    log ERROR "API call failed after $max_retries retries: $endpoint"
    return 1
}

# ---------------------------------------------------------------------------
# Concurrent fetch-by-ID using curl --parallel.
#
# All requests are dispatched inside a SINGLE curl process — no bash subprocess
# forking, no temp header files per request, no process-table pressure.
# curl --parallel-max caps in-flight connections; --retry / --retry-delay handle
# transient 5xx automatically. 429 (rate-limit) is handled by a post-pass retry
# loop: any ID whose output file is missing or is a 429-body gets retried
# sequentially with a backoff derived from the response (or 10s default).
#
# Requirements: curl 7.66+ (ships with macOS Monterey+; verified 8.7.1 here).
#
#   $1 = max parallel connections (tuned per endpoint's x-ratelimit-limit)
#   $2 = URL path template containing the literal token __ID__
#   $3 = output file path template containing the literal token __ID__
#   stdin = newline-separated IDs
# ---------------------------------------------------------------------------
fetch_ids_concurrent() {
    local max_parallel="$1"
    local url_tmpl="$2"
    local out_tmpl="$3"

    [[ "$max_parallel" =~ ^[0-9]+$ ]] && [ "$max_parallel" -gt 0 ] || max_parallel=8

    # Collect IDs, skip blanks
    local ids=()
    while IFS= read -r id; do
        [ -z "${id//[[:space:]]/}" ] && continue
        ids+=("$id")
    done

    local total="${#ids[@]}"
    [ "$total" -eq 0 ] && return 0

    # Build a curl config file: one entry per ID separated by --next.
    # curl --parallel dispatches all entries concurrently inside a single process
    # (no forking, no extra bash subprocesses, no file-descriptor pressure).
    # 429 detection is done post-run by inspecting the output files.
    local cfg_file; cfg_file="$(mktemp)"
    local id url out first=1
    for id in "${ids[@]}"; do
        url="${DATADOG_API_URL}${url_tmpl//__ID__/$id}"
        out="${out_tmpl//__ID__/$id}"
        if [ "$first" = "1" ]; then
            first=0
        else
            printf -- '--next\n' >> "$cfg_file"
        fi
        printf -- '--url "%s"\n--output "%s"\n--header "DD-API-KEY: %s"\n--header "DD-APPLICATION-KEY: %s"\n--header "Content-Type: application/json"\n' \
            "$url" "$out" "${DATADOG_API_KEY}" "${DATADOG_APP_KEY}" >> "$cfg_file"
    done

    # First pass: fire all requests in parallel inside one curl process.
    curl -s --parallel --parallel-max "$max_parallel" --config "$cfg_file"
    rm -f "$cfg_file"

    # Retry pass: any output file that contains a 429 JSON body (or is absent)
    # means the item was rate-limited. Re-fetch sequentially with backoff.
    local retry_ids=() attempt
    for id in "${ids[@]}"; do
        out="${out_tmpl//__ID__/$id}"
        if [ ! -f "$out" ] || grep -q '"status":429\|"errors":\["Too many requests' "$out" 2>/dev/null; then
            retry_ids+=("$id")
            rm -f "$out"
        fi
    done

    if [ "${#retry_ids[@]}" -gt 0 ]; then
        log WARNING "  Rate-limited on ${#retry_ids[@]} items — retrying with backoff..."
        for id in "${retry_ids[@]}"; do
            url="${DATADOG_API_URL}${url_tmpl//__ID__/$id}"
            out="${out_tmpl//__ID__/$id}"
            attempt=0
            while [ "$attempt" -lt 5 ]; do
                local code; code="$(curl -s -o "$out" -w "%{http_code}" \
                    -H "DD-API-KEY: ${DATADOG_API_KEY}" \
                    -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
                    -H "Content-Type: application/json" \
                    "$url")"
                case "$code" in
                    200|201) break ;;
                    429) sleep $(( 10 + (RANDOM % 5) )); attempt=$((attempt+1)) ;;
                    5*) sleep $(( 3 + (RANDOM % 3) )); attempt=$((attempt+1)) ;;
                    *) rm -f "$out"; break ;;
                esac
            done
        done
    fi
}

# ---------------------------------------------------------------------------
# Save a single list/config endpoint to a file, degrading gracefully:
#   200/201 -> save body, log item count (best-effort)
#   401/403 -> WARN "missing scope" and skip (endpoint is real, key lacks scope)
#   404     -> INFO "not available" and skip
#   other   -> WARN and skip
# Never aborts the export. Used for the breadth of single-call resources.
#   $1 = human label   $2 = API path   $3 = absolute output file
# ---------------------------------------------------------------------------
export_simple_list() {
    local label="$1" endpoint="$2" out_file="$3"
    mkdir -p "$(dirname "$out_file")"
    local tmp hdr code
    tmp=$(mktemp); hdr=$(mktemp)
    code=$(curl -s -D "$hdr" -o "$tmp" -w "%{http_code}" \
        -H "DD-API-KEY: ${DATADOG_API_KEY}" \
        -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
        -H "Content-Type: application/json" \
        "${DATADOG_API_URL}${endpoint}")
    TOTAL_API_CALLS=$((TOTAL_API_CALLS + 1))
    case "$code" in
        200|201)
            SUCCESSFUL_API_CALLS=$((SUCCESSFUL_API_CALLS + 1))
            cp "$tmp" "$out_file"
            # Count only when the candidate path is genuinely an array — avoids
            # the `null|length == 0` trap that mislabels non-.data shapes as empty.
            local n=""
            for p in '.data' '.dashboard_lists' '.variables' '.locations' '.notebooks' '.tags' '.accounts' '.'; do
                n=$(jq -r "if (${p}|type)==\"array\" then (${p}|length) else empty end" "$tmp" 2>/dev/null)
                [[ "$n" =~ ^[0-9]+$ ]] && break || n=""
            done
            [ -z "$n" ] && n="?"
            if [ "$n" = "0" ]; then
                log INFO "  $label: 0 (accessible, empty)"
            else
                log SUCCESS "  $label: $n"
            fi
            ;;
        401|403) log WARNING "  $label: skipped — Application Key missing required scope (HTTP $code)" ;;
        404)     log INFO    "  $label: not available on this org (HTTP 404)" ;;
        *)       FAILED_API_CALLS=$((FAILED_API_CALLS + 1)); log WARNING "  $label: failed (HTTP $code)" ;;
    esac
    rm -f "$tmp" "$hdr"
}

# Export the full breadth of remaining single-call configuration resources.
# Each is best-effort: empty or scope-gated resources are noted and skipped so
# the same script exports them automatically wherever the data/scopes exist.
export_additional_resources() {
    print_step "Exporting Additional Resources"

    # label | API endpoint | output file (relative to OUTPUT_DIR)
    local rows=(
        # Visualization & content
        "Notebooks|/api/v1/notebooks|notebooks/_list.json"
        "Dashboard lists|/api/v1/dashboard/lists/manual|dashboards/lists.json"
        "Powerpacks|/api/v2/powerpacks|powerpacks/_list.json"
        # Monitoring extras
        "SLO corrections|/api/v1/slo/correction|slos/corrections.json"
        "Monitor config policies|/api/v2/monitor/policy|monitors/config_policies.json"
        # Logs (beyond pipelines/indexes)
        "Log archives|/api/v2/logs/config/archives|logs/archives.json"
        "Log metrics|/api/v2/logs/config/metrics|logs/metrics.json"
        "Log custom destinations|/api/v2/logs/config/custom-destinations|logs/custom_destinations.json"
        "Log restriction queries|/api/v2/logs/config/restriction_queries|logs/restriction_queries.json"
        # APM / spans / RUM
        "APM retention filters|/api/v2/apm/config/retention-filters|apm/retention_filters.json"
        "Spans metrics|/api/v2/apm/config/metrics|apm/spans_metrics.json"
        "RUM applications|/api/v2/rum/applications|rum/applications.json"
        # Synthetics extras
        "Synthetics global variables|/api/v1/synthetics/variables|synthetics/global_variables.json"
        "Synthetics private locations|/api/v1/synthetics/locations|synthetics/locations.json"
        # Security / catalog / reference
        "Security monitoring rules|/api/v2/security_monitoring/rules|security/monitoring_rules.json"
        "Service definitions (Software Catalog)|/api/v2/services/definitions|service_catalog/definitions.json"
        "Reference tables|/api/v2/reference-tables/tables|reference_tables/_list.json"
        "Incidents|/api/v2/incidents|incidents/_list.json"
        # Org / access
        "Authn mappings|/api/v2/authn_mappings|users/authn_mappings.json"
        # Integrations
        "AWS integration|/api/v1/integration/aws|integrations/aws.json"
        "Azure integration|/api/v1/integration/azure|integrations/azure.json"
        "GCP integration (legacy)|/api/v1/integration/gcp|integrations/gcp.json"
        "GCP integration (STS)|/api/v2/integration/gcp/accounts|integrations/gcp_sts.json"
        "PagerDuty integration|/api/v1/integration/pagerduty|integrations/pagerduty.json"
        # Infrastructure
        "Host tags|/api/v1/tags/hosts|infra/host_tags.json"
    )

    local row label endpoint out
    for row in "${rows[@]}"; do
        IFS='|' read -r label endpoint out <<< "$row"
        export_simple_list "$label" "$endpoint" "$OUTPUT_DIR/$out"
    done

    return 0
}

# Validate DataDog credentials
validate_credentials() {
    print_step "Validating DataDog API Credentials"

    log INFO "Testing connection to DataDog API..."
    log INFO "Site: $DATADOG_SITE"
    log INFO "API URL: $DATADOG_API_URL"

    # Try to validate the API key
    local temp_file=$(mktemp)
    if dd_api_call "GET" "/api/v1/validate" "$temp_file"; then
        log SUCCESS "API credentials validated successfully"

        # Try to get organization info
        if dd_api_call "GET" "/api/v1/org" "$temp_file"; then
            if command_exists jq; then
                DATADOG_ORG_NAME=$(jq -r '.org.name // "Unknown"' "$temp_file" 2>/dev/null)
                DATADOG_ORG_ID=$(jq -r '.org.id // "Unknown"' "$temp_file" 2>/dev/null)
                log INFO "Organization: $DATADOG_ORG_NAME"
                log INFO "Organization ID: $DATADOG_ORG_ID"
            fi
        fi

        rm -f "$temp_file"
        return 0
    else
        log ERROR "Failed to validate API credentials"
        log ERROR "Please check your API Key and Application Key"
        rm -f "$temp_file"
        return 1
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

# Export all dashboards
export_dashboards() {
    if [[ "$SKIP_DASHBOARDS" == "true" ]]; then
        log INFO "Skipping dashboards (--skip-dashboards flag)"
        return 0
    fi

    print_step "Exporting Dashboards"

    local dashboards_dir="$OUTPUT_DIR/dashboards"
    mkdir -p "$dashboards_dir"

    log INFO "Fetching dashboard list (paginated)..."
    local list_file="$dashboards_dir/_list.json"

    # Paginate dashboard list to avoid rate limits
    local page=0
    local page_size=5000  # Maximum supported by DataDog API
    local all_dashboards="[]"
    local total_fetched=0

    while true; do
        local temp_file=$(mktemp)
        local offset=$((page * page_size))

        if dd_api_call "GET" "/api/v1/dashboard?start=${offset}&count=${page_size}" "$temp_file"; then
            local batch=$(jq '.dashboards' "$temp_file" 2>/dev/null || echo "[]")
            local batch_count=$(echo "$batch" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$batch_count" -eq 0 ]]; then
                rm -f "$temp_file"
                break
            fi

            # Merge with existing results
            all_dashboards=$(jq -s '.[0] + .[1]' <(echo "$all_dashboards") <(echo "$batch"))
            total_fetched=$((total_fetched + batch_count))

            rm -f "$temp_file"
            page=$((page + 1))

            if [[ "$batch_count" -lt "$page_size" ]]; then
                break
            fi
        else
            log WARNING "Failed to fetch dashboards at offset $offset"
            rm -f "$temp_file"
            break
        fi
    done

    # Save complete list
    echo "{\"dashboards\": $all_dashboards}" > "$list_file"
    local count=$(echo "$all_dashboards" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        track_empty_result "dashboards" "dashboards_read"
    else
        log SUCCESS "Found $count dashboards"
    fi

    if [[ "$count" -gt 0 ]]; then
        # Dashboards MUST be fetched individually: the list response carries
        # only metadata (no `widgets`). Rate limit (measured): 600/60s = 10/s.
        # Fetch concurrently; the helper self-paces via X-RateLimit-Reset.
        local dashboard_ids=$(jq -r '.[]|.id' <(echo "$all_dashboards") 2>/dev/null)

        log INFO "Fetching $count dashboards concurrently (full widget definitions)..."
        echo "$dashboard_ids" | fetch_ids_concurrent "$DASHBOARD_CONCURRENCY" \
            "/api/v1/dashboard/__ID__" \
            "$dashboards_dir/dashboard-__ID__.json"

        local exported=$(ls "$dashboards_dir"/dashboard-*.json 2>/dev/null | wc -l | tr -d ' ')
        TOTAL_API_CALLS=$((TOTAL_API_CALLS + exported))
        SUCCESSFUL_API_CALLS=$((SUCCESSFUL_API_CALLS + exported))
        log SUCCESS "Exported $exported / $count dashboards"
    fi

    return 0
}

# Export all monitors/alerts
export_monitors() {
    if [[ "$SKIP_MONITORS" == "true" ]]; then
        log INFO "Skipping monitors (--skip-monitors flag)"
        return 0
    fi

    print_step "Exporting Monitors/Alerts"

    local monitors_dir="$OUTPUT_DIR/monitors"
    mkdir -p "$monitors_dir"

    log INFO "Fetching monitor list (paginated)..."
    local list_file="$monitors_dir/_list.json"

    # Paginate monitor list to avoid rate limits
    local page=0
    local page_size=5000  # Maximum supported by DataDog API
    local all_monitors="[]"
    local total_fetched=0

    while true; do
        local temp_file=$(mktemp)

        if dd_api_call "GET" "/api/v1/monitor?page=${page}&page_size=${page_size}" "$temp_file"; then
            local batch=$(cat "$temp_file" 2>/dev/null || echo "[]")
            local batch_count=$(echo "$batch" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$batch_count" -eq 0 ]]; then
                rm -f "$temp_file"
                break
            fi

            # Merge with existing results
            all_monitors=$(jq -s '.[0] + .[1]' <(echo "$all_monitors") <(echo "$batch"))
            total_fetched=$((total_fetched + batch_count))

            rm -f "$temp_file"
            page=$((page + 1))

            if [[ "$batch_count" -lt "$page_size" ]]; then
                break
            fi
        else
            log WARNING "Failed to fetch monitors at page $page"
            rm -f "$temp_file"
            break
        fi
    done

    # Save complete list
    echo "$all_monitors" > "$list_file"
    local count=$(echo "$all_monitors" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        track_empty_result "monitors" "monitors_read"
    else
        log SUCCESS "Found $count monitors"
    fi

    if [[ "$count" -gt 0 ]]; then
        # Save full list with all monitors
        log INFO "Saving complete monitor list..."

        # Extract individual monitors from the list (no need to re-fetch)
        # The list response already contains full monitor details
        log INFO "Extracting individual monitor files from list..."

        local current=0
        jq -c '.[]' "$list_file" 2>/dev/null | while IFS= read -r monitor_json; do
            current=$((current + 1))
            show_progress $current $count

            local monitor_id=$(echo "$monitor_json" | jq -r '.id')
            local output_file="$monitors_dir/monitor-${monitor_id}.json"
            echo "$monitor_json" | jq '.' > "$output_file"
        done

        echo ""  # New line after progress bar
        log SUCCESS "Exported $count monitors"
    fi

    return 0
}

# Export log pipelines and indexes
export_logs_config() {
    if [[ "$SKIP_LOGS" == "true" ]]; then
        log INFO "Skipping log configurations (--skip-logs flag)"
        return 0
    fi

    print_step "Exporting Log Configurations"

    local logs_dir="$OUTPUT_DIR/logs"
    mkdir -p "$logs_dir/pipelines"
    mkdir -p "$logs_dir/indexes"

    # Export log pipelines
    log INFO "Fetching log pipelines..."
    local pipelines_list="$logs_dir/pipelines/_list.json"

    if dd_api_call "GET" "/api/v1/logs/config/pipelines" "$pipelines_list"; then
        local count=$(jq '. | length' "$pipelines_list" 2>/dev/null || echo "0")

        if [[ "$count" -eq 0 ]]; then
            track_empty_result "log pipelines" "logs_read_config"
        else
            log SUCCESS "Found $count log pipelines"
        fi

        if [[ "$count" -gt 0 ]]; then
            # Pipelines fetched individually (measured limit 420/60s = 7/s).
            local pipeline_ids=$(jq -r '.[].id' "$pipelines_list" 2>/dev/null)

            log INFO "Fetching $count log pipelines concurrently..."
            echo "$pipeline_ids" | fetch_ids_concurrent "$LOGS_CONCURRENCY" \
                "/api/v1/logs/config/pipelines/__ID__" \
                "$logs_dir/pipelines/pipeline-__ID__.json"
            log SUCCESS "Exported $count log pipelines"
        fi
    else
        log WARNING "Failed to fetch log pipelines"
    fi

    # Export log indexes
    log INFO "Fetching log indexes..."
    local indexes_list="$logs_dir/indexes/_list.json"

    if dd_api_call "GET" "/api/v1/logs/config/indexes" "$indexes_list"; then
        local count=$(jq '.indexes | length' "$indexes_list" 2>/dev/null || echo "0")
        log SUCCESS "Found $count log indexes"

        if [[ "$count" -gt 0 ]]; then
            # Extract individual indexes
            local index_names=$(jq -r '.indexes[].name' "$indexes_list" 2>/dev/null)

            local current=0
            while IFS= read -r index_name; do
                current=$((current + 1))
                show_progress $current $count

                local safe_name=$(echo "$index_name" | tr '/' '_')
                local output_file="$logs_dir/indexes/index-${safe_name}.json"
                dd_api_call "GET" "/api/v1/logs/config/indexes/${index_name}" "$output_file" >/dev/null 2>&1

            done <<< "$index_names"
            echo ""
            log SUCCESS "Exported $count log indexes"
        fi
    else
        log WARNING "Failed to fetch log indexes"
    fi

    return 0
}

# Export synthetic tests
export_synthetics() {
    if [[ "$SKIP_SYNTHETICS" == "true" ]]; then
        log INFO "Skipping synthetic tests (--skip-synthetics flag)"
        return 0
    fi

    print_step "Exporting Synthetic Tests"

    local synthetics_dir="$OUTPUT_DIR/synthetics"
    mkdir -p "$synthetics_dir"

    log INFO "Fetching synthetic tests (paginated)..."
    local list_file="$synthetics_dir/_list.json"

    # Paginate synthetic tests
    local page=0
    local page_size=5000  # Maximum supported by DataDog API
    local all_tests="[]"

    while true; do
        local temp_file=$(mktemp)

        if dd_api_call "GET" "/api/v1/synthetics/tests?page=${page}&page_size=${page_size}" "$temp_file"; then
            local batch=$(jq '.tests' "$temp_file" 2>/dev/null || echo "[]")
            local batch_count=$(echo "$batch" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$batch_count" -eq 0 ]]; then
                rm -f "$temp_file"
                break
            fi

            all_tests=$(jq -s '.[0] + .[1]' <(echo "$all_tests") <(echo "$batch"))
            rm -f "$temp_file"
            page=$((page + 1))

            if [[ "$batch_count" -lt "$page_size" ]]; then
                break
            fi
        else
            log WARNING "Failed to fetch synthetic tests at page $page"
            rm -f "$temp_file"
            break
        fi
    done

    echo "{\"tests\": $all_tests}" > "$list_file"
    local count=$(echo "$all_tests" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        track_empty_result "synthetic tests" "synthetics_read"
    else
        log SUCCESS "Found $count synthetic tests"
    fi

    if [[ "$count" -gt 0 ]]; then
        # The synthetics LIST response already contains the full `config` for
        # API tests, so write every test straight from the list — no per-test
        # fetch needed for the 80%+ that are API tests.
        log INFO "Writing $count synthetic tests from list..."
        jq -c '.[]' <(echo "$all_tests") 2>/dev/null | while IFS= read -r t; do
            local pid=$(echo "$t" | jq -r '.public_id')
            echo "$t" | jq '.' > "$synthetics_dir/test-${pid}.json"
        done

        # Browser tests are the exception: their `steps` are NOT in the list
        # config and only come from /synthetics/tests/browser/{id}. Fetch those
        # concurrently (measured limit 1450/60s = 24/s) and overwrite the
        # list-derived file with the steps-included full object.
        local browser_ids=$(jq -r '.[] | select(.type=="browser") | .public_id' <(echo "$all_tests") 2>/dev/null)
        local browser_count=$(printf '%s\n' "$browser_ids" | grep -c '[^[:space:]]')

        if [[ "$browser_count" -gt 0 ]]; then
            log INFO "Fetching $browser_count browser tests with full steps (concurrent)..."
            echo "$browser_ids" | fetch_ids_concurrent "$SYNTHETICS_CONCURRENCY" \
                "/api/v1/synthetics/tests/browser/__ID__" \
                "$synthetics_dir/test-__ID__.json"
        fi

        log SUCCESS "Exported $count synthetic tests ($browser_count browser w/ full steps)"
    fi

    return 0
}

# Export SLOs
export_slos() {
    if [[ "$SKIP_SLOS" == "true" ]]; then
        log INFO "Skipping SLOs (--skip-slos flag)"
        return 0
    fi

    print_step "Exporting SLOs"

    local slos_dir="$OUTPUT_DIR/slos"
    mkdir -p "$slos_dir"

    log INFO "Fetching SLOs..."
    local list_file="$slos_dir/_list.json"

    # SLO API supports pagination
    local offset=0
    local limit=1000
    local all_slos="[]"

    while true; do
        local temp_file=$(mktemp)
        if dd_api_call "GET" "/api/v1/slo?offset=${offset}&limit=${limit}" "$temp_file"; then
            local batch_count=$(jq '.data | length' "$temp_file" 2>/dev/null || echo "0")

            if [[ "$batch_count" -eq 0 ]]; then
                break
            fi

            # Merge with existing results
            all_slos=$(jq -s '.[0] + .[1].data' <(echo "$all_slos") "$temp_file")

            offset=$((offset + limit))
            rm -f "$temp_file"

            if [[ "$batch_count" -lt "$limit" ]]; then
                break
            fi
        else
            log ERROR "Failed to fetch SLOs at offset $offset"
            rm -f "$temp_file"
            break
        fi
    done

    # Save complete list
    echo "{\"data\": $all_slos}" > "$list_file"
    local count=$(echo "$all_slos" | jq '. | length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        track_empty_result "SLOs" "slos_read"
    else
        log SUCCESS "Found $count SLOs"
    fi

    if [[ "$count" -gt 0 ]]; then
        # Extract individual SLOs
        local slo_ids=$(echo "$all_slos" | jq -r '.[].id' 2>/dev/null)

        local current=0
        while IFS= read -r slo_id; do
            current=$((current + 1))
            show_progress $current $count

            local output_file="$slos_dir/slo-${slo_id}.json"
            dd_api_call "GET" "/api/v1/slo/${slo_id}" "$output_file" >/dev/null 2>&1

        done <<< "$slo_ids"

        echo ""
        log SUCCESS "Exported $count SLOs"
    fi

    return 0
}

# Export downtimes
export_downtimes() {
    print_step "Exporting Downtimes"

    local downtimes_dir="$OUTPUT_DIR/downtimes"
    mkdir -p "$downtimes_dir"

    log INFO "Fetching downtimes (paginated)..."
    local list_file="$downtimes_dir/_list.json"

    # Paginate downtimes (v2 API uses page[limit] and page[offset])
    local offset=0
    local limit=1000  # Maximum supported by v2 API
    local all_downtimes="[]"

    while true; do
        local temp_file=$(mktemp)

        if dd_api_call "GET" "/api/v2/downtime?page%5Blimit%5D=${limit}&page%5Boffset%5D=${offset}" "$temp_file"; then
            local batch=$(jq '.data' "$temp_file" 2>/dev/null || echo "[]")
            local batch_count=$(echo "$batch" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$batch_count" -eq 0 ]]; then
                rm -f "$temp_file"
                break
            fi

            all_downtimes=$(jq -s '.[0] + .[1]' <(echo "$all_downtimes") <(echo "$batch"))
            rm -f "$temp_file"
            offset=$((offset + limit))

            if [[ "$batch_count" -lt "$limit" ]]; then
                break
            fi
        else
            log WARNING "Failed to fetch downtimes at offset $offset"
            rm -f "$temp_file"
            break
        fi
    done

    echo "{\"data\": $all_downtimes}" > "$list_file"
    local count=$(echo "$all_downtimes" | jq 'length' 2>/dev/null || echo "0")
    log SUCCESS "Found $count downtimes"

    if [[ "$count" -gt 0 ]]; then
        # The v2 downtime LIST response carries the full object (verified:
        # list .attributes == GET /downtime/{id} .attributes), so write each
        # downtime straight from the list — no per-ID fetch required.
        log INFO "Writing $count downtimes from list..."
        jq -c '.[]' <(echo "$all_downtimes") 2>/dev/null | while IFS= read -r dt; do
            local dtid=$(echo "$dt" | jq -r '.id')
            echo "$dt" | jq '.' > "$downtimes_dir/downtime-${dtid}.json"
        done
        log SUCCESS "Exported $count downtimes"
    fi

    return 0
}

# Export metrics metadata
export_metrics() {
    if [[ "$SKIP_METRICS" == "true" ]]; then
        log INFO "Skipping metrics (--skip-metrics flag)"
        return 0
    fi

    print_step "Exporting Metrics Metadata"

    local metrics_dir="$OUTPUT_DIR/metrics"
    mkdir -p "$metrics_dir"

    log INFO "Fetching active metrics list..."
    local list_file="$metrics_dir/_list.json"

    # DataDog requires a 'from' timestamp - use 24 hours ago for active metrics
    local from_ts=$(date -u -v-1d "+%s" 2>/dev/null || date -u -d "1 day ago" "+%s" 2>/dev/null)

    if dd_api_call "GET" "/api/v1/metrics?from=${from_ts}" "$list_file"; then
        local count=$(jq '.metrics | length' "$list_file" 2>/dev/null || echo "0")

        if [[ "$count" -eq 0 ]]; then
            track_empty_result "metrics" "metrics_read"
        else
            log SUCCESS "Found $count active metrics"
        fi

        # Note: Getting metadata for each metric would be very slow
        # So we just save the list
        log INFO "Metrics list saved (individual metadata export would be time-consuming)"
    else
        log WARNING "Failed to fetch metrics list"
    fi

    return 0
}

# Export webhooks
export_webhooks() {
    print_step "Exporting Webhook Integrations"

    local webhooks_dir="$OUTPUT_DIR/webhooks"
    mkdir -p "$webhooks_dir"

    log INFO "Fetching webhook configurations..."
    local list_file="$webhooks_dir/_list.json"

    if dd_api_call "GET" "/api/v1/integration/webhooks/configuration/webhooks" "$list_file"; then
        local count=$(jq '. | length' "$list_file" 2>/dev/null || echo "0")
        log SUCCESS "Found $count webhooks"

        if [[ "$count" -gt 0 ]]; then
            # Extract webhook names
            local webhook_names=$(jq -r '.[].name' "$list_file" 2>/dev/null)

            local current=0
            while IFS= read -r webhook_name; do
                current=$((current + 1))
                show_progress $current $count

                local safe_name=$(echo "$webhook_name" | tr '/' '_' | tr ' ' '-')
                local output_file="$webhooks_dir/webhook-${safe_name}.json"
                dd_api_call "GET" "/api/v1/integration/webhooks/configuration/webhooks/${webhook_name}" "$output_file" >/dev/null 2>&1

            done <<< "$webhook_names"

            echo ""
            log SUCCESS "Exported $count webhooks"
        fi
    else
        log WARNING "Failed to fetch webhooks"
    fi

    return 0
}

# Export users and teams
export_users_teams() {
    if [[ "$SKIP_USERS" == "true" ]]; then
        log INFO "Skipping users and teams (--skip-users flag)"
        return 0
    fi

    print_step "Exporting Users, Roles, and Teams"

    local users_dir="$OUTPUT_DIR/users"
    mkdir -p "$users_dir"

    # Export users (paginated)
    log INFO "Fetching users (paginated)..."
    local users_file="$users_dir/users.json"
    local page_number=0
    local page_size=1000  # Maximum supported by v2 API
    local all_users="[]"

    while true; do
        local temp_file=$(mktemp)
        if dd_api_call "GET" "/api/v2/users?page%5Bsize%5D=${page_size}&page%5Bnumber%5D=${page_number}" "$temp_file"; then
            local batch=$(jq '.data' "$temp_file" 2>/dev/null || echo "[]")
            local batch_count=$(echo "$batch" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$batch_count" -eq 0 ]]; then
                rm -f "$temp_file"
                break
            fi

            all_users=$(jq -s '.[0] + .[1]' <(echo "$all_users") <(echo "$batch"))
            rm -f "$temp_file"
            page_number=$((page_number + 1))

            if [[ "$batch_count" -lt "$page_size" ]]; then
                break
            fi
        else
            log WARNING "Failed to fetch users at page $page_number"
            rm -f "$temp_file"
            break
        fi
    done

    echo "{\"data\": $all_users}" > "$users_file"
    local count=$(echo "$all_users" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        track_empty_result "users" "user_access_read"
    else
        log SUCCESS "Exported $count users"
    fi

    # Export roles (paginated)
    log INFO "Fetching roles (paginated)..."
    local roles_file="$users_dir/roles.json"
    page_number=0
    local roles_page_size=100  # v2 roles API rejects page sizes above 100
    local all_roles="[]"

    while true; do
        local temp_file=$(mktemp)
        if dd_api_call "GET" "/api/v2/roles?page%5Bsize%5D=${roles_page_size}&page%5Bnumber%5D=${page_number}" "$temp_file"; then
            local batch=$(jq '.data' "$temp_file" 2>/dev/null || echo "[]")
            local batch_count=$(echo "$batch" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$batch_count" -eq 0 ]]; then
                rm -f "$temp_file"
                break
            fi

            all_roles=$(jq -s '.[0] + .[1]' <(echo "$all_roles") <(echo "$batch"))
            rm -f "$temp_file"
            page_number=$((page_number + 1))

            if [[ "$batch_count" -lt "$page_size" ]]; then
                break
            fi
        else
            log WARNING "Failed to fetch roles at page $page_number"
            rm -f "$temp_file"
            break
        fi
    done

    echo "{\"data\": $all_roles}" > "$roles_file"
    local count=$(echo "$all_roles" | jq 'length' 2>/dev/null || echo "0")
    log SUCCESS "Exported $count roles"

    # Export teams (paginated)
    log INFO "Fetching teams (paginated)..."
    local teams_file="$users_dir/teams.json"
    page_number=0
    local all_teams="[]"

    while true; do
        local temp_file=$(mktemp)
        if dd_api_call "GET" "/api/v2/team?page%5Bsize%5D=${page_size}&page%5Bnumber%5D=${page_number}" "$temp_file"; then
            local batch=$(jq '.data' "$temp_file" 2>/dev/null || echo "[]")
            local batch_count=$(echo "$batch" | jq 'length' 2>/dev/null || echo "0")

            if [[ "$batch_count" -eq 0 ]]; then
                rm -f "$temp_file"
                break
            fi

            all_teams=$(jq -s '.[0] + .[1]' <(echo "$all_teams") <(echo "$batch"))
            rm -f "$temp_file"
            page_number=$((page_number + 1))

            if [[ "$batch_count" -lt "$page_size" ]]; then
                break
            fi
        else
            log WARNING "Failed to fetch teams at page $page_number"
            rm -f "$temp_file"
            break
        fi
    done

    echo "{\"data\": $all_teams}" > "$teams_file"
    local count=$(echo "$all_teams" | jq 'length' 2>/dev/null || echo "0")
    log SUCCESS "Exported $count teams"

    return 0
}

# =============================================================================
# USAGE ANALYTICS (Audit Trail + Usage Metering)
# =============================================================================
# Collects usage intelligence about DataDog assets:
#   1. Dashboard views    — who viewed which dashboards, how often
#   2. Monitor triggers   — which monitors fired, how often
#   3. Log index volume   — per-index daily event counts
#   4. Monitor activity   — which monitors were recently modified/created
#   5. Unused dashboards  — dashboards with zero views in the usage period
#   6. Unused monitors    — monitors that never triggered in the usage period
#   7. Unified            — all of the above in one pass (optional)
#
# Requires: audit_trail_read + usage_read permissions on the Application Key.
# Controlled by: --usage / --skip-usage flags. Default: skip.
# =============================================================================

USAGE_PERIOD="${USAGE_PERIOD:-90d}"

# Parse usage period into ISO 8601 timestamps
get_usage_from_timestamp() {
    local period="$USAGE_PERIOD"
    local days=90
    if [[ "$period" =~ ^([0-9]+)d$ ]]; then
        days="${BASH_REMATCH[1]}"
    fi
    # Cross-platform date arithmetic
    if date -v -1d >/dev/null 2>&1; then
        # macOS (BSD date)
        date -v "-${days}d" -u '+%Y-%m-%dT00:00:00Z'
    else
        # Linux (GNU date)
        date -u -d "${days} days ago" '+%Y-%m-%dT00:00:00Z'
    fi
}

get_usage_to_timestamp() {
    date -u '+%Y-%m-%dT23:59:59Z'
}

# Paginate through Audit Trail events and collect all results
# Usage: audit_trail_query <filter_query> <output_file>
audit_trail_query() {
    local filter_query="$1"
    local output_file="$2"
    local from_ts=$(get_usage_from_timestamp)
    local to_ts=$(get_usage_to_timestamp)
    local page_limit=1000
    local all_events="[]"
    local cursor=""
    local page=0
    local max_pages=20

    log DEBUG "Audit Trail query: $filter_query (from=$from_ts, to=$to_ts)"

    while [ $page -lt $max_pages ]; do
        local endpoint="/api/v2/audit/events?filter%5Bquery%5D=$(jq -rn --arg q "$filter_query" '$q | @uri')&filter%5Bfrom%5D=${from_ts}&filter%5Bto%5D=${to_ts}&page%5Blimit%5D=${page_limit}"
        if [[ -n "$cursor" ]]; then
            endpoint="${endpoint}&page%5Bcursor%5D=${cursor}"
        fi

        local temp_file=$(mktemp)
        if dd_api_call "GET" "$endpoint" "$temp_file"; then
            local page_events=$(jq -r '.data // [] | length' "$temp_file" 2>/dev/null)
            if [[ "$page_events" == "0" ]] || [[ -z "$page_events" ]]; then
                rm -f "$temp_file"
                break
            fi

            # Merge page events into all_events
            all_events=$(echo "$all_events" | jq --slurpfile page <(jq '.data // []' "$temp_file") '. + $page[0]')

            # Get next page cursor
            cursor=$(jq -r '.meta.page.after // empty' "$temp_file" 2>/dev/null)
            rm -f "$temp_file"

            page=$((page + 1))
            log DEBUG "  Page $page: $page_events events (total so far: $(echo "$all_events" | jq 'length'))"

            if [[ -z "$cursor" ]] || [[ "$cursor" == "null" ]]; then
                break
            fi
        else
            rm -f "$temp_file"
            log WARNING "Audit Trail query failed on page $page"
            break
        fi
    done

    echo "$all_events" > "$output_file"
    local total=$(jq 'length' "$output_file" 2>/dev/null)
    log DEBUG "Audit Trail collected $total events"
}

# ── Query 1: Dashboard Views ─────────────────────────────────────────────────
collect_dashboard_views() {
    log INFO "Collecting dashboard view analytics..."
    local raw_file=$(mktemp)
    local fails_before=$FAILED_API_CALLS
    audit_trail_query "@evt.name:\"Dashboard Viewed\"" "$raw_file"
    if [[ $(jq 'length' "$raw_file" 2>/dev/null) == "0" ]] && [[ $FAILED_API_CALLS -gt $fails_before ]]; then
        log WARNING "Dashboard views: 0 results — Audit Trail API call failed. Ensure your Application Key has the 'audit_trail_read' scope in DataDog (Organization Settings → API Keys → Application Keys)."
    fi

    # Aggregate: per-dashboard view count, unique users, last viewed
    jq '[group_by(.attributes.asset.id) | .[] | {
        dashboard_id: .[0].attributes.asset.id,
        dashboard_name: .[0].attributes.asset.name,
        view_count: length,
        unique_users: ([.[].attributes.usr.email] | unique | length),
        last_viewed: (sort_by(.attributes.timestamp) | last | .attributes.timestamp),
        users: ([.[].attributes.usr.email] | unique)
    }] | sort_by(-.view_count)' "$raw_file" > "$OUTPUT_DIR/analytics/dashboard_views.json" 2>/dev/null

    local count=$(jq 'length' "$OUTPUT_DIR/analytics/dashboard_views.json" 2>/dev/null)
    log SUCCESS "Dashboard views: $count dashboards with activity"
    rm -f "$raw_file"
}

# ── Query 2: Monitor Triggers ────────────────────────────────────────────────
collect_monitor_triggers() {
    log INFO "Collecting monitor trigger analytics..."
    local raw_file=$(mktemp)
    local fails_before=$FAILED_API_CALLS
    audit_trail_query "@asset.type:monitor @evt.name:(\"Monitor Alert Triggered\" OR \"Monitor Resolved\")" "$raw_file"
    if [[ $(jq 'length' "$raw_file" 2>/dev/null) == "0" ]] && [[ $FAILED_API_CALLS -gt $fails_before ]]; then
        log WARNING "Monitor triggers: 0 results — Audit Trail API call failed. Ensure your Application Key has the 'audit_trail_read' scope in DataDog (Organization Settings → API Keys → Application Keys)."
    fi

    jq '[group_by(.attributes.asset.id) | .[] | {
        monitor_id: .[0].attributes.asset.id,
        monitor_name: .[0].attributes.asset.name,
        trigger_count: [.[] | select(.attributes.evt.name == "Monitor Alert Triggered")] | length,
        resolve_count: [.[] | select(.attributes.evt.name == "Monitor Resolved")] | length,
        total_events: length,
        last_triggered: (sort_by(.attributes.timestamp) | last | .attributes.timestamp)
    }] | sort_by(-.trigger_count)' "$raw_file" > "$OUTPUT_DIR/analytics/monitor_triggers.json" 2>/dev/null

    local count=$(jq 'length' "$OUTPUT_DIR/analytics/monitor_triggers.json" 2>/dev/null)
    log SUCCESS "Monitor triggers: $count monitors with activity"
    rm -f "$raw_file"
}

# ── Query 3: Log Index Volume ────────────────────────────────────────────────
collect_log_index_volume() {
    log INFO "Collecting log index volume analytics..."
    # DataDog Usage Metering API allows at most ~1 month per request; paginate monthly.
    local from_date to_date
    from_date=$(get_usage_from_timestamp | cut -c1-10)
    to_date=$(get_usage_to_timestamp   | cut -c1-10)
    local outfile="$OUTPUT_DIR/analytics/log_index_volume.json"

    local entries_file=$(mktemp)
    echo '[]' > "$entries_file"
    local any_data=false

    local current="$from_date"
    while [[ "$current" < "$to_date" ]] || [[ "$current" == "$to_date" ]]; do
        # Compute end of this monthly window
        local window_end
        if date -v -1d >/dev/null 2>&1; then
            # macOS BSD date
            window_end=$(date -j -f '%Y-%m-%d' "$current" -v +1m -v -1d '+%Y-%m-%d' 2>/dev/null)
        else
            # GNU date (Linux)
            window_end=$(date -u -d "$current +1 month -1 day" '+%Y-%m-%d' 2>/dev/null)
        fi
        [[ "$window_end" > "$to_date" ]] && window_end="$to_date"

        local temp_file=$(mktemp)
        if dd_api_call "GET" \
            "/api/v1/usage/logs_by_index?start_hr=${current}T00&end_hr=${window_end}T23" \
            "$temp_file"; then
            any_data=true
            # Flatten all per-day by_index entries from this window
            local page_entries
            page_entries=$(jq '[.usage // [] | .[] | (.by_index // []) | .[] |
                {index_name, event_count: (.event_count // 0), retention_event_count: (.retention_event_count // 0)}]' \
                "$temp_file" 2>/dev/null)
            # Append to running list
            jq -n --slurpfile a "$entries_file" --argjson b "$page_entries" '$a[0] + $b' \
                > "${entries_file}.tmp" && mv "${entries_file}.tmp" "$entries_file"
        fi
        rm -f "$temp_file"

        [[ "$window_end" == "$to_date" ]] && break
        if date -v -1d >/dev/null 2>&1; then
            current=$(date -j -f '%Y-%m-%d' "$current" -v +1m '+%Y-%m-%d' 2>/dev/null)
        else
            current=$(date -u -d "$current +1 month" '+%Y-%m-%d' 2>/dev/null)
        fi
        [[ "$current" > "$to_date" ]] && break
    done

    if [[ "$any_data" == "true" ]]; then
        jq -n \
            --arg from "$from_date" --arg to "$to_date" \
            --slurpfile e "$entries_file" \
            '{
                period: {from: $from, to: $to},
                indexes: [$e[0] | group_by(.index_name) | .[] | {
                    index_name: .[0].index_name,
                    total_event_count:            ([.[].event_count]            | add),
                    total_retention_event_count:  ([.[].retention_event_count]  | add),
                    days_active: length
                }] | sort_by(-.total_event_count)
            }' > "$outfile"
        local count
        count=$(jq '.indexes | length' "$outfile" 2>/dev/null)
        log SUCCESS "Log index volume: $count indexes with usage data"
    else
        echo '{"indexes": [], "error": "Usage Metering API not available"}' > "$outfile"
        log WARNING "Log index volume: no data returned — check that your Application Key has the 'usage_read' scope"
    fi
    rm -f "$entries_file"
}

# ── Query 4: Monitor Modifications ───────────────────────────────────────────
collect_monitor_modifications() {
    log INFO "Collecting monitor modification analytics..."
    local raw_file=$(mktemp)
    local fails_before=$FAILED_API_CALLS
    audit_trail_query "@asset.type:monitor @evt.name:(\"Monitor Created\" OR \"Monitor Modified\")" "$raw_file"
    if [[ $(jq 'length' "$raw_file" 2>/dev/null) == "0" ]] && [[ $FAILED_API_CALLS -gt $fails_before ]]; then
        log WARNING "Monitor modifications: 0 results — Audit Trail API call failed. Ensure your Application Key has the 'audit_trail_read' scope in DataDog (Organization Settings → API Keys → Application Keys)."
    fi

    jq '[group_by(.attributes.asset.id) | .[] | {
        monitor_id: .[0].attributes.asset.id,
        monitor_name: .[0].attributes.asset.name,
        modification_count: length,
        created_events: [.[] | select(.attributes.evt.name == "Monitor Created")] | length,
        modified_events: [.[] | select(.attributes.evt.name == "Monitor Modified")] | length,
        last_modified: (sort_by(.attributes.timestamp) | last | .attributes.timestamp),
        modified_by: ([.[].attributes.usr.email] | unique)
    }] | sort_by(-.modification_count)' "$raw_file" > "$OUTPUT_DIR/analytics/monitor_modifications.json" 2>/dev/null

    local count=$(jq 'length' "$OUTPUT_DIR/analytics/monitor_modifications.json" 2>/dev/null)
    log SUCCESS "Monitor modifications: $count monitors with changes"
    rm -f "$raw_file"
}

# ── Query 5: Unused Dashboards ───────────────────────────────────────────────
collect_unused_dashboards() {
    log INFO "Identifying unused dashboards..."

    # Get all dashboard IDs from the export
    local all_dashboards=$(find "$OUTPUT_DIR/dashboards" -name "dashboard-*.json" -exec jq -r '.id' {} \; 2>/dev/null | sort)
    local total_dashboards=$(echo "$all_dashboards" | grep -c . || echo 0)

    if [[ $total_dashboards -eq 0 ]]; then
        if [[ "$SKIP_DASHBOARDS" == "true" ]]; then
            log INFO "Skipping unused-dashboard cross-reference (--skip-dashboards was set)"
        else
            log WARNING "No dashboard files found in export — dashboards may not have been exported in this run"
        fi
        echo '{"unused_dashboards": [], "total_dashboards": 0, "unused_count": 0}' > "$OUTPUT_DIR/analytics/unused_dashboards.json"
        return
    fi

    # Get viewed dashboard IDs from the views analytics
    local viewed_ids=""
    if [[ -f "$OUTPUT_DIR/analytics/dashboard_views.json" ]]; then
        viewed_ids=$(jq -r '.[].dashboard_id // empty' "$OUTPUT_DIR/analytics/dashboard_views.json" 2>/dev/null | sort)
    fi

    # Find dashboards with zero views
    local unused=$(comm -23 <(echo "$all_dashboards") <(echo "$viewed_ids"))
    local unused_count=$(echo "$unused" | grep -c . || echo 0)

    # Build JSON output with dashboard names
    local unused_json="[]"
    while IFS= read -r dash_id; do
        [[ -z "$dash_id" ]] && continue
        local dash_file="$OUTPUT_DIR/dashboards/dashboard-${dash_id}.json"
        local dash_name=""
        if [[ -f "$dash_file" ]]; then
            dash_name=$(jq -r '.title // "Unknown"' "$dash_file" 2>/dev/null)
        fi
        unused_json=$(echo "$unused_json" | jq --arg id "$dash_id" --arg name "$dash_name" '. + [{"dashboard_id": $id, "title": $name}]')
    done <<< "$unused"

    jq -n --argjson unused "$unused_json" --arg total "$total_dashboards" --arg count "$unused_count" '{
        unused_dashboards: $unused,
        total_dashboards: ($total | tonumber),
        viewed_count: (($total | tonumber) - ($count | tonumber)),
        unused_count: ($count | tonumber),
        usage_period: "'"$USAGE_PERIOD"'"
    }' > "$OUTPUT_DIR/analytics/unused_dashboards.json"

    log SUCCESS "Unused dashboards: $unused_count of $total_dashboards never viewed in $USAGE_PERIOD"
}

# ── Query 6: Unused Monitors ────────────────────────────────────────────────
collect_unused_monitors() {
    log INFO "Identifying unused monitors..."

    local all_monitors=$(find "$OUTPUT_DIR/monitors" -name "monitor-*.json" -exec jq -r '.id | tostring' {} \; 2>/dev/null | sort)
    local total_monitors=$(echo "$all_monitors" | grep -c . || echo 0)

    if [[ $total_monitors -eq 0 ]]; then
        if [[ "$SKIP_MONITORS" == "true" ]]; then
            log INFO "Skipping unused-monitor cross-reference (--skip-monitors was set)"
        else
            log WARNING "No monitor files found in export — monitors may not have been exported in this run"
        fi
        echo '{"unused_monitors": [], "total_monitors": 0, "unused_count": 0}' > "$OUTPUT_DIR/analytics/unused_monitors.json"
        return
    fi

    local triggered_ids=""
    if [[ -f "$OUTPUT_DIR/analytics/monitor_triggers.json" ]]; then
        triggered_ids=$(jq -r '.[].monitor_id // empty' "$OUTPUT_DIR/analytics/monitor_triggers.json" 2>/dev/null | sort)
    fi

    local unused=$(comm -23 <(echo "$all_monitors") <(echo "$triggered_ids"))
    local unused_count=$(echo "$unused" | grep -c . || echo 0)

    local unused_json="[]"
    while IFS= read -r mon_id; do
        [[ -z "$mon_id" ]] && continue
        local mon_file="$OUTPUT_DIR/monitors/monitor-${mon_id}.json"
        local mon_name=""
        if [[ -f "$mon_file" ]]; then
            mon_name=$(jq -r '.name // "Unknown"' "$mon_file" 2>/dev/null)
        fi
        unused_json=$(echo "$unused_json" | jq --arg id "$mon_id" --arg name "$mon_name" '. + [{"monitor_id": $id, "name": $name}]')
    done <<< "$unused"

    jq -n --argjson unused "$unused_json" --arg total "$total_monitors" --arg count "$unused_count" '{
        unused_monitors: $unused,
        total_monitors: ($total | tonumber),
        triggered_count: (($total | tonumber) - ($count | tonumber)),
        unused_count: ($count | tonumber),
        usage_period: "'"$USAGE_PERIOD"'"
    }' > "$OUTPUT_DIR/analytics/unused_monitors.json"

    log SUCCESS "Unused monitors: $unused_count of $total_monitors never triggered in $USAGE_PERIOD"
}

# ── Orchestrator: collect all usage analytics ────────────────────────────────
collect_usage_analytics() {
    if [[ "$COLLECT_USAGE" != "true" ]]; then
        return 0
    fi

    print_step "Collecting Usage Analytics"
    log INFO "Usage period: $USAGE_PERIOD"
    log INFO "APIs used: Audit Trail (v2), Usage Metering (v1)"

    mkdir -p "$OUTPUT_DIR/analytics"

    collect_dashboard_views
    collect_monitor_triggers
    collect_log_index_volume
    collect_monitor_modifications
    collect_unused_dashboards
    collect_unused_monitors

    # Write analytics summary
    jq -n \
        --arg period "$USAGE_PERIOD" \
        --arg from "$(get_usage_from_timestamp)" \
        --arg to "$(get_usage_to_timestamp)" \
        --argjson dv "$(jq 'length' "$OUTPUT_DIR/analytics/dashboard_views.json" 2>/dev/null || echo 0)" \
        --argjson mt "$(jq 'length' "$OUTPUT_DIR/analytics/monitor_triggers.json" 2>/dev/null || echo 0)" \
        --argjson iv "$(jq '.indexes | length' "$OUTPUT_DIR/analytics/log_index_volume.json" 2>/dev/null || echo 0)" \
        --argjson mm "$(jq 'length' "$OUTPUT_DIR/analytics/monitor_modifications.json" 2>/dev/null || echo 0)" \
        --argjson ud "$(jq '.unused_count' "$OUTPUT_DIR/analytics/unused_dashboards.json" 2>/dev/null || echo 0)" \
        --argjson um "$(jq '.unused_count' "$OUTPUT_DIR/analytics/unused_monitors.json" 2>/dev/null || echo 0)" \
        '{
            usage_period: $period,
            from: $from,
            to: $to,
            queries: {
                dashboard_views: { dashboards_with_views: $dv },
                monitor_triggers: { monitors_with_triggers: $mt },
                log_index_volume: { indexes_with_data: $iv },
                monitor_modifications: { monitors_modified: $mm },
                unused_dashboards: { count: $ud },
                unused_monitors: { count: $um }
            }
        }' > "$OUTPUT_DIR/analytics/_summary.json"

    log SUCCESS "Usage analytics complete — results in analytics/"
}

# =============================================================================
# MANIFEST GENERATION
# =============================================================================

generate_manifest() {
    print_step "Generating Export Manifest"

    local manifest_file="$OUTPUT_DIR/manifest.json"
    local end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local duration=$(($(date +%s) - $(date -d "$START_TIME" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "$START_TIME" +%s)))

    log INFO "Creating manifest file..."

    # Count exported items
    local dashboard_count=$(find "$OUTPUT_DIR/dashboards" -name "dashboard-*.json" 2>/dev/null | wc -l | tr -d ' ')
    local monitor_count=$(find "$OUTPUT_DIR/monitors" -name "monitor-*.json" 2>/dev/null | wc -l | tr -d ' ')
    local pipeline_count=$(find "$OUTPUT_DIR/logs/pipelines" -name "pipeline-*.json" 2>/dev/null | wc -l | tr -d ' ')
    local index_count=$(find "$OUTPUT_DIR/logs/indexes" -name "index-*.json" 2>/dev/null | wc -l | tr -d ' ')
    local synthetic_count=$(find "$OUTPUT_DIR/synthetics" -name "test-*.json" 2>/dev/null | wc -l | tr -d ' ')
    local slo_count=$(find "$OUTPUT_DIR/slos" -name "slo-*.json" 2>/dev/null | wc -l | tr -d ' ')
    local downtime_count=$(find "$OUTPUT_DIR/downtimes" -name "downtime-*.json" 2>/dev/null | wc -l | tr -d ' ')
    local webhook_count=$(find "$OUTPUT_DIR/webhooks" -name "webhook-*.json" 2>/dev/null | wc -l | tr -d ' ')

    cat > "$manifest_file" <<EOF
{
  "export_info": {
    "script_name": "$SCRIPT_NAME",
    "script_version": "$SCRIPT_VERSION",
    "export_name": "$EXPORT_NAME",
    "export_timestamp": "$TIMESTAMP",
    "start_time": "$START_TIME",
    "end_time": "$end_time",
    "duration_seconds": $duration
  },
  "datadog_info": {
    "site": "$DATADOG_SITE",
    "api_url": "$DATADOG_API_URL",
    "organization_name": "$DATADOG_ORG_NAME",
    "organization_id": "$DATADOG_ORG_ID"
  },
  "export_statistics": {
    "total_api_calls": $TOTAL_API_CALLS,
    "successful_api_calls": $SUCCESSFUL_API_CALLS,
    "failed_api_calls": $FAILED_API_CALLS,
    "errors_encountered": $ERRORS_ENCOUNTERED
  },
  "exported_items": {
    "dashboards": $dashboard_count,
    "monitors": $monitor_count,
    "log_pipelines": $pipeline_count,
    "log_indexes": $index_count,
    "synthetic_tests": $synthetic_count,
    "slos": $slo_count,
    "downtimes": $downtime_count,
    "webhooks": $webhook_count
  },
  "directories": {
    "dashboards": "dashboards/",
    "monitors": "monitors/",
    "logs": "logs/",
    "synthetics": "synthetics/",
    "slos": "slos/",
    "downtimes": "downtimes/",
    "metrics": "metrics/",
    "webhooks": "webhooks/",
    "users": "users/"
  }
}
EOF

    log SUCCESS "Manifest created: manifest.json"

    # Display summary
    echo ""
    print_color "$CYAN" "${BOX_TL}$(printf '%*s' 78 '' | tr ' ' "${BOX_H}")${BOX_TR}"
    print_color "$CYAN" "${BOX_V} ${WHITE}Export Summary${CYAN}$(printf '%*s' 63 '')${BOX_V}"
    print_color "$CYAN" "${BOX_T}$(printf '%*s' 78 '' | tr ' ' "${BOX_H}")${BOX_B}"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Dashboards:" "$dashboard_count"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Monitors/Alerts:" "$monitor_count"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Log Pipelines:" "$pipeline_count"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Log Indexes:" "$index_count"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Synthetic Tests:" "$synthetic_count"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "SLOs:" "$slo_count"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Downtimes:" "$downtime_count"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Webhooks:" "$webhook_count"
    print_color "$CYAN" "${BOX_T}$(printf '%*s' 78 '' | tr ' ' "${BOX_H}")${BOX_B}"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Total API Calls:" "$TOTAL_API_CALLS"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Successful:" "$SUCCESSFUL_API_CALLS"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Failed:" "$FAILED_API_CALLS"
    printf "${CYAN}${BOX_V}${NC} %-40s %36s ${CYAN}${BOX_V}${NC}\n" "Errors:" "$ERRORS_ENCOUNTERED"
    print_color "$CYAN" "${BOX_BL}$(printf '%*s' 78 '' | tr ' ' "${BOX_H}")${BOX_BR}"
    echo ""
}

# =============================================================================
# ARCHIVE CREATION
# =============================================================================

create_archive() {
    print_step "Creating Export Archive"

    local archive_name="${EXPORT_NAME}.tar.gz"
    local archive_path="$EXPORT_DIR/$archive_name"

    log INFO "Compressing export directory..."
    log INFO "Archive: $archive_name"

    # NOTE: do not `cd "$EXPORT_DIR"` here. EXPORT_DIR may be relative (the
    # default is ./datadog-export); changing the shell cwd would invalidate every
    # other relative path used below ($LOG_FILE for tee, $archive_path for du /
    # shasum / the .sha256 redirect), silently skipping the checksum step. Let
    # tar change directories itself via -C so the shell cwd is left untouched.
    if tar -czf "$archive_path" -C "$EXPORT_DIR" "$EXPORT_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        local archive_size=$(du -h "$archive_path" | cut -f1)
        log SUCCESS "Archive created: $archive_name ($archive_size)"

        # Calculate checksum
        log INFO "Calculating checksum..."
        if command_exists shasum; then
            local checksum=$(shasum -a 256 "$archive_path" | cut -d' ' -f1)
            echo "$checksum  $archive_name" > "${archive_path}.sha256"
            log SUCCESS "Checksum: $checksum"
        fi

        return 0
    else
        log ERROR "Failed to create archive"
        return 1
    fi
}

# =============================================================================
# ACCESS TEST
# =============================================================================

# Probe a single endpoint; sets PROBE_CODE and PROBE_BODY globals.
probe_endpoint() {
    local endpoint="$1"
    local url="${DATADOG_API_URL}${endpoint}"
    local tmp
    tmp=$(mktemp)
    PROBE_CODE=$(curl -s -o "$tmp" -w "%{http_code}" \
        -H "DD-API-KEY: ${DATADOG_API_KEY}" \
        -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
        -H "Content-Type: application/json" \
        --max-time 15 \
        "$url" 2>/dev/null)
    PROBE_BODY=$(cat "$tmp")
    rm -f "$tmp"
}

# Classify HTTP code + body into PASS / WARN / FAIL.
# $1 = http code, $2 = response body, $3 = jq expression returning item count
classify_probe() {
    local code="$1" body="$2" jq_expr="$3"
    case "$code" in
        200|201)
            local count
            count=$(echo "$body" | jq "$jq_expr" 2>/dev/null)
            if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]; then
                echo "PASS"
            else
                echo "WARN"
            fi
            ;;
        401|403) echo "FAIL" ;;
        404)     echo "WARN" ;;
        *)       echo "FAIL" ;;
    esac
}

run_test_access() {
    echo ""
    print_header "DataDog Access Test"
    echo ""
    print_color "$CYAN" "  Testing credentials and API permissions for: $DATADOG_API_URL"
    echo ""

    local sep="  +----------------------------------+---------+------+----------------------------+"
    local hfmt="  | %-32s | %-7s | %-4s | %-26s |"
    local rfmt="  | %-32s | %-7s | %-4s | %-26s |"

    echo "$sep"
    printf "$hfmt\n" "CATEGORY" "RESULT" "HTTP" "NOTES"
    echo "$sep"

    local pass_count=0 warn_count=0 fail_count=0

    test_one() {
        local label="$1" endpoint="$2" jq_expr="$3"

        probe_endpoint "$endpoint"
        local code="$PROBE_CODE" body="$PROBE_BODY"
        local result notes=""

        case "$code" in
            000|"") result="FAIL"; notes="No response - check network" ;;
            401|403) result="FAIL"; notes="Auth error - check key scopes" ;;
            404)     result="WARN"; notes="Endpoint not found" ;;
            200|201) result=$(classify_probe "$code" "$body" "$jq_expr") ;;
            *)       result="FAIL"; notes="Unexpected HTTP $code" ;;
        esac

        if [[ "$result" == "WARN" ]] && [[ -z "$notes" ]]; then
            notes="Scope ok; category may be empty"
        fi

        case "$result" in
            PASS)
                printf "${GREEN}${rfmt}${NC}\n" "$label" "PASS" "$code" "$notes"
                pass_count=$((pass_count + 1))
                ;;
            WARN)
                printf "${YELLOW}${rfmt}${NC}\n" "$label" "WARN" "$code" "$notes"
                warn_count=$((warn_count + 1))
                ;;
            FAIL)
                printf "${RED}${rfmt}${NC}\n" "$label" "FAIL" "$code" "$notes"
                fail_count=$((fail_count + 1))
                ;;
        esac
    }

    # Compute timestamp for metrics API (requires 'from' parameter)
    local metrics_from=$(date -u -v-1d "+%s" 2>/dev/null || date -u -d "1 day ago" "+%s" 2>/dev/null)

    test_one "Credentials"              "/api/v1/validate"                            "if .valid then 1 else 0 end"
    test_one "Organization"             "/api/v1/org"                                 ".org | if . then 1 else 0 end"
    test_one "Dashboards"               "/api/v1/dashboard"                           ".dashboards | length"
    test_one "Monitors"                 "/api/v1/monitor?page_size=1"                 "length"
    test_one "Log Pipelines"            "/api/v1/logs/config/pipelines"               "length"
    test_one "Log Indexes"              "/api/v1/logs/config/indexes"                 ".indexes | length"
    test_one "Synthetic Tests"          "/api/v1/synthetics/tests?page_size=1"        ".tests | length"
    test_one "SLOs"                     "/api/v1/slo?limit=1"                         ".data | length"
    test_one "Downtimes"                "/api/v2/downtime?page%5Blimit%5D=1"          ".data | length"
    test_one "Metrics"                  "/api/v1/metrics?from=${metrics_from}"        ".metrics | length"
    test_one "Webhooks"                 "/api/v1/integration/webhooks"                ".webhooks | length"
    test_one "Users"                    "/api/v2/users?page%5Bsize%5D=1"             ".data | length"
    test_one "Roles"                    "/api/v2/roles?page%5Bsize%5D=1"             ".data | length"
    test_one "Teams"                    "/api/v2/teams?page%5Bsize%5D=1"             ".data | length"
    test_one "Audit Trail (analytics)"  "/api/v2/audit/events?page%5Blimit%5D=1"     ".data | length"
    test_one "Usage Metering (analytics)" "/api/v1/usage/logs_by_index?start_hr=2024-01-01T00&end_hr=2024-01-02T00" ".usage | length"

    echo "$sep"
    printf "  | %-32s   ${GREEN}PASS: %-3s${NC}   ${YELLOW}WARN: %-3s${NC}   ${RED}FAIL: %-3s${NC} |\n" \
           "SUMMARY" "$pass_count" "$warn_count" "$fail_count"
    echo "$sep"
    echo ""

    if [[ $fail_count -gt 0 ]]; then
        print_color "$RED" "  One or more categories FAILED. Fix Application Key scopes before running a full export."
    elif [[ $warn_count -gt 0 ]]; then
        print_color "$YELLOW" "  All categories accessible. WARN may indicate empty categories or optional scopes."
    else
        print_color "$GREEN" "  All checks passed. Ready to run a full export."
    fi
    echo ""
}

# =============================================================================
# COMMAND LINE ARGUMENT PARSING
# =============================================================================

usage() {
    cat << EOF

${BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${NC}

${BOLD}USAGE:${NC}
    $0 [OPTIONS]

${BOLD}REQUIRED OPTIONS:${NC}
    --api-key KEY          DataDog API Key (DD-API-KEY)
    --app-key KEY          DataDog Application Key (DD-APPLICATION-KEY)

${BOLD}OPTIONAL:${NC}
    --site SITE            DataDog site identifier (default: app, equivalent to us1)
                           Accepts a short code, domain, or full app URL:
                             Short code: app / us1 (default), us3, us5, eu, ap1
                             Domain:     hxp.datadoghq.com, hx-eu.datadoghq.eu
                             Full URL:   https://app.datadoghq.com
                                         https://hx-eu.datadoghq.eu
    --custom-url URL       Custom API URL (for testing with mock API)
    --output DIR           Export directory (default: ./datadog-export)
    --name NAME            Export name (default: datadog-export-TIMESTAMP)

${BOLD}SKIP OPTIONS:${NC}
    --skip-dashboards      Skip dashboard export
    --skip-monitors        Skip monitor/alert export
    --skip-logs            Skip log pipeline/index export
    --skip-synthetics      Skip synthetic test export
    --skip-slos            Skip SLO export
    --skip-metrics         Skip metrics metadata export
    --skip-users           Skip user/role/team export
    --usage                Collect usage analytics (dashboard views, monitor
                           triggers, index volume, unused assets)
                           Requires: audit_trail_read + usage_read permissions
    --usage-period PERIOD  Usage lookback period (default: 90d). Implies --usage

${BOLD}OTHER:${NC}
    --test-access          Test credentials and scope for all export categories, then exit.
                           No data is written. Run this before every first export.
    --debug                Enable debug logging
    --help                 Show this help message

${BOLD}EXAMPLES:${NC}
    # Interactive mode (will prompt for credentials)
    $0

    # Non-interactive mode with US1 (default)
    $0 --api-key "abc123" --app-key "xyz789"

    # EU region
    $0 --api-key "abc123" --app-key "xyz789" --site eu

    # Custom output directory
    $0 --api-key "abc123" --app-key "xyz789" --output /tmp/dd-export

    # Skip certain exports
    $0 --api-key "abc123" --app-key "xyz789" --skip-logs --skip-users

    # Test with mock API
    $0 --api-key "test" --app-key "test" --custom-url "http://localhost:3000"

${BOLD}SITE IDENTIFIER FORMATS:${NC}
    Short codes (backwards compatible):
      app / us1 → https://api.datadoghq.com (default)
      us3       → https://api.us3.datadoghq.com
      us5       → https://api.us5.datadoghq.com
      eu        → https://api.datadoghq.eu
      ap1       → https://api.ap1.datadoghq.com

    Domain or full URL (recommended for dedicated clusters):
      hxp.datadoghq.com         → https://api.hxp.datadoghq.com
      hx-eu.datadoghq.eu        → https://api.hx-eu.datadoghq.eu
      https://hx-eu.datadoghq.eu  (same result — URL is parsed automatically)

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-key)
                DATADOG_API_KEY="$2"
                shift 2
                ;;
            --app-key)
                DATADOG_APP_KEY="$2"
                shift 2
                ;;
            --site)
                DATADOG_SITE="$2"
                SITE_EXPLICITLY_SET=true
                shift 2
                ;;
            --custom-url)
                CUSTOM_API_URL="$2"
                shift 2
                ;;
            --output)
                EXPORT_DIR="$2"
                shift 2
                ;;
            --name)
                EXPORT_NAME="$2"
                shift 2
                ;;
            --skip-dashboards)
                SKIP_DASHBOARDS=true
                shift
                ;;
            --skip-monitors)
                SKIP_MONITORS=true
                shift
                ;;
            --skip-logs)
                SKIP_LOGS=true
                shift
                ;;
            --skip-synthetics)
                SKIP_SYNTHETICS=true
                shift
                ;;
            --skip-slos)
                SKIP_SLOS=true
                shift
                ;;
            --skip-metrics)
                SKIP_METRICS=true
                shift
                ;;
            --skip-users)
                SKIP_USERS=true
                shift
                ;;
            --usage)
                COLLECT_USAGE=true
                shift
                ;;
            --usage-period)
                COLLECT_USAGE=true
                USAGE_PERIOD="$2"
                shift 2
                ;;
            --test-access)
                TEST_ACCESS=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# INTERACTIVE PROMPTS
# =============================================================================

prompt_for_credentials() {
    if [[ -z "$DATADOG_API_KEY" ]]; then
        echo ""
        print_color "$YELLOW" "DataDog API Key not provided via command line"
        read -p "$(print_color $CYAN 'Enter DataDog API Key: ')" DATADOG_API_KEY
    fi

    if [[ -z "$DATADOG_APP_KEY" ]]; then
        echo ""
        print_color "$YELLOW" "DataDog Application Key not provided via command line"
        read -p "$(print_color $CYAN 'Enter DataDog Application Key: ')" DATADOG_APP_KEY
    fi

    if [[ -z "$CUSTOM_API_URL" ]] && [[ "$SITE_EXPLICITLY_SET" != "true" ]]; then
        echo ""
        print_color "$CYAN" "DataDog Site (default: app, equivalent to us1)"
        print_color "$GRAY" "  Paste your DataDog app URL or enter a site identifier:"
        print_color "$GRAY" "  URL:        https://app.datadoghq.com  or  https://hx-eu.datadoghq.eu"
        print_color "$GRAY" "  Short code: app / us1 (default), us3, us5, eu, ap1"
        read -p "$(print_color $CYAN 'Site [app]: ')" site_input
        DATADOG_SITE="${site_input:-app}"
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Print header
    clear
    print_header "$SCRIPT_NAME v$SCRIPT_VERSION"

    # Check requirements
    log INFO "Checking system requirements..."
    if ! check_requirements; then
        log ERROR "System requirements not met"
        exit 1
    fi
    log SUCCESS "System requirements met"

    # Prompt for credentials if not provided
    prompt_for_credentials

    # Validate we have credentials
    if [[ -z "$DATADOG_API_KEY" ]] || [[ -z "$DATADOG_APP_KEY" ]]; then
        log ERROR "API Key and Application Key are required"
        exit 1
    fi

    # Set API URL (needed for both test-access and full export)
    DATADOG_API_URL=$(get_api_url)

    # Handle --test-access: probe all endpoints and exit without writing any files
    if [[ "$TEST_ACCESS" == "true" ]]; then
        run_test_access
        exit $?
    fi

    # Set up export directory
    TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
    if [[ -z "$EXPORT_DIR" ]]; then
        EXPORT_DIR="./datadog-export"
    fi
    if [[ -z "$EXPORT_NAME" ]]; then
        EXPORT_NAME="datadog-export-${TIMESTAMP}"
    fi

    OUTPUT_DIR="$EXPORT_DIR/$EXPORT_NAME"
    LOG_FILE="$OUTPUT_DIR/export.log"

    # Create export directory
    mkdir -p "$OUTPUT_DIR"

    # Initialize log file
    START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    log INFO "================================"
    log INFO "Export started: $START_TIME"
    log INFO "Script version: $SCRIPT_VERSION"
    log INFO "Export directory: $OUTPUT_DIR"
    log INFO "================================"

    # Calculate total steps
    TOTAL_STEPS=11
    [[ "$SKIP_DASHBOARDS" == "true" ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))
    [[ "$SKIP_MONITORS" == "true" ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))
    [[ "$SKIP_LOGS" == "true" ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))
    [[ "$SKIP_SYNTHETICS" == "true" ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))
    [[ "$SKIP_SLOS" == "true" ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))
    [[ "$SKIP_METRICS" == "true" ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))
    [[ "$SKIP_USERS" == "true" ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))
    [[ "$COLLECT_USAGE" == "true" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

    # Validate credentials
    if ! validate_credentials; then
        log ERROR "Credential validation failed"
        exit 1
    fi

    # Execute export steps
    export_dashboards
    export_monitors
    export_logs_config
    export_synthetics
    export_slos
    export_downtimes
    export_metrics
    export_webhooks
    export_users_teams
    export_additional_resources

    # Collect usage analytics (if --usage flag is set)
    collect_usage_analytics

    # Generate manifest
    generate_manifest

    # Create archive
    create_archive

    # Final summary
    echo ""
    print_header "Export Complete!"

    print_color "$GREEN" "Export completed successfully!"
    print_color "$WHITE" "Export location: $OUTPUT_DIR"
    print_color "$WHITE" "Archive: $EXPORT_DIR/${EXPORT_NAME}.tar.gz"
    print_color "$WHITE" "Log file: $LOG_FILE"

    # Show warnings for potential silent failures
    if [[ $SUSPICIOUS_EMPTY_COUNT -gt 0 ]]; then
        echo ""
        print_color "$YELLOW" "${BOX_TL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_TR}"
        print_color "$YELLOW" "${BOX_V}  ⚠️  POTENTIAL SILENT FAILURES DETECTED                                      ${BOX_V}"
        print_color "$YELLOW" "${BOX_T}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_B}"
        print_color "$YELLOW" "${BOX_V}                                                                            ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  Export completed successfully but ${SUSPICIOUS_EMPTY_COUNT} resource type(s) returned 0 items.  ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}                                                                            ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  This usually means your Application Key is MISSING REQUIRED SCOPES.       ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  DataDog APIs return HTTP 200 (success) even when scopes are missing.     ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}                                                                            ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  Empty results for:                                                        ${BOX_V}"

        for warning in "${EMPTY_RESULTS_WARNINGS[@]}"; do
            IFS='|' read -r resource scope <<< "$warning"
            printf "${YELLOW}${BOX_V}    • %-30s (missing scope: %-20s) ${BOX_V}${NC}\n" "$resource" "$scope"
        done

        print_color "$YELLOW" "${BOX_V}                                                                            ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  CRITICAL: Your export is likely INCOMPLETE!                               ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}                                                                            ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  To fix:                                                                   ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  1. Recreate your Application Key with ALL required scopes                 ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  2. Run this script with --test-access to validate scopes                  ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}  3. Re-run the full export with the corrected Application Key              ${BOX_V}"
        print_color "$YELLOW" "${BOX_V}                                                                            ${BOX_V}"
        print_color "$YELLOW" "${BOX_BL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_BR}"
        echo ""
    fi

    if [[ $ERRORS_ENCOUNTERED -gt 0 ]]; then
        echo ""
        print_color "$YELLOW" "⚠ Completed with $ERRORS_ENCOUNTERED errors"
        print_color "$YELLOW" "Review the log file for details: $LOG_FILE"
    fi

    echo ""
    print_color "$CYAN" "Next steps:"
    print_color "$WHITE" "1. Upload the archive to DMP (DataDog Edition) application"
    print_color "$WHITE" "2. Review the export manifest: $OUTPUT_DIR/manifest.json"
    print_color "$WHITE" "3. Begin migration planning in Dynatrace"
    echo ""

    log INFO "Export completed at $(date '+%Y-%m-%d %H:%M:%S')"
}

# Run main function
main "$@"
