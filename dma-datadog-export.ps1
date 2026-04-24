#Requires -Version 5.1
<#
.SYNOPSIS
    DMA DataDog Export Script v2.0.0 (PowerShell)

.DESCRIPTION
    REST API-Only Data Collection for DataDog to Dynatrace Migration.
    Collects configurations, dashboards, alerts, monitors, SLOs, synthetic
    tests, log pipelines, and other observability data from your DataDog
    environment via REST API to enable migration planning and execution
    using the DMA (Dynatrace Migration Assistant) application.

    Zero external dependencies  - no curl, jq, or Python required.
    Requires Windows 10 build 1803+ or Windows 11 (for built-in tar.exe).

.PARAMETER ApiKey
    DataDog API Key (DD-API-KEY). Required.

.PARAMETER AppKey
    DataDog Application Key (DD-APPLICATION-KEY). Required.

.PARAMETER Site
    DataDog site identifier. Default: app (equivalent to us1).
    Accepts a short code (app/us1, us3, us5, eu, ap1), a site domain (hxp.datadoghq.com,
    hx-eu.datadoghq.eu), or a full app URL (https://app.datadoghq.com, https://hx-eu.datadoghq.eu).

.PARAMETER CustomUrl
    Custom API base URL (for testing with a mock API).

.PARAMETER Output
    Export destination directory. Default: .\datadog-export.

.PARAMETER Name
    Export name prefix. Default: datadog-export-{TIMESTAMP}.

.PARAMETER SkipDashboards
    Skip dashboard export.

.PARAMETER SkipMonitors
    Skip monitor/alert export.

.PARAMETER SkipLogs
    Skip log pipeline and index export.

.PARAMETER SkipSynthetics
    Skip synthetic test export.

.PARAMETER SkipSlos
    Skip SLO export.

.PARAMETER SkipMetrics
    Skip metrics metadata export.

.PARAMETER SkipUsers
    Skip users, roles, and teams export.

.PARAMETER Usage
    Enable usage analytics (Audit Trail + Usage Metering).
    Requires audit_trail_read and usage_read scopes on the Application Key.

.PARAMETER UsagePeriod
    Lookback period for usage analytics, e.g. 30d or 90d. Default: 90d.
    Implies -Usage.

.PARAMETER NonInteractive
    Skip all interactive prompts. Requires -ApiKey and -AppKey.

.PARAMETER DebugMode
    Enable verbose debug logging.

.PARAMETER SkipCertCheck
    Disable SSL certificate validation. Use for dedicated clusters whose certificate
    is not trusted by Windows (e.g. corporate CA or hostname mismatch). Use with care.

.PARAMETER ShowHelp
    Show this help message and exit.

.EXAMPLE
    # Interactive mode
    .\dma-datadog-export.ps1

.EXAMPLE
    # Non-interactive, US1 (default)
    .\dma-datadog-export.ps1 -ApiKey "abc123" -AppKey "xyz789"

.EXAMPLE
    # EU region with usage analytics
    .\dma-datadog-export.ps1 -ApiKey "abc123" -AppKey "xyz789" -Site eu -Usage

.EXAMPLE
    # Skip logs and users for a faster partial export
    .\dma-datadog-export.ps1 -ApiKey "abc123" -AppKey "xyz789" -SkipLogs -SkipUsers

.EXAMPLE
    # Custom lookback period (30 days)
    .\dma-datadog-export.ps1 -ApiKey "abc123" -AppKey "xyz789" -UsagePeriod 30d
#>

param(
    [string]$ApiKey       = "",
    [string]$AppKey       = "",
    [string]$Site         = "app",
    [string]$CustomUrl    = "",
    [string]$Output       = "",
    [string]$Name         = "",
    [switch]$SkipDashboards,
    [switch]$SkipMonitors,
    [switch]$SkipLogs,
    [switch]$SkipSynthetics,
    [switch]$SkipSlos,
    [switch]$SkipMetrics,
    [switch]$SkipUsers,
    [switch]$Usage,
    [string]$UsagePeriod  = "90d",
    [switch]$NonInteractive,
    [switch]$DebugMode,
    [switch]$TestAccess,
    [switch]$SkipCertCheck,
    [switch]$ShowHelp
)

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

$script:ScriptVersion     = "2.0.0"
$script:ScriptName        = "DMA DataDog Export"

$script:DatadogApiKey     = $ApiKey
$script:DatadogAppKey     = $AppKey
$script:DatadogSite       = $Site
$script:SiteExplicitlySet = $PSBoundParameters.ContainsKey('Site')
$script:DatadogApiUrl     = ""
$script:CustomApiUrl      = $CustomUrl

$script:ExportDir         = $Output
$script:ExportName        = $Name
$script:Timestamp         = ""
$script:LogFile           = ""
$script:OutputDir         = ""

# PS 5.1 defaults to TLS 1.0/1.1; dedicated DataDog clusters require TLS 1.2+
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($SkipCertCheck) {
    Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class DmaTrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
    [Net.ServicePointManager]::CertificatePolicy = New-Object DmaTrustAllCerts
    Write-Warning "SSL certificate validation is disabled (-SkipCertCheck). Use only on trusted networks."
}

$script:OrgName           = ""
$script:OrgId             = ""

$script:SkipDashboardsF   = $SkipDashboards.IsPresent
$script:SkipMonitorsF     = $SkipMonitors.IsPresent
$script:SkipLogsF         = $SkipLogs.IsPresent
$script:SkipSyntheticsF   = $SkipSynthetics.IsPresent
$script:SkipSlosF         = $SkipSlos.IsPresent
$script:SkipMetricsF      = $SkipMetrics.IsPresent
$script:SkipUsersF        = $SkipUsers.IsPresent
$script:CollectUsage      = $Usage.IsPresent
$script:UsagePeriodValue  = $UsagePeriod

$script:TotalSteps        = 0
$script:CurrentStep       = 0
$script:StartTime         = $null
$script:ErrorsEncountered = 0
$script:TotalApiCalls     = 0
$script:SuccessfulApiCalls = 0
$script:FailedApiCalls    = 0

# =============================================================================
# HELPERS
# =============================================================================

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($script:LogFile) {
        "[$ts] [$Level] $Message" | Out-File -FilePath $script:LogFile -Append -Encoding utf8
    }
    switch ($Level) {
        'INFO'    { Write-Host "  i $Message" -ForegroundColor Cyan }
        'SUCCESS' { Write-Host "  v $Message" -ForegroundColor Green }
        'WARNING' { Write-Host "  ! $Message" -ForegroundColor Yellow }
        'ERROR'   { Write-Host "  x $Message" -ForegroundColor Red; $script:ErrorsEncountered++ }
        'DEBUG'   { if ($DebugMode) { Write-Host "  [DEBUG] $Message" -ForegroundColor DarkGray } }
    }
}

function Write-Header {
    param([string]$Text)
    $line = '=' * 80
    $pad  = [Math]::Max(0, [int]((80 - $Text.Length) / 2))
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host (' ' * $pad + $Text) -ForegroundColor White
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    $script:CurrentStep++
    Write-Host ""
    Write-Host ("-" * 80) -ForegroundColor Blue
    Write-Host " [$($script:CurrentStep)/$($script:TotalSteps)] $Text" -ForegroundColor White
    Write-Host ("-" * 80) -ForegroundColor Blue
}

function Show-Progress {
    param([int]$Current, [int]$Total)
    if ($Total -le 0) { return }
    $pct    = [int]($Current * 100 / $Total)
    $filled = [int](50 * $Current / $Total)
    $bar    = ('#' * $filled) + ('-' * (50 - $filled))
    Write-Host "`r  Progress: [$bar] $pct%" -NoNewline -ForegroundColor Cyan
}

function Write-JsonFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-JsonObject {
    param([string]$Path, $Object)
    Write-JsonFile -Path $Path -Content ($Object | ConvertTo-Json -Depth 100 -Compress)
}

# =============================================================================
# DATADOG API
# =============================================================================

function Get-DataDogApiUrl {
    if ($script:CustomApiUrl) { return $script:CustomApiUrl }

    $site = $script:DatadogSite

    # Short-code aliases (backwards compat)
    switch ($site) {
        'app' { $site = 'datadoghq.com' }
        'us1' { $site = 'datadoghq.com' }
        'us3' { $site = 'us3.datadoghq.com' }
        'us5' { $site = 'us5.datadoghq.com' }
        'eu'  { $site = 'datadoghq.eu' }
        'ap1' { $site = 'ap1.datadoghq.com' }
    }

    # If a full URL was passed, extract the domain
    if ($site -match '://') {
        $site = ($site -replace '^https?://', '').TrimEnd('/')
    }

    # If value contains a dot, it's a domain — strip 'app.' prefix and build API URL
    if ($site -match '\.') {
        $site = $site -replace '^app\.', ''
        return "https://api.$site"
    }

    # Unknown short code — warn the user; dedicated orgs on US1 should use -Site app
    Write-Warning "Unknown site identifier '$($script:DatadogSite)'. Known codes: app/us1, us3, us5, eu, ap1."
    Write-Warning "If this is a dedicated org on US1 infrastructure, use -Site app instead. Use -CustomUrl to set an explicit API URL."
    return "https://api.$site.datadoghq.com"
}

function Invoke-DataDogApi {
    param(
        [string]$Method,
        [string]$Endpoint,
        [string]$OutputFile = ""
    )

    $script:TotalApiCalls++
    $url = "$($script:DatadogApiUrl)$Endpoint"

    $headers = @{
        'DD-API-KEY'         = $script:DatadogApiKey
        'DD-APPLICATION-KEY' = $script:DatadogAppKey
        'Content-Type'       = 'application/json'
    }

    Write-Log DEBUG "API Call: $Method $url"

    $retryCount = 0
    $maxRetries = 3
    $retryDelay = 5

    while ($retryCount -lt $maxRetries) {
        $response = $null
        try {
            $response = Invoke-WebRequest -Uri $url -Method $Method -Headers $headers `
                -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
        }
        catch {
            $statusCode = 0
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }

            if ($statusCode -eq 429) {
                $retryCount++
                $wait = $retryDelay * $retryCount
                Write-Log WARNING "Rate limited (429). Retry $retryCount/$maxRetries after ${wait}s..."
                Start-Sleep -Seconds $wait
                continue
            }
            elseif ($statusCode -in @(401, 403)) {
                $script:FailedApiCalls++
                Write-Log ERROR "Authentication failed ($statusCode) for: $Endpoint"
                return $null
            }
            elseif ($statusCode -eq 404) {
                $script:FailedApiCalls++
                Write-Log WARNING "Not found (404): $Endpoint"
                return $null
            }
            elseif ($statusCode -in @(500, 502, 503, 504)) {
                $retryCount++
                Write-Log WARNING "Server error ($statusCode). Retry $retryCount/$maxRetries..."
                Start-Sleep -Seconds $retryDelay
                continue
            }
            else {
                $script:FailedApiCalls++
                Write-Log ERROR "Network error ($statusCode) for: $Endpoint - $($_.Exception.Message)"
                return $null
            }
        }

        if ($response) {
            $script:SuccessfulApiCalls++
            Write-Log DEBUG "API call successful: $($response.StatusCode)"
            if ($OutputFile) { Write-JsonFile -Path $OutputFile -Content $response.Content }
            return $response.Content | ConvertFrom-Json
        }
    }

    $script:FailedApiCalls++
    Write-Log ERROR "API call failed after $maxRetries retries: $Endpoint"
    return $null
}

# =============================================================================
# ACCESS TEST
# =============================================================================

function Test-ApiEndpoint {
    param([string]$Endpoint)
    $url     = "$($script:DatadogApiUrl)$Endpoint"
    $headers = @{
        'DD-API-KEY'         = $script:DatadogApiKey
        'DD-APPLICATION-KEY' = $script:DatadogAppKey
        'Content-Type'       = 'application/json'
    }
    try {
        $resp = Invoke-WebRequest -Uri $url -Method GET -Headers $headers `
            -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
        return @{ OK = $true; StatusCode = [int]$resp.StatusCode; Data = ($resp.Content | ConvertFrom-Json) }
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return @{ OK = $false; StatusCode = $code; Data = $null }
    }
}

function Format-AuthError {
    param([int]$Code)
    switch ($Code) {
        401     { return "Auth failed - invalid API key (401)" }
        403     { return "Permission denied - missing scope (403)" }
        404     { return "Not found (404)" }
        0       { return "No response - check network/firewall" }
        default { return "Error ($Code)" }
    }
}

function Show-AccessTestTable {
    param([PSCustomObject[]]$Results)
    $cw = 38; $sw = 6; $dw = 40
    $sep = "+" + ("-" * ($cw + 2)) + "+" + ("-" * ($sw + 2)) + "+" + ("-" * ($dw + 2)) + "+"
    Write-Host $sep
    Write-Host ("| {0,-$cw} | {1,-$sw} | {2,-$dw} |" -f "Category", "Status", "Detail")
    Write-Host $sep
    foreach ($r in $Results) {
        $color  = switch ($r.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'White' } }
        $cat    = if ($r.Category.Length -gt $cw) { $r.Category.Substring(0, $cw) } else { $r.Category }
        $status = if ($r.Status.Length   -gt $sw) { $r.Status.Substring(0, $sw)   } else { $r.Status   }
        $detail = if ($r.Detail.Length   -gt $dw) { $r.Detail.Substring(0, $dw)   } else { $r.Detail   }
        Write-Host ("| {0,-$cw} | {1,-$sw} | {2,-$dw} |" -f $cat, $status, $detail) -ForegroundColor $color
    }
    Write-Host $sep
    Write-Host ""
}

function Invoke-TestAccess {
    Write-Header "DataDog API Access Test"
    Write-Host "  Endpoint : $($script:DatadogApiUrl)" -ForegroundColor Cyan
    Write-Host "  Checking credentials and permissions for all export categories..." -ForegroundColor White
    Write-Host ""

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    function Add-Result($Cat, $St, $Det) {
        $results.Add([PSCustomObject]@{ Category = $Cat; Status = $St; Detail = $Det })
    }

    # ── Credentials ──────────────────────────────────────────────────────────
    Write-Host "  Testing credentials..." -NoNewline -ForegroundColor Cyan
    $r = Test-ApiEndpoint "/api/v1/validate"
    if ($r.OK) {
        Add-Result "Credentials (validate)" "PASS" "Authenticated OK"
        Write-Host " PASS" -ForegroundColor Green
    } else {
        Add-Result "Credentials (validate)" "FAIL" (Format-AuthError $r.StatusCode)
        Write-Host " FAIL" -ForegroundColor Red
        Show-AccessTestTable $results.ToArray()
        Write-Host "  Cannot proceed - verify your API Key and Application Key." -ForegroundColor Red
        return
    }

    # ── Organization ─────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/org"
    $orgDetail = if ($r.OK -and $r.Data.org.name) { "$($r.Data.org.name)" } `
                 elseif ($r.OK) { "Retrieved OK" } `
                 else { Format-AuthError $r.StatusCode }
    Add-Result "Organization" $(if ($r.OK) { "PASS" } else { "WARN" }) $orgDetail

    # ── Dashboards ───────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/dashboard"
    if ($r.OK) { Add-Result "Dashboards" "PASS" "$(@($r.Data.dashboards).Count) found" }
    else       { Add-Result "Dashboards" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Monitors ─────────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/monitor"
    if ($r.OK) { Add-Result "Monitors / Alerts" "PASS" "$(if ($r.Data -is [array]) { $r.Data.Count } else { 0 }) found" }
    else       { Add-Result "Monitors / Alerts" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Log Pipelines ─────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/logs/config/pipelines"
    if ($r.OK) { Add-Result "Log Pipelines" "PASS" "$(if ($r.Data -is [array]) { $r.Data.Count } else { 0 }) found" }
    else       { Add-Result "Log Pipelines" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Log Indexes ───────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/logs/config/indexes"
    if ($r.OK) { Add-Result "Log Indexes" "PASS" "$(@($r.Data.indexes).Count) found" }
    else       { Add-Result "Log Indexes" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Synthetic Tests ───────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/synthetics/tests"
    if ($r.OK) { Add-Result "Synthetic Tests" "PASS" "$(@($r.Data.tests).Count) found" }
    else       { Add-Result "Synthetic Tests" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── SLOs ──────────────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/slo?limit=10"
    if ($r.OK) { Add-Result "SLOs" "PASS" "$(@($r.Data.data).Count) found (first page)" }
    else       { Add-Result "SLOs" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Downtimes ─────────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v2/downtime"
    if ($r.OK) { Add-Result "Downtimes" "PASS" "$(@($r.Data.data).Count) found" }
    else       { Add-Result "Downtimes" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Metrics ───────────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/metrics"
    if ($r.OK) { Add-Result "Metrics Metadata" "PASS" "$(@($r.Data.metrics).Count) active metrics" }
    else       { Add-Result "Metrics Metadata" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Webhooks ──────────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v1/integration/webhooks/configuration/webhooks"
    if ($r.OK) { Add-Result "Webhooks" "PASS" "$(if ($r.Data -is [array]) { $r.Data.Count } else { 0 }) found" }
    else       { Add-Result "Webhooks" "WARN" (Format-AuthError $r.StatusCode) }

    # ── Users ─────────────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v2/users"
    if ($r.OK) { Add-Result "Users" "PASS" "$(@($r.Data.data).Count) found" }
    else       { Add-Result "Users" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Roles ─────────────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v2/roles"
    if ($r.OK) { Add-Result "Roles" "PASS" "$(@($r.Data.data).Count) found" }
    else       { Add-Result "Roles" "FAIL" (Format-AuthError $r.StatusCode) }

    # ── Teams ─────────────────────────────────────────────────────────────────
    $r = Test-ApiEndpoint "/api/v2/team"
    if ($r.OK) { Add-Result "Teams" "PASS" "$(@($r.Data.data).Count) found" }
    else       { Add-Result "Teams" "WARN" (Format-AuthError $r.StatusCode) }

    # ── Usage Analytics: Audit Trail (audit_trail_read) ───────────────────────
    $r = Test-ApiEndpoint "/api/v2/audit/events?page[limit]=1"
    if ($r.OK) {
        Add-Result "Usage: Audit Trail (audit_trail_read)" "PASS" "Accessible - --usage will collect views/triggers"
    } elseif ($r.StatusCode -in @(401, 403)) {
        Add-Result "Usage: Audit Trail (audit_trail_read)" "WARN" "Missing scope - --usage analytics will be empty"
    } else {
        Add-Result "Usage: Audit Trail (audit_trail_read)" "WARN" (Format-AuthError $r.StatusCode)
    }

    # ── Usage Analytics: Usage Metering (usage_read) ─────────────────────────
    $fromHr = (Get-Date).AddDays(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH')
    $toHr   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH')
    $r      = Test-ApiEndpoint ('/api/v1/usage/logs_by_index?start_hr={0}&end_hr={1}' -f $fromHr, $toHr)
    if ($r.OK) {
        Add-Result "Usage: Metering (usage_read)" "PASS" "Accessible - log index volume will be collected"
    } elseif ($r.StatusCode -in @(401, 403)) {
        Add-Result "Usage: Metering (usage_read)" "WARN" "Missing scope - index volume will be empty"
    } else {
        Add-Result "Usage: Metering (usage_read)" "WARN" (Format-AuthError $r.StatusCode)
    }

    # ── Results table ─────────────────────────────────────────────────────────
    Show-AccessTestTable $results.ToArray()

    $passCount = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
    $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count

    if ($failCount -gt 0) {
        Write-Host ("  {0} FAILED, {1} warnings, {2} passed." -f $failCount, $warnCount, $passCount) -ForegroundColor Red
        Write-Host "  Fix FAIL items before running a full export." -ForegroundColor Yellow
        Write-Host "  Missing scopes produce silent empty results - the export will appear to succeed but data will be missing." -ForegroundColor Yellow
    } elseif ($warnCount -gt 0) {
        Write-Host ("  All critical checks passed. {0} optional scope(s) not available." -f $warnCount) -ForegroundColor Yellow
        Write-Host "  WARN items affect --usage analytics only. The main export will complete normally." -ForegroundColor White
    } else {
        Write-Host ("  All {0} checks passed. Ready to run a full export." -f $passCount) -ForegroundColor Green
    }
    Write-Host ""
}

function Test-DataDogCredentials {
    Write-Step "Validating DataDog API Credentials"
    Write-Log INFO "Site: $($script:DatadogSite)"
    Write-Log INFO "API URL: $($script:DatadogApiUrl)"

    if ($null -eq (Invoke-DataDogApi -Method GET -Endpoint "/api/v1/validate")) {
        Write-Log ERROR "Failed to validate API credentials  - check your API Key and Application Key"
        return $false
    }
    Write-Log SUCCESS "API credentials validated successfully"

    $org = Invoke-DataDogApi -Method GET -Endpoint "/api/v1/org"
    if ($org) {
        $script:OrgName = if ($org.org.name) { $org.org.name } else { "Unknown" }
        $script:OrgId   = if ($org.org.id)   { "$($org.org.id)" } else { "Unknown" }
        Write-Log INFO "Organization: $($script:OrgName)"
        Write-Log INFO "Organization ID: $($script:OrgId)"
    }
    return $true
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

function Export-Dashboards {
    if ($script:SkipDashboardsF) { Write-Log INFO "Skipping dashboards (-SkipDashboards)"; return }
    Write-Step "Exporting Dashboards"
    $dir = Join-Path $script:OutputDir "dashboards"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Log INFO "Fetching dashboard list..."
    $list = Invoke-DataDogApi -Method GET -Endpoint "/api/v1/dashboard" -OutputFile (Join-Path $dir "_list.json")
    if ($null -eq $list) { Write-Log ERROR "Failed to fetch dashboard list"; return }

    $items = if ($list.dashboards) { @($list.dashboards) } else { @() }
    Write-Log SUCCESS "Found $($items.Count) dashboards"
    $i = 0
    foreach ($d in $items) {
        $i++; Show-Progress $i $items.Count
        Invoke-DataDogApi -Method GET -Endpoint "/api/v1/dashboard/$($d.id)" `
            -OutputFile (Join-Path $dir "dashboard-$($d.id).json") | Out-Null
    }
    if ($items.Count -gt 0) { Write-Host ""; Write-Log SUCCESS "Exported $($items.Count) dashboards" }
}

function Export-Monitors {
    if ($script:SkipMonitorsF) { Write-Log INFO "Skipping monitors (-SkipMonitors)"; return }
    Write-Step "Exporting Monitors/Alerts"
    $dir = Join-Path $script:OutputDir "monitors"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Log INFO "Fetching monitor list..."
    $list = Invoke-DataDogApi -Method GET -Endpoint "/api/v1/monitor" -OutputFile (Join-Path $dir "_list.json")
    if ($null -eq $list) { Write-Log ERROR "Failed to fetch monitor list"; return }

    $items = if ($list -is [array]) { $list } else { @() }
    Write-Log SUCCESS "Found $($items.Count) monitors"
    $i = 0
    foreach ($m in $items) {
        $i++; Show-Progress $i $items.Count
        Invoke-DataDogApi -Method GET -Endpoint "/api/v1/monitor/$($m.id)" `
            -OutputFile (Join-Path $dir "monitor-$($m.id).json") | Out-Null
    }
    if ($items.Count -gt 0) { Write-Host ""; Write-Log SUCCESS "Exported $($items.Count) monitors" }
}

function Export-LogsConfig {
    if ($script:SkipLogsF) { Write-Log INFO "Skipping log configurations (-SkipLogs)"; return }
    Write-Step "Exporting Log Configurations"

    $pipDir = Join-Path $script:OutputDir "logs\pipelines"
    $idxDir = Join-Path $script:OutputDir "logs\indexes"
    New-Item -ItemType Directory -Path $pipDir -Force | Out-Null
    New-Item -ItemType Directory -Path $idxDir -Force | Out-Null

    Write-Log INFO "Fetching log pipelines..."
    $pipelines = Invoke-DataDogApi -Method GET -Endpoint "/api/v1/logs/config/pipelines" `
        -OutputFile (Join-Path $pipDir "_list.json")
    if ($pipelines) {
        $items = if ($pipelines -is [array]) { $pipelines } else { @() }
        Write-Log SUCCESS "Found $($items.Count) log pipelines"
        $i = 0
        foreach ($p in $items) {
            $i++; Show-Progress $i $items.Count
            Invoke-DataDogApi -Method GET -Endpoint "/api/v1/logs/config/pipelines/$($p.id)" `
                -OutputFile (Join-Path $pipDir "pipeline-$($p.id).json") | Out-Null
        }
        if ($items.Count -gt 0) { Write-Host ""; Write-Log SUCCESS "Exported $($items.Count) log pipelines" }
    } else { Write-Log WARNING "Failed to fetch log pipelines" }

    Write-Log INFO "Fetching log indexes..."
    $idxData = Invoke-DataDogApi -Method GET -Endpoint "/api/v1/logs/config/indexes" `
        -OutputFile (Join-Path $idxDir "_list.json")
    if ($idxData) {
        $items = if ($idxData.indexes) { @($idxData.indexes) } else { @() }
        Write-Log SUCCESS "Found $($items.Count) log indexes"
        $i = 0
        foreach ($idx in $items) {
            $i++; Show-Progress $i $items.Count
            $safe = $idx.name -replace '[/\\]', '_'
            Invoke-DataDogApi -Method GET -Endpoint "/api/v1/logs/config/indexes/$($idx.name)" `
                -OutputFile (Join-Path $idxDir "index-${safe}.json") | Out-Null
        }
        if ($items.Count -gt 0) { Write-Host ""; Write-Log SUCCESS "Exported $($items.Count) log indexes" }
    } else { Write-Log WARNING "Failed to fetch log indexes" }
}

function Export-Synthetics {
    if ($script:SkipSyntheticsF) { Write-Log INFO "Skipping synthetic tests (-SkipSynthetics)"; return }
    Write-Step "Exporting Synthetic Tests"
    $dir = Join-Path $script:OutputDir "synthetics"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Log INFO "Fetching synthetic tests..."
    $data = Invoke-DataDogApi -Method GET -Endpoint "/api/v1/synthetics/tests" `
        -OutputFile (Join-Path $dir "_list.json")
    if ($null -eq $data) { Write-Log ERROR "Failed to fetch synthetic tests"; return }

    $items = if ($data.tests) { @($data.tests) } else { @() }
    Write-Log SUCCESS "Found $($items.Count) synthetic tests"
    $i = 0
    foreach ($t in $items) {
        $i++; Show-Progress $i $items.Count
        Invoke-DataDogApi -Method GET -Endpoint "/api/v1/synthetics/tests/$($t.public_id)" `
            -OutputFile (Join-Path $dir "test-$($t.public_id).json") | Out-Null
    }
    if ($items.Count -gt 0) { Write-Host ""; Write-Log SUCCESS "Exported $($items.Count) synthetic tests" }
}

function Export-SLOs {
    if ($script:SkipSlosF) { Write-Log INFO "Skipping SLOs (-SkipSlos)"; return }
    Write-Step "Exporting SLOs"
    $dir = Join-Path $script:OutputDir "slos"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Log INFO "Fetching SLOs..."
    $allSlos = [System.Collections.Generic.List[object]]::new()
    $offset = 0; $limit = 1000
    do {
        $data = Invoke-DataDogApi -Method GET -Endpoint ('/api/v1/slo?offset={0}&limit={1}' -f $offset, $limit)
        if ($null -eq $data) { Write-Log ERROR "Failed to fetch SLOs at offset $offset"; break }
        $batch = if ($data.data) { @($data.data) } else { @() }
        foreach ($s in $batch) { $allSlos.Add($s) }
        $offset += $limit
    } while ($batch.Count -eq $limit)

    Write-JsonObject -Path (Join-Path $dir "_list.json") -Object @{ data = $allSlos.ToArray() }
    Write-Log SUCCESS "Found $($allSlos.Count) SLOs"
    $i = 0
    foreach ($slo in $allSlos) {
        $i++; Show-Progress $i $allSlos.Count
        Invoke-DataDogApi -Method GET -Endpoint "/api/v1/slo/$($slo.id)" `
            -OutputFile (Join-Path $dir "slo-$($slo.id).json") | Out-Null
    }
    if ($allSlos.Count -gt 0) { Write-Host ""; Write-Log SUCCESS "Exported $($allSlos.Count) SLOs" }
}

function Export-Downtimes {
    Write-Step "Exporting Downtimes"
    $dir = Join-Path $script:OutputDir "downtimes"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Log INFO "Fetching downtimes..."
    $data = Invoke-DataDogApi -Method GET -Endpoint "/api/v2/downtime" `
        -OutputFile (Join-Path $dir "_list.json")
    if ($null -eq $data) { Write-Log WARNING "Failed to fetch downtimes"; return }

    $items = if ($data.data) { @($data.data) } else { @() }
    Write-Log SUCCESS "Found $($items.Count) downtimes"
    $i = 0
    foreach ($dt in $items) {
        $i++; Show-Progress $i $items.Count
        Invoke-DataDogApi -Method GET -Endpoint "/api/v2/downtime/$($dt.id)" `
            -OutputFile (Join-Path $dir "downtime-$($dt.id).json") | Out-Null
    }
    if ($items.Count -gt 0) { Write-Host ""; Write-Log SUCCESS "Exported $($items.Count) downtimes" }
}

function Export-Metrics {
    if ($script:SkipMetricsF) { Write-Log INFO "Skipping metrics (-SkipMetrics)"; return }
    Write-Step "Exporting Metrics Metadata"
    $dir = Join-Path $script:OutputDir "metrics"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Log INFO "Fetching active metrics list..."
    $data = Invoke-DataDogApi -Method GET -Endpoint "/api/v1/metrics" `
        -OutputFile (Join-Path $dir "_list.json")
    if ($data) {
        $count = if ($data.metrics) { $data.metrics.Count } else { 0 }
        Write-Log SUCCESS "Found $count active metrics (last 24 hours)"
        Write-Log INFO "Metrics list saved (individual metadata export would be time-consuming)"
    } else { Write-Log WARNING "Failed to fetch metrics list" }
}

function Export-Webhooks {
    Write-Step "Exporting Webhook Integrations"
    $dir = Join-Path $script:OutputDir "webhooks"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Log INFO "Fetching webhook configurations..."
    $data = Invoke-DataDogApi -Method GET `
        -Endpoint "/api/v1/integration/webhooks/configuration/webhooks" `
        -OutputFile (Join-Path $dir "_list.json")
    if ($null -eq $data) { Write-Log WARNING "Failed to fetch webhooks"; return }

    $items = if ($data -is [array]) { $data } else { @() }
    Write-Log SUCCESS "Found $($items.Count) webhooks"
    $i = 0
    foreach ($wh in $items) {
        $i++; Show-Progress $i $items.Count
        $safe = $wh.name -replace '[/ ]', '-'
        Invoke-DataDogApi -Method GET `
            -Endpoint "/api/v1/integration/webhooks/configuration/webhooks/$($wh.name)" `
            -OutputFile (Join-Path $dir "webhook-${safe}.json") | Out-Null
    }
    if ($items.Count -gt 0) { Write-Host ""; Write-Log SUCCESS "Exported $($items.Count) webhooks" }
}

function Export-UsersTeams {
    if ($script:SkipUsersF) { Write-Log INFO "Skipping users and teams (-SkipUsers)"; return }
    Write-Step "Exporting Users, Roles, and Teams"
    $dir = Join-Path $script:OutputDir "users"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    @(
        @{ Endpoint = "/api/v2/users"; File = "users.json"; Key = "data"; Label = "users" },
        @{ Endpoint = "/api/v2/roles"; File = "roles.json"; Key = "data"; Label = "roles" },
        @{ Endpoint = "/api/v2/team";  File = "teams.json"; Key = "data"; Label = "teams" }
    ) | ForEach-Object {
        Write-Log INFO "Fetching $($_.Label)..."
        $result = Invoke-DataDogApi -Method GET -Endpoint $_.Endpoint `
            -OutputFile (Join-Path $dir $_.File)
        if ($result) {
            $count = if ($result.($_.Key)) { $result.($_.Key).Count } else { 0 }
            Write-Log SUCCESS "Exported $count $($_.Label)"
        } else { Write-Log WARNING "Failed to fetch $($_.Label)" }
    }
}

# =============================================================================
# USAGE ANALYTICS
# =============================================================================

function Get-UsageFromTimestamp {
    $days = 90
    if ($script:UsagePeriodValue -match '^(\d+)d$') { $days = [int]$Matches[1] }
    return (Get-Date).AddDays(-$days).ToUniversalTime().ToString('yyyy-MM-ddT00:00:00Z')
}

function Get-UsageToTimestamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddT23:59:59Z')
}

function Invoke-AuditTrailQuery {
    param([string]$FilterQuery)

    $from      = Get-UsageFromTimestamp
    $to        = Get-UsageToTimestamp
    $limit     = 1000
    $allEvents = [System.Collections.Generic.List[object]]::new()
    $cursor    = ""
    $page      = 0
    $maxPages  = 20

    Write-Log DEBUG "Audit Trail query: $FilterQuery (from=$from to=$to)"

    $encQ    = [System.Uri]::EscapeDataString($FilterQuery)
    $encFrom = [System.Uri]::EscapeDataString($from)
    $encTo   = [System.Uri]::EscapeDataString($to)

    while ($page -lt $maxPages) {
        $ep = '/api/v2/audit/events?filter[query]={0}&filter[from]={1}&filter[to]={2}&page[limit]={3}' -f $encQ, $encFrom, $encTo, $limit
        if ($cursor) { $ep += ('&page[cursor]={0}' -f [System.Uri]::EscapeDataString($cursor)) }

        $data = Invoke-DataDogApi -Method GET -Endpoint $ep
        if ($null -eq $data) { Write-Log WARNING "Audit Trail query failed on page $page"; break }

        $pageEvents = if ($data.data) { @($data.data) } else { @() }
        if ($pageEvents.Count -eq 0) { break }

        foreach ($evt in $pageEvents) { $allEvents.Add($evt) }
        $cursor = if ($data.meta -and $data.meta.page -and $data.meta.page.after) {
            $data.meta.page.after
        } else { "" }
        $page++
        Write-Log DEBUG "  Page $page`: $($pageEvents.Count) events (total: $($allEvents.Count))"
        if (-not $cursor) { break }
    }

    Write-Log DEBUG "Audit Trail collected $($allEvents.Count) events"
    return $allEvents
}

function Collect-DashboardViews {
    Write-Log INFO "Collecting dashboard view analytics..."
    $events  = Invoke-AuditTrailQuery '@type:audit @evt.name:"Dashboard Viewed"'
    $grouped = $events | Group-Object { $_.attributes.asset.id } | ForEach-Object {
        $g      = $_.Group
        $emails = @($g | ForEach-Object { $_.attributes.usr.email } | Sort-Object -Unique)
        $lastTs = ($g | Sort-Object { $_.attributes.timestamp } | Select-Object -Last 1).attributes.timestamp
        [PSCustomObject]@{
            dashboard_id   = $g[0].attributes.asset.id
            dashboard_name = $g[0].attributes.asset.name
            view_count     = $g.Count
            unique_users   = $emails.Count
            last_viewed    = $lastTs
            users          = $emails
        }
    } | Sort-Object -Property view_count -Descending
    Write-JsonObject -Path (Join-Path $script:OutputDir "analytics\dashboard_views.json") -Object @($grouped)
    Write-Log SUCCESS "Dashboard views: $(@($grouped).Count) dashboards with activity"
}

function Collect-MonitorTriggers {
    Write-Log INFO "Collecting monitor trigger analytics..."
    $events  = Invoke-AuditTrailQuery '@type:audit @asset.type:monitor @evt.name:("Monitor Alert Triggered" OR "Monitor Resolved")'
    $grouped = $events | Group-Object { $_.attributes.asset.id } | ForEach-Object {
        $g        = $_.Group
        $triggers = @($g | Where-Object { $_.attributes.evt.name -eq 'Monitor Alert Triggered' }).Count
        $resolves = @($g | Where-Object { $_.attributes.evt.name -eq 'Monitor Resolved' }).Count
        $lastTs   = ($g | Sort-Object { $_.attributes.timestamp } | Select-Object -Last 1).attributes.timestamp
        [PSCustomObject]@{
            monitor_id     = $g[0].attributes.asset.id
            monitor_name   = $g[0].attributes.asset.name
            trigger_count  = $triggers
            resolve_count  = $resolves
            total_events   = $g.Count
            last_triggered = $lastTs
        }
    } | Sort-Object -Property trigger_count -Descending
    Write-JsonObject -Path (Join-Path $script:OutputDir "analytics\monitor_triggers.json") -Object @($grouped)
    Write-Log SUCCESS "Monitor triggers: $(@($grouped).Count) monitors with activity"
}

function Collect-LogIndexVolume {
    Write-Log INFO "Collecting log index volume analytics..."
    $fromHr = (Get-UsageFromTimestamp).Substring(0, 13)
    $toHr   = (Get-UsageToTimestamp).Substring(0, 13)
    $data   = Invoke-DataDogApi -Method GET -Endpoint ('/api/v1/usage/logs_by_index?start_hr={0}&end_hr={1}' -f $fromHr, $toHr)
    $outFile = Join-Path $script:OutputDir "analytics\log_index_volume.json"

    if ($data -and $data.usage) {
        $totals = @{}
        foreach ($day in $data.usage) {
            if (-not $day.by_index) { continue }
            foreach ($entry in $day.by_index) {
                $n = $entry.index_name
                if (-not $totals.ContainsKey($n)) {
                    $totals[$n] = @{ total_event_count = 0; total_retention_event_count = 0; days_active = 0 }
                }
                $totals[$n].total_event_count           += if ($entry.event_count)           { $entry.event_count }           else { 0 }
                $totals[$n].total_retention_event_count += if ($entry.retention_event_count) { $entry.retention_event_count } else { 0 }
                $totals[$n].days_active++
            }
        }
        $indexes = $totals.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{
                index_name                   = $_.Key
                total_event_count            = $_.Value.total_event_count
                total_retention_event_count  = $_.Value.total_retention_event_count
                days_active                  = $_.Value.days_active
            }
        } | Sort-Object -Property total_event_count -Descending
        Write-JsonObject -Path $outFile -Object ([PSCustomObject]@{
            period  = @{ from = $fromHr; to = $toHr }
            indexes = @($indexes)
        })
        Write-Log SUCCESS "Log index volume: $(@($indexes).Count) indexes with usage data"
    } else {
        Write-JsonFile -Path $outFile -Content '{"indexes":[],"error":"Usage Metering API not available"}'
        Write-Log WARNING "Log index volume: Usage Metering API not available (needs usage_read permission)"
    }
}

function Collect-MonitorModifications {
    Write-Log INFO "Collecting monitor modification analytics..."
    $events  = Invoke-AuditTrailQuery '@type:audit @asset.type:monitor @evt.name:("Monitor Created" OR "Monitor Modified")'
    $grouped = $events | Group-Object { $_.attributes.asset.id } | ForEach-Object {
        $g        = $_.Group
        $created  = @($g | Where-Object { $_.attributes.evt.name -eq 'Monitor Created' }).Count
        $modified = @($g | Where-Object { $_.attributes.evt.name -eq 'Monitor Modified' }).Count
        $lastTs   = ($g | Sort-Object { $_.attributes.timestamp } | Select-Object -Last 1).attributes.timestamp
        $editors  = @($g | ForEach-Object { $_.attributes.usr.email } | Sort-Object -Unique)
        [PSCustomObject]@{
            monitor_id         = $g[0].attributes.asset.id
            monitor_name       = $g[0].attributes.asset.name
            modification_count = $g.Count
            created_events     = $created
            modified_events    = $modified
            last_modified      = $lastTs
            modified_by        = $editors
        }
    } | Sort-Object -Property modification_count -Descending
    Write-JsonObject -Path (Join-Path $script:OutputDir "analytics\monitor_modifications.json") -Object @($grouped)
    Write-Log SUCCESS "Monitor modifications: $(@($grouped).Count) monitors with changes"
}

function Collect-UnusedDashboards {
    Write-Log INFO "Identifying unused dashboards..."
    $dashDir = Join-Path $script:OutputDir "dashboards"
    $allIds  = @(Get-ChildItem -Path $dashDir -Filter "dashboard-*.json" -ErrorAction SilentlyContinue |
        ForEach-Object { ($_ | Get-Content -Raw | ConvertFrom-Json).id } | Where-Object { $_ } | Sort-Object)
    $outFile = Join-Path $script:OutputDir "analytics\unused_dashboards.json"

    if ($allIds.Count -eq 0) {
        Write-Log WARNING "No dashboards found to cross-reference"
        Write-JsonFile -Path $outFile -Content '{"unused_dashboards":[],"total_dashboards":0,"unused_count":0}'
        return
    }

    $viewedIds = @()
    $vf = Join-Path $script:OutputDir "analytics\dashboard_views.json"
    if (Test-Path $vf) {
        $viewedIds = @(Get-Content $vf -Raw | ConvertFrom-Json |
            ForEach-Object { $_.dashboard_id } | Where-Object { $_ } | Sort-Object)
    }

    $unusedIds = @($allIds | Where-Object { $_ -notin $viewedIds })
    $unusedList = $unusedIds | ForEach-Object {
        $title = "Unknown"
        $f = Join-Path $dashDir "dashboard-${_}.json"
        if (Test-Path $f) { $d = Get-Content $f -Raw | ConvertFrom-Json; if ($d.title) { $title = $d.title } }
        [PSCustomObject]@{ dashboard_id = $_; title = $title }
    }
    Write-JsonObject -Path $outFile -Object ([PSCustomObject]@{
        unused_dashboards = @($unusedList)
        total_dashboards  = $allIds.Count
        viewed_count      = $allIds.Count - $unusedIds.Count
        unused_count      = $unusedIds.Count
        usage_period      = $script:UsagePeriodValue
    })
    Write-Log SUCCESS "Unused dashboards: $($unusedIds.Count) of $($allIds.Count) never viewed in $($script:UsagePeriodValue)"
}

function Collect-UnusedMonitors {
    Write-Log INFO "Identifying unused monitors..."
    $monDir = Join-Path $script:OutputDir "monitors"
    $allIds = @(Get-ChildItem -Path $monDir -Filter "monitor-*.json" -ErrorAction SilentlyContinue |
        ForEach-Object { "$((Get-Content $_.FullName -Raw | ConvertFrom-Json).id)" } | Where-Object { $_ } | Sort-Object)
    $outFile = Join-Path $script:OutputDir "analytics\unused_monitors.json"

    if ($allIds.Count -eq 0) {
        Write-Log WARNING "No monitors found to cross-reference"
        Write-JsonFile -Path $outFile -Content '{"unused_monitors":[],"total_monitors":0,"unused_count":0}'
        return
    }

    $triggeredIds = @()
    $tf = Join-Path $script:OutputDir "analytics\monitor_triggers.json"
    if (Test-Path $tf) {
        $triggeredIds = @(Get-Content $tf -Raw | ConvertFrom-Json |
            ForEach-Object { "$($_.monitor_id)" } | Where-Object { $_ } | Sort-Object)
    }

    $unusedIds  = @($allIds | Where-Object { $_ -notin $triggeredIds })
    $unusedList = $unusedIds | ForEach-Object {
        $name = "Unknown"
        $f = Join-Path $monDir "monitor-${_}.json"
        if (Test-Path $f) { $m = Get-Content $f -Raw | ConvertFrom-Json; if ($m.name) { $name = $m.name } }
        [PSCustomObject]@{ monitor_id = $_; name = $name }
    }
    Write-JsonObject -Path $outFile -Object ([PSCustomObject]@{
        unused_monitors = @($unusedList)
        total_monitors  = $allIds.Count
        triggered_count = $allIds.Count - $unusedIds.Count
        unused_count    = $unusedIds.Count
        usage_period    = $script:UsagePeriodValue
    })
    Write-Log SUCCESS "Unused monitors: $($unusedIds.Count) of $($allIds.Count) never triggered in $($script:UsagePeriodValue)"
}

function Invoke-UsageAnalytics {
    if (-not $script:CollectUsage) { return }
    Write-Step "Collecting Usage Analytics"
    Write-Log INFO "Usage period: $($script:UsagePeriodValue)"
    Write-Log INFO "APIs used: Audit Trail (v2), Usage Metering (v1)"

    New-Item -ItemType Directory -Path (Join-Path $script:OutputDir "analytics") -Force | Out-Null

    Collect-DashboardViews
    Collect-MonitorTriggers
    Collect-LogIndexVolume
    Collect-MonitorModifications
    Collect-UnusedDashboards
    Collect-UnusedMonitors

    $aDir    = Join-Path $script:OutputDir "analytics"
    $getCount = { param($file, $prop)
        try {
            $c = Get-Content (Join-Path $aDir $file) -Raw | ConvertFrom-Json
            if ($prop) { $c.$prop } else { @($c).Count }
        } catch { 0 }
    }
    Write-JsonObject -Path (Join-Path $aDir "_summary.json") -Object ([PSCustomObject]@{
        usage_period = $script:UsagePeriodValue
        from         = Get-UsageFromTimestamp
        to           = Get-UsageToTimestamp
        queries      = [PSCustomObject]@{
            dashboard_views       = [PSCustomObject]@{ dashboards_with_views  = (& $getCount "dashboard_views.json"       $null) }
            monitor_triggers      = [PSCustomObject]@{ monitors_with_triggers = (& $getCount "monitor_triggers.json"      $null) }
            log_index_volume      = [PSCustomObject]@{ indexes_with_data      = (& $getCount "log_index_volume.json"      "indexes") }
            monitor_modifications = [PSCustomObject]@{ monitors_modified      = (& $getCount "monitor_modifications.json" $null) }
            unused_dashboards     = [PSCustomObject]@{ count                  = (& $getCount "unused_dashboards.json"     "unused_count") }
            unused_monitors       = [PSCustomObject]@{ count                  = (& $getCount "unused_monitors.json"       "unused_count") }
        }
    })
    Write-Log SUCCESS "Usage analytics complete  - results in analytics/"
}

# =============================================================================
# MANIFEST
# =============================================================================

function Write-Manifest {
    Write-Step "Generating Export Manifest"

    $count = {
        param([string]$sub, [string]$pat)
        $p = Join-Path $script:OutputDir $sub
        if (Test-Path $p) { (Get-ChildItem -Path $p -Filter $pat -ErrorAction SilentlyContinue).Count } else { 0 }
    }

    $manifest = [PSCustomObject]@{
        export_info = [PSCustomObject]@{
            script_name      = $script:ScriptName
            script_version   = $script:ScriptVersion
            export_name      = $script:ExportName
            export_timestamp = $script:Timestamp
            start_time       = $script:StartTime.ToString('yyyy-MM-dd HH:mm:ss')
            end_time         = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            duration_seconds = [int]((Get-Date) - $script:StartTime).TotalSeconds
        }
        datadog_info = [PSCustomObject]@{
            site              = $script:DatadogSite
            api_url           = $script:DatadogApiUrl
            organization_name = $script:OrgName
            organization_id   = $script:OrgId
        }
        export_statistics = [PSCustomObject]@{
            total_api_calls      = $script:TotalApiCalls
            successful_api_calls = $script:SuccessfulApiCalls
            failed_api_calls     = $script:FailedApiCalls
            errors_encountered   = $script:ErrorsEncountered
        }
        exported_items = [PSCustomObject]@{
            dashboards      = (& $count "dashboards"     "dashboard-*.json")
            monitors        = (& $count "monitors"       "monitor-*.json")
            log_pipelines   = (& $count "logs\pipelines" "pipeline-*.json")
            log_indexes     = (& $count "logs\indexes"   "index-*.json")
            synthetic_tests = (& $count "synthetics"     "test-*.json")
            slos            = (& $count "slos"           "slo-*.json")
            downtimes       = (& $count "downtimes"      "downtime-*.json")
            webhooks        = (& $count "webhooks"       "webhook-*.json")
        }
        directories = [PSCustomObject]@{
            dashboards = "dashboards/"; monitors  = "monitors/";  logs      = "logs/"
            synthetics = "synthetics/"; slos      = "slos/";      downtimes = "downtimes/"
            metrics    = "metrics/";    webhooks  = "webhooks/";  users     = "users/"
        }
    }

    Write-JsonObject -Path (Join-Path $script:OutputDir "manifest.json") -Object $manifest
    Write-Log SUCCESS "Manifest created: manifest.json"

    $ei = $manifest.exported_items
    $es = $manifest.export_statistics
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host " Export Summary" -ForegroundColor White
    Write-Host ("=" * 60) -ForegroundColor Cyan
    "Dashboards:{0}","Monitors/Alerts:{0}","Log Pipelines:{0}","Log Indexes:{0}",
    "Synthetic Tests:{0}","SLOs:{0}","Downtimes:{0}","Webhooks:{0}" |
        ForEach-Object { $_ } |
        ForEach-Object -Begin { $vals = $ei.dashboards,$ei.monitors,$ei.log_pipelines,$ei.log_indexes,
                                         $ei.synthetic_tests,$ei.slos,$ei.downtimes,$ei.webhooks; $idx = 0 } `
                       -Process { Write-Host ("  {0,-35} {1,8}" -f ($_ -replace '\{0\}',''), $vals[$idx]) -ForegroundColor White; $idx++ }
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ("  {0,-35} {1,8}" -f "Total API Calls:", $es.total_api_calls)      -ForegroundColor White
    Write-Host ("  {0,-35} {1,8}" -f "Successful:",      $es.successful_api_calls) -ForegroundColor Green
    Write-Host ("  {0,-35} {1,8}" -f "Failed:",          $es.failed_api_calls)     -ForegroundColor $(if ($es.failed_api_calls -gt 0) { 'Yellow' } else { 'White' })
    Write-Host ("  {0,-35} {1,8}" -f "Errors:",          $es.errors_encountered)   -ForegroundColor $(if ($es.errors_encountered -gt 0) { 'Red' } else { 'White' })
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host ""
}

# =============================================================================
# ARCHIVE
# =============================================================================

function New-ExportArchive {
    Write-Step "Creating Export Archive"
    $archiveName = "$($script:ExportName).tar.gz"
    $archivePath = Join-Path $script:ExportDir $archiveName

    Write-Log INFO "Compressing export directory..."
    Write-Log INFO "Archive: $archiveName"

    try {
        $proc = Start-Process -FilePath "tar" `
            -ArgumentList @("-czf", $archivePath, "-C", $script:ExportDir, $script:ExportName) `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { Write-Log ERROR "tar exited with code $($proc.ExitCode)"; return }

        $size = "{0:N1} MB" -f ((Get-Item $archivePath).Length / 1MB)
        Write-Log SUCCESS "Archive created: $archiveName ($size)"

        Write-Log INFO "Calculating checksum..."
        $hash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLower()
        [System.IO.File]::WriteAllText("$archivePath.sha256",
            "$hash  $archiveName`n", [System.Text.UTF8Encoding]::new($false))
        Write-Log SUCCESS "Checksum: $hash"
    }
    catch { Write-Log ERROR "Failed to create archive: $_" }
}

# =============================================================================
# INTERACTIVE PROMPTS
# =============================================================================

function Read-Credentials {
    if (-not $script:DatadogApiKey) {
        Write-Host ""
        Write-Host "DataDog API Key not provided via command line" -ForegroundColor Yellow
        $script:DatadogApiKey = Read-Host "Enter DataDog API Key"
    }
    if (-not $script:DatadogAppKey) {
        Write-Host ""
        Write-Host "DataDog Application Key not provided via command line" -ForegroundColor Yellow
        $script:DatadogAppKey = Read-Host "Enter DataDog Application Key"
    }
    if (-not $script:CustomApiUrl -and -not $script:SiteExplicitlySet) {
        Write-Host ""
        Write-Host "DataDog Site (default: app, equivalent to us1)" -ForegroundColor Cyan
        Write-Host "  Paste your DataDog app URL or enter a site identifier:" -ForegroundColor DarkGray
        Write-Host "  URL:        https://app.datadoghq.com  or  https://hx-eu.datadoghq.eu" -ForegroundColor DarkGray
        Write-Host "  Short code: app / us1 (default), us3, us5, eu, ap1" -ForegroundColor DarkGray
        $siteInput = Read-Host "Site [app]"
        if ($siteInput) { $script:DatadogSite = $siteInput }
    }
}

# =============================================================================
# MAIN
# =============================================================================

function Main {
    if ($ShowHelp) { Get-Help $PSCommandPath -Detailed; exit 0 }

    if ($PSBoundParameters.ContainsKey('UsagePeriod')) { $script:CollectUsage = $true }

    Clear-Host
    Write-Header "$($script:ScriptName) v$($script:ScriptVersion)"

    Write-Log INFO "Checking system requirements..."
    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        Write-Log ERROR "tar.exe not found. Requires Windows 10 build 1803 or later."
        exit 1
    }
    Write-Log SUCCESS "System requirements met (zero external dependencies)"

    if (-not $NonInteractive) { Read-Credentials }

    if (-not $script:DatadogApiKey -or -not $script:DatadogAppKey) {
        Write-Log ERROR "-ApiKey and -AppKey are required"
        exit 1
    }

    $script:DatadogApiUrl = Get-DataDogApiUrl

    if ($TestAccess) {
        Invoke-TestAccess
        exit 0
    }

    $script:Timestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (-not $script:ExportDir)  { $script:ExportDir  = ".\datadog-export" }
    if (-not $script:ExportName) { $script:ExportName = "datadog-export-$($script:Timestamp)" }

    $resolvedExportDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($script:ExportDir)
    if (-not (Test-Path $resolvedExportDir -PathType Container)) {
        if ($NonInteractive) {
            New-Item -ItemType Directory -Path $resolvedExportDir -Force | Out-Null
            Write-Log SUCCESS "Created output directory: $resolvedExportDir"
        } else {
            Write-Host ""
            Write-Host "  Output directory does not exist:" -ForegroundColor Yellow
            Write-Host "  $resolvedExportDir" -ForegroundColor Yellow
            $answer = Read-Host "  Create it? [Y/n]"
            if ($answer -eq '' -or $answer -match '^[Yy]') {
                New-Item -ItemType Directory -Path $resolvedExportDir -Force | Out-Null
                Write-Log SUCCESS "Created output directory: $resolvedExportDir"
            } else {
                Write-Log ERROR "Output directory does not exist. Aborting."
                exit 1
            }
        }
    }

    $script:ExportDir = $resolvedExportDir
    $script:OutputDir = Join-Path $script:ExportDir $script:ExportName
    $script:LogFile   = Join-Path $script:OutputDir "export.log"

    New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
    $script:StartTime     = Get-Date

    Write-Log INFO "================================"
    Write-Log INFO "Export started: $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log INFO "Script version: $($script:ScriptVersion)"
    Write-Log INFO "Export directory: $($script:OutputDir)"
    Write-Log INFO "================================"

    $script:TotalSteps = 10
    if ($script:SkipDashboardsF) { $script:TotalSteps-- }
    if ($script:SkipMonitorsF)   { $script:TotalSteps-- }
    if ($script:SkipLogsF)       { $script:TotalSteps-- }
    if ($script:SkipSyntheticsF) { $script:TotalSteps-- }
    if ($script:SkipSlosF)       { $script:TotalSteps-- }
    if ($script:SkipMetricsF)    { $script:TotalSteps-- }
    if ($script:SkipUsersF)      { $script:TotalSteps-- }
    if ($script:CollectUsage)    { $script:TotalSteps++ }

    if (-not (Test-DataDogCredentials)) { Write-Log ERROR "Credential validation failed"; exit 1 }

    Export-Dashboards
    Export-Monitors
    Export-LogsConfig
    Export-Synthetics
    Export-SLOs
    Export-Downtimes
    Export-Metrics
    Export-Webhooks
    Export-UsersTeams
    Invoke-UsageAnalytics
    Write-Manifest
    New-ExportArchive

    Write-Host ""
    Write-Header "Export Complete!"
    Write-Host "  Export location : $($script:OutputDir)" -ForegroundColor White
    Write-Host "  Archive         : $(Join-Path $script:ExportDir "$($script:ExportName).tar.gz")" -ForegroundColor White
    Write-Host "  Log file        : $($script:LogFile)" -ForegroundColor White

    if ($script:ErrorsEncountered -gt 0) {
        Write-Host ""
        Write-Host "  Completed with $($script:ErrorsEncountered) error(s)  - review: $($script:LogFile)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Upload the archive to DMA (DataDog Edition) application" -ForegroundColor White
    Write-Host "  2. Review the export manifest: $($script:OutputDir)\manifest.json" -ForegroundColor White
    Write-Host "  3. Begin migration planning in Dynatrace" -ForegroundColor White
    Write-Host ""

    $completedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Log INFO "Export completed at $completedAt"
}

Main
