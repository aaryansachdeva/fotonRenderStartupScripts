#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# FOTONLABS PROVISIONING PROTOCOL — Multi-GPU Session Striping
# ═══════════════════════════════════════════════════════════════
#
# Architecture:
#   - Each GPU runs a "session" with Blender's native -a flag
#   - Sessions divide frames via stride: session 0 gets 1,3,5,...
#     session 1 gets 2,4,6,... (with N sessions, stride = N)
#   - A main monitoring loop sends heartbeats with GPU stats
#     and checks for rebalancing (new sessions added by user)
#   - On rebalance: kill all Blender processes, recalculate
#     frame assignments from remaining work, restart
#   - Watchdog per session: detects frames on disk, uploads
#     to R2, reports progress
# ═══════════════════════════════════════════════════════════════

# Helper: report status to Foton API
report_status() {
  local STATUS="$1"
  local EXTRA="$2"
  if [ -n "$FOTON_API_URL" ]; then
    curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/report" \
      -H "Content-Type: application/json" \
      -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"status\": \"${STATUS}\"${EXTRA:+, $EXTRA}}" > /dev/null
  fi
}

# Helper: collect GPU stats as JSON
collect_gpu_stats() {
  if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | python3 -c "
import sys, json
stats = []
for line in sys.stdin:
    parts = [p.strip() for p in line.strip().split(',')]
    if len(parts) >= 6:
        stats.append({
            'gpuIndex': int(parts[0]),
            'utilization': float(parts[1]),
            'memoryUsed': float(parts[2]),
            'memoryTotal': float(parts[3]),
            'temperature': float(parts[4]),
            'powerDraw': float(parts[5]) if parts[5] != '[N/A]' else 0
        })
print(json.dumps(stats))
" 2>/dev/null || echo "[]"
  else
    echo "[]"
  fi
}

# ═══════════════════════════════════════════════════════════════
# 1. IGNITING THRUSTERS (Booting Up)
# ═══════════════════════════════════════════════════════════════

touch /root/installing
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚡ IGNITING THRUSTERS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Foton] Instance booted. Task: ${FOTON_TASK_ID}"

report_status "booting"
echo "[Foton] Status → booting"

# Start SSH
mkdir -p /var/run/sshd
service ssh start

# ── Log Pusher (background, every 5s) ──
PROV_LOG_FILE="/var/log/portal/provisioning.log"
echo 0 > /tmp/prov_log_offset

push_logs() {
  if [ -f "$PROV_LOG_FILE" ]; then
    local PROV_OFFSET=$(cat /tmp/prov_log_offset)
    local PROV_SIZE=$(wc -c < "$PROV_LOG_FILE")
    if [ "$PROV_SIZE" -gt "$PROV_OFFSET" ]; then
      local PROV_CHUNK=$(tail -c +$(( PROV_OFFSET + 1 )) "$PROV_LOG_FILE")
      if [ -n "$PROV_CHUNK" ]; then
        local ESCAPED=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$PROV_CHUNK")
        curl -s --connect-timeout 5 --max-time 15 -X POST "${FOTON_API_URL}/instances/logs" \
          -H "Content-Type: application/json" \
          -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"type\":\"provisioning\",\"content\":${ESCAPED}}" > /dev/null 2>&1
        echo "$PROV_SIZE" > /tmp/prov_log_offset
      fi
    fi
  fi
}

if [ -n "$FOTON_API_URL" ]; then
  (while true; do push_logs; sleep 5; done) &
  LOG_PUSHER_PID=$!
fi

# ═══════════════════════════════════════════════════════════════
# 2. ONBOARDING SYSTEMS (Downloading Software)
# ═══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 ONBOARDING SYSTEMS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

report_status "downloading_software"
echo "[Foton] Status → downloading_software"

apt-get update -qq
apt-get install -y -qq wget xz-utils libgl1 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxxf86vm1 libsm6 libxext6 openssh-server python3 curl zstd
echo "[Foton] System dependencies installed."

if [ ! -d "/opt/blender" ]; then
  echo "[Foton] Downloading Blender 5.0.1..."
  wget -q --show-progress https://download.blender.org/release/Blender5.0/blender-5.0.1-linux-x64.tar.xz 2>&1 | \
    while IFS= read -r line; do echo "[Foton] $line"; done
  tar -xf blender-5.0.1-linux-x64.tar.xz
  mv blender-5.0.1-linux-x64 /opt/blender
  rm blender-5.0.1-linux-x64.tar.xz
  echo "[Foton] Blender 5.0.1 installed."
else
  echo "[Foton] Blender already installed."
fi

wget -q -O /opt/blender/activate_gpu.py https://raw.githubusercontent.com/aaryansachdeva/fotonRenderStartupScripts/refs/heads/main/activate_gpu.py

# ═══════════════════════════════════════════════════════════════
# 3. FETCH RENDER CONFIG
# ═══════════════════════════════════════════════════════════════

if [ -z "$FOTON_API_URL" ]; then
  echo "[Foton] No API URL set. Exiting."
  exit 0
fi

CONFIG=$(curl -s "${FOTON_API_URL}/instances/render-config?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}")

export FRAME_START=$(echo "$CONFIG"  | python3 -c "import sys,json; print(json.load(sys.stdin)['frameStart'])")
export FRAME_END=$(echo "$CONFIG"    | python3 -c "import sys,json; print(json.load(sys.stdin)['frameEnd'])")
export FRAME_INC=$(echo "$CONFIG"    | python3 -c "import sys,json; print(json.load(sys.stdin)['frameIncrement'])")
export TOTAL_FRAMES=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('totalFrames', 0))")
export RES_X=$(echo "$CONFIG"        | python3 -c "import sys,json; print(json.load(sys.stdin)['resolutionX'])")
export RES_Y=$(echo "$CONFIG"        | python3 -c "import sys,json; print(json.load(sys.stdin)['resolutionY'])")
export CAMERA=$(echo "$CONFIG"       | python3 -c "import sys,json; print(json.load(sys.stdin)['camera'])")
export RENDER_ENGINE=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin)['renderEngine'])")
export FILE_EXT=$(echo "$CONFIG"     | python3 -c "import sys,json; print(json.load(sys.stdin)['fileExtension'])")
export OUTPUT_NAMING=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin)['outputFileNaming'])")
export MAX_SAMPLES=$(echo "$CONFIG"  | python3 -c "import sys,json; print(json.load(sys.stdin)['maxSamples'])")
export UPLOAD_TYPE=$(echo "$CONFIG"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('uploadType') or 'blend')" 2>/dev/null)
export BLEND_RELATIVE_PATH=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendRelativePath') or '')" 2>/dev/null)
export IS_BENCHMARK=$(echo "$CONFIG" | python3 -c "import sys,json; print(1 if json.load(sys.stdin).get('isBenchmark') else 0)")
export SELECTED_ADDONS_JSON=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('selectedAddons',[])))" 2>/dev/null)

# Map file extension to Blender format
case "$FILE_EXT" in
  exr)      export BLENDER_FORMAT="OPEN_EXR" ;;
  png)      export BLENDER_FORMAT="PNG" ;;
  jpeg|jpg) export BLENDER_FORMAT="JPEG"; FILE_EXT="jpg" ;;
  tiff|tif) export BLENDER_FORMAT="TIFF"; FILE_EXT="tif" ;;
  *)        export BLENDER_FORMAT="PNG"; FILE_EXT="png" ;;
esac

echo "[Foton] Config: frames ${FRAME_START}-${FRAME_END} (step ${FRAME_INC}), total=${TOTAL_FRAMES}, ${RES_X}x${RES_Y}, engine=${RENDER_ENGINE}, samples=${MAX_SAMPLES}"

# ── Disk space info ──
DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
DISK_USED=$(df -h / | awk 'NR==2{print $3}')
DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
echo "[Foton] Disk: ${DISK_TOTAL} total, ${DISK_USED} used, ${DISK_FREE} free"

# ── Install selected Blender add-ons from extensions.blender.org ──
if [ -n "$SELECTED_ADDONS_JSON" ] && [ "$SELECTED_ADDONS_JSON" != "[]" ]; then
  echo "[Foton] Installing Blender add-ons: $SELECTED_ADDONS_JSON"
  echo "[Foton] Syncing extension repository index..."
  /opt/blender/blender --online-mode --command extension sync 2>&1
  echo "[Foton] Sync complete, installing add-ons..."
  /opt/blender/blender --online-mode -b --python-expr "
import bpy, json, os

addons = json.loads(os.environ.get('SELECTED_ADDONS_JSON', '[]'))
print(f'[Foton] Add-ons to install: {addons}')

for addon_id in addons:
    try:
        print(f'[Foton] Installing {addon_id}...')
        bpy.ops.extensions.package_install(repo_index=0, pkg_id=addon_id)
        bpy.ops.preferences.addon_enable(module=f'bl_ext.blender_org.{addon_id}')
        print(f'[Foton] Installed and enabled: {addon_id}')
    except Exception as e:
        print(f'[Foton] Warning: Failed to install {addon_id}: {e}')

bpy.ops.wm.save_userpref()
print('[Foton] Add-on preferences saved')
" 2>&1
  echo "[Foton] Add-on installation complete"
fi

if [ "$IS_BENCHMARK" = "1" ]; then

# ═══════════════════════════════════════════════════════════════
# BENCHMARK TWO-PASS MODE (single session, no multi-GPU)
# ═══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 BENCHMARK MODE (Two-Pass)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p /root/output

cat > /root/bench_setup.py << 'PYEOF'
import bpy
import os
import sys

def env(key):
    val = os.environ.get(key)
    if val is None:
        print(f"[Foton] FATAL: Missing env var {key}")
        sys.exit(1)
    return val

RES_X = int(env('RES_X'))
RES_Y = int(env('RES_Y'))
FRAME_START = int(env('FRAME_START'))
FRAME_END = int(env('FRAME_END'))
FRAME_INC = int(env('FRAME_INC'))
CAMERA = env('CAMERA')
ENGINE = env('RENDER_ENGINE')
SAMPLES = int(env('BENCH_SAMPLES'))
FILE_FORMAT = env('BLENDER_FORMAT')
OUTPUT_NAMING = env('OUTPUT_NAMING')

scene = bpy.context.scene
scene.render.resolution_x = RES_X
scene.render.resolution_y = RES_Y
scene.render.resolution_percentage = 100
scene.frame_start = FRAME_START
scene.frame_end = FRAME_END
scene.frame_step = FRAME_INC

if CAMERA and CAMERA in bpy.data.objects:
    scene.camera = bpy.data.objects[CAMERA]
if ENGINE:
    scene.render.engine = ENGINE

if SAMPLES > 0:
    if ENGINE == 'CYCLES':
        scene.cycles.samples = SAMPLES
        scene.cycles.device = 'GPU'
    elif ENGINE in ('BLENDER_EEVEE', 'BLENDER_EEVEE_NEXT'):
        scene.eevee.taa_render_samples = SAMPLES

scene.render.image_settings.file_format = FILE_FORMAT
scene.render.filepath = f"/root/output/{OUTPUT_NAMING}_"
scene.render.use_file_extension = True
print(f"[Foton] Bench setup: {RES_X}x{RES_Y}, frames {FRAME_START}-{FRAME_END} step {FRAME_INC}, engine={ENGINE}, format={FILE_FORMAT}, samples={SAMPLES}")

# List all enabled add-ons
enabled = [mod.module for mod in bpy.context.preferences.addons]
print(f"[Foton] Active add-ons ({len(enabled)}): {', '.join(sorted(enabled))}")
PYEOF

report_status "rendering"
echo "[Foton] Status → rendering"

# ── Pass 0: Warmup (single frame at 1 sample — compiles GPU kernels) ──
echo "[Foton] Pass 0: Warmup render (1 sample, first frame only)..."
export BENCH_SAMPLES=1
WARMUP_LOG="/root/warmup.log"
/opt/blender/blender -b "$BLEND_FILE" \
  -P /opt/blender/activate_gpu.py \
  -P /root/bench_setup.py \
  -f "$FRAME_START" > "$WARMUP_LOG" 2>&1
echo "[Foton] Warmup complete. GPU kernels compiled."
rm -f /root/output/*

# ── Pass 1: 1-sample pass across all benchmark frames (baseline timing) ──
echo "[Foton] Pass 1: 1-sample baseline across all frames..."
export BENCH_SAMPLES=1
PASS1_LOG="/root/pass1.log"
/opt/blender/blender -b "$BLEND_FILE" \
  -P /opt/blender/activate_gpu.py \
  -P /root/bench_setup.py \
  -a > "$PASS1_LOG" 2>&1

# Parse per-frame warmup times from Pass 1 log
declare -A WARMUP_TIMES
PASS1_FRAMES=()
for f in $(seq "$FRAME_START" "$FRAME_INC" "$FRAME_END"); do
  PASS1_FRAMES+=("$f")
done
PASS1_TIMES=()
while IFS= read -r line; do
  PASS1_TIMES+=("$line")
done < <(grep -oP 'Time:\s+\K[0-9]+:[0-9]+\.[0-9]+' "$PASS1_LOG")

for i in "${!PASS1_FRAMES[@]}"; do
  if [ "$i" -lt "${#PASS1_TIMES[@]}" ]; then
    TIME_LINE="${PASS1_TIMES[$i]}"
    MINUTES=$(echo "$TIME_LINE" | cut -d: -f1)
    SECONDS_PART=$(echo "$TIME_LINE" | cut -d: -f2)
    WARMUP_TIMES[${PASS1_FRAMES[$i]}]=$(python3 -c "print(int('${MINUTES}')*60 + float('${SECONDS_PART}'))")
    echo "[Foton] Pass 1 frame ${PASS1_FRAMES[$i]}: ${WARMUP_TIMES[${PASS1_FRAMES[$i]}]}s"
  fi
done

rm -f /root/output/*
echo "[Foton] Pass 1 complete. Warmup times recorded."

# ── Pass 2: N-sample full render + watchdog ──
echo "[Foton] Pass 2: Full render at ${MAX_SAMPLES} samples..."
export BENCH_SAMPLES="$MAX_SAMPLES"
BLENDER_LOG="/root/blender.log"
> "$BLENDER_LOG"

/opt/blender/blender -b "$BLEND_FILE" \
  -P /opt/blender/activate_gpu.py \
  -P /root/bench_setup.py \
  -a > "$BLENDER_LOG" 2>&1 &
BLENDER_PID=$!
echo "[Foton] Blender launched for Pass 2 (PID: $BLENDER_PID)"

EXPECTED_FRAMES=()
for f in $(seq "$FRAME_START" "$FRAME_INC" "$FRAME_END"); do
  EXPECTED_FRAMES+=("$f")
done
TOTAL=${#EXPECTED_FRAMES[@]}
echo "[Foton] Expecting ${TOTAL} frames."

# ── Watchdog Loop ──
NEXT=0
HB_TICK=0
CANCELLED=false
BLENDER_EXIT=0
LOG_OFFSET=0

while true; do
  BLENDER_ALIVE=true
  if ! kill -0 "$BLENDER_PID" 2>/dev/null; then
    BLENDER_ALIVE=false
    wait "$BLENDER_PID" 2>/dev/null
    BLENDER_EXIT=$?
  fi

  while [ "$NEXT" -lt "$TOTAL" ]; do
    FRAME=${EXPECTED_FRAMES[$NEXT]}
    PADDED=$(printf "%04d" "$FRAME")
    FILE="/root/output/${OUTPUT_NAMING}_${PADDED}.${FILE_EXT}"

    [ ! -f "$FILE" ] && break

    SAFE=false
    if [ "$BLENDER_ALIVE" = false ]; then
      SAFE=true
    elif [ $(( NEXT + 1 )) -lt "$TOTAL" ]; then
      NF=${EXPECTED_FRAMES[$(( NEXT + 1 ))]}
      NP=$(printf "%04d" "$NF")
      [ -f "/root/output/${OUTPUT_NAMING}_${NP}.${FILE_EXT}" ] && SAFE=true
    fi
    [ "$SAFE" = false ] && break

    UPLOAD_URL=""
    for RETRY in 1 2 3; do
      UPLOAD_URL=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/frame-upload-url" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"frameNumber\": ${FRAME}}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('uploadUrl') or '')" 2>/dev/null)
      [ -n "$UPLOAD_URL" ] && break
      echo "[Foton] Retry ${RETRY}: failed to get upload URL for frame ${FRAME}"
      sleep 2
    done

    if [ -z "$UPLOAD_URL" ]; then
      echo "[Foton] ERROR: No upload URL for frame ${FRAME} after 3 retries. Aborting."
      kill "$BLENDER_PID" 2>/dev/null
      wait "$BLENDER_PID" 2>/dev/null
      BLENDER_ALIVE=false
      BLENDER_EXIT=1
      break 2
    fi

    UPLOAD_OK=false
    for RETRY in 1 2 3; do
      HTTP_CODE=$(curl -s --connect-timeout 10 --max-time 120 -o /dev/null -w "%{http_code}" -X PUT "$UPLOAD_URL" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${FILE}")
      if [ "$HTTP_CODE" = "200" ]; then
        UPLOAD_OK=true
        break
      fi
      echo "[Foton] Retry ${RETRY}: upload for frame ${FRAME} returned HTTP ${HTTP_CODE}"
      sleep 2
    done

    if [ "$UPLOAD_OK" = false ]; then
      echo "[Foton] ERROR: Upload failed for frame ${FRAME} after 3 retries. Aborting."
      kill "$BLENDER_PID" 2>/dev/null
      wait "$BLENDER_PID" 2>/dev/null
      BLENDER_ALIVE=false
      BLENDER_EXIT=1
      break 2
    fi

    RENDER_TIME=""
    NEW_LOG=$(tail -c +$(( LOG_OFFSET + 1 )) "$BLENDER_LOG" 2>/dev/null)
    LOG_OFFSET=$(wc -c < "$BLENDER_LOG")

    TIME_LINE=$(echo "$NEW_LOG" | grep -oP 'Time:\s+\K[0-9]+:[0-9]+\.[0-9]+' | tail -1)
    if [ -n "$TIME_LINE" ]; then
      MINUTES=$(echo "$TIME_LINE" | cut -d: -f1)
      SECONDS_PART=$(echo "$TIME_LINE" | cut -d: -f2)
      RENDER_TIME=$(python3 -c "print(int('${MINUTES}')*60 + float('${SECONDS_PART}'))")
    fi

    FRAME_WARMUP="${WARMUP_TIMES[$FRAME]:-}"

    if [ -n "$RENDER_TIME" ] && [ -n "$FRAME_WARMUP" ]; then
      curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/progress" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"currentFrame\":${FRAME},\"completedFrame\":${FRAME},\"renderTime\":${RENDER_TIME},\"warmupTime\":${FRAME_WARMUP}}" > /dev/null
    elif [ -n "$RENDER_TIME" ]; then
      curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/progress" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"currentFrame\":${FRAME},\"completedFrame\":${FRAME},\"renderTime\":${RENDER_TIME}}" > /dev/null
    else
      curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/progress" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"currentFrame\":${FRAME},\"completedFrame\":${FRAME}}" > /dev/null
    fi

    rm -f "$FILE"
    NEXT=$(( NEXT + 1 ))
    echo "[Foton] Frame ${FRAME} uploaded. (${NEXT}/${TOTAL}${RENDER_TIME:+, ${RENDER_TIME}s}${FRAME_WARMUP:+, warmup=${FRAME_WARMUP}s})"
  done

  if [ "$NEXT" -ge "$TOTAL" ]; then
    echo "[Foton] All ${TOTAL} benchmark frames uploaded."
    break
  fi

  if [ "$BLENDER_ALIVE" = false ]; then
    if [ "$BLENDER_EXIT" -ne 0 ]; then
      echo "[Foton] Blender crashed (exit code ${BLENDER_EXIT}). ${NEXT}/${TOTAL} frames uploaded."
    else
      echo "[Foton] Blender finished but only ${NEXT}/${TOTAL} frames were found."
    fi
    break
  fi

  HB_TICK=$(( HB_TICK + 1 ))
  if [ "$HB_TICK" -ge 10 ]; then
    HB_TICK=0
    BENCH_GPU_STATS=$(collect_gpu_stats)
    HB_ACTION=$(curl -s --connect-timeout 5 --max-time 15 -X POST "${FOTON_API_URL}/instances/heartbeat" \
      -H "Content-Type: application/json" \
      -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"gpuStats\": ${BENCH_GPU_STATS}}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('action') or '')" 2>/dev/null)
    if [ "$HB_ACTION" = "shutdown" ]; then
      echo "[Foton] Shutdown signal received. Killing Blender..."
      kill "$BLENDER_PID" 2>/dev/null
      wait "$BLENDER_PID" 2>/dev/null
      CANCELLED=true
      break
    fi
  fi

  sleep 2
done

kill "$LOG_PUSHER_PID" 2>/dev/null
push_logs

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$CANCELLED" = true ]; then
  echo "[Foton] Benchmark was cancelled. Exiting."
  exit 0
fi

if [ "$NEXT" -ge "$TOTAL" ]; then
  FINAL_STATUS="completed"
else
  FINAL_STATUS="failed"
fi

echo "[Foton] Benchmark reporting: ${FINAL_STATUS}"

for ATTEMPT in 1 2 3; do
  HTTP_STATUS=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w "%{http_code}" -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"status\": \"${FINAL_STATUS}\"}")

  if [ "$HTTP_STATUS" = "200" ]; then
    echo "[Foton] Benchmark ${FINAL_STATUS}. Instance will be destroyed by API."
    break
  else
    echo "[Foton] WARNING: Final report attempt ${ATTEMPT} failed (HTTP ${HTTP_STATUS})"
    sleep 5
  fi
done

echo "[Foton] Done."
exit 0

fi

# ═══════════════════════════════════════════════════════════════
# 4. DOWNLOAD PROJECT FILES
# ═══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 DOWNLOADING PROJECT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

report_status "downloading"

RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/report" \
  -H "Content-Type: application/json" \
  -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"blendDownloaded\": false}")

BLEND_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendUrl') or '')" 2>/dev/null)

POLL_COUNT=0
while [ -z "$BLEND_URL" ]; do
    POLL_COUNT=$(( POLL_COUNT + 1 ))
    echo "[Foton] Waiting for upload... (attempt ${POLL_COUNT})"
    sleep 5
    BLEND_URL=$(curl -s --connect-timeout 10 --max-time 30 "${FOTON_API_URL}/instances/blend-url?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendUrl') or '')" 2>/dev/null)
done

if [ "$UPLOAD_TYPE" = "blend" ]; then
  HTTP_CODE=$(curl -s --connect-timeout 15 --max-time 600 -o /root/scene.blend -w "%{http_code}" "$BLEND_URL")
  if [ "$HTTP_CODE" != "200" ]; then
    echo "[Foton] FATAL: Download failed (HTTP $HTTP_CODE)"
    report_status "failed"
    exit 1
  fi
  BLEND_FILE="/root/scene.blend"
  echo "[Foton] Project file downloaded ($(du -h "$BLEND_FILE" | cut -f1))."
else
  ARCHIVE_FILE="/root/project_archive"
  HTTP_CODE=$(curl -s --connect-timeout 15 --max-time 1800 -o "$ARCHIVE_FILE" -w "%{http_code}" "$BLEND_URL")
  if [ "$HTTP_CODE" != "200" ]; then
    echo "[Foton] FATAL: Archive download failed (HTTP $HTTP_CODE)"
    report_status "failed"
    exit 1
  fi

  ARCHIVE_SIZE_BYTES=$(stat -c%s "$ARCHIVE_FILE" 2>/dev/null || stat -f%z "$ARCHIVE_FILE" 2>/dev/null)
  if [ "$ARCHIVE_SIZE_BYTES" -lt 10240 ]; then
    echo "[Foton] FATAL: File too small, likely error response"
    report_status "failed"
    exit 1
  fi

  mkdir -p /root/project
  EXTRACT_OK=false
  if echo "$BLEND_URL" | grep -q '\.tar\.zst'; then
    tar -I zstd -xf "$ARCHIVE_FILE" -C /root/project && EXTRACT_OK=true
  elif echo "$BLEND_URL" | grep -q '\.tar\.gz'; then
    tar -xzf "$ARCHIVE_FILE" -C /root/project && EXTRACT_OK=true
  elif file "$ARCHIVE_FILE" | grep -q -i "zstandard"; then
    tar -I zstd -xf "$ARCHIVE_FILE" -C /root/project && EXTRACT_OK=true
  else
    tar -xzf "$ARCHIVE_FILE" -C /root/project && EXTRACT_OK=true
  fi

  if [ "$EXTRACT_OK" != "true" ]; then
    echo "[Foton] FATAL: Extraction failed"
    report_status "failed"
    exit 1
  fi

  rm -f "$ARCHIVE_FILE"
  BLEND_FILE="/root/project/${BLEND_RELATIVE_PATH}"
  echo "[Foton] Project extracted. Blend: ${BLEND_FILE}"
fi

curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/report" \
  -H "Content-Type: application/json" \
  -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"blendDownloaded\": true}" > /dev/null

rm /root/installing
touch /root/ready
echo "[Foton] Ready."

# ═══════════════════════════════════════════════════════════════
# 5. DETECT GPUs + REGISTER SESSIONS
# ═══════════════════════════════════════════════════════════════

GPU_COUNT=1
if command -v nvidia-smi &> /dev/null; then
  GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)
fi
echo "[Foton] Detected ${GPU_COUNT} GPU(s)."

# Register workers with API → get session indices + epoch
REG_RESP=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/register-workers" \
  -H "Content-Type: application/json" \
  -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"gpuCount\": ${GPU_COUNT}}")

SESSION_INDICES=$(echo "$REG_RESP" | python3 -c "import sys,json; print(' '.join(str(i) for i in json.load(sys.stdin)['sessionIndices']))")
CURRENT_EPOCH=$(echo "$REG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['epoch'])")
TOTAL_SESSIONS=$(echo "$REG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['totalSessions'])")

echo "[Foton] Registered sessions: [${SESSION_INDICES}], total=${TOTAL_SESSIONS}, epoch=${CURRENT_EPOCH}"

# ═══════════════════════════════════════════════════════════════
# 6. GPU WORKER FUNCTION (Session + Watchdog)
# ═══════════════════════════════════════════════════════════════

mkdir -p /root/output

# gpu_worker GPU_IDX SESSION_IDX W_FRAME_START W_FRAME_END W_FRAME_STEP
gpu_worker() {
  local GPU_IDX=$1
  local SESSION_IDX=$2
  local W_FRAME_START=$3
  local W_FRAME_END=$4
  local W_FRAME_STEP=$5

  local WORKER_LOG="/root/blender_gpu${GPU_IDX}.log"

  echo "[GPU${GPU_IDX}] Session ${SESSION_IDX}: frames ${W_FRAME_START}-${W_FRAME_END} step ${W_FRAME_STEP}"

  # Skip if start > end (no frames for this session)
  if [ "$W_FRAME_START" -gt "$W_FRAME_END" ]; then
    echo "[GPU${GPU_IDX}] No frames to render."
    return
  fi

  # Create per-GPU render setup script
  cat > /root/render_setup_gpu${GPU_IDX}.py << PYEOF
import bpy, os, sys

scene = bpy.context.scene
scene.render.resolution_x = ${RES_X}
scene.render.resolution_y = ${RES_Y}
scene.render.resolution_percentage = 100
scene.frame_start = ${W_FRAME_START}
scene.frame_end = ${W_FRAME_END}
scene.frame_step = ${W_FRAME_STEP}

CAMERA = "${CAMERA}"
if CAMERA and CAMERA in bpy.data.objects:
    scene.camera = bpy.data.objects[CAMERA]

ENGINE = "${RENDER_ENGINE}"
if ENGINE:
    scene.render.engine = ENGINE

SAMPLES = ${MAX_SAMPLES}
if SAMPLES > 0:
    if ENGINE == 'CYCLES':
        scene.cycles.samples = SAMPLES
        scene.cycles.device = 'GPU'
    elif ENGINE in ('BLENDER_EEVEE', 'BLENDER_EEVEE_NEXT'):
        scene.eevee.taa_render_samples = SAMPLES

scene.render.image_settings.file_format = "${BLENDER_FORMAT}"
scene.render.filepath = "/root/output/${OUTPUT_NAMING}_"
scene.render.use_file_extension = True

print(f"[GPU${GPU_IDX}] Configured: frames {scene.frame_start}-{scene.frame_end} step {scene.frame_step}")

# List all enabled add-ons
enabled = [mod.module for mod in bpy.context.preferences.addons]
print(f"[GPU${GPU_IDX}] Active add-ons ({len(enabled)}): {', '.join(sorted(enabled))}")
PYEOF

  # Launch Blender in background with -a (animation render)
  > "$WORKER_LOG"
  CUDA_VISIBLE_DEVICES=$GPU_IDX /opt/blender/blender -b "$BLEND_FILE" \
    -P /opt/blender/activate_gpu.py \
    -P /root/render_setup_gpu${GPU_IDX}.py \
    -a > "$WORKER_LOG" 2>&1 &
  local BLENDER_PID=$!
  echo "[GPU${GPU_IDX}] Blender launched (PID: $BLENDER_PID)"

  # Build expected frame list for this session
  local EXPECTED_FRAMES=()
  for f in $(seq "$W_FRAME_START" "$W_FRAME_STEP" "$W_FRAME_END"); do
    EXPECTED_FRAMES+=("$f")
  done
  local TOTAL_EXPECTED=${#EXPECTED_FRAMES[@]}
  echo "[GPU${GPU_IDX}] Expecting ${TOTAL_EXPECTED} frames"

  # ── Watchdog Loop ──
  local NEXT=0
  local LOG_OFFSET=0

  while true; do
    # Check if Blender is still running
    local BLENDER_ALIVE=true
    if ! kill -0 "$BLENDER_PID" 2>/dev/null; then
      BLENDER_ALIVE=false
      wait "$BLENDER_PID" 2>/dev/null
    fi

    # Upload all safe frames
    while [ "$NEXT" -lt "$TOTAL_EXPECTED" ]; do
      local FRAME=${EXPECTED_FRAMES[$NEXT]}
      local PADDED=$(printf "%04d" "$FRAME")
      local FILE="/root/output/${OUTPUT_NAMING}_${PADDED}.${FILE_EXT}"

      [ ! -f "$FILE" ] && break

      # Safe-gap: only upload if next frame exists too OR Blender exited
      local SAFE=false
      if [ "$BLENDER_ALIVE" = false ]; then
        SAFE=true
      elif [ $(( NEXT + 1 )) -lt "$TOTAL_EXPECTED" ]; then
        local NF=${EXPECTED_FRAMES[$(( NEXT + 1 ))]}
        local NP=$(printf "%04d" "$NF")
        [ -f "/root/output/${OUTPUT_NAMING}_${NP}.${FILE_EXT}" ] && SAFE=true
      fi
      [ "$SAFE" = false ] && break

      # Get upload URL
      local UPLOAD_URL=""
      for RETRY in 1 2 3; do
        UPLOAD_URL=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/frame-upload-url" \
          -H "Content-Type: application/json" \
          -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"frameNumber\": ${FRAME}}" \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('uploadUrl') or '')" 2>/dev/null)
        [ -n "$UPLOAD_URL" ] && break
        sleep 2
      done

      if [ -z "$UPLOAD_URL" ]; then
        echo "[GPU${GPU_IDX}] ERROR: No upload URL for frame ${FRAME}"
        break 2
      fi

      # Upload
      local FILE_SIZE=$(du -h "$FILE" | cut -f1)
      local UPLOAD_OK=false
      for RETRY in 1 2 3; do
        HTTP_CODE=$(curl -s --connect-timeout 10 --max-time 120 -o /dev/null -w "%{http_code}" -X PUT "$UPLOAD_URL" \
          -H "Content-Type: application/octet-stream" \
          --data-binary "@${FILE}")
        if [ "$HTTP_CODE" = "200" ]; then
          UPLOAD_OK=true
          echo "[GPU${GPU_IDX}] Frame ${FRAME} uploaded to R2 (${FILE_SIZE})"
          break
        fi
        echo "[GPU${GPU_IDX}] Retry ${RETRY}: upload for frame ${FRAME} returned HTTP ${HTTP_CODE}"
        sleep 2
      done

      if [ "$UPLOAD_OK" = false ]; then
        echo "[GPU${GPU_IDX}] ERROR: Upload failed for frame ${FRAME} after 3 retries"
        break 2
      fi

      # Parse render time from log
      local RENDER_TIME=""
      local NEW_LOG=$(tail -c +$(( LOG_OFFSET + 1 )) "$WORKER_LOG" 2>/dev/null)
      LOG_OFFSET=$(wc -c < "$WORKER_LOG")
      local TIME_LINE=$(echo "$NEW_LOG" | grep -oP 'Time:\s+\K[0-9]+:[0-9]+\.[0-9]+' | tail -1)
      if [ -n "$TIME_LINE" ]; then
        local MINUTES=$(echo "$TIME_LINE" | cut -d: -f1)
        local SECONDS_PART=$(echo "$TIME_LINE" | cut -d: -f2)
        RENDER_TIME=$(python3 -c "print(int('${MINUTES}')*60 + float('${SECONDS_PART}'))")
      fi

      # Report progress (with retry + verification)
      local PROGRESS_OK=false
      for RETRY in 1 2 3; do
        local PROGRESS_RESP
        if [ -n "$RENDER_TIME" ]; then
          PROGRESS_RESP=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/progress" \
            -H "Content-Type: application/json" \
            -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"currentFrame\":${FRAME},\"completedFrame\":${FRAME},\"renderTime\":${RENDER_TIME}}")
        else
          PROGRESS_RESP=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/progress" \
            -H "Content-Type: application/json" \
            -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"currentFrame\":${FRAME},\"completedFrame\":${FRAME}}")
        fi
        local PROGRESS_SUCCESS=$(echo "$PROGRESS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
        if [ "$PROGRESS_SUCCESS" = "True" ]; then
          PROGRESS_OK=true
          break
        fi
        echo "[GPU${GPU_IDX}] Retry ${RETRY}: progress report for frame ${FRAME} not acknowledged"
        sleep 2
      done
      if [ "$PROGRESS_OK" = false ]; then
        echo "[GPU${GPU_IDX}] WARNING: Progress report for frame ${FRAME} failed after 3 retries"
      fi

      # Remove from active frames tracking
      curl -s --connect-timeout 5 --max-time 15 -X POST "${FOTON_API_URL}/instances/frame-rendered" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"frame\":${FRAME},\"gpuIndex\":${GPU_IDX}}" > /dev/null

      rm -f "$FILE"
      NEXT=$(( NEXT + 1 ))
      echo "[GPU${GPU_IDX}] Frame ${FRAME} done. (${NEXT}/${TOTAL_EXPECTED}${RENDER_TIME:+, ${RENDER_TIME}s})"
    done

    # Exit conditions
    if [ "$NEXT" -ge "$TOTAL_EXPECTED" ]; then
      echo "[GPU${GPU_IDX}] All ${TOTAL_EXPECTED} frames complete."
      break
    fi

    if [ "$BLENDER_ALIVE" = false ]; then
      echo "[GPU${GPU_IDX}] Blender exited. ${NEXT}/${TOTAL_EXPECTED} frames uploaded."
      break
    fi

    # Check if we should stop (rebalance signal via temp file from main loop)
    if [ -f "/tmp/foton_rebalance" ]; then
      echo "[GPU${GPU_IDX}] Rebalance signal. Stopping Blender..."
      kill "$BLENDER_PID" 2>/dev/null
      wait "$BLENDER_PID" 2>/dev/null
      break
    fi

    sleep 2
  done
}

# ═══════════════════════════════════════════════════════════════
# 7. MAIN RENDER LOOP (with rebalancing)
# ═══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎬 RENDERING (${GPU_COUNT} GPUs, ${TOTAL_SESSIONS} total sessions)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

report_status "rendering"

CANCELLED=false

while true; do
  rm -f /tmp/foton_rebalance

  # Fetch session configs for our GPUs
  WORKER_PIDS=()
  IDX=0
  for SI in $SESSION_INDICES; do
    # Get this session's frame assignment
    SCFG=$(curl -s --connect-timeout 10 --max-time 30 \
      "${FOTON_API_URL}/instances/session-config?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}&sessionIndex=${SI}")

    W_START=$(echo "$SCFG" | python3 -c "import sys,json; print(json.load(sys.stdin)['frameStart'])")
    W_END=$(echo "$SCFG"   | python3 -c "import sys,json; print(json.load(sys.stdin)['frameEnd'])")
    W_STEP=$(echo "$SCFG"  | python3 -c "import sys,json; print(json.load(sys.stdin)['frameStep'])")

    # Launch worker
    gpu_worker $IDX $SI $W_START $W_END $W_STEP &
    WORKER_PIDS+=($!)
    echo "[Foton] Worker GPU${IDX} → session ${SI} (PID: ${WORKER_PIDS[-1]})"

    IDX=$(( IDX + 1 ))
  done

  # ── Monitor loop: heartbeat + rebalance detection ──
  REBALANCE=false
  HB_COUNTER=0

  while true; do
    # Check if all workers are done
    ALL_DONE=true
    for PID in "${WORKER_PIDS[@]}"; do
      if kill -0 "$PID" 2>/dev/null; then
        ALL_DONE=false
        break
      fi
    done
    if [ "$ALL_DONE" = true ]; then
      break
    fi

    # Heartbeat with GPU stats (~every 12 seconds = 6 * 2s sleep)
    HB_COUNTER=$(( HB_COUNTER + 1 ))
    if [ "$HB_COUNTER" -ge 6 ]; then
      HB_COUNTER=0
      GPU_STATS=$(collect_gpu_stats)
      HB_RESP=$(curl -s --connect-timeout 5 --max-time 15 -X POST "${FOTON_API_URL}/instances/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"gpuStats\": ${GPU_STATS}}")

      # Check cancellation
      HB_ACTION=$(echo "$HB_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action') or '')" 2>/dev/null)
      if [ "$HB_ACTION" = "shutdown" ]; then
        echo "[Foton] Shutdown signal. Killing workers..."
        touch /tmp/foton_rebalance  # signal workers to stop
        sleep 1
        for PID in "${WORKER_PIDS[@]}"; do kill "$PID" 2>/dev/null; done
        CANCELLED=true
        break
      fi

      # Check rebalance (epoch changed)
      NEW_EPOCH=$(echo "$HB_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('epoch', 0))" 2>/dev/null)
      if [ -n "$NEW_EPOCH" ] && [ "$NEW_EPOCH" != "$CURRENT_EPOCH" ]; then
        echo "[Foton] Epoch changed ${CURRENT_EPOCH} → ${NEW_EPOCH}. Rebalancing..."
        CURRENT_EPOCH="$NEW_EPOCH"
        REBALANCE=true

        # Signal workers to stop
        touch /tmp/foton_rebalance
        sleep 3  # give workers time to notice and upload current frame

        # Kill any remaining Blender processes
        for PID in "${WORKER_PIDS[@]}"; do kill "$PID" 2>/dev/null; done
        for PID in "${WORKER_PIDS[@]}"; do wait "$PID" 2>/dev/null; done
        break
      fi
    fi

    sleep 2
  done

  # Wait for all workers to fully exit
  for PID in "${WORKER_PIDS[@]}"; do
    wait "$PID" 2>/dev/null
  done

  if [ "$CANCELLED" = true ]; then
    break
  fi

  if [ "$REBALANCE" = true ]; then
    echo "[Foton] Getting new session configs after rebalance..."
    # Clean up partial output
    rm -f /root/output/*
    continue  # restart the outer loop with new configs
  fi

  # Normal completion — all workers finished
  break
done

# Kill background processes
kill "$LOG_PUSHER_PID" 2>/dev/null
push_logs

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════
# 8. REPORT FINAL STATUS
# ═══════════════════════════════════════════════════════════════

if [ "$CANCELLED" = true ]; then
  echo "[Foton] Task was cancelled."
  exit 0
fi

# Check completion and sweep for missing frames
FINAL_CHECK=$(curl -s "${FOTON_API_URL}/instances/render-config?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}")
COMPLETED_FRAMES_JSON=$(echo "$FINAL_CHECK" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('completedFrames',[])))" 2>/dev/null)
COMPLETED_COUNT=$(echo "$COMPLETED_FRAMES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)

if [ "$COMPLETED_COUNT" -lt "$TOTAL_FRAMES" ]; then
  echo "[Foton] Only ${COMPLETED_COUNT}/${TOTAL_FRAMES} acknowledged. Sweeping for missing frames..."

  # Find which frames are missing and re-report them
  MISSING_FRAMES=$(python3 -c "
import json
completed = set(json.loads('${COMPLETED_FRAMES_JSON}'))
all_frames = list(range(${FRAME_START}, ${FRAME_END} + 1, ${FRAME_INC}))
missing = [f for f in all_frames if f not in completed]
print(' '.join(str(f) for f in missing))
" 2>/dev/null)

  RECOVERED=0
  for FRAME in $MISSING_FRAMES; do
    echo "[Foton] Re-reporting frame ${FRAME}..."
    for RETRY in 1 2 3; do
      RESP=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/progress" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"currentFrame\":${FRAME},\"completedFrame\":${FRAME}}")
      SUCCESS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
      if [ "$SUCCESS" = "True" ]; then
        RECOVERED=$(( RECOVERED + 1 ))
        echo "[Foton] Frame ${FRAME} recovered."
        break
      fi
      sleep 2
    done
  done

  # Re-check after sweep
  COMPLETED_COUNT=$(( COMPLETED_COUNT + RECOVERED ))
  echo "[Foton] After sweep: ${COMPLETED_COUNT}/${TOTAL_FRAMES} frames acknowledged (recovered ${RECOVERED})."
fi

if [ "$COMPLETED_COUNT" -ge "$TOTAL_FRAMES" ]; then
  FINAL_STATUS="completed"
else
  FINAL_STATUS="failed"
  echo "[Foton] Still missing $(( TOTAL_FRAMES - COMPLETED_COUNT )) frames after sweep."
fi

echo "[Foton] Reporting: ${FINAL_STATUS}"

for ATTEMPT in 1 2 3; do
  HTTP_STATUS=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w "%{http_code}" -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"status\": \"${FINAL_STATUS}\"}")
  if [ "$HTTP_STATUS" = "200" ]; then
    echo "[Foton] Reported: ${FINAL_STATUS}."
    break
  fi
  sleep 5
done

echo "[Foton] Done."
