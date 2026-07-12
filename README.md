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
   Restic Manager Backup - Multi-backend CLI
============================================================
  1.  Run backup
  2.  List snapshots
  3.  Restore backup
  4.  Prune repository
  5.  Verify repository
  6.  Repository statistics
  7.  Other options...
  0.  Quit
============================================================
```

Selecting **option 7** opens the **Other options** sub-menu:

```
============================================================
   Other Options
============================================================
  1.  Initialize repository
  2.  Detect available targets
  3.  Unlock repository
  4.  Browse snapshot contents
  5.  Dry-run backup (preview)
  6.  Remove repository
  0.  Back to main menu
============================================================
```

### Main Menu

#### Option 1 -- Run backup

Runs an incremental, deduplicated backup. You can select specific backends or run all enabled backends at once.
- A colored **ASCII progress bar** shows file count, bytes processed, and the current file being backed up (when `verbose` is enabled).
- Network backends (S3, Swift, SFTP) are skipped if no network is available.
- Compression mode is configurable via `config.json` (`"auto"`, `"off"`, or `"max"`).
- An enhanced **per-backend summary table** is displayed after completion (files new/changed, data added, duration, snapshot ID).
- Elapsed time is shown for each backend.

#### Option 2 -- List snapshots

Displays a list of all available snapshots in each enabled backend.

#### Option 3 -- Restore backup

1. Select the source backend.
2. Choose the snapshot ID (or `latest`).
3. Enter the destination directory.
4. Optionally specify **include/exclude patterns** to restore only specific files or skip certain paths.
5. A real-time **ASCII progress bar** displays restore progress, followed by a restore summary on completion.

#### Option 4 -- Prune repository

Opens a sub-menu with two options:
1. **Prune by retention policy** -- Displays the current retention policy and asks for **Y/N confirmation** before proceeding. Applies the policy defined in `config.json` and removes old unused snapshots/packs.
2. **Delete specific snapshot** -- Lists snapshots for a selected backend and lets you delete a specific snapshot by ID (with confirmation).

#### Option 5 -- Verify repository

Runs `restic check` to verify data integrity in each backend.

#### Option 6 -- Statistics

Displays storage statistics (total size, deduplication) for each backend.

#### Option 7 -- Other options

Opens the sub-menu described above.

### Other Options Sub-Menu

#### Option 1 -- Initialize repository

Creates a new restic repository on each enabled backend.  
If the repository already exists, this operation is silently skipped.  
**Run once per backend.**

#### Option 2 -- Detect available targets

Lists:
- All local and removable drives (letter, label, type, free/total space)
- Whether the configured USB drive is present
- Network availability

#### Option 3 -- Unlock repository

Removes stale locks from restic repositories. Useful when a previous operation was interrupted and left a lock behind.

#### Option 4 -- Browse snapshot contents

Lists the files inside a specific snapshot using `restic ls`. Select a backend and snapshot ID to explore its contents.

#### Option 5 -- Dry-run backup (preview)

Simulates a backup without actually writing any data. Shows what files **would** be backed up, allowing you to verify your sources and exclusions before committing.

#### Option 6 -- Remove repository

Permanently deletes a restic repository. Opens a sub-menu with two options:
1. **Remove local repository** (local / USB) -- Deletes the repository folder from the local disk or USB drive after safety checks (won't delete drive roots or the script directory, and verifies the target is a valid restic repository).
2. **Remove remote repository** (S3 / Swift / SFTP) -- Displays instructions and provider-specific commands for removing remote repositories, since they cannot be deleted directly by the script.

---

## Multi-backend Workflow: Cloud + USB

Here is a recommended workflow:

```
1. [First time only] Initialize repositories (Main Menu > option 7 > Other options > option 1)
2. Connect the USB drive
3. Run backup (Main Menu > option 1)
   |-- Backend "local"  -> C:\...\repos\local\
   |-- Backend "usb"    -> E:\ResticRepo\  (USB drive)
   +-- Backend "s3"     -> s3:https://...  (cloud, if network available)
4. Verify repositories (option 5) -- periodically
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
