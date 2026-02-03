#!/bin/bash
set -e

# Configuration
CONFIG_FILE="config.json"
EXAMPLE_CONFIG="config.json.example"

# Helpers
log() { echo "[INFO] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

# Dependency Check
if ! command -v python3 &> /dev/null;
    then
    error "python3 is required to parse the configuration file."
fi

# Load Config
if [ ! -f "$CONFIG_FILE" ]; then
    error "$CONFIG_FILE not found. Please copy $EXAMPLE_CONFIG to $CONFIG_FILE and edit it."
fi

get_config() {
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

RESTIC_VERSION=$(get_config "restic_version" "0.18.1")
BACKUP_PASSWORD=$(get_config "backup_password" "")
REPO=$(get_config "repository" "")
HEALTHCHECK_URL=$(get_config "healthcheck_url" "")
CRON_SCHEDULE=$(get_config "cron_schedule" "0 12 * * *")

if [ -z "$BACKUP_PASSWORD" ] || [ "$BACKUP_PASSWORD" == "CHANGE_ME" ]; then
    error "Please set a valid backup_password in $CONFIG_FILE"
fi

# Install Restic
if ! command -v restic &> /dev/null;
    then
    log "Installing restic v$RESTIC_VERSION..."
    URL="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2"
    curl -L -o /tmp/restic.bz2 "$URL"
    bunzip2 /tmp/restic.bz2
    chmod +x /tmp/restic
    log "Sudo access required to move restic to /usr/local/bin"
    sudo mv /tmp/restic /usr/local/bin/restic
    sudo chown root:root /usr/local/bin/restic
else
    log "Restic already installed."
fi

# Setup Directories
log "Setting up directories..."
RESTIC_DIR="$HOME/.restic"
BIN_DIR="$HOME/bin"
mkdir -p "$RESTIC_DIR" "$BIN_DIR"

# Password File
echo -n "$BACKUP_PASSWORD" > "$RESTIC_DIR/.restic_passwd"
chmod 600 "$RESTIC_DIR/.restic_passwd"

# Exclude File
get_exclude_paths > "$RESTIC_DIR/.restic_exclude"

# .bashrc
if ! grep -q "\$HOME/bin" "$HOME/.bashrc"; then
    log "Adding ~/bin to PATH in .bashrc"
    echo 'export PATH=$PATH:$HOME/bin' >> "$HOME/.bashrc"
fi

# Generate Backup Script
BACKUP_SCRIPT="$BIN_DIR/restic-custom-backup"
log "Generating backup script at $BACKUP_SCRIPT..."

cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

# Configuration
RESTIC_PASSWD="$RESTIC_DIR/.restic_passwd"
RESTIC_EXCLUDE_FILE="$RESTIC_DIR/.restic_exclude"
BACKUP_REPO="$REPO"
KEEP_OPTIONS="--keep-hourly 2 --keep-daily 6 --keep-weekly 3 --keep-monthly 1"
HOST_TAG="
$(hostname)"
HEALTHCHECK_URL="$HEALTHCHECK_URL"

FAILURE=0
LOGFILE="/tmp/restic-backup.log"

exec >> "
$LOGFILE" 2>&1

echo "=== Backup started: 
$(date) on $HOST_TAG ==="
if [ -n "
$HEALTHCHECK_URL" ]; then
    curl -fsS --retry 3 "
$HEALTHCHECK_URL/start" >/dev/null 2>&1 || true
fi

# Initialize repository if it doesn't exist
if ! /usr/local/bin/restic -p "
$RESTIC_PASSWD" -r "
$BACKUP_REPO" cat config >/dev/null 2>&1; then
    echo "Initializing restic repository at $BACKUP_REPO"
    /usr/local/bin/restic -p "
$RESTIC_PASSWD" -r "
$BACKUP_REPO" init
fi

# Unlock stale locks
/usr/local/bin/restic -p "
$RESTIC_PASSWD" -r "
$BACKUP_REPO" unlock || true

EOF

# Loop for sources
SOURCES=$(get_source_keys)
for SERVICE in $SOURCES; do
    PATH_VAL=$(get_source_path "$SERVICE")
    cat >> "$BACKUP_SCRIPT" <<EOF
echo "Backing up $SERVICE: $PATH_VAL"
/usr/local/bin/restic -p "
$RESTIC_PASSWD" -r "
$BACKUP_REPO" \
    --host "
$HOST_TAG" \
    --tag "$SERVICE" \
    --exclude-caches \
    --exclude-file="
$RESTIC_EXCLUDE_FILE" \
    backup "$PATH_VAL"

echo "$SERVICE backup complete: 
$(/usr/local/bin/restic -p "
$RESTIC_PASSWD" -r "
$BACKUP_REPO" stats --host "
$HOST_TAG" --tag "$SERVICE")"

EOF
done

# Loop for forget
for SERVICE in $SOURCES; do
    cat >> "$BACKUP_SCRIPT" <<EOF
/usr/local/bin/restic -p "
$RESTIC_PASSWD" -r "
$BACKUP_REPO" \
    forget \
    --host "
$HOST_TAG" \
    --tag "$SERVICE" \
    --group-by host,tags \
    $KEEP_OPTIONS \
    --cleanup-cache || true

EOF
done

# Footer
cat >> "$BACKUP_SCRIPT" <<EOF
# Ping healthcheck
if [ $? -eq 0 ]; then
    if [ -n "
$HEALTHCHECK_URL" ]; then
        curl -fsS --retry 3 "
$HEALTHCHECK_URL" >/dev/null 2>&1 || true
    fi
else
    FAILURE=1
fi

echo "=== Backup finished: 
$(date) ==="
exit $FAILURE
EOF

chmod +x "$BACKUP_SCRIPT"

# Setup Cron
log "Setting up cron..."
if ! crontab -l 2>/dev/null | grep -q "$BACKUP_SCRIPT"; then
    (crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $BACKUP_SCRIPT") | crontab -
    log "Cron job added."
else
    log "Cron job already exists."
fi

log "Setup complete!"
