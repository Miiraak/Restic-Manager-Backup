# Restic Manager Backup

> **100% CLI | Windows 64-bit | Multi-backend | Lightweight & Extensible**

Interactive backup manager built on [restic](https://restic.net/), designed for Windows 64-bit.  
A single PowerShell script, a JSON configuration file, and incremental deduplicated backups to multiple destinations simultaneously.

**v2.3.0** -- ASCII progress bar, restore progress, per-backend selection, dry-run backup, snapshot browsing, repository unlock & removal, specific snapshot deletion, config validation, restore filters, prune confirmation, startup banner, and performance optimizations.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [File Structure](#file-structure)
4. [Configuration (`config.json`)](#configuration-configjson)
5. [CLI Menu Usage](#cli-menu-usage)
6. [Multi-backend Workflow: Cloud + USB](#multi-backend-workflow-cloud--usb)
7. [Retention and Pruning](#retention-and-pruning)
8. [Logs](#logs)
9. [Adding a New Backend](#adding-a-new-backend)
10. [Troubleshooting](#troubleshooting)
11. [Security](#security)
12. [License](#license)

---

## Prerequisites

| Component  | Minimum Version                  |
|------------|----------------------------------|
| Windows    | 10 / Server 2016 (64-bit)       |
| PowerShell | 5.1 (included in Windows 10)    |
| restic     | 0.16 or later                   |

> The script is designed and tested for **Windows PowerShell 5.1** (built-in to Windows 10/11). PowerShell 7+ is compatible thanks to the use of `Get-CimInstance` (replacement for `Get-WmiObject` removed in PS7).

---

## Installation

### 1. Clone or download the project

```
git clone https://github.com/Miiraak/Restic-Manager-Backup.git
cd Restic-Manager-Backup
```

### 2. Download restic

1. Go to <https://github.com/restic/restic/releases>
2. Download `restic_X.Y.Z_windows_amd64.zip`
3. Extract and rename the binary to **`restic.exe`**
4. Copy `restic.exe` into the `Restic\` folder

### 3. Configure `config.json`

Copy and customize the provided file:

```powershell
Copy-Item config.json config.json.bak   # optional backup
notepad config.json                      # or VS Code, etc.
```

Fill in the backend sections you want to enable (see [Configuration](#configuration-configjson)).

### 4. Run the script

```powershell
# From PowerShell (allow execution if needed)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\backup-manager.ps1
```

---

## File Structure

```
Restic-Manager-Backup/
|
|-- backup-manager.ps1    # Main script -- interactive menu
|-- config.json           # Full configuration (backends, sources, retention)
|-- .gitignore
|-- LICENSE               # MIT License
|-- CONTRIBUTING.md       # Contribution guidelines
|-- CHANGELOG.md          # Version history
|-- SECURITY.md           # Security policy and best practices
|
|-- Restic/
|   +-- restic.exe        # Restic binary (download separately)
|
|-- logs/                 # Timestamped logs generated automatically
|   +-- backup_YYYYMMDD_HHMMSS.log
|
+-- repos/
    +-- local/            # Local restic repository (internal disk)
```

---

## Configuration (`config.json`)

### `general` Section

| Key                    | Description                                                                 |
|------------------------|-----------------------------------------------------------------------------|
| `restic_exe`           | Relative path to `restic.exe`                                               |
| `log_dir`              | Log directory                                                               |
| `log_retention_days`   | Log retention duration (days)                                               |
| `verbose`              | `true` / `false` -- enable verbose output with real-time progress bar        |
| `compression`          | `"auto"`, `"off"`, or `"max"` -- compression mode for backups               |
| `one_file_system`      | `true` / `false` -- stay on one filesystem (no mount-point traversal)        |
| `tags`                 | Array of default tags applied to every backup (e.g. `["daily", "desktop"]`) |
| `exclude_caches`       | `true` / `false` -- exclude cache directories                               |
| `exclude_if_present`   | Array of marker filenames (e.g. `[".nobackup"]`) -- skip directories containing these files |

### `sources` Section

List of folders to back up. Environment variables like `%USERNAME%` are automatically expanded.

```json
"sources": [
  "C:\\Users\\%USERNAME%\\Documents",
  "C:\\Users\\%USERNAME%\\Pictures",
  "D:\\Projects"
]
```

### `exclusions` Section

File/folder patterns to exclude (restic syntax):

```json
"exclusions": ["*.tmp", "*.log", "~$*", "Thumbs.db", "node_modules"]
```

### `retention` Section

Retention policy applied during pruning:

```json
"retention": {
  "keep_last":    5,
  "keep_daily":   7,
  "keep_weekly":  4,
  "keep_monthly": 6,
  "keep_yearly":  1
}
```

### `backends` Section

Each backend has these common fields:

| Field         | Description                                   |
|---------------|-----------------------------------------------|
| `enabled`     | `true` / `false` -- enable or disable backend  |
| `description` | Text displayed in the menu                    |
| `password`    | Restic repository password                    |
| `env`         | Backend-specific environment variables        |

#### S3 Example (Swiss Backup Infomaniak)

```json
"s3": {
  "enabled": true,
  "description": "Swiss Backup -- Infomaniak S3",
  "repository": "s3:https://s3.swiss-backup01.infomaniak.com/default",
  "password": "your-restic-password",
  "env": {
    "AWS_ACCESS_KEY_ID":     "your-s3-access-key",
    "AWS_SECRET_ACCESS_KEY": "your-s3-secret-key"
  }
}
```

> The S3 endpoint varies by datacenter (`swiss-backup01`, `swiss-backup02`, `swiss-backup03`...). Check your Infomaniak manager panel for the correct hostname. The bucket is usually `default`.

#### Swift Example (Swiss Backup Infomaniak)

```json
"swift": {
  "enabled": true,
  "description": "Swiss Backup -- Infomaniak Swift",
  "repository": "swift:default:/restic",
  "password": "your-restic-password",
  "env": {
    "OS_AUTH_URL":             "https://swiss-backup01.infomaniak.com/identity/v3",
    "OS_IDENTITY_API_VERSION": "3",
    "OS_USER_DOMAIN_NAME":     "default",
    "OS_PROJECT_DOMAIN_NAME":  "default",
    "OS_PROJECT_NAME":         "sb_project_SBI-AB123456",
    "OS_TENANT_NAME":          "sb_project_SBI-AB123456",
    "OS_USERNAME":             "SBI-AB123456",
    "OS_PASSWORD":             "your-swift-password",
    "OS_REGION_NAME":          "RegionOne"
  }
}
```

<details>
<summary><strong>Infomaniak Swiss Backup connection reference</strong></summary>

| Field | Value / Format |
|-------|---------------|
| Username | `SBI-AB123456` (from your Infomaniak manager) |
| Auth URL | `https://swiss-backup0X.infomaniak.com/identity/v3` |
| API version | `3` (Keystone v3) |
| User domain | `default` |
| Project domain | `default` |
| Project / Tenant | `sb_project_SBI-AB123456` |
| Region | `RegionOne` |
| Bucket / Container | `default` |

> Replace `swiss-backup0X` with your actual datacenter number (01, 02, 03...) and `SBI-AB123456` with your real username. These values are displayed in your Infomaniak manager under **Swiss Backup > Connection info**.

</details>

#### SFTP Example

```json
"sftp": {
  "enabled": true,
  "repository": "sftp:user@backup-server.example.com:/srv/restic/repo",
  "password": "your-restic-password",
  "env": {}
}
```

> For SFTP, the SSH key must be configured without a passphrase (or with `ssh-agent`).

#### USB Backend

The script automatically detects the USB drive by its **volume label**.

```json
"usb": {
  "enabled": true,
  "drive_label": "BACKUP_USB",
  "repository_path": "ResticRepo",
  "password": "your-restic-password",
  "env": {}
}
```

Format the USB drive with the label `BACKUP_USB` (NTFS or exFAT).  
The repository will be created at `E:\ResticRepo\` (drive letter assigned automatically).

---

## CLI Menu Usage

At startup, a banner displays the version, enabled backends, and source count. Then the **main menu** is displayed:

```
============================================================
   Restic Manager Backup v3.0.0
============================================================
  1.  Backup
  2.  Restore
  3.  Snapshots
  4.  Prune / retention
  5.  Repository health
  6.  Configuration
  7.  Maintenance & tools
  0.  Quit
============================================================
```

### Main Menu

#### Option 1 -- Backup

Presents a **backup type selection** submenu:
1. **Full backup** -- Back up all configured sources
2. **Specific files or folders** -- Enter custom paths interactively
3. **Single folder** -- Quick backup of one folder
4. **VSS snapshot** -- Use Windows Volume Shadow Copy for consistent backups of locked files
5. **Dry-run** -- Preview what would be backed up without writing data

After selecting the type, choose backends. A colored **ASCII progress bar** shows progress. An enhanced **per-backend summary table** is displayed after completion.

#### Option 2 -- Restore

Presents a **restore mode selection** submenu:
1. **Full snapshot restore** -- Restore the entire snapshot
2. **Restore specific folder** -- Uses restic's `snapshot:subfolder` syntax to restore a single directory tree
3. **Restore specific file(s)** -- Uses `--include` patterns to restore individual files
4. **Dry-run restore** -- Preview what would be restored without writing any files

After selecting the mode, choose the overwrite behavior:
- Always overwrite (default)
- Only if changed (skip matching files)
- Only if newer (by modification time)
- Never overwrite existing files

A real-time **ASCII progress bar** shows restore progress, followed by a restore summary.

#### Option 3 -- Snapshots

Opens a submenu for snapshot management:
1. **List all snapshots** -- Display snapshots across backends
2. **Browse snapshot contents** -- List files in a specific snapshot (`restic ls`)
3. **Find files across snapshots** -- Search for a file by name (`restic find`)
4. **Compare snapshots (diff)** -- Show differences between two snapshots

#### Option 4 -- Prune / retention

Opens a sub-menu with two options:
1. **Prune by retention policy** -- Applies the policy from `config.json` with Y/N confirmation
2. **Delete specific snapshot** -- Remove a single snapshot by ID

#### Option 5 -- Repository health

Consolidated health checks:
1. **Verify integrity** -- Run `restic check` on repositories
2. **Repository statistics** -- Display storage stats (size, deduplication)
3. **Full health check** -- Run both verify and stats together

#### Option 6 -- Configuration

Interactive config editor without leaving the CLI:
1. **View current configuration** -- Display all settings
2. **Edit source paths** -- Add/remove backup sources
3. **Edit exclusion patterns** -- Add/remove exclusion patterns
4. **Edit retention policy** -- Change keep_last, keep_daily, etc.
5. **Toggle backends** -- Enable/disable backends
6. **Edit general settings** -- Toggle verbose, change compression, etc.
7. **Reload config from disk** -- Re-read config.json after external edits
8. **Open config.json in editor** -- Launch external editor

#### Option 7 -- Maintenance & tools

Utility operations:
1. **Initialize repository** -- Create new restic repos on backends (run once per backend)
2. **Unlock repository** -- Remove stale locks from interrupted operations
3. **Detect available targets** -- List drives, USB status, and network availability
4. **Remove repository** -- Permanently delete local or remote repositories (with safety checks)

---

## Multi-backend Workflow: Cloud + USB

Here is a recommended workflow:

```
1. [First time only] Initialize repositories (Maintenance & tools > option 1)
2. Connect the USB drive
3. Run backup (Backup > select type > select backends)
   |-- Backend "local"  -> C:\...\repos\local\
   |-- Backend "usb"    -> E:\ResticRepo\  (USB drive)
   +-- Backend "s3"     -> s3:https://...  (cloud, if network available)
4. Repository health (option 5) -- periodically
5. Prune (option 4) -- weekly or monthly
```

---

## Retention and Pruning

The **Prune (option 4)** command runs `restic forget --prune` with the following parameters (configurable in `config.json`):

| Parameter      | Default | Meaning                                        |
|----------------|---------|------------------------------------------------|
| `keep_last`    | 5       | Keep the last 5 snapshots                      |
| `keep_daily`   | 7       | Keep 1 snapshot per day (last 7 days)          |
| `keep_weekly`  | 4       | Keep 1 snapshot per week (last 4 weeks)        |
| `keep_monthly` | 6       | Keep 1 snapshot per month (last 6 months)      |
| `keep_yearly`  | 1       | Keep 1 snapshot per year                       |

---

## Logs

A new log file is created for each session:

```
logs\backup_20240315_143022.log
```

Contents:
- Timestamp and level (`INFO`, `WARN`, `ERROR`)
- Backend, repository path
- Backup summary (files, data, duration)
- Any errors encountered

Logs older than `log_retention_days` days are automatically deleted at startup.

---

## Adding a New Backend

1. **Add an entry in `config.json`** under `backends` with the fields `enabled`, `description`, `repository`, `password`, `env`.

2. **If the backend requires custom resolution logic** (like USB drive detection), modify the `Resolve-Repository` function in `backup-manager.ps1`.

3. **Environment variables**: restic natively supports variables for major providers (AWS, Azure, GCS, OpenStack...). Enter them in the backend's `env` field.

Example -- Backblaze B2 backend:

```json
"b2": {
  "enabled": false,
  "description": "Backblaze B2",
  "repository": "b2:my-bucket:/restic",
  "password": "your-restic-password",
  "env": {
    "B2_ACCOUNT_ID":  "your-account-id",
    "B2_ACCOUNT_KEY": "your-application-key"
  }
}
```

---

## Troubleshooting

| Problem                        | Solution                                                                 |
|--------------------------------|--------------------------------------------------------------------------|
| `restic.exe not found`         | Download restic and place it in `Restic\restic.exe`                      |
| `config.json not found`        | Ensure `config.json` is in the same folder as the script                 |
| PowerShell execution error     | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`                |
| USB backend not detected       | Verify the volume label matches `drive_label` exactly                    |
| SFTP error                     | Configure SSH key without passphrase or start `ssh-agent`                |
| Repo already initialized       | Normal -- the script detects and silently skips                           |

---

## Security

> [!] **Passwords and credentials are stored in plain text in `config.json`.**

See [SECURITY.md](SECURITY.md) for detailed security guidelines.

Recommended measures:
- **Restrict file permissions** (only your user account should be able to read and write it):
  ```powershell
  icacls config.json /inheritance:r /grant:r "$($env:USERNAME):(R,W)"
  ```
- **Never commit `config.json`** with real credentials to a public repository. The provided file contains only placeholder values.
- For enhanced security, consider storing passwords in the **Windows Credential Manager** and reading them dynamically via `Get-StoredCredential` (module `CredentialManager`).

---

## License

[MIT](LICENSE) -- Free to use, modify, and distribute.
