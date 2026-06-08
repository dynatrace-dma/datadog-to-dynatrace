#Requires -Version 5.1
<#
.SYNOPSIS
    DMA DataDog Export Script v2.0.1 (PowerShell)

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

$script:ScriptVersion     = "2.0.1"
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

# Per-endpoint concurrency caps for concurrent fetch-by-ID (parity with bash).
# Tuned to each endpoint's measured x-ratelimit-limit; overridable via env var.
# 5.1-safe: a non-numeric/<=0 env value falls back to the default.
$script:DashboardConcurrency  = if (($env:DASHBOARD_CONCURRENCY  -as [int]) -gt 0) { [int]$env:DASHBOARD_CONCURRENCY }  else { 10 }
$script:SyntheticsConcurrency = if (($env:SYNTHETICS_CONCURRENCY -as [int]) -gt 0) { [int]$env:SYNTHETICS_CONCURRENCY } else { 10 }
$script:LogsConcurrency       = if (($env:LOGS_CONCURRENCY       -as [int]) -gt 0) { [int]$env:LOGS_CONCURRENCY }       else { 5 }

# Silent failure tracking (200 OK but empty results)
$script:EmptyResultsWarnings = @()
$script:SuspiciousEmptyCount = 0

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

function Track-EmptyResult {
    param([string]$ResourceType, [string]$ScopeName)

    $script:SuspiciousEmptyCount++
    $script:EmptyResultsWarnings += @{
        ResourceType = $ResourceType
        ScopeName = $ScopeName
    }

    Write-Log WARNING "[!]  Found 0 $ResourceType (API returned 200 OK)"
    Write-Log WARNING "    This often means the Application Key is missing the '$ScopeName' scope"
    Write-Log WARNING "    Run with -TestAccess to validate all required scopes"
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

    # If value contains a dot, it's a domain - strip 'app.' prefix and build API URL
    if ($site -match '\.') {
        $site = $site -replace '^app\.', ''
        return "https://api.$site"
    }

    # Unknown short code - warn the user; dedicated orgs on US1 should use -Site app
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

# ---------------------------------------------------------------------------
# Concurrent fetch-by-ID via a runspace pool. Parity with bash
# fetch_ids_concurrent. Windows PowerShell 5.1 compatible - RunspacePool, NOT
# ForEach-Object -Parallel (which is PS7+ only).
#
#   Phase 1: dispatch all IDs through a pool throttled to -MaxParallel. Each
#     runspace GETs one URL and writes the body on 2xx, a
#     {"__ratelimited__":429} sentinel on 429, or nothing on other errors.
#   Phase 2: any ID whose file is missing or holds the sentinel is retried
#     sequentially with backoff (429: 10+rand s, 5xx: 3+rand s, <=5 attempts).
#     An ID still failing leaves NO file (never a bogus/sentinel body).
#
# Relies on the process-global ServicePointManager TLS 1.2 + cert policy set at
# script init (inherited by in-process runspaces). Do NOT move those per-call.
#
#   -MaxParallel      in-flight connection cap (throttle)
#   -UrlTemplate      API path containing the literal token __ID__
#   -OutFileTemplate  absolute output path containing the literal token __ID__
#   -Ids              ids to fetch (blank/whitespace entries skipped)
# ---------------------------------------------------------------------------
function Invoke-IdsConcurrent {
    param(
        [int]$MaxParallel,
        [string]$UrlTemplate,
        [string]$OutFileTemplate,
        [string[]]$Ids
    )

    $clean = @($Ids | Where-Object { $_ -and "$_".Trim() -ne "" })
    if ($clean.Count -eq 0) { return }
    if ($MaxParallel -le 0) { $MaxParallel = 8 }

    Write-Log DEBUG "  runspace pool max-parallel=$MaxParallel for $($clean.Count) items"

    $apiBase = $script:DatadogApiUrl
    $apiKey  = $script:DatadogApiKey
    $appKey  = $script:DatadogAppKey

    # Self-contained worker - no access to $script:* (runspaces don't share it).
    $worker = {
        param($Url, $OutFile, $ApiKey, $AppKey)
        $headers = @{
            'DD-API-KEY'         = $ApiKey
            'DD-APPLICATION-KEY' = $AppKey
            'Content-Type'       = 'application/json'
        }
        try {
            $resp = Invoke-WebRequest -Uri $Url -Method GET -Headers $headers `
                -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
            [System.IO.File]::WriteAllText($OutFile, $resp.Content, [System.Text.UTF8Encoding]::new($false))
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 429) {
                [System.IO.File]::WriteAllText($OutFile, '{"__ratelimited__":429}', [System.Text.UTF8Encoding]::new($false))
            }
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $pool.Open()
    $jobs = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($id in $clean) {
            $url = $apiBase + ($UrlTemplate -replace '__ID__', $id)
            $out = ($OutFileTemplate -replace '__ID__', $id)
            $ps  = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($worker).AddArgument($url).AddArgument($out).AddArgument($apiKey).AddArgument($appKey)
            $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }
        foreach ($j in $jobs) {
            try { [void]$j.PS.EndInvoke($j.Handle) } catch { }
            $j.PS.Dispose()
        }
    } finally {
        $pool.Close(); $pool.Dispose()
    }

    # Phase 2 - sequential retry of rate-limited / missing items.
    $headers = @{
        'DD-API-KEY'         = $apiKey
        'DD-APPLICATION-KEY' = $appKey
        'Content-Type'       = 'application/json'
    }
    $retry = @()
    foreach ($id in $clean) {
        $out = ($OutFileTemplate -replace '__ID__', $id)
        if (-not (Test-Path $out)) {
            $retry += $id
        } elseif ((Get-Content -Path $out -Raw) -match '"__ratelimited__":429') {
            Remove-Item $out -Force
            $retry += $id
        }
    }

    if ($retry.Count -gt 0) {
        Write-Log WARNING "  Rate-limited on $($retry.Count) item(s) - retrying with backoff..."
        foreach ($id in $retry) {
            $url = $apiBase + ($UrlTemplate -replace '__ID__', $id)
            $out = ($OutFileTemplate -replace '__ID__', $id)
            $attempt = 0
            while ($attempt -lt 5) {
                try {
                    $resp = Invoke-WebRequest -Uri $url -Method GET -Headers $headers `
                        -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
                    [System.IO.File]::WriteAllText($out, $resp.Content, [System.Text.UTF8Encoding]::new($false))
                    break
                } catch {
                    $code = 0
                    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                    if     ($code -eq 429) { Start-Sleep -Seconds (10 + (Get-Random -Maximum 5)); $attempt++ }
                    elseif ($code -ge 500) { Start-Sleep -Seconds (3 + (Get-Random -Maximum 3));  $attempt++ }
                    else { if (Test-Path $out) { Remove-Item $out -Force }; break }
                }
            }
        }
    }
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

    # -- Credentials ----------------------------------------------------------
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

    # -- Organization ---------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v1/org"
    $orgDetail = if ($r.OK -and $r.Data.org.name) { "$($r.Data.org.name)" } `
                 elseif ($r.OK) { "Retrieved OK" } `
                 else { Format-AuthError $r.StatusCode }
    Add-Result "Organization" $(if ($r.OK) { "PASS" } else { "WARN" }) $orgDetail

    # -- Dashboards -----------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v1/dashboard"
    if ($r.OK) { Add-Result "Dashboards" "PASS" "$(@($r.Data.dashboards).Count) found" }
    else       { Add-Result "Dashboards" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Monitors -------------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v1/monitor"
    if ($r.OK) { Add-Result "Monitors / Alerts" "PASS" "$(if ($r.Data -is [array]) { $r.Data.Count } else { 0 }) found" }
    else       { Add-Result "Monitors / Alerts" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Log Pipelines ---------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v1/logs/config/pipelines"
    if ($r.OK) { Add-Result "Log Pipelines" "PASS" "$(if ($r.Data -is [array]) { $r.Data.Count } else { 0 }) found" }
    else       { Add-Result "Log Pipelines" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Log Indexes -----------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v1/logs/config/indexes"
    if ($r.OK) { Add-Result "Log Indexes" "PASS" "$(@($r.Data.indexes).Count) found" }
    else       { Add-Result "Log Indexes" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Synthetic Tests -------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v1/synthetics/tests"
    if ($r.OK) { Add-Result "Synthetic Tests" "PASS" "$(@($r.Data.tests).Count) found" }
    else       { Add-Result "Synthetic Tests" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- SLOs ------------------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v1/slo?limit=10"
    if ($r.OK) { Add-Result "SLOs" "PASS" "$(@($r.Data.data).Count) found (first page)" }
    else       { Add-Result "SLOs" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Downtimes -------------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v2/downtime"
    if ($r.OK) { Add-Result "Downtimes" "PASS" "$(@($r.Data.data).Count) found" }
    else       { Add-Result "Downtimes" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Metrics ---------------------------------------------------------------
    $metricsFrom = [int]([datetime]::UtcNow - [datetime]::new(1970,1,1,0,0,0,[System.DateTimeKind]::Utc)).TotalSeconds - 86400
    $r = Test-ApiEndpoint "/api/v1/metrics?from=$metricsFrom"
    if ($r.OK) { Add-Result "Metrics Metadata" "PASS" "$(@($r.Data.metrics).Count) active metrics" }
    else       { Add-Result "Metrics Metadata" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Webhooks --------------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v1/integration/webhooks/configuration/webhooks"
    if ($r.OK) { Add-Result "Webhooks" "PASS" "$(if ($r.Data -is [array]) { $r.Data.Count } else { 0 }) found" }
    else       { Add-Result "Webhooks" "WARN" (Format-AuthError $r.StatusCode) }

    # -- Users -----------------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v2/users"
    if ($r.OK) { Add-Result "Users" "PASS" "$(@($r.Data.data).Count) found" }
    else       { Add-Result "Users" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Roles -----------------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v2/roles"
    if ($r.OK) { Add-Result "Roles" "PASS" "$(@($r.Data.data).Count) found" }
    else       { Add-Result "Roles" "FAIL" (Format-AuthError $r.StatusCode) }

    # -- Teams -----------------------------------------------------------------
    $r = Test-ApiEndpoint "/api/v2/team"
    if ($r.OK) { Add-Result "Teams" "PASS" "$(@($r.Data.data).Count) found" }
    else       { Add-Result "Teams" "WARN" (Format-AuthError $r.StatusCode) }

    # -- Usage Analytics: Audit Trail (audit_trail_read) -----------------------
    $r = Test-ApiEndpoint "/api/v2/audit/events?page[limit]=1"
    if ($r.OK) {
        Add-Result "Usage: Audit Trail (audit_trail_read)" "PASS" "Accessible - --usage will collect views/triggers"
    } elseif ($r.StatusCode -in @(401, 403)) {
        Add-Result "Usage: Audit Trail (audit_trail_read)" "WARN" "Missing scope - --usage analytics will be empty"
    } else {
        Add-Result "Usage: Audit Trail (audit_trail_read)" "WARN" (Format-AuthError $r.StatusCode)
    }

    # -- Usage Analytics: Usage Metering (usage_read) -------------------------
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

    # -- Results table ---------------------------------------------------------
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
    if ($items.Count -eq 0) {
        Track-EmptyResult -ResourceType "dashboards" -ScopeName "dashboards_read"
    } else {
        Write-Log SUCCESS "Found $($items.Count) dashboards"
    }
    if ($items.Count -gt 0) {
        # Dashboards MUST be fetched individually: the list carries only metadata
        # (no widgets). Fetch concurrently; measured rate limit ~600/60s = 10/s.
        Write-Log INFO "Fetching $($items.Count) dashboards concurrently (full widget definitions)..."
        Invoke-IdsConcurrent -MaxParallel $script:DashboardConcurrency `
            -UrlTemplate "/api/v1/dashboard/__ID__" `
            -OutFileTemplate (Join-Path $dir "dashboard-__ID__.json") `
            -Ids @($items | ForEach-Object { "$($_.id)" })
        $exported = (Get-ChildItem -Path $dir -Filter "dashboard-*.json" -ErrorAction SilentlyContinue).Count
        $script:TotalApiCalls += $exported; $script:SuccessfulApiCalls += $exported
        Write-Log SUCCESS "Exported $exported / $($items.Count) dashboards"
    }
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
    if ($items.Count -eq 0) {
        Track-EmptyResult -ResourceType "monitors" -ScopeName "monitors_read"
    } else {
        Write-Log SUCCESS "Found $($items.Count) monitors"
    }
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
        if ($items.Count -eq 0) {
            Track-EmptyResult -ResourceType "log pipelines" -ScopeName "logs_read_config"
        } else {
            Write-Log SUCCESS "Found $($items.Count) log pipelines"
        }
        if ($items.Count -gt 0) {
            Write-Log INFO "Fetching $($items.Count) log pipelines concurrently..."
            Invoke-IdsConcurrent -MaxParallel $script:LogsConcurrency `
                -UrlTemplate "/api/v1/logs/config/pipelines/__ID__" `
                -OutFileTemplate (Join-Path $pipDir "pipeline-__ID__.json") `
                -Ids @($items | ForEach-Object { "$($_.id)" })
            $exported = (Get-ChildItem -Path $pipDir -Filter "pipeline-*.json" -ErrorAction SilentlyContinue).Count
            $script:TotalApiCalls += $exported; $script:SuccessfulApiCalls += $exported
            Write-Log SUCCESS "Exported $exported / $($items.Count) log pipelines"
        }
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
    if ($items.Count -eq 0) {
        Track-EmptyResult -ResourceType "synthetic tests" -ScopeName "synthetics_read"
    } else {
        Write-Log SUCCESS "Found $($items.Count) synthetic tests"
    }
    if ($items.Count -gt 0) {
        Write-Log INFO "Fetching $($items.Count) synthetic tests concurrently (full step definitions)..."
        Invoke-IdsConcurrent -MaxParallel $script:SyntheticsConcurrency `
            -UrlTemplate "/api/v1/synthetics/tests/__ID__" `
            -OutFileTemplate (Join-Path $dir "test-__ID__.json") `
            -Ids @($items | ForEach-Object { "$($_.public_id)" })
        $exported = (Get-ChildItem -Path $dir -Filter "test-*.json" -ErrorAction SilentlyContinue).Count
        $script:TotalApiCalls += $exported; $script:SuccessfulApiCalls += $exported
        Write-Log SUCCESS "Exported $exported / $($items.Count) synthetic tests"
    }
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
    if ($allSlos.Count -eq 0) {
        Track-EmptyResult -ResourceType "SLOs" -ScopeName "slos_read"
    } else {
        Write-Log SUCCESS "Found $($allSlos.Count) SLOs"
    }
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
    $metricsFrom = [int]([datetime]::UtcNow - [datetime]::new(1970,1,1,0,0,0,[System.DateTimeKind]::Utc)).TotalSeconds - 86400
    $data = Invoke-DataDogApi -Method GET -Endpoint "/api/v1/metrics?from=$metricsFrom" `
        -OutputFile (Join-Path $dir "_list.json")
    if ($data) {
        $count = if ($data.metrics) { $data.metrics.Count } else { 0 }
        if ($count -eq 0) {
            Track-EmptyResult -ResourceType "metrics" -ScopeName "metrics_read"
        } else {
            Write-Log SUCCESS "Found $count active metrics (last 24 hours)"
        }
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
            if ($count -eq 0 -and $_.Label -eq "users") {
                Track-EmptyResult -ResourceType "users" -ScopeName "user_access_read"
            } else {
                Write-Log SUCCESS "Exported $count $($_.Label)"
            }
        } else { Write-Log WARNING "Failed to fetch $($_.Label)" }
    }
}

# ---------------------------------------------------------------------------
# Count items in a single-call list body without mislabeling non-.data shapes
# as empty (parity with bash export_simple_list candidate-path probing).
# Returns the count as a string, "0" for an accessible-but-empty array, or "?"
# when no array-typed candidate is found.
# ---------------------------------------------------------------------------
function Get-ListItemCount {
    param([string]$Json)
    try { $o = $Json | ConvertFrom-Json } catch { return '?' }
    foreach ($p in 'data','dashboard_lists','variables','locations','notebooks','tags','accounts') {
        if ($o -and $o.PSObject.Properties[$p]) {
            $v = $o.$p
            if ($v -is [array]) { return "$($v.Count)" }
        }
    }
    if ($o -is [array]) { return "$($o.Count)" }
    return '?'
}

# ---------------------------------------------------------------------------
# Save a single list/config endpoint to a file, degrading gracefully (parity
# with bash export_simple_list):
#   200/201 -> save body + log item count
#   401/403 -> WARN "missing scope" and skip (endpoint real, key lacks scope)
#   404     -> INFO "not available" and skip
#   other   -> WARN and count as a failed call
# Never aborts the export.
# ---------------------------------------------------------------------------
function Export-SimpleList {
    param([string]$Label, [string]$Endpoint, [string]$OutFile)

    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $script:TotalApiCalls++
    $url = "$($script:DatadogApiUrl)$Endpoint"
    $headers = @{
        'DD-API-KEY'         = $script:DatadogApiKey
        'DD-APPLICATION-KEY' = $script:DatadogAppKey
        'Content-Type'       = 'application/json'
    }
    try {
        $resp = Invoke-WebRequest -Uri $url -Method GET -Headers $headers `
            -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
        $script:SuccessfulApiCalls++
        Write-JsonFile -Path $OutFile -Content $resp.Content
        $n = Get-ListItemCount $resp.Content
        if     ($n -eq '0') { Write-Log INFO    "  ${Label}: 0 (accessible, empty)" }
        elseif ($n -eq '?') { Write-Log SUCCESS "  ${Label}: saved" }
        else                { Write-Log SUCCESS "  ${Label}: $n" }
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if     ($code -eq 401 -or $code -eq 403) { Write-Log WARNING "  ${Label}: skipped - Application Key missing required scope (HTTP $code)" }
        elseif ($code -eq 404)                   { Write-Log INFO    "  ${Label}: not available on this org (HTTP 404)" }
        else   { $script:FailedApiCalls++; Write-Log WARNING "  ${Label}: failed (HTTP $code)" }
    }
}

# Export the full breadth of remaining single-call configuration resources.
# Each is best-effort: empty or scope-gated resources are noted and skipped so
# the script exports them automatically wherever the data/scopes exist.
# Paths mirror bash export_additional_resources verbatim. Parity note: these are
# intentionally NOT added to manifest.exported_items or -TestAccess (bash isn't).
function Export-AdditionalResources {
    Write-Step "Exporting Additional Resources"

    $rows = @(
        # Visualization & content
        @{ L = 'Notebooks';                            E = '/api/v1/notebooks';                       O = 'notebooks/_list.json' }
        @{ L = 'Dashboard lists';                      E = '/api/v1/dashboard/lists/manual';          O = 'dashboards/lists.json' }
        @{ L = 'Powerpacks';                           E = '/api/v2/powerpacks';                      O = 'powerpacks/_list.json' }
        # Monitoring extras
        @{ L = 'SLO corrections';                      E = '/api/v1/slo/correction';                  O = 'slos/corrections.json' }
        @{ L = 'Monitor config policies';              E = '/api/v2/monitor/policy';                  O = 'monitors/config_policies.json' }
        # Logs (beyond pipelines/indexes)
        @{ L = 'Log archives';                         E = '/api/v2/logs/config/archives';            O = 'logs/archives.json' }
        @{ L = 'Log metrics';                          E = '/api/v2/logs/config/metrics';             O = 'logs/metrics.json' }
        @{ L = 'Log custom destinations';              E = '/api/v2/logs/config/custom-destinations'; O = 'logs/custom_destinations.json' }
        @{ L = 'Log restriction queries';              E = '/api/v2/logs/config/restriction_queries'; O = 'logs/restriction_queries.json' }
        # APM / spans / RUM
        @{ L = 'APM retention filters';                E = '/api/v2/apm/config/retention-filters';    O = 'apm/retention_filters.json' }
        @{ L = 'Spans metrics';                        E = '/api/v2/apm/config/metrics';              O = 'apm/spans_metrics.json' }
        @{ L = 'RUM applications';                     E = '/api/v2/rum/applications';                O = 'rum/applications.json' }
        # Synthetics extras
        @{ L = 'Synthetics global variables';          E = '/api/v1/synthetics/variables';            O = 'synthetics/global_variables.json' }
        @{ L = 'Synthetics private locations';         E = '/api/v1/synthetics/locations';            O = 'synthetics/locations.json' }
        # Security / catalog / reference
        @{ L = 'Security monitoring rules';            E = '/api/v2/security_monitoring/rules';       O = 'security/monitoring_rules.json' }
        @{ L = 'Service definitions (Software Catalog)'; E = '/api/v2/services/definitions';          O = 'service_catalog/definitions.json' }
        @{ L = 'Reference tables';                     E = '/api/v2/reference-tables/tables';         O = 'reference_tables/_list.json' }
        @{ L = 'Incidents';                            E = '/api/v2/incidents';                       O = 'incidents/_list.json' }
        # Org / access
        @{ L = 'Authn mappings';                       E = '/api/v2/authn_mappings';                  O = 'users/authn_mappings.json' }
        # Integrations
        @{ L = 'AWS integration';                      E = '/api/v1/integration/aws';                 O = 'integrations/aws.json' }
        @{ L = 'Azure integration';                    E = '/api/v1/integration/azure';               O = 'integrations/azure.json' }
        @{ L = 'GCP integration (legacy)';             E = '/api/v1/integration/gcp';                 O = 'integrations/gcp.json' }
        @{ L = 'GCP integration (STS)';                E = '/api/v2/integration/gcp/accounts';        O = 'integrations/gcp_sts.json' }
        @{ L = 'PagerDuty integration';                E = '/api/v1/integration/pagerduty';           O = 'integrations/pagerduty.json' }
        # Infrastructure
        @{ L = 'Host tags';                            E = '/api/v1/tags/hosts';                      O = 'infra/host_tags.json' }
    )

    $sep = [System.IO.Path]::DirectorySeparatorChar
    foreach ($r in $rows) {
        $out = Join-Path $script:OutputDir ($r.O -replace '/', $sep)
        Export-SimpleList -Label $r.L -Endpoint $r.E -OutFile $out
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

function Invoke-EventsApiQuery {
    param([string]$FilterQuery, [int]$MaxPages = 50)
    $allEvents = [System.Collections.Generic.List[object]]::new()
    $cursor    = ''
    $page      = 0
    $limit     = 1000
    $from      = Get-UsageFromTimestamp
    $to        = Get-UsageToTimestamp

    Write-Log DEBUG "Events API query: $FilterQuery (from=$from to=$to)"

    $encQ    = [System.Uri]::EscapeDataString($FilterQuery)
    $encFrom = [System.Uri]::EscapeDataString($from)
    $encTo   = [System.Uri]::EscapeDataString($to)

    while ($page -lt $MaxPages) {
        $ep = '/api/v2/events?filter[query]={0}&filter[from]={1}&filter[to]={2}&page[limit]={3}' -f $encQ, $encFrom, $encTo, $limit
        if ($cursor) { $ep += ('&page[cursor]={0}' -f [System.Uri]::EscapeDataString($cursor)) }

        $data = Invoke-DataDogApi -Method GET -Endpoint $ep
        if ($null -eq $data) { Write-Log WARNING "Events API query failed on page $page"; break }

        $pageEvents = if ($data.data) { @($data.data) } else { @() }
        if ($pageEvents.Count -eq 0) { break }
        foreach ($evt in $pageEvents) { $allEvents.Add($evt) }

        $cursor = if ($data.meta -and $data.meta.page -and $data.meta.page.after) {
            $data.meta.page.after
        } else { '' }
        $page++
        Write-Log DEBUG "  Page $page`: $($pageEvents.Count) events (total: $($allEvents.Count))"
        if (-not $cursor) { break }
    }

    Write-Log DEBUG "Events API collected $($allEvents.Count) events"
    return $allEvents
}

function Collect-DashboardViews {
    Write-Log INFO "Collecting dashboard view analytics..."
    $outFile = Join-Path $script:OutputDir "analytics\dashboard_views.json"
    Write-JsonObject -Path $outFile -Object ([PSCustomObject]@{
        views   = @()
        error   = 'not_available'
        message = 'DataDog does not expose dashboard view counts via a public API. View analytics are only available in the DataDog UI (Organization Settings -> Audit Trail filtered by @asset.type:dashboard, or via the Popular Dashboards feature on the Dashboards list page).'
    })
    Write-Log WARNING "Dashboard views: not available via DataDog API - see analytics\dashboard_views.json for UI alternatives"
}

function Collect-MonitorTriggers {
    Write-Log INFO "Collecting monitor trigger analytics..."
    $failsBefore = $script:FailedApiCalls
    $events  = Invoke-EventsApiQuery 'sources:monitors'
    if (@($events).Count -eq 0 -and $script:FailedApiCalls -gt $failsBefore) {
        Write-Log WARNING "Monitor triggers: Events API call failed. Ensure your API Key has Events read access."
    }
    $grouped = $events | Group-Object { $_.attributes.attributes.monitor.id } | ForEach-Object {
        $g        = $_.Group
        $monId    = $g[0].attributes.attributes.monitor.id
        $monName  = if ($g[0].attributes.title) { $g[0].attributes.title } else { "Monitor $monId" }
        $triggers = @($g | Where-Object { $_.attributes.alert_type -eq 'triggered' }).Count
        $resolves = @($g | Where-Object { $_.attributes.alert_type -eq 'recovered' }).Count
        $lastTs   = ($g | Sort-Object { $_.attributes.timestamp } | Select-Object -Last 1).attributes.timestamp
        [PSCustomObject]@{
            monitor_id     = $monId
            monitor_name   = $monName
            trigger_count  = $triggers
            resolve_count  = $resolves
            total_events   = $g.Count
            last_triggered = $lastTs
        }
    } | Where-Object { $_.monitor_id } | Sort-Object -Property trigger_count -Descending
    Write-JsonObject -Path (Join-Path $script:OutputDir "analytics\monitor_triggers.json") -Object @($grouped)
    Write-Log SUCCESS "Monitor triggers: $(@($grouped).Count) monitors with activity"
}

function Collect-LogIndexVolume {
    Write-Log INFO "Collecting log index volume analytics..."
    # DataDog Usage Metering API allows at most ~1 month per request.
    # Split the usage period into monthly windows and aggregate the results.
    $fromDate = [datetime]::ParseExact((Get-UsageFromTimestamp).Substring(0, 10), 'yyyy-MM-dd', $null)
    $toDate   = [datetime]::ParseExact((Get-UsageToTimestamp).Substring(0, 10),   'yyyy-MM-dd', $null)
    $outFile  = Join-Path $script:OutputDir "analytics\log_index_volume.json"
    $totals   = @{}
    $anyData  = $false

    $windowStart = $fromDate
    while ($windowStart -le $toDate) {
        $windowEnd = $windowStart.AddMonths(1).AddDays(-1)
        if ($windowEnd -gt $toDate) { $windowEnd = $toDate }

        $startHr = $windowStart.ToString('yyyy-MM-ddT00')
        $endHr   = $windowEnd.ToString('yyyy-MM-ddT23')

        $data = Invoke-DataDogApi -Method GET -Endpoint ('/api/v2/usage/hourly_usage?product_families=indexed_logs&start_hr={0}&end_hr={1}' -f $startHr, $endHr)
        if ($data -and $data.data) {
            $anyData = $true
            foreach ($entry in $data.data) {
                $n = if ($entry.attributes.tags -and $entry.attributes.tags.'log_index_name') {
                    $entry.attributes.tags.'log_index_name'
                } elseif ($entry.attributes.tags -and $entry.attributes.tags.log_index_name) {
                    $entry.attributes.tags.log_index_name
                } else { continue }
                if (-not $n) { continue }
                if (-not $totals.ContainsKey($n)) {
                    $totals[$n] = @{ total_event_count = 0; hours_active = 0 }
                }
                $measurement = $entry.attributes.measurements | Where-Object { $_.usage_type -eq 'logs_indexed_events_count' } | Select-Object -First 1
                $totals[$n].total_event_count += if ($measurement -and $measurement.value) { [long]$measurement.value } else { 0 }
                $totals[$n].hours_active++
            }
        }
        $windowStart = $windowStart.AddMonths(1)
    }

    if ($anyData) {
        $indexes = $totals.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{
                index_name        = $_.Key
                total_event_count = $_.Value.total_event_count
                hours_active      = $_.Value.hours_active
            }
        } | Sort-Object -Property total_event_count -Descending
        Write-JsonObject -Path $outFile -Object ([PSCustomObject]@{
            period  = @{ from = $fromDate.ToString('yyyy-MM-dd'); to = $toDate.ToString('yyyy-MM-dd') }
            indexes = @($indexes)
        })
        Write-Log SUCCESS "Log index volume: $(@($indexes).Count) indexes with usage data"
    } else {
        Write-JsonFile -Path $outFile -Content '{"indexes":[],"error":"Usage Metering API not available"}'
        Write-Log WARNING "Log index volume: no data returned from /api/v2/usage/hourly_usage - check that your Application Key has the 'usage_read' scope"
    }
}

function Collect-MonitorModifications {
    Write-Log INFO "Collecting monitor modification analytics..."
    $failsBefore = $script:FailedApiCalls
    $events  = Invoke-AuditTrailQuery '@asset.type:monitor @action:(created modified)'
    if (@($events).Count -eq 0 -and $script:FailedApiCalls -gt $failsBefore) {
        Write-Log WARNING "Monitor modifications: 0 results - Audit Trail API call failed. Ensure your Application Key has the 'audit_trail_read' scope in DataDog (Organization Settings -> API Keys -> Application Keys)."
    }
    $grouped = $events | Group-Object { $_.attributes.asset.id } | ForEach-Object {
        $g        = $_.Group
        $created  = @($g | Where-Object { $_.attributes.action -eq 'created' }).Count
        $modified = @($g | Where-Object { $_.attributes.action -eq 'modified' }).Count
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
        if ($script:SkipDashboardsF) {
            Write-Log INFO "Skipping unused-dashboard cross-reference (-SkipDashboards was set)"
        } else {
            Write-Log WARNING "No dashboard files found in $dashDir - dashboards may not have been exported in this run"
        }
        Write-JsonFile -Path $outFile -Content '{"unused_dashboards":[],"total_dashboards":0,"unused_count":0}'
        return
    }

    $viewedIds         = @()
    $viewDataAvailable = $true
    $vf = Join-Path $script:OutputDir "analytics\dashboard_views.json"
    if (Test-Path $vf) {
        $vfContent = Get-Content $vf -Raw | ConvertFrom-Json
        if ($vfContent.error -eq 'not_available') {
            $viewDataAvailable = $false
        } else {
            $viewedIds = @($vfContent | ForEach-Object { $_.dashboard_id } | Where-Object { $_ } | Sort-Object)
        }
    }

    if (-not $viewDataAvailable) {
        Write-JsonObject -Path $outFile -Object ([PSCustomObject]@{
            unused_dashboards    = @()
            total_dashboards     = $allIds.Count
            unused_count         = 0
            view_data_available  = $false
            note                 = 'Dashboard view data is not available via the DataDog API. Classification as used/unused cannot be determined.'
            usage_period         = $script:UsagePeriodValue
        })
        Write-Log WARNING "Unused dashboards: cannot classify - dashboard view data is not available via the DataDog API"
        return
    }

    $unusedIds = @($allIds | Where-Object { $_ -notin $viewedIds })
    $unusedList = $unusedIds | ForEach-Object {
        $title = "Unknown"
        $f = Join-Path $script:OutputDir "dashboards\dashboard-${_}.json"
        if ($f -and (Test-Path $f)) { $d = Get-Content $f -Raw | ConvertFrom-Json; if ($d.title) { $title = $d.title } }
        [PSCustomObject]@{ dashboard_id = $_; title = $title }
    }
    Write-JsonObject -Path $outFile -Object ([PSCustomObject]@{
        unused_dashboards    = @($unusedList)
        total_dashboards     = $allIds.Count
        viewed_count         = $allIds.Count - $unusedIds.Count
        unused_count         = $unusedIds.Count
        view_data_available  = $true
        usage_period         = $script:UsagePeriodValue
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
        if ($script:SkipMonitorsF) {
            Write-Log INFO "Skipping unused-monitor cross-reference (-SkipMonitors was set)"
        } else {
            Write-Log WARNING "No monitor files found in $monDir - monitors may not have been exported in this run"
        }
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
        $f = Join-Path $script:OutputDir "monitors\monitor-${_}.json"
        if ($f -and (Test-Path $f)) { $m = Get-Content $f -Raw | ConvertFrom-Json; if ($m.name) { $name = $m.name } }
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
    Write-Log INFO "APIs used: Audit Trail v2 (config changes), Events v2 (monitor firings), Usage Metering v2 (log index volume)"

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
            dashboard_views       = [PSCustomObject]@{ dashboards_with_views  = (& $getCount "dashboard_views.json"       $null); note = 'not_available_via_api' }
            monitor_triggers      = [PSCustomObject]@{ monitors_with_triggers = (& $getCount "monitor_triggers.json"      $null) }
            log_index_volume      = [PSCustomObject]@{ indexes_with_data      = (& $getCount "log_index_volume.json"      "indexes") }
            monitor_modifications = [PSCustomObject]@{ monitors_modified      = (& $getCount "monitor_modifications.json" $null) }
            unused_dashboards     = [PSCustomObject]@{ count                  = (& $getCount "unused_dashboards.json"     "unused_count") }
            unused_monitors       = [PSCustomObject]@{ count                  = (& $getCount "unused_monitors.json"       "unused_count") }
        }
        ui_queries = [PSCustomObject]@{
            dashboard_views = [PSCustomObject]@{
                note    = 'DataDog does not expose dashboard view counts via a public API.'
                ui_path = 'Organization Settings -> Audit Trail -> filter: @asset.type:dashboard (shows config changes only, not views)'
                tip     = 'For view activity, check the Popular Dashboards section on the Dashboards list page in the DataDog UI.'
            }
            monitor_triggers = [PSCustomObject]@{
                events_explorer = 'Events -> Explorer -> filter: sources:monitors -> date range: last 30 days -> group by monitor'
                notebook_query  = 'events("sources:monitors").rollup("count").by("monitor_id").last("30d")'
            }
            log_index_volume = [PSCustomObject]@{
                notebook_query   = 'sum:datadog.estimated_usage.logs.ingested_events{*} by {index_name}.rollup(sum, 86400)'
                built_in_dashboard = 'Log Management -> Log Management - Estimated Usage -> Indexed Logs section'
            }
            monitor_modifications = [PSCustomObject]@{
                audit_trail_filter = '@asset.type:monitor @action:(created modified deleted)'
                ui_path            = 'Organization Settings -> Audit Trail -> apply the filter above -> last 30 days'
            }
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

    $script:TotalSteps = 11  # +1 for the Additional Resources step
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
    Export-AdditionalResources
    Invoke-UsageAnalytics
    Write-Manifest
    New-ExportArchive

    Write-Host ""
    Write-Header "Export Complete!"
    Write-Host "  Export location : $($script:OutputDir)" -ForegroundColor White
    Write-Host "  Archive         : $(Join-Path $script:ExportDir "$($script:ExportName).tar.gz")" -ForegroundColor White
    Write-Host "  Log file        : $($script:LogFile)" -ForegroundColor White

    # Show warnings for potential silent failures
    if ($script:SuspiciousEmptyCount -gt 0) {
        Write-Host ""
        Write-Host ("=" * 78) -ForegroundColor Yellow
        Write-Host "  [!]  POTENTIAL SILENT FAILURES DETECTED" -ForegroundColor Yellow
        Write-Host ("=" * 78) -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Export completed successfully but $($script:SuspiciousEmptyCount) resource type(s) returned 0 items." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  This usually means your Application Key is MISSING REQUIRED SCOPES." -ForegroundColor Yellow
        Write-Host "  DataDog APIs return HTTP 200 (success) even when scopes are missing." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Empty results for:" -ForegroundColor Yellow
        foreach ($warning in $script:EmptyResultsWarnings) {
            $resource = $warning.ResourceType.PadRight(30)
            $scope = $warning.ScopeName.PadRight(20)
            Write-Host "    * $resource (missing scope: $scope)" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  CRITICAL: Your export is likely INCOMPLETE!" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To fix:" -ForegroundColor Yellow
        Write-Host "  1. Recreate your Application Key with ALL required scopes" -ForegroundColor White
        Write-Host "  2. Run this script with -TestAccess to validate scopes" -ForegroundColor White
        Write-Host "  3. Re-run the full export with the corrected Application Key" -ForegroundColor White
        Write-Host ""
        Write-Host ("=" * 78) -ForegroundColor Yellow
        Write-Host ""
    }

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
