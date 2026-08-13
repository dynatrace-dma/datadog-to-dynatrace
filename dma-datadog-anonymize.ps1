#Requires -Version 5.1
<#
.SYNOPSIS
    DMA DataDog Export Anonymizer v1.0.0

.DESCRIPTION
    Pseudonymizes email addresses and user handles in a DataDog export archive
    produced by dma-datadog-export.ps1. Produces a new *_anonymized.tar.gz
    archive that is safe to share with Dynatrace colleagues for migration
    analysis - no customer PII remains.

    Pseudonymization method: SHA-256 of the original email (lowercase, trimmed),
    first 8 hex characters. Same email always maps to the same pseudonym across
    all runs and all files. No mapping table is stored; the transformation is
    not reversible from the output alone.

    Zero external dependencies. Requires Windows 10 build 1803+ or Windows 11
    (for built-in tar.exe).

.PARAMETER InputPath
    Path to the export archive (.tar.gz) or an already-extracted export directory.

.PARAMETER DryRun
    Report what would be changed without writing any files.

.EXAMPLE
    .\dma-datadog-anonymize.ps1 .\datadog-export\export_20260807_142233.tar.gz

.EXAMPLE
    .\dma-datadog-anonymize.ps1 .\datadog-export\export_20260807_142233\ -DryRun
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [switch]$DryRun
)

$script:ErrorsEncountered = 0
$script:FilesProcessed    = 0
$script:EmailsReplaced    = 0

# =============================================================================
# HELPERS - LOGGING / OUTPUT
# =============================================================================

function Write-Log {
    param([string]$Level, [string]$Message)
    switch ($Level) {
        'INFO'    { Write-Host "  i $Message" -ForegroundColor Cyan }
        'SUCCESS' { Write-Host "  v $Message" -ForegroundColor Green }
        'WARNING' { Write-Host "  ! $Message" -ForegroundColor Yellow }
        'ERROR'   { Write-Host "  x $Message" -ForegroundColor Red; $script:ErrorsEncountered++ }
    }
}

function Write-Header {
    param([string]$Text)
    $line = '=' * 80
    $pad  = [Math]::Max(0, [int]((80 - $Text.Length) / 2))
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host (' ' * $pad + $Text) -ForegroundColor White
    Write-Host $line -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ('-' * 80) -ForegroundColor Blue
    Write-Host " $Text" -ForegroundColor White
    Write-Host ('-' * 80) -ForegroundColor Blue
}

# =============================================================================
# PSEUDONYMIZATION CORE
# =============================================================================

$script:Sha256 = [System.Security.Cryptography.SHA256]::Create()

function Get-EmailToken {
    param([string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.Trim().ToLower())
    $hash  = $script:Sha256.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
}

$script:EmailPattern = [regex][string]'[a-zA-Z0-9._%+\-]+@(?!anonymized\.example)[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}'

function Invoke-AnonEmail {
    param([string]$Email)
    if ([string]::IsNullOrEmpty($Email) -or $Email -like '*@anonymized.example') { return $Email }
    $script:EmailsReplaced++
    return 'user-' + (Get-EmailToken $Email) + '@anonymized.example'
}

function Invoke-AnonHandle {
    param([string]$Handle)
    if ([string]::IsNullOrEmpty($Handle)) { return $Handle }
    return 'user-' + (Get-EmailToken $Handle)
}

function Invoke-AnonName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $Name }
    return 'User ' + (Get-EmailToken $Name)
}

function Invoke-ScrubText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # Replace each match in reverse-index order so positions stay valid.
    $matchList = @($script:EmailPattern.Matches($Text))
    $result    = $Text
    for ($i = $matchList.Count - 1; $i -ge 0; $i--) {
        $m           = $matchList[$i]
        $replacement = 'user-' + (Get-EmailToken $m.Value) + '@anonymized.example'
        $script:EmailsReplaced++
        $result = $result.Remove($m.Index, $m.Length).Insert($m.Index, $replacement)
    }
    return $result
}

# Safe in-place property update for PSCustomObject (PS 5.1 NoteProperty compatible).
# Returns $true when the property existed and was non-empty, $false otherwise.
function Set-Prop {
    param($Obj, [string]$Prop, [string]$NewValue)
    if ($null -eq $Obj) { return }
    $pp = $Obj.PSObject.Properties[$Prop]
    if ($pp -and -not [string]::IsNullOrEmpty($pp.Value)) {
        $pp.Value = $NewValue
    }
}

function Invoke-TransformCreator {
    param($Item)
    if ($null -eq $Item) { return }
    $cp = $Item.PSObject.Properties['creator']
    if ($null -eq $cp -or $null -eq $cp.Value) { return }
    $c = $cp.Value
    $ep = $c.PSObject.Properties['email']
    if ($ep -and -not [string]::IsNullOrEmpty($ep.Value)) {
        Set-Prop $c 'email'  (Invoke-AnonEmail  $ep.Value)
        Set-Prop $c 'handle' (Invoke-AnonHandle ($c.PSObject.Properties['handle'] | Select-Object -ExpandProperty Value))
        Set-Prop $c 'name'   (Invoke-AnonName   ($c.PSObject.Properties['name']   | Select-Object -ExpandProperty Value))
    } else {
        $hp = $c.PSObject.Properties['handle']
        if ($hp -and -not [string]::IsNullOrEmpty($hp.Value)) {
            Set-Prop $c 'handle' (Invoke-AnonHandle $hp.Value)
            Set-Prop $c 'name'   (Invoke-AnonName   ($c.PSObject.Properties['name'] | Select-Object -ExpandProperty Value))
        }
    }
}

# =============================================================================
# FILE-LEVEL TRANSFORM DISPATCH
# =============================================================================

function Invoke-ProcessFile {
    param([string]$FilePath, [string]$RelPath, [bool]$DryRun)

    $parts  = $RelPath.Replace('\', '/') -split '/'
    $parent = if ($parts.Count -ge 2) { $parts[$parts.Count - 2] } else { '' }
    $name   = $parts[$parts.Count - 1]

    $raw = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $data = $null
    try {
        $data = $raw | ConvertFrom-Json
    } catch {
        Write-Log WARNING "Could not parse JSON: $RelPath - skipping"
        return $false
    }

    $changed = $false

    if ($parent -eq 'users' -and $name -eq 'users.json') {
        foreach ($item in @($data.data)) {
            if ($null -eq $item) { continue }
            $ap = $item.PSObject.Properties['attributes']
            if ($null -eq $ap -or $null -eq $ap.Value) { continue }
            $a  = $ap.Value
            $ep = $a.PSObject.Properties['email']
            if ($ep -and -not [string]::IsNullOrEmpty($ep.Value)) {
                Set-Prop $a 'email'  (Invoke-AnonEmail  $ep.Value)
                Set-Prop $a 'handle' (Invoke-AnonHandle ($a.PSObject.Properties['handle'] | Select-Object -ExpandProperty Value))
                Set-Prop $a 'name'   (Invoke-AnonName   ($a.PSObject.Properties['name']   | Select-Object -ExpandProperty Value))
                $changed = $true
            }
        }

    } elseif ($parent -eq 'monitors') {
        $items = if ($data -is [array]) { $data } else { @($data) }
        foreach ($item in $items) {
            if ($null -eq $item) { continue }
            Invoke-TransformCreator $item
            $mp = $item.PSObject.Properties['message']
            if ($mp -and -not [string]::IsNullOrEmpty($mp.Value)) {
                $mp.Value = Invoke-ScrubText $mp.Value
            }
            $changed = $true
        }

    } elseif ($parent -eq 'dashboards') {
        if ($null -ne $data) {
            $hp = $data.PSObject.Properties['author_handle']
            if ($hp -and -not [string]::IsNullOrEmpty($hp.Value)) {
                Set-Prop $data 'author_handle' (Invoke-AnonHandle $hp.Value)
                Set-Prop $data 'author_name'   (Invoke-AnonName   ($data.PSObject.Properties['author_name'] | Select-Object -ExpandProperty Value))
                $changed = $true
            }
        }

    } elseif ($parent -eq 'slos' -or $parent -eq 'synthetics') {
        $items = if ($data -is [array]) { $data } else { @($data) }
        foreach ($item in $items) {
            if ($null -ne $item) {
                Invoke-TransformCreator $item
                $changed = $true
            }
        }

    } elseif ($parent -eq 'downtimes') {
        $items = if ($data -is [array]) { $data } else { @($data) }
        foreach ($item in $items) {
            if ($null -eq $item) { continue }
            foreach ($inc in @($item.included)) {
                if ($null -eq $inc) { continue }
                $ap = $inc.PSObject.Properties['attributes']
                if ($null -eq $ap -or $null -eq $ap.Value) { continue }
                $a = $ap.Value
                $ep = $a.PSObject.Properties['email']
                if ($ep -and -not [string]::IsNullOrEmpty($ep.Value)) {
                    Set-Prop $a 'email' (Invoke-AnonEmail $ep.Value)
                }
                $hp = $a.PSObject.Properties['handle']
                if ($hp -and -not [string]::IsNullOrEmpty($hp.Value)) {
                    Set-Prop $a 'handle' (Invoke-AnonHandle $hp.Value)
                }
                $changed = $true
            }
        }

    } elseif ($parent -eq 'notebooks' -and $name -eq '_list.json') {
        foreach ($item in @($data.data)) {
            if ($null -eq $item) { continue }
            $ap = $item.PSObject.Properties['attributes']
            if ($null -eq $ap -or $null -eq $ap.Value) { continue }
            $aup = $ap.Value.PSObject.Properties['author']
            if ($null -eq $aup -or $null -eq $aup.Value) { continue }
            $au = $aup.Value
            $ep = $au.PSObject.Properties['email']
            if ($ep -and -not [string]::IsNullOrEmpty($ep.Value)) {
                Set-Prop $au 'email'  (Invoke-AnonEmail  $ep.Value)
                Set-Prop $au 'handle' (Invoke-AnonHandle ($au.PSObject.Properties['handle'] | Select-Object -ExpandProperty Value))
                $changed = $true
            }
        }

    } elseif ($parent -eq 'analytics' -and $name -eq 'dashboard_views.json') {
        $items = if ($data -is [array]) { $data } else { @($data) }
        foreach ($item in $items) {
            if ($null -eq $item) { continue }
            $up = $item.PSObject.Properties['users']
            if ($null -eq $up -or $null -eq $up.Value) { continue }
            $up.Value = @($up.Value | ForEach-Object {
                if (-not [string]::IsNullOrEmpty($_)) { Invoke-AnonEmail $_ } else { $_ }
            })
            $changed = $true
        }

    } elseif ($parent -eq 'analytics' -and $name -eq 'monitor_modifications.json') {
        $items = if ($data -is [array]) { $data } else { @($data) }
        foreach ($item in $items) {
            if ($null -eq $item) { continue }
            $mbp = $item.PSObject.Properties['modified_by']
            if ($null -eq $mbp -or $null -eq $mbp.Value) { continue }
            $mbp.Value = @($mbp.Value | ForEach-Object {
                if (-not [string]::IsNullOrEmpty($_)) { Invoke-AnonEmail $_ } else { $_ }
            })
            $changed = $true
        }
    }

    if ($changed -and -not $DryRun) {
        $out = $data | ConvertTo-Json -Depth 100 -Compress
        [System.IO.File]::WriteAllText($FilePath, $out, [System.Text.UTF8Encoding]::new($false))
    }
    return $changed
}

# =============================================================================
# PROCESS ALL JSON FILES IN A DIRECTORY
# =============================================================================

function Invoke-AnonymizeDirectory {
    param([string]$WorkDir, [bool]$DryRun)

    $jsonFiles = Get-ChildItem -Path $WorkDir -Filter '*.json' -Recurse |
                 Where-Object { -not $_.PSIsContainer }

    foreach ($file in $jsonFiles) {
        $rel = $file.FullName.Substring($WorkDir.Length).TrimStart([char]'\', [char]'/')
        $ok  = Invoke-ProcessFile -FilePath $file.FullName -RelPath $rel -DryRun $DryRun
        if ($ok) { $script:FilesProcessed++ }
    }

    # Patch manifest.json to record that data has been anonymized
    $manifestPath = Join-Path $WorkDir 'manifest.json'
    if (Test-Path $manifestPath) {
        try {
            $raw      = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
            $manifest = $raw | ConvertFrom-Json
            $manifest | Add-Member -NotePropertyName 'anonymized'    -NotePropertyValue $true -Force
            $manifest | Add-Member -NotePropertyName 'anonymized_at' -NotePropertyValue (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') -Force
            if (-not $DryRun) {
                $out = $manifest | ConvertTo-Json -Depth 100 -Compress
                [System.IO.File]::WriteAllText($manifestPath, $out, [System.Text.UTF8Encoding]::new($false))
            }
        } catch {
            Write-Log WARNING "Could not patch manifest.json: $_"
        }
    }
}

# =============================================================================
# ARCHIVE
# =============================================================================

function New-AnonymizedArchive {
    param([string]$WorkTmpDir, [string]$OutputName, [string]$OutputArchivePath)

    Write-Log INFO "Compressing: $(Split-Path $OutputArchivePath -Leaf)"
    try {
        $proc = Start-Process -FilePath 'tar' `
            -ArgumentList @('-czf', $OutputArchivePath, '-C', $WorkTmpDir, $OutputName) `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Log ERROR "tar exited with code $($proc.ExitCode)"
            return
        }
        $sizeMb = '{0:N1} MB' -f ((Get-Item $OutputArchivePath).Length / 1MB)
        Write-Log SUCCESS "Archive created: $(Split-Path $OutputArchivePath -Leaf) ($sizeMb)"

        Write-Log INFO 'Calculating SHA-256...'
        $hash        = (Get-FileHash -Path $OutputArchivePath -Algorithm SHA256).Hash.ToLower()
        $sidecarPath = $OutputArchivePath + '.sha256'
        [System.IO.File]::WriteAllText($sidecarPath,
            ($hash + '  ' + (Split-Path $OutputArchivePath -Leaf) + "`n"),
            [System.Text.UTF8Encoding]::new($false))
        Write-Log SUCCESS "SHA-256: $hash"
    } catch {
        Write-Log ERROR "Failed to create archive: $_"
    }
}

# =============================================================================
# MAIN
# =============================================================================

Write-Header 'DMA DataDog Export Anonymizer v1.0.0'

if ($DryRun) { Write-Log WARNING 'DRY RUN - no files will be written.' }

# -- Resolve input path ---------------------------------------------------------

$resolvedInput = Resolve-Path $InputPath -ErrorAction SilentlyContinue
if (-not $resolvedInput) {
    Write-Log ERROR "Input not found: $InputPath"
    exit 1
}
$inputFull = $resolvedInput.Path

$inputIsArchive = $inputFull -like '*.tar.gz'
$workTmpDir     = $null
$workExportDir  = $null
$outputArchive  = $null
$outputName     = $null

if ($inputIsArchive) {
    # -- Archive input ------------------------------------------------------
    Write-Step 'Extracting Archive'

    $archiveParent = Split-Path $inputFull -Parent
    $noGz          = [System.IO.Path]::GetFileNameWithoutExtension($inputFull)          # strip .gz
    $archiveBase   = [System.IO.Path]::GetFileNameWithoutExtension($noGz)               # strip .tar
    $outputName    = $archiveBase + '_anonymized'
    $outputArchive = Join-Path $archiveParent ($outputName + '.tar.gz')

    $workTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dma-anon-' + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $workTmpDir -Force | Out-Null
    Write-Log INFO "Temp dir: $workTmpDir"

    try {
        $proc = Start-Process -FilePath 'tar' `
            -ArgumentList @('-xzf', $inputFull, '-C', $workTmpDir) `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            Write-Log ERROR "tar extraction failed (exit $($proc.ExitCode))"
            Remove-Item $workTmpDir -Recurse -Force -ErrorAction SilentlyContinue
            exit 1
        }
    } catch {
        Write-Log ERROR "tar not found. Windows 10 build 1803+ required: $_"
        Remove-Item $workTmpDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

    $extractedDirs = @(Get-ChildItem -Path $workTmpDir -Directory)
    if ($extractedDirs.Count -ne 1) {
        Write-Log ERROR "Expected a single top-level directory in the archive; found $($extractedDirs.Count)."
        Remove-Item $workTmpDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Log SUCCESS "Extracted: $($extractedDirs[0].Name)"

    # Rename to the anonymized name so the final archive contains the right directory
    $renamedDir = Join-Path $workTmpDir $outputName
    Rename-Item -Path $extractedDirs[0].FullName -NewName $outputName
    $workExportDir = $renamedDir

} else {
    # -- Directory input ----------------------------------------------------
    Write-Step 'Copying Export Directory'

    if (-not (Test-Path $inputFull -PathType Container)) {
        Write-Log ERROR "Not a directory: $inputFull"
        exit 1
    }

    $inputParent   = Split-Path $inputFull -Parent
    $inputBasename = Split-Path $inputFull -Leaf
    $outputName    = $inputBasename + '_anonymized'
    $workExportDir = Join-Path $inputParent $outputName

    if (Test-Path $workExportDir) {
        Write-Log WARNING "Output directory already exists and will be overwritten: $workExportDir"
        Remove-Item $workExportDir -Recurse -Force
    }
    Copy-Item -Path $inputFull -Destination $workExportDir -Recurse
    Write-Log SUCCESS "Copied to: $workExportDir"
}

# -- Anonymize ------------------------------------------------------------------

Write-Step 'Anonymizing PII'
Invoke-AnonymizeDirectory -WorkDir $workExportDir -DryRun $DryRun.IsPresent

Write-Log SUCCESS "Files with PII processed:  $($script:FilesProcessed)"
Write-Log SUCCESS "Email addresses replaced:  $($script:EmailsReplaced)"

# -- Recreate archive -----------------------------------------------------------

if ($inputIsArchive) {
    Write-Step 'Creating Anonymized Archive'
    if ($DryRun) {
        Write-Log INFO "[dry-run] Would create: $outputArchive"
    } else {
        New-AnonymizedArchive -WorkTmpDir $workTmpDir -OutputName $outputName `
                              -OutputArchivePath $outputArchive
    }
}

# -- Cleanup temp dir -----------------------------------------------------------

if ($null -ne $workTmpDir -and (Test-Path $workTmpDir)) {
    Remove-Item $workTmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# -- Summary --------------------------------------------------------------------

Write-Header 'Anonymization Complete'

if ($inputIsArchive) {
    if ($DryRun) {
        Write-Host "  Output (dry-run): $outputArchive" -ForegroundColor Cyan
    } else {
        Write-Host "  Output archive:   $outputArchive" -ForegroundColor Cyan
        Write-Host "  SHA-256 sidecar:  $outputArchive.sha256" -ForegroundColor Cyan
    }
} else {
    Write-Host "  Output directory: $workExportDir" -ForegroundColor Cyan
}

Write-Host "  Files processed:  $($script:FilesProcessed)" -ForegroundColor Cyan
Write-Host "  Emails replaced:  $($script:EmailsReplaced)"  -ForegroundColor Cyan
Write-Host ''

if ($script:ErrorsEncountered -gt 0) { exit 1 }
