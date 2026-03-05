# DMP DataDog Export Script

This script exports your DataDog assets for migration to Dynatrace.

## Requirements

- `curl` - for API calls
- `jq` - for JSON processing
- DataDog API Key (from Organization Settings > API Keys)
- DataDog Application Key (from Organization Settings > Application Keys)

## Usage

```bash
# Make executable
chmod +x dmp-datadog-export.sh

# Run export (US1 - default)
./dmp-datadog-export.sh --api-key YOUR_API_KEY --app-key YOUR_APP_KEY

# Run export (EU region)
./dmp-datadog-export.sh --api-key YOUR_API_KEY --app-key YOUR_APP_KEY --site datadoghq.eu

# Run export (US3 region)
./dmp-datadog-export.sh --api-key YOUR_API_KEY --app-key YOUR_APP_KEY --site us3.datadoghq.com
```

## DataDog Sites

| Region | Site |
|--------|------|
| US1 (default) | datadoghq.com |
| EU | datadoghq.eu |
| US3 | us3.datadoghq.com |
| US5 | us5.datadoghq.com |
| AP1 | ap1.datadoghq.com |

## What Gets Exported

- **Dashboards** - All dashboard definitions with widgets and queries
- **Monitors** - All alert monitors with thresholds and conditions
- **Log Pipelines** - Log processing pipeline configurations
- **Synthetic Tests** - API and browser test definitions
- **SLOs** - Service Level Objective configurations
- **Metrics** - Active metric metadata (last 24 hours)

## Output

The script creates a `.tar.gz` archive containing:

```
dmp-datadog-export-YYYYMMDD-HHMMSS/
├── manifest.json
├── dashboards/
│   └── dashboard-{id}.json
├── monitors/
│   └── monitor-{id}.json
├── pipelines/
│   └── pipeline-{id}.json
├── synthetics/
│   └── synthetic-{id}.json
├── slos/
│   └── slo-{id}.json
└── metrics/
    └── metrics-list.json
```

## Next Steps

1. Upload the generated archive to DMP (DataDog Edition)
2. Review the migration analysis report
3. Start migrating your assets to Dynatrace
