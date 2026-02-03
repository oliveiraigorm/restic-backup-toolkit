#!/bin/bash
set -e

# Configuration
CONFIG_FILE="config.json"
EXAMPLE_CONFIG="config.json.example"

# --- Helpers ---

log() { echo "[INFO] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

# Helper to load config values using Python (reliable JSON parsing)
get_config_value() {
    python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('$1', '$2'))"
}

get_source_keys() {
    python3 -c "import json; print(' '.join(json.load(open('$CONFIG_FILE'))['source_paths'].keys()))"
}

get_source_path() {
    python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['source_paths']['$1'])"
}

get_exclude_paths() {
    python3 -c "import json; print('\n'.join(json.load(open('$CONFIG_FILE'))['exclude_paths']))"
}

# --- Tasks ---

task_check_dependencies() {
    if ! command -v python3 &> /dev/null; then
        error "python3 is required to parse the configuration file."
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        error "$CONFIG_FILE not found. Please copy $EXAMPLE_CONFIG to $CONFIG_FILE and edit it."
    fi
    
    # Validation
    BACKUP_PASSWORD=$(get_config_value "backup_password" "")
    if [ -z "$BACKUP_PASSWORD" ] || [ "$BACKUP_PASSWORD" == "CHANGE_ME" ]; then
        error "Please set a valid backup_password in $CONFIG_FILE"
    fi
}

task_install() {
    local version=$1
    if ! command -v restic &> /dev/null; then
        log "Installing restic v$version..."
        local url="https://github.com/restic/restic/releases/download/v${version}/restic_${version}_linux_amd64.bz2"
        curl -L -o /tmp/restic.bz2 "$url"
        bunzip2 /tmp/restic.bz2
        chmod +x /tmp/restic
        log "Sudo access required to move restic to /usr/local/bin"
        sudo mv /tmp/restic /usr/local/bin/restic
        sudo chown root:root /usr/local/bin/restic
    else
        log "Restic is already installed."
    fi
}

task_setup() {
    local backup_password=$1
    log "Setting up directories and configuration files..."
    
    local restic_dir="$HOME/.restic"
    local bin_dir="$HOME/bin"
    mkdir -p "$restic_dir" "$bin_dir"

    # Password File
    echo -n "$backup_password" > "$restic_dir/.restic_passwd"
    chmod 600 "$restic_dir/.restic_passwd"

    # Exclude File
    get_exclude_paths > "$restic_dir/.restic_exclude"

    # .bashrc PATH
    if ! grep -q "\$HOME/bin" "$HOME/.bashrc"; then
        log "Adding ~/bin to PATH in .bashrc"
        echo 'export PATH=$PATH:$HOME/bin' >> "$HOME/.bashrc"
    fi
}

task_backup_script() {
    local repo=$1
    local healthcheck_url=$2
    local bin_dir="$HOME/bin"
    local script_path="$bin_dir/restic-custom-backup"
    local restic_dir="$HOME/.restic"

    log "Generating backup script at $script_path..."

    # Header
    cat > "$script_path" <<SHELL
#!/bin/bash
set -euo pipefail

# Configuration
RESTIC_PASSWD="$restic_dir/.restic_passwd"
RESTIC_EXCLUDE_FILE="$restic_dir/.restic_exclude"
BACKUP_REPO="$repo"
KEEP_OPTIONS="--keep-hourly 2 --keep-daily 6 --keep-weekly 3 --keep-monthly 1"
HOST_TAG="
$(hostname)"
HEALTHCHECK_URL="$healthcheck_url"

FAILURE=0
LOGFILE="/tmp/restic-backup.log"

exec >> "$LOGFILE" 2>&1

echo "=== Backup started: 
$(date) on $HOST_TAG ==="
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

SHELL

    # Backup Sources Loop
    local sources=$(get_source_keys)
    for service in $sources; do
        local path_val=$(get_source_path "$service")
        cat >> "$script_path" <<SHELL
echo "Backing up $service: $path_val"
/usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" \
    --host "$HOST_TAG" \
    --tag "$service" \
    --exclude-caches \
    --exclude-file="$RESTIC_EXCLUDE_FILE" \
    backup "$path_val"

echo "$service backup complete: $
(/usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" stats --host "$HOST_TAG" --tag "$service")"

SHELL
    done

    # Forget/Prune Loop
    for service in $sources; do
        cat >> "$script_path" <<SHELL
/usr/local/bin/restic -p "$RESTIC_PASSWD" -r "$BACKUP_REPO" \
    forget \
    --host "$HOST_TAG" \
    --tag "$service" \
    --group-by host,tags \
    $KEEP_OPTIONS \
    --cleanup-cache || true

SHELL
    done

    # Footer
    cat >> "$script_path" <<SHELL
# Ping healthcheck
if [ $? -eq 0 ]; then
    if [ -n "$HEALTHCHECK_URL" ]; then
        curl -fsS --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    fi
else
    FAILURE=1
fi

echo "=== Backup finished: 
$(date) ==="
exit $FAILURE
SHELL

    chmod +x "$script_path"
}

task_cron() {
    local schedule=$1
    local script_path="$HOME/bin/restic-custom-backup"

    log "Setting up cron..."
    if ! crontab -l 2>/dev/null | grep -q "$script_path"; then
        (crontab -l 2>/dev/null; echo "$schedule $script_path") | crontab -
        log "Cron job added."
    else
        log "Cron job already exists."
    fi
}

# --- Main ---

main() {
    task_check_dependencies

    # Read config variables
    local restic_version=$(get_config_value "restic_version" "0.18.1")
    local backup_password=$(get_config_value "backup_password" "")
    local repo=$(get_config_value "repository" "")
    local healthcheck_url=$(get_config_value "healthcheck_url" "")
    local cron_schedule=$(get_config_value "cron_schedule" "0 12 * * *")

    # Execute Tasks
    task_install "$restic_version"
    task_setup "$backup_password"
    task_backup_script "$repo" "$healthcheck_url"
    task_cron "$cron_schedule"

    log "Setup complete!"
}

main
