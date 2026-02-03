#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import shutil
import urllib.request
import bz2
from pathlib import Path

# Constants
CONFIG_FILE = "config.json"
EXAMPLE_CONFIG = "config.json.example"
HOME = Path.home()
RESTIC_DIR = HOME / ".restic"
BIN_DIR = HOME / "bin"
RESTIC_BIN_PATH = Path("/usr/local/bin/restic")
BACKUP_SCRIPT_PATH = BIN_DIR / "restic-custom-backup"

def load_config():
    if not os.path.exists(CONFIG_FILE):
        print(f"Error: {CONFIG_FILE} not found. Please copy {EXAMPLE_CONFIG} to {CONFIG_FILE} and edit it.")
        sys.exit(1)
    
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def check_command(command):
    return shutil.which(command) is not None

def install_restic(version):
    print(f"Checking for restic...")
    if check_command("restic"):
        # optionally check version
        print("restic is already installed.")
        return

    print(f"Installing restic version {version}...")
    url = f"https://github.com/restic/restic/releases/download/v{version}/restic_{version}_linux_amd64.bz2"
    temp_bz2 = "/tmp/restic.bz2"
    
    try:
        print(f"Downloading {url}...")
        urllib.request.urlretrieve(url, temp_bz2)
        
        print("Extracting...")
        with open(temp_bz2, 'rb') as source, open('/tmp/restic', 'wb') as dest:
            dest.write(bz2.decompress(source.read()))
            
        print("Installing to /usr/local/bin/restic (requires sudo)...")
        os.chmod('/tmp/restic', 0o755)
        subprocess.check_call(['sudo', 'mv', '/tmp/restic', str(RESTIC_BIN_PATH)])
        subprocess.check_call(['sudo', 'chown', 'root:root', str(RESTIC_BIN_PATH)])
        
    except Exception as e:
        print(f"Failed to install restic: {e}")
        sys.exit(1)
    finally:
        if os.path.exists(temp_bz2):
            os.remove(temp_bz2)

def setup_directories(config):
    print("Setting up directories...")
    RESTIC_DIR.mkdir(parents=True, exist_ok=True)
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    
    # Write password file
    passwd_file = RESTIC_DIR / ".restic_passwd"
    with open(passwd_file, 'w') as f:
        f.write(config['backup_password'])
    passwd_file.chmod(0o600)
    
    # Write exclude file
    exclude_file = RESTIC_DIR / ".restic_exclude"
    with open(exclude_file, 'w') as f:
        f.write("\n".join(config['exclude_paths']))
    
    # Add bin to PATH in .bashrc if not present
    bashrc = HOME / ".bashrc"
    if bashrc.exists():
        with open(bashrc, 'r') as f:
            content = f.read()
        
        export_line = 'export PATH=$PATH:$HOME/bin'
        if export_line not in content and f'$HOME/bin' not in content:
            print("Adding ~/bin to PATH in .bashrc")
            with open(bashrc, 'a') as f:
                f.write(f"\n{export_line}\n")

def generate_backup_script(config):
    print("Generating backup script...")
    
    sources_block = ""
    forget_block = ""
    
    for service, path in config['source_paths'].items():
        sources_block += f"""
echo "Backing up {service}: {path}"
/usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" \
    --host "$HOST_TAG" \
    --tag "{service}" \
    --exclude-caches \
    --exclude-file="$RESTIC_EXCLUDE_FILE" \
    backup "{path}"

echo "{service} backup complete: $(/usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" stats --host "$HOST_TAG" --tag "{service}")"
"""
        forget_block += f"""
/usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" \
    forget \
    --host "$HOST_TAG" \
    --tag "{service}" \
    --group-by host,tags \
    $KEEP_OPTIONS \
    --cleanup-cache || true
"""

    script_content = f"""#!/bin/bash
set -euo pipefail

# Configuration
RESTIC_PASSWD="{RESTIC_DIR}/.restic_passwd"
RESTIC_EXCLUDE_FILE="{RESTIC_DIR}/.restic_exclude"
BACKUP_REPO="{config['repository']}"
KEEP_OPTIONS="--keep-hourly 2 --keep-daily 6 --keep-weekly 3 --keep-monthly 1"
HOST_TAG="{os.uname().nodename}"
HEALTHCHECK_URL="{config.get('healthcheck_url', '')}"

FAILURE=0
LOGFILE="/tmp/restic-backup.log"

exec >> "$LOGFILE" 2>&1

echo "=== Backup started: $(date) on $HOST_TAG ==="
if [ -n "$HEALTHCHECK_URL" ]; then
    curl -fsS --retry 3 "$HEALTHCHECK_URL/start" >/dev/null 2>&1 || true
fi

# Initialize repository if it doesn't exist
if ! /usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" cat config >/dev/null 2>&1; then
    echo "Initializing restic repository at $BACKUP_REPO"
    /usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" init
fi

# Unlock stale locks
/usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" unlock || true

# Backup Sources
{sources_block}

# Forget/Prune
{forget_block}

# Ping healthcheck
if [ $? -eq 0 ]; then
    if [ -n "$HEALTHCHECK_URL" ]; then
        curl -fsS --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    fi
else
    FAILURE=1
fi

echo "=== Backup finished: $(date) ==="
exit $FAILURE
"""
    
    with open(BACKUP_SCRIPT_PATH, 'w') as f:
        f.write(script_content)
    BACKUP_SCRIPT_PATH.chmod(0o755)
    print(f"Backup script written to {BACKUP_SCRIPT_PATH}")

def setup_cron(config):
    print("Setting up cron job...")
    schedule = config.get('cron_schedule', '0 12 * * *')
    job_command = str(BACKUP_SCRIPT_PATH)
    
    # List current crontab
    try:
        current_cron = subprocess.check_output(['crontab', '-l'], text=True)
    except subprocess.CalledProcessError:
        current_cron = ""
    
    if job_command in current_cron:
        print("Cron job already exists.")
        return

    new_cron_line = f"{schedule} {job_command}\n"
    new_cron = current_cron + new_cron_line
    
    process = subprocess.Popen(['crontab', '-'], stdin=subprocess.PIPE)
    process.communicate(input=new_cron.encode('utf-8'))
    print("Cron job added.")

def main():
    config = load_config()
    install_restic(config['restic_version'])
    setup_directories(config)
    generate_backup_script(config)
    setup_cron(config)
    print("Restic setup complete!")

if __name__ == "__main__":
    main()
