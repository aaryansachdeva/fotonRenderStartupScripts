#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# FOTONLABS BENCHMARK INSTANCE — Polling Architecture
# ═══════════════════════════════════════════════════════════════
#
# Always-on GPU instance that polls the Foton API for benchmark
# jobs. No inbound server needed — just polls, renders, reports.
#
# Environment vars (set when provisioning via Vast.ai):
#   FOTON_API_URL          — Worker API base URL
#   BENCHMARK_TOKEN        — shared secret for auth (same value as Worker's BENCHMARK_TOKEN)
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
# HELPER: Parse Blender's "Time:MM:SS.FF" or "Time:HH:MM:SS.FF"
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

  # Check if we got a job
  JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id // empty' 2>/dev/null)

  if [ -z "$JOB_ID" ]; then
    # No job — sleep and poll again
    sleep 20
    continue
  fi

  # ── We have a job — extract details ──
  BLEND_URL=$(echo "$RESPONSE"    | jq -r '.job.blendUrl')
  FRAME=$(echo "$RESPONSE"        | jq -r '.job.frame')
  RES_X=$(echo "$RESPONSE"        | jq -r '.job.resolutionX')
  RES_Y=$(echo "$RESPONSE"        | jq -r '.job.resolutionY')
  SAMPLES=$(echo "$RESPONSE"      | jq -r '.job.samples')
  ENGINE=$(echo "$RESPONSE"       | jq -r '.job.engine')
  CAMERA=$(echo "$RESPONSE"       | jq -r '.job.camera')

  echo ""
  echo "[Benchmark] ── Job ${JOB_ID} ──"
  echo "[Benchmark] Frame ${FRAME}, ${RES_X}x${RES_Y}, ${ENGINE}, ${SAMPLES} samples"

  # ── Create temp workspace ──
  WORK_DIR=$(mktemp -d /tmp/foton_bench_XXXXXX)
  BLEND_PATH="${WORK_DIR}/scene.blend"

  # ── Download blend file ──
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

  # ── Create render script ──
  cat > "${WORK_DIR}/bench_setup.py" << PYEOF
import bpy
import time

scene = bpy.context.scene

# Resolution — full resolution, no scaling
scene.render.resolution_x = ${RES_X}
scene.render.resolution_y = ${RES_Y}
scene.render.resolution_percentage = 100

# Camera
cam = bpy.data.objects.get("${CAMERA}")
if cam and cam.type == "CAMERA":
    scene.camera = cam

# Engine + samples (fixed at ${SAMPLES} for benchmark)
scene.render.engine = "${ENGINE}"
if "${ENGINE}" == "CYCLES":
    scene.cycles.samples = ${SAMPLES}
    scene.cycles.use_denoising = False
    scene.cycles.device = "GPU"
elif "${ENGINE}" in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
    scene.eevee.taa_render_samples = ${SAMPLES}

# Output
scene.render.filepath = "${WORK_DIR}/bench_"
scene.render.image_settings.file_format = "PNG"

# Set frame and render
scene.frame_set(${FRAME})

print("[Benchmark] Starting render...")
start = time.time()
bpy.ops.render.render(write_still=True)
elapsed = time.time() - start
print(f"[Benchmark] RENDER_TIME={elapsed:.3f}")
PYEOF

  # ── Run Blender ──
  echo "[Benchmark] Rendering frame ${FRAME}..."
  BLENDER_OUTPUT=$(/opt/blender/blender -b "$BLEND_PATH" \
    -P /opt/blender/activate_gpu.py \
    -P "${WORK_DIR}/bench_setup.py" 2>&1)

  BLENDER_EXIT=$?

  # ── Parse total render time from Python output ──
  RENDER_TIME=$(echo "$BLENDER_OUTPUT" | grep -oP '\[Benchmark\] RENDER_TIME=\K[0-9]+\.[0-9]+' | tail -1)

  # ── Parse init time from Blender's stdout ──
  # Look for the first "Path Tracing Sample" line — the Time: field is init time
  # Format: "Fra:N Mem:... | Time:MM:SS.FF | ... | Path Tracing Sample 1/16"
  FIRST_SAMPLE_LINE=$(echo "$BLENDER_OUTPUT" | grep -m1 "Path Tracing Sample 1/")
  INIT_TIME_STR=$(echo "$FIRST_SAMPLE_LINE" | grep -oP 'Time:\K[0-9]+:[0-9]+\.[0-9]+' | head -1)

  INIT_TIME=""
  PER_SAMPLE_TIME=""

  if [ -n "$INIT_TIME_STR" ] && [ -n "$RENDER_TIME" ]; then
    INIT_TIME=$(parse_blender_time "$INIT_TIME_STR")
    # per_sample_time = (total_render_time - init_time) / num_samples
    PER_SAMPLE_TIME=$(echo "$RENDER_TIME $INIT_TIME $SAMPLES" | awk '{
      if ($3 > 0) printf "%.4f", ($1 - $2) / $3
      else print "0"
    }')
    echo "[Benchmark] Init time: ${INIT_TIME}s"
    echo "[Benchmark] Per-sample time: ${PER_SAMPLE_TIME}s"
  fi

  if [ -n "$RENDER_TIME" ] && [ "$BLENDER_EXIT" -eq 0 -o "$BLENDER_EXIT" -eq 139 ]; then
    # Exit 139 (SIGSEGV) is OK if render completed — it's a bpy cleanup crash
    echo "[Benchmark] Frame ${FRAME} rendered in ${RENDER_TIME}s"

    # Build JSON payload with init/sample timing
    PAYLOAD="{\"token\": \"${BENCHMARK_TOKEN}\", \"jobId\": \"${JOB_ID}\", \"renderTime\": ${RENDER_TIME}, \"gpuName\": \"${GPU_NAME}\""
    if [ -n "$INIT_TIME" ]; then
      PAYLOAD="${PAYLOAD}, \"initTime\": ${INIT_TIME}"
    fi
    if [ -n "$PER_SAMPLE_TIME" ]; then
      PAYLOAD="${PAYLOAD}, \"perSampleTime\": ${PER_SAMPLE_TIME}"
    fi
    PAYLOAD="${PAYLOAD}}"

    curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/benchmark/result" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" > /dev/null

    echo "[Benchmark] Result reported."
  else
    echo "[Benchmark] ERROR: Render failed (exit ${BLENDER_EXIT})"
    # Send last 500 chars of output as error context
    ERROR_TAIL=$(echo "$BLENDER_OUTPUT" | tail -c 500 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null)

    curl -s --connect-timeout 10 --max-time 30 -X POST "${FOTON_API_URL}/benchmark/result" \
      -H "Content-Type: application/json" \
      -d "{\"token\": \"${BENCHMARK_TOKEN}\", \"jobId\": \"${JOB_ID}\", \"error\": ${ERROR_TAIL:-\"\"Render failed\"\"}}" > /dev/null

    echo "[Benchmark] Error reported."
  fi

  # ── Cleanup ──
  rm -rf "$WORK_DIR"
  echo "[Benchmark] Workspace cleaned up."

done
