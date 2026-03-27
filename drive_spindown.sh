#!/bin/bash
# =============================================================================
# drive_spindown.sh - Monitor and spin down idle drives on TrueNAS Scale
# =============================================================================
# Checks drive state without waking sleeping drives, logs spin up/down events,
# and keeps a 24-hour running total per drive.
#
# Usage:    bash drive_spindown.sh
# Cron:     */15 * * * * /path/to/drive_spindown.sh
# VIBECODED BUT TESTED
# =============================================================================

# --- Configuration -----------------------------------------------------------

# Drives to monitor (edit this list to match your system)
DRIVES=(sda sdb sdc sdd sde sdf)

# Where to write the log file
LOG_FILE="/var/log/drive_spindown.log"

# How long a drive must be idle before spinning it down (seconds)
# hdparm -S value: 120 = 10 minutes, 240 = 20 minutes, etc.
# We spin down immediately here since the cron interval is your throttle.
SPINDOWN_TIMEOUT=1   # hdparm standby value (1 = ~5 seconds, used for immediate)

# How many days to keep log entries (old entries pruned on each run)
LOG_RETENTION_DAYS=7

# --- Helpers -----------------------------------------------------------------

LOG_DATE=$(date '+%Y-%m-%d %H:%M:%S')
YESTERDAY=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S')

log() {
    echo "$LOG_DATE | $1" | tee -a "$LOG_FILE"
}

# Get drive state without spinning it up.
# hdparm -C returns:  "drive state is:  standby"  or  "active/idle"
get_drive_state() {
    local drive="/dev/$1"
    local output
    output=$(hdparm -C "$drive" 2>&1)

    if echo "$output" | grep -qi "standby\|sleeping"; then
        echo "standby"
    elif echo "$output" | grep -qi "active\|idle"; then
        echo "active"
    else
        echo "unknown"
    fi
}

# Spin the drive down using hdparm -y (immediate standby)
spin_down_drive() {
    local drive="/dev/$1"
    hdparm -y "$drive" > /dev/null 2>&1
    log "SPINDOWN | /dev/$1 | Drive sent to standby"
}

# Count events for a drive in the last 24 hours from the log
count_events_24h() {
    local drive="$1"
    local event_type="$2"   # SPINUP or SPINDOWN

    if [[ ! -f "$LOG_FILE" ]]; then
        echo 0
        return
    fi

    # Count lines matching drive + event type that are newer than 24h ago
    awk -v cutoff="$YESTERDAY" -v drv="$drive" -v evt="$event_type" '
        $1" "$2 >= cutoff && $3 == "|" && $4 == evt && $6 == "/dev/"drv
        { count++ }
        END { print count+0 }
    ' "$LOG_FILE"
}

# Prune log entries older than LOG_RETENTION_DAYS
prune_old_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then return; fi
    local cutoff
    cutoff=$(date -d "${LOG_RETENTION_DAYS} days ago" '+%Y-%m-%d %H:%M:%S')
    local tmp
    tmp=$(mktemp)
    awk -v cutoff="$cutoff" '$1" "$2 >= cutoff' "$LOG_FILE" > "$tmp"
    mv "$tmp" "$LOG_FILE"
}

# --- State tracking ----------------------------------------------------------
# We track the previous state of each drive in a small state file so we can
# detect a drive that has spun UP since the last check (meaning something woke
# it). We log a SPINUP event only on that transition.

STATE_FILE="/var/run/drive_spindown_state"

load_previous_state() {
    declare -gA PREV_STATE
    if [[ -f "$STATE_FILE" ]]; then
        while IFS='=' read -r key val; do
            PREV_STATE["$key"]="$val"
        done < "$STATE_FILE"
    fi
}

save_current_state() {
    : > "$STATE_FILE"
    for drive in "${DRIVES[@]}"; do
        echo "${drive}=${CURRENT_STATE[$drive]}" >> "$STATE_FILE"
    done
}

# --- Main loop ---------------------------------------------------------------

prune_old_logs
load_previous_state

declare -A CURRENT_STATE

log "--------- CHECK START ---------"

for drive in "${DRIVES[@]}"; do
    if [[ ! -b "/dev/$drive" ]]; then
        log "SKIP     | /dev/$drive | Device not found"
        CURRENT_STATE[$drive]="missing"
        continue
    fi

    state=$(get_drive_state "$drive")
    CURRENT_STATE[$drive]="$state"
    prev="${PREV_STATE[$drive]:-unknown}"

    case "$state" in
        active)
            # Was it previously asleep? Then something woke it — log SPINUP.
            if [[ "$prev" == "standby" || "$prev" == "unknown" ]]; then
                log "SPINUP   | /dev/$drive | Drive is active (was: $prev)"
            else
                log "ACTIVE   | /dev/$drive | Drive already active (was: $prev)"
            fi

            # Spin it down
            spin_down_drive "$drive"
            CURRENT_STATE[$drive]="standby"

            # Print 24h totals
            spinups=$(count_events_24h "$drive" "SPINUP")
            spindowns=$(count_events_24h "$drive" "SPINDOWN")
            log "TOTAL24H | /dev/$drive | Spin-ups: $spinups | Spin-downs: $spindowns"
            ;;

        standby)
            log "STANDBY  | /dev/$drive | Drive already sleeping — no action"
            ;;

        unknown)
            log "UNKNOWN  | /dev/$drive | Could not determine state"
            ;;
    esac
done

save_current_state
log "--------- CHECK END -----------"
echo "" >> "$LOG_FILE"
