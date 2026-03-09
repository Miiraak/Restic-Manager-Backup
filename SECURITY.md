# Security Policy

## Credential Handling

> ⚠️ **Passwords and credentials are stored in plain text in `config.json`.**

This is a known limitation of the current design. Take the following precautions:

### Restrict File Permissions

Limit access to `config.json` so only your user account can read and write it:

```powershell
icacls config.json /inheritance:r /grant:r "$($env:USERNAME):(R,W)"
```

### Never Commit Real Credentials

The `config.json` file in this repository contains only placeholder values. If you fork or clone this project:

- **Do not** commit your actual passwords, access keys, or secrets
- Consider adding `config.json` to a local `.gitignore` override if you customize it
- Use `git update-index --assume-unchanged config.json` to prevent accidental commits of your local changes

### Alternative: Windows Credential Manager

For stronger security, consider storing sensitive values in the **Windows Credential Manager** and reading them dynamically:

1. Install the `CredentialManager` PowerShell module:
   ```powershell
   Install-Module -Name CredentialManager -Scope CurrentUser
   ```

2. Store your credentials:
   ```powershell
   New-StoredCredential -Target "ResticBackup-S3" -UserName "access-key" -Password "secret-key"
   ```

3. Modify the script to retrieve credentials at runtime using `Get-StoredCredential`.

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please:

1. **Do not** open a public issue
2. Contact the maintainer directly via GitHub (private message or security advisory)
3. Provide a clear description of the vulnerability and steps to reproduce it

We will acknowledge receipt and work on a fix as soon as possible.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 2.0.x   | ✅        |
| 1.0.x   | ✅        |
