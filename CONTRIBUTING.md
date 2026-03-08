# Contributing to Restic Manager Backup

Thank you for your interest in contributing to Restic Manager Backup! This document provides guidelines and information for contributors.

## How to Contribute

### Reporting Bugs

If you find a bug, please open an issue on GitHub with:
- A clear and descriptive title
- Steps to reproduce the issue
- Expected behavior vs. actual behavior
- Your environment (Windows version, PowerShell version)
- Relevant log output from the `logs/` directory

### Suggesting Features

Feature requests are welcome! Please open an issue with:
- A clear description of the feature
- The use case or problem it solves
- Any relevant examples

### Submitting Changes

1. **Fork** the repository
2. **Create a branch** for your feature or fix (`git checkout -b feature/my-feature`)
3. **Make your changes** following the coding guidelines below
4. **Test** your changes on Windows with PowerShell 5.1 and (optionally) PowerShell 7+
5. **Commit** with clear messages (`git commit -m "Fix: correct USB drive detection"`)
6. **Push** to your fork (`git push origin feature/my-feature`)
7. **Open a Pull Request** with a description of your changes

## Coding Guidelines

### PowerShell Style

- Use **approved verbs** for public-facing functions (e.g., `Get-`, `Set-`, `Invoke-`, `Test-`)
- Follow [PowerShell Best Practices](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/strongly-encouraged-development-guidelines)
- Use `PascalCase` for function names and parameters
- Use `$camelCase` for local variables
- Avoid using automatic variable names (e.g., `$args`, `$input`) as custom variables
- Keep functions focused on a single responsibility

### Compatibility

- The script must remain compatible with **PowerShell 5.1** (built-in to Windows 10/11)
- Use `Get-CimInstance` instead of `Get-WmiObject` (removed in PowerShell 7)
- Test changes on both PowerShell 5.1 and 7+ when possible

### Configuration

- New backends should follow the existing pattern in `config.json`
- Always include `enabled`, `description`, `password`, and `env` fields
- Document any new configuration options in the README

### Security

- **Never** commit real credentials or passwords
- Keep placeholder values in `config.json`
- See [SECURITY.md](SECURITY.md) for security-related guidelines

## Development Setup

1. Clone the repository:
   ```
   git clone https://github.com/Miiraak/Restic-Manager-Backup.git
   cd Restic-Manager-Backup
   ```

2. Download [restic](https://github.com/restic/restic/releases) and place `restic.exe` in the `Restic\` folder.

3. Configure `config.json` with test backends (local backend is easiest for development).

4. Run the script:
   ```powershell
   .\backup-manager.ps1
   ```

## Code of Conduct

- Be respectful and constructive in all interactions
- Focus on the technical merits of contributions
- Help others learn and grow

## License

By contributing to this project, you agree that your contributions will be licensed under the [MIT License](LICENSE).
