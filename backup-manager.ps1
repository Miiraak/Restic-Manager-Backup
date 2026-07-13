<#
.SYNOPSIS
    Restic Manager Backup - Interactive CLI backup manager for Windows 64-bit.

.DESCRIPTION
    Multi-backend backup tool built on top of restic.
    Supported backends: S3, Swift (OpenStack), SFTP, local disk, USB key.
    Features: progress bar, verbose output, dry-run, snapshot browsing,
    per-backend selection, config validation, backup type selection,
    partial restore, config editing, and more.

.NOTES
    Version      : 3.0.0
    Requirements : restic.exe placed in .\Restic\restic.exe
    Configuration: .\config.json
    Logs         : .\logs\
    Local repos  : .\repos\
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:BackRequested  = $false

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
$ScriptRoot  = $PSScriptRoot
$ConfigFile  = Join-Path $ScriptRoot "config.json"
$ScriptVersion = "3.0.0"

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

function Write-Warn {
    param([string]$Text)
    Write-Host "[!] $Text" -ForegroundColor DarkYellow
}

function Write-Detail {
    param([string]$Text)
    Write-Host "    $Text" -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
# Helper - ASCII menu transition
# -----------------------------------------------------------------------------
function Write-Transition {
    param([string]$Target = "")
    $width = 60
    Write-Host ""
    Write-Host ("." * $width) -ForegroundColor DarkGray
    if ($Target) {
        Write-Host "  >> $Target" -ForegroundColor DarkCyan
    }
    Write-Host ("." * $width) -ForegroundColor DarkGray
    Write-Host ""
}

function Write-Separator {
    Write-Host ("─" * 60) -ForegroundColor DarkGray
}

# -----------------------------------------------------------------------------
# Helper - ASCII progress bar (in-place, colored)
# -----------------------------------------------------------------------------
function Write-AsciiProgress {
    param(
        [string] $Activity,
        [double] $PercentComplete,
        [string] $Status,
        [switch] $Completed
    )

    $width = 120
    try {
        # Prefer the visible window width to avoid wrapping when buffer > window
        $width = [Console]::WindowWidth
    } catch {
        try {
            $width = [Console]::BufferWidth
        } catch {
            # Fall back to the default width if console information is unavailable
        }
    }

    # Clamp to a sane minimum to avoid zero/negative lengths
    if (-not $width -or $width -lt 20) {
        $width = 20
    }
    $maxLen = $width - 1   # leave 1-char margin to avoid line wrap

    if ($Completed) {
        Write-Host ("`r" + (" " * $maxLen)) -NoNewline
        Write-Host "`r" -NoNewline
        return
    }

    $barWidth = 30
    $pct = [math]::Max(0, [math]::Min(100, $PercentComplete))
    $filled = [int][math]::Floor($pct / 100 * $barWidth)
    $empty  = $barWidth - $filled

    # Build bar segments
    if ($filled -gt 0 -and $empty -gt 0) {
        $barFilled = ("=" * ($filled - 1)) + ">"
        $barEmpty  = ("-" * $empty)
    }
    elseif ($filled -ge $barWidth) {
        $barFilled = "=" * $barWidth
        $barEmpty  = ""
    }
    else {
        $barFilled = ""
        $barEmpty  = "-" * $barWidth
    }

    $pctStr = "{0,5:F1}%" -f $pct

    # Truncate status so the full line fits inside the console width
    # Fixed parts: "  " + Activity + " [" + bar + "] " + pctStr + "  " + Status
    $fixedLen = 2 + $Activity.Length + 2 + $barWidth + 2 + $pctStr.Length + 2
    $maxStatus = $maxLen - $fixedLen
    if ($maxStatus -lt 0) { $maxStatus = 0 }
    if ($Status.Length -gt $maxStatus) {
        if ($maxStatus -gt 3) {
            $Status = "..." + $Status.Substring($Status.Length - ($maxStatus - 3))
        }
        else {
            $Status = $Status.Substring(0, $maxStatus)
        }
    }

    # Write the bar with colors via individual segments
    Write-Host "`r" -NoNewline
    Write-Host "  " -NoNewline
    Write-Host $Activity -ForegroundColor Cyan -NoNewline
    Write-Host " [" -NoNewline
    if ($barFilled) { Write-Host $barFilled -ForegroundColor Green -NoNewline }
    if ($barEmpty)  { Write-Host $barEmpty  -ForegroundColor DarkGray -NoNewline }
    Write-Host "] " -NoNewline
    Write-Host $pctStr -ForegroundColor Yellow -NoNewline
    Write-Host "  " -NoNewline
    Write-Host $Status -ForegroundColor Gray -NoNewline

    # Pad remainder to overwrite any leftover characters from previous longer line
    $usedLen = 2 + $Activity.Length + 2 + $barFilled.Length + $barEmpty.Length + 2 + $pctStr.Length + 2 + $Status.Length
    $pad = $maxLen - $usedLen
    if ($pad -gt 0) { Write-Host (" " * $pad) -NoNewline }
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
$LogFile = $null   # set once config is loaded

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if (-not $LogFile) { return }
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    # Direct .NET call avoids cmdlet overhead (parameter binding, provider resolution)
    try {
        [System.IO.File]::AppendAllText($LogFile, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    }
    catch {
        # Logging is best-effort and should not interrupt backup/restore operations
    }
}

function Initialize-Log {
    param([string]$LogDir)
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $script:LogFile = Join-Path $LogDir ("backup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
    Write-Log "Session started (v$ScriptVersion)"
}

# -----------------------------------------------------------------------------
# Config loading & validation
# -----------------------------------------------------------------------------
function Import-Config {
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

function Test-Config {
    param($Config)

    $errors   = @()
    $warnings = @()

    # Check general section (critical)
    if (-not $Config.general) {
        $errors += "Missing 'general' section in config.json."
    }
    else {
        if (-not $Config.general.restic_exe) { $errors += "Missing 'general.restic_exe' field." }
        if (-not $Config.general.log_dir)    { $errors += "Missing 'general.log_dir' field." }
        if ($null -eq $Config.general.log_retention_days) { $warnings += "Missing 'general.log_retention_days' field (defaulting to 30 days)." }
    }

    # Check sources
    if (-not $Config.sources -or @($Config.sources).Count -eq 0) {
        $warnings += "No source paths defined in 'sources' section."
    }

    # Check retention
    if (-not $Config.retention) {
        $warnings += "Missing 'retention' section."
    }
    else {
        $retFields = @("keep_last", "keep_daily", "keep_weekly", "keep_monthly", "keep_yearly")
        foreach ($f in $retFields) {
            if ($null -eq $Config.retention.$f) { $warnings += "Missing 'retention.$f' field." }
        }
    }

    # Check backends (critical)
    if (-not $Config.backends) {
        $errors += "Missing 'backends' section."
    }
    else {
        $enabledCount = 0
        foreach ($prop in $Config.backends.PSObject.Properties) {
            $name = $prop.Name
            $b    = $prop.Value
            if ($b.enabled) {
                $enabledCount++
                if (-not $b.password) { $warnings += "Backend '$name' is enabled but has no password set." }
                if ($name -ne "usb" -and -not $b.repository) {
                    $warnings += "Backend '$name' is enabled but has no repository path."
                }
                if ($name -eq "usb") {
                    if (-not $b.drive_label) { $warnings += "USB backend enabled but 'drive_label' not set." }
                    if (-not $b.repository_path) { $warnings += "USB backend enabled but 'repository_path' not set." }
                }
            }
        }
        if ($enabledCount -eq 0) { $warnings += "No backends are enabled. Enable at least one backend." }
    }

    # Show errors
    if ($errors.Count -gt 0) {
        Write-Err "Configuration errors (cannot continue):"
        foreach ($e in $errors) {
            Write-Detail "- $e"
        }
        Write-Host ""
    }

    # Show warnings
    if ($warnings.Count -gt 0) {
        Write-Warn "Configuration warnings:"
        foreach ($w in $warnings) {
            Write-Detail "- $w"
        }
        Write-Host ""
    }

    return $errors.Count -eq 0
}

# -----------------------------------------------------------------------------
# Config helper - get optional fields with defaults
# -----------------------------------------------------------------------------
function Get-ConfigValue {
    param($Config, [string]$Path, $Default)
    $parts = $Path.Split(".")
    $current = $Config
    foreach ($part in $parts) {
        if ($null -eq $current) { return $Default }
        try {
            $current = $current.$part
        }
        catch {
            return $Default
        }
        if ($null -eq $current) { return $Default }
    }
    return $current
}

# -----------------------------------------------------------------------------
# Config editing and reloading from CLI
# -----------------------------------------------------------------------------
function Invoke-ConfigReload {
    <#
    .SYNOPSIS Reloads config.json and re-validates. Returns new config or $null on failure.
    #>
    Write-Step "Reloading configuration..."
    $newConfig = Import-Config
    $valid = Test-Config -Config $newConfig
    if ($valid) {
        Write-OK "Configuration reloaded successfully."
        Write-Log "Configuration reloaded" "INFO"
        return $newConfig
    }
    else {
        Write-Err "Configuration has errors. Keeping previous configuration."
        Write-Log "Config reload failed validation" "WARN"
        return $null
    }
}

function Edit-ConfigSection {
    <#
    .SYNOPSIS Interactive config editor - allows viewing/editing sections from CLI.
    #>
    param([ref]$ConfigRef)

    while ($true) {
        Write-Transition "Configuration Editor"
        Write-Header "Configuration Editor"

        Write-Host ""
        Write-Host "  Current config: $ConfigFile" -ForegroundColor Gray
        Write-Separator
        Write-Host "  1.  View current configuration"         -ForegroundColor White
        Write-Host "  2.  Edit source paths"                  -ForegroundColor White
        Write-Host "  3.  Edit exclusion patterns"            -ForegroundColor White
        Write-Host "  4.  Edit retention policy"              -ForegroundColor White
        Write-Host "  5.  Toggle backends (enable/disable)"   -ForegroundColor White
        Write-Host "  6.  Edit general settings"              -ForegroundColor White
        Write-Host "  7.  Reload config from disk"            -ForegroundColor White
        Write-Host "  8.  Open config.json in editor"         -ForegroundColor White
        Write-Host "  0.  Back"                               -ForegroundColor DarkGray
        Write-Separator

        $editChoice = Read-Host "  Your choice"

        switch ($editChoice) {
            "1" { Show-CurrentConfig -Config $ConfigRef.Value }
            "2" { Edit-Sources -ConfigRef $ConfigRef }
            "3" { Edit-Exclusions -ConfigRef $ConfigRef }
            "4" { Edit-Retention -ConfigRef $ConfigRef }
            "5" { Edit-BackendToggle -ConfigRef $ConfigRef }
            "6" { Edit-GeneralSettings -ConfigRef $ConfigRef }
            "7" {
                $reloaded = Invoke-ConfigReload
                if ($reloaded) { $ConfigRef.Value = $reloaded }
            }
            "8" { Open-ConfigInEditor }
            "0" { $script:BackRequested = $true; return }
            default { Write-Err "Invalid choice." }
        }

        if (-not $script:BackRequested) {
            Write-Host ""
            Read-Host "Press Enter to continue" | Out-Null
        }
        $script:BackRequested = $false
    }
}

function Show-CurrentConfig {
    param($Config)
    Write-Host ""
    Write-Host "  [General]" -ForegroundColor Cyan
    Write-Detail "  Verbose       : $($Config.general.verbose)"
    Write-Detail "  Compression   : $($Config.general.compression)"
    Write-Detail "  One filesystem: $($Config.general.one_file_system)"
    Write-Detail "  Exclude caches: $($Config.general.exclude_caches)"

    Write-Host ""
    Write-Host "  [Sources]" -ForegroundColor Cyan
    $i = 1
    foreach ($src in $Config.sources) {
        Write-Detail "  $i. $src"
        $i++
    }

    Write-Host ""
    Write-Host "  [Exclusions]" -ForegroundColor Cyan
    foreach ($ex in $Config.exclusions) {
        Write-Detail "  - $ex"
    }

    Write-Host ""
    Write-Host "  [Retention]" -ForegroundColor Cyan
    Write-Detail "  keep_last    : $($Config.retention.keep_last)"
    Write-Detail "  keep_daily   : $($Config.retention.keep_daily)"
    Write-Detail "  keep_weekly  : $($Config.retention.keep_weekly)"
    Write-Detail "  keep_monthly : $($Config.retention.keep_monthly)"
    Write-Detail "  keep_yearly  : $($Config.retention.keep_yearly)"

    Write-Host ""
    Write-Host "  [Backends]" -ForegroundColor Cyan
    foreach ($prop in $Config.backends.PSObject.Properties) {
        $status = if ($prop.Value.enabled) { "[ON]" } else { "[OFF]" }
        Write-Detail "  $status $($prop.Name) - $($prop.Value.description)"
    }
}

function Edit-Sources {
    param([ref]$ConfigRef)
    $config = $ConfigRef.Value

    Write-Host ""
    Write-Host "  Current sources:" -ForegroundColor Cyan
    $i = 1
    foreach ($src in $config.sources) {
        Write-Host "  $i. $src" -ForegroundColor White
        $i++
    }
    Write-Host ""
    Write-Host "  [A] Add a source path" -ForegroundColor White
    Write-Host "  [R] Remove a source path" -ForegroundColor White
    Write-Host "  [B] Back" -ForegroundColor DarkGray

    $action = Read-Host "  Action"
    switch ($action.ToUpper()) {
        "A" {
            $newPath = Read-Host "  Enter new source path"
            if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                $config.sources = @($config.sources) + @($newPath)
                Save-Config -Config $config
                Write-OK "Source added: $newPath"
            }
        }
        "R" {
            $idx = Read-Host "  Enter number to remove"
            [int]$num = 0
            if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le @($config.sources).Count) {
                $removed = $config.sources[$num - 1]
                $config.sources = @($config.sources | Where-Object { $_ -ne $removed })
                Save-Config -Config $config
                Write-OK "Removed: $removed"
            }
            else { Write-Err "Invalid selection." }
        }
    }
}

function Edit-Exclusions {
    param([ref]$ConfigRef)
    $config = $ConfigRef.Value

    Write-Host ""
    Write-Host "  Current exclusions:" -ForegroundColor Cyan
    $i = 1
    foreach ($ex in $config.exclusions) {
        Write-Host "  $i. $ex" -ForegroundColor White
        $i++
    }
    Write-Host ""
    Write-Host "  [A] Add an exclusion pattern" -ForegroundColor White
    Write-Host "  [R] Remove an exclusion pattern" -ForegroundColor White
    Write-Host "  [B] Back" -ForegroundColor DarkGray

    $action = Read-Host "  Action"
    switch ($action.ToUpper()) {
        "A" {
            $newPattern = Read-Host "  Enter exclusion pattern (e.g. '*.tmp')"
            if (-not [string]::IsNullOrWhiteSpace($newPattern)) {
                $config.exclusions = @($config.exclusions) + @($newPattern)
                Save-Config -Config $config
                Write-OK "Exclusion added: $newPattern"
            }
        }
        "R" {
            $idx = Read-Host "  Enter number to remove"
            [int]$num = 0
            if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le @($config.exclusions).Count) {
                $removed = $config.exclusions[$num - 1]
                $config.exclusions = @($config.exclusions | Where-Object { $_ -ne $removed })
                Save-Config -Config $config
                Write-OK "Removed: $removed"
            }
            else { Write-Err "Invalid selection." }
        }
    }
}

function Edit-Retention {
    param([ref]$ConfigRef)
    $config = $ConfigRef.Value

    Write-Host ""
    Write-Host "  Current retention policy:" -ForegroundColor Cyan
    Write-Detail "  1. keep_last    : $($config.retention.keep_last)"
    Write-Detail "  2. keep_daily   : $($config.retention.keep_daily)"
    Write-Detail "  3. keep_weekly  : $($config.retention.keep_weekly)"
    Write-Detail "  4. keep_monthly : $($config.retention.keep_monthly)"
    Write-Detail "  5. keep_yearly  : $($config.retention.keep_yearly)"
    Write-Host ""

    $field = Read-Host "  Enter field number to edit (or Enter to skip)"
    if ([string]::IsNullOrWhiteSpace($field)) { return }

    $fieldMap = @{ "1" = "keep_last"; "2" = "keep_daily"; "3" = "keep_weekly"; "4" = "keep_monthly"; "5" = "keep_yearly" }
    if (-not $fieldMap.ContainsKey($field)) { Write-Err "Invalid field."; return }

    $fieldName = $fieldMap[$field]
    $newVal = Read-Host "  New value for $fieldName"
    [int]$intVal = 0
    if ([int]::TryParse($newVal, [ref]$intVal) -and $intVal -ge 0) {
        $config.retention.$fieldName = $intVal
        Save-Config -Config $config
        Write-OK "$fieldName set to $intVal"
    }
    else { Write-Err "Invalid number." }
}

function Edit-BackendToggle {
    param([ref]$ConfigRef)
    $config = $ConfigRef.Value

    Write-Host ""
    Write-Host "  Backends:" -ForegroundColor Cyan
    $i = 1
    $backendList = @($config.backends.PSObject.Properties)
    foreach ($prop in $backendList) {
        $status = if ($prop.Value.enabled) { "[ON] " } else { "[OFF]" }
        Write-Host "  $i. $status $($prop.Name) - $($prop.Value.description)" -ForegroundColor White
        $i++
    }
    Write-Host ""

    $idx = Read-Host "  Enter number to toggle (or Enter to skip)"
    [int]$num = 0
    if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le $backendList.Count) {
        $target = $backendList[$num - 1]
        $target.Value.enabled = -not $target.Value.enabled
        $newState = if ($target.Value.enabled) { "enabled" } else { "disabled" }
        Save-Config -Config $config
        Write-OK "$($target.Name) is now $newState."
    }
    else { Write-Err "Invalid selection." }
}

function Edit-GeneralSettings {
    param([ref]$ConfigRef)
    $config = $ConfigRef.Value

    Write-Host ""
    Write-Host "  General settings:" -ForegroundColor Cyan
    Write-Host "  1. Verbose        : $($config.general.verbose)" -ForegroundColor White
    Write-Host "  2. Compression    : $($config.general.compression)" -ForegroundColor White
    Write-Host "  3. One filesystem : $($config.general.one_file_system)" -ForegroundColor White
    Write-Host "  4. Exclude caches : $($config.general.exclude_caches)" -ForegroundColor White
    Write-Host "  5. Log retention  : $($config.general.log_retention_days) days" -ForegroundColor White
    Write-Host ""

    $field = Read-Host "  Enter field number to edit (or Enter to skip)"
    switch ($field) {
        "1" {
            $config.general.verbose = -not $config.general.verbose
            Save-Config -Config $config
            Write-OK "Verbose set to $($config.general.verbose)"
        }
        "2" {
            Write-Info "Options: auto, off, max"
            $val = Read-Host "  New compression mode"
            if ($val -in @("auto", "off", "max")) {
                $config.general.compression = $val
                Save-Config -Config $config
                Write-OK "Compression set to $val"
            }
            else { Write-Err "Invalid value." }
        }
        "3" {
            $config.general.one_file_system = -not $config.general.one_file_system
            Save-Config -Config $config
            Write-OK "One filesystem set to $($config.general.one_file_system)"
        }
        "4" {
            $config.general.exclude_caches = -not $config.general.exclude_caches
            Save-Config -Config $config
            Write-OK "Exclude caches set to $($config.general.exclude_caches)"
        }
        "5" {
            $val = Read-Host "  New log retention (days)"
            [int]$intVal = 0
            if ([int]::TryParse($val, [ref]$intVal) -and $intVal -gt 0) {
                $config.general.log_retention_days = $intVal
                Save-Config -Config $config
                Write-OK "Log retention set to $intVal days"
            }
            else { Write-Err "Invalid number." }
        }
    }
}

function Open-ConfigInEditor {
    Write-Step "Opening config.json..."
    try {
        $editor = $env:EDITOR
        if (-not $editor) {
            # Try notepad on Windows
            $editor = "notepad.exe"
        }
        Start-Process -FilePath $editor -ArgumentList $ConfigFile -ErrorAction Stop
        Write-OK "Opened in $editor. Reload config after saving changes (option 7)."
    }
    catch {
        Write-Err "Could not open editor: $_"
        Write-Info "Edit manually: $ConfigFile"
    }
}

function Save-Config {
    param($Config)
    try {
        $json = $Config | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($ConfigFile, $json, [System.Text.Encoding]::UTF8)
        Write-Log "Configuration saved to disk" "INFO"
    }
    catch {
        Write-Err "Failed to save config: $_"
        Write-Log "Config save failed: $_" "ERROR"
    }
}

# -----------------------------------------------------------------------------
# Helper - parse backup/restore summary from restic output lines
# -----------------------------------------------------------------------------
function Find-Summary {
    <#
    .SYNOPSIS Searches an array of output lines for a restic JSON summary object.
    Returns the parsed summary or $null.
    #>
    param([object[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match '"message_type"\s*:\s*"summary"') {
            # -ErrorAction Stop ensures parse failures are caught; silently skip malformed/truncated lines.
            try { return ($line | ConvertFrom-Json -ErrorAction Stop) } catch { }
        }
    }
    return $null
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
        foreach ($prop in $Backend.env.PSObject.Properties) {
            [System.Environment]::SetEnvironmentVariable($prop.Name, $prop.Value, "Process")
        }
    }
}

function Clear-BackendEnv {
    param([PSCustomObject]$Backend)
    if ($Backend.env) {
        foreach ($prop in $Backend.env.PSObject.Properties) {
            [System.Environment]::SetEnvironmentVariable($prop.Name, $null, "Process")
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

function Get-LocalTargets {
    <#
    .SYNOPSIS Returns a list of available local / removable drives with their labels.
    #>
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2 OR DriveType=3"
        foreach ($disk in $disks) {
            $results.Add([PSCustomObject]@{
                DeviceID   = $disk.DeviceID
                VolumeName = $disk.VolumeName
                DriveType  = if ($disk.DriveType -eq 2) { "Removable" } else { "Fixed" }
                FreeGB     = [math]::Round($disk.FreeSpace / 1GB, 2)
                TotalGB    = [math]::Round($disk.Size / 1GB, 2)
            })
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
            # Temporarily set Continue so 2>&1 captures stderr as ErrorRecord
            # objects instead of throwing a terminating NativeCommandError.
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = & $ResticExe @Arguments 2>&1
                $exit   = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $prevEAP
            }
        }
        else {
            & $ResticExe @Arguments | Out-Host
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
# Restic command executor with real-time progress bar
# -----------------------------------------------------------------------------
function ConvertTo-EscapedArg {
    <#
    .SYNOPSIS Escapes a single argument for use in ProcessStartInfo.Arguments.
    #>
    param([string]$Arg)
    if ($Arg -eq "") { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    # Escape embedded double-quotes and wrap in double-quotes
    return '"' + ($Arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-ResticWithProgress {
    param(
        [string]   $ResticExe,
        [string]   $Repository,
        [string]   $Password,
        [string[]] $Arguments,
        [string]   $BackendName,
        [string]   $ActivityName = ""
    )

    if (-not $ActivityName) { $ActivityName = "Backup to $BackendName" }

    $env:RESTIC_REPOSITORY = $Repository
    $env:RESTIC_PASSWORD   = $Password

    Write-Log "restic $Arguments (repo: $Repository)"

    $summary         = $null
    $lastFile        = ""
    $diagnostics     = [System.Collections.Generic.List[string]]::new()
    $stderrBuilder   = $null
    $stderrSourceId  = $null
    $stderrJob       = $null
    $process         = $null
    $exitCode        = 1

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $ResticExe
        $psi.Arguments              = ($Arguments | ForEach-Object { ConvertTo-EscapedArg $_ }) -join " "
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        # Pass environment
        $psi.EnvironmentVariables["RESTIC_REPOSITORY"] = $Repository
        $psi.EnvironmentVariables["RESTIC_PASSWORD"]   = $Password

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $process.EnableRaisingEvents = $true

        # Drain stderr concurrently to prevent buffer-full deadlock
        $stderrBuilder = New-Object System.Text.StringBuilder
        $stderrSourceId = "ResticStderr_$([guid]::NewGuid().ToString('N'))"
        $stderrJob = Register-ObjectEvent -InputObject $process `
            -EventName ErrorDataReceived -SourceIdentifier $stderrSourceId -Action {
                if ($null -ne $EventArgs.Data) {
                    [void]$Event.MessageData.AppendLine($EventArgs.Data)
                }
            } -MessageData $stderrBuilder

        $process.Start() | Out-Null
        $process.BeginErrorReadLine()

        # Read stdout line by line for JSON status.
        # Throttle progress bar to reduce overhead (restic emits status very frequently).
        $progressSw = [System.Diagnostics.Stopwatch]::StartNew()
        $progressIntervalMs = 250

        while (-not $process.StandardOutput.EndOfStream) {
            $line = $process.StandardOutput.ReadLine()

            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            # Fast pre-check: restic JSON lines always start with '{'
            if ($line[0] -ne '{') {
                $diagnostics.Add($line)
                continue
            }

            try {
                $json = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $json) {
                    $diagnostics.Add($line)
                    continue
                }

                if ($json.message_type -eq "status") {
                    # Only refresh the progress bar once per throttle interval
                    if ($progressSw.ElapsedMilliseconds -lt $progressIntervalMs) { continue }
                    $progressSw.Restart()

                    # Percentage: prefer restic-provided percent_done (0..1), fall back to bytes or files ratio
                    $pctDone = 0
                    if ($null -ne $json.percent_done) {
                        $pctDone = [math]::Min(100, [math]::Round($json.percent_done * 100, 1))
                    }
                    elseif ($json.total_bytes -and $json.total_bytes -gt 0) {
                        $done = if ($json.bytes_done) { $json.bytes_done } elseif ($json.bytes_restored) { $json.bytes_restored } else { 0 }
                        $pctDone = [math]::Min(100, [math]::Round(($done / $json.total_bytes) * 100, 1))
                    }
                    elseif ($json.total_files -and $json.total_files -gt 0) {
                        $done = if ($json.files_done) { $json.files_done } elseif ($json.files_restored) { $json.files_restored } else { 0 }
                        $pctDone = [math]::Min(100, [math]::Round(($done / $json.total_files) * 100, 1))
                    }

                    # Current file being processed (backup only)
                    $currentFiles = @($json.current_files)
                    if ($currentFiles -and $currentFiles.Count -gt 0 -and $null -ne $currentFiles[0]) {
                        $lastFile = $currentFiles[0]
                    }

                    # File counts: backup uses files_done, restore uses files_restored
                    $filesDone  = if ($json.files_done) { $json.files_done } elseif ($json.files_restored) { $json.files_restored } else { 0 }
                    $totalFiles = if ($json.total_files) { $json.total_files } else { 0 }
                    $bytesDone  = if ($json.bytes_done)  { $json.bytes_done } elseif ($json.bytes_restored) { $json.bytes_restored } else { 0 }

                    $bytesDoneMB = [math]::Round($bytesDone / 1MB, 1)

                    $statusText = "[$BackendName] Files: $filesDone/$totalFiles | ${bytesDoneMB} MiB"
                    if ($lastFile) { $statusText += " | $lastFile" }

                    Write-AsciiProgress -Activity $ActivityName `
                                        -PercentComplete $pctDone `
                                        -Status $statusText
                }
                elseif ($json.message_type -eq "summary") {
                    $summary = $json
                    $diagnostics.Add($line)
                }
                else {
                    # Retain any non-status JSON (e.g. error messages)
                    $diagnostics.Add($line)
                }
            }
            catch {
                # Not JSON or parse error - ignore
            }
        }

        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        # Clean up stderr event handler and background job
        if ($stderrSourceId) {
            Unregister-Event -SourceIdentifier $stderrSourceId -Force -ErrorAction SilentlyContinue
        }
        if ($stderrJob) {
            Remove-Job -Id $stderrJob.Id -Force -ErrorAction SilentlyContinue
        }

        # Collect any stderr output that was captured asynchronously
        if ($stderrBuilder -and $stderrBuilder.Length -gt 0) {
            $stderrText = $stderrBuilder.ToString()
            if ($stderrText) { $diagnostics.Add($stderrText) }
        }

        # Release the native process handle
        if ($process) { $process.Dispose() }

        Remove-Item Env:\RESTIC_REPOSITORY -ErrorAction SilentlyContinue
        Remove-Item Env:\RESTIC_PASSWORD   -ErrorAction SilentlyContinue
        Write-AsciiProgress -Activity $ActivityName -Completed
        Write-Host ""   # move to new line after the progress bar
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $diagnostics
        Summary  = $summary
    }
}

# -----------------------------------------------------------------------------
# Backend selection helper
# -----------------------------------------------------------------------------
function Select-Backends {
    param($Config, [string]$Operation, [string[]]$BackendNames)

    $enabledBackends = $Config.backends.PSObject.Properties | Where-Object { $_.Value.enabled }
    if ($BackendNames) {
        $enabledBackends = @($enabledBackends | Where-Object { $_.Name -in $BackendNames })
    }
    if (-not $enabledBackends) {
        Write-Err "No enabled backends found."
        return @()
    }

    $enabledList = @($enabledBackends)
    if ($enabledList.Count -eq 1) {
        return $enabledList
    }

    Write-Host ""
    Write-Host "  Select backends for ${Operation}:" -ForegroundColor White
    Write-Host "  [A] All enabled backends ($($enabledList.Count))" -ForegroundColor White
    $i = 1
    foreach ($prop in $enabledList) {
        Write-Host "  [$i] $($prop.Name) - $($prop.Value.description)" -ForegroundColor White
        $i++
    }
    Write-Host "  [B] Back" -ForegroundColor DarkGray

    $userChoice = Read-Host "  Your choice (A, number, or B to go back)"

    if ($userChoice -eq "B" -or $userChoice -eq "b") {
        Write-Info "Cancelled."
        $script:BackRequested = $true
        return @()
    }

    if ($userChoice -eq "A" -or $userChoice -eq "a" -or $userChoice -eq "") {
        return $enabledList
    }

    [int]$choiceNumber = 0
    if ([int]::TryParse($userChoice, [ref]$choiceNumber) -and $choiceNumber -ge 1 -and $choiceNumber -le $enabledList.Count) {
        return @($enabledList[$choiceNumber - 1])
    }

    Write-Err "Invalid selection. Using all backends."
    return $enabledList
}

function Select-SingleBackend {
    <#
    .SYNOPSIS Prompts the user to pick exactly one enabled backend.
    Returns the selected PSNoteProperty (Name + Value) or $null on failure.
    #>
    param($Config, [string]$Operation)

    $enabledBackends = $Config.backends.PSObject.Properties | Where-Object { $_.Value.enabled }
    if (-not $enabledBackends) { Write-Err "No enabled backends."; return $null }

    $enabledList = @($enabledBackends)
    if ($enabledList.Count -eq 1) { return $enabledList[0] }

    Write-Host ""
    Write-Host "  Select backend for ${Operation}:" -ForegroundColor White
    $i = 1
    foreach ($prop in $enabledList) {
        Write-Host "  [$i] $($prop.Name) - $($prop.Value.description)" -ForegroundColor White
        $i++
    }
    Write-Host "  [B] Back" -ForegroundColor DarkGray
    $userChoice = Read-Host "  Your choice (number or B to go back)"

    if ($userChoice -eq "B" -or $userChoice -eq "b") {
        Write-Info "Cancelled."
        $script:BackRequested = $true
        return $null
    }

    [int]$choiceNumber = 0
    if ([int]::TryParse($userChoice, [ref]$choiceNumber) -and $choiceNumber -ge 1 -and $choiceNumber -le $enabledList.Count) {
        return $enabledList[$choiceNumber - 1]
    }

    Write-Err "Invalid selection."
    return $null
}

# -----------------------------------------------------------------------------
# Network check helper for backend
# -----------------------------------------------------------------------------
function Test-BackendNetwork {
    param([string]$Name)
    if ($Name -in @("s3", "swift", "sftp")) {
        if (-not (Test-NetworkAvailable)) {
            Write-Err "[$Name] No network available - skipped."
            Write-Log "[$Name] skipped (no network)" "WARN"
            return $false
        }
    }
    return $true
}

# -----------------------------------------------------------------------------
# 1. Initialize repository
# -----------------------------------------------------------------------------
function Initialize-Repository {
    param($Config, [string]$ResticExe)

    Write-Header "Initialize repository"

    $selectedBackends = @(Select-Backends -Config $Config -Operation "initialization")
    if ($selectedBackends.Count -eq 0) { return }

    foreach ($prop in $selectedBackends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not (Test-BackendNetwork -Name $name)) { continue }

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
# Shared helper - build common backup arguments (exclusions, compression, etc.)
# Returns a hashtable with ExcludeArgs, CompressionArg, OfsArg, TagArgs.
# -----------------------------------------------------------------------------
function Build-BackupArguments {
    param($Config)

    $general = $Config.general

    $excludeArgs = @()
    $exclusions = Get-ConfigValue -Config $Config -Path "exclusions" -Default @()
    foreach ($pattern in $exclusions) {
        $excludeArgs += "--exclude=$pattern"
    }

    $excludeCaches = if ($null -ne $general.exclude_caches) { $general.exclude_caches } else { $false }
    if ($excludeCaches) { $excludeArgs += "--exclude-caches" }

    $excludeIfPresent = if ($null -ne $general.exclude_if_present) { $general.exclude_if_present } else { @() }
    foreach ($marker in $excludeIfPresent) {
        $excludeArgs += "--exclude-if-present=$marker"
    }

    $compression = if ($null -ne $general.compression) { $general.compression } else { "auto" }
    $compressionArg = "--compression=$compression"

    $oneFileSystem = if ($null -ne $general.one_file_system) { $general.one_file_system } else { $false }
    $ofsArg = @()
    if ($oneFileSystem) { $ofsArg = @("--one-file-system") }

    $tags = if ($null -ne $general.tags) { $general.tags } else { @() }
    $tagArgs = @()
    foreach ($tag in $tags) { $tagArgs += @("--tag", $tag) }

    return @{
        ExcludeArgs    = $excludeArgs
        CompressionArg = $compressionArg
        OfsArg         = $ofsArg
        TagArgs        = $tagArgs
    }
}

# -----------------------------------------------------------------------------
# 2. Run backup (with backup type selection, progress bar, VSS support)
# -----------------------------------------------------------------------------
function Select-BackupType {
    <#
    .SYNOPSIS Prompts the user to choose the backup type.
    Returns a hashtable with Sources (array) and ExtraArgs (array).
    #>
    param($Config)

    Write-Host ""
    Write-Host "  Backup type:" -ForegroundColor White
    Write-Separator
    Write-Host "  1. Full backup (all configured sources)"      -ForegroundColor White
    Write-Host "  2. Specific files or folders"                  -ForegroundColor White
    Write-Host "  3. Single folder (quick)"                      -ForegroundColor White
    Write-Host "  4. VSS snapshot (Windows shadow copy)"         -ForegroundColor White
    Write-Host "  5. Dry-run (preview what would be backed up)"  -ForegroundColor White
    Write-Host "  B. Back"                                       -ForegroundColor DarkGray
    Write-Separator

    $typeChoice = Read-Host "  Your choice"

    switch ($typeChoice) {
        "1" {
            # Full backup - use all configured sources
            $sources = @(foreach ($s in $Config.sources) {
                [System.Environment]::ExpandEnvironmentVariables($s)
            })
            return @{ Sources = $sources; ExtraArgs = @(); Type = "Full" }
        }
        "2" {
            # Specific files or folders
            Write-Host ""
            Write-Info "Enter file/folder paths to back up (one per line, empty line to finish):"
            $customSources = [System.Collections.Generic.List[string]]::new()
            while ($true) {
                $path = Read-Host "  Path"
                if ([string]::IsNullOrWhiteSpace($path)) { break }
                $expanded = [System.Environment]::ExpandEnvironmentVariables($path)
                $customSources.Add($expanded)
            }
            if ($customSources.Count -eq 0) {
                Write-Err "No paths specified."
                return $null
            }
            return @{ Sources = @($customSources); ExtraArgs = @(); Type = "Selective" }
        }
        "3" {
            # Single folder
            $folder = Read-Host "  Enter folder path to back up"
            if ([string]::IsNullOrWhiteSpace($folder)) {
                Write-Err "No path specified."
                return $null
            }
            $expanded = [System.Environment]::ExpandEnvironmentVariables($folder)
            return @{ Sources = @($expanded); ExtraArgs = @(); Type = "Single folder" }
        }
        "4" {
            # VSS snapshot (Windows only)
            $sources = @(foreach ($s in $Config.sources) {
                [System.Environment]::ExpandEnvironmentVariables($s)
            })
            Write-Info "Using Volume Shadow Copy (VSS) for consistent backup."
            Write-Info "VSS timeout: 120s (default). Files locked by other processes will be captured."
            return @{ Sources = $sources; ExtraArgs = @("--use-fs-snapshot"); Type = "VSS snapshot" }
        }
        "5" {
            # Dry-run backup
            $sources = @(foreach ($s in $Config.sources) {
                [System.Environment]::ExpandEnvironmentVariables($s)
            })
            Write-Info "Dry-run mode: no data will be stored, only a preview."
            return @{ Sources = $sources; ExtraArgs = @("--dry-run"); Type = "Dry-run" }
        }
        { $_ -eq "B" -or $_ -eq "b" } {
            $script:BackRequested = $true
            return $null
        }
        default {
            Write-Err "Invalid choice."
            return $null
        }
    }
}

function Start-Backup {
    param($Config, [string]$ResticExe)

    Write-Transition "Backup"
    Write-Header "Run backup"

    # Backup type selection
    $backupType = Select-BackupType -Config $Config
    if (-not $backupType) { return }

    $sources = $backupType.Sources
    $extraArgs = $backupType.ExtraArgs

    # Validate sources
    $validSources   = @()
    $invalidSources = @()
    foreach ($src in $sources) {
        if (Test-Path $src) { $validSources += $src }
        else { $invalidSources += $src }
    }

    if ($invalidSources.Count -gt 0) {
        Write-Warn "The following source paths were not found and will be skipped:"
        foreach ($inv in $invalidSources) {
            Write-Detail "- $inv"
        }
    }

    if ($validSources.Count -eq 0) {
        Write-Err "No valid source paths found."
        return
    }

    Write-Host ""
    Write-Info "Backup type: $($backupType.Type)"
    Write-Info "Sources ($($validSources.Count)):"
    foreach ($src in $validSources) {
        Write-Detail "- $src"
    }

    $ba = Build-BackupArguments -Config $Config
    $excludeArgs    = $ba.ExcludeArgs
    $compressionArg = $ba.CompressionArg
    $ofsArg         = $ba.OfsArg
    $tagArgs        = $ba.TagArgs

    # Verbose
    $verbose = Get-ConfigValue -Config $Config -Path "general.verbose" -Default $true

    # Backend selection
    $selectedBackends = @(Select-Backends -Config $Config -Operation "backup")
    if ($selectedBackends.Count -eq 0) { return }

    $overallStart = Get-Date
    $backendResults = @()

    foreach ($prop in $selectedBackends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not (Test-BackendNetwork -Name $name)) { continue }

        $repo = Resolve-Repository -BackendName $name -Backend $backend
        if (-not $repo) { continue }

        Write-Host ""
        Write-Step "Backing up to: $name ($($backend.description))"
        Write-Log "Starting backup to [$name] repo: $repo"

        $backendStart = Get-Date

        Set-BackendEnv -Backend $backend
        try {
            if ($verbose) {
                # Use progress bar with JSON output
                $backupArgs = @("backup") + $validSources + $excludeArgs + @($compressionArg, "--json") + $ofsArg + $tagArgs + $extraArgs

                $result = Invoke-ResticWithProgress -ResticExe $ResticExe -Repository $repo `
                                                    -Password $backend.password `
                                                    -Arguments $backupArgs `
                                                    -BackendName $name
            }
            else {
                # Silent mode
                $backupArgs = @("backup") + $validSources + $excludeArgs + @($compressionArg, "--json") + $ofsArg + $tagArgs + $extraArgs

                $result = Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                                        -Password $backend.password -Arguments $backupArgs -Silent

                # Parse summary from output
                $parsedSummary = Find-Summary -Lines $result.Output
                if ($parsedSummary) {
                    $result | Add-Member -NotePropertyName Summary -NotePropertyValue $parsedSummary
                }
            }
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }

        $backendDuration = (Get-Date) - $backendStart

        if ($result.ExitCode -eq 0) {
            Write-OK "[$name] backup completed in $($backendDuration.ToString('hh\:mm\:ss'))."
            Write-Log "[$name] backup OK (duration: $($backendDuration.ToString('hh\:mm\:ss')))" "INFO"

            # Display summary
            $summary = $result.Summary
            if (-not $summary -and $result.Output) {
                $summary = Find-Summary -Lines $result.Output
            }

            if ($summary) {
                Write-Host ""
                Write-Host "  Backup Summary for [$name]:" -ForegroundColor Green
                Write-Detail ("  Files new      : {0}" -f $summary.files_new)
                Write-Detail ("  Files changed  : {0}" -f $summary.files_changed)
                Write-Detail ("  Files unchanged: {0}" -f $summary.files_unmodified)
                Write-Detail ("  Data added     : {0:F2} MiB" -f ($summary.data_added / 1MB))
                Write-Detail ("  Total files    : {0}" -f $summary.total_files_processed)
                Write-Detail ("  Total bytes    : {0:F2} MiB" -f ($summary.total_bytes_processed / 1MB))
                Write-Detail ("  Duration       : {0:F1} s" -f $summary.total_duration)
                Write-Detail ("  Snapshot ID    : {0}" -f $summary.snapshot_id)

                Write-Log ("[$name] files_new={0} files_changed={1} files_unmodified={2} data_added={3}B total_files={4} duration={5}s snapshot={6}" -f `
                    $summary.files_new, $summary.files_changed, $summary.files_unmodified,
                    $summary.data_added, $summary.total_files_processed,
                    $summary.total_duration, $summary.snapshot_id) "INFO"

                $backendResults += [PSCustomObject]@{
                    Backend    = $name
                    Status     = "OK"
                    FilesNew   = $summary.files_new
                    FilesChg   = $summary.files_changed
                    DataAdded  = "{0:F2} MiB" -f ($summary.data_added / 1MB)
                    Duration   = "{0:F1} s" -f $summary.total_duration
                    SnapshotID = $(
                        $snapshotDisplayLen = 8
                        if ($summary.snapshot_id) {
                            $summary.snapshot_id.Substring(0, [math]::Min($snapshotDisplayLen, $summary.snapshot_id.Length))
                        } else { "N/A" }
                    )
                }
            }
            else {
                $backendResults += [PSCustomObject]@{
                    Backend    = $name
                    Status     = "OK"
                    FilesNew   = "N/A"
                    FilesChg   = "N/A"
                    DataAdded  = "N/A"
                    Duration   = $backendDuration.ToString('hh\:mm\:ss')
                    SnapshotID = "N/A"
                }
            }
        }
        else {
            Write-Err "[$name] backup failed (exit $($result.ExitCode))."
            $lastLine = if ($result.Output) { ($result.Output | Select-Object -Last 1).ToString() } else { "(no output)" }
            Write-Log "[$name] backup failed: $lastLine" "ERROR"

            $backendResults += [PSCustomObject]@{
                Backend    = $name
                Status     = "FAILED"
                FilesNew   = "-"
                FilesChg   = "-"
                DataAdded  = "-"
                Duration   = $backendDuration.ToString('hh\:mm\:ss')
                SnapshotID = "-"
            }
        }
    }

    # Overall summary table
    $overallDuration = (Get-Date) - $overallStart

    if ($backendResults.Count -gt 0) {
        Write-Host ""
        Write-Header "Backup Summary"
        $backendResults | Format-Table -AutoSize
        Write-Info ("Total elapsed time: {0:hh\:mm\:ss}" -f $overallDuration)
        Write-Log ("Total backup duration: {0:hh\:mm\:ss}" -f $overallDuration)
    }
}

# -----------------------------------------------------------------------------
# 3. List snapshots
# -----------------------------------------------------------------------------
function Show-Snapshots {
    param($Config, [string]$ResticExe)

    Write-Header "List snapshots"

    $selectedBackends = @(Select-Backends -Config $Config -Operation "list snapshots")
    if ($selectedBackends.Count -eq 0) { return }

    foreach ($prop in $selectedBackends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not (Test-BackendNetwork -Name $name)) { continue }

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
# 4. Restore backup (full, folder, file, with overwrite modes)
# -----------------------------------------------------------------------------
function Restore-Backup {
    param($Config, [string]$ResticExe)

    Write-Transition "Restore"
    Write-Header "Restore backup"

    # Restore type selection
    Write-Host ""
    Write-Host "  Restore mode:" -ForegroundColor White
    Write-Separator
    Write-Host "  1. Full snapshot restore"                     -ForegroundColor White
    Write-Host "  2. Restore specific folder (subfolder syntax)" -ForegroundColor White
    Write-Host "  3. Restore specific file(s) (include filter)"  -ForegroundColor White
    Write-Host "  4. Dry-run restore (preview only)"            -ForegroundColor White
    Write-Host "  B. Back"                                      -ForegroundColor DarkGray
    Write-Separator

    $restoreMode = Read-Host "  Your choice"
    if ($restoreMode -eq "B" -or $restoreMode -eq "b") {
        $script:BackRequested = $true
        return
    }
    if ($restoreMode -notin @("1", "2", "3", "4")) {
        Write-Err "Invalid choice."
        return
    }

    $selected = Select-SingleBackend -Config $Config -Operation "restore"
    if (-not $selected) { return }

    $name    = $selected.Name
    $backend = $selected.Value

    $repo = Resolve-Repository -BackendName $name -Backend $backend
    if (-not $repo) { return }

    Set-BackendEnv -Backend $backend
    try {
        Write-Step "Listing snapshots for [$name]..."
        Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                      -Password $backend.password -Arguments @("snapshots")

        Write-Host ""
        $snapshotId = Read-Host "Enter snapshot ID to restore, 'latest', or leave empty to cancel"
        if ([string]::IsNullOrWhiteSpace($snapshotId)) {
            Write-Info "Restore cancelled."
            return
        }

        # Build the snapshot reference (with optional subfolder)
        $snapshotRef = $snapshotId
        $filterArgs = @()
        $extraRestoreArgs = @()

        switch ($restoreMode) {
            "2" {
                # Subfolder restore using snapshot:subfolder syntax
                Write-Host ""
                Write-Info "Browse the snapshot to find the folder path:"
                Write-Info "  Tip: Use 'restic ls <snapshot>' to list contents."
                Write-Host ""
                Write-Step "Listing snapshot contents to help identify paths..."
                Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                -Password $backend.password -Arguments @("ls", $snapshotId, "--long")
                Write-Host ""
                $subfolder = Read-Host "  Enter subfolder path (e.g. /home/user/Documents)"
                if (-not [string]::IsNullOrWhiteSpace($subfolder)) {
                    $subfolder = $subfolder.TrimEnd('/', '\')
                    $snapshotRef = "${snapshotId}:${subfolder}"
                    Write-Info "Will restore: $snapshotRef"
                }
            }
            "3" {
                # File restore using --include
                Write-Host ""
                Write-Info "Enter file paths or patterns to include (one per line, empty to finish):"
                Write-Info "  Examples: /path/to/file.txt, *.docx, /Documents/report*"
                while ($true) {
                    $incPath = Read-Host "  Include"
                    if ([string]::IsNullOrWhiteSpace($incPath)) { break }
                    $filterArgs += @("--include", $incPath)
                }
                if ($filterArgs.Count -eq 0) {
                    Write-Err "No include patterns specified."
                    return
                }
            }
            "4" {
                # Dry-run mode
                $extraRestoreArgs += @("--dry-run", "--verbose=2")
                Write-Info "Dry-run mode: no files will be written."
            }
        }

        # Destination path
        $restorePath = Read-Host "Enter restore destination path (or leave empty to cancel)"
        if ([string]::IsNullOrWhiteSpace($restorePath)) {
            Write-Err "Restore path cannot be empty."
            return
        }

        # Overwrite mode selection (not for dry-run)
        if ($restoreMode -ne "4") {
            Write-Host ""
            Write-Host "  Overwrite mode:" -ForegroundColor White
            Write-Host "  1. Always overwrite (default)"           -ForegroundColor White
            Write-Host "  2. Only if changed (skip matching)"      -ForegroundColor White
            Write-Host "  3. Only if newer (by modification time)" -ForegroundColor White
            Write-Host "  4. Never overwrite existing files"        -ForegroundColor White
            $overwriteChoice = Read-Host "  Choice (1-4, default: 1)"

            switch ($overwriteChoice) {
                "2" { $extraRestoreArgs += @("--overwrite", "if-changed") }
                "3" { $extraRestoreArgs += @("--overwrite", "if-newer") }
                "4" { $extraRestoreArgs += @("--overwrite", "never") }
            }
        }

        # Optional exclude filter (for full and subfolder modes)
        if ($restoreMode -in @("1", "2") -and $filterArgs.Count -eq 0) {
            $excludePattern = Read-Host "Exclude pattern (e.g. '*.tmp') or press Enter to skip"
            if (-not [string]::IsNullOrWhiteSpace($excludePattern)) {
                $filterArgs += @("--exclude", $excludePattern)
            }
        }

        Write-Host ""
        Write-Step "Restoring '$snapshotRef' to '$restorePath'..."
        Write-Log "Restoring [$name] snapshot $snapshotRef to $restorePath (mode: $restoreMode)"

        $restoreArgs = @("restore", $snapshotRef, "--target", $restorePath, "--json") + $filterArgs + $extraRestoreArgs

        $result = Invoke-ResticWithProgress -ResticExe $ResticExe -Repository $repo `
                                            -Password $backend.password `
                                            -Arguments $restoreArgs `
                                            -BackendName $name `
                                            -ActivityName "Restore from $name"

        if ($result.ExitCode -eq 0) {
            if ($restoreMode -eq "4") {
                Write-OK "Dry-run completed (no files were written)."
            }
            else {
                Write-OK "Restore completed successfully."
            }
            Write-Log "[$name] restore OK" "INFO"

            $summary = $result.Summary
            if (-not $summary -and $result.Output) {
                $summary = Find-Summary -Lines $result.Output
            }
            if ($summary) {
                Write-Host ""
                Write-Host "  Restore Summary for [$name]:" -ForegroundColor Green
                if ($null -ne $summary.files_restored)  { Write-Detail ("  Files restored : {0}" -f $summary.files_restored) }
                if ($null -ne $summary.total_files)     { Write-Detail ("  Total files    : {0}" -f $summary.total_files) }
                if ($null -ne $summary.bytes_restored)  { Write-Detail ("  Bytes restored : {0:F2} MiB" -f ($summary.bytes_restored / 1MB)) }
                if ($null -ne $summary.total_bytes)     { Write-Detail ("  Total bytes    : {0:F2} MiB" -f ($summary.total_bytes / 1MB)) }
            }

            # Show diagnostic output for dry-run
            if ($restoreMode -eq "4" -and $result.Output) {
                Write-Host ""
                Write-Info "Dry-run details:"
                foreach ($line in $result.Output) {
                    $lineStr = $line.ToString()
                    if ($lineStr -and $lineStr[0] -ne '{') {
                        Write-Detail "  $lineStr"
                    }
                }
            }
        }
        else {
            Write-Err "Restore failed (exit $($result.ExitCode))."
            $lastLine = if ($result.Output) { ($result.Output | Select-Object -Last 1).ToString() } else { "(no output)" }
            Write-Err $lastLine
            Write-Log "[$name] restore failed (exit $($result.ExitCode)): $lastLine" "ERROR"
        }
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

    $selectedBackends = @(Select-Backends -Config $Config -Operation "verify")
    if ($selectedBackends.Count -eq 0) { return }

    foreach ($prop in $selectedBackends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not (Test-BackendNetwork -Name $name)) { continue }

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
# 6. Prune repository (with sub-menu)
# -----------------------------------------------------------------------------
function Invoke-Prune {
    param($Config, [string]$ResticExe)

    while ($true) {
        Write-Header "Prune repository"

        Write-Host ""
        Write-Host "  Prune options:" -ForegroundColor White
        Write-Host "  1. Prune by retention policy"     -ForegroundColor White
        Write-Host "  2. Delete specific snapshot"       -ForegroundColor White
        Write-Host "  0. Back"                           -ForegroundColor DarkGray

        $pruneChoice = Read-Host "  Your choice"

        switch ($pruneChoice) {
            "1" { Invoke-PruneByPolicy  -Config $Config -ResticExe $ResticExe; return }
            "2" { Remove-Snapshot       -Config $Config -ResticExe $ResticExe; return }
            "0" { $script:BackRequested = $true; return }
            default {
                Write-Err "Invalid choice. Please enter 0, 1, or 2."
            }
        }
    }
}

function Invoke-PruneByPolicy {
    param($Config, [string]$ResticExe)

    $ret = $Config.retention

    # Show retention policy and ask for confirmation
    Write-Info "Current retention policy:"
    Write-Detail "  keep_last    : $($ret.keep_last)"
    Write-Detail "  keep_daily   : $($ret.keep_daily)"
    Write-Detail "  keep_weekly  : $($ret.keep_weekly)"
    Write-Detail "  keep_monthly : $($ret.keep_monthly)"
    Write-Detail "  keep_yearly  : $($ret.keep_yearly)"
    Write-Host ""
    Write-Warn "Pruning will permanently delete snapshots that do not match the retention policy."
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Info "Prune cancelled."
        return
    }

    $retArgs = @(
        "--keep-last",    $ret.keep_last,
        "--keep-daily",   $ret.keep_daily,
        "--keep-weekly",  $ret.keep_weekly,
        "--keep-monthly", $ret.keep_monthly,
        "--keep-yearly",  $ret.keep_yearly
    )

    $selectedBackends = @(Select-Backends -Config $Config -Operation "prune")
    if ($selectedBackends.Count -eq 0) { return }

    foreach ($prop in $selectedBackends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not (Test-BackendNetwork -Name $name)) { continue }

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

function Remove-Snapshot {
    param($Config, [string]$ResticExe)

    Write-Header "Delete specific snapshot"

    $selected = Select-SingleBackend -Config $Config -Operation "delete snapshot"
    if (-not $selected) { return }

    $name    = $selected.Name
    $backend = $selected.Value

    if (-not (Test-BackendNetwork -Name $name)) { return }

    $repo = Resolve-Repository -BackendName $name -Backend $backend
    if (-not $repo) { return }

    Set-BackendEnv -Backend $backend
    try {
        Write-Step "Listing snapshots for [$name]..."
        Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                      -Password $backend.password -Arguments @("snapshots")

        Write-Host ""
        $snapshotId = Read-Host "Enter snapshot ID to delete (or leave empty to cancel)"
        if ([string]::IsNullOrWhiteSpace($snapshotId)) {
            Write-Info "Delete cancelled."
            return
        }

        Write-Warn "This will permanently delete snapshot '$snapshotId' and prune unreferenced data."
        $confirm = Read-Host "Are you sure? (y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Info "Delete cancelled."
            return
        }

        Write-Step "Deleting snapshot '$snapshotId' from [$name]..."
        Write-Log "Deleting snapshot $snapshotId from [$name]"

        $exit = Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                              -Password $backend.password `
                              -Arguments @("forget", $snapshotId, "--prune")

        if ($exit -eq 0) {
            Write-OK "[$name] snapshot '$snapshotId' deleted."
            Write-Log "[$name] snapshot $snapshotId deleted OK" "INFO"
        }
        else {
            Write-Err "[$name] failed to delete snapshot (exit $exit)."
            Write-Log "[$name] snapshot $snapshotId delete failed" "ERROR"
        }
    }
    finally {
        Clear-BackendEnv -Backend $backend
    }
}

# -----------------------------------------------------------------------------
# 7. Repository statistics
# -----------------------------------------------------------------------------
function Show-Stats {
    param($Config, [string]$ResticExe)

    Write-Header "Repository statistics"

    $selectedBackends = @(Select-Backends -Config $Config -Operation "statistics")
    if ($selectedBackends.Count -eq 0) { return }

    foreach ($prop in $selectedBackends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not (Test-BackendNetwork -Name $name)) { continue }

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
    $drives = @(Get-LocalTargets)
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
# 9. Unlock repository
# -----------------------------------------------------------------------------
function Unlock-Repository {
    param($Config, [string]$ResticExe)

    Write-Header "Unlock repository"
    Write-Info "Removes stale locks from repositories (e.g. after a crashed backup)."

    $selectedBackends = @(Select-Backends -Config $Config -Operation "unlock")
    if ($selectedBackends.Count -eq 0) { return }

    foreach ($prop in $selectedBackends) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not (Test-BackendNetwork -Name $name)) { continue }

        $repo = Resolve-Repository -BackendName $name -Backend $backend
        if (-not $repo) { continue }

        Write-Step "Unlocking backend: $name"
        Write-Log "Unlocking [$name]"

        Set-BackendEnv -Backend $backend
        try {
            $exit = Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                                  -Password $backend.password -Arguments @("unlock")
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }

        if ($exit -eq 0) {
            Write-OK "[$name] repository unlocked."
            Write-Log "[$name] unlock OK" "INFO"
        }
        else {
            Write-Err "[$name] unlock failed (exit $exit)."
            Write-Log "[$name] unlock failed" "ERROR"
        }
    }
}

# -----------------------------------------------------------------------------
# 10. Browse snapshot contents
# -----------------------------------------------------------------------------
function Show-SnapshotContents {
    param($Config, [string]$ResticExe)

    Write-Header "Browse snapshot contents"

    $selected = Select-SingleBackend -Config $Config -Operation "browse snapshots"
    if (-not $selected) { return }

    $name    = $selected.Name
    $backend = $selected.Value

    $repo = Resolve-Repository -BackendName $name -Backend $backend
    if (-not $repo) { return }

    Set-BackendEnv -Backend $backend
    try {
        Write-Step "Listing snapshots for [$name]..."
        Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                      -Password $backend.password -Arguments @("snapshots")

        $snapshotId = Read-Host "Enter snapshot ID to browse, 'latest', or leave empty to cancel"
        if ([string]::IsNullOrWhiteSpace($snapshotId)) {
            Write-Info "Browse cancelled."
            return
        }

        Write-Step "Listing files in snapshot '$snapshotId'..."
        Write-Log "Browsing [$name] snapshot $snapshotId"

        Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                      -Password $backend.password -Arguments @("ls", $snapshotId)
    }
    finally {
        Clear-BackendEnv -Backend $backend
    }
}

# -----------------------------------------------------------------------------
# 11. Dry-run backup
# -----------------------------------------------------------------------------
function Start-DryRunBackup {
    param($Config, [string]$ResticExe)

    Write-Header "Dry-run backup (preview)"
    Write-Info "This will show what would be backed up without actually storing any data."

    # Build source list
    $sources = @(foreach ($s in $Config.sources) {
        $expanded = [System.Environment]::ExpandEnvironmentVariables($s)
        if (Test-Path $expanded) { $expanded }
    })

    if ($sources.Count -eq 0) {
        Write-Err "No valid source paths found."
        return
    }

    $ba = Build-BackupArguments -Config $Config
    $excludeArgs    = $ba.ExcludeArgs
    $compressionArg = $ba.CompressionArg
    $ofsArg         = $ba.OfsArg
    $tagArgs        = $ba.TagArgs

    # Select exactly one backend for dry-run
    $selected = Select-SingleBackend -Config $Config -Operation "dry-run"
    if (-not $selected) { return }

    $name    = $selected.Name
    $backend = $selected.Value

    if (-not (Test-BackendNetwork -Name $name)) { return }

    $repo = Resolve-Repository -BackendName $name -Backend $backend
    if (-not $repo) { return }

    Write-Step "Dry-run backup using backend: $name"
    Write-Log "Dry-run backup [$name] repo: $repo"

    $backupArgs = @("backup", "--dry-run") + $sources + $excludeArgs + @($compressionArg, "--json") + $ofsArg + $tagArgs

    Set-BackendEnv -Backend $backend
    try {
        $result = Invoke-ResticWithProgress -ResticExe $ResticExe -Repository $repo `
                                            -Password $backend.password `
                                            -Arguments $backupArgs `
                                            -BackendName $name `
                                            -ActivityName "Dry-run to $name"
    }
    finally {
        Clear-BackendEnv -Backend $backend
    }

    if ($result.ExitCode -eq 0) {
        Write-OK "Dry-run completed."

        $summary = $result.Summary
        if (-not $summary -and $result.Output) {
            $summary = Find-Summary -Lines $result.Output
        }

        if ($summary) {
            Write-Host ""
            Write-Info "Dry-run summary (no data was written):"
            Write-Detail ("  Files new      : {0}" -f $summary.files_new)
            Write-Detail ("  Files changed  : {0}" -f $summary.files_changed)
            Write-Detail ("  Files unchanged: {0}" -f $summary.files_unmodified)
            Write-Detail ("  Total files    : {0}" -f $summary.total_files_processed)
            Write-Detail ("  Total bytes    : {0:F2} MiB" -f ($summary.total_bytes_processed / 1MB))

            Write-Log ("[$name] dry-run files_new={0} files_changed={1} files_unmodified={2} total_files={3} total_bytes={4}B" -f `
                $summary.files_new, $summary.files_changed, $summary.files_unmodified,
                $summary.total_files_processed, $summary.total_bytes_processed) "INFO"
        }
    }
    else {
        Write-Err "Dry-run failed (exit $($result.ExitCode))."
        $lastLine = if ($result.Output) { ($result.Output | Select-Object -Last 1).ToString() } else { "(no output)" }
        Write-Err $lastLine
        Write-Log "[$name] dry-run failed (exit $($result.ExitCode)): $lastLine" "ERROR"
    }
}

# -----------------------------------------------------------------------------
# Remove restic installation
# -----------------------------------------------------------------------------
function Remove-Repository {
    param($Config)

    while ($true) {
        Write-Header "Remove repository"

        Write-Host ""
        Write-Host "  Remove options:" -ForegroundColor White
        Write-Host "  1. Remove local repository (local/USB)"      -ForegroundColor White
        Write-Host "  2. Remove remote repository (S3/Swift/SFTP)" -ForegroundColor White
        Write-Host "  0. Back"                                     -ForegroundColor DarkGray

        $choice = Read-Host "  Your choice"

        switch ($choice) {
            "1" { Remove-LocalRepository  -Config $Config; return }
            "2" { Remove-RemoteRepository -Config $Config; return }
            "0" { $script:BackRequested = $true; return }
            default {
                Write-Err "Invalid choice. Please enter 0, 1, or 2."
            }
        }
    }
}

function Remove-LocalRepository {
    param($Config)

    Write-Header "Remove local/USB repository"

    $selected = @(Select-Backends -Config $Config -Operation "repository removal" -BackendNames @("local", "usb"))
    if ($selected.Count -eq 0) { return }

    foreach ($prop in $selected) {
        $name    = $prop.Name
        $backend = $prop.Value

        # Resolve path without creating the directory
        if ($name -eq "usb") {
            $drive = Find-UsbDrive -Label $backend.drive_label
            if (-not $drive) {
                Write-Err "[$name] USB drive with label '$($backend.drive_label)' not found."
                continue
            }
            $repo = Join-Path $drive $backend.repository_path
        }
        else {
            $repo = $backend.repository
            if (-not [System.IO.Path]::IsPathRooted($repo)) {
                $repo = Join-Path $ScriptRoot $repo
            }
        }

        $repo = [System.IO.Path]::GetFullPath($repo)

        # Defensive validation: reject drive roots
        $pathRoot = [System.IO.Path]::GetPathRoot($repo)
        if ($repo.TrimEnd('\', '/') -eq $pathRoot.TrimEnd('\', '/')) {
            Write-Err "[$name] refusing to delete a drive root: $repo"
            continue
        }

        # Defensive validation: reject ScriptRoot
        if ($repo.TrimEnd('\', '/') -eq $ScriptRoot.TrimEnd('\', '/')) {
            Write-Err "[$name] refusing to delete the script directory: $repo"
            continue
        }

        if (-not (Test-Path $repo)) {
            Write-Info "[$name] repository not found at: $repo"
            continue
        }

        # Defensive validation: verify it looks like a restic repository
        $configFile = Join-Path $repo "config"
        if (-not (Test-Path $configFile)) {
            Write-Err "[$name] path does not appear to be a restic repository (missing 'config' file): $repo"
            continue
        }

        Write-Warn "Repository path: $repo"
        Write-Warn "This will permanently delete all data in this repository."
        $confirm = Read-Host "Delete repository for [$name]? (y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Info "Skipped [$name]."
            continue
        }

        try {
            Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction Stop
            Write-OK "[$name] repository removed successfully."
            Write-Log "[$name] repository removed: $repo" "INFO"
        }
        catch {
            Write-Err "[$name] failed to remove repository: $_"
            Write-Log "[$name] repository removal failed: $_" "ERROR"
        }
    }
}

function Remove-RemoteRepository {
    param($Config)

    Write-Header "Remove remote repository"

    $selected = @(Select-Backends -Config $Config -Operation "repository removal" -BackendNames @("s3", "swift", "sftp"))
    if ($selected.Count -eq 0) { return }

    foreach ($prop in $selected) {
        $name    = $prop.Name
        $backend = $prop.Value

        if (-not (Test-BackendNetwork -Name $name)) { continue }

        $repo = $backend.repository

        Write-Warn "Repository: $repo"
        Write-Warn "This will permanently delete all data in this repository."
        $confirm = Read-Host "Delete repository for [$name]? (y/N)"
        if ($confirm -ne "y" -and $confirm -ne "Y") {
            Write-Info "Skipped [$name]."
            continue
        }

        Set-BackendEnv -Backend $backend
        try {
            $removed = $false

            switch ($name) {
                "s3" {
                    $s3Repo = $repo -replace "^s3:", ""
                    $endpoint   = $null
                    $bucketPath = $null

                    if ($s3Repo -match "^(https?://[^/]+)/(.+)$") {
                        $endpoint   = $Matches[1]
                        $bucketPath = $Matches[2]
                    }
                    elseif ($s3Repo -match "^([^/]+)/(.+)$") {
                        $endpoint   = "https://$($Matches[1])"
                        $bucketPath = $Matches[2]
                    }
                    else {
                        Write-Err "[$name] Unable to parse S3 repository URL: $repo"
                        continue
                    }

                    $awsExe = Get-Command "aws" -ErrorAction SilentlyContinue
                    if ($awsExe) {
                        Write-Step "Removing S3 repository via AWS CLI..."
                        & $awsExe.Source s3 rm "s3://$bucketPath" --recursive --endpoint-url $endpoint 2>&1 | Out-Host
                        if ($LASTEXITCODE -eq 0) { $removed = $true }
                        else { Write-Err "[$name] AWS CLI returned exit code $LASTEXITCODE." }
                    }
                    else {
                        Write-Err "[$name] AWS CLI (aws) not found."
                        Write-Info "Install the AWS CLI and run manually:"
                        Write-Detail "  aws s3 rm s3://$bucketPath --recursive --endpoint-url $endpoint"
                    }
                }

                "swift" {
                    $container = $null
                    $prefix    = $null

                    if ($repo -match "^swift:([^:]+):/?(.*)$") {
                        $container = $Matches[1]
                        $prefix    = $Matches[2]
                    }
                    else {
                        Write-Err "[$name] Unable to parse Swift repository URL: $repo"
                        continue
                    }

                    $swiftExe = Get-Command "swift" -ErrorAction SilentlyContinue
                    if ($swiftExe) {
                        Write-Step "Removing Swift repository..."
                        if ($prefix) {
                            & $swiftExe.Source delete $container --prefix $prefix 2>&1 | Out-Host
                        }
                        else {
                            & $swiftExe.Source delete $container 2>&1 | Out-Host
                        }
                        if ($LASTEXITCODE -eq 0) { $removed = $true }
                        else { Write-Err "[$name] Swift CLI returned exit code $LASTEXITCODE." }
                    }
                    else {
                        Write-Err "[$name] Swift CLI (swift) not found."
                        Write-Info "Install the Swift CLI and run manually:"
                        if ($prefix) {
                            Write-Detail "  swift delete $container --prefix $prefix"
                        }
                        else {
                            Write-Detail "  swift delete $container"
                        }
                    }
                }

                "sftp" {
                    $sshTarget  = $null
                    $remotePath = $null

                    if ($repo -match "^sftp:([^@]+@[^:]+):(.+)$") {
                        $sshTarget  = $Matches[1]
                        $remotePath = $Matches[2]
                    }
                    elseif ($repo -match "^sftp://([^@]+@[^/]+)(/.+)$") {
                        $sshTarget  = $Matches[1]
                        $remotePath = $Matches[2]
                    }
                    else {
                        Write-Err "[$name] Unable to parse SFTP repository URL: $repo"
                        continue
                    }

                    # Validate remote path to prevent command injection
                    if ($remotePath -match '[;`$|&<>(){}!]|''') {
                        Write-Err "[$name] Remote path contains unsafe characters: $remotePath"
                        continue
                    }

                    $sshExe = Get-Command "ssh" -ErrorAction SilentlyContinue
                    if ($sshExe) {
                        Write-Step "Removing SFTP repository via SSH..."
                        $escapedPath = $remotePath -replace "'", "'\''"
                        & $sshExe.Source $sshTarget "rm -rf '$escapedPath'" 2>&1 | Out-Host
                        if ($LASTEXITCODE -eq 0) { $removed = $true }
                        else { Write-Err "[$name] SSH returned exit code $LASTEXITCODE." }
                    }
                    else {
                        Write-Err "[$name] SSH (ssh) not found."
                        Write-Info "Run manually:"
                        Write-Detail "  ssh $sshTarget 'rm -rf $remotePath'"
                    }
                }
            }

            if ($removed) {
                Write-OK "[$name] repository removed successfully."
                Write-Log "[$name] repository removed: $repo" "INFO"
            }
            else {
                Write-Log "[$name] repository removal incomplete or failed" "WARN"
            }
        }
        finally {
            Clear-BackendEnv -Backend $backend
        }
    }
}

# -----------------------------------------------------------------------------
# Other options sub-menu
# -----------------------------------------------------------------------------
function Show-OtherMenu {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "   Maintenance & Tools" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  1.  Initialize repository"               -ForegroundColor White
    Write-Host "  2.  Unlock repository"                   -ForegroundColor White
    Write-Host "  3.  Detect available targets"            -ForegroundColor White
    Write-Host "  4.  Remove repository"                   -ForegroundColor White
    Write-Host "  0.  Back to main menu"                   -ForegroundColor DarkGray
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Invoke-OtherMenu {
    param($Config, [string]$ResticExe)

    while ($true) {
        Write-Transition "Maintenance & Tools"
        Show-OtherMenu
        $otherChoice = Read-Host "Enter your choice"

        switch ($otherChoice) {
            "1" { Initialize-Repository    -Config $Config -ResticExe $ResticExe }
            "2" { Unlock-Repository        -Config $Config -ResticExe $ResticExe }
            "3" { Show-Targets             -Config $Config }
            "4" { Remove-Repository -Config $Config }
            "0" { $script:BackRequested = $true; return }
            default {
                Write-Err "Invalid choice. Please enter a number from 0 to 4."
                continue
            }
        }

        if (-not $script:BackRequested) {
            Write-Host ""
            Read-Host "Press Enter to continue" | Out-Null
        }
        $script:BackRequested = $false
    }
}

# -----------------------------------------------------------------------------
# Snapshots submenu (consolidates list + browse)
# -----------------------------------------------------------------------------
function Invoke-SnapshotsMenu {
    param($Config, [string]$ResticExe)

    while ($true) {
        Write-Transition "Snapshots"
        Write-Header "Snapshots"

        Write-Host ""
        Write-Host "  1.  List all snapshots"                  -ForegroundColor White
        Write-Host "  2.  Browse snapshot contents"            -ForegroundColor White
        Write-Host "  3.  Find files across snapshots"         -ForegroundColor White
        Write-Host "  4.  Compare snapshots (diff)"            -ForegroundColor White
        Write-Host "  0.  Back"                                -ForegroundColor DarkGray
        Write-Separator

        $snapChoice = Read-Host "  Your choice"

        switch ($snapChoice) {
            "1" { Show-Snapshots         -Config $Config -ResticExe $ResticExe }
            "2" { Show-SnapshotContents  -Config $Config -ResticExe $ResticExe }
            "3" { Find-InSnapshots       -Config $Config -ResticExe $ResticExe }
            "4" { Compare-Snapshots      -Config $Config -ResticExe $ResticExe }
            "0" { $script:BackRequested = $true; return }
            default {
                Write-Err "Invalid choice."
                continue
            }
        }

        if (-not $script:BackRequested) {
            Write-Host ""
            Read-Host "Press Enter to continue" | Out-Null
        }
        $script:BackRequested = $false
    }
}

function Find-InSnapshots {
    param($Config, [string]$ResticExe)

    Write-Header "Find files across snapshots"

    $selected = Select-SingleBackend -Config $Config -Operation "find"
    if (-not $selected) { return }

    $name    = $selected.Name
    $backend = $selected.Value

    $repo = Resolve-Repository -BackendName $name -Backend $backend
    if (-not $repo) { return }

    $pattern = Read-Host "Enter file name or pattern to search for"
    if ([string]::IsNullOrWhiteSpace($pattern)) {
        Write-Info "Search cancelled."
        return
    }

    Write-Step "Searching for '$pattern' in [$name]..."
    Write-Log "Finding '$pattern' in [$name]"

    Set-BackendEnv -Backend $backend
    try {
        Invoke-Restic -ResticExe $ResticExe -Repository $repo ` `
                              -Password $backend.password -Arguments @("find", $pattern)
    }
    finally {
        Clear-BackendEnv -Backend $backend
    }
}

function Compare-Snapshots {
    param($Config, [string]$ResticExe)

    Write-Header "Compare snapshots (diff)"

    $selected = Select-SingleBackend -Config $Config -Operation "diff"
    if (-not $selected) { return }

    $name    = $selected.Name
    $backend = $selected.Value

    $repo = Resolve-Repository -BackendName $name -Backend $backend
    if (-not $repo) { return }

    Set-BackendEnv -Backend $backend
    try {
        Write-Step "Listing snapshots for [$name]..."
        Invoke-Restic -ResticExe $ResticExe -Repository $repo ` `
                              -Password $backend.password -Arguments @("snapshots")

        Write-Host ""
        $snap1 = Read-Host "Enter first snapshot ID (older)"
        if ([string]::IsNullOrWhiteSpace($snap1)) { Write-Info "Cancelled."; return }

        $snap2 = Read-Host "Enter second snapshot ID (newer, or 'latest')"
        if ([string]::IsNullOrWhiteSpace($snap2)) { Write-Info "Cancelled."; return }

        Write-Step "Comparing $snap1 vs $snap2..."
        Write-Log "Diff [$name] $snap1 vs $snap2"

        Invoke-Restic -ResticExe $ResticExe -Repository $repo ` `
                              -Password $backend.password -Arguments @("diff", $snap1, $snap2)
    }
    finally {
        Clear-BackendEnv -Backend $backend
    }
}

# -----------------------------------------------------------------------------
# Repository health (consolidates verify + stats)
# -----------------------------------------------------------------------------
function Invoke-RepositoryHealth {
    param($Config, [string]$ResticExe)

    while ($true) {
        Write-Transition "Repository Health"
        Write-Header "Repository Health"

        Write-Host ""
        Write-Host "  1.  Verify integrity (check)"          -ForegroundColor White
        Write-Host "  2.  Repository statistics"              -ForegroundColor White
        Write-Host "  3.  Full health check (verify + stats)" -ForegroundColor White
        Write-Host "  0.  Back"                               -ForegroundColor DarkGray
        Write-Separator

        $healthChoice = Read-Host "  Your choice"

        switch ($healthChoice) {
            "1" { Test-Repository -Config $Config -ResticExe $ResticExe }
            "2" { Show-Stats      -Config $Config -ResticExe $ResticExe }
            "3" {
                Test-Repository -Config $Config -ResticExe $ResticExe
                Show-Stats      -Config $Config -ResticExe $ResticExe
            }
            "0" { $script:BackRequested = $true; return }
            default {
                Write-Err "Invalid choice."
                continue
            }
        }

        if (-not $script:BackRequested) {
            Write-Host ""
            Read-Host "Press Enter to continue" | Out-Null
        }
        $script:BackRequested = $false
    }
}

# -----------------------------------------------------------------------------
# Purge old log files
# -----------------------------------------------------------------------------
function Remove-OldLogs {
    param([string]$LogDir, [int]$RetentionDays)
    if (-not (Test-Path $LogDir)) { return }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    foreach ($file in Get-ChildItem -Path $LogDir -Filter "*.log") {
        if ($file.LastWriteTime -lt $cutoff) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
            catch {
                Write-Warning ("Failed to remove old log file '{0}': {1}" -f $file.FullName, $_.Exception.Message)
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Startup banner
# -----------------------------------------------------------------------------
function Show-Banner {
    param($Config)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "   Restic Manager Backup v$ScriptVersion" -ForegroundColor Cyan
    Write-Host "   Multi-backend CLI for Windows" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan

    # Show enabled backends
    $enabled = [System.Collections.Generic.List[string]]::new()
    if ($Config -and $Config.backends -and $Config.backends.PSObject -and $Config.backends.PSObject.Properties) {
        foreach ($prop in $Config.backends.PSObject.Properties) {
            if ($prop.Value -and $prop.Value.enabled) { $enabled.Add($prop.Name) }
        }
        if ($enabled.Count -gt 0) {
            Write-Info "Enabled backends: $($enabled -join ', ')"
        }
        else {
            Write-Warn "No backends are enabled."
        }
    }
    else {
        Write-Warn "Backends configuration is missing or invalid."
    }

    # Show source count
    if ($Config -and $Config.sources) {
        Write-Info "Source paths configured: $(@($Config.sources).Count)"
    }
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------
function Show-Menu {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "   Restic Manager Backup v$ScriptVersion" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  1.  Backup"                              -ForegroundColor White
    Write-Host "  2.  Restore"                             -ForegroundColor White
    Write-Host "  3.  Snapshots"                           -ForegroundColor White
    Write-Host "  4.  Prune / retention"                   -ForegroundColor White
    Write-Host "  5.  Repository health"                   -ForegroundColor White
    Write-Host "  6.  Configuration"                       -ForegroundColor White
    Write-Host "  7.  Maintenance & tools"                 -ForegroundColor White
    Write-Host "  0.  Quit"                                -ForegroundColor DarkGray
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
$Config = Import-Config

# Validate config before accessing any fields (Get-ResticExe / Initialize-Log
# rely on general.restic_exe / general.log_dir and would throw an unhelpful
# strict-mode error if those fields are absent).
$configValid = Test-Config -Config $Config
if (-not $configValid) {
    Write-Err "Cannot start due to configuration errors. Please fix config.json and try again."
    exit 1
}

$ResticExe = Get-ResticExe -Config $Config
$LogDir    = Join-Path $ScriptRoot $Config.general.log_dir
Initialize-Log -LogDir $LogDir

# Show startup banner
Show-Banner -Config $Config

# Purge old logs
$logRetentionDays = Get-ConfigValue -Config $Config -Path "general.log_retention_days" -Default 30
Remove-OldLogs -LogDir $LogDir -RetentionDays $logRetentionDays

while ($true) {
    Show-Menu
    $choice = Read-Host "Enter your choice"

    switch ($choice) {
        "1"  { Start-Backup           -Config $Config -ResticExe $ResticExe }
        "2"  { Restore-Backup         -Config $Config -ResticExe $ResticExe }
        "3"  { Invoke-SnapshotsMenu   -Config $Config -ResticExe $ResticExe }
        "4"  { Invoke-Prune           -Config $Config -ResticExe $ResticExe }
        "5"  { Invoke-RepositoryHealth -Config $Config -ResticExe $ResticExe }
        "6"  { Edit-ConfigSection     -ConfigRef ([ref]$Config) }
        "7"  { Invoke-OtherMenu       -Config $Config -ResticExe $ResticExe }
        "0"  {
            Write-Log "Session ended by user"
            Write-Host ""
            Write-Host ("=" * 60) -ForegroundColor Cyan
            Write-Host "  Goodbye! Stay backed up." -ForegroundColor Cyan
            Write-Host ("=" * 60) -ForegroundColor Cyan
            exit 0
        }
        default {
            Write-Err "Invalid choice. Please enter a number from 0 to 7."
        }
    }

    if (-not $script:BackRequested) {
        Write-Host ""
        Read-Host "Press Enter to return to the menu" | Out-Null
    }
    $script:BackRequested = $false
}
