# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
