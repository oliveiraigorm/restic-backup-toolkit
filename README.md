# Restic Backup Toolkit

This project provides both **Python** and **Shell** scripts to automate the installation and configuration of [restic](https://restic.net/) backups on a Linux system.

## Features

*   **Installs Restic:** Downloads the official binary from GitHub.
*   **Configures Environment:** Sets up `~/.restic` with password and exclude files.
*   **Generates Backup Script:** Creates a custom wrapper script `~/bin/restic-custom-backup` that:
    *   Handles authentication automatically.
    *   Initializes the repository if it doesn't exist.
    *   Backs up multiple defined paths with specific tags.
    *   Prunes old backups (forget) according to a retention policy.
    *   Supports healthcheck.io (or compatible) pinging.
*   **Sets up Cron:** Adds a daily cron job to run the backup.

## Prerequisites

*   Linux system (x86_64).
*   `sudo` access (for installing the restic binary to `/usr/local/bin`).
*   `curl` and `bunzip2` (for the Shell script).
*   `python3` (for the Python script, and also used by the Shell script for config parsing).

## Configuration

1.  Copy the example configuration:
    ```bash
    cp config.json.example config.json
    ```

2.  Edit `config.json` with your details:
    *   `repository`: Your restic repository URL (e.g., `s3:https://s3.amazonaws.com/...`, `b2:...`, `/mnt/backup`).
    *   `backup_password`: The encryption password for the repository.
    *   `source_paths`: A dictionary of `service_name: path_to_backup`.
    *   `exclude_paths`: List of file patterns to ignore.
    *   `healthcheck_url`: (Optional) URL to ping on start/success.

## Usage

You can use either the Shell script or the Python script. They perform the same actions.

### Option 1: Python Script

```bash
python3 setup_restic.py
```

### Option 2: Shell Script

```bash
chmod +x setup_restic.sh
./setup_restic.sh
```

## What it does

1.  Checks if `restic` is installed; installs it if missing.
2.  Creates `~/.restic/` and stores the password and exclude list.
3.  Creates `~/bin/restic-custom-backup` with your configured sources.
4.  Adds `~/bin` to your `PATH` in `~/.bashrc` if needed.
5.  Adds a cron job (default: 12:00 PM daily) to run the backup.

## Generated Backup Script

The generated script (`~/bin/restic-custom-backup`) is standalone. You can run it manually to trigger a backup:

```bash
restic-custom-backup
```
