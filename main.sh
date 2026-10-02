#!/usr/bin/env bash

set -euo pipefail

# Usage:
#   ./cleanup.sh <log_dir> <threshold_percent> <backup_dir>
#
# Example:
#   ./cleanup.sh ./log 70 ./backup
#
# Compression:
#   default                     -> tar.gz
#   LAB1_MAX_COMPRESSION=1     -> tar.lzma

usage() {
    echo "Usage: $0 <log_dir> <threshold_percent> <backup_dir>"
    exit 1
}

error() {
    echo "Error: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

[[ $# -eq 3 ]] || usage

LOG_DIR="$1"
THRESHOLD="$2"
BACKUP_DIR="$3"

[[ -d "$LOG_DIR" ]] || error "log directory does not exist: $LOG_DIR"

[[ "$THRESHOLD" =~ ^[0-9]+$ ]] ||
    error "threshold must be an integer from 0 to 100"

(( THRESHOLD >= 0 && THRESHOLD <= 100 )) ||
    error "threshold must be between 0 and 100"

mkdir -p "$BACKUP_DIR"

# ------------------------------------------------------------
# Compression mode
# ------------------------------------------------------------

if [[ "${LAB1_MAX_COMPRESSION:-0}" == "1" ]]; then
    COMPRESSION="lzma"
    ARCHIVE_SUFFIX="tar.lzma"
    TAR_COMPRESSION_OPTION="--lzma"
else
    COMPRESSION="gzip"
    ARCHIVE_SUFFIX="tar.gz"
    TAR_COMPRESSION_OPTION="--gzip"
fi

# ------------------------------------------------------------
# Read filesystem usage
# ------------------------------------------------------------

read -r TOTAL_KB USED_KB AVAILABLE_KB < <(
    df -Pk "$LOG_DIR" | awk 'NR == 2 {
        print $2, $3, $4
    }'
)

[[ -n "$TOTAL_KB" ]] ||
    error "failed to determine filesystem size"

# Use tenths of a percent to avoid floating-point arithmetic.
USED_PERCENT_10=$(( USED_KB * 1000 / TOTAL_KB ))

USED_PERCENT_INT=$(( USED_PERCENT_10 / 10 ))
USED_PERCENT_DEC=$(( USED_PERCENT_10 % 10 ))

echo "Directory : $LOG_DIR"
echo "Backup    : $BACKUP_DIR"
echo "Usage     : ${USED_PERCENT_INT}.${USED_PERCENT_DEC}%"
echo "Threshold : ${THRESHOLD}%"
echo "Mode      : $COMPRESSION"

# ------------------------------------------------------------
# Check threshold
# ------------------------------------------------------------

if (( USED_PERCENT_10 <= THRESHOLD * 10 )); then
    echo "Nothing to archive."
    exit 0
fi

echo "Threshold exceeded. Selecting oldest files..."

# Amount of free space required to reach the threshold.
TARGET_USED_KB=$(( TOTAL_KB * THRESHOLD / 100 ))
NEEDED_FREE_KB=$(( USED_KB - TARGET_USED_KB ))

# ------------------------------------------------------------
# Temporary files
# ------------------------------------------------------------

TMP_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

FILE_LIST="$TMP_DIR/files"
SELECTED_LIST="$TMP_DIR/selected"

touch "$SELECTED_LIST"

# ------------------------------------------------------------
# Find all regular files and sort by modification time.
#
# %T@ = modification time as Unix timestamp
# %p  = path
#
# NUL separators allow filenames containing spaces to work.
# ------------------------------------------------------------

find "$LOG_DIR" \
    -type f \
    -printf '%T@ %p\0' |
    sort -z -n > "$FILE_LIST"

# ------------------------------------------------------------
# Select the oldest files until enough data is collected
# to bring the filesystem below the threshold.
# ------------------------------------------------------------

SELECTED_SIZE_KB=0
SELECTED_COUNT=0

while IFS= read -r -d '' ENTRY; do

    FILE_PATH="${ENTRY#* }"

    [[ -f "$FILE_PATH" ]] || continue

    read -r BLOCKS BLOCK_SIZE < <(
        stat -c '%b %B' -- "$FILE_PATH"
    )

    # Convert allocated blocks to KiB.
    FILE_SIZE_KB=$(
        awk -v blocks="$BLOCKS" -v block_size="$BLOCK_SIZE" '
            BEGIN {
                bytes = blocks * block_size
                print int((bytes + 1023) / 1024)
            }
        '
    )

    RELATIVE_PATH="${FILE_PATH#"$LOG_DIR"/}"

    printf '%s\0' "$RELATIVE_PATH" >> "$SELECTED_LIST"

    SELECTED_SIZE_KB=$(( SELECTED_SIZE_KB + FILE_SIZE_KB ))
    SELECTED_COUNT=$(( SELECTED_COUNT + 1 ))

    if (( SELECTED_SIZE_KB >= NEEDED_FREE_KB )); then
        break
    fi

done < "$FILE_LIST"

if (( SELECTED_COUNT == 0 )); then
    error "no files available for archiving"
fi

if (( SELECTED_SIZE_KB < NEEDED_FREE_KB )); then
    error "not enough files to reach the threshold"
fi

echo "Selected  : $SELECTED_COUNT file(s)"
echo "Data      : ${SELECTED_SIZE_KB} KiB"

# ------------------------------------------------------------
# Create archive
# ------------------------------------------------------------

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

ARCHIVE_PATH="$BACKUP_DIR/log_backup_${TIMESTAMP}.${ARCHIVE_SUFFIX}"
TEMP_ARCHIVE="$TMP_DIR/archive.${ARCHIVE_SUFFIX}"

echo "Creating  : $ARCHIVE_PATH"

tar \
    --create \
    "$TAR_COMPRESSION_OPTION" \
    --file="$TEMP_ARCHIVE" \
    --directory="$LOG_DIR" \
    --null \
    --verbatim-files-from \
    --files-from="$SELECTED_LIST"

# ------------------------------------------------------------
# Verify that the archive can be read.
# ------------------------------------------------------------

tar --list --file="$TEMP_ARCHIVE" >/dev/null

mv "$TEMP_ARCHIVE" "$ARCHIVE_PATH"

echo "Archive created successfully."

# ------------------------------------------------------------
# Delete only files that were successfully archived.
# ------------------------------------------------------------

echo "Removing archived files..."

while IFS= read -r -d '' RELATIVE_PATH; do

    FILE_PATH="$LOG_DIR/$RELATIVE_PATH"

    if [[ -f "$FILE_PATH" ]]; then
        rm -- "$FILE_PATH"
    fi

done < "$SELECTED_LIST"

# ------------------------------------------------------------
# Final usage
# ------------------------------------------------------------

read -r TOTAL_KB_AFTER USED_KB_AFTER AVAILABLE_KB_AFTER < <(
    df -Pk "$LOG_DIR" | awk 'NR == 2 {
        print $2, $3, $4
    }'
)

USED_PERCENT_10_AFTER=$(
    awk -v used="$USED_KB_AFTER" -v total="$TOTAL_KB_AFTER" '
        BEGIN {
            print int(used * 1000 / total)
        }
    '
)

USED_PERCENT_INT_AFTER=$(( USED_PERCENT_10_AFTER / 10 ))
USED_PERCENT_DEC_AFTER=$(( USED_PERCENT_10_AFTER % 10 ))

echo "Usage now  : ${USED_PERCENT_INT_AFTER}.${USED_PERCENT_DEC_AFTER}%"
echo "Done."