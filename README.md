# Restic Manager Backup

> **100 % CLI · Windows 64-bit · Multi-backend · Léger et extensible**

Gestionnaire de sauvegardes interactif basé sur [restic](https://restic.net/), conçu pour Windows 64 bits.  
Un seul script PowerShell, un fichier JSON de configuration, des sauvegardes incrémentielles dédupliquées vers plusieurs destinations simultanément.

---

## Sommaire

1. [Prérequis](#prérequis)
2. [Installation](#installation)
3. [Structure des fichiers](#structure-des-fichiers)
4. [Configuration (`config.json`)](#configuration-configjson)
5. [Utilisation du menu CLI](#utilisation-du-menu-cli)
6. [Workflow multi-backend : cloud + USB](#workflow-multi-backend--cloud--usb)
7. [Rétention et pruning](#rétention-et-pruning)
8. [Logs](#logs)
9. [Ajouter un nouveau backend](#ajouter-un-nouveau-backend)
10. [Dépannage](#dépannage)

---

## Prérequis

| Élément | Version minimale |
|---------|-----------------|
| Windows | 10 / Server 2016 (64-bit) |
| PowerShell | 5.1 (inclus dans Windows 10) |
| restic | 0.16 ou plus récent |

> **PowerShell 7+** est recommandé pour de meilleures performances JSON.

---

## Installation

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

Remplir les sections des backends que vous souhaitez activer (voir [Configuration](#configuration-configjson)).

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

## Configuration (`config.json`)

### Section `general`

| Clé | Description |
|-----|-------------|
| `restic_exe` | Chemin relatif vers `restic.exe` |
| `log_dir` | Dossier des logs |
| `repos_dir` | Dossier des repositories locaux |
| `log_retention_days` | Durée de conservation des logs (jours) |

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
  "repository": "s3:https://s3.pub1.infomaniak.cloud/mon-bucket",
  "password": "mot-de-passe-restic",
  "env": {
    "AWS_ACCESS_KEY_ID":     "ACCESS_KEY",
    "AWS_SECRET_ACCESS_KEY": "SECRET_KEY"
  }
}
```

#### Exemple Swift (OpenStack / OVH)

```json
"swift": {
  "enabled": true,
  "repository": "swift:mon-conteneur:/restic",
  "password": "mot-de-passe-restic",
  "env": {
    "OS_AUTH_URL":   "https://auth.cloud.ovh.net/v3",
    "OS_USERNAME":   "user",
    "OS_PASSWORD":   "pass",
    "OS_TENANT_NAME":"tenant",
    "OS_REGION_NAME":"GRA"
  }
}
```

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

Au démarrage, le menu suivant s'affiche :

```
============================================================
   Restic Manager Backup – Multi-backend CLI
============================================================
  1. Initialize repository
  2. Run backup (all enabled backends)
  3. List snapshots
  4. Restore backup
  5. Verify repository
  6. Prune repository
  7. Repository statistics
  8. Detect available targets
  0. Quit
============================================================
```

### Option 1 – Initialiser le repository

Crée un nouveau repository restic sur chaque backend activé.  
Si le repository existe déjà, cette opération est ignorée sans erreur.  
**À exécuter une seule fois par backend.**

### Option 2 – Lancer le backup

Lance une sauvegarde incrémentale et dédupliquée vers **tous les backends activés** en séquence.  
- Les backends réseau (S3, Swift, SFTP) sont ignorés si le réseau n'est pas disponible.  
- La compression automatique est activée (`--compression=auto`).  
- Un résumé est affiché après chaque backend (fichiers nouveaux/modifiés, données ajoutées, durée).

### Option 3 – Lister les snapshots

Affiche la liste de tous les snapshots disponibles dans chaque backend activé.

### Option 4 – Restaurer un backup

1. Sélectionner le backend source.  
2. Choisir l'ID de snapshot (ou `latest`).  
3. Indiquer le répertoire de destination.

### Option 5 – Vérifier le repository

Exécute `restic check` pour s'assurer de l'intégrité des données dans chaque backend.

### Option 6 – Prune (nettoyage)

Applique la politique de rétention définie dans `config.json` et supprime les anciens snapshots/packs inutilisés.

### Option 7 – Statistiques

Affiche les statistiques de stockage (taille totale, déduplication) pour chaque backend.

### Option 8 – Détecter les cibles disponibles

Liste :
- Tous les lecteurs locaux et amovibles (lettre, label, type, espace libre/total)
- La présence ou non de la clé USB configurée
- La disponibilité du réseau

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

## Logs

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

---

## Sécurité

> ⚠️ **Les mots de passe et credentials sont stockés en clair dans `config.json`.**

Mesures de protection recommandées :

- **Restreindre les permissions du fichier** (seul votre compte utilisateur doit pouvoir le lire) :
  ```powershell
  icacls config.json /inheritance:r /grant:r "$($env:USERNAME):(R,W)"
  ```
- **Ne jamais versionner `config.json`** avec vos vraies credentials dans un dépôt public. Le fichier fourni ne contient que des valeurs d'exemple.
- Pour une sécurité renforcée, envisager de stocker les mots de passe dans le **Windows Credential Manager** et de les lire dynamiquement dans le script via `Get-StoredCredential` (module `CredentialManager`).

---

## Licence

MIT – Libre d'utilisation, de modification et de distribution.
