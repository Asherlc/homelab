#!/bin/bash
# Idempotently apply Tdarr desired state from configs/tdarr/qsv-state.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${TDARR_IAC_CONFIG:-$REPO_DIR/configs/tdarr/qsv-state.json}"
API_BASE="${TDARR_API_BASE:-http://127.0.0.1:8265/api/v2}"

log() {
    echo "[tdarr-iac] $*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "Missing required command: $1"
        exit 1
    }
}

api_post() {
    local path="$1"
    local payload="$2"
    curl -fsS --connect-timeout 5 --max-time 60 \
        -X POST "$API_BASE/$path" \
        -H "Content-Type: application/json" \
        -d "$payload"
}

wait_for_tdarr() {
    local attempts=30
    local sleep_sec=2
    for ((i = 1; i <= attempts; i++)); do
        if curl -fsS --connect-timeout 2 --max-time 5 "$API_BASE/status" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$sleep_sec"
    done
    return 1
}

normalize_json() {
    jq -cS "."
}

main() {
    require_cmd curl
    require_cmd jq

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    if ! wait_for_tdarr; then
        log "Tdarr API unavailable at $API_BASE, skipping apply."
        exit 0
    fi

    local desired_stack
    desired_stack="$(jq -c ".plugin_stack" "$CONFIG_FILE")"
    local desired_stack_norm
    desired_stack_norm="$(printf "%s" "$desired_stack" | normalize_json)"

    local libraries_json
    libraries_json="$(api_post "cruddb" '{"data":{"collection":"LibrarySettingsJSONDB","mode":"getAll"}}')"

    local updates=0
    local missing=0

    while IFS= read -r target; do
        local lib_name lib_folder
        lib_name="$(jq -r ".name" <<<"$target")"
        lib_folder="$(jq -r ".folder" <<<"$target")"

        local lib_json
        lib_json="$(jq -c --arg name "$lib_name" --arg folder "$lib_folder" \
            '.[] | select((.name == $name) or (.folder == $folder))' <<<"$libraries_json" | head -n 1)"

        if [[ -z "$lib_json" ]]; then
            log "Library not found: name='$lib_name', folder='$lib_folder'"
            missing=$((missing + 1))
            continue
        fi

        local lib_id current_stack_norm
        lib_id="$(jq -r "._id" <<<"$lib_json")"
        current_stack_norm="$(jq -c ".pluginIDs" <<<"$lib_json" | normalize_json)"

        if [[ "$current_stack_norm" != "$desired_stack_norm" ]]; then
            local payload
            payload="$(jq -cn --arg id "$lib_id" --argjson plugins "$desired_stack" \
                '{data:{collection:"LibrarySettingsJSONDB",mode:"update",docID:$id,obj:{pluginIDs:$plugins}}}')"
            api_post "cruddb" "$payload" >/dev/null
            log "Updated plugin stack for library '$lib_name' ($lib_id)."
            updates=$((updates + 1))
        else
            log "Library '$lib_name' ($lib_id) already matches desired plugin stack."
        fi
    done < <(jq -c ".libraries[]" "$CONFIG_FILE")

    local nodes_json
    nodes_json="$(curl -fsS --connect-timeout 5 --max-time 60 "$API_BASE/get-nodes")"

    local node_name node_id
    node_name="$(jq -r ".node.name" "$CONFIG_FILE")"
    node_id="$(jq -r --arg node_name "$node_name" \
        'to_entries[] | select(.value.nodeName == $node_name) | .key' <<<"$nodes_json" | head -n 1)"

    if [[ -n "$node_id" ]]; then
        for worker_type in healthcheckcpu healthcheckgpu transcodecpu transcodegpu; do
            local desired current
            desired="$(jq -r --arg wt "$worker_type" '.node.worker_limits[$wt] // empty' "$CONFIG_FILE")"
            [[ -z "$desired" ]] && continue

            current="$(jq -r --arg id "$node_id" --arg wt "$worker_type" '.[$id].workerLimits[$wt]' <<<"$nodes_json")"
            if [[ -z "$current" ]]; then
                log "Node '$node_name' missing worker type '$worker_type'; skipping."
                continue
            fi

            while (( current < desired )); do
                api_post "alter-worker-limit" \
                    "{\"data\":{\"nodeID\":\"$node_id\",\"process\":\"increase\",\"workerType\":\"$worker_type\"}}" \
                    >/dev/null
                current=$((current + 1))
            done

            while (( current > desired )); do
                api_post "alter-worker-limit" \
                    "{\"data\":{\"nodeID\":\"$node_id\",\"process\":\"decrease\",\"workerType\":\"$worker_type\"}}" \
                    >/dev/null
                current=$((current - 1))
            done
        done
        log "Applied worker limit targets for node '$node_name' ($node_id)."

        # Apply schedule if defined in config
        local desired_schedule
        desired_schedule="$(jq -c '.node.schedule // empty' "$CONFIG_FILE")"
        if [[ -n "$desired_schedule" ]]; then
            # Build the 24-hour schedule array from the per-hour template
            local schedule_array
            schedule_array="$(jq -c --argjson sched "$desired_schedule" '
                [ "00-01","01-02","02-03","03-04","04-05","05-06",
                  "06-07","07-08","08-09","09-10","10-11","11-12",
                  "12-13","13-14","14-15","15-16","16-17","17-18",
                  "18-19","19-20","20-21","21-22","22-23","23-00" ]
                | [ .[] as $slot | { _id: $slot } + $sched ]
            ' <<< 'null')"

            # Fetch current schedule from NodeJSONDB
            local node_db_json current_schedule_norm desired_schedule_norm
            node_db_json="$(api_post "cruddb" '{"data":{"collection":"NodeJSONDB","mode":"getAll"}}')"
            current_schedule_norm="$(jq -cS '.[0].schedule' <<< "$node_db_json")"
            desired_schedule_norm="$(printf '%s' "$schedule_array" | jq -cS '.')"

            if [[ "$current_schedule_norm" != "$desired_schedule_norm" ]]; then
                local sched_payload
                sched_payload="$(jq -cn --arg id "$node_name" --argjson schedule "$schedule_array" \
                    '{data:{collection:"NodeJSONDB",mode:"update",docID:$id,obj:{schedule:$schedule}}}')"
                api_post "cruddb" "$sched_payload" >/dev/null
                log "Updated schedule for node '$node_name'."

                # Tdarr doesn't reload the schedule from NodeJSONDB at runtime,
                # so a container restart is required for schedule changes to take effect.
                local container="${TDARR_CONTAINER:-tdarr}"
                log "Restarting container '$container' to apply schedule change..."
                sudo docker restart "$container" >/dev/null
                if ! wait_for_tdarr; then
                    log "Tdarr failed to come back up after restart."
                    exit 1
                fi
                log "Container restarted and Tdarr is ready."
            else
                log "Schedule for node '$node_name' already matches desired state."
            fi
        fi
    else
        log "Node '$node_name' not found; skipped worker limit enforcement."
    fi

    log "Tdarr IaC apply complete (libraries_updated=$updates, libraries_missing=$missing)."
}

main "$@"
