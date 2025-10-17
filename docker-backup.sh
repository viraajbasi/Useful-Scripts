#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Configuration
SOURCE_DIR="/media/nvme/docker"
BACKUP_DIR="/media/nvme/backups"
BACKUP_TAR="$BACKUP_DIR/backup-$(date +%Y%m%d).tar"
BACKUP_FILE="$BACKUP_DIR/backup-$(date +%Y%m%d).7z"
PASSWORD_FILE="/root/.backup-password"
LOG_FILE="/var/log/docker-backup.log"
RETENTION_DAYS=7
COMPOSE_FILE="$SOURCE_DIR/docker-compose.yml"
REQUIRED_BINARIES=("docker" "tar" "7z" "find" "du" "grep" "tee" "cat" "mv" "chmod" "diff" "msmtp")
SYNCTHING_USER="viraaj"
SYNCTHING_GROUP="viraaj"
MSMTP_CONFIG="/root/.msmtprc"
EMAIL_FILE="/root/.backup-email"
EXCLUDE_FILE="/root/.backup-exclude"

# Read credentials
read -r EMAIL_TO < "$EMAIL_FILE"
read -r BACKUP_PASSWORD < "$PASSWORD_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

send_error_email() {
    local error_message="$1"
    local log_tail
    log_tail=$(tail -20 "$LOG_FILE")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if ! (
        cat << EOF | msmtp --file="$MSMTP_CONFIG" "$EMAIL_TO"
To: $EMAIL_TO
Subject: [BACKUP FAILED] Docker Backup Error on $HOSTNAME - $timestamp
Date: $(date -R)
Message-ID: <backup-error-$(date +%s)-$$@$HOSTNAME>
Content-Type: text/plain; charset=UTF-8
X-Priority: 1
X-MSMail-Priority: High
Importance: high

⚠️  DOCKER BACKUP FAILURE ALERT ⚠️

Server: $HOSTNAME
Time: $timestamp
Status: FAILED

Error Details:
$error_message

Recent Log Entries:
----------------------------------------
$log_tail
----------------------------------------

Action Required:
Please check the server and resolve the backup issue immediately.

Full log file: $LOG_FILE

This is an automated message from the Docker backup script.
EOF
    ); then
        log "WARNING: Failed to send error notification email"
    else
        log "Error notification email sent successfully"
    fi
}

handle_error() {
    local error_msg="$1"
    log "ERROR: $error_msg"
    send_error_email "$error_msg"
    exit 1
}

# Ensure required binaries are installed
for bin in "${REQUIRED_BINARIES[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        handle_error "Required binary '$bin' is not installed or not in PATH"
    fi
done

# Docker Compose check
if ! docker compose version >/dev/null 2>&1; then
    handle_error "'docker compose' is not available. Ensure you're using Docker v2+"
fi

# Validate files/directories
[ -f "$PASSWORD_FILE" ] || handle_error "Password file not found at $PASSWORD_FILE"
[ -f "$COMPOSE_FILE" ] || handle_error "Docker compose file not found at $COMPOSE_FILE"
[ -d "$SOURCE_DIR" ] || handle_error "Source directory $SOURCE_DIR does not exist"
[ -d "$BACKUP_DIR" ] || handle_error "Backup directory $BACKUP_DIR does not exist"
[ -f "$MSMTP_CONFIG" ] || handle_error "msmtp config not found at $MSMTP_CONFIG"

log "Starting backup"
cd "$(dirname "$COMPOSE_FILE")"

log "Saving current container states"
docker compose ps > /tmp/docker-states-before-backup.txt

ALL_SERVICES="$(docker compose ps --services)"

EXCLUDE_SERVICES=()
if [ -f "$EXCLUDE_FILE" ]; then
    log "Reading container exclusion list from $EXCLUDE_FILE"
    mapfile -t EXCLUDE_SERVICES < <(grep -v '^#' "$EXCLUDE_FILE" | grep -v '^[[:space:]]*$')
    log "Containers to keep running: ${EXCLUDE_SERVICES[*]}"
else
    log "No exclusion file found at $EXCLUDE_FILE - all containers will be stopped"
fi

STOP_SERVICES=()
for service in $ALL_SERVICES; do
    if printf '%s\n' "${EXCLUDE_SERVICES[@]}" | grep -qx "$service"; then
        log "Excluding $service from shutdown"
    else
        STOP_SERVICES+=("$service")
    fi
done

if [ "${#STOP_SERVICES[@]}" -gt 0 ]; then
    log "Stopping containers: ${STOP_SERVICES[*]}"
    docker compose stop "${STOP_SERVICES[@]}" || handle_error "Failed to stop Docker containers"
else
    log "No containers to stop - all are excluded"
fi

log "Creating tar archive of source directory"
if tar -cf "$BACKUP_TAR" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"; then
    log "Tar archive created: $BACKUP_TAR"
else
    docker compose -f $COMPOSE_FILE up -d
    handle_error "Failed to create tar archive"
fi

log "Creating password-protected 7z archive"
if 7z a -p"$BACKUP_PASSWORD" -mhe=on "$BACKUP_FILE" "$BACKUP_TAR" >/dev/null; then
    log "7z archive created successfully: $BACKUP_FILE"
    BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | awk '{print $1}')
    log "Backup size: $BACKUP_SIZE"
    chown "$SYNCTHING_USER:$SYNCTHING_GROUP" "$BACKUP_FILE"
    chmod 640 "$BACKUP_FILE"
    rm -f "$BACKUP_TAR"
else
    rm -f "$BACKUP_TAR" "$BACKUP_FILE"
    docker compose -f $COMPOSE_FILE up -d
    handle_error "Failed to create 7z archive"
fi

log "Verifying backup contents against source directory"
TMP_VERIFY_DIR=$(mktemp -d -t docker-backup-XXXX)

if 7z x -p"$BACKUP_PASSWORD" -o"$TMP_VERIFY_DIR" "$BACKUP_FILE" >/dev/null 2>&1; then
    TAR_FILE="$TMP_VERIFY_DIR/$(basename "$BACKUP_TAR")"
    if [ -f "$TAR_FILE" ]; then
        if tar -C "$(dirname "$SOURCE_DIR")" -df "$TAR_FILE" "$(basename "$SOURCE_DIR")" >/dev/null 2>&1; then
            log "Backup contents match source directory (tar --compare)"
        else
            log "WARNING: Backup contents differ from source directory (tar --compare):"
            tar -C "$(dirname "$SOURCE_DIR")" -df "$TAR_FILE" "$(basename "$SOURCE_DIR")" | tee -a "$LOG_FILE"
        fi
    else
        log "WARNING: Expected tar file not found inside 7z archive: $TAR_FILE"
    fi
else
    log "WARNING: Failed to extract 7z archive for content verification"
fi

rm -rf "$TMP_VERIFY_DIR"

log "Restarting all Docker containers"
docker compose -f $COMPOSE_FILE up -d || handle_error "Failed to restart Docker containers"

if [ "$(docker ps --filter "name=^syncthing$" --filter "status=running" -q)" ]; then
    log "Syncthing container is running - backups will be synced"
else
    log "WARNING: Syncthing container may not be running properly"
fi

log "Cleaning up backups older than $RETENTION_DAYS days"
DELETED=$(find "$BACKUP_DIR" -name "backup-*.7z" -mtime +$RETENTION_DAYS -delete -print | wc -l)
REMAINING=$(find "$BACKUP_DIR" -name "backup-*.7z" | wc -l)
log "Deleted $DELETED old backups, $REMAINING remaining"

log "Final container status:"
docker compose ps | tee -a "$LOG_FILE"

log "Docker backup completed successfully"
