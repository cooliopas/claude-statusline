#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ───────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ──────────────────────────────────────────────
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

iso_to_epoch() {
    local iso_str="$1"
    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi
    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"
    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi
    return 1
}

# ── Extract JSON data ─────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

session_duration=""
start_epoch=""
session_start=$(echo "$input" | jq -r '.session.start_time // empty')
if [ -n "$session_start" ] && [ "$session_start" != "null" ]; then
    start_epoch=$(iso_to_epoch "$session_start")
    if [ -n "$start_epoch" ]; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

# ── OAuth token resolution ────────────────────────────────
get_oauth_token() {
    local token=""
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi
    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi
    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi
    echo ""
}

# ── Fetch usage data (cached) ─────────────────────────────
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
mkdir -p /tmp/claude

needs_refresh=true
usage_data=""

if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    now=$(date +%s)
    cache_age=$(( now - cache_mtime ))
    if [ "$cache_age" -lt "$cache_max_age" ]; then
        needs_refresh=false
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

if $needs_refresh; then
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        response=$(curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "$cache_file"
        fi
    fi
    if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

# ── Version update check (cached) ────────────────────────
update_indicator=""
session_ver_file="/tmp/claude/statusline-session-ver"
current_ver_file="/tmp/claude/statusline-current-ver"
ver_cache_max_age=120

# Get currently installed version (cached)
installed_ver=""
needs_ver_check=true
if [ -f "$current_ver_file" ]; then
    ver_mtime=$(stat -c %Y "$current_ver_file" 2>/dev/null || stat -f %m "$current_ver_file" 2>/dev/null)
    ver_now=$(date +%s)
    ver_age=$(( ver_now - ver_mtime ))
    if [ "$ver_age" -lt "$ver_cache_max_age" ]; then
        needs_ver_check=false
        installed_ver=$(cat "$current_ver_file" 2>/dev/null)
    fi
fi
if $needs_ver_check; then
    installed_ver=$(claude --version 2>/dev/null | awk '{print $1}')
    if [ -n "$installed_ver" ]; then
        echo "$installed_ver" > "$current_ver_file"
    fi
fi

# Save session version on first run or new session
regen_session_ver=false
if [ ! -f "$session_ver_file" ]; then
    regen_session_ver=true
elif [ -n "$start_epoch" ]; then
    sv_mtime=$(stat -c %Y "$session_ver_file" 2>/dev/null || stat -f %m "$session_ver_file" 2>/dev/null)
    if [ -n "$sv_mtime" ] && [ "$sv_mtime" -lt "$start_epoch" ]; then
        regen_session_ver=true
    fi
fi
if $regen_session_ver && [ -n "$installed_ver" ]; then
    echo "$installed_ver" > "$session_ver_file"
fi

# Compare: show version normally, or restart indicator if changed
if [ -f "$session_ver_file" ] && [ -n "$installed_ver" ]; then
    session_ver=$(cat "$session_ver_file" 2>/dev/null)
    if [ "$session_ver" != "$installed_ver" ]; then
        update_indicator="${sep}${red}⟳ restart ${dim}(${installed_ver})${reset}"
    else
        update_indicator="${sep}${dim}v${session_ver}${reset}"
    fi
elif [ -n "$installed_ver" ]; then
    update_indicator="${sep}${dim}v${installed_ver}${reset}"
fi

# ── Build inline rate limit segments ─────────────────────
rate_segment=""

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    five_pct_color=$(color_for_pct "$five_hour_pct")

    seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    seven_pct_color=$(color_for_pct "$seven_day_pct")

    rate_segment="${sep}${dim}5h:${reset}${five_pct_color}${five_hour_pct}%${reset}${dim} 7d:${reset}${seven_pct_color}${seven_day_pct}%${reset}"
fi

# ── Assemble single line ──────────────────────────────────
pct_color=$(color_for_pct "$pct_used")

line="${blue}${model_name}${reset}"
line+="${sep}"
line+="✍️ ${pct_color}${pct_used}%${reset}"
line+="${sep}"
line+="${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
    line+="${sep}"
    line+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
line+="$rate_segment"
line+="$update_indicator"

printf "%b" "$line"
exit 0
