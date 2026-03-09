#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# FOTONLABS PROVISIONING PROTOCOL — Watchdog Architecture
# ═══════════════════════════════════════════════════════════════
#
# Blender renders all frames natively via the -a flag (zero overhead).
# A parallel watcher loop detects completed frames on disk, uploads
# them to R2, reports progress, and handles cancellation.
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

# ═══════════════════════════════════════════════════════════════
# 1. IGNITING THRUSTERS (Booting Up)
# ═══════════════════════════════════════════════════════════════

touch /root/installing
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚡ IGNITING THRUSTERS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "[Foton] Instance booted. Task: ${FOTON_TASK_ID}"

# Report booting immediately so the app knows we're alive
report_status "booting"
echo "[Foton] Status → booting"

# Start SSH
mkdir -p /var/run/sshd
service ssh start
echo "[Foton] SSH service started."

# ── Log Pusher (sends new log bytes to API every 5s) ──

PROV_LOG_FILE="/var/log/portal/provisioning.log"
BLENDER_LOG_FILE="/root/blender.log"

# Use temp files for offsets so background subshell and main script stay in sync
echo 0 > /tmp/prov_log_offset
echo 0 > /tmp/blender_log_offset

push_logs() {
  # Push provisioning log
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

  # Push blender log
  if [ -f "$BLENDER_LOG_FILE" ]; then
    local BL_OFFSET=$(cat /tmp/blender_log_offset)
    local BLENDER_SIZE=$(wc -c < "$BLENDER_LOG_FILE")
    if [ "$BLENDER_SIZE" -gt "$BL_OFFSET" ]; then
      local BLENDER_CHUNK=$(tail -c +$(( BL_OFFSET + 1 )) "$BLENDER_LOG_FILE")
      if [ -n "$BLENDER_CHUNK" ]; then
        local ESCAPED=$(python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" <<< "$BLENDER_CHUNK")
        curl -s --connect-timeout 5 --max-time 15 -X POST "${FOTON_API_URL}/instances/logs" \
          -H "Content-Type: application/json" \
          -d "{\"taskId\":\"${FOTON_TASK_ID}\",\"token\":\"${FOTON_INSTANCE_TOKEN}\",\"type\":\"blender\",\"content\":${ESCAPED}}" > /dev/null 2>&1
        echo "$BLENDER_SIZE" > /tmp/blender_log_offset
      fi
    fi
  fi
}

if [ -n "$FOTON_API_URL" ]; then
  (while true; do
    push_logs
    sleep 5
  done) &
  LOG_PUSHER_PID=$!
  echo "[Foton] Log pusher active (every 5s)."
fi

# ── Heartbeat (background keep-alive ping) ──

if [ -n "$FOTON_API_URL" ]; then
  (while true; do
      curl -s --connect-timeout 5 --max-time 15 -X POST "${FOTON_API_URL}/instances/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\"}" > /dev/null
      sleep 20
  done) &
  HEARTBEAT_PID=$!
  echo "[Foton] Heartbeat active."
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

echo "[Foton] Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq wget xz-utils libgl1 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxxf86vm1 libsm6 libxext6 openssh-server python3 curl
echo "[Foton] System dependencies installed."

if [ ! -d "/opt/blender" ]; then
  echo "[Foton] Downloading Blender 5.0.1..."
  wget -q --show-progress https://download.blender.org/release/Blender5.0/blender-5.0.1-linux-x64.tar.xz 2>&1 | \
    while IFS= read -r line; do echo "[Foton] $line"; done

  echo "[Foton] Extracting Blender..."
  tar -xf blender-5.0.1-linux-x64.tar.xz
  mv blender-5.0.1-linux-x64 /opt/blender
  rm blender-5.0.1-linux-x64.tar.xz
  echo "[Foton] Blender 5.0.1 installed."
else
  echo "[Foton] Blender already installed. Skipping download."
fi

echo "[Foton] Fetching GPU activation script..."
wget -q -O /opt/blender/activate_gpu.py https://raw.githubusercontent.com/aaryansachdeva/fotonRenderStartupScripts/refs/heads/main/activate_gpu.py
echo "[Foton] GPU activation script ready."

echo "[Foton] All systems onboarded."

# ═══════════════════════════════════════════════════════════════
# 3. FETCH RENDER CONFIG (needed before download to know upload type)
# ═══════════════════════════════════════════════════════════════

if [ -z "$FOTON_API_URL" ]; then
  echo "[Foton] No API URL set. Skipping render."
  exit 0
fi

echo ""
echo "[Foton] Fetching render config..."
CONFIG=$(curl -s "${FOTON_API_URL}/instances/render-config?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}")

export FRAME_START=$(echo "$CONFIG"  | python3 -c "import sys,json; print(json.load(sys.stdin)['frameStart'])")
export FRAME_END=$(echo "$CONFIG"    | python3 -c "import sys,json; print(json.load(sys.stdin)['frameEnd'])")
export FRAME_INC=$(echo "$CONFIG"    | python3 -c "import sys,json; print(json.load(sys.stdin)['frameIncrement'])")
export RES_X=$(echo "$CONFIG"        | python3 -c "import sys,json; print(json.load(sys.stdin)['resolutionX'])")
export RES_Y=$(echo "$CONFIG"        | python3 -c "import sys,json; print(json.load(sys.stdin)['resolutionY'])")
export CAMERA=$(echo "$CONFIG"       | python3 -c "import sys,json; print(json.load(sys.stdin)['camera'])")
export RENDER_ENGINE=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin)['renderEngine'])")
export FILE_EXT=$(echo "$CONFIG"     | python3 -c "import sys,json; print(json.load(sys.stdin)['fileExtension'])")
export OUTPUT_NAMING=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin)['outputFileNaming'])")
export MAX_SAMPLES=$(echo "$CONFIG"  | python3 -c "import sys,json; print(json.load(sys.stdin)['maxSamples'])")
export UPLOAD_TYPE=$(echo "$CONFIG"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('uploadType') or 'blend')" 2>/dev/null)
export BLEND_RELATIVE_PATH=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendRelativePath') or '')" 2>/dev/null)

# ═══════════════════════════════════════════════════════════════
# 4. ACCESSING IMPERIAL BLUEPRINTS (Downloading Project Files)
# ═══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 ACCESSING IMPERIAL BLUEPRINTS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

report_status "downloading"
echo "[Foton] Status → downloading"

if [ -n "$FOTON_API_URL" ]; then
  # Get blend download URL
  RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"blendDownloaded\": false}")

  BLEND_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendUrl') or '')" 2>/dev/null)

  # If upload isn't done yet, poll until it is
  POLL_COUNT=0
  while [ -z "$BLEND_URL" ]; do
      POLL_COUNT=$(( POLL_COUNT + 1 ))
      echo "[Foton] Waiting for project file upload... (attempt ${POLL_COUNT})"
      sleep 5
      BLEND_URL=$(curl -s --connect-timeout 10 --max-time 30 "${FOTON_API_URL}/instances/blend-url?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendUrl') or '')" 2>/dev/null)
  done

  if [ "$UPLOAD_TYPE" = "project" ]; then
    # Project flow: download tar.gz → extract to /root/project/
    echo "[Foton] Downloading project archive..."
    curl -# --connect-timeout 15 --max-time 1800 -o /root/project.tar.gz "$BLEND_URL" 2>&1 | while IFS= read -r line; do echo "[Foton] $line"; done

    ARCHIVE_SIZE=$(du -h /root/project.tar.gz | cut -f1)
    echo "[Foton] Project archive downloaded (${ARCHIVE_SIZE}). Extracting..."

    mkdir -p /root/project
    tar -xzf /root/project.tar.gz -C /root/project
    rm -f /root/project.tar.gz

    BLEND_FILE="/root/project/${BLEND_RELATIVE_PATH}"
    echo "[Foton] Project extracted. Blend file: ${BLEND_FILE}"
  else
    # Single file flow: download as scene.blend
    echo "[Foton] Downloading project file..."
    curl -# --connect-timeout 15 --max-time 600 -o /root/scene.blend "$BLEND_URL" 2>&1 | while IFS= read -r line; do echo "[Foton] $line"; done

    BLEND_SIZE=$(du -h /root/scene.blend | cut -f1)
    echo "[Foton] Project file downloaded (${BLEND_SIZE})."
    BLEND_FILE="/root/scene.blend"
  fi

  # Report blend downloaded
  curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"blendDownloaded\": true}" > /dev/null
  echo "[Foton] Imperial blueprints secured."
fi

rm /root/installing
touch /root/ready
echo "[Foton] Node fully provisioned and ready."

# ── Skip completed frames on recovery ──
# Build a set of completed frame numbers so we can skip them individually
# (not just max — there may be gaps where progress reports were lost)
COMPLETED_SET=$(echo "$CONFIG" | python3 -c "
import sys,json
cf = json.load(sys.stdin).get('completedFrames', [])
print(' '.join(str(f) for f in cf))
" 2>/dev/null)

if [ -n "$COMPLETED_SET" ]; then
  # Store completed frames in an associative array for O(1) lookup
  declare -A COMPLETED_MAP
  COMPLETED_COUNT=0
  for f in $COMPLETED_SET; do
    COMPLETED_MAP[$f]=1
    COMPLETED_COUNT=$(( COMPLETED_COUNT + 1 ))
  done

  # Count total expected frames
  TOTAL_EXPECTED=0
  for f in $(seq "$FRAME_START" "$FRAME_INC" "$FRAME_END"); do
    TOTAL_EXPECTED=$(( TOTAL_EXPECTED + 1 ))
  done

  echo "[Foton] Recovery: ${COMPLETED_COUNT}/${TOTAL_EXPECTED} frames already completed"

  if [ "$COMPLETED_COUNT" -ge "$TOTAL_EXPECTED" ]; then
    echo "[Foton] All frames already completed!"
    report_status "completed"
    exit 0
  fi

  # Find the earliest missing frame to set as FRAME_START for Blender
  for f in $(seq "$FRAME_START" "$FRAME_INC" "$FRAME_END"); do
    if [ "${COMPLETED_MAP[$f]:-0}" != "1" ]; then
      FRAME_START=$f
      break
    fi
  done
  echo "[Foton] Blender will start from frame ${FRAME_START}"

  # Export the set so the watchdog loop can skip completed frames
  export RECOVERY_MODE=1
fi

export IS_BENCHMARK=$(echo "$CONFIG" | python3 -c "import sys,json; print(1 if json.load(sys.stdin).get('isBenchmark') else 0)")

echo "[Foton] Config: frames ${FRAME_START}-${FRAME_END} (step ${FRAME_INC}), ${RES_X}x${RES_Y}, engine=${RENDER_ENGINE}, camera=${CAMERA}, samples=${MAX_SAMPLES}, benchmark=${IS_BENCHMARK}"

# Map file extension to Blender format string
# Also normalize FILE_EXT to match what Blender actually writes on disk
case "$FILE_EXT" in
  exr)      export BLENDER_FORMAT="OPEN_EXR" ;;
  png)      export BLENDER_FORMAT="PNG" ;;
  jpeg|jpg) export BLENDER_FORMAT="JPEG"; FILE_EXT="jpg" ;;
  tiff|tif) export BLENDER_FORMAT="TIFF"; FILE_EXT="tif" ;;
  *)        export BLENDER_FORMAT="PNG"; FILE_EXT="png" ;;
esac

# ═══════════════════════════════════════════════════════════════
# BENCHMARK TWO-PASS MODE
# ═══════════════════════════════════════════════════════════════

if [ "$IS_BENCHMARK" = "1" ]; then

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 BENCHMARK MODE (Two-Pass)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p /root/output

# Create setup script for benchmark (same as normal but parameterised samples)
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
rm -f /root/output/*  # Discard warmup output

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
# Extract all Time: entries from the pass1 log
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

# Delete 1-sample output files
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

# Build expected frames
EXPECTED_FRAMES=()
for f in $(seq "$FRAME_START" "$FRAME_INC" "$FRAME_END"); do
  EXPECTED_FRAMES+=("$f")
done
TOTAL=${#EXPECTED_FRAMES[@]}
echo "[Foton] Expecting ${TOTAL} frames."

# ── Watchdog Loop (same as normal render) ──
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

    # Get presigned upload URL
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

    # Upload file
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

    # Parse render time from log
    RENDER_TIME=""
    NEW_LOG=$(tail -c +$(( LOG_OFFSET + 1 )) "$BLENDER_LOG" 2>/dev/null)
    LOG_OFFSET=$(wc -c < "$BLENDER_LOG")

    TIME_LINE=$(echo "$NEW_LOG" | grep -oP 'Time:\s+\K[0-9]+:[0-9]+\.[0-9]+' | tail -1)
    if [ -n "$TIME_LINE" ]; then
      MINUTES=$(echo "$TIME_LINE" | cut -d: -f1)
      SECONDS_PART=$(echo "$TIME_LINE" | cut -d: -f2)
      RENDER_TIME=$(python3 -c "print(int('${MINUTES}')*60 + float('${SECONDS_PART}'))")
    fi

    # Get warmup time for this frame
    FRAME_WARMUP="${WARMUP_TIMES[$FRAME]:-}"

    # Report progress with warmupTime
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
    HB_ACTION=$(curl -s --connect-timeout 5 --max-time 15 -X POST "${FOTON_API_URL}/instances/heartbeat" \
      -H "Content-Type: application/json" \
      -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\"}" \
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

# Kill background processes
kill "$HEARTBEAT_PID" 2>/dev/null
kill "$LOG_PUSHER_PID" 2>/dev/null

# Final log push to capture last lines
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
# 5. CREATE SCENE SETUP SCRIPT (Normal Render)
# ═══════════════════════════════════════════════════════════════

mkdir -p /root/output

cat > /root/render_setup.py << 'PYEOF'
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
SAMPLES = int(env('MAX_SAMPLES'))
FILE_FORMAT = env('BLENDER_FORMAT')
OUTPUT_NAMING = env('OUTPUT_NAMING')

scene = bpy.context.scene

# Resolution
scene.render.resolution_x = RES_X
scene.render.resolution_y = RES_Y
scene.render.resolution_percentage = 100

# Frame range — the -a flag uses these scene properties
scene.frame_start = FRAME_START
scene.frame_end = FRAME_END
scene.frame_step = FRAME_INC

# Camera
if CAMERA and CAMERA in bpy.data.objects:
    scene.camera = bpy.data.objects[CAMERA]

# Render engine
if ENGINE:
    scene.render.engine = ENGINE

# Samples
if SAMPLES > 0:
    if ENGINE == 'CYCLES':
        scene.cycles.samples = SAMPLES
        scene.cycles.device = 'GPU'
    elif ENGINE in ('BLENDER_EEVEE', 'BLENDER_EEVEE_NEXT'):
        scene.eevee.taa_render_samples = SAMPLES

# Output format and filepath
scene.render.image_settings.file_format = FILE_FORMAT
scene.render.filepath = f"/root/output/{OUTPUT_NAMING}_"
scene.render.use_file_extension = True

print(f"[Foton] Scene configured: {RES_X}x{RES_Y}, frames {FRAME_START}-{FRAME_END} step {FRAME_INC}, engine={ENGINE}, format={FILE_FORMAT}, samples={SAMPLES}")
PYEOF

echo "[Foton] Render setup script created."

# ═══════════════════════════════════════════════════════════════
# 6. RENDERING
# ═══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎬 RENDERING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

report_status "rendering"
echo "[Foton] Status → rendering"

# ═══════════════════════════════════════════════════════════════
# 7. LAUNCH BLENDER (background) + WATCHDOG LOOP (foreground)
# ═══════════════════════════════════════════════════════════════

BLENDER_LOG="/root/blender.log"
> "$BLENDER_LOG"

/opt/blender/blender -b "$BLEND_FILE" \
  -P /opt/blender/activate_gpu.py \
  -P /root/render_setup.py \
  -a > "$BLENDER_LOG" 2>&1 &
BLENDER_PID=$!
echo "[Foton] Blender launched (PID: $BLENDER_PID)"

# Build ordered list of expected frame numbers (skipping already-completed frames in recovery)
EXPECTED_FRAMES=()
for f in $(seq "$FRAME_START" "$FRAME_INC" "$FRAME_END"); do
  if [ "${RECOVERY_MODE:-0}" = "1" ] && [ "${COMPLETED_MAP[$f]:-0}" = "1" ]; then
    continue  # Skip frames already completed in previous instance
  fi
  EXPECTED_FRAMES+=("$f")
done
TOTAL=${#EXPECTED_FRAMES[@]}
if [ "${RECOVERY_MODE:-0}" = "1" ]; then
  echo "[Foton] Expecting ${TOTAL} remaining frames (skipped completed)."
else
  echo "[Foton] Expecting ${TOTAL} frames."
fi

# ── Watchdog Loop ─────────────────────────────────────────────

NEXT=0            # Index into EXPECTED_FRAMES of next frame to upload
HB_TICK=0         # Counter for heartbeat checks (~every 30s)
CANCELLED=false
BLENDER_EXIT=0
LOG_OFFSET=0      # Track how far we've read in the Blender log

while true; do

  # ── Check if Blender is still running ──
  BLENDER_ALIVE=true
  if ! kill -0 "$BLENDER_PID" 2>/dev/null; then
    BLENDER_ALIVE=false
    wait "$BLENDER_PID" 2>/dev/null
    BLENDER_EXIT=$?
  fi

  # ── Upload all safe frames ──
  while [ "$NEXT" -lt "$TOTAL" ]; do
    FRAME=${EXPECTED_FRAMES[$NEXT]}
    PADDED=$(printf "%04d" "$FRAME")
    FILE="/root/output/${OUTPUT_NAMING}_${PADDED}.${FILE_EXT}"

    # Frame file must exist on disk
    [ ! -f "$FILE" ] && break

    # Safe-gap check: only upload if next frame also exists OR Blender has exited
    SAFE=false
    if [ "$BLENDER_ALIVE" = false ]; then
      SAFE=true
    elif [ $(( NEXT + 1 )) -lt "$TOTAL" ]; then
      NF=${EXPECTED_FRAMES[$(( NEXT + 1 ))]}
      NP=$(printf "%04d" "$NF")
      [ -f "/root/output/${OUTPUT_NAMING}_${NP}.${FILE_EXT}" ] && SAFE=true
    fi
    [ "$SAFE" = false ] && break

    # ── Get presigned upload URL (with retry) ──
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

    # ── Upload file to R2 (with retry) ──
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

    # ── Parse Blender's render time from log ──
    RENDER_TIME=""
    NEW_LOG=$(tail -c +$(( LOG_OFFSET + 1 )) "$BLENDER_LOG" 2>/dev/null)
    LOG_OFFSET=$(wc -c < "$BLENDER_LOG")

    TIME_LINE=$(echo "$NEW_LOG" | grep -oP 'Time:\s+\K[0-9]+:[0-9]+\.[0-9]+' | tail -1)
    if [ -n "$TIME_LINE" ]; then
      MINUTES=$(echo "$TIME_LINE" | cut -d: -f1)
      SECONDS_PART=$(echo "$TIME_LINE" | cut -d: -f2)
      RENDER_TIME=$(python3 -c "print(int('${MINUTES}')*60 + float('${SECONDS_PART}'))")
    fi

    # ── Report progress (with retry + verification) ──
    PROGRESS_OK=false
    for RETRY in 1 2 3; do
      if [ -n "$RENDER_TIME" ]; then
        PROGRESS_RESP=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/progress" \
          -H "Content-Type: application/json" \
          -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"currentFrame\": ${FRAME}, \"completedFrame\": ${FRAME}, \"renderTime\": ${RENDER_TIME}}")
      else
        PROGRESS_RESP=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/instances/progress" \
          -H "Content-Type: application/json" \
          -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"currentFrame\": ${FRAME}, \"completedFrame\": ${FRAME}}")
      fi
      # Verify server acknowledged
      PROGRESS_SUCCESS=$(echo "$PROGRESS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null)
      if [ "$PROGRESS_SUCCESS" = "True" ]; then
        PROGRESS_OK=true
        break
      fi
      echo "[Foton] Retry ${RETRY}: progress report for frame ${FRAME} not acknowledged"
      sleep 2
    done
    if [ "$PROGRESS_OK" = false ]; then
      echo "[Foton] WARNING: Progress report for frame ${FRAME} failed after 3 retries (frame is in R2 but may not be tracked)"
    fi

    # Clean up to save disk
    rm -f "$FILE"
    NEXT=$(( NEXT + 1 ))
    echo "[Foton] Frame ${FRAME} uploaded. (${NEXT}/${TOTAL}${RENDER_TIME:+, ${RENDER_TIME}s})"
  done

  # ── Exit conditions ──

  if [ "$NEXT" -ge "$TOTAL" ]; then
    echo "[Foton] All ${TOTAL} frames uploaded."
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

  # ── Heartbeat / cancellation check (~every 20s) ──
  HB_TICK=$(( HB_TICK + 1 ))
  if [ "$HB_TICK" -ge 10 ]; then
    HB_TICK=0
    HB_ACTION=$(curl -s --connect-timeout 5 --max-time 15 -X POST "${FOTON_API_URL}/instances/heartbeat" \
      -H "Content-Type: application/json" \
      -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\"}" \
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

# Kill background processes
kill "$HEARTBEAT_PID" 2>/dev/null
kill "$LOG_PUSHER_PID" 2>/dev/null

# Final log push to capture last lines
push_logs

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════
# 8. REPORT FINAL STATUS
# ═══════════════════════════════════════════════════════════════

if [ "$CANCELLED" = true ]; then
  echo "[Foton] Task was cancelled. Exiting."
  exit 0
fi

if [ "$NEXT" -ge "$TOTAL" ]; then
  FINAL_STATUS="completed"
else
  FINAL_STATUS="failed"
fi

echo "[Foton] Reporting: ${FINAL_STATUS}"

for ATTEMPT in 1 2 3; do
  HTTP_STATUS=$(curl -s --connect-timeout 10 --max-time 30 -o /dev/null -w "%{http_code}" -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"status\": \"${FINAL_STATUS}\"}")

  if [ "$HTTP_STATUS" = "200" ]; then
    echo "[Foton] Reported status: ${FINAL_STATUS}. Instance will be destroyed by API."
    break
  else
    echo "[Foton] WARNING: Final report attempt ${ATTEMPT} failed (HTTP ${HTTP_STATUS})"
    sleep 5
  fi
done

echo "[Foton] Done."
