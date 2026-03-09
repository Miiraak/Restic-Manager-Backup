# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.2.0] - 2026-03-09

### Added
- **Restore progress bar**: `Restore-Backup` now displays real-time progress via `Invoke-ResticWithProgress` with `--json` output, including a restore summary on completion
- **ASCII progress bar** (`Write-AsciiProgress`): new colored, in-place console progress bar using pure ASCII characters (`[===>----]`), replacing the native `Write-Progress` cmdlet across all operations (backup, dry-run, restore)

### Changed
- `Invoke-ResticWithProgress` now uses `Write-AsciiProgress` instead of `Write-Progress` for a consistent look across all terminal hosts
- `Invoke-ResticWithProgress` generalised to handle both backup and restore JSON status fields (`files_done`/`bytes_done` and `files_restored`/`bytes_restored`, plus `percent_done`)

---

## [2.1.0] - 2026-03-09

### Changed
- **Progress bar throttled** to ~250ms refresh interval, reducing `Write-Progress` overhead during backup/dry-run without affecting upload speed
- **Extracted `Build-BackupArguments`** helper: eliminates duplicated exclusion/compression/tag argument building between `Start-Backup` and `Start-DryRunBackup`
- **Extracted `Select-SingleBackend`** helper: replaces duplicated backend picker code in `Restore-Backup` and `Show-SnapshotContents`
- Renamed `Load-Config` to `Import-Config` and `Detect-LocalTargets` to `Get-LocalTargets` (approved PowerShell verbs per CONTRIBUTING.md)

### Fixed
- `Invoke-ResticWithProgress` now calls `$process.Dispose()` to release native process handles (resource leak)
- `$process` variable initialized before `try` block to prevent strict-mode error in `finally`

---

## [2.0.0] - 2026-03-09

### Added
- Real-time **progress bar** during backup (file count, bytes processed, current file) using `Write-Progress`
- **Per-backend selection**: choose specific backends or all at once when running a backup
- **3 new menu options** (menu expanded from 8 to 11 operations):
  - Option 9: Unlock repository (removes stale locks after crashed backups)
  - Option 10: Browse snapshot contents (list files in a snapshot via `restic ls`)
  - Option 11: Dry-run backup (preview what would be backed up without writing data)
- **Config validation** at startup with clear warnings for missing or invalid fields
- **Startup banner** showing version, enabled backends, and source path count
- **Prune confirmation prompt** displaying the retention policy before execution
- **Restore filters**: optional `--include` and `--exclude` patterns during restore
- **Backup summary table** at the end of backup showing per-backend results (files, data, duration, snapshot ID)
- New `general` config options: `verbose`, `compression`, `one_file_system`, `tags`, `exclude_caches`, `exclude_if_present`
- `Write-Warn` and `Write-Detail` colored output helpers
- `Test-BackendNetwork` helper to reduce code duplication
- `Get-ConfigValue` helper for safe access to optional config fields with defaults
- Elapsed time displayed per-backend during all operations

### Changed
- Backup now shows invalid source paths as warnings instead of silently skipping them
- Backup uses `System.Diagnostics.Process` for real-time JSON output parsing when verbose mode is enabled
- Menu numbering updated to accommodate new options (0-11)
- **S3 backend** example updated: uses Infomaniak Swiss Backup S3 endpoint (`s3.swiss-backup0X.infomaniak.com`)
- **Swift backend** example updated: replaced generic OVH template with Infomaniak Swiss Backup connection details (Keystone v3, `OS_IDENTITY_API_VERSION`, `OS_PROJECT_NAME`, correct region/domain)
- Added connection info reference table (EN + FR) for Infomaniak Swiss Backup in README
- Duration formatting uses `hh:mm:ss` to avoid misleading wrap after 59 minutes

### Fixed
- Config validation now runs before `Get-ResticExe` / `Initialize-Log` to avoid strict-mode crashes on missing `general` fields
- Stderr event cleanup uses correct `SubscriptionId` property (was `.Name`, which doesn't exist on `PSEventSubscriber`)
- `Invoke-ResticWithProgress` no longer stores every status JSON line in memory (only stderr + summary + non-status lines are retained)
- `log_retention_days` accessed via `Get-ConfigValue` with default of 30 (avoids strict-mode error when field is absent)

---

## [1.0.0] - 2025-06-01

### Added
- Interactive CLI menu with 8 operations (init, backup, list, restore, verify, prune, stats, detect)
- Multi-backend support: S3, Swift (OpenStack), SFTP, local disk, USB drive
- Automatic USB drive detection by volume label
- Network availability check before remote backend operations
- JSON-based configuration (`config.json`)
- Configurable retention policies (keep last, daily, weekly, monthly, yearly)
- Automatic log file creation with timestamps
- Old log file cleanup based on configurable retention period
- Incremental, deduplicated backups via restic
- Automatic compression (`--compression=auto`)
- Backup summary output (new/changed files, data added, duration)
- Environment variable expansion in source paths (`%USERNAME%`, etc.)
- File and folder exclusion patterns
