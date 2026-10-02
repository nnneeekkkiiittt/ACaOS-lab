#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Lab 1 — automated tests for cleanup.sh
#
# Requirements:
#   - no sudo/root
#   - creates a 1 GiB filesystem image automatically
#   - mounts it through FUSE
#   - runs exactly 4 test cases
#   - every test uses a filesystem of at least 0.5 GiB
#
# Expected dependencies (Linux):
#   fuse2fs
#   fusermount3 or fusermount
#   mkfs.ext4
#
# Usage:
#   ./test.sh [path/to/cleanup.sh]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="${1:-$SCRIPT_DIR/cleanup.sh}"

IMAGE_SIZE_MIB=1024
IMAGE_SIZE_BYTES=$((IMAGE_SIZE_MIB * 1024 * 1024))

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lab1-tests.XXXXXX")"
IMAGE="$WORK_DIR/disk.img"
LOG_DIR="$WORK_DIR/log"
BACKUP_DIR="$WORK_DIR/backup"

MOUNTED=0
PASSED=0
FAILED=0
CURRENT_TEST=0

# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------

info() {
    printf '%s\n' "$*"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

pass_test() {
    PASSED=$((PASSED + 1))
    printf 'PASS\n\n'
}

fail_test() {
    FAILED=$((FAILED + 1))
    printf 'FAIL\n\n'
}

# ------------------------------------------------------------
# Dependency checks
# ------------------------------------------------------------

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "required command not found: $1"
    fi
}

if (( EUID == 0 )); then
    fail "run tests as a regular user, not root"
fi

if [[ ! -f "$CLEANUP_SCRIPT" ]]; then
    fail "cleanup script not found: $CLEANUP_SCRIPT"
fi

if [[ ! -x "$CLEANUP_SCRIPT" ]]; then
    fail "cleanup script is not executable: $CLEANUP_SCRIPT"
fi

require_command fuse2fs
require_command df
require_command tar
require_command mkfs.ext4
require_command truncate
require_command stat
require_command mountpoint
require_command find
require_command sort
require_command awk

if command -v fusermount3 >/dev/null 2>&1; then
    UNMOUNT_COMMAND="fusermount3"
elif command -v fusermount >/dev/null 2>&1; then
    UNMOUNT_COMMAND="fusermount"
else
    fail "required command not found: fusermount3 or fusermount"
fi

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

unmount_log() {
    if (( MOUNTED == 1 )); then
        "$UNMOUNT_COMMAND" -u "$LOG_DIR" >/dev/null 2>&1 || true
        MOUNTED=0
    fi
}

cleanup() {
    unmount_log
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT INT TERM

# ------------------------------------------------------------
# Filesystem setup
# ------------------------------------------------------------

create_filesystem() {
    rm -rf "$LOG_DIR" "$BACKUP_DIR"
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"

    # A sparse image is enough: mkfs/ext4 and FUSE will materialize
    # blocks as they are actually written.
    truncate -s "${IMAGE_SIZE_BYTES}" "$IMAGE"

    # -m 0 avoids reserving part of the filesystem for root.
    mkfs.ext4 -q -F -m 0 "$IMAGE"

    fuse2fs -o rw+ "$IMAGE" "$LOG_DIR" >/dev/null 2>&1 &

    # Give FUSE a moment to establish the mount.
    for _ in {1..50}; do
        if mountpoint -q "$LOG_DIR" 2>/dev/null; then
            MOUNTED=1
            return 0
        fi
        sleep 0.1
    done

    # mountpoint may not know about FUSE on some systems.
    if df -P "$LOG_DIR" >/dev/null 2>&1; then
        MOUNTED=1
        return 0
    fi

    return 1
}

reset_test_environment() {
    unmount_log

    # Recreate image and mount point for complete isolation.
    rm -f "$IMAGE"
    rm -rf "$LOG_DIR" "$BACKUP_DIR"

    create_filesystem || fail "could not create or mount test filesystem"
}

# ------------------------------------------------------------
# Test data helpers
# ------------------------------------------------------------

write_file() {
    local path="$1"
    local size_mib="$2"

    dd if=/dev/zero \
        of="$path" \
        bs=1M \
        count="$size_mib" \
        status=none
}

create_ordered_files() {
    local total_mib="$1"
    local file_mib=100
    local count=$((total_mib / file_mib))

    (( count > 0 )) || return 0

    for ((i=1; i<=count; i++)); do
        local name
        name=$(printf 'log_%02d.dat' "$i")

        write_file "$LOG_DIR/$name" "$file_mib"

        # Older files have smaller timestamps.
        touch -d "$((count - i + 1)) days ago" "$LOG_DIR/$name"
    done
}

used_percent() {
    df -Pk "$LOG_DIR" |
        awk 'NR == 2 { print int(($3 * 100) / $2) }'
}

archive_count() {
    find "$BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        \( -name '*.tar.gz' -o -name '*.tar.lzma' \) \
        | wc -l
}

log_file_count() {
    find "$LOG_DIR" -type f | wc -l
}

run_cleanup() {
    local threshold="$1"
    shift

    env "$@" "$CLEANUP_SCRIPT" "$LOG_DIR" "$threshold" "$BACKUP_DIR"
}

# ------------------------------------------------------------
# Test 1: 0% occupied filesystem
# ------------------------------------------------------------

test_zero_usage() {
    CURRENT_TEST=$((CURRENT_TEST + 1))
    printf 'Test %d: empty log filesystem\n' "$CURRENT_TEST"

    reset_test_environment

    local before
    before=$(used_percent)

    if (( before > 5 )); then
        fail "empty filesystem unexpectedly uses ${before}%"
    fi

    run_cleanup 70 >/dev/null

    local archives
    archives=$(archive_count)

    if (( archives != 0 )); then
        fail "archive was created for an empty log"
    fi

    info "  Initial usage: ${before}%"
    info "  Expected: no archive"
    info "  Result: no archive"
}

# ------------------------------------------------------------
# Test 2: usage exceeds threshold
# ------------------------------------------------------------

test_over_threshold() {
    CURRENT_TEST=$((CURRENT_TEST + 1))
    printf 'Test %d: usage exceeds threshold\n' "$CURRENT_TEST"

    reset_test_environment
    create_ordered_files 600

    local before
    before=$(used_percent)

    if (( before <= 50 )); then
        fail "test data did not exceed 50% (actual: ${before}%)"
    fi

    run_cleanup 50 >/dev/null

    local after
    after=$(used_percent)

    local archives
    archives=$(archive_count)

    if (( archives < 1 )); then
        fail "no archive was created"
    fi

    if (( after > 50 )); then
        fail "filesystem is still above threshold: ${after}%"
    fi

    # The oldest file must be among the archived/deleted files.
    if [[ -e "$LOG_DIR/log_01.dat" ]]; then
        fail "oldest file was not removed"
    fi

    info "  Initial usage: ${before}%"
    info "  Threshold: 50%"
    info "  Final usage: ${after}%"
    info "  Archives: ${archives}"
}

# ------------------------------------------------------------
# Test 3: random input below threshold
# ------------------------------------------------------------

test_random_below() {
    CURRENT_TEST=$((CURRENT_TEST + 1))
    printf 'Test %d: random amount below threshold\n' "$CURRENT_TEST"

    reset_test_environment

    local random_mib
    random_mib=$((520 + RANDOM % 81))

    # Random value: 520..600 MiB.
    # 80% threshold guarantees no cleanup is required.
    create_ordered_files "$random_mib"

    local before
    before=$(used_percent)

    if (( before >= 80 )); then
        fail "random test unexpectedly reached ${before}%"
    fi

    run_cleanup 80 >/dev/null

    local archives
    archives=$(archive_count)

    if (( archives != 0 )); then
        fail "archive was created although usage was below threshold"
    fi

    info "  Random size: ${random_mib} MiB"
    info "  Initial usage: ${before}%"
    info "  Threshold: 80%"
    info "  Expected: no archive"
}

# ------------------------------------------------------------
# Test 4: random input above threshold
# ------------------------------------------------------------

test_random_above() {
    CURRENT_TEST=$((CURRENT_TEST + 1))
    printf 'Test %d: random amount above threshold\n' "$CURRENT_TEST"

    reset_test_environment

    local random_mib
    random_mib=$((700 + RANDOM % 121))

    # Random value: 700..820 MiB.
    # 50% threshold guarantees cleanup is required.
    create_ordered_files "$random_mib"

    local before
    before=$(used_percent)

    if (( before <= 50 )); then
        fail "random test did not exceed 50% (actual: ${before}%)"
    fi

    run_cleanup 50 >/dev/null

    local after
    after=$(used_percent)

    local archives
    archives=$(archive_count)

    if (( archives < 1 )); then
        fail "no archive was created"
    fi

    if (( after > 50 )); then
        fail "filesystem is still above threshold: ${after}%"
    fi

    info "  Random size: ${random_mib} MiB"
    info "  Initial usage: ${before}%"
    info "  Final usage: ${after}%"
    info "  Threshold: 50%"
    info "  Archives: ${archives}"
}

# ------------------------------------------------------------
# Run tests
# ------------------------------------------------------------

printf 'Lab 1 automated tests\n'
printf 'Cleanup script: %s\n\n' "$CLEANUP_SCRIPT"

for test in \
    test_zero_usage \
    test_over_threshold \
    test_random_below \
    test_random_above

do
    if "$test"; then
        pass_test
    else
        fail_test
    fi

done

printf 'Summary: %d passed, %d failed\n' "$PASSED" "$FAILED"

if (( FAILED > 0 )); then
    exit 1
fi

exit 0
