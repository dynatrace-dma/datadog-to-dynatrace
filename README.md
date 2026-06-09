# DMA DataDog Export Script

**Version**: 2.0.2
**Last Updated**: June 2026

> **Developed for Dynatrace One by Enterprise Solutions & Architecture**
> *An ACE Services Division of Dynatrace*

---

## Overview

Two export scripts are provided — choose the one that matches your environment:

| Script | Platform | Requirements |
|--------|----------|--------------|
| `dma-datadog-export.sh` | Linux, macOS, WSL | bash, curl, awk, tar — **all pre-installed on macOS and standard on Linux. No `jq`, no Python, nothing to install.** |
| `dma-datadog-export.ps1` | Windows (PowerShell 5.1+) | tar.exe (Windows 10 build 1803+) — no external dependencies |

Both scripts are **zero-install**: they rely only on tools that ship with the OS. Both produce the same output archive structure and are feature-equivalent for the core export. A few **usage-analytics** details differ by platform — see the platform-divergence note in [Opt-In: Usage Analytics](#opt-in-usage-analytics-default-off) below. The bash script is preferred on Linux/macOS; the PowerShell script is preferred on Windows.

> **No `jq` required (as of v2.0.2).** The bash script parses and builds all JSON in pure bash + POSIX `awk` — it no longer depends on `jq`. If you used an earlier version that required `brew install jq`, that step is gone.

> **DataDog SaaS only.** DataDog does not offer self-hosted versions, so there is no on-premises variant of this script.

---

## Step-by-Step Operator Guide (start here)

This is the complete path from a clean machine to an uploaded archive. Each step links to its detailed section. **Do them in order** — the most common cause of a bad export is skipping Step 4.

> **The one rule that prevents 90% of problems:** a missing *read* scope makes DataDog return `200 OK` with **empty data**, not an error. So an export can finish "successfully" yet be missing dashboards/monitors/etc. **Step 4 (`--test-access`) is how you catch this before it happens.** Don't skip it.

### Step 1 — Get the script onto a machine with internet access

Any laptop, jump host, or CI runner that can reach the DataDog API works ([details](#where-to-run)). On macOS/Linux:

```bash
chmod +x dma-datadog-export.sh
```

Confirm the (pre-installed) tooling is present — `curl --version`, `awk --version`, `tar --version`. Nothing to install ([prerequisites](#prerequisites)).

### Step 2 — Create two DataDog credentials *with the right scopes*

In **Organization Settings**, create an **API Key** and an **Application Key** ([details](#what-you-need)). The Application Key carries the permissions — grant it **all Tier-1 scopes** ([scope tiers](#application-key-scopes--required-vs-optional)). Add Tier-2 scopes only if you plan to use `--usage`.

### Step 3 — Find your DataDog region

Read it from the URL in your DataDog browser tab and map it to a `--site` value ([regions](#datadog-regions)). US1 is the default (`app`).

### Step 4 — Verify access (`--test-access`) — **the critical gate**

```bash
./dma-datadog-export.sh --api-key "<API>" --app-key "<APP>" --site <SITE> --test-access
```

This writes **nothing** — it probes every category and prints a PASS/WARN/FAIL table ([how to read it](#verify-access-and-permissions)). **Do not proceed until there are zero `FAIL` rows** and every category you expect to contain data shows a non-zero count. `WARN` is fine if it's only on `--usage` scopes you don't need.

### Step 5 — Decide scope

- **Just config?** Run the defaults.
- **Want usage/cost intelligence** (views, triggers, log volume, unused assets)? Add `--usage` ([what it does](#how-usage-analytics-estimates-asset-usage)) — and make sure Tier-2 scopes passed in Step 4.
- **Huge org / only need some categories?** Use `--skip-*` flags ([reference](#scope--skip-flags)).

### Step 6 — Run the export

```bash
./dma-datadog-export.sh --api-key "<API>" --app-key "<APP>" --site <SITE> --output ./datadog-export
```

What you'll see and how long it takes: [Running the Export](#running-the-export) and [Typical Runtimes](#typical-runtimes).

### Step 7 — Verify the export is *complete* (not just "finished")

"It finished" ≠ "it's complete." Check:
1. **No `⚠ POTENTIAL SILENT FAILURES DETECTED` box** was printed at the end.
2. **`manifest.json`** shows the right org and non-zero counts where you expect data.
3. The detail folders contain per-item files (e.g. `dashboards/dashboard-*.json`), not just `_list.json`.

If anything looks empty, fix the scope (Step 2), re-test (Step 4), re-run.

### Step 8 — Hand off the archive

Verify the checksum and upload the `.tar.gz` ([where to upload](#where-to-upload-the-archive)).

---

## Before You Begin

### Prerequisites

**Bash script (`dma-datadog-export.sh`)**

| Requirement | Detail |
|-------------|--------|
| **Platform** | Linux, macOS, or WSL |
| **Shell** | bash 3.2+ (works with macOS default bash) |
| **curl** | `curl --version` to verify (pre-installed on macOS; standard on Linux) |
| **awk** | `awk --version` (or just `awk` — any POSIX awk: BSD awk on macOS, gawk/mawk on Linux). Used for all JSON processing |
| **tar** | `tar --version` to verify |
| **Network** | HTTPS access to your DataDog API endpoint (see regions below) |
| **Disk space** | 500 MB+ free in the working directory |

> `jq` is **not** required. All JSON is handled in pure bash + awk, so the script runs on a clean macOS/Linux box with nothing to install.

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

### Application Key Scopes — Required vs Optional

Scopes fall into **three tiers**. Tier 1 is **mandatory**; Tiers 2 and 3 are **optional** and degrade gracefully — a missing optional scope skips just that data, it never aborts the export. When in doubt, run [`--test-access`](#verify-access-and-permissions) — it reports exactly which scopes you have.

#### Tier 1 — Required (core export — grant ALL of these)

A missing Tier-1 scope is the **most dangerous** failure mode: DataDog returns `200 OK` with an **empty list** (not a `403`) when a read scope is absent, so the export *looks* successful but silently omits that category. Always confirm these with `--test-access`.

| Scope | Unlocks |
|-------|---------|
| `dashboards_read` | Dashboard configurations |
| `monitors_read` | Monitor and alert configurations |
| `org_management` | Organization name/metadata (manifest) |
| `logs_read_config` | Log pipeline and log index configurations |
| `synthetics_read` | Synthetic test configurations |
| `slos_read` | SLO configurations |
| `monitors_downtime` | Downtime configurations |
| `metrics_read` | Metric metadata |
| `integrations_read` | Webhook integrations |
| `user_access_read` | Users and roles |
| `teams_read` | Teams |

#### Tier 2 — Optional: Usage Analytics (only needed with `--usage`)

| Scope | Unlocks |
|-------|---------|
| `audit_trail_read` | Dashboard views, monitor triggers, and monitor modification history (Audit Trail API) |
| `usage_read` | Per-index log ingestion volume (Usage Metering API) |

> If you run `--usage` without these, the run completes but the corresponding analytics files are **empty** — no error is raised. This is the #1 reason the DMA Explorer shows zero usage data. If you are not running `--usage`, you do not need these.

#### Tier 3 — Optional: Additional Resources (best-effort, auto-skipped)

The always-on [Additional Resources](#additional-resources-defaults-on-best-effort) pass sweeps ~25 extra config endpoints. Each is **best-effort**: if the key lacks that product's read scope (HTTP `401/403`) or the org doesn't use it (`404`), that single file is **skipped with a logged note** — never fatal, never counted in the manifest. You do **not** need to grant these for a successful migration export; grant them only if you want that extra config captured.

| If you want… | Grant (representative) |
|---|---|
| APM retention filters / spans metrics | `apm_read` |
| RUM applications | `rum_apps_read` (or RUM read) |
| Security monitoring rules | `security_monitoring_rules_read` |
| Incidents | `incident_read` |
| Service catalog / reference tables / notebooks / powerpacks | covered by `dashboards_read` / catalog read |
| Cloud integrations (AWS/Azure/GCP/PagerDuty), host tags | `integrations_read` |

> Tier-3 scopes vary by DataDog plan and naming; rather than chase them, just run the export and check the log — anything skipped is clearly listed, and it's safe to ignore unless that resource matters to your migration.

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

Detail-heavy categories (dashboards, log pipelines, synthetic tests) are fetched **concurrently** — bash via `curl --parallel`, PowerShell via a runspace pool — with per-endpoint concurrency caps tuned to each endpoint's rate limit and automatic 429 back-off. Override the caps with the `DASHBOARD_CONCURRENCY` (default 10), `SYNTHETICS_CONCURRENCY` (10), and `LOGS_CONCURRENCY` (5) environment variables on either platform.

### Additional Resources (defaults ON, best-effort)

Beyond the core categories above, both scripts also collect the following single-call configuration resources. Each is **best-effort**: a resource gated by a missing scope (HTTP 401/403) or unavailable on the org (HTTP 404) is logged and skipped — never fatal, and never counted in the manifest item totals.

| Group | Resources |
|-------|-----------|
| Content | Notebooks, Dashboard lists, Powerpacks |
| Monitoring | SLO corrections, Monitor config policies |
| Logs | Archives, Log metrics, Custom destinations, Restriction queries |
| APM / RUM | APM retention filters, Spans metrics, RUM applications |
| Synthetics | Global variables, Private locations |
| Security / catalog | Security monitoring rules, Service definitions (Software Catalog), Reference tables, Incidents |
| Org / access | Authn mappings |
| Integrations | AWS, Azure, GCP (legacy + STS), PagerDuty |
| Infrastructure | Host tags |

### Opt-In: Usage Analytics (default OFF)

Enable with `--usage`. Requires `audit_trail_read` and `usage_read` scopes.

| File | Source API (bash / PowerShell) | DMA Explorer Use |
|------|--------------------------------|-----------------|
| `analytics/dashboard_views.json` | Audit Trail v2 / *not collected* | Dashboard view counts (see note below) |
| `analytics/monitor_triggers.json` | Audit Trail v2 / Events API v2 | Monitor trigger and resolve counts |
| `analytics/log_index_volume.json` | Usage Metering v1 / Usage Metering v2 | Per-index event counts |
| `analytics/monitor_modifications.json` | Audit Trail v2 | Monitor change history, modified-by |
| `analytics/unused_dashboards.json` | Cross-reference | Dashboards with zero views (only when view data is available) |
| `analytics/unused_monitors.json` | Cross-reference | Monitors that never triggered in the usage period |
| `analytics/_summary.json` | — | Aggregate counts for all of the above |

The usage period defaults to 90 days. Override with `--usage-period 30d` or set the `USAGE_PERIOD` environment variable.

> **Platform divergence in usage analytics.** Three files behave differently between the two scripts:
> - **`dashboard_views.json`** — DataDog exposes no public API for per-dashboard view counts. The **bash** script attempts a best-effort proxy from Audit Trail `"Dashboard Viewed"` events (populated only if your DataDog plan records them; otherwise an empty array). The **PowerShell** script does not attempt this and always writes `{"error": "not_available"}`. Either way, collect the **Dashboards → Popular Dashboards** list from the UI manually — see [USAGE.md](USAGE.md).
> - **`monitor_triggers.json`** — derived from the **Audit Trail v2** API (bash) vs. the **Events v2** API (PowerShell). The PowerShell path needs Events read access rather than `audit_trail_read` for this file.
> - **`log_index_volume.json`** — collected via Usage Metering **v1** (`/api/v1/usage/logs_by_index`, bash) vs. **v2** (`/api/v2/usage/hourly_usage`, PowerShell).

### What Is NOT Collected

- API keys, Application Keys, or session tokens
- Actual log or event data (only pipeline and index configuration)
- SSL certificates or private keys
- User passwords

---

## How Usage Analytics Estimates Asset Usage

When you pass `--usage`, the script doesn't just copy configuration — it estimates **which assets are actually used** so you can prioritise (and prune) during migration. There is no single "usage" API in DataDog, so the script derives these estimates from **two** different DataDog APIs and then cross-references them with the exported inventory.

### A. The Audit Trail API — "who did what, when"

`GET /api/v2/audit/events` is DataDog's activity log. The script issues **filtered queries** over the lookback window (the `--usage-period`, default **90 days**), paginating with a cursor (up to 20 pages × 1000 events per query), then **groups the events by asset and counts them** (in pure bash/awk). Three signals come from here:

| Analytics file | Audit query (`@evt.name:`) | Per-asset aggregation → meaning |
|----------------|----------------------------|--------------------------------|
| `dashboard_views.json` | `"Dashboard Viewed"` | grouped by dashboard → **view_count**, **unique_users** (distinct viewer emails), **last_viewed** → *is anyone actually looking at this dashboard?* |
| `monitor_triggers.json` | `"Monitor Alert Triggered"` / `"Monitor Resolved"` | grouped by monitor → **trigger_count**, **resolve_count**, **total_events**, **last_triggered** → *does this monitor ever actually fire, or is it dormant?* |
| `monitor_modifications.json` | `"Monitor Created"` / `"Monitor Modified"` | grouped by monitor → **modification_count**, **created/modified counts**, **last_modified**, **modified_by** → *is this monitor actively maintained, and by whom?* |

So "usage" for dashboards and monitors is **estimated from audit activity**: a dashboard with many `Dashboard Viewed` events from several users is clearly in use; one with none is a pruning candidate.

### B. The Usage Metering API — "how much volume / cost"

`GET /api/v1/usage/logs_by_index` is DataDog's billing/metering data. The API caps each request to ~one month, so the script **paginates by month** across the window and **sums per index**:

| Analytics file | Source | Per-index aggregation → meaning |
|----------------|--------|--------------------------------|
| `log_index_volume.json` | Usage Metering (`logs_by_index`) | **total_event_count**, **total_retention_event_count**, **days_active**, sorted by volume → *which log indexes carry real ingest volume (cost) vs. near-empty ones you can consolidate?* |

### C. Cross-reference → unused assets

The script then combines the **full exported inventory** (every dashboard/monitor it pulled) with the **activity signals** above:

| Analytics file | How it's derived |
|----------------|------------------|
| `unused_dashboards.json` | dashboards present in the export **minus** those with any `Dashboard Viewed` event in the window → dashboards never viewed |
| `unused_monitors.json` | monitors present in the export **minus** those with any trigger event → monitors that never fired |
| `_summary.json` | roll-up counts for all of the above (what the DMA Explorer reads first) |

### What "estimate" means — important caveats

- **Window-bounded.** Everything is "within the last `--usage-period`" (default 90d), **not all-time**. A monitor that last fired 100 days ago shows as *unused* for a 90-day window. Widen with `--usage-period 180d` if needed.
- **Audit Trail retention.** Events older than your DataDog plan's Audit Trail retention simply aren't there to count — the estimate is only as deep as your retention.
- **Dashboard views are plan-dependent.** DataDog only records `Dashboard Viewed` audit events on some plans. If yours doesn't, `dashboard_views.json` is empty and `unused_dashboards.json` reports `view_data_available: false` (it won't guess). The PowerShell script doesn't attempt dashboard views at all and always writes `not_available` — collect the **Dashboards → Popular Dashboards** list from the UI instead (see [USAGE.md](USAGE.md)).
- **Log volume is metering, not a bill.** `total_event_count` is ingested-event volume per index — a relative cost/activity signal, not a billing-exact figure.

Net: treat these as **decision-support estimates** for "keep / consolidate / drop," not as audited ground truth.

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
| *(n/a)* | `-NonInteractive` | **PowerShell only.** Skip all interactive prompts (requires `-ApiKey` and `-AppKey`). The bash script has no `--non-interactive` flag — passing it errors. To run bash without prompts, simply supply `--api-key`, `--app-key`, and `--site`. |
| *(n/a)* | `-SkipCertCheck` | **PowerShell only.** Disable SSL certificate validation. Use when connecting to a dedicated cluster whose certificate is not trusted by the Windows certificate store. Use only on trusted networks. |
| `--help` | `-ShowHelp` | Show help and exit |

---

## Output Structure

The script creates the following directory layout and then compresses it into a `.tar.gz` archive:

Files marked **(additional)** come from the best-effort Additional Resources pass and are present only when the org has that data and the key has the scope.

```
datadog-export/
└── datadog-export-{TIMESTAMP}/
    ├── dashboards/
    │   ├── _list.json
    │   ├── dashboard-{id}.json
    │   └── lists.json                  (additional — dashboard lists)
    ├── monitors/
    │   ├── _list.json
    │   ├── monitor-{id}.json
    │   └── config_policies.json        (additional)
    ├── logs/
    │   ├── pipelines/
    │   │   ├── _list.json
    │   │   └── pipeline-{id}.json
    │   ├── indexes/
    │   │   ├── _list.json
    │   │   └── index-{name}.json
    │   ├── archives.json               (additional)
    │   ├── metrics.json                (additional)
    │   ├── custom_destinations.json    (additional)
    │   └── restriction_queries.json    (additional)
    ├── synthetics/
    │   ├── _list.json
    │   ├── test-{public_id}.json
    │   ├── global_variables.json       (additional)
    │   └── locations.json              (additional)
    ├── slos/
    │   ├── _list.json
    │   ├── slo-{id}.json
    │   └── corrections.json            (additional)
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
    │   ├── teams.json
    │   └── authn_mappings.json         (additional)
    ├── notebooks/_list.json            (additional)
    ├── powerpacks/_list.json           (additional)
    ├── apm/                            (additional)
    │   ├── retention_filters.json
    │   └── spans_metrics.json
    ├── rum/applications.json           (additional)
    ├── security/monitoring_rules.json  (additional)
    ├── service_catalog/definitions.json (additional)
    ├── reference_tables/_list.json     (additional)
    ├── incidents/_list.json            (additional)
    ├── integrations/                   (additional)
    │   ├── aws.json
    │   ├── azure.json
    │   ├── gcp.json
    │   ├── gcp_sts.json
    │   └── pagerduty.json
    ├── infra/host_tags.json            (additional)
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

The final archive is written to `{output}/{name}.tar.gz` alongside a SHA-256 checksum file (`{name}.tar.gz.sha256`). The `manifest.json` inside the archive records the script version, organization name and ID, item counts per **core** category (the additional resources above are not tallied there), API call statistics, and start/end timestamps.

---

## What to Expect

### Interactive Mode Flow

When run without CLI arguments, the script:

1. Checks that `curl`, `awk`, and `tar` are installed
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
| `awk: command not found` | No awk on PATH (extremely rare — awk is part of POSIX) | Install via your package manager (`apt-get install gawk` / `apk add gawk`). macOS ships awk by default |
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
- Concurrency throttles (`max-parallel=N`) and pagination/aggregation steps emit intermediate counts

Debug output goes to both the console and `export.log` inside the archive.

---

## Where to Upload the Archive

After the export completes, upload the `.tar.gz` archive to:

- **DMA Curator Server** — recommended for all exports; enables migration planning, team collaboration, and full reporting
- **DMA DataDog App** — suitable for ad-hoc analysis of smaller archives

The `manifest.json` embedded in the archive tells the DMA Server which script version produced it and validates that the expected data categories are present.

---

## Release Notes

### v2.0.2 — Zero-dependency bash (jq removed)

- **`jq` is no longer required** by `dma-datadog-export.sh`. All JSON parsing, counting, pagination, aggregation, and emission is now done in pure **bash + POSIX awk** via an embedded JSON layer. The bash script now runs on a clean macOS/Linux box with **nothing to install** (curl, awk, and tar all ship with the OS), matching the PowerShell script's zero-install property.
- **Verified equivalent to the previous jq implementation** by differential testing on identical inputs — byte/semantically identical output across the full export (core + usage analytics) under both **BSD awk (macOS)** and **gawk (Linux)**, plus a real multi-thousand-asset production org.
- **Byte-deterministic processing** — the script forces `LC_ALL=C` so the awk layer is byte-oriented and identical across awk implementations (gawk's UTF-8 locale otherwise diverges on multibyte data).
- **Manifest hardening** — the organization name and other free-text fields are now JSON-escaped in `manifest.json` (quotes/backslashes/unicode can no longer produce invalid JSON).
- **Concurrency** — detail-heavy categories (dashboards, log pipelines, synthetics) are fetched concurrently with per-endpoint caps (`DASHBOARD_CONCURRENCY`/`SYNTHETICS_CONCURRENCY`/`LOGS_CONCURRENCY`) and 429 back-off, plus a best-effort **Additional Resources** pass (~25 extra config endpoints). PowerShell is unchanged this release.

### v2.0.1 — PowerShell improvements and site flexibility

- **PowerShell script added** — `dma-datadog-export.ps1` provides feature parity with the bash script on Windows, with no external dependencies beyond `tar.exe` (built into Windows 10 build 1803+)
- **Flexible `--site` / `-Site` parameter** — now accepts short codes (`app`, `us1`, `us3`, `us5`, `eu`, `ap1`), site domains (`hx-eu.datadoghq.eu`), or full app URLs (`https://hx-eu.datadoghq.eu`). The API URL is derived automatically. `app` is the default and is equivalent to `us1`
- **Unknown site warning** — passing an unrecognised short code now prints a warning and suggests `--site app` for dedicated orgs on US1 infrastructure
- **TLS 1.2 enforcement (PowerShell)** — PowerShell 5.1 defaults to TLS 1.0/1.1; the script now enforces TLS 1.2 explicitly to support dedicated cluster endpoints
- **`-SkipCertCheck` (PowerShell)** — new switch to bypass SSL certificate validation for dedicated clusters whose certificate is not trusted by the Windows certificate store
- **Output directory validation (PowerShell)** — if the target output directory does not exist, the script prompts to create it rather than failing silently mid-export
- **Relative path fix (PowerShell)** — relative `--output` paths (e.g., `..\exports\my-org`) are now resolved against PowerShell's working directory instead of the .NET runtime directory (`C:\Windows\`)
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
