# DataDog Usage Analytics: What the Script Collects and What It Cannot

> **Companion to [README.md](README.md).** This document focuses exclusively on usage analytics — what data the export script collects automatically, what it cannot collect (and why), and how to gather the remaining data manually from the DataDog UI.

---

## What the Script Collects Automatically

Run the export with the `--usage` / `-Usage` flag. The following files are written to the `analytics/` folder of the export archive:

| File | API Used | Contents |
|------|----------|----------|
| `monitor_triggers.json` | Audit Trail v2 (bash) / Events API v2 (PowerShell) | Per-monitor trigger and recovery counts for the usage period |
| `log_index_volume.json` | Usage Metering v1 (bash) / v2 (PowerShell) | Per-index ingested event counts aggregated over the usage period |
| `monitor_modifications.json` | Audit Trail v2 | Monitor change history — who created or modified each monitor and when |
| `unused_monitors.json` | Cross-reference | Monitors that never triggered in the usage period |
| `_summary.json` | — | Aggregate counts for all of the above, plus UI query guidance |

Required Application Key scopes: `audit_trail_read` (for monitor modifications) and `usage_read` (for log index volume). Monitor trigger data comes from the Audit Trail (bash — needs `audit_trail_read`) or the Events API (PowerShell — needs Events read access).

---

## What the Script Cannot Collect

### Dashboard View Counts

DataDog exposes **no public API for per-dashboard view counts or per-user access history.** The two scripts handle this differently:

- **PowerShell** does not attempt it: `analytics/dashboard_views.json` always contains `{"error": "not_available"}`, and `unused_dashboards.json` reports `"view_data_available": false`.
- **Bash** attempts a best-effort proxy by querying the Audit Trail for `"Dashboard Viewed"` events. This is populated **only if your DataDog plan records those events** in the Audit Trail; on plans that do not, the file is an empty array.

Because reliable view data is not generally available, always collect the **Dashboards → Popular Dashboards** list from the UI manually (below) and share it with your DMA consultant.

---

## Collecting Usage Data Manually from the DataDog UI

When the script cannot collect usage data automatically, gather it directly from DataDog and share it with your DMA consultant alongside the export archive.

---

### Dashboard Activity

There is no DataDog API for dashboard view counts. The closest proxies available in the UI are:

**Option A — Popular Dashboards list**

1. Go to **Dashboards** in the left-hand navigation.
2. The top of the list shows a **Popular Dashboards** section — these are the most-accessed dashboards in your organization over the recent period.
3. Take a screenshot or note the titles.

**Option B — Audit Trail (configuration changes only)**

1. Go to **Organization Settings → Audit Trail**.
2. Set the date range to your desired usage period (e.g., last 90 days).
3. Apply the filter:
   ```
   @asset.type:dashboard
   ```
4. This shows dashboards that were *created or modified* — a proxy for "is this dashboard actively maintained?" rather than "is it being viewed?"
5. Use the **Download** button to export the results as CSV.

> If knowing which dashboards are actively viewed is critical, ask your DataDog account team — some enterprise plans include extended usage reporting not available via the API.

---

### Monitor Alert Firings

The script collects monitor firing events via the Events API. If `monitor_triggers.json` shows lower counts than expected, verify or supplement with the following:

**Events Explorer**

1. Go to **Events → Explorer** in the left-hand navigation.
2. Set the date range to match your usage period.
3. Apply the filter:
   ```
   sources:monitors
   ```
4. Click **Group by** in the aggregation bar and select **Monitor** to see trigger counts per monitor.
5. Use the **Export** button to download the results.

**DataDog Notebook query**

Open a new DataDog Notebook, add a **Timeseries** widget, and enter:
```
events("sources:monitors").rollup("count").by("monitor_id").last("30d")
```
Adjust the time selector to match your usage period. Export the chart or data table from the widget menu.

---

### Log Index Volume

The script collects log index ingestion data via the Usage Metering v2 API. If `log_index_volume.json` is empty (the Application Key is missing the `usage_read` scope), pull this data from the DataDog UI instead:

**Built-in usage dashboard**

1. Go to **Logs** in the left-hand navigation, then **Log Management**.
2. Open the **"Log Management - Estimated Usage"** dashboard (pre-built by DataDog).
3. Navigate to the **Indexed Logs** section — it shows per-index ingested event counts for the selected time period.
4. Use the dashboard's export or screenshot controls to save the data.

**DataDog Notebook query**

Open a new DataDog Notebook, add a **Timeseries** widget, and enter:
```
sum:datadog.estimated_usage.logs.ingested_events{*} by {index_name}.rollup(sum, 86400)
```
Set the time range to your usage period (e.g., last 90 days). The chart shows daily ingestion volume per index. Export the data table from the widget menu.

---

### Monitor Configuration Changes

The script collects monitor modification history via the Audit Trail API. If `monitor_modifications.json` is empty (missing `audit_trail_read` scope), pull this from the UI:

1. Go to **Organization Settings → Audit Trail**.
2. Set the date range to your usage period.
3. Apply the filter:
   ```
   @asset.type:monitor @action:(created modified deleted)
   ```
4. The table shows which monitors were created, modified, or deleted — by whom and when.
5. Use the **Download** button to export as CSV.

---

## Sharing Supplementary Data with Your DMA Consultant

Collect the following from the DataDog UI and share them alongside the `.tar.gz` export archive:

| Data Point | How to Collect | Format |
|------------|---------------|--------|
| Dashboard view activity | Popular Dashboards list (Dashboards → Popular) — **no CSV/JSON export available**; DataDog does not expose view counts via API or UI export | Screenshot or manual list only |
| Dashboard config changes | Audit Trail → `@asset.type:dashboard` → Download button | CSV export |
| Monitor trigger counts | Events Explorer → `sources:monitors` → group by monitor → Export button | CSV export or screenshot |
| Log index volume | "Log Management - Estimated Usage" dashboard or Notebook query | CSV export or screenshot |
| Monitor change history | Audit Trail → `@asset.type:monitor @action:(created modified deleted)` → Download button | CSV export |

> **Why dashboard view activity cannot be exported:** DataDog's Popular Dashboards list is driven by internal, non-public telemetry. There is no API endpoint, Notebook metric, or UI export button that surfaces per-dashboard view counts. If precise view data is essential for migration scoping, ask your DataDog account team — some enterprise plans include an Advanced Usage Attribution add-on that provides this data, but it is not universally available.
