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
#  DMA DataDog Export Script v2.0.0
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

SCRIPT_VERSION="2.0.0"
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
DATADOG_SITE="us1"          # default: US1
DATADOG_API_URL=""          # Will be set based on site
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

# Progress tracking
TOTAL_STEPS=0
CURRENT_STEP=0
START_TIME=""
ERRORS_ENCOUNTERED=0

# API Response tracking
TOTAL_API_CALLS=0
SUCCESSFUL_API_CALLS=0
FAILED_API_CALLS=0

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

    # Write to log file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

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

    case "$DATADOG_SITE" in
        us1)
            echo "https://api.datadoghq.com"
            ;;
        us3)
            echo "https://api.us3.datadoghq.com"
            ;;
        us5)
            echo "https://api.us5.datadoghq.com"
            ;;
        eu)
            echo "https://api.datadoghq.eu"
            ;;
        ap1)
            echo "https://api.ap1.datadoghq.com"
            ;;
        *)
            echo "https://api.datadoghq.com"
            ;;
    esac
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

    log INFO "Fetching dashboard list..."
    local list_file="$dashboards_dir/_list.json"

    if dd_api_call "GET" "/api/v1/dashboard" "$list_file"; then
        local count=$(jq '.dashboards | length' "$list_file" 2>/dev/null || echo "0")
        log SUCCESS "Found $count dashboards"

        if [[ "$count" -gt 0 ]]; then
            # Extract dashboard IDs
            local dashboard_ids=$(jq -r '.dashboards[].id' "$list_file" 2>/dev/null)

            local current=0
            while IFS= read -r dashboard_id; do
                current=$((current + 1))
                show_progress $current $count

                local output_file="$dashboards_dir/dashboard-${dashboard_id}.json"
                dd_api_call "GET" "/api/v1/dashboard/${dashboard_id}" "$output_file" >/dev/null 2>&1

            done <<< "$dashboard_ids"

            echo ""  # New line after progress bar
            log SUCCESS "Exported $count dashboards"
        fi
    else
        log ERROR "Failed to fetch dashboard list"
        return 1
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

    log INFO "Fetching monitor list..."
    local list_file="$monitors_dir/_list.json"

    if dd_api_call "GET" "/api/v1/monitor" "$list_file"; then
        local count=$(jq '. | length' "$list_file" 2>/dev/null || echo "0")
        log SUCCESS "Found $count monitors"

        if [[ "$count" -gt 0 ]]; then
            # Save full list with all monitors
            log INFO "Saving complete monitor list..."

            # Extract individual monitors
            local monitor_ids=$(jq -r '.[].id' "$list_file" 2>/dev/null)

            local current=0
            while IFS= read -r monitor_id; do
                current=$((current + 1))
                show_progress $current $count

                local output_file="$monitors_dir/monitor-${monitor_id}.json"
                dd_api_call "GET" "/api/v1/monitor/${monitor_id}" "$output_file" >/dev/null 2>&1

            done <<< "$monitor_ids"

            echo ""  # New line after progress bar
            log SUCCESS "Exported $count monitors"
        fi
    else
        log ERROR "Failed to fetch monitor list"
        return 1
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
        log SUCCESS "Found $count log pipelines"

        if [[ "$count" -gt 0 ]]; then
            # Extract individual pipelines
            local pipeline_ids=$(jq -r '.[].id' "$pipelines_list" 2>/dev/null)

            local current=0
            while IFS= read -r pipeline_id; do
                current=$((current + 1))
                show_progress $current $count

                local output_file="$logs_dir/pipelines/pipeline-${pipeline_id}.json"
                dd_api_call "GET" "/api/v1/logs/config/pipelines/${pipeline_id}" "$output_file" >/dev/null 2>&1

            done <<< "$pipeline_ids"
            echo ""
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

    log INFO "Fetching synthetic tests..."
    local list_file="$synthetics_dir/_list.json"

    if dd_api_call "GET" "/api/v1/synthetics/tests" "$list_file"; then
        local count=$(jq '.tests | length' "$list_file" 2>/dev/null || echo "0")
        log SUCCESS "Found $count synthetic tests"

        if [[ "$count" -gt 0 ]]; then
            # Extract test IDs
            local test_ids=$(jq -r '.tests[].public_id' "$list_file" 2>/dev/null)

            local current=0
            while IFS= read -r test_id; do
                current=$((current + 1))
                show_progress $current $count

                local output_file="$synthetics_dir/test-${test_id}.json"
                dd_api_call "GET" "/api/v1/synthetics/tests/${test_id}" "$output_file" >/dev/null 2>&1

            done <<< "$test_ids"

            echo ""
            log SUCCESS "Exported $count synthetic tests"
        fi
    else
        log ERROR "Failed to fetch synthetic tests"
        return 1
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
    log SUCCESS "Found $count SLOs"

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

    log INFO "Fetching downtimes..."
    local list_file="$downtimes_dir/_list.json"

    if dd_api_call "GET" "/api/v2/downtime" "$list_file"; then
        local count=$(jq '.data | length' "$list_file" 2>/dev/null || echo "0")
        log SUCCESS "Found $count downtimes"

        if [[ "$count" -gt 0 ]]; then
            # Extract downtime IDs
            local downtime_ids=$(jq -r '.data[].id' "$list_file" 2>/dev/null)

            local current=0
            while IFS= read -r downtime_id; do
                current=$((current + 1))
                show_progress $current $count

                local output_file="$downtimes_dir/downtime-${downtime_id}.json"
                dd_api_call "GET" "/api/v2/downtime/${downtime_id}" "$output_file" >/dev/null 2>&1

            done <<< "$downtime_ids"

            echo ""
            log SUCCESS "Exported $count downtimes"
        fi
    else
        log WARNING "Failed to fetch downtimes"
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

    if dd_api_call "GET" "/api/v1/metrics" "$list_file"; then
        local count=$(jq '.metrics | length' "$list_file" 2>/dev/null || echo "0")
        log SUCCESS "Found $count active metrics"

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

    # Export users
    log INFO "Fetching users..."
    local users_file="$users_dir/users.json"
    if dd_api_call "GET" "/api/v2/users" "$users_file"; then
        local count=$(jq '.data | length' "$users_file" 2>/dev/null || echo "0")
        log SUCCESS "Exported $count users"
    else
        log WARNING "Failed to fetch users"
    fi

    # Export roles
    log INFO "Fetching roles..."
    local roles_file="$users_dir/roles.json"
    if dd_api_call "GET" "/api/v2/roles" "$roles_file"; then
        local count=$(jq '.data | length' "$roles_file" 2>/dev/null || echo "0")
        log SUCCESS "Exported $count roles"
    else
        log WARNING "Failed to fetch roles"
    fi

    # Export teams
    log INFO "Fetching teams..."
    local teams_file="$users_dir/teams.json"
    if dd_api_call "GET" "/api/v2/team" "$teams_file"; then
        local count=$(jq '.data | length' "$teams_file" 2>/dev/null || echo "0")
        log SUCCESS "Exported $count teams"
    else
        log WARNING "Failed to fetch teams"
    fi

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
    audit_trail_query "@type:audit @evt.name:\"Dashboard Viewed\"" "$raw_file"

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
    audit_trail_query "@type:audit @asset.type:monitor @evt.name:(\"Monitor Alert Triggered\" OR \"Monitor Resolved\")" "$raw_file"

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
    local from_hr=$(get_usage_from_timestamp | sed 's/T.*/T00/')
    local to_hr=$(get_usage_to_timestamp | sed 's/T.*/T00/')

    local temp_file=$(mktemp)
    if dd_api_call "GET" "/api/v1/usage/logs_by_index?start_hr=${from_hr}&end_hr=${to_hr}" "$temp_file"; then
        # Aggregate daily data into per-index totals
        jq '{
            period: { from: .'"'"'usage'"'"'[0].date // "unknown", to: .'"'"'usage'"'"'[-1].date // "unknown" },
            indexes: [.usage // [] | [.[].by_index // []] | add // [] | group_by(.index_name) | .[] | {
                index_name: .[0].index_name,
                total_event_count: ([.[].event_count] | add),
                total_retention_event_count: ([.[].retention_event_count // 0] | add),
                days_active: length
            }] | sort_by(-.total_event_count)
        }' "$temp_file" > "$OUTPUT_DIR/analytics/log_index_volume.json" 2>/dev/null

        local count=$(jq '.indexes | length' "$OUTPUT_DIR/analytics/log_index_volume.json" 2>/dev/null)
        log SUCCESS "Log index volume: $count indexes with usage data"
    else
        log WARNING "Log index volume: Usage Metering API not available (needs usage_read permission)"
        echo '{"indexes": [], "error": "Usage Metering API not available"}' > "$OUTPUT_DIR/analytics/log_index_volume.json"
    fi
    rm -f "$temp_file"
}

# ── Query 4: Monitor Modifications ───────────────────────────────────────────
collect_monitor_modifications() {
    log INFO "Collecting monitor modification analytics..."
    local raw_file=$(mktemp)
    audit_trail_query "@type:audit @asset.type:monitor @evt.name:(\"Monitor Created\" OR \"Monitor Modified\")" "$raw_file"

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
        log WARNING "No dashboards found in export to cross-reference"
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
        log WARNING "No monitors found in export to cross-reference"
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

    cd "$EXPORT_DIR"
    if tar -czf "$archive_name" "$EXPORT_NAME" 2>&1 | tee -a "$LOG_FILE"; then
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
    --site SITE            DataDog site/region (default: us1)
                           Options: us1, us3, us5, eu, ap1
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

${BOLD}DATADOG SITES:${NC}
    us1 - https://api.datadoghq.com (default)
    us3 - https://api.us3.datadoghq.com
    us5 - https://api.us5.datadoghq.com
    eu  - https://api.datadoghq.eu
    ap1 - https://api.ap1.datadoghq.com

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

    if [[ -z "$CUSTOM_API_URL" ]]; then
        if [[ -z "$DATADOG_SITE" ]] || [[ "$DATADOG_SITE" == "us1" ]]; then
            echo ""
            print_color "$CYAN" "DataDog Site/Region (default: us1)"
            print_color "$GRAY" "  Options: us1, us3, us5, eu, ap1, custom"
            read -p "$(print_color $CYAN 'Site [us1]: ')" site_input
            DATADOG_SITE="${site_input:-us1}"
        fi
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

    # Set API URL
    DATADOG_API_URL=$(get_api_url)

    # Initialize log file
    START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    log INFO "================================"
    log INFO "Export started: $START_TIME"
    log INFO "Script version: $SCRIPT_VERSION"
    log INFO "Export directory: $OUTPUT_DIR"
    log INFO "================================"

    # Calculate total steps
    TOTAL_STEPS=10
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
