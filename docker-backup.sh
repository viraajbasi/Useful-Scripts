#!/bin/bash

# Configuration
SOURCE_DIR="/media/nvme/docker"
BACKUP_DIR="/media/nvme/backups"
BACKUP_TAR="$BACKUP_DIR/backup-$(date +%Y%m%d).tar"
BACKUP_FILE="$BACKUP_DIR/backup-$(date +%Y%m%d).7z"
PASSWORD_FILE="/root/.backup-password"
LOG_FILE="/var/log/docker-backup.log"
RETENTION_DAYS=7
COMPOSE_FILE="/media/nvme/docker/docker-compose.yml"
REQUIRED_BINARIES=("docker" "tar" "7z" "find" "du" "grep" "tee" "cat" "mv" "chmod" "diff")
SYNCTHING_USER="viraaj"
SYNCTHING_GROUP="viraaj"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

for bin in "${REQUIRED_BINARIES[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        log "ERROR: Required binary '$bin' is not installed or not in PATH"
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    log "ERROR: 'docker compose' is not available. Ensure you're using Docker v2+"
    exit 1
fi

if [ ! -f "$PASSWORD_FILE" ]; then
    log "ERROR: Password file not found at $PASSWORD_FILE"
    echo "Create it with: sudo bash -c 'echo \"your-password\" > $PASSWORD_FILE' && sudo chmod 600 $PASSWORD_FILE"
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    log "ERROR: Docker compose file not found at $COMPOSE_FILE"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    log "ERROR: Source directory $SOURCE_DIR does not exist"
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
	log "ERROR: Backup directory $BACKUP_DIR does not exist"
	exit 1
fi

BACKUP_PASSWORD=$(cat "$PASSWORD_FILE")
log "Starting backup"
cd "$(dirname "$COMPOSE_FILE")"

log "Saving current container states"
docker compose ps > /tmp/docker-states-before-backup.txt

log "Stopping all Docker containers via compose"
docker compose down

log "Creating tar archive"
if tar -cf "$BACKUP_TAR" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"; then
    log "Tar archive created: $BACKUP_TAR"
else
    log "ERROR: Failed to create tar archive"
    docker compose up -d
    exit 1
fi

log "Creating password-protected 7z archive"
if 7z a -p"$BACKUP_PASSWORD" -mhe=on "$BACKUP_FILE" "$BACKUP_TAR" >/dev/null; then
    log "7z archive created successfully: $BACKUP_FILE"
    log "Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"
    chown "$SYNCTHING_USER:$SYNCTHING_GROUP" "$BACKUP_FILE"
    chmod 640 "$BACKUP_FILE"
    rm -f "$BACKUP_TAR"
else
    log "ERROR: Failed to create 7z archive"
    rm -f "$BACKUP_TAR" "$BACKUP_FILE"
    docker compose up -d
    exit 1
fi

log "Verifying backup contents against source directory"
TMP_VERIFY_DIR=$(mktemp -d)
TMP_EXTRACT_DIR=$(mktemp -d)
if 7z x -p"$BACKUP_PASSWORD" -o"$TMP_VERIFY_DIR" "$BACKUP_FILE" >/dev/null 2>&1; then
    TAR_FILE="$TMP_VERIFY_DIR/$(basename "$BACKUP_TAR")"
    if tar -xf "$TAR_FILE" -C "$TMP_EXTRACT_DIR"; then
        if diff_output=$(diff -r "$SOURCE_DIR" "$TMP_EXTRACT_DIR/$(basename "$SOURCE_DIR")"); then
            log "Backup contents match source directory"
        else
            log "WARNING: Backup contents differ from source directory. Differences:"
            echo "$diff_output" | tee -a "$LOG_FILE"
        fi
    else
        log "WARNING: Failed to extract tar archive for content verification"
    fi
else
    log "WARNING: Failed to extract 7z archive for content verification"
fi
rm -rf "$TMP_VERIFY_DIR" "$TMP_EXTRACT_DIR"


log "Restarting all Docker containers via compose"
docker compose up -d

log "Checking if syncthing container is running"
if docker compose ps | grep -q syncthing && docker compose ps syncthing | grep -q "Up"; then
    log "Syncthing container is running - backups will be synced"
else
    log "WARNING: Syncthing container may not be running properly"
    docker compose ps | grep syncthing || log "No syncthing service found in compose file"
fi

log "Cleaning up backups older than $RETENTION_DAYS days"
DELETED=$(find "$BACKUP_DIR" -name "backup-*.7z" -mtime +$RETENTION_DAYS -delete -print | wc -l)
REMAINING=$(find "$BACKUP_DIR" -name "backup-*.7z" | wc -l)
log "Deleted $DELETED old backups, $REMAINING remaining"

log "Final container status:"
docker compose ps | tee -a "$LOG_FILE"

log "Docker backup completed successfully"
