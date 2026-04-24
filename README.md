# DMA DataDog Export Script

**Version**: 2.0.0
**Last Updated**: April 2026

> **Developed for Dynatrace One by Enterprise Solutions & Architecture**
> *An ACE Services Division of Dynatrace*

---

## Overview

Two export scripts are provided — choose the one that matches your environment:

| Script | Platform | Requirements |
|--------|----------|--------------|
| `dma-datadog-export.sh` | Linux, macOS, WSL | bash, curl, jq, tar |
| `dma-datadog-export.ps1` | Windows (PowerShell 5.1+) | tar.exe (Windows 10 build 1803+) |

Both scripts produce identical output archives and are feature-equivalent. The bash script is preferred on Linux/macOS; the PowerShell script is preferred on Windows.

> **DataDog SaaS only.** DataDog does not offer self-hosted versions, so there is no on-premises variant of this script.

---

## Before You Begin

### Prerequisites

**Bash script (`dma-datadog-export.sh`)**

| Requirement | Detail |
|-------------|--------|
| **Platform** | Linux, macOS, or WSL |
| **Shell** | bash 3.2+ (works with macOS default bash) |
| **curl** | `curl --version` to verify |
| **jq** | `jq --version` to verify — install with `brew install jq` (macOS) or `apt-get install jq` (Linux) |
| **tar** | `tar --version` to verify |
| **Network** | HTTPS access to your DataDog API endpoint (see regions below) |
| **Disk space** | 500 MB+ free in the working directory |

**PowerShell script (`dma-datadog-export.ps1`)**

| Requirement | Detail |
|-------------|--------|
| **Platform** | Windows 10 build 1803+ or Windows Server 2019+ |
| **PowerShell** | 5.1+ (Windows PowerShell, pre-installed on Windows 10/11) |
| **tar.exe** | Built into Windows 10 build 1803+; verify with `tar --version` in PowerShell |
| **Network** | HTTPS access to your DataDog API endpoint (see regions below) |
| **Disk space** | 500 MB+ free in the working directory |

### Where to Run

Both scripts run from **any machine with internet access** to the DataDog API — your laptop, a jump host, a CI/CD runner. No access to DataDog infrastructure is required.

### CRLF Line Endings (Windows)

If you downloaded or edited the script on Windows, it may have CRLF line endings. The script auto-detects this on startup and fixes itself — if you see `$'\r': command not found`, let it complete the one-time conversion and re-run.

---

## CRITICAL: Credentials and Permissions

**Insufficient permissions are the most common cause of incomplete exports.** Many DataDog API endpoints silently return empty results rather than a 403 — an export can complete successfully but be missing critical data if the Application Key lacks the required scopes.

### What You Need

You need two credentials from DataDog:

| Credential | Where to Generate | Header Name |
|------------|-------------------|-------------|
| **API Key** | Organization Settings → API Keys → New Key | `DD-API-KEY` |
| **Application Key** | Organization Settings → Application Keys → New Key | `DD-APPLICATION-KEY` |

### Required Application Key Scopes

When creating the Application Key, grant **all** of the following scopes:

| Scope | What It Unlocks |
|-------|----------------|
| `dashboards_read` | Dashboard configurations |
| `monitors_read` | Monitor and alert configurations |
| `org_management` | Organization settings and metadata |
| `logs_read_config` | Log pipeline and log index configurations |
| `synthetics_read` | Synthetic test configurations |
| `slos_read` | SLO configurations |
| `monitors_downtime` | Downtime configurations |
| `metrics_read` | Metric metadata |
| `integrations_read` | Webhook integrations |
| `user_access_read` | Users and roles |
| `teams_read` | Teams |

**For usage analytics** (`--usage` flag), two additional scopes are required:

| Scope | What It Unlocks |
|-------|----------------|
| `audit_trail_read` | Dashboard views, monitor triggers, and modification history via the Audit Trail API |
| `usage_read` | Log index ingestion volume via the Usage Metering API |

> If `audit_trail_read` or `usage_read` are missing, the `--usage` flag will run but produce empty analytics files. No error is raised. This is the most frequent reason the DMA Explorer shows zero usage data for DataDog assets.

### Verify Access and Permissions

**Always run `--test-access` before your first full export.** It probes every API category the script calls — without writing any data — and reports exactly which scopes are working and which are missing.

```bash
# Bash
./dma-datadog-export.sh \
  --api-key "your-api-key" \
  --app-key "your-application-key" \
  --test-access

# PowerShell
.\dma-datadog-export.ps1 `
  -ApiKey "your-api-key" `
  -AppKey "your-application-key" `
  -TestAccess
```

Example output:

```
+----------------------------------------+--------+--------------------------------------+
| Category                               | Status | Detail                               |
+----------------------------------------+--------+--------------------------------------+
| Credentials (validate)                 | PASS   | Authenticated OK                     |
| Organization                           | PASS   | Acme Corp                            |
| Dashboards                             | PASS   | 47 found                             |
| Monitors / Alerts                      | PASS   | 123 found                            |
| Log Pipelines                          | PASS   | 8 found                              |
| Downtimes                              | FAIL   | Permission denied - missing scope (403) |
| Usage: Audit Trail (audit_trail_read)  | WARN   | Missing scope - --usage will be empty |
+----------------------------------------+--------+--------------------------------------+
  1 FAILED, 1 warnings, 13 passed.
  Fix FAIL items before running a full export.
```

**How to read the results:**
- **PASS** — This category will export data normally.
- **FAIL** — A required scope is missing. Many DataDog API endpoints silently return empty results on a 403 rather than raising an error — the export will appear to succeed but that category's data will be absent. Fix all FAIL items before proceeding.
- **WARN** — An optional scope is missing. WARN items only affect `--usage` analytics; the main export will complete normally.

---

## DataDog Regions

### Known Regions

| Site | API URL | `--site` value |
|------|---------|----------------|
| US1 (default) | `https://api.datadoghq.com` | `app` or `us1` |
| US3 | `https://api.us3.datadoghq.com` | `us3` |
| US5 | `https://api.us5.datadoghq.com` | `us5` |
| EU | `https://api.datadoghq.eu` | `eu` |
| AP1 | `https://api.ap1.datadoghq.com` | `ap1` |
| Custom / Mock | Any URL | `--custom-url URL` |

### Dedicated Clusters

The `--site` flag accepts three formats, which is useful for dedicated DataDog clusters:

| Format | Example | When to use |
|--------|---------|-------------|
| Short code | `app`, `eu`, `ap1` | Standard regions (see table above) |
| Site domain | `hx-eu.datadoghq.eu` | Dedicated cluster with known domain |
| Full app URL | `https://hx-eu.datadoghq.eu` | Paste directly from browser address bar |

The API URL is derived automatically: `https://app.hx-eu.datadoghq.eu` → strip `app.` → `https://api.hx-eu.datadoghq.eu`.

> **Dedicated orgs on US1:** Some DataDog dedicated instances are isolated organizations on the shared US1 infrastructure rather than separate clusters. If your browser shows a custom domain (e.g., `hxp.datadoghq.com`) but `--site hxp` fails to connect, use `--site app` instead — the API is at the standard `https://api.datadoghq.com` endpoint.

If you do not know your region, log into the DataDog UI and check the URL in your browser.

---

## What Is Collected

### Always Collected (defaults ON)

| Category | API | Migration Use |
|----------|-----|---------------|
| **Dashboards** | v1 `/dashboard` | Visual migration to Dynatrace dashboards |
| **Monitors / Alerts** | v1 `/monitor` | Alert and notification migration |
| **Log Pipelines** | v1 `/logs/config/pipelines` | OpenPipeline configuration generation |
| **Log Indexes** | v1 `/logs/config/indexes` | Grail bucket planning, retention mapping |
| **Synthetic Tests** | v1 `/synthetics/tests` | Synthetic monitor migration |
| **SLOs** | v1 `/slo` (paginated) | SLO recreation in Dynatrace |
| **Downtimes** | v2 `/downtime` | Maintenance window migration |
| **Metrics Metadata** | v1 `/metrics` | Metric name mapping reference — active metrics reported in the last 24 hours |
| **Webhooks** | v1 `/integration/webhooks` | Integration and notification migration |
| **Users, Roles, Teams** | v2 `/users`, `/roles`, `/team` | Access control planning |

### Opt-In: Usage Analytics (default OFF)

Enable with `--usage`. Requires `audit_trail_read` and `usage_read` scopes.

| File | Source API | DMA Explorer Use |
|------|-----------|-----------------|
| `analytics/dashboard_views.json` | Audit Trail v2 | Dashboard view counts, unique users, last viewed |
| `analytics/monitor_triggers.json` | Audit Trail v2 | Monitor trigger and resolve counts |
| `analytics/log_index_volume.json` | Usage Metering v1 | Per-index daily event counts |
| `analytics/monitor_modifications.json` | Audit Trail v2 | Monitor change history, modified-by |
| `analytics/unused_dashboards.json` | Cross-reference | Dashboards with zero views in the usage period |
| `analytics/unused_monitors.json` | Cross-reference | Monitors that never triggered in the usage period |
| `analytics/_summary.json` | — | Aggregate counts for all of the above |

The usage period defaults to 90 days. Override with `--usage-period 30d` or set the `USAGE_PERIOD` environment variable.

### What Is NOT Collected

- API keys, Application Keys, or session tokens
- Actual log or event data (only pipeline and index configuration)
- SSL certificates or private keys
- User passwords

---

## Running the Export

### Make the Script Executable

Before running for the first time:

```bash
chmod +x dma-datadog-export.sh
```

### Interactive Mode

Run without arguments — the script prompts for credentials and site:

```bash
./dma-datadog-export.sh
```

### Non-Interactive Mode

Provide all parameters on the command line — suitable for automation and CI/CD:

```bash
./dma-datadog-export.sh \
  --api-key "your-api-key" \
  --app-key "your-application-key" \
  --site us1 \
  --output /path/to/export
```

### Common Examples

```bash
# EU region
./dma-datadog-export.sh \
  --api-key "abc123" --app-key "xyz789" \
  --site eu

# Include usage analytics (90-day lookback)
./dma-datadog-export.sh \
  --api-key "abc123" --app-key "xyz789" \
  --usage

# Custom lookback period (30 days)
./dma-datadog-export.sh \
  --api-key "abc123" --app-key "xyz789" \
  --usage --usage-period 30d

# Skip logs and users for a faster partial export
./dma-datadog-export.sh \
  --api-key "abc123" --app-key "xyz789" \
  --skip-logs --skip-users

# Test against a local mock API
./dma-datadog-export.sh \
  --api-key "test" --app-key "test" \
  --custom-url "http://localhost:3000"
```

---

## Command-Line Reference

### Connection & Authentication

| Flag | Description |
|------|-------------|
| `--api-key KEY` | DataDog API Key (`DD-API-KEY`) — **required** |
| `--app-key KEY` | DataDog Application Key (`DD-APPLICATION-KEY`) — **required** |
| `--site SITE` | DataDog region: `us1` (default), `us3`, `us5`, `eu`, `ap1` |
| `--custom-url URL` | Override API base URL (e.g., `http://localhost:3000` for mock testing) |

### Output Control

| Flag | Description |
|------|-------------|
| `--output DIR` | Export destination directory (default: `./datadog-export`) |
| `--name NAME` | Export name prefix (default: `datadog-export-{TIMESTAMP}`) |

### Scope — Skip Flags

| Flag | What It Skips |
|------|--------------|
| `--skip-dashboards` | Dashboard export |
| `--skip-monitors` | Monitor and alert export |
| `--skip-logs` | Log pipeline and index export |
| `--skip-synthetics` | Synthetic test export |
| `--skip-slos` | SLO export |
| `--skip-metrics` | Metrics metadata export |
| `--skip-users` | Users, roles, and teams export |

### Usage Analytics

| Flag | Description |
|------|-------------|
| `--usage` | Enable usage analytics collection (Audit Trail + Usage Metering) |
| `--usage-period PERIOD` | Lookback period (e.g., `30d`, `90d`) — implies `--usage` (default: `90d`) |

### Other

| Flag | PowerShell | Description |
|------|------------|-------------|
| `--test-access` | `-TestAccess` | Test credentials and permissions for all export categories, then exit. No data is written. Run this before every first export. |
| `--debug` | `-DebugMode` | Enable verbose debug logging to console and log file |
| `--non-interactive` | `-NonInteractive` | Skip all interactive prompts. Requires `--api-key` and `--app-key`. |
| *(n/a)* | `-SkipCertCheck` | **PowerShell only.** Disable SSL certificate validation. Use when connecting to a dedicated cluster whose certificate is not trusted by the Windows certificate store. Use only on trusted networks. |
| `--help` | `-ShowHelp` | Show help and exit |

---

## Output Structure

The script creates the following directory layout and then compresses it into a `.tar.gz` archive:

```
datadog-export/
└── datadog-export-{TIMESTAMP}/
    ├── dashboards/
    │   ├── _list.json
    │   └── dashboard-{id}.json
    ├── monitors/
    │   ├── _list.json
    │   └── monitor-{id}.json
    ├── logs/
    │   ├── pipelines/
    │   │   ├── _list.json
    │   │   └── pipeline-{id}.json
    │   └── indexes/
    │       ├── _list.json
    │       └── index-{name}.json
    ├── synthetics/
    │   ├── _list.json
    │   └── test-{public_id}.json
    ├── slos/
    │   ├── _list.json
    │   └── slo-{id}.json
    ├── downtimes/
    │   ├── _list.json
    │   └── downtime-{id}.json
    ├── metrics/
    │   └── _list.json
    ├── webhooks/
    │   ├── _list.json
    │   └── webhook-{name}.json
    ├── users/
    │   ├── users.json
    │   ├── roles.json
    │   └── teams.json
    ├── analytics/              ← only present when --usage is set
    │   ├── _summary.json
    │   ├── dashboard_views.json
    │   ├── monitor_triggers.json
    │   ├── log_index_volume.json
    │   ├── monitor_modifications.json
    │   ├── unused_dashboards.json
    │   └── unused_monitors.json
    ├── manifest.json
    └── export.log
```

The final archive is written to `{output}/{name}.tar.gz` alongside a SHA-256 checksum file (`{name}.tar.gz.sha256`). The `manifest.json` inside the archive records the script version, organization name and ID, item counts per category, API call statistics, and start/end timestamps.

---

## What to Expect

### Interactive Mode Flow

When run without CLI arguments, the script:

1. Checks that `curl`, `jq`, and `tar` are installed
2. Prompts for API Key, Application Key, and site/region
3. Validates credentials against `/api/v1/validate` and fetches the organization name
4. Exports each data category in sequence, showing a progress bar per category
5. Collects usage analytics (if `--usage` was set)
6. Generates `manifest.json` and prints an export summary table
7. Compresses the export into a `.tar.gz` archive and writes a SHA-256 checksum

### Typical Runtimes

| Environment | Without `--usage` | With `--usage` |
|-------------|-------------------|----------------|
| Small (50 dashboards, 100 monitors) | 2–5 minutes | 10–20 minutes |
| Medium (500 dashboards, 1 000 monitors) | 10–20 minutes | 20–45 minutes |
| Large (2 000+ dashboards, 5 000+ monitors) | 30–60 minutes | 1–3 hours |

Usage analytics runtimes are dominated by Audit Trail pagination. The Audit Trail API returns up to 1 000 events per page and the script paginates up to 20 pages per query — large organizations with high event volume will be at the upper end of the range.

### Rate Limiting

The DataDog API enforces per-endpoint rate limits. The script handles this automatically: on a `429 Too Many Requests` response it retries up to 3 times with exponential backoff (5 s, 10 s, 15 s). No action is required.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Export completes but DMA shows no dashboards | Application Key missing `dashboards_read` scope | Re-create the Application Key with all required scopes |
| Export completes but analytics tab is empty | Application Key missing `audit_trail_read` or `usage_read` | Add both scopes to the Application Key, re-run with `--usage` |
| `Authentication failed (403)` during export | Wrong API Key or Application Key value | Verify both keys in DataDog Organization Settings; re-generate if needed |
| `Credentials (validate): PASS` but all exports fail | Application Key is wrong — `/api/v1/validate` checks only the API Key | Verify the Application Key separately; the validate endpoint does not check it |
| `curl: (6) Could not resolve host` | Wrong `--site` value, or no internet access | Confirm the correct region and test with the connectivity check command above |
| `000` from connectivity test | Firewall or proxy blocking HTTPS to DataDog | Check outbound HTTPS rules; if behind a proxy, set `https_proxy` in your environment |
| `No response` for a dedicated cluster site | Dedicated org on US1 infrastructure — no separate cluster API | Use `--site app` instead; the API is at `https://api.datadoghq.com` |
| `No response` after `--site` with unknown short code | Warning is printed; constructed URL may not exist | Pass the full app URL or domain instead: `--site hx-eu.datadoghq.eu` |
| **PowerShell:** `No response` for a known dedicated cluster | TLS certificate not trusted by Windows certificate store | Add `-SkipCertCheck` to the PowerShell command — use only on trusted networks |
| **PowerShell:** `API call failed (0)` for all endpoints | File write error masked as API failure (pre-2.0.1) | Upgrade to the current version; the actual error is now shown |
| **PowerShell:** Output goes to wrong location | Relative `--output` path (e.g., `../folder`) resolved by .NET against `C:\Windows\` | Fixed in 2.0.1 — relative paths are now resolved against PowerShell's working directory |
| `jq: command not found` | `jq` not installed | `brew install jq` (macOS) or `apt-get install jq` (Linux) |
| `$'\r': command not found` | Windows CRLF line endings | Run the script once — it auto-converts itself and re-executes |
| Archive not created at end | `tar` failed — usually disk space | Ensure 500 MB+ free; use `--output` to point to a partition with more space |
| `Rate limited (429)` logged repeatedly | Very large environment hitting API burst limits | Script retries automatically; if it keeps failing, reduce concurrency by running with `--skip-metrics --skip-users` first and re-running those categories separately |
| `Not found (404)` for individual items | Item was deleted between list fetch and detail fetch | Expected for fast-changing environments — the manifest will reflect the actual export count |
| SLO export very slow | Large SLO count — SLO API paginates at 1 000 per page | Expected behavior; the script handles pagination automatically |
| Log index volume missing from analytics | Application Key missing `usage_read` | Add `usage_read` scope; the analytics file will contain `"error": "Usage Metering API not available"` when this scope is absent |

### Debug Mode

Add `--debug` to enable detailed diagnostic output:

- Every API call is logged with endpoint, HTTP status code, and body
- Rate limit retries and backoff timing are shown
- All `jq` processing steps emit intermediate counts

Debug output goes to both the console and `export.log` inside the archive.

---

## Where to Upload the Archive

After the export completes, upload the `.tar.gz` archive to:

- **DMA Curator Server** — recommended for all exports; enables migration planning, team collaboration, and full reporting
- **DMA DataDog App** — suitable for ad-hoc analysis of smaller archives

The `manifest.json` embedded in the archive tells the DMA Server which script version produced it and validates that the expected data categories are present.

---

## Release Notes

### v2.0.1 — PowerShell improvements and site flexibility

- **PowerShell script added** — `dma-datadog-export.ps1` provides feature parity with the bash script on Windows, with no external dependencies beyond `tar.exe` (built into Windows 10 build 1803+)
- **Flexible `--site` / `-Site` parameter** — now accepts short codes (`app`, `us1`, `us3`, `us5`, `eu`, `ap1`), site domains (`hx-eu.datadoghq.eu`), or full app URLs (`https://hx-eu.datadoghq.eu`). The API URL is derived automatically. `app` is the default and is equivalent to `us1`
- **Unknown site warning** — passing an unrecognised short code now prints a warning and suggests `--site app` for dedicated orgs on US1 infrastructure
- **TLS 1.2 enforcement (PowerShell)** — PowerShell 5.1 defaults to TLS 1.0/1.1; the script now enforces TLS 1.2 explicitly to support dedicated cluster endpoints
- **`-SkipCertCheck` (PowerShell)** — new switch to bypass SSL certificate validation for dedicated clusters whose certificate is not trusted by the Windows certificate store
- **Output directory validation (PowerShell)** — if the target output directory does not exist, the script prompts to create it rather than failing silently mid-export
- **Relative path fix (PowerShell)** — relative `--output` paths (e.g., `../Test/Hyland`) are now resolved against PowerShell's working directory instead of the .NET runtime directory (`C:\Windows\`)
- **Improved error messages (PowerShell)** — network-level failures now report the actual exception message rather than `API call failed (0)`, making it easier to distinguish TLS errors, certificate failures, and connectivity problems

### v2.0.0 — REST API rewrite

Complete rewrite from shell-script scraping to a clean REST API-only implementation.

- **All data collected via authenticated REST API** — no browser automation or UI scraping
- **Usage Analytics** — new `--usage` / `--usage-period` flags backed by the Audit Trail v2 API and Usage Metering v1 API; produces dashboard views, monitor trigger counts, log index volume, modification history, and unused-asset identification
- **SLO pagination** — SLO endpoint is fully paginated (1 000 per page) to handle large SLO inventories without truncation
- **Exponential backoff** — automatic retry with backoff on `429 Too Many Requests` and `5xx` server errors (up to 3 retries per call)
- **Export manifest** — `manifest.json` records script version, org metadata, item counts, API call statistics, and duration
- **SHA-256 checksum** — `.sha256` file written alongside the archive for integrity verification
- **CRLF auto-fix** — script detects Windows line endings on startup and converts in-place before re-executing
- **Multi-region support** — `--site` flag supports `us1`, `us3`, `us5`, `eu`, `ap1`, and `--custom-url` for mock API testing
