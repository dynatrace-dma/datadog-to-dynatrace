#!/bin/bash
#
# DMP DataDog Export Script
# ===========================
#
# This script exports DataDog assets for migration to Dynatrace.
# It uses the DataDog API to fetch dashboards, monitors, pipelines,
# synthetics, SLOs, and metrics, then packages them into a .tar.gz archive.
#
# Requirements:
#   - curl
#   - jq
#   - DataDog API Key
#   - DataDog Application Key
#
# Usage:
#   ./dmp-datadog-export.sh --api-key <API_KEY> --app-key <APP_KEY> [--site <SITE>]
#

set -e

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="DMP DataDog Export"

# Default values
DD_SITE="datadoghq.com"
DD_API_KEY=""
DD_APP_KEY=""
OUTPUT_DIR=""
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_usage() {
    cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage: $0 [OPTIONS]

Required Options:
  --api-key KEY       DataDog API Key
  --app-key KEY       DataDog Application Key

Optional Options:
  --site SITE         DataDog site (default: datadoghq.com)
                      Options: datadoghq.com, datadoghq.eu, us3.datadoghq.com,
                               us5.datadoghq.com, ap1.datadoghq.com
  --output DIR        Output directory (default: current directory)
  --verbose           Enable verbose output
  --help              Show this help message

Examples:
  # Basic export (US1)
  $0 --api-key abc123 --app-key xyz789

  # Export from EU site
  $0 --api-key abc123 --app-key xyz789 --site datadoghq.eu
EOF
}

check_dependencies() {
    local missing=()
    command -v curl &> /dev/null || missing+=("curl")
    command -v jq &> /dev/null || missing+=("jq")
    command -v tar &> /dev/null || missing+=("tar")
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

dd_api_call() {
    local endpoint="$1"
    local method="${2:-GET}"
    local url="https://api.${DD_SITE}${endpoint}"
    curl -s -X $method $url \
        -H "Content-Type: application/json" \
        -H "DD-API-KEY: ${DD_API_KEY}" \
        -H "DD-APPLICATION-KEY: ${DD_APP_KEY}"
}

validate_credentials() {
    log_info "Validating DataDog credentials..."
    local response
    response=$(dd_api_call "/api/v1/validate")
    if echo $response | jq -e '.valid' &> /dev/null; then
        log_success "Credentials validated successfully"
        return 0
    else
        log_error "Invalid credentials or API error"
        return 1
    fi
}

export_dashboards() {
    local export_dir="$1"
    mkdir -p "${export_dir}/dashboards"
    log_info "Exporting dashboards..."
    local dashboard_list
    dashboard_list=$(dd_api_call "/api/v1/dashboard")
    local count
    count=$(echo $dashboard_list | jq '.dashboards | length')
    log_info "Found $count dashboards"
    echo $dashboard_list | jq -c '.dashboards[]' | while read -r dash; do
        local id=$(echo $dash | jq -r '.id')
        dd_api_call "/api/v1/dashboard/${id}" > "${export_dir}/dashboards/dashboard-${id}.json"
    done
    log_success "Exported $count dashboards"
}

export_monitors() {
    local export_dir="$1"
    mkdir -p "${export_dir}/monitors"
    log_info "Exporting monitors..."
    local monitors
    monitors=$(dd_api_call "/api/v1/monitor")
    local count=$(echo $monitors | jq 'length')
    log_info "Found $count monitors"
    echo $monitors | jq -c '.[]' | while read -r monitor; do
        local id=$(echo $monitor | jq -r '.id')
        echo $monitor > "${export_dir}/monitors/monitor-${id}.json"
    done
    log_success "Exported $count monitors"
}

export_pipelines() {
    local export_dir="$1"
    mkdir -p "${export_dir}/pipelines"
    log_info "Exporting log pipelines..."
    local pipelines
    pipelines=$(dd_api_call "/api/v1/logs/config/pipelines")
    local count=$(echo $pipelines | jq 'length')
    log_info "Found $count log pipelines"
    echo $pipelines | jq -c '.[]' | while read -r pipeline; do
        local id=$(echo $pipeline | jq -r '.id')
        echo $pipeline > "${export_dir}/pipelines/pipeline-${id}.json"
    done
    log_success "Exported $count pipelines"
}

export_synthetics() {
    local export_dir="$1"
    mkdir -p "${export_dir}/synthetics"
    log_info "Exporting synthetic tests..."
    local synthetics
    synthetics=$(dd_api_call "/api/v1/synthetics/tests")
    local count=$(echo $synthetics | jq '.tests | length')
    log_info "Found $count synthetic tests"
    echo $synthetics | jq -c '.tests[]' | while read -r synthetic; do
        local id=$(echo $synthetic | jq -r '.public_id')
        echo $synthetic > "${export_dir}/synthetics/synthetic-${id}.json"
    done
    log_success "Exported $count synthetics"
}

export_slos() {
    local export_dir="$1"
    mkdir -p "${export_dir}/slos"
    log_info "Exporting SLOs..."
    local slos
    slos=$(dd_api_call "/api/v1/slo")
    local count=$(echo $slos | jq '.data | length')
    log_info "Found $count SLOs"
    echo $slos | jq -c '.data[]' | while read -r slo; do
        local id=$(echo $slo | jq -r '.id')
        echo $slo > "${export_dir}/slos/slo-${id}.json"
    done
    log_success "Exported $count SLOs"
}

export_metrics() {
    local export_dir="$1"
    mkdir -p "${export_dir}/metrics"
    log_info "Exporting metric metadata..."
    local from_ts=$(($(date +%s) - 86400))
    local metrics
    metrics=$(dd_api_call "/api/v1/metrics?from=${from_ts}")
    local count=$(echo $metrics | jq '.metrics | length')
    log_info "Found $count active metrics"
    echo $metrics | jq '.metrics' > "${export_dir}/metrics/metrics-list.json"
    log_success "Exported $count metrics"
}

create_manifest() {
    local export_dir="$1"
    log_info "Creating manifest..."
    local dashboard_count=$(find "${export_dir}/dashboards" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local monitor_count=$(find "${export_dir}/monitors" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local pipeline_count=$(find "${export_dir}/pipelines" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local synthetic_count=$(find "${export_dir}/synthetics" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local slo_count=$(find "${export_dir}/slos" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    local metric_count=0
    [ -f "${export_dir}/metrics/metrics-list.json" ] && metric_count=$(jq 'length' "${export_dir}/metrics/metrics-list.json")

    local region="US1"
    case $DD_SITE in
        "datadoghq.eu") region="EU" ;;
        "us3.datadoghq.com") region="US3" ;;
        "us5.datadoghq.com") region="US5" ;;
        "ap1.datadoghq.com") region="AP1" ;;
    esac

    cat > "${export_dir}/manifest.json" << MANIFEST_EOF
{
  "version": "${SCRIPT_VERSION}",
  "exportedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "exportScript": "dmp-datadog-export.sh",
  "region": "${region}",
  "site": "${DD_SITE}",
  "counts": {
    "dashboards": ${dashboard_count},
    "monitors": ${monitor_count},
    "pipelines": ${pipeline_count},
    "synthetics": ${synthetic_count},
    "slos": ${slo_count},
    "metrics": ${metric_count}
  }
}
MANIFEST_EOF
    log_success "Manifest created"
}

main() {
    echo ""
    echo "========================================"
    echo "  ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "========================================"
    echo ""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --api-key) DD_API_KEY="$2"; shift 2 ;;
            --app-key) DD_APP_KEY="$2"; shift 2 ;;
            --site) DD_SITE="$2"; shift 2 ;;
            --output) OUTPUT_DIR="$2"; shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --help) show_usage; exit 0 ;;
            *) log_error "Unknown option: $1"; show_usage; exit 1 ;;
        esac
    done

    if [ -z $DD_API_KEY ] || [ -z $DD_APP_KEY ]; then
        log_error "API Key and Application Key are required"
        show_usage
        exit 1
    fi

    [ -z $OUTPUT_DIR ] && OUTPUT_DIR="."
    check_dependencies

    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local export_name="dmp-datadog-export-${timestamp}"
    local export_dir="${OUTPUT_DIR}/${export_name}"

    mkdir -p $export_dir
    log_info "Export directory: $export_dir"

    validate_credentials || exit 1

    export_dashboards $export_dir
    export_monitors $export_dir
    export_pipelines $export_dir
    export_synthetics $export_dir
    export_slos $export_dir
    export_metrics $export_dir
    create_manifest $export_dir

    log_info "Creating archive..."
    local archive_name="${export_name}.tar.gz"
    tar -czf "${OUTPUT_DIR}/${archive_name}" -C $OUTPUT_DIR "$export_name"
    rm -rf $export_dir

    echo ""
    log_success "Export complete!"
    log_info "Archive: ${OUTPUT_DIR}/${archive_name}"
    echo ""
    echo "Next steps:"
    echo "  1. Upload ${archive_name} to DMP (DataDog Edition)"
    echo "  2. Review the migration analysis"
    echo "  3. Start migrating assets to Dynatrace"
    echo ""
}

main "$@"
