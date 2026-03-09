<#
.SYNOPSIS
    Restic Manager Backup - Interactive CLI backup manager for Windows 64-bit.

.DESCRIPTION
    Multi-backend backup tool built on top of restic.
    Supported backends: S3, Swift (OpenStack), SFTP, local disk, USB key.
    Features: progress bar, verbose output, dry-run, snapshot browsing,
    per-backend selection, config validation, and more.

.NOTES
    Version      : 2.2.0
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
$ScriptVersion = "2.2.0"

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
    try { $width = [Console]::BufferWidth } catch {}
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

    # Compose and pad
    $line = "  $Activity [$barFilled$barEmpty] $pctStr  $Status"
    if ($line.Length -lt $maxLen) { $line = $line.PadRight($maxLen) }
    if ($line.Length -gt $maxLen) { $line = $line.Substring(0, $maxLen) }

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
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    if ($LogFile) { Add-Content -Path $LogFile -Value $line -Encoding UTF8 }
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
        $Config.backends.PSObject.Properties | ForEach-Object {
            $name = $_.Name
            $b    = $_.Value
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

function Get-LocalTargets {
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
    $diagnostics     = @()   # Only stderr + non-status lines (avoid unbounded memory)
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

            try {
                $json = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $json) {
                    $diagnostics += $line
                    continue
                }

                if ($json.message_type -eq "status") {
                    # Only refresh the progress bar once per throttle interval
                    if ($progressSw.ElapsedMilliseconds -lt $progressIntervalMs) { continue }
                    $progressSw.Restart()

                    # Percentage: prefer restic-provided percent_done (0..1), fall back to bytes or files ratio
                    $pctDone = 0
                    if ($json.percent_done) {
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
                    $diagnostics += $line
                }
                else {
                    # Retain any non-status JSON (e.g. error messages)
                    $diagnostics += $line
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
            if ($stderrText) { $diagnostics += $stderrText }
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
    param($Config, [string]$Operation)

    $enabledBackends = $Config.backends.PSObject.Properties | Where-Object { $_.Value.enabled }
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

    $excludeArgs = @()
    $exclusions = Get-ConfigValue -Config $Config -Path "exclusions" -Default @()
    foreach ($pattern in $exclusions) {
        $excludeArgs += "--exclude=$pattern"
    }

    $excludeCaches = Get-ConfigValue -Config $Config -Path "general.exclude_caches" -Default $false
    if ($excludeCaches) { $excludeArgs += "--exclude-caches" }

    $excludeIfPresent = Get-ConfigValue -Config $Config -Path "general.exclude_if_present" -Default @()
    foreach ($marker in $excludeIfPresent) {
        $excludeArgs += "--exclude-if-present=$marker"
    }

    $compression = Get-ConfigValue -Config $Config -Path "general.compression" -Default "auto"
    $compressionArg = "--compression=$compression"

    $oneFileSystem = Get-ConfigValue -Config $Config -Path "general.one_file_system" -Default $false
    $ofsArg = @()
    if ($oneFileSystem) { $ofsArg = @("--one-file-system") }

    $tags = Get-ConfigValue -Config $Config -Path "general.tags" -Default @()
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
# 2. Run backup (with progress bar and verbose output)
# -----------------------------------------------------------------------------
function Start-Backup {
    param($Config, [string]$ResticExe)

    Write-Header "Run backup"

    # Build source list (expand %USERNAME% etc.)
    $sources = $Config.sources | ForEach-Object { [System.Environment]::ExpandEnvironmentVariables($_) }

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
        Write-Err "No valid source paths found. Check the 'sources' section in config.json."
        return
    }

    Write-Info "Sources to back up ($($validSources.Count)):"
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
                $backupArgs = @("backup") + $validSources + $excludeArgs + @($compressionArg, "--json") + $ofsArg + $tagArgs

                $result = Invoke-ResticWithProgress -ResticExe $ResticExe -Repository $repo `
                                                    -Password $backend.password `
                                                    -Arguments $backupArgs `
                                                    -BackendName $name
            }
            else {
                # Silent mode
                $backupArgs = @("backup") + $validSources + $excludeArgs + @($compressionArg, "--json") + $ofsArg + $tagArgs

                $result = Invoke-Restic -ResticExe $ResticExe -Repository $repo `
                                        -Password $backend.password -Arguments $backupArgs -Silent

                # Parse summary from output
                $summaryLine = ($result.Output | Select-String '"message_type":"summary"').Line
                if ($summaryLine) {
                    try {
                        $parsedSummary = $summaryLine | ConvertFrom-Json
                        $result | Add-Member -NotePropertyName Summary -NotePropertyValue $parsedSummary
                    }
                    catch {
                        Write-Log "Failed to parse backup summary JSON: $_" "WARN"
                    }
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
                # Try to parse summary from output
                foreach ($line in $result.Output) {
                    if ($line -match '"message_type"\s*:\s*"summary"') {
                        try { $summary = $line | ConvertFrom-Json } catch {}
                    }
                }
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
# 4. Restore backup (with include/exclude filters)
# -----------------------------------------------------------------------------
function Restore-Backup {
    param($Config, [string]$ResticExe)

    Write-Header "Restore backup"

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

        $snapshotId  = Read-Host "Enter snapshot ID to restore, 'latest', or leave empty to cancel"
        if ([string]::IsNullOrWhiteSpace($snapshotId)) {
            Write-Info "Restore cancelled."
            return
        }

        $restorePath = Read-Host "Enter restore destination path (or leave empty to cancel)"

        if ([string]::IsNullOrWhiteSpace($restorePath)) {
            Write-Err "Restore path cannot be empty."
            return
        }

        # Optional include/exclude filters
        $filterArgs = @()
        Write-Host ""
        Write-Info "Optional: You can filter which files to restore."
        $includePattern = Read-Host "Include pattern (e.g. '*.docx') or press Enter to skip"
        if (-not [string]::IsNullOrWhiteSpace($includePattern)) {
            $filterArgs += @("--include", $includePattern)
        }
        $excludePattern = Read-Host "Exclude pattern (e.g. '*.tmp') or press Enter to skip"
        if (-not [string]::IsNullOrWhiteSpace($excludePattern)) {
            $filterArgs += @("--exclude", $excludePattern)
        }

        Write-Step "Restoring snapshot '$snapshotId' to '$restorePath'..."
        Write-Log "Restoring [$name] snapshot $snapshotId to $restorePath"

        $restoreArgs = @("restore", $snapshotId, "--target", $restorePath, "--json") + $filterArgs

        $result = Invoke-ResticWithProgress -ResticExe $ResticExe -Repository $repo `
                                            -Password $backend.password `
                                            -Arguments $restoreArgs `
                                            -BackendName $name `
                                            -ActivityName "Restore from $name"

        if ($result.ExitCode -eq 0) {
            Write-OK "Restore completed successfully."
            Write-Log "[$name] restore OK" "INFO"

            $summary = $result.Summary
            if (-not $summary -and $result.Output) {
                foreach ($line in $result.Output) {
                    if ($line -match '"message_type"\s*:\s*"summary"') {
                        try { $summary = $line | ConvertFrom-Json } catch {}
                    }
                }
            }
            if ($summary) {
                Write-Host ""
                Write-Host "  Restore Summary for [$name]:" -ForegroundColor Green
                $filesRestored = if ($summary.files_restored)  { $summary.files_restored } else { $summary.total_files }
                $bytesRestored = if ($summary.bytes_restored)   { $summary.bytes_restored } else { $summary.total_bytes }
                if ($filesRestored) { Write-Detail ("  Files restored : {0}" -f $filesRestored) }
                if ($bytesRestored) { Write-Detail ("  Bytes restored : {0:F2} MiB" -f ($bytesRestored / 1MB)) }
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
            "0" { return }
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
    $sources = @($Config.sources | ForEach-Object { [System.Environment]::ExpandEnvironmentVariables($_) } |
               Where-Object { Test-Path $_ })

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
            foreach ($line in $result.Output) {
                if ($line -match '"message_type"\s*:\s*"summary"') {
                    try { $summary = $line | ConvertFrom-Json } catch {}
                }
            }
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
function Remove-ResticInstallation {
    param($Config)

    Write-Header "Remove restic installation"

    $resticDir = Join-Path $ScriptRoot "Restic"
    $logDir    = Join-Path $ScriptRoot $Config.general.log_dir

    Write-Info "This will remove the restic binary from the local Restic folder."
    Write-Detail "  Restic folder : $resticDir"
    Write-Detail "  Log folder    : $logDir"
    Write-Host ""
    Write-Warn "Repository data on remote/local backends will NOT be affected."
    Write-Host ""

    $confirm = Read-Host "Remove restic binary? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Info "Removal cancelled."
        return
    }

    # Remove restic binary
    if (Test-Path $resticDir) {
        $exeFiles = @(Get-ChildItem -Path $resticDir -Filter "restic*" -File -ErrorAction SilentlyContinue)
        foreach ($f in $exeFiles) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                Write-OK "Removed: $($f.FullName)"
                Write-Log "Removed restic file: $($f.FullName)" "INFO"
            }
            catch {
                Write-Err "Failed to remove $($f.FullName): $_"
                Write-Log "Failed to remove $($f.FullName): $_" "ERROR"
            }
        }
    }
    else {
        Write-Info "Restic folder not found - nothing to remove."
    }

    # Optionally remove logs
    $removeLogs = Read-Host "Also remove log files? (y/N)"
    if ($removeLogs -eq "y" -or $removeLogs -eq "Y") {
        if (Test-Path $logDir) {
            try {
                Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction Stop
                Write-OK "Removed log folder: $logDir"
            }
            catch {
                Write-Err "Failed to remove log folder: $_"
            }
        }
        else {
            Write-Info "Log folder not found - nothing to remove."
        }
    }

    Write-OK "Restic removal complete."
    Write-Info "Repository data on backends has not been modified."
}

# -----------------------------------------------------------------------------
# Other options sub-menu
# -----------------------------------------------------------------------------
function Show-OtherMenu {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "   Other Options" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  1.  Initialize repository"               -ForegroundColor White
    Write-Host "  2.  Detect available targets"            -ForegroundColor White
    Write-Host "  3.  Unlock repository"                   -ForegroundColor White
    Write-Host "  4.  Browse snapshot contents"            -ForegroundColor White
    Write-Host "  5.  Dry-run backup (preview)"            -ForegroundColor White
    Write-Host "  6.  Remove restic installation"          -ForegroundColor White
    Write-Host "  0.  Back to main menu"                   -ForegroundColor DarkGray
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Invoke-OtherMenu {
    param($Config, [string]$ResticExe)

    while ($true) {
        Show-OtherMenu
        $otherChoice = Read-Host "Enter your choice"

        switch ($otherChoice) {
            "1" { Initialize-Repository    -Config $Config -ResticExe $ResticExe }
            "2" { Show-Targets             -Config $Config }
            "3" { Unlock-Repository        -Config $Config -ResticExe $ResticExe }
            "4" { Show-SnapshotContents    -Config $Config -ResticExe $ResticExe }
            "5" { Start-DryRunBackup       -Config $Config -ResticExe $ResticExe }
            "6" { Remove-ResticInstallation -Config $Config }
            "0" { return }
            default {
                Write-Err "Invalid choice. Please enter a number from 0 to 6."
                continue
            }
        }

        Write-Host ""
        Read-Host "Press Enter to continue" | Out-Null
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
    $enabled = @()
    if ($Config -and $Config.backends -and $Config.backends.PSObject -and $Config.backends.PSObject.Properties) {
        $Config.backends.PSObject.Properties | ForEach-Object {
            if ($_.Value -and $_.Value.enabled) { $enabled += "$($_.Name)" }
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
    Write-Host "   Restic Manager Backup - Multi-backend CLI" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  1.  Run backup"                          -ForegroundColor White
    Write-Host "  2.  List snapshots"                      -ForegroundColor White
    Write-Host "  3.  Restore backup"                      -ForegroundColor White
    Write-Host "  4.  Prune repository"                    -ForegroundColor White
    Write-Host "  5.  Verify repository"                   -ForegroundColor White
    Write-Host "  6.  Repository statistics"               -ForegroundColor White
    Write-Host "  7.  Other options..."                    -ForegroundColor White
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
        "2"  { Show-Snapshots         -Config $Config -ResticExe $ResticExe }
        "3"  { Restore-Backup         -Config $Config -ResticExe $ResticExe }
        "4"  { Invoke-Prune           -Config $Config -ResticExe $ResticExe }
        "5"  { Test-Repository        -Config $Config -ResticExe $ResticExe }
        "6"  { Show-Stats             -Config $Config -ResticExe $ResticExe }
        "7"  { Invoke-OtherMenu       -Config $Config -ResticExe $ResticExe }
        "0"  {
            Write-Log "Session ended by user"
            Write-Host "`nGoodbye!" -ForegroundColor Cyan
            exit 0
        }
        default {
            Write-Err "Invalid choice. Please enter a number from 0 to 7."
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to the menu" | Out-Null
}
