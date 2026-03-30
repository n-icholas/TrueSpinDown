#!/bin/bash
# =============================================================================
# drive_spindown.sh - Monitor and spin down idle drives on TrueNAS Scale
# =============================================================================
# Normal run:        bash drive_spindown.sh
# Daily summary:     bash drive_spindown.sh --daily-summary
#
# Cron (every 15min): */15 * * * * bash /path/to/drive_spindown.sh
# Cron (daily total): 30 23 * * *  bash /path/to/drive_spindown.sh --daily-summary
# =============================================================================

# --- Configuration -----------------------------------------------------------

DRIVES=(sda sdb sdc)
LOG_FILE="/root/drive_spindown/drive_spindown.log"
LOG_RETENTION_DAYS=7
STATE_FILE="/root/drive_spindown/drive_spindown_state"

# --- Flags -------------------------------------------------------------------

DAILY_SUMMARY=false
if [[ "$1" == "--daily-summary" ]]; then
    DAILY_SUMMARY=true
fi

# --- Helpers -----------------------------------------------------------------

LOG_DATE=$(date '+%Y-%m-%d %H:%M:%S')
TODAY=$(date '+%Y-%m-%d')
YESTERDAY=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S')

log() {
    echo "$LOG_DATE | $1" >> "$LOG_FILE"
}

get_drive_state() {
    local output
    output=$(hdparm -C "/dev/$1" 2>&1)
    if echo "$output" | grep -qi "standby\|sleeping"; then
        echo "standby"
    elif echo "$output" | grep -qi "active\|idle"; then
        echo "active"
    else
        echo "unknown"
    fi
}

spin_down_drive() {
    hdparm -y "/dev/$1" > /dev/null 2>&1
    log "FORCE SPINDOWN | /dev/$1 | Drive sent to standby"
}

count_events_24h() {
    local drive="$1"
    local event_type="$2"
    if [[ ! -f "$LOG_FILE" ]]; then echo 0; return; fi

    awk -v cutoff="$YESTERDAY" -v drv="/dev/$drive" -v evt="$event_type" '
    {
        datetime = $1 " " $2
        if (datetime >= cutoff && index($0, evt) > 0 && index($0, drv) > 0)
            count++
    }
    END { print count+0 }
    ' "$LOG_FILE"
}

prune_old_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then return; fi
    local cutoff tmp
    cutoff=$(date -d "${LOG_RETENTION_DAYS} days ago" '+%Y-%m-%d %H:%M:%S')
    tmp=$(mktemp)
    awk -v cutoff="$cutoff" '{ if ($1 " " $2 >= cutoff) print }' "$LOG_FILE" > "$tmp"
    mv "$tmp" "$LOG_FILE"
}

# --- Daily summary -----------------------------------------------------------

write_daily_summary() {
    log "========= DAILY SUMMARY ($TODAY) ========="
    for drive in "${DRIVES[@]}"; do
        if [[ ! -b "/dev/$drive" ]]; then continue; fi
                spinups=$(count_events_24h "$drive" "DRIVE ACTIVE")
                spindowns=$(count_events_24h "$drive" "SPINDOWN")
        log "TOTAL24H | /dev/$drive | Spin-ups: $spinups | Spin-downs: $spindowns"
    done
    log "========= END SUMMARY ===================="
    echo "" >> "$LOG_FILE"
}

# --- State tracking ----------------------------------------------------------



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

# --- Main --------------------------------------------------------------------

prune_old_logs

if $DAILY_SUMMARY; then
    write_daily_summary
    exit 0
fi

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
            if [[ "$prev" == "standby" || "$prev" == "unknown" ]]; then
                log "DRIVE ACTIVE   | /dev/$drive | Drive is currently powered up (was: $prev)"
            else
                log "DRIVE ACTIVE | /dev/$drive | Drive already active (was: $prev)"
            fi
            spin_down_drive "$drive"
            CURRENT_STATE[$drive]="standby"
            ;;
        standby)
            log "DRIVE IN STANDBY | /dev/$drive | Drive already sleeping, nothing to do."
            ;;
        unknown)
            log "UNKNOWN  | /dev/$drive | Could not determine state"
            ;;
    esac
done

save_current_state
log "--------- CHECK END -----------"
echo "" >> "$LOG_FILE"
