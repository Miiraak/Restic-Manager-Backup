<#
.SYNOPSIS
    Restic Manager Backup - Interactive CLI backup manager for Windows 64-bit.

.DESCRIPTION
    Multi-backend backup tool built on top of restic.
    Supported backends: S3, Swift (OpenStack), SFTP, local disk, USB key.

.NOTES
    Requirements : restic.exe placed in .\Restic\restic.exe
    Configuration: .\config.json
    Logs         : .\logs\
    Local repos  : .\repos\
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
$ScriptRoot  = $PSScriptRoot
$ConfigFile  = Join-Path $ScriptRoot "config.json"

# -----------------------------------------------------------------------------
# Helper - colored output
# -----------------------------------------------------------------------------
function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "[>] $Text" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Err {
    param([string]$Text)
    Write-Host "[ERR] $Text" -ForegroundColor Red
}

function Write-Info {
    param([string]$Text)
    Write-Host "[i] $Text" -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
$LogFile = $null   # set once config is loaded

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    if ($LogFile) { Add-Content -Path $LogFile -Value $line -Encoding UTF8 }
}

function Initialize-Log {
    param([string]$LogDir)
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $script:LogFile = Join-Path $LogDir ("backup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    Write-Log "Session started"
}

# -----------------------------------------------------------------------------
# Config loading
# -----------------------------------------------------------------------------
function Load-Config {
    if (-not (Test-Path $ConfigFile)) {
        Write-Err "config.json not found at: $ConfigFile"
        Write-Info "Create config.json in the script directory and fill in your settings (see the project documentation for details)."
        exit 1
    }
    try {
        $raw    = Get-Content $ConfigFile -Raw -Encoding UTF8
        $config = $raw | ConvertFrom-Json
        return $config
    }
    catch {
        Write-Err "Failed to parse config.json: $_"
        exit 1
    }
}

# -----------------------------------------------------------------------------
# Restic binary helper
# -----------------------------------------------------------------------------
function Get-ResticExe {
    param($Config)
    $exe = Join-Path $ScriptRoot $Config.general.restic_exe
    if (-not (Test-Path $exe)) {
        Write-Err "restic.exe not found at: $exe"
        Write-Info "Download restic from https://github.com/restic/restic/releases and place it in the Restic\ folder."
        exit 1
    }
    return $exe
}

# -----------------------------------------------------------------------------
# Environment variable helpers for backends
# -----------------------------------------------------------------------------
function Set-BackendEnv {
    param([PSCustomObject]$Backend)
    if ($Backend.env) {
        $Backend.env.PSObject.Properties | ForEach-Object {
            [System.Environment]::SetEnvironmentVariable($_.Name, $_.Value, "Process")
        }
    }
}

function Clear-BackendEnv {
    param([PSCustomObject]$Backend)
    if ($Backend.env) {
        $Backend.env.PSObject.Properties | ForEach-Object {
            [System.Environment]::SetEnvironmentVariable($_.Name, $null, "Process")
        }
    }
}

# -----------------------------------------------------------------------------
# USB / drive detection
# -----------------------------------------------------------------------------
function Find-UsbDrive {
    param([string]$Label)
    try {
        $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2 OR DriveType=3" |
                  Where-Object { $_.VolumeName -eq $Label }
        if ($drives) { return @($drives)[0].DeviceID }   # e.g. "E:"
    }
    catch {
        # CIM might not be available in all environments
    }
    return $null
}

function Detect-LocalTargets {
    <#
    .SYNOPSIS Returns a list of available local / removable drives with their labels.
    #>
    $results = @()
    try {
        Get-CimInstance -ClassName Win32_LogicalDisk |
            Where-Object { $_.DriveType -in @(2, 3) } |
            ForEach-Object {
                $results += [PSCustomObject]@{
                    DeviceID   = $_.DeviceID
                    VolumeName = $_.VolumeName
                    DriveType  = if ($_.DriveType -eq 2) { "Removable" } else { "Fixed" }
                    FreeGB     = [math]::Round($_.FreeSpace / 1GB, 2)
                    TotalGB    = [math]::Round($_.Size / 1GB, 2)
                }
            }
    }
    catch {
        Write-Info "CIM unavailable - skipping drive detection."
    }
    return $results
}

# -----------------------------------------------------------------------------
# Network connectivity check
# -----------------------------------------------------------------------------
function Test-NetworkAvailable {
    try {
        return [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    }
    catch {
        return $false
    }
}

# -----------------------------------------------------------------------------
# Resolve repository path for a backend
# -----------------------------------------------------------------------------
function Resolve-Repository {
    param([string]$BackendName, $Backend)

    if ($BackendName -eq "usb") {
        $drive = Find-UsbDrive -Label $Backend.drive_label
        if (-not $drive) {
            Write-Err "USB drive with label '$($Backend.drive_label)' not found."
            return $null
        }
        return Join-Path $drive $Backend.repository_path
    }

    if ($BackendName -eq "local") {
        $path = $Backend.repository
        if (-not [System.IO.Path]::IsPathRooted($path)) {
            $path = Join-Path $ScriptRoot $path
        }
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        return $path
    }

    # Remote backends (s3, swift, sftp): return as-is
    return $Backend.repository
}

# -----------------------------------------------------------------------------
# Restic command executor
# -----------------------------------------------------------------------------
function Invoke-Restic {
    param(
        [string]   $ResticExe,
        [string]   $Repository,
        [string]   $Password,
        [string[]] $Arguments,
        [switch]   $Silent
    )

    $env:RESTIC_REPOSITORY = $Repository
    $env:RESTIC_PASSWORD   = $Password

    Write-Log "restic $Arguments (repo: $Repository)"

    try {
        if ($Silent) {
            $output = & $ResticExe @Arguments 2>&1
            $exit   = $LASTEXITCODE
        }
        else {
            & $ResticExe @Arguments
            $exit = $LASTEXITCODE
        }
    }
    finally {
        Remove-Item Env:\RESTIC_REPOSITORY -ErrorAction SilentlyContinue
        Remove-Item Env:\RESTIC_PASSWORD   -ErrorAction SilentlyContinue
    }

    if (-not $Silent) { return $exit }
    return [PSCustomObject]@{ ExitCode = $exit; Output = $output }
}

# -----------------------------------------------------------------------------
# 1. Initialize repository
# -----------------------------------------------------------------------------
function Initialize-Repository {
    param($Config, [string]$ResticExe)

    Write-Header "Initialize repository"

    $backends = $Config.backends.PSObject.Properties
    foreach ($prop in $backends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not $backend.enabled) { Write-Info "[$name] disabled - skipped."; continue }

        # Network check for remote backends
        if ($name -in @("s3", "swift", "sftp")) {
            if (-not (Test-NetworkAvailable)) {
                Write-Err "[$name] No network available - skipped."
                Write-Log "[$name] skipped (no network)" "WARN"
                continue
            }
        }

        Write-Step "Initializing backend: $name ($($backend.description))"
        Write-Log "Initializing backend: $name"

        $repo = Resolve-Repository -BackendName $name -Backend $backend
        if (-not $repo) { continue }

        Set-BackendEnv -Backend $backend
        try {
            $result = Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                                    -Password $backend.password -Arguments @("init") -Silent
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }

        if ($result.ExitCode -eq 0) {
            Write-OK "[$name] repository initialized successfully."
            Write-Log "[$name] initialized OK" "INFO"
        }
        elseif ($result.Output -match "already initialized") {
            Write-Info "[$name] repository already initialized."
            Write-Log "[$name] already initialized" "INFO"
        }
        else {
            Write-Err "[$name] initialization failed (exit $($result.ExitCode))."
            Write-Log "[$name] initialization failed: $($result.Output)" "ERROR"
        }
    }
}

# -----------------------------------------------------------------------------
# 2. Run backup
# -----------------------------------------------------------------------------
function Start-Backup {
    param($Config, [string]$ResticExe)

    Write-Header "Run backup"

    # Build source list (expand %USERNAME% etc.)
    $sources = $Config.sources | ForEach-Object { [System.Environment]::ExpandEnvironmentVariables($_) } |
               Where-Object { Test-Path $_ }

    if ($sources.Count -eq 0) {
        Write-Err "No valid source paths found. Check the 'sources' section in config.json."
        return
    }

    # Build exclusion flags
    $excludeArgs = $Config.exclusions | ForEach-Object { "--exclude=$_" }

    $startTime = Get-Date

    $backends = $Config.backends.PSObject.Properties
    foreach ($prop in $backends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not $backend.enabled) { Write-Info "[$name] disabled - skipped."; continue }

        # Network check for remote backends
        if ($name -in @("s3", "swift", "sftp")) {
            if (-not (Test-NetworkAvailable)) {
                Write-Err "[$name] No network available - skipped."
                Write-Log "[$name] skipped (no network)" "WARN"
                continue
            }
        }

        $repo = Resolve-Repository -BackendName $name -Backend $backend
        if (-not $repo) { continue }

        Write-Step "Backing up to: $name ($($backend.description))"
        Write-Log "Starting backup to [$name] repo: $repo"

        Set-BackendEnv -Backend $backend
        try {
            $backupArgs = @("backup") + $sources + $excludeArgs + @("--compression=auto", "--json")

            $result = Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                                    -Password $backend.password -Arguments $backupArgs -Silent
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }

        if ($result.ExitCode -eq 0) {
            Write-OK "[$name] backup completed."
            Write-Log "[$name] backup OK" "INFO"

            # Parse JSON summary from restic output
            $summaryLine = ($result.Output | Select-String '"message_type":"summary"').Line
            if ($summaryLine) {
                try {
                    $summary = $summaryLine | ConvertFrom-Json
                    Write-Info ("  Files new/changed : {0} / {1}" -f $summary.files_new, $summary.files_changed)
                    Write-Info ("  Data added        : {0:F2} MiB" -f ($summary.data_added / 1MB))
                    Write-Info ("  Total duration    : {0:F1} s"   -f $summary.total_duration)
                    Write-Log  ("[$name] files_new={0} files_changed={1} data_added={2}B duration={3}s" -f
                                $summary.files_new, $summary.files_changed,
                                $summary.data_added, $summary.total_duration) "INFO"
                }
                catch {}
            }
        }
        else {
            Write-Err "[$name] backup failed (exit $($result.ExitCode))."
            $lastLine = if ($result.Output) { ($result.Output | Select-Object -Last 1).ToString() } else { "(no output)" }
            Write-Log "[$name] backup failed: $lastLine" "ERROR"
        }
    }

    $duration = (Get-Date) - $startTime
    Write-Info ("Total elapsed time: {0:mm\:ss}" -f $duration)
    Write-Log ("Total backup duration: {0:mm\:ss}" -f $duration)
}

# -----------------------------------------------------------------------------
# 3. List snapshots
# -----------------------------------------------------------------------------
function Show-Snapshots {
    param($Config, [string]$ResticExe)

    Write-Header "List snapshots"

    $backends = $Config.backends.PSObject.Properties
    foreach ($prop in $backends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not $backend.enabled) { continue }

        # Network check for remote backends
        if ($name -in @("s3", "swift", "sftp")) {
            if (-not (Test-NetworkAvailable)) {
                Write-Err "[$name] No network available - skipped."
                Write-Log "[$name] skipped (no network)" "WARN"
                continue
            }
        }

        $repo = Resolve-Repository -BackendName $name -Backend $backend
        if (-not $repo) { continue }

        Write-Step "Snapshots for backend: $name"

        Set-BackendEnv -Backend $backend
        try {
            Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                          -Password $backend.password -Arguments @("snapshots")
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }
    }
}

# -----------------------------------------------------------------------------
# 4. Restore backup
# -----------------------------------------------------------------------------
function Restore-Backup {
    param($Config, [string]$ResticExe)

    Write-Header "Restore backup"

    # Choose backend
    $enabledBackends = $Config.backends.PSObject.Properties | Where-Object { $_.Value.enabled }
    if (-not $enabledBackends) { Write-Err "No enabled backends."; return }

    Write-Host "Available backends:" -ForegroundColor White
    $i = 1
    $map = @{}
    foreach ($prop in $enabledBackends) {
        Write-Host "  [$i] $($prop.Name) - $($prop.Value.description)" -ForegroundColor White
        $map[$i] = $prop
        $i++
    }
    $choiceInput = Read-Host "Select backend number"
    [int]$choiceNumber = 0
    if (-not [int]::TryParse($choiceInput, [ref]$choiceNumber)) {
        Write-Err "Invalid selection. Please enter a valid number."
        return
    }
    $selected = $map[$choiceNumber]
    if (-not $selected) { Write-Err "Invalid selection."; return }

    $name    = $selected.Name
    $backend = $selected.Value

    $repo = Resolve-Repository -BackendName $name -Backend $backend
    if (-not $repo) { return }

    Set-BackendEnv -Backend $backend
    try {
        Write-Step "Listing snapshots for [$name]..."
        Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                      -Password $backend.password -Arguments @("snapshots")

        $snapshotId  = Read-Host "Enter snapshot ID to restore (or 'latest')"
        $restorePath = Read-Host "Enter restore destination path"

        if ([string]::IsNullOrWhiteSpace($restorePath)) {
            Write-Err "Restore path cannot be empty."
            return
        }

        Write-Step "Restoring snapshot '$snapshotId' to '$restorePath'..."
        Write-Log "Restoring [$name] snapshot $snapshotId to $restorePath"

        Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                      -Password $backend.password `
                      -Arguments @("restore", $snapshotId, "--target", $restorePath)
    }
    finally {
        Clear-BackendEnv -Backend $backend
    }
}

# -----------------------------------------------------------------------------
# 5. Verify / check repository
# -----------------------------------------------------------------------------
function Test-Repository {
    param($Config, [string]$ResticExe)

    Write-Header "Verify repository"

    $backends = $Config.backends.PSObject.Properties
    foreach ($prop in $backends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not $backend.enabled) { continue }

        # Network check for remote backends
        if ($name -in @("s3", "swift", "sftp")) {
            if (-not (Test-NetworkAvailable)) {
                Write-Err "[$name] No network available - skipped."
                Write-Log "[$name] skipped (no network)" "WARN"
                continue
            }
        }

        $repo = Resolve-Repository -BackendName $name -Backend $backend
        if (-not $repo) { continue }

        Write-Step "Checking backend: $name"
        Write-Log "Checking [$name]"

        Set-BackendEnv -Backend $backend
        try {
            $exit = Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                                  -Password $backend.password -Arguments @("check")
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }

        if ($exit -eq 0) {
            Write-OK "[$name] repository is consistent."
            Write-Log "[$name] check OK" "INFO"
        }
        else {
            Write-Err "[$name] check reported errors (exit $exit)."
            Write-Log "[$name] check errors" "ERROR"
        }
    }
}

# -----------------------------------------------------------------------------
# 6. Prune repository
# -----------------------------------------------------------------------------
function Invoke-Prune {
    param($Config, [string]$ResticExe)

    Write-Header "Prune repository"

    $ret = $Config.retention
    $retArgs = @(
        "--keep-last",    $ret.keep_last,
        "--keep-daily",   $ret.keep_daily,
        "--keep-weekly",  $ret.keep_weekly,
        "--keep-monthly", $ret.keep_monthly,
        "--keep-yearly",  $ret.keep_yearly
    )

    $backends = $Config.backends.PSObject.Properties
    foreach ($prop in $backends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not $backend.enabled) { continue }

        # Network check for remote backends
        if ($name -in @("s3", "swift", "sftp")) {
            if (-not (Test-NetworkAvailable)) {
                Write-Err "[$name] No network available - skipped."
                Write-Log "[$name] skipped (no network)" "WARN"
                continue
            }
        }

        $repo = Resolve-Repository -BackendName $name -Backend $backend
        if (-not $repo) { continue }

        Write-Step "Pruning backend: $name"
        Write-Log "Pruning [$name]"

        Set-BackendEnv -Backend $backend
        try {
            $exit = Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                                  -Password $backend.password `
                                  -Arguments (@("forget", "--prune") + $retArgs)
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }

        if ($exit -eq 0) {
            Write-OK "[$name] prune completed."
            Write-Log "[$name] prune OK" "INFO"
        }
        else {
            Write-Err "[$name] prune failed (exit $exit)."
            Write-Log "[$name] prune failed" "ERROR"
        }
    }
}

# -----------------------------------------------------------------------------
# 7. Repository statistics
# -----------------------------------------------------------------------------
function Show-Stats {
    param($Config, [string]$ResticExe)

    Write-Header "Repository statistics"

    $backends = $Config.backends.PSObject.Properties
    foreach ($prop in $backends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not $backend.enabled) { continue }

        # Network check for remote backends
        if ($name -in @("s3", "swift", "sftp")) {
            if (-not (Test-NetworkAvailable)) {
                Write-Err "[$name] No network available - skipped."
                Write-Log "[$name] skipped (no network)" "WARN"
                continue
            }
        }

        $repo = Resolve-Repository -BackendName $name -Backend $backend
        if (-not $repo) { continue }

        Write-Step "Stats for backend: $name"

        Set-BackendEnv -Backend $backend
        try {
            Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                          -Password $backend.password -Arguments @("stats")
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }
    }
}

# -----------------------------------------------------------------------------
# 8. Detect available targets
# -----------------------------------------------------------------------------
function Show-Targets {
    param($Config)

    Write-Header "Detect available targets"

    Write-Step "Local / removable drives:"
    $drives = Detect-LocalTargets
    if ($drives.Count -eq 0) {
        Write-Info "No drives detected (may require elevated privileges)."
    }
    else {
        $drives | Format-Table DeviceID, VolumeName, DriveType, FreeGB, TotalGB -AutoSize
    }

    Write-Step "USB backend configuration:"
    $usb = $Config.backends.usb
    if ($usb.enabled) {
        $drive = Find-UsbDrive -Label $usb.drive_label
        if ($drive) {
            Write-OK "USB drive '$($usb.drive_label)' found at $drive"
        }
        else {
            Write-Info "USB drive '$($usb.drive_label)' NOT found."
        }
    }
    else {
        Write-Info "USB backend is disabled in config.json."
    }

    Write-Step "Network availability:"
    if (Test-NetworkAvailable) {
        Write-OK "Network is available."
    }
    else {
        Write-Err "No network detected."
    }
}

# -----------------------------------------------------------------------------
# Purge old log files
# -----------------------------------------------------------------------------
function Remove-OldLogs {
    param([string]$LogDir, [int]$RetentionDays)
    if (-not (Test-Path $LogDir)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $LogDir -Filter "*.log" |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            }
            catch {
                Write-Warning ("Failed to remove old log file '{0}': {1}" -f $_.FullName, $_.Exception.Message)
            }
        }
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------
function Show-Menu {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "   Restic Manager Backup - Multi-backend CLI" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  1. Initialize repository"          -ForegroundColor White
    Write-Host "  2. Run backup (all enabled backends)" -ForegroundColor White
    Write-Host "  3. List snapshots"                 -ForegroundColor White
    Write-Host "  4. Restore backup"                 -ForegroundColor White
    Write-Host "  5. Verify repository"              -ForegroundColor White
    Write-Host "  6. Prune repository"               -ForegroundColor White
    Write-Host "  7. Repository statistics"          -ForegroundColor White
    Write-Host "  8. Detect available targets"       -ForegroundColor White
    Write-Host "  0. Quit"                           -ForegroundColor DarkGray
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
$Config    = Load-Config
$ResticExe = Get-ResticExe -Config $Config
$LogDir    = Join-Path $ScriptRoot $Config.general.log_dir
Initialize-Log -LogDir $LogDir

# Purge old logs
Remove-OldLogs -LogDir $LogDir -RetentionDays $Config.general.log_retention_days

while ($true) {
    Show-Menu
    $choice = Read-Host "Enter your choice"

    switch ($choice) {
        "1" { Initialize-Repository -Config $Config -ResticExe $ResticExe }
        "2" { Start-Backup          -Config $Config -ResticExe $ResticExe }
        "3" { Show-Snapshots        -Config $Config -ResticExe $ResticExe }
        "4" { Restore-Backup        -Config $Config -ResticExe $ResticExe }
        "5" { Test-Repository       -Config $Config -ResticExe $ResticExe }
        "6" { Invoke-Prune          -Config $Config -ResticExe $ResticExe }
        "7" { Show-Stats            -Config $Config -ResticExe $ResticExe }
        "8" { Show-Targets          -Config $Config }
        "0" {
            Write-Log "Session ended by user"
            Write-Host "`nGoodbye!" -ForegroundColor Cyan
            exit 0
        }
        default {
            Write-Err "Invalid choice. Please enter a number between 0 and 8."
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to the menu" | Out-Null
}
