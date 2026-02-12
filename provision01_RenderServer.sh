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
    curl -s -X POST "${FOTON_API_URL}/instances/report" \
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

# ── Log Server (serves provisioning + blender logs over HTTP) ──

cat > /root/log_server.py << 'PYEOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

TOKEN = os.environ.get('FOTON_INSTANCE_TOKEN', '')
LOG_FILES = {
    '/provisioning': '/var/log/portal/provisioning.log',
    '/blender': '/root/blender.log'
}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        params = dict(p.split('=',1) for p in (self.path.split('?',1)[1] if '?' in self.path else '').split('&') if '=' in p)
        if params.get('token') != TOKEN:
            self.send_response(403); self.end_headers(); return
        path = self.path.split('?')[0]
        log_file = LOG_FILES.get(path)
        if not log_file or not os.path.exists(log_file):
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        with open(log_file, 'rb') as f:
            self.wfile.write(f.read())
    def log_message(self, *args): pass

HTTPServer(('0.0.0.0', 8081), Handler).serve_forever()
PYEOF

python3 /root/log_server.py &
LOG_SERVER_PID=$!

# Compute public log URL from Vast.ai env vars
EXTERNAL_PORT=${VAST_TCP_PORT_8081:-8081}
LOG_BASE_URL="http://${PUBLIC_IPADDR}:${EXTERNAL_PORT}"
echo "[Foton] Log server started → ${LOG_BASE_URL}"

# Report log URL so the app can start showing logs immediately
if [ -n "$FOTON_API_URL" ]; then
  curl -s -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"logBaseUrl\": \"${LOG_BASE_URL}\"}" > /dev/null
fi

# ── Heartbeat (background keep-alive ping) ──

if [ -n "$FOTON_API_URL" ]; then
  (while true; do
      curl -s -X POST "${FOTON_API_URL}/instances/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\"}" > /dev/null
      sleep 30
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
# 3. ACCESSING IMPERIAL BLUEPRINTS (Downloading Project Files)
# ═══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 ACCESSING IMPERIAL BLUEPRINTS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

report_status "downloading"
echo "[Foton] Status → downloading"

if [ -n "$FOTON_API_URL" ]; then
  # Get blend download URL
  RESPONSE=$(curl -s -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"blendDownloaded\": false}")

  BLEND_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendUrl') or '')" 2>/dev/null)

  # If upload isn't done yet, poll until it is
  POLL_COUNT=0
  while [ -z "$BLEND_URL" ]; do
      POLL_COUNT=$(( POLL_COUNT + 1 ))
      echo "[Foton] Waiting for project file upload... (attempt ${POLL_COUNT})"
      sleep 5
      BLEND_URL=$(curl -s "${FOTON_API_URL}/instances/blend-url?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendUrl') or '')" 2>/dev/null)
  done

  echo "[Foton] Downloading project file..."
  curl -# -o /root/scene.blend "$BLEND_URL" 2>&1 | while IFS= read -r line; do echo "[Foton] $line"; done

  BLEND_SIZE=$(du -h /root/scene.blend | cut -f1)
  echo "[Foton] Project file downloaded (${BLEND_SIZE})."

  # Report blend downloaded
  curl -s -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"blendDownloaded\": true}" > /dev/null
  echo "[Foton] Imperial blueprints secured."
fi

rm /root/installing
touch /root/ready
echo "[Foton] Node fully provisioned and ready."

# ═══════════════════════════════════════════════════════════════
# 4. FETCH RENDER CONFIG
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

echo "[Foton] Config: frames ${FRAME_START}-${FRAME_END} (step ${FRAME_INC}), ${RES_X}x${RES_Y}, engine=${RENDER_ENGINE}, camera=${CAMERA}, samples=${MAX_SAMPLES}"

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
# 5. CREATE SCENE SETUP SCRIPT
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

/opt/blender/blender -b /root/scene.blend \
  -P /opt/blender/activate_gpu.py \
  -P /root/render_setup.py \
  -a > "$BLENDER_LOG" 2>&1 &
BLENDER_PID=$!
echo "[Foton] Blender launched (PID: $BLENDER_PID)"

# Build ordered list of expected frame numbers
EXPECTED_FRAMES=()
for f in $(seq "$FRAME_START" "$FRAME_INC" "$FRAME_END"); do
  EXPECTED_FRAMES+=("$f")
done
TOTAL=${#EXPECTED_FRAMES[@]}
echo "[Foton] Expecting ${TOTAL} frames."

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
      UPLOAD_URL=$(curl -s -X POST "${FOTON_API_URL}/instances/frame-upload-url" \
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
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$UPLOAD_URL" \
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
      RENDER_TIME=$(python3 -c "print(int(${MINUTES})*60 + float(${SECONDS_PART}))")
    fi

    # ── Report progress ──
    if [ -n "$RENDER_TIME" ]; then
      curl -s -X POST "${FOTON_API_URL}/instances/progress" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"currentFrame\": ${FRAME}, \"completedFrame\": ${FRAME}, \"renderTime\": ${RENDER_TIME}}" > /dev/null
    else
      curl -s -X POST "${FOTON_API_URL}/instances/progress" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"currentFrame\": ${FRAME}, \"completedFrame\": ${FRAME}}" > /dev/null
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

  # ── Heartbeat / cancellation check (~every 30s) ──
  HB_TICK=$(( HB_TICK + 1 ))
  if [ "$HB_TICK" -ge 15 ]; then
    HB_TICK=0
    HB_ACTION=$(curl -s -X POST "${FOTON_API_URL}/instances/heartbeat" \
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
kill "$LOG_SERVER_PID" 2>/dev/null

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
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${FOTON_API_URL}/instances/report" \
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
