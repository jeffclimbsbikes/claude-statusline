#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
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

# ── Helpers ─────────────────────────────────────────────
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

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local remainder=$(( (pct * width) % 100 ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    # Partial dot: ◔ ◑ ◕ based on how far into the next dot we are
    local partial="" has_partial=0
    if [ "$remainder" -gt 0 ] && [ "$filled" -lt "$width" ]; then
        has_partial=1
        if [ "$remainder" -le 30 ]; then partial="◔"
        elif [ "$remainder" -le 65 ]; then partial="◑"
        else partial="◕"
        fi
    fi

    local empty=$(( width - filled - has_partial ))
    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${partial}${dim}${empty_str}${reset}"
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

format_relative_time() {
    local epoch="$1"
    [ -z "$epoch" ] || [ "$epoch" = "null" ] && return

    local now_epoch
    now_epoch=$(date +%s)
    local diff=$(( epoch - now_epoch ))
    if [ "$diff" -le 0 ]; then
        local result=""
        result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
        [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //; s/\.//g')
        printf "%s" "$result"
        return
    fi

    local total_min=$(( diff / 60 ))
    local h=$(( total_min / 60 ))
    local m=$(( total_min % 60 ))
    if [ "$h" -gt 0 ]; then
        printf "%dh %dm" "$h" "$m"
    else
        printf "%dm" "$m"
    fi
}

format_reset_datetime() {
    local epoch="$1"
    [ -z "$epoch" ] || [ "$epoch" = "null" ] && return

    local result=""
    result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
    [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g')
    printf "%s" "$result"
}

# ── Extract JSON data ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
output_tokens=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
cost_fmt=$(awk "BEGIN {printf \"\$%.3f\", $cost_usd}")

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

pct_used=$(echo "$input" | jq -r '.context_window.used_percentage // empty' | awk '{printf "%.0f", $1}')
if [ -z "$pct_used" ]; then
    if [ "$size" -gt 0 ]; then
        pct_used=$(( current * 100 / size ))
    else
        pct_used=0
    fi
fi

effort=$(echo "$input" | jq -r '.effort.level // "default"')

# ── LINE 1: Model │ Context % │ Directory (branch) │ Session │ Thinking ──
pct_color=$(color_for_pct "$pct_used")
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

line1="${blue}${model_name}${reset}"
line1+="${sep}"
line1+="${yellow}${cost_fmt}${reset}"
line1+="${sep}"
line1+="${dim}↑$(format_tokens $output_tokens)${reset}"
line1+="${sep}"
line1+="${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$session_duration" ]; then
    line1+="${sep}"
    line1+="${dim}⏱ ${reset}${white}${session_duration}${reset}"
fi
line1+="${sep}"
case "$effort" in
    high|xhigh|max) line1+="${magenta}● ${effort}${reset}" ;;
    medium) line1+="${dim}◑ ${effort}${reset}" ;;
    low)    line1+="${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${dim}◑ ${effort}${reset}" ;;
esac

# ── Rate limit lines ────────────────────────────────────
rate_lines=""

# Context window bar (always shown if data available)
if [ "$size" -gt 0 ]; then
    ctx_bar=$(build_bar "$pct_used" 10)
    ctx_pct_color=$(color_for_pct "$pct_used")
    ctx_pct_fmt=$(printf "%3d" "$pct_used")
    rate_lines+="${white}context${reset} ${ctx_bar} ${ctx_pct_color}${ctx_pct_fmt}%${reset} ${dim}${used_tokens}/${total_tokens}${reset}"
fi

# Rate limits come from stdin; each window may be absent
rate_line() {
    local label="$1" key="$2" fmt_reset="$3"
    local pct
    pct=$(echo "$input" | jq -r ".rate_limits.${key}.used_percentage // empty" | awk '{printf "%.0f", $1}')
    [ -z "$pct" ] && return
    local reset_epoch reset_txt bar pct_color pct_fmt dollars=""
    reset_epoch=$(echo "$input" | jq -r ".rate_limits.${key}.resets_at // empty")
    reset_txt=$($fmt_reset "$reset_epoch")
    bar=$(build_bar "$pct" 10)
    pct_color=$(color_for_pct "$pct")
    pct_fmt=$(printf "%3d" "$pct")
    local usd
    usd=$(echo "$input" | jq -r ".rate_limits.${key} | select(.used_usd != null and .limit_usd != null) | \"\\(.used_usd) \\(.limit_usd)\"")
    if [ -n "$usd" ]; then
        dollars=" ${dim}$(echo "$usd" | awk '{printf "$%.2f/$%.2f", $1, $2}')${reset}"
    fi
    local line
    line="${white}$(printf "%-7s" "$label")${reset} ${bar} ${pct_color}${pct_fmt}%${reset}${dollars}"
    [ -n "$reset_txt" ] && line+=" ${dim}⟳${reset} ${white}${reset_txt}${reset}"
    printf "%s" "$line"
}

for spec in "5-hour five_hour format_relative_time" "weekly seven_day format_reset_datetime" "spend spend_limit format_reset_datetime"; do
    set -- $spec
    rl=$(rate_line "$1" "$2" "$3")
    [ -n "$rl" ] && rate_lines+="\n${rl}"
done

# ── Turn timing stats (per-session) ─────────────────────
turn_line=""
session_id=$(echo "$input" | jq -r '.session_id // ""')
if [ -n "$session_id" ]; then
    history_file="/tmp/claude/turns-${session_id}.log"
    if [ -f "$history_file" ]; then
        turn_stats=$(python3 - "$history_file" <<'EOF'
import sys, statistics

vals = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line.isdigit():
            vals.append(int(line))

if not vals:
    sys.exit(0)

def fmt(ms):
    if ms >= 60000: return f"{ms/60000:.1f}m"
    if ms >= 1000:  return f"{ms/1000:.1f}s"
    return f"{ms}ms"

last = vals[-1]
avg  = int(statistics.mean(vals))
med  = int(statistics.median(vals))
mx   = max(vals)
n    = len(vals)

print(f"{fmt(last)}|{fmt(avg)}|{fmt(med)}|{fmt(mx)}|{n}")
EOF
)
        if [ -n "$turn_stats" ]; then
            IFS='|' read -r t_last t_avg t_med t_max t_n <<< "$turn_stats"
            # Last completion time from file mtime
            t_completed=$(date -j -r "$(stat -f %m "$history_file" 2>/dev/null)" +"%H:%M:%S" 2>/dev/null)
            [ -z "$t_completed" ] && t_completed=$(date -d "@$(stat -c %Y "$history_file" 2>/dev/null)" +"%H:%M:%S" 2>/dev/null)
            turn_line="${white}turns${reset}   ${dim}n=${reset}${white}${t_n}${reset}"
            turn_line+="${sep}${cyan}${t_last}${reset} ${dim}last${reset} ${dim}@${reset}${white}${t_completed}${reset}"
            turn_line+="${sep}${dim}avg ${reset}${white}${t_avg}${reset}"
            turn_line+="${sep}${dim}p50 ${reset}${white}${t_med}${reset}"
            turn_line+="${sep}${dim}max ${reset}${white}${t_max}${reset}"
        fi
    fi
fi
if [ -n "$turn_line" ]; then
    rate_lines+="\n${turn_line}"
fi

# ── Output ──────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"

exit 0
