#!/bin/sh
# Usage: ./measure.sh <label> [minutes] [interval-seconds]
# Logs whole-system power every interval to logs/<label>.csv, then prints a summary.
# No admin needed: reads battery telemetry from ioreg. Works with the lid closed
# as long as the Mac stays awake (Decaffeinate helper installed).
set -e
# The CSV is comma-separated: a locale with a decimal comma (it_IT) would split every number in two.
export LC_ALL=C
cd "$(dirname "$0")"
LABEL=${1:?label required, e.g. baseline-open}
MINUTES=${2:-10}
INTERVAL=${3:-15}
mkdir -p logs
CSV="logs/$LABEL.csv"
echo "time,lid_closed,on_ac,battery_pct,system_w,battery_w,battery_temp_c,battery_ma" > "$CSV"

top_energy() { top -l 2 -s 3 -o power -stats command,cpu,power -n 8 | tail -8; }
top_energy > "logs/$LABEL.top-start.txt"

end=$(( $(date +%s) + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  # Values are read from the last field: depending on the macOS version, ioreg prefixes the lines with "|".
  # A missing key fails the run instead of logging zeros.
  ioreg -rn AppleSmartBattery | awk -v t="$(date +%H:%M:%S)" \
    -v lid="$(ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes' && echo 1 || echo 0)" '
    /"CurrentCapacity" =/   { pct = $NF }
    /"ExternalConnected" =/ { ac = ($NF == "Yes") }
    /"Voltage" =/           { v = $NF }
    /"InstantAmperage" =/   { a = (length($NF) == 20) ? substr($NF, 15) - 551616 : $NF }  # negative = 2^64 - |a|
    /"Temperature" =/       { temp = $NF / 100 }
    /PowerTelemetryData/    { if (match($0, /"SystemLoad"=[0-9]+/)) sys = substr($0, RSTART + 13, RLENGTH - 13) / 1000 }
    END {
      if (pct == "" || v == "" || a == "") { print "measure.sh: battery keys not found in ioreg" > "/dev/stderr"; exit 1 }
      printf "%s,%d,%d,%d,%.1f,%.1f,%.1f,%d\n", t, lid, ac, pct, sys, v * a / 1e6, temp, a
    }' >> "$CSV"
  sleep "$INTERVAL"
done

top_energy > "logs/$LABEL.top-end.txt"

# mAh used: the battery current integrated over the samples (discharge is negative).
awk -F, -v label="$LABEL" -v dt="$INTERVAL" 'NR > 1 { n++; w = $3 ? $5 : -$6; mah -= $8 * dt / 3600; s += w; if (w > mx) mx = w; if (n == 1) p0 = $4; p1 = $4; lid += $2; ac += $3 }
  END { printf "%s: %d samples, avg %.1f W, peak %.1f W, battery %d%% -> %d%% (%d mAh used), lid closed %d/%d, on AC %d/%d\n",
        label, n, s / n, mx, p0, p1, mah, lid, n, ac, n }' "$CSV" | tee -a logs/summary.txt
echo "Top energy apps at end:"; cat "logs/$LABEL.top-end.txt"
