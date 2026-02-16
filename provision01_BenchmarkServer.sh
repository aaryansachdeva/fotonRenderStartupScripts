#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# FOTONLABS BENCHMARK INSTANCE — Polling Architecture
# ═══════════════════════════════════════════════════════════════
#
# Always-on GPU instance that polls the Foton API for benchmark
# jobs. Uses Blender's -a flag for efficient multi-frame rendering
# with two passes (1 sample + N samples) for init time isolation.
#
# Environment vars (set when provisioning via Vast.ai):
#   FOTON_API_URL          — Worker API base URL
#   BENCHMARK_TOKEN        — shared secret for auth
# ═══════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚡ FOTON BENCHMARK INSTANCE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════
# 1. INSTALL DEPENDENCIES
# ═══════════════════════════════════════════════════════════════

echo "[Benchmark] Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq wget xz-utils libgl1 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxxf86vm1 libsm6 libxext6 python3 curl jq
echo "[Benchmark] System dependencies installed."

if [ ! -d "/opt/blender" ]; then
  echo "[Benchmark] Downloading Blender 5.0.1..."
  wget -q --show-progress https://download.blender.org/release/Blender5.0/blender-5.0.1-linux-x64.tar.xz
  echo "[Benchmark] Extracting Blender..."
  tar -xf blender-5.0.1-linux-x64.tar.xz
  mv blender-5.0.1-linux-x64 /opt/blender
  rm blender-5.0.1-linux-x64.tar.xz
  echo "[Benchmark] Blender 5.0.1 installed."
else
  echo "[Benchmark] Blender already installed."
fi

echo "[Benchmark] Fetching GPU activation script..."
wget -q -O /opt/blender/activate_gpu.py https://raw.githubusercontent.com/aaryansachdeva/fotonRenderStartupScripts/refs/heads/main/activate_gpu.py
echo "[Benchmark] GPU activation script ready."

# Detect GPU name
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
echo "[Benchmark] GPU: ${GPU_NAME}"

# ═══════════════════════════════════════════════════════════════
# HELPER: Parse "Time: MM:SS.FF" from Blender log into seconds
# ═══════════════════════════════════════════════════════════════
parse_blender_time() {
  local time_str="$1"
  echo "$time_str" | awk -F'[:]' '{
    n = NF
    if (n == 2) {
      # MM:SS.FF
      print $1 * 60 + $2
    } else if (n == 3) {
      # HH:MM:SS.FF
      print $1 * 3600 + $2 * 60 + $3
    } else {
      print 0
    }
  }'
}

# ═══════════════════════════════════════════════════════════════
# 2. POLL LOOP — check for jobs every 20 seconds
# ═══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔄 ENTERING POLL LOOP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

while true; do

  # ── Poll for next job ──
  RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/benchmark/poll" \
    -H "Content-Type: application/json" \
    -d "{\"token\": \"${BENCHMARK_TOKEN}\", \"gpuName\": \"${GPU_NAME}\"}")

  JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id // empty' 2>/dev/null)

  if [ -z "$JOB_ID" ]; then
    sleep 20
    continue
  fi

  # ── Extract job details ──
  BLEND_URL=$(echo "$RESPONSE"     | jq -r '.job.blendUrl')
  FRAME_START=$(echo "$RESPONSE"   | jq -r '.job.frameStart')
  FRAME_END=$(echo "$RESPONSE"     | jq -r '.job.frameEnd')
  RES_X=$(echo "$RESPONSE"         | jq -r '.job.resolutionX')
  RES_Y=$(echo "$RESPONSE"         | jq -r '.job.resolutionY')
  SAMPLES=$(echo "$RESPONSE"       | jq -r '.job.samples')
  ENGINE=$(echo "$RESPONSE"        | jq -r '.job.engine')
  CAMERA=$(echo "$RESPONSE"        | jq -r '.job.camera')

  # Calculate frame step to hit ~3 frames (beginning, middle, end)
  FRAME_RANGE=$((FRAME_END - FRAME_START))
  if [ "$FRAME_RANGE" -le 0 ]; then
    FRAME_STEP=1
  elif [ "$FRAME_RANGE" -le 2 ]; then
    FRAME_STEP=1
  else
    FRAME_STEP=$((FRAME_RANGE / 2))
  fi

  # Count expected frames
  FRAME_COUNT=$(( (FRAME_RANGE / FRAME_STEP) + 1 ))

  echo ""
  echo "[Benchmark] ── Job ${JOB_ID} ──"
  echo "[Benchmark] Frames ${FRAME_START}-${FRAME_END} (step ${FRAME_STEP}, ~${FRAME_COUNT} frames)"
  echo "[Benchmark] ${RES_X}x${RES_Y}, ${ENGINE}, ${SAMPLES} bench samples"

  # ── Create workspace ──
  WORK_DIR=$(mktemp -d /tmp/foton_bench_XXXXXX)
  BLEND_PATH="${WORK_DIR}/scene.blend"
  mkdir -p "${WORK_DIR}/output"

  # ── Download blend file (once) ──
  echo "[Benchmark] Downloading blend file..."
  HTTP_CODE=$(curl -s --connect-timeout 15 --max-time 600 -o "$BLEND_PATH" -w "%{http_code}" "$BLEND_URL")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "[Benchmark] ERROR: Blend download failed (HTTP ${HTTP_CODE})"
    curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/benchmark/result" \
      -H "Content-Type: application/json" \
      -d "{\"token\": \"${BENCHMARK_TOKEN}\", \"jobId\": \"${JOB_ID}\", \"error\": \"Blend download failed (HTTP ${HTTP_CODE})\"}" > /dev/null
    rm -rf "$WORK_DIR"
    continue
  fi

  BLEND_SIZE=$(du -h "$BLEND_PATH" | cut -f1)
  echo "[Benchmark] Blend downloaded (${BLEND_SIZE})"

  # ═══════════════════════════════════════════════════════════════
  # SINGLE-PASS at 20 samples — fast benchmark, linear extrapolation
  #
  # Renders 3 frames (first, mid, last) at 20 samples using -a flag.
  # Warmup frame pre-compiles GPU kernels first.
  #
  # Reports:
  #   initTime      = first frame time (includes BVH/kernel cold start)
  #   perSampleTime = avg warm frame time (mid + last / 2)
  #   renderTime    = avg of all 3 frames
  # ═══════════════════════════════════════════════════════════════

  # ── Create render setup script ──
  cat > "${WORK_DIR}/bench_setup.py" << 'PYEOF'
import bpy, os

scene = bpy.context.scene

BENCH_SAMPLES = int(os.environ.get('BENCH_SAMPLES', '20'))

scene.render.resolution_x = int(os.environ['BENCH_RES_X'])
scene.render.resolution_y = int(os.environ['BENCH_RES_Y'])
scene.render.resolution_percentage = 100

scene.frame_start = int(os.environ['BENCH_FRAME_START'])
scene.frame_end = int(os.environ['BENCH_FRAME_END'])
scene.frame_step = int(os.environ['BENCH_FRAME_STEP'])

cam_name = os.environ.get('BENCH_CAMERA', '')
if cam_name and cam_name in bpy.data.objects:
    scene.camera = bpy.data.objects[cam_name]

engine = os.environ.get('BENCH_ENGINE', 'CYCLES')
scene.render.engine = engine

if engine == 'CYCLES':
    scene.cycles.samples = BENCH_SAMPLES
    scene.cycles.device = 'GPU'
elif engine in ('BLENDER_EEVEE', 'BLENDER_EEVEE_NEXT'):
    scene.eevee.taa_render_samples = BENCH_SAMPLES

scene.render.filepath = os.environ.get('BENCH_OUTPUT', '/tmp/bench_')
scene.render.image_settings.file_format = 'PNG'
scene.render.use_file_extension = True

print(f"[Benchmark] Setup: {scene.render.resolution_x}x{scene.render.resolution_y}, "
      f"frames {scene.frame_start}-{scene.frame_end} step {scene.frame_step}, "
      f"samples={BENCH_SAMPLES}, engine={engine}")
PYEOF

  # Common env vars
  export BENCH_RES_X="$RES_X"
  export BENCH_RES_Y="$RES_Y"
  export BENCH_FRAME_START="$FRAME_START"
  export BENCH_FRAME_END="$FRAME_END"
  export BENCH_FRAME_STEP="$FRAME_STEP"
  export BENCH_CAMERA="$CAMERA"
  export BENCH_ENGINE="$ENGINE"
  export BENCH_OUTPUT="${WORK_DIR}/output/bench_"
  export BENCH_SAMPLES="$SAMPLES"

  # ── Warmup: render 1 frame at 1 sample to compile GPU kernels ──
  echo "[Benchmark] Warmup: compiling render kernels..."
  SAVE_SAMPLES="$BENCH_SAMPLES"
  SAVE_FRAME_END="$BENCH_FRAME_END"
  SAVE_FRAME_STEP="$BENCH_FRAME_STEP"
  export BENCH_SAMPLES=1
  export BENCH_FRAME_END="$FRAME_START"
  export BENCH_FRAME_STEP=1

  /opt/blender/blender -b "$BLEND_PATH" \
    -P /opt/blender/activate_gpu.py \
    -P "${WORK_DIR}/bench_setup.py" \
    -a > /dev/null 2>&1

  echo "[Benchmark] Warmup complete — kernels cached."
  rm -f "${WORK_DIR}"/output/bench_*.png

  # Restore actual values
  export BENCH_SAMPLES="$SAVE_SAMPLES"
  export BENCH_FRAME_END="$SAVE_FRAME_END"
  export BENCH_FRAME_STEP="$SAVE_FRAME_STEP"

  # ── Render 3 frames at 20 samples ──
  echo "[Benchmark] Rendering ${FRAME_COUNT} frames at ${SAMPLES} samples..."
  BENCH_LOG="${WORK_DIR}/blender_bench.log"

  /opt/blender/blender -b "$BLEND_PATH" \
    -P /opt/blender/activate_gpu.py \
    -P "${WORK_DIR}/bench_setup.py" \
    -a > "$BENCH_LOG" 2>&1

  EXIT_CODE=$?
  echo "[Benchmark] Render complete (exit $EXIT_CODE)"

  # Parse per-frame times from log: "Time: MM:SS.FF"
  FRAME_TIMES=()
  while IFS= read -r line; do
    SECS=$(parse_blender_time "$line")
    FRAME_TIMES+=("$SECS")
  done < <(grep -oP 'Time:\s*\K[0-9]+:[0-9]+\.[0-9]+' "$BENCH_LOG")

  echo "[Benchmark] Frame times: ${FRAME_TIMES[*]}"

  FRAME_COUNT_ACTUAL=${#FRAME_TIMES[@]}

  if [ "$FRAME_COUNT_ACTUAL" -gt 0 ]; then
    # First frame = cold (includes BVH build + scene sync overhead)
    FIRST_FRAME=${FRAME_TIMES[0]}
    echo "[Benchmark] First frame (cold): ${FIRST_FRAME}s"

    # Avg warm frames = mid + last (skip first)
    if [ "$FRAME_COUNT_ACTUAL" -ge 3 ]; then
      AVG_WARM=$(echo "${FRAME_TIMES[1]} ${FRAME_TIMES[2]}" | awk '{printf "%.4f", ($1 + $2) / 2}')
    elif [ "$FRAME_COUNT_ACTUAL" -ge 2 ]; then
      AVG_WARM=${FRAME_TIMES[1]}
    else
      AVG_WARM=$FIRST_FRAME
    fi
    echo "[Benchmark] Avg warm frame: ${AVG_WARM}s"

    # Overall average for display
    SUM_TOTAL=0
    for i in $(seq 0 $((FRAME_COUNT_ACTUAL - 1))); do
      T=${FRAME_TIMES[$i]}
      echo "[Benchmark] Frame $((i+1)): ${T}s"
      SUM_TOTAL=$(echo "$SUM_TOTAL $T" | awk '{printf "%.6f", $1 + $2}')
    done
    AVG_TOTAL=$(echo "$SUM_TOTAL $FRAME_COUNT_ACTUAL" | awk '{printf "%.4f", $1 / $2}')

    # Parse peak VRAM from Blender log (Mem: XXM)
    PEAK_VRAM=$(grep -oP 'Mem:\s*\K[0-9]+' "$BENCH_LOG" | sort -n | tail -1)
    PEAK_VRAM=${PEAK_VRAM:-0}

    echo ""
    echo "[Benchmark] ── Results (${FRAME_COUNT_ACTUAL} frames at ${SAMPLES} samples) ──"
    echo "[Benchmark] First frame:     ${FIRST_FRAME}s"
    echo "[Benchmark] Avg warm frame:  ${AVG_WARM}s"
    echo "[Benchmark] Overall average: ${AVG_TOTAL}s"
    echo "[Benchmark] Peak VRAM:       ${PEAK_VRAM}M"

    # initTime = first frame, perSampleTime = avg warm frame, renderTime = overall avg
    PAYLOAD="{\"token\": \"${BENCHMARK_TOKEN}\", \"jobId\": \"${JOB_ID}\", \"renderTime\": ${AVG_TOTAL}, \"initTime\": ${FIRST_FRAME}, \"perSampleTime\": ${AVG_WARM}, \"gpuName\": \"${GPU_NAME}\", \"peakVram\": ${PEAK_VRAM}}"

    curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/benchmark/result" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" > /dev/null

    echo "[Benchmark] Result reported."
  else
    echo "[Benchmark] ERROR: Failed to parse frame times from Blender logs"

    ERROR_CONTEXT="Exit:${EXIT_CODE}. Log tail: $(tail -c 500 "$BENCH_LOG" 2>/dev/null)"
    ERROR_JSON=$(echo "$ERROR_CONTEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo "\"Failed to parse frame times\"")

    curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/benchmark/result" \
      -H "Content-Type: application/json" \
      -d "{\"token\": \"${BENCHMARK_TOKEN}\", \"jobId\": \"${JOB_ID}\", \"error\": ${ERROR_JSON}}" > /dev/null

    echo "[Benchmark] Error reported."
  fi

  # ── Cleanup ──
  rm -rf "$WORK_DIR"
  echo "[Benchmark] Workspace cleaned up."

done
