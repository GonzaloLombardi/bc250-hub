#!/usr/bin/env bash
# soak-test.sh — 10-minute sustained loads, to see where temps settle and how much throughput
# survives once the board is heat-soaked (short benchmarks finish before that happens).
#
# Each combo is GPU:CPU, run back to back after a cool-down:
#   GPU  auto = adaptive governor, or a MHz value pinned with cyan-skillfish-performance-mode
#        (governor throttling stays on in both cases)
#   CPU  idle = no CPU load, max = stress-ng on all threads uncapped, or a MHz cap + stress-ng
# The GPU runs llama-bench pp512 back to back (-r 30 batches) the whole time.
#
#   sudo ./soak-test.sh                                       # 1700/1850 x 2000/2550 MHz
#   sudo COMBOS="auto:idle auto:max auto:2550" ./soak-test.sh # adaptive GPU, three CPU settings
#   sudo DUR=300 LIMIT=95 COMBOS="1850:2550" ./soak-test.sh
#
# Hard stop at LIMIT (default 100 C) on CPU Tctl or GPU edge. Needs root (CPU cap), the governor
# with [dbus] enabled = true, and llama-bench + a .gguf model under ~/llamabench and ~/models.
# Per-minute temps/power/CPU MHz, pp512 per batch and stress-ng bogo ops/s go to the terminal
# and to ~/cooling-bench/soak-<timestamp>/. Restores the CPU cap and adaptive mode on exit.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
UH=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
OUT=$UH/cooling-bench/soak-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"; exec > >(tee "$OUT/summary.txt") 2>&1
DUR=${DUR:-600}; LIMIT=${LIMIT:-100}; COMBOS=${COMBOS:-"1700:2000 1700:2550 1850:2000 1850:2550"}
G=""; K=""; for h in /sys/class/hwmon/hwmon*; do n=$(cat $h/name); [ "$n" = amdgpu ] && G=$h; [ "$n" = k10temp ] && K=$h; done
[ -n "$G" ] && [ -n "$K" ] || { echo "amdgpu / k10temp hwmon not found"; exit 2; }
B=$(find $UH/llamabench -name llama-bench | head -1); L=$(dirname "$B"); M=$(ls $UH/models/*.gguf 2>/dev/null | head -1)
[ -n "$B" ] && [ -n "$M" ] || { echo "need llama-bench + a .gguf model (see the unlock guide)"; exit 2; }
MAXF=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
setcap() { for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo "$1" > "$f"; done; }
tK() { echo $(( $(cat $K/temp1_input)/1000 )); }; tG() { echo $(( $(cat $G/temp1_input)/1000 )); }
mhz() { awk '/^cpu MHz/{s+=$4;n++}END{printf "%d", s/n}' /proc/cpuinfo; }
cleanup() { pkill -f stress-ng; pkill -f llama-bench; setcap "$MAXF"; cyan-skillfish-performance-mode --off >/dev/null 2>&1; }
trap cleanup EXIT
# Cool down to <=48 C on both sensors (4 min max), then settle 15 s.
cool() { local i=0; while { [ "$(tK)" -gt 48 ] || [ "$(tG)" -gt 48 ]; } && [ $i -lt 48 ]; do sleep 5; i=$((i+1)); done; sleep 15; }

soak() {  # soak GPU CPU
  local gf=$1 cf=$2 name="gpu$1-cpu$2" t0 end stop="" SN=""
  cyan-skillfish-performance-mode --off >/dev/null
  case "$cf" in idle|max) setcap "$MAXF" ;; *) setcap $((cf*1000)) ;; esac
  cool
  [ "$gf" != auto ] && { cyan-skillfish-performance-mode --fixed-frequency "$gf" >/dev/null; sleep 2; }
  echo "== $name  (start Tctl $(tK) C, edge $(tG) C, ${DUR}s)"
  t0=$(date +%s); end=$((t0+DUR))
  ( while :; do echo "$(( $(date +%s)-t0 )) $(cat $K/temp1_input) $(cat $G/temp1_input) $(cat $G/power1_input) $(mhz)"; sleep 1; done ) > "$OUT/$name.log" & local SP=$!
  [ "$cf" != idle ] && { stress-ng --cpu "$(nproc)" --timeout "${DUR}s" --metrics-brief > "$OUT/$name.stress" 2>&1 & SN=$!; }
  ( while [ "$(date +%s)" -lt "$end" ]; do
      r=$(LD_LIBRARY_PATH=$L "$B" -m $M -p 512 -n 0 -ngl 99 -r 30 2>/dev/null | awk -F'|' '/pp512/{print $(NF-1)}' | grep -oE '[0-9]+\.[0-9]+' | head -1)
      echo "$(( $(date +%s)-t0 )) ${r:-?}"; done ) > "$OUT/$name.tok" & local GP=$!
  while [ "$(date +%s)" -lt "$end" ]; do
    if [ "$(tK)" -ge "$LIMIT" ] || [ "$(tG)" -ge "$LIMIT" ]; then stop="HARD STOP at $(( $(date +%s)-t0 ))s: Tctl $(tK) C, edge $(tG) C"; break; fi
    sleep 1; done
  if [ -n "$SN" ]; then [ -n "$stop" ] && kill $SN; wait $SN 2>/dev/null; fi
  kill $GP 2>/dev/null; pkill -f llama-bench; wait $GP 2>/dev/null; kill $SP; wait $SP 2>/dev/null
  cyan-skillfish-performance-mode --off >/dev/null
  [ -n "$stop" ] && echo "$stop"
  echo "per minute:  min  Tctl avg/max  edge avg/max  PPT avg/max  CPU MHz"
  awk '{m=int($1/60); n[m]++; t[m]+=$2; g[m]+=$3; p[m]+=$4; c[m]+=$5; if($2>tm[m])tm[m]=$2; if($3>gm[m])gm[m]=$3; if($4>pm[m])pm[m]=$4}
    END{for(i=0;i in n;i++) printf "             %2d   %5.1f/%-5.1f  %5.1f/%-5.1f  %5.1f/%-5.1f  %d\n",i+1,t[i]/n[i]/1000,tm[i]/1000,g[i]/n[i]/1000,gm[i]/1000,p[i]/n[i]/1e6,pm[i]/1e6,c[i]/n[i]}' "$OUT/$name.log"
  echo "pp512 per batch (s: tok/s): $(tr '\n' ' ' < "$OUT/$name.tok")"
  awk -v h=$((DUR/2)) '$1>=h && $2+0>0{s+=$2;n++}END{if(n) printf "pp512 steady state (last half): %.0f tok/s\n", s/n}' "$OUT/$name.tok"
  [ -n "$SN" ] && echo "stress-ng bogo ops/s: $(awk '/metrc.* cpu /{print $(NF-1)}' "$OUT/$name.stress" | tail -1)"
}

echo "== $(date)  kernel $(uname -r)  threads $(nproc --all)  idle Tctl $(tK) C edge $(tG) C"
for c in $COMBOS; do soak "${c%%:*}" "${c##*:}"; done
echo "== done: $OUT"
