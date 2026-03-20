#!/bin/bash
# Audit /mnt/storage/downloads against /mnt/storage/media to find safe-to-delete items.
# Runs all logic server-side via SSH heredoc to avoid round-trips.
set -euo pipefail

SSH_CMD=(ssh -o ConnectTimeout=10 asherlc@192.168.1.197)
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

echo "Connecting to homelab server..."

"${SSH_CMD[@]}" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail

DOWNLOADS="/mnt/storage/downloads"
MEDIA="/mnt/storage/media"

# Build a lookup of normalized titles in the media library.
# We scan top-level dirs in Movies and season-level dirs in TV Shows.
declare -A media_titles

normalize() {
    # Lowercase, strip year/quality tags, punctuation, collapse whitespace
    echo "$1" \
        | sed -E 's/\.(mkv|mp4|avi|srt|nfo|jpg|png|txt)$//i' \
        | sed -E 's/\(([0-9]{4})\)/\1/' \
        | sed -E 's/\{[^}]*\}//g' \
        | sed -E 's/\[[^]]*\]//g' \
        | tr '._' '  ' \
        | sed -E 's/[^a-zA-Z0-9 ]//g' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/\b(720p|1080p|2160p|4k|bluray|brrip|webrip|web dl|webdl|hdtv|x264|x265|h264|h265|hevc|aac|ac3|dts|remux|proper|repack|extended|unrated|directors cut)\b//gi' \
        | sed -E 's/  +/ /g' \
        | sed -E 's/^ +| +$//g'
}

# Extract the "core title" — the meaningful part for matching.
# For TV: show name (+ season if present). For movies: title (+ year if present).
extract_core() {
    local name="$1"
    local norm
    norm=$(normalize "$name")

    # Try to extract "Title S01" or "Title Season 1" pattern for TV
    if echo "$norm" | grep -qiE '\bs[0-9]{1,2}'; then
        echo "$norm" | sed -E 's/(s[0-9]{1,2}).*/\1/' | sed -E 's/ +$//'
        return
    fi
    if echo "$norm" | grep -qiE '\bseason [0-9]+'; then
        echo "$norm" | sed -E 's/(season [0-9]+).*/\1/' | sed -E 's/ +$//'
        return
    fi

    # For movies, keep title + year if present, drop everything after year
    if echo "$norm" | grep -qE '[0-9]{4}'; then
        echo "$norm" | sed -E 's/([0-9]{4}).*/\1/' | sed -E 's/ +$//'
        return
    fi

    # Fallback: just the normalized name
    echo "$norm"
}

human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc)G"
    elif (( bytes >= 1048576 )); then
        echo "$(echo "scale=1; $bytes / 1048576" | bc)M"
    else
        echo "${bytes}B"
    fi
}

echo "Indexing media library..."

# Index Movies — each top-level dir is a movie
if [ -d "$MEDIA/Movies" ]; then
    for entry in "$MEDIA/Movies"/*/; do
        [ -d "$entry" ] || continue
        name=$(basename "$entry")
        core=$(extract_core "$name")
        media_titles["$core"]=1
    done
fi

# Index TV Shows — index both the show name and show+season
if [ -d "$MEDIA/TV Shows" ]; then
    for show_dir in "$MEDIA/TV Shows"/*/; do
        [ -d "$show_dir" ] || continue
        show_name=$(basename "$show_dir")
        show_core=$(normalize "$show_name")
        media_titles["$show_core"]=1

        # Also index each season
        for season_dir in "$show_dir"*/; do
            [ -d "$season_dir" ] || continue
            season_name=$(basename "$season_dir")
            if echo "$season_name" | grep -qiE 'season [0-9]+'; then
                season_num=$(echo "$season_name" | grep -oiE '[0-9]+')
                padded=$(printf "s%02d" "$season_num")
                media_titles["${show_core} ${padded}"]=1
            fi
        done
    done
fi

echo "Indexed ${#media_titles[@]} media entries."
echo ""
echo "Scanning downloads..."
echo ""

safe_items=()
safe_sizes=()
keep_items=()
keep_sizes=()
safe_total=0
keep_total=0

for entry in "$DOWNLOADS"/*/; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")

    # Skip incomplete/temp dirs
    [[ "$name" == .* ]] && continue
    [[ "$name" == "_"* ]] && continue

    size_bytes=$(du -sb "$entry" 2>/dev/null | cut -f1)
    size_human=$(human_size "$size_bytes")
    core=$(extract_core "$name")

    found=0

    # Strategy 1: exact core match
    if [ -n "${media_titles[$core]+x}" ]; then
        found=1
    fi

    # Strategy 2: if this looks like TV with a season, also check without season
    if [ "$found" -eq 0 ]; then
        base_show=$(echo "$core" | sed -E 's/ s[0-9]{1,2}$//')
        if [ "$base_show" != "$core" ] && [ -n "${media_titles[$base_show]+x}" ]; then
            found=1
        fi
    fi

    # Strategy 3: check if any media title is a substring of this core or vice versa
    if [ "$found" -eq 0 ]; then
        for mtitle in "${!media_titles[@]}"; do
            # Skip very short titles to avoid false matches
            [ "${#mtitle}" -lt 4 ] && continue
            if [[ "$core" == *"$mtitle"* ]] || [[ "$mtitle" == *"$core"* ]]; then
                found=1
                break
            fi
        done
    fi

    if [ "$found" -eq 1 ]; then
        safe_items+=("$name")
        safe_sizes+=("$size_human")
        safe_total=$((safe_total + size_bytes))
    else
        keep_items+=("$name")
        keep_sizes+=("$size_human")
        keep_total=$((keep_total + size_bytes))
    fi
done

# Also check loose files (not directories) in downloads
for entry in "$DOWNLOADS"/*; do
    [ -f "$entry" ] || continue
    name=$(basename "$entry")

    [[ "$name" == .* ]] && continue

    size_bytes=$(stat -c%s "$entry" 2>/dev/null || echo 0)
    size_human=$(human_size "$size_bytes")
    core=$(extract_core "$name")

    found=0

    if [ -n "${media_titles[$core]+x}" ]; then
        found=1
    fi

    if [ "$found" -eq 0 ]; then
        for mtitle in "${!media_titles[@]}"; do
            [ "${#mtitle}" -lt 4 ] && continue
            if [[ "$core" == *"$mtitle"* ]] || [[ "$mtitle" == *"$core"* ]]; then
                found=1
                break
            fi
        done
    fi

    if [ "$found" -eq 1 ]; then
        safe_items+=("$name")
        safe_sizes+=("$size_human")
        safe_total=$((safe_total + size_bytes))
    else
        keep_items+=("$name")
        keep_sizes+=("$size_human")
        keep_total=$((keep_total + size_bytes))
    fi
done

echo "========================================"
echo " SAFE TO DELETE (found in media library)"
echo "========================================"
if [ ${#safe_items[@]} -eq 0 ]; then
    echo "  (none)"
else
    for i in "${!safe_items[@]}"; do
        printf "  %-8s  %s\n" "${safe_sizes[$i]}" "${safe_items[$i]}"
    done
fi
echo ""
echo "  Total: $(human_size $safe_total) across ${#safe_items[@]} items"
echo ""

echo "========================================"
echo " NOT IN MEDIA (only copy — keep)"
echo "========================================"
if [ ${#keep_items[@]} -eq 0 ]; then
    echo "  (none)"
else
    for i in "${!keep_items[@]}"; do
        printf "  %-8s  %s\n" "${keep_sizes[$i]}" "${keep_items[$i]}"
    done
fi
echo ""
echo "  Total: $(human_size $keep_total) across ${#keep_items[@]} items"
echo ""

grand_total=$((safe_total + keep_total))
echo "========================================"
echo " SUMMARY"
echo "========================================"
echo "  Safe to delete:  $(human_size $safe_total)"
echo "  Only copy (keep): $(human_size $keep_total)"
echo "  Total downloads:  $(human_size $grand_total)"
echo ""

REMOTE_SCRIPT
