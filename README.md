# Restic Manager Backup

> **100% CLI · Windows 64-bit · Multi-backend · Lightweight & Extensible**

Interactive backup manager built on [restic](https://restic.net/), designed for Windows 64-bit.  
A single PowerShell script, a JSON configuration file, and incremental deduplicated backups to multiple destinations simultaneously.

**v2.0.0** – Real-time progress bar, per-backend selection, dry-run backup, snapshot browsing, repository unlock, config validation, restore filters, prune confirmation, and startup banner.

🇫🇷 *[Version française ci-dessous](#version-française)*

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
Restic-Manager-Backup\
│
├── backup-manager.ps1    # Main script – interactive menu
├── config.json           # Full configuration (backends, sources, retention)
├── .gitignore
├── LICENSE               # MIT License
├── CONTRIBUTING.md       # Contribution guidelines
├── CHANGELOG.md          # Version history
├── SECURITY.md           # Security policy and best practices
│
├── Restic\
│   └── restic.exe        # Restic binary (download separately)
│
├── logs\                 # Timestamped logs generated automatically
│   └── backup_YYYYMMDD_HHMMSS.log
│
└── repos\
    └── local\            # Local restic repository (internal disk)
```

---

## Configuration (`config.json`)

### `general` Section

| Key                    | Description                                                                 |
|------------------------|-----------------------------------------------------------------------------|
| `restic_exe`           | Relative path to `restic.exe`                                               |
| `log_dir`              | Log directory                                                               |
| `log_retention_days`   | Log retention duration (days)                                               |
| `verbose`              | `true` / `false` – enable verbose output with real-time progress bar        |
| `compression`          | `"auto"`, `"off"`, or `"max"` – compression mode for backups               |
| `one_file_system`      | `true` / `false` – stay on one filesystem (no mount-point traversal)        |
| `tags`                 | Array of default tags applied to every backup (e.g. `["daily", "desktop"]`) |
| `exclude_caches`       | `true` / `false` – exclude cache directories                               |
| `exclude_if_present`   | Array of marker filenames (e.g. `[".nobackup"]`) – skip directories containing these files |

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
| `enabled`     | `true` / `false` – enable or disable backend  |
| `description` | Text displayed in the menu                    |
| `password`    | Restic repository password                    |
| `env`         | Backend-specific environment variables        |

#### S3 Example (Swiss Backup Infomaniak)

```json
"s3": {
  "enabled": true,
  "description": "Swiss Backup – Infomaniak S3",
  "repository": "s3:https://s3.swiss-backup01.infomaniak.com/default",
  "password": "your-restic-password",
  "env": {
    "AWS_ACCESS_KEY_ID":     "your-s3-access-key",
    "AWS_SECRET_ACCESS_KEY": "your-s3-secret-key"
  }
}
```

> The S3 endpoint varies by datacenter (`swiss-backup01`, `swiss-backup02`, `swiss-backup03`…). Check your Infomaniak manager panel for the correct hostname. The bucket is usually `default`.

#### Swift Example (Swiss Backup Infomaniak)

```json
"swift": {
  "enabled": true,
  "description": "Swiss Backup – Infomaniak Swift",
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

> Replace `swiss-backup0X` with your actual datacenter number (01, 02, 03…) and `SBI-AB123456` with your real username. These values are displayed in your Infomaniak manager under **Swiss Backup > Connection info**.

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

At startup, a banner displays the version, enabled backends, and source count. Then the following menu is displayed:

```
============================================================
   Restic Manager Backup - Multi-backend CLI
============================================================
  1. Initialize repository
  2. Run backup
  3. List snapshots
  4. Restore backup
  5. Verify repository
  6. Prune repository
  7. Repository statistics
  8. Detect available targets
  9. Unlock repository
  10. Browse snapshot contents
  11. Dry-run backup
  0. Quit
============================================================
```

### Option 1 – Initialize repository

Creates a new restic repository on each enabled backend.  
If the repository already exists, this operation is silently skipped.  
**Run once per backend.**

### Option 2 – Run backup

Runs an incremental, deduplicated backup. You can select specific backends or run all enabled backends at once.
- A real-time **progress bar** shows file count, bytes processed, and the current file being backed up (when `verbose` is enabled).
- Network backends (S3, Swift, SFTP) are skipped if no network is available.
- Compression mode is configurable via `config.json` (`"auto"`, `"off"`, or `"max"`).
- An enhanced **per-backend summary table** is displayed after completion (files new/changed, data added, duration, snapshot ID).
- Elapsed time is shown for each backend.

### Option 3 – List snapshots

Displays a list of all available snapshots in each enabled backend.

### Option 4 – Restore backup

1. Select the source backend.
2. Choose the snapshot ID (or `latest`).
3. Enter the destination directory.
4. Optionally specify **include/exclude patterns** to restore only specific files or skip certain paths.

### Option 5 – Verify repository

Runs `restic check` to verify data integrity in each backend.

### Option 6 – Prune (cleanup)

Displays the current retention policy and asks for **Y/N confirmation** before proceeding.  
Applies the retention policy defined in `config.json` and removes old unused snapshots/packs.

### Option 7 – Statistics

Displays storage statistics (total size, deduplication) for each backend.

### Option 8 – Detect available targets

Lists:
- All local and removable drives (letter, label, type, free/total space)
- Whether the configured USB drive is present
- Network availability

### Option 9 – Unlock repository

Removes stale locks from restic repositories. Useful when a previous operation was interrupted and left a lock behind.

### Option 10 – Browse snapshot contents

Lists the files inside a specific snapshot using `restic ls`. Select a backend and snapshot ID to explore its contents.

### Option 11 – Dry-run backup

Simulates a backup without actually writing any data. Shows what files **would** be backed up, allowing you to verify your sources and exclusions before committing.

---

## Multi-backend Workflow: Cloud + USB

Here is a recommended workflow:

```
1. [First time only] Initialize repositories (option 1)
2. Connect the USB drive
3. Run backup (option 2)
   ├── Backend "local"  → C:\...\repos\local\
   ├── Backend "usb"    → E:\ResticRepo\  (USB drive)
   └── Backend "s3"     → s3:https://...  (cloud, if network available)
4. Verify repositories (option 5) – periodically
5. Prune (option 6) – weekly or monthly
```

---

## Retention and Pruning

The **Prune (option 6)** command runs `restic forget --prune` with the following parameters (configurable in `config.json`):

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

3. **Environment variables**: restic natively supports variables for major providers (AWS, Azure, GCS, OpenStack…). Enter them in the backend's `env` field.

Example – Backblaze B2 backend:

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
| Repo already initialized       | Normal – the script detects and silently skips                           |

---

## Security

> ⚠️ **Passwords and credentials are stored in plain text in `config.json`.**

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

[MIT](LICENSE) – Free to use, modify, and distribute.

---
---

# Version française

> **100 % CLI · Windows 64-bit · Multi-backend · Léger et extensible**

Gestionnaire de sauvegardes interactif basé sur [restic](https://restic.net/), conçu pour Windows 64 bits.  
Un seul script PowerShell, un fichier JSON de configuration, des sauvegardes incrémentielles dédupliquées vers plusieurs destinations simultanément.

**v2.0.0** – Barre de progression en temps réel, sélection par backend, dry-run, exploration de snapshots, déverrouillage de dépôt, validation de configuration, filtres de restauration, confirmation de prune et bannière de démarrage.

---

## Sommaire

1. [Prérequis](#prérequis)
2. [Installation (FR)](#installation-fr)
3. [Structure des fichiers](#structure-des-fichiers)
4. [Configuration (`config.json`) (FR)](#configuration-configjson-fr)
5. [Utilisation du menu CLI](#utilisation-du-menu-cli)
6. [Workflow multi-backend : cloud + USB](#workflow-multi-backend--cloud--usb)
7. [Rétention et pruning](#rétention-et-pruning)
8. [Logs (FR)](#logs-fr)
9. [Ajouter un nouveau backend](#ajouter-un-nouveau-backend)
10. [Dépannage](#dépannage)

---

## Prérequis

| Élément | Version minimale |
|---------|-----------------|
| Windows | 10 / Server 2016 (64-bit) |
| PowerShell | 5.1 (inclus dans Windows 10) |
| restic | 0.16 ou plus récent |

> Le script est conçu et testé pour **Windows PowerShell 5.1** (inclus dans Windows 10/11). PowerShell 7+ est compatible grâce à l'utilisation de `Get-CimInstance` (remplaçant de `Get-WmiObject` supprimé dans PS7).

---

## Installation (FR)

### 1. Cloner ou télécharger le projet

```
git clone https://github.com/Miiraak/Restic-Manager-Backup.git
cd Restic-Manager-Backup
```

### 2. Télécharger restic

1. Aller sur <https://github.com/restic/restic/releases>
2. Télécharger `restic_X.Y.Z_windows_amd64.zip`
3. Extraire et renommer le binaire en **`restic.exe`**
4. Copier `restic.exe` dans le dossier `Restic\`

### 3. Configurer `config.json`

Copier et adapter le fichier fourni :

```powershell
Copy-Item config.json config.json.bak   # sauvegarde optionnelle
notepad config.json                      # ou VS Code, etc.
```

Remplir les sections des backends que vous souhaitez activer (voir [Configuration](#configuration-configjson-fr)).

### 4. Lancer le script

```powershell
# Depuis PowerShell (autoriser l'exécution si nécessaire)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\backup-manager.ps1
```

---

## Structure des fichiers

```
Restic-Manager-Backup\
│
├── backup-manager.ps1    # Script principal – menu interactif
├── config.json           # Configuration complète (backends, sources, rétention)
├── .gitignore
├── LICENSE               # Licence MIT
├── CONTRIBUTING.md       # Guide de contribution
├── CHANGELOG.md          # Historique des versions
├── SECURITY.md           # Politique de sécurité
│
├── Restic\
│   └── restic.exe        # Binaire restic (à télécharger)
│
├── logs\                 # Logs horodatés générés automatiquement
│   └── backup_YYYYMMDD_HHMMSS.log
│
└── repos\
    └── local\            # Repository restic local (disque interne)
```

---

## Configuration (`config.json`) (FR)

### Section `general`

| Clé | Description |
|-----|-------------|
| `restic_exe` | Chemin relatif vers `restic.exe` |
| `log_dir` | Dossier des logs |
| `log_retention_days` | Durée de conservation des logs (jours) |
| `verbose` | `true` / `false` – active la sortie détaillée avec barre de progression en temps réel |
| `compression` | `"auto"`, `"off"` ou `"max"` – mode de compression des sauvegardes |
| `one_file_system` | `true` / `false` – rester sur un seul système de fichiers (pas de traversée de points de montage) |
| `tags` | Tableau de tags par défaut appliqués à chaque backup (ex. `["daily", "desktop"]`) |
| `exclude_caches` | `true` / `false` – exclure les répertoires de cache |
| `exclude_if_present` | Tableau de noms de fichiers marqueurs (ex. `[".nobackup"]`) – ignore les dossiers contenant ces fichiers |

### Section `sources`

Liste des dossiers à sauvegarder. Les variables d'environnement comme `%USERNAME%` sont automatiquement résolues.

```json
"sources": [
  "C:\\Users\\%USERNAME%\\Documents",
  "C:\\Users\\%USERNAME%\\Pictures",
  "D:\\Projets"
]
```

### Section `exclusions`

Patterns de fichiers/dossiers à exclure (syntaxe restic) :

```json
"exclusions": ["*.tmp", "*.log", "~$*", "Thumbs.db", "node_modules"]
```

### Section `retention`

Politique de rétention appliquée lors du pruning :

```json
"retention": {
  "keep_last":    5,
  "keep_daily":   7,
  "keep_weekly":  4,
  "keep_monthly": 6,
  "keep_yearly":  1
}
```

### Section `backends`

Chaque backend possède les champs communs :

| Champ | Description |
|-------|-------------|
| `enabled` | `true` / `false` – active ou désactive le backend |
| `description` | Texte affiché dans le menu |
| `password` | Mot de passe du repository restic |
| `env` | Variables d'environnement spécifiques au backend |

#### Exemple S3 (Swiss Backup Infomaniak)

```json
"s3": {
  "enabled": true,
  "description": "Swiss Backup – Infomaniak S3",
  "repository": "s3:https://s3.swiss-backup01.infomaniak.com/default",
  "password": "mot-de-passe-restic",
  "env": {
    "AWS_ACCESS_KEY_ID":     "votre-cle-acces-s3",
    "AWS_SECRET_ACCESS_KEY": "votre-cle-secrete-s3"
  }
}
```

> Le endpoint S3 varie selon le datacenter (`swiss-backup01`, `swiss-backup02`, `swiss-backup03`...). Vérifiez le hostname correct dans votre manager Infomaniak. Le bucket est généralement `default`.

#### Exemple Swift (Swiss Backup Infomaniak)

```json
"swift": {
  "enabled": true,
  "description": "Swiss Backup – Infomaniak Swift",
  "repository": "swift:default:/restic",
  "password": "mot-de-passe-restic",
  "env": {
    "OS_AUTH_URL":             "https://swiss-backup01.infomaniak.com/identity/v3",
    "OS_IDENTITY_API_VERSION": "3",
    "OS_USER_DOMAIN_NAME":     "default",
    "OS_PROJECT_DOMAIN_NAME":  "default",
    "OS_PROJECT_NAME":         "sb_project_SBI-AB123456",
    "OS_TENANT_NAME":          "sb_project_SBI-AB123456",
    "OS_USERNAME":             "SBI-AB123456",
    "OS_PASSWORD":             "votre-mot-de-passe-swift",
    "OS_REGION_NAME":          "RegionOne"
  }
}
```

<details>
<summary><strong>Référence des informations de connexion Infomaniak Swiss Backup</strong></summary>

| Champ | Valeur / Format |
|-------|----------------|
| Nom d'utilisateur | `SBI-AB123456` (depuis votre manager Infomaniak) |
| URL d'authentification | `https://swiss-backup0X.infomaniak.com/identity/v3` |
| Version API | `3` (Keystone v3) |
| Domaine utilisateur | `default` |
| Domaine projet | `default` |
| Projet / Tenant | `sb_project_SBI-AB123456` |
| Région | `RegionOne` |
| Bucket / Conteneur | `default` |

> Remplacez `swiss-backup0X` par le numéro de votre datacenter (01, 02, 03...) et `SBI-AB123456` par votre identifiant réel. Ces valeurs sont affichées dans votre manager Infomaniak sous **Swiss Backup > Informations de connexion**.

</details>

#### Exemple SFTP

```json
"sftp": {
  "enabled": true,
  "repository": "sftp:user@serveur.example.com:/srv/restic/repo",
  "password": "mot-de-passe-restic",
  "env": {}
}
```

> Pour SFTP, la clé SSH doit être configurée sans phrase de passe (ou avec `ssh-agent`).

#### Backend USB

Le script détecte automatiquement le lecteur USB par son **label de volume**.

```json
"usb": {
  "enabled": true,
  "drive_label": "BACKUP_USB",
  "repository_path": "ResticRepo",
  "password": "mot-de-passe-restic",
  "env": {}
}
```

Formater la clé USB avec le label `BACKUP_USB` (NTFS ou exFAT).  
Le repository sera créé dans `E:\ResticRepo\` (lettre de lecteur automatique).

---

## Utilisation du menu CLI

Au démarrage, une bannière affiche la version, les backends activés et le nombre de sources. Puis le menu suivant s'affiche :

```
============================================================
   Restic Manager Backup - Multi-backend CLI
============================================================
  1. Initialize repository
  2. Run backup
  3. List snapshots
  4. Restore backup
  5. Verify repository
  6. Prune repository
  7. Repository statistics
  8. Detect available targets
  9. Unlock repository
  10. Browse snapshot contents
  11. Dry-run backup
  0. Quit
============================================================
```

### Option 1 – Initialiser le repository

Crée un nouveau repository restic sur chaque backend activé.  
Si le repository existe déjà, cette opération est ignorée sans erreur.  
**À exécuter une seule fois par backend.**

### Option 2 – Lancer le backup

Lance une sauvegarde incrémentale et dédupliquée. Vous pouvez sélectionner des backends spécifiques ou les exécuter tous en une fois.
- Une **barre de progression** en temps réel affiche le nombre de fichiers, les octets traités et le fichier en cours (lorsque `verbose` est activé).
- Les backends réseau (S3, Swift, SFTP) sont ignorés si le réseau n'est pas disponible.
- Le mode de compression est configurable via `config.json` (`"auto"`, `"off"` ou `"max"`).
- Un **tableau récapitulatif par backend** amélioré est affiché après l'exécution (fichiers nouveaux/modifiés, données ajoutées, durée, ID du snapshot).
- Le temps écoulé est affiché pour chaque backend.

### Option 3 – Lister les snapshots

Affiche la liste de tous les snapshots disponibles dans chaque backend activé.

### Option 4 – Restaurer un backup

1. Sélectionner le backend source.  
2. Choisir l'ID de snapshot (ou `latest`).  
3. Indiquer le répertoire de destination.
4. Spécifier éventuellement des **filtres d'inclusion/exclusion** pour ne restaurer que certains fichiers ou ignorer certains chemins.

### Option 5 – Vérifier le repository

Exécute `restic check` pour s'assurer de l'intégrité des données dans chaque backend.

### Option 6 – Prune (nettoyage)

Affiche la politique de rétention actuelle et demande une **confirmation Y/N** avant de procéder.  
Applique la politique de rétention définie dans `config.json` et supprime les anciens snapshots/packs inutilisés.

### Option 7 – Statistiques

Affiche les statistiques de stockage (taille totale, déduplication) pour chaque backend.

### Option 8 – Détecter les cibles disponibles

Liste :
- Tous les lecteurs locaux et amovibles (lettre, label, type, espace libre/total)
- La présence ou non de la clé USB configurée
- La disponibilité du réseau

### Option 9 – Déverrouiller le repository

Supprime les verrous obsolètes des repositories restic. Utile lorsqu'une opération précédente a été interrompue et a laissé un verrou.

### Option 10 – Explorer le contenu d'un snapshot

Liste les fichiers contenus dans un snapshot spécifique via `restic ls`. Sélectionnez un backend et un ID de snapshot pour en explorer le contenu.

### Option 11 – Dry-run (simulation de backup)

Simule une sauvegarde sans écrire de données. Affiche les fichiers qui **seraient** sauvegardés, permettant de vérifier vos sources et exclusions avant de lancer la sauvegarde réelle.

---

## Workflow multi-backend : cloud + USB

Voici un exemple de flux de travail recommandé :

```
1. [1ère fois uniquement] Initialiser les repositories (option 1)
2. Connecter la clé USB
3. Lancer le backup (option 2)
   ├── Backend "local"  → C:\...\repos\local\
   ├── Backend "usb"    → E:\ResticRepo\  (clé USB)
   └── Backend "s3"     → s3:https://...  (cloud, si réseau disponible)
4. Vérifier les repositories (option 5) – périodiquement
5. Prune (option 6) – hebdomadaire ou mensuel
```

---

## Rétention et pruning

La commande **Prune (option 6)** exécute `restic forget --prune` avec les paramètres suivants (configurables dans `config.json`) :

| Paramètre | Par défaut | Signification |
|-----------|-----------|---------------|
| `keep_last` | 5 | Garder les 5 derniers snapshots |
| `keep_daily` | 7 | Garder 1 snapshot par jour (7 derniers jours) |
| `keep_weekly` | 4 | Garder 1 snapshot par semaine (4 dernières semaines) |
| `keep_monthly` | 6 | Garder 1 snapshot par mois (6 derniers mois) |
| `keep_yearly` | 1 | Garder 1 snapshot par an |

---

## Logs (FR)

Un nouveau fichier log est créé à chaque session :

```
logs\backup_20240315_143022.log
```

Contenu :
- Timestamp et niveau (`INFO`, `WARN`, `ERROR`)
- Backend, chemin du repository
- Résumé de chaque backup (fichiers, données, durée)
- Erreurs éventuelles

Les logs plus anciens que `log_retention_days` jours sont supprimés automatiquement au démarrage.

---

## Ajouter un nouveau backend

1. **Ajouter une entrée dans `config.json`** sous `backends` avec les champs `enabled`, `description`, `repository`, `password`, `env`.

2. **Si le backend nécessite une logique de résolution spécifique** (comme la détection USB), modifier la fonction `Resolve-Repository` dans `backup-manager.ps1`.

3. **Variables d'environnement** : restic reconnaît nativement les variables des principaux providers (AWS, Azure, GCS, OpenStack…). Les renseigner dans le champ `env` du backend.

Exemple – backend Backblaze B2 :

```json
"b2": {
  "enabled": false,
  "description": "Backblaze B2",
  "repository": "b2:mon-bucket:/restic",
  "password": "mot-de-passe-restic",
  "env": {
    "B2_ACCOUNT_ID":  "votre-account-id",
    "B2_ACCOUNT_KEY": "votre-application-key"
  }
}
```

---

## Dépannage

| Problème | Solution |
|----------|---------|
| `restic.exe not found` | Télécharger restic et le placer dans `Restic\restic.exe` |
| `config.json not found` | Vérifier que `config.json` est dans le même dossier que le script |
| Erreur d'exécution PowerShell | Exécuter `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| Backend USB non détecté | Vérifier que le label de volume correspond exactement à `drive_label` |
| Erreur SFTP | Configurer la clé SSH sans phrase de passe ou démarrer `ssh-agent` |
| Repo déjà initialisé | Normal – le script détecte et ignore cette situation |
