#!/bin/bash
# analyze.sh - Aggregate and compare results from multiple clone-tests runs
# Usage:
#   ./analyze.sh                    # analyze all runs in logs/
#   ./analyze.sh logs/20260320-*    # analyze specific runs
#   ./analyze.sh customer1/ customer2/  # compare customer submissions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="unknown"
[ -f "$SCRIPT_DIR/.version" ] && VERSION=$(tr -d '[:space:]' < "$SCRIPT_DIR/.version")

# Collect run directories
RUN_DIRS=()
if [ $# -eq 0 ]; then
    for d in "$SCRIPT_DIR"/logs/*/; do
        [ -d "$d" ] && RUN_DIRS+=("$d")
    done
else
    for arg in "$@"; do
        if [ -d "$arg" ]; then
            # Could be a run dir directly or a parent containing runs
            if [ -f "$arg/run_summary.json" ] || [ -f "$arg/clone_summary.log" ]; then
                RUN_DIRS+=("$arg")
            else
                for d in "$arg"/*/; do
                    [ -d "$d" ] && RUN_DIRS+=("$d")
                done
            fi
        fi
    done
fi

if [ ${#RUN_DIRS[@]} -eq 0 ]; then
    echo "No run directories found."
    echo "Usage: ./analyze.sh [logs/run-id/ ...]"
    exit 1
fi

echo "============================================"
echo "  Clone Tests Analysis v${VERSION}"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Runs found: ${#RUN_DIRS[@]}"
echo "============================================"
echo ""

# Header for the summary table
printf "%-24s %-8s %-16s %-22s %-6s %-8s %-10s %-10s %-10s %-8s %-30s\n" \
    "RUN ID" "ENV" "PUBLIC IP" "ISP" "POP" "CLONES" "AVG MiB/s" "MIN MiB/s" "MAX MiB/s" "PING ms" "MTR WORST HOP"
printf '%0.s-' {1..160}
echo ""

for run_dir in "${RUN_DIRS[@]}"; do
    run_id=$(basename "$run_dir")

    # Try to extract from run_summary.json first (machine-readable)
    json_file="$run_dir/run_summary.json"
    summary_file="$run_dir/clone_summary.log"
    mtr_file="$run_dir/mtr.log"
    system_file="$run_dir/system_info.log"
    network_file="$run_dir/network_diag.log"

    env="-"
    pub_ip="-"
    isp="-"
    pop="-"
    clone_count=0
    avg_speed="-"
    min_speed="-"
    max_speed="-"
    ping_avg="-"
    mtr_worst="-"

    # Extract from JSON if available
    if [ -f "$json_file" ]; then
        env=$(grep -oE '"env":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        pub_ip=$(grep -oE '"public_ip":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        isp=$(grep -oE '"isp":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        mtr_host=$(grep -oE '"worst_hop_host":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        mtr_loss=$(grep -oE '"worst_hop_loss_pct":\s*[0-9.]+' "$json_file" | head -1 | awk -F: '{print $2}' | tr -d ' ' || true)
        [ -n "$mtr_host" ] && [ "$mtr_host" != "none" ] && mtr_worst="${mtr_host} (${mtr_loss}%)"
    fi

    # Extract from system_info.log as fallback
    if { [ "$pub_ip" = "-" ] || [ -z "$pub_ip" ]; } && [ -f "$system_file" ]; then
        pub_ip=$(grep "Public IP:" "$system_file" 2>/dev/null | head -1 | awk '{print $NF}')
    fi

    # Extract from clone_summary.log
    if [ -f "$summary_file" ]; then
        clone_count=$(grep -c "^Clone #" "$summary_file" 2>/dev/null || echo 0)

        # Extract POP from first clone
        pop=$(grep -oE 'POP: [A-Z]+' "$summary_file" | head -1 | awk '{print $2}')

        # Aggregate speed stats across all clones (POSIX awk - no gawk capture groups)
        read -r min_speed max_speed avg_speed <<< $(awk '
            /^Clone #/ {
                if (match($0, /Min=[0-9.]+/)) {
                    val=substr($0, RSTART+4, RLENGTH-4)+0
                    if(val>0 && (global_min=="" || val<global_min)) global_min=val
                }
                if (match($0, /Max=[0-9.]+/)) {
                    val=substr($0, RSTART+4, RLENGTH-4)+0
                    if(val>global_max) global_max=val
                }
                if (match($0, /Avg=[0-9.]+/)) {
                    avg_sum+=substr($0, RSTART+4, RLENGTH-4)+0; avg_count++
                }
            }
            END {
                if (avg_count>0) printf "%.1f %.1f %.1f", global_min, global_max, avg_sum/avg_count
                else print "- - -"
            }
        ' "$summary_file")

        # Average ping (POSIX awk)
        ping_avg=$(awk '
            /^Clone #/ && /Ping:/ {
                if (match($0, /Ping: [0-9.]+ms/)) {
                    sum+=substr($0, RSTART+6, RLENGTH-8)+0; n++
                }
            }
            END { if(n>0) printf "%.1f", sum/n; else print "-" }
        ' "$summary_file")
    fi

    # Extract MTR worst hop from mtr.log as fallback
    if [ "$mtr_worst" = "-" ] && [ -f "$mtr_file" ]; then
        read -r mtr_w_host mtr_w_loss <<< $(awk '
            /^\s*[0-9]+\.\|--/ && !/\?\?\?/ {
                gsub(/\|--/, ""); hop=$1+0; host=$2; loss=$3
                gsub(/%/, "", loss)
                if (loss+0 > max+0 && loss+0 < 100) { max=loss; mhost=host }
            }
            END { if(mhost) printf "%s %s", mhost, max }
        ' "$mtr_file")
        [ -n "$mtr_w_host" ] && mtr_worst="${mtr_w_host} (${mtr_w_loss}%)"
    fi

    # Extract from network_diag.log as fallback for POP
    if { [ -z "$pop" ] || [ "$pop" = "-" ]; } && [ -f "$network_file" ]; then
        pop=$(grep -oE 'POP=[A-Z]+' "$network_file" | head -1 | cut -d= -f2)
    fi

    [ -z "$env" ] && env="-"
    [ -z "$pub_ip" ] && pub_ip="-"
    [ -z "$isp" ] && isp="-"
    [ -z "$pop" ] && pop="-"

    printf "%-24s %-8s %-16s %-22s %-6s %-8s %-10s %-10s %-10s %-8s %-30s\n" \
        "$run_id" "${env:0:8}" "${pub_ip:0:16}" "${isp:0:22}" "$pop" "$clone_count" \
        "$avg_speed" "$min_speed" "$max_speed" "$ping_avg" "${mtr_worst:0:30}"
done

echo ""
echo "============================================"
echo "  Detailed Per-Run Breakdown"
echo "============================================"

for run_dir in "${RUN_DIRS[@]}"; do
    run_id=$(basename "$run_dir")
    summary_file="$run_dir/clone_summary.log"
    mtr_file="$run_dir/mtr.log"
    network_file="$run_dir/network_diag.log"

    echo ""
    echo "--- $run_id ---"

    # Show system info one-liner
    json_file="$run_dir/run_summary.json"
    if [ -f "$json_file" ]; then
        city=$(grep -oE '"city":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        region=$(grep -oE '"region":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        country=$(grep -oE '"country":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        isp=$(grep -oE '"isp":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        pub_ip=$(grep -oE '"public_ip":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        echo "  Location: ${city:-?}, ${region:-?}, ${country:-?} | ISP: ${isp:-?} | IP: ${pub_ip:-?}"
    fi

    # Show clone results
    if [ -f "$summary_file" ]; then
        grep "^Clone #" "$summary_file" | while IFS= read -r line; do
            echo "  $line"
        done
    fi

    # Show MTR worst hops (top 3 by loss)
    if [ -f "$mtr_file" ] && grep -q '|--' "$mtr_file"; then
        echo "  MTR worst hops:"
        awk '
            /^\s*[0-9]+\.\|--/ && !/\?\?\?/ {
                gsub(/\|--/, ""); hop=$1; host=$2; loss=$3
                gsub(/%/, "", loss)
                if (loss+0 > 5) printf "    Hop %s %s - %s%% loss\n", hop, host, loss
            }
        ' "$mtr_file" | sort -t'%' -k1 -rn | head -5
    fi

    # Show transit providers from network log
    if [ -f "$network_file" ]; then
        zayo_hops=$(grep -oE '[a-z0-9.-]+\.zayo\.com' "$network_file" 2>/dev/null | sort -u | wc -l | tr -d ' ')
        [ "$zayo_hops" -gt 0 ] && echo "  Transit: Zayo ($zayo_hops hops observed)"
    fi
done

echo ""
echo "============================================"
echo "  Transit Analysis"
echo "============================================"
echo ""

# Look for common problem routers across all runs
echo "Common Zayo routers with loss (across all runs):"
for run_dir in "${RUN_DIRS[@]}"; do
    mtr_file="$run_dir/mtr.log"
    [ -f "$mtr_file" ] || continue
    awk '
        /^\s*[0-9]+\.\|--/ && /zayo\.com/ && !/\?\?\?/ {
            gsub(/\|--/, ""); host=$2; loss=$3
            gsub(/%/, "", loss)
            if (loss+0 > 5) print host, loss
        }
    ' "$mtr_file"
done | sort | uniq -c | sort -rn | head -10 | while read -r count host loss; do
    printf "  %-50s %s%% loss (seen in %s run%s)\n" "$host" "$loss" "$count" "$([ "$count" -gt 1 ] && echo 's')"
done

echo ""
echo "============================================"
echo "  One-Line Fingerprints (for spreadsheets)"
echo "============================================"
echo ""
echo "RUN_ID,ENV,PUBLIC_IP,CITY,REGION,COUNTRY,ISP,POP,CLONES,AVG_SPEED_MIB,MIN_SPEED_MIB,MAX_SPEED_MIB,PING_AVG_MS,MTR_WORST_HOST,MTR_WORST_LOSS_PCT"

for run_dir in "${RUN_DIRS[@]}"; do
    run_id=$(basename "$run_dir")
    json_file="$run_dir/run_summary.json"
    summary_file="$run_dir/clone_summary.log"
    mtr_file="$run_dir/mtr.log"

    env="" pub_ip="" city="" region="" country="" isp="" pop=""
    clone_count=0 avg_speed="" min_speed="" max_speed="" ping_avg=""
    mtr_host="" mtr_loss="0"

    if [ -f "$json_file" ]; then
        env=$(grep -oE '"env":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        pub_ip=$(grep -oE '"public_ip":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        city=$(grep -oE '"city":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        region=$(grep -oE '"region":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        country=$(grep -oE '"country":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        isp=$(grep -oE '"isp":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        mtr_host=$(grep -oE '"worst_hop_host":\s*"[^"]*"' "$json_file" | head -1 | cut -d'"' -f4 || true)
        mtr_loss=$(grep -oE '"worst_hop_loss_pct":\s*[0-9.]+' "$json_file" | head -1 | awk -F: '{print $2}' | tr -d ' ' || true)
    fi

    if [ -f "$summary_file" ]; then
        clone_count=$(grep -c "^Clone #" "$summary_file" 2>/dev/null || echo 0)
        pop=$(grep -oE 'POP: [A-Z]+' "$summary_file" | head -1 | awk '{print $2}' || true)
        read -r min_speed max_speed avg_speed <<< $(awk '
            /^Clone #/ {
                if (match($0, /Min=[0-9.]+/)) { v=substr($0,RSTART+4,RLENGTH-4)+0; if(v>0&&(gmin==""||v<gmin))gmin=v }
                if (match($0, /Max=[0-9.]+/)) { v=substr($0,RSTART+4,RLENGTH-4)+0; if(v>gmax)gmax=v }
                if (match($0, /Avg=[0-9.]+/)) { s+=substr($0,RSTART+4,RLENGTH-4)+0; n++ }
            }
            END { if(n>0) printf "%.1f %.1f %.1f",gmin,gmax,s/n; else print "0 0 0" }
        ' "$summary_file")
        ping_avg=$(awk '/^Clone #/ && /Ping:/ { if(match($0,/Ping: [0-9.]+ms/)){s+=substr($0,RSTART+6,RLENGTH-8)+0;n++} } END{if(n>0)printf "%.1f",s/n;else print "0"}' "$summary_file")
    fi

    # Escape commas in ISP name for CSV
    isp_csv=$(echo "${isp:-}" | tr ',' ';')

    echo "${run_id},${env:-},${pub_ip:-},${city:-},${region:-},${country:-},${isp_csv},${pop:-},${clone_count},${avg_speed:-0},${min_speed:-0},${max_speed:-0},${ping_avg:-0},${mtr_host:-none},${mtr_loss:-0}"
done

echo ""
echo "Tip: Redirect CSV to a file: ./analyze.sh 2>/dev/null | tail -n +N > results.csv"
