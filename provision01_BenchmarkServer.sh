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
  # TWO-PASS RENDERING (init time isolation)
  #
  # Pass 1: Render all frames at 1 sample using -a flag
  #   Each frame: t1 = init + 1×per_sample
  #
  # Pass 2: Render all frames at N samples using -a flag
  #   Each frame: tN = init + N×per_sample
  #
  # Per frame: per_sample = (tN - t1) / (N - 1)
  #            init_time = t1 - per_sample
  # ═══════════════════════════════════════════════════════════════

  # ── Create render setup script (reads BENCH_SAMPLES env var) ──
  cat > "${WORK_DIR}/bench_setup.py" << 'PYEOF'
import bpy, os

scene = bpy.context.scene

BENCH_SAMPLES = int(os.environ.get('BENCH_SAMPLES', '16'))

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
    scene.cycles.use_denoising = False
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

  # Common env vars for both passes
  export BENCH_RES_X="$RES_X"
  export BENCH_RES_Y="$RES_Y"
  export BENCH_FRAME_START="$FRAME_START"
  export BENCH_FRAME_END="$FRAME_END"
  export BENCH_FRAME_STEP="$FRAME_STEP"
  export BENCH_CAMERA="$CAMERA"
  export BENCH_ENGINE="$ENGINE"
  export BENCH_OUTPUT="${WORK_DIR}/output/bench_"

  # ── Warmup: render 1 frame at 1 sample to compile GPU kernels ──
  echo "[Benchmark] Warmup: compiling render kernels..."
  export BENCH_SAMPLES=1
  export BENCH_FRAME_END="$FRAME_START"
  export BENCH_FRAME_STEP=1

  /opt/blender/blender -b "$BLEND_PATH" \
    -P /opt/blender/activate_gpu.py \
    -P "${WORK_DIR}/bench_setup.py" \
    -a > /dev/null 2>&1

  echo "[Benchmark] Warmup complete — kernels cached."
  rm -f "${WORK_DIR}"/output/bench_*.png

  # Restore actual frame range
  export BENCH_FRAME_END="$FRAME_END"
  export BENCH_FRAME_STEP="$FRAME_STEP"

  # ── Pass 1: Render at 1 sample ──
  echo "[Benchmark] Pass 1: Rendering ${FRAME_COUNT} frames at 1 sample (calibration)..."
  LOG_1="${WORK_DIR}/blender_1.log"
  export BENCH_SAMPLES=1

  /opt/blender/blender -b "$BLEND_PATH" \
    -P /opt/blender/activate_gpu.py \
    -P "${WORK_DIR}/bench_setup.py" \
    -a > "$LOG_1" 2>&1

  EXIT_1=$?
  echo "[Benchmark] Pass 1 complete (exit $EXIT_1)"

  # Parse per-frame times from log: "Time: MM:SS.FF"
  # Each frame produces one Time: line at the end
  TIMES_1=()
  while IFS= read -r line; do
    SECS=$(parse_blender_time "$line")
    TIMES_1+=("$SECS")
  done < <(grep -oP 'Time:\s*\K[0-9]+:[0-9]+\.[0-9]+' "$LOG_1")

  echo "[Benchmark] Pass 1 frame times: ${TIMES_1[*]}"

  # ── Pass 2: Render at N samples ──
  echo "[Benchmark] Pass 2: Rendering ${FRAME_COUNT} frames at ${SAMPLES} samples..."
  LOG_N="${WORK_DIR}/blender_N.log"
  export BENCH_SAMPLES="$SAMPLES"

  # Clean output from pass 1
  rm -f "${WORK_DIR}"/output/bench_*.png

  /opt/blender/blender -b "$BLEND_PATH" \
    -P /opt/blender/activate_gpu.py \
    -P "${WORK_DIR}/bench_setup.py" \
    -a > "$LOG_N" 2>&1

  EXIT_N=$?
  echo "[Benchmark] Pass 2 complete (exit $EXIT_N)"

  TIMES_N=()
  while IFS= read -r line; do
    SECS=$(parse_blender_time "$line")
    TIMES_N+=("$SECS")
  done < <(grep -oP 'Time:\s*\K[0-9]+:[0-9]+\.[0-9]+' "$LOG_N")

  echo "[Benchmark] Pass 2 frame times: ${TIMES_N[*]}"

  # ── Calculate init and per-sample from both passes ──
  COUNT_1=${#TIMES_1[@]}
  COUNT_N=${#TIMES_N[@]}
  PAIR_COUNT=$((COUNT_1 < COUNT_N ? COUNT_1 : COUNT_N))

  if [ "$PAIR_COUNT" -gt 0 ]; then
    SUM_INIT=0
    SUM_PER_SAMPLE=0
    SUM_TOTAL=0

    for i in $(seq 0 $((PAIR_COUNT - 1))); do
      T1=${TIMES_1[$i]}
      TN=${TIMES_N[$i]}

      FRAME_INIT=$(echo "$T1 $TN $SAMPLES" | awk '{
        per_sample = ($2 - $1) / ($3 - 1)
        init = $1 - per_sample
        if (init < 0) init = 0
        printf "%.6f", init
      }')

      FRAME_PER_SAMPLE=$(echo "$T1 $TN $SAMPLES" | awk '{
        per_sample = ($2 - $1) / ($3 - 1)
        if (per_sample < 0) per_sample = 0
        printf "%.6f", per_sample
      }')

      echo "[Benchmark] Frame $((i+1)): t1=${T1}s, tN=${TN}s → init=${FRAME_INIT}s, per_sample=${FRAME_PER_SAMPLE}s"

      SUM_INIT=$(echo "$SUM_INIT $FRAME_INIT" | awk '{printf "%.6f", $1 + $2}')
      SUM_PER_SAMPLE=$(echo "$SUM_PER_SAMPLE $FRAME_PER_SAMPLE" | awk '{printf "%.6f", $1 + $2}')
      SUM_TOTAL=$(echo "$SUM_TOTAL $TN" | awk '{printf "%.6f", $1 + $2}')
    done

    AVG_INIT=$(echo "$SUM_INIT $PAIR_COUNT" | awk '{printf "%.4f", $1 / $2}')
    AVG_PER_SAMPLE=$(echo "$SUM_PER_SAMPLE $PAIR_COUNT" | awk '{printf "%.6f", $1 / $2}')
    AVG_TOTAL=$(echo "$SUM_TOTAL $PAIR_COUNT" | awk '{printf "%.4f", $1 / $2}')

    echo ""
    echo "[Benchmark] ── Results (${PAIR_COUNT} frames) ──"
    echo "[Benchmark] Avg init time:       ${AVG_INIT}s"
    echo "[Benchmark] Avg per-sample time: ${AVG_PER_SAMPLE}s"
    echo "[Benchmark] Avg total time:      ${AVG_TOTAL}s (at ${SAMPLES} samples)"

    PAYLOAD="{\"token\": \"${BENCHMARK_TOKEN}\", \"jobId\": \"${JOB_ID}\", \"renderTime\": ${AVG_TOTAL}, \"initTime\": ${AVG_INIT}, \"perSampleTime\": ${AVG_PER_SAMPLE}, \"gpuName\": \"${GPU_NAME}\"}"

    curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/benchmark/result" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" > /dev/null

    echo "[Benchmark] Result reported."
  else
    echo "[Benchmark] ERROR: Failed to parse frame times from Blender logs"

    # Send last 500 chars of both logs as error context
    ERROR_CONTEXT="Pass1 exit:${EXIT_1}, Pass2 exit:${EXIT_N}. Times1:[${TIMES_1[*]}] TimesN:[${TIMES_N[*]}]"
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
