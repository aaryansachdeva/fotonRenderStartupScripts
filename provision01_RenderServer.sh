#!/bin/bash

# --- FOTONLABS PROVISIONING PROTOCOL ---

# 1. MARKER: Create a flag so we know installation is in progress
touch /root/installing
echo "[Foton] Starting Provisioning..."

# 2. INSTALL SYSTEM DEPENDENCIES
apt-get update -qq
apt-get install -y -qq wget xz-utils libgl1 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxxf86vm1 libsm6 libxext6 openssh-server python3 curl

# 3. INSTALL BLENDER 5.0.1
if [ ! -d "/opt/blender" ]; then
  echo "[Foton] Downloading Blender 5.0.1..."
  wget -q https://download.blender.org/release/Blender5.0/blender-5.0.1-linux-x64.tar.xz

  echo "[Foton] Extracting..."
  tar -xf blender-5.0.1-linux-x64.tar.xz
  mv blender-5.0.1-linux-x64 /opt/blender
  rm blender-5.0.1-linux-x64.tar.xz
else
  echo "[Foton] Blender already installed. Skipping download."
fi

# 4. DOWNLOAD YOUR GPU ACTIVATION SCRIPT
echo "[Foton] Fetching GPU Logic from GitHub..."
wget -q -O /opt/blender/activate_gpu.py https://raw.githubusercontent.com/aaryansachdeva/fotonRenderStartupScripts/refs/heads/main/activate_gpu.py

# 5. SETUP SSH
mkdir -p /var/run/sshd
service ssh start

# 6. START HEARTBEAT (runs in background)
if [ -n "$FOTON_API_URL" ]; then
  (while true; do
      RESPONSE=$(curl -s -X POST "${FOTON_API_URL}/instances/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\"}")
      ACTION=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('action',''))" 2>/dev/null)
      if [ "$ACTION" = "shutdown" ]; then
          echo "[Foton] Shutdown signal received. Exiting."
          exit 0
      fi
      sleep 30
  done) &
  HEARTBEAT_PID=$!
  echo "[Foton] Heartbeat started (PID: $HEARTBEAT_PID)."
fi

# 7. REPORT READY & DOWNLOAD BLEND FILE
if [ -n "$FOTON_API_URL" ]; then
  RESPONSE=$(curl -s -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"status\": \"ready\"}")
  echo "[Foton] Reported ready to API."

  # Extract blend download URL from response
  BLEND_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendUrl',''))" 2>/dev/null)

  # If upload isn't done yet, poll until it is
  while [ -z "$BLEND_URL" ]; do
      echo "[Foton] Waiting for blend file upload..."
      sleep 5
      BLEND_URL=$(curl -s "${FOTON_API_URL}/instances/blend-url?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('blendUrl',''))" 2>/dev/null)
  done

  echo "[Foton] Downloading blend file..."
  curl -s -o /root/scene.blend "$BLEND_URL"

  # Report blend downloaded
  curl -s -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"blendDownloaded\": true}"
  echo "[Foton] Blend file ready."
fi

# 8. MARKER: PROVISIONING DONE
rm /root/installing
touch /root/ready
echo "[Foton] Node Fully Provisioned & Ready."

# ═══════════════════════════════════════════════════════════════
# 9. FETCH RENDER CONFIG
# ═══════════════════════════════════════════════════════════════
if [ -z "$FOTON_API_URL" ]; then
  echo "[Foton] No API URL set. Skipping render."
  exit 0
fi

echo "[Foton] Fetching render config..."
CONFIG=$(curl -s "${FOTON_API_URL}/instances/render-config?taskId=${FOTON_TASK_ID}&token=${FOTON_INSTANCE_TOKEN}")

FRAME_START=$(echo "$CONFIG"  | python3 -c "import sys,json; print(json.load(sys.stdin)['frameStart'])")
FRAME_END=$(echo "$CONFIG"    | python3 -c "import sys,json; print(json.load(sys.stdin)['frameEnd'])")
FRAME_INC=$(echo "$CONFIG"    | python3 -c "import sys,json; print(json.load(sys.stdin)['frameIncrement'])")
RES_X=$(echo "$CONFIG"        | python3 -c "import sys,json; print(json.load(sys.stdin)['resolutionX'])")
RES_Y=$(echo "$CONFIG"        | python3 -c "import sys,json; print(json.load(sys.stdin)['resolutionY'])")
CAMERA=$(echo "$CONFIG"       | python3 -c "import sys,json; print(json.load(sys.stdin)['camera'])")
RENDER_ENGINE=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin)['renderEngine'])")
FILE_EXT=$(echo "$CONFIG"     | python3 -c "import sys,json; print(json.load(sys.stdin)['fileExtension'])")
OUTPUT_NAMING=$(echo "$CONFIG" | python3 -c "import sys,json; print(json.load(sys.stdin)['outputFileNaming'])")

echo "[Foton] Config: frames ${FRAME_START}-${FRAME_END} (step ${FRAME_INC}), ${RES_X}x${RES_Y}, engine=${RENDER_ENGINE}, camera=${CAMERA}"

# Map file extension to Blender format string
case "$FILE_EXT" in
  exr)      BLENDER_FORMAT="OPEN_EXR" ;;
  png)      BLENDER_FORMAT="PNG" ;;
  jpeg|jpg) BLENDER_FORMAT="JPEG" ;;
  tiff|tif) BLENDER_FORMAT="TIFF" ;;
  *)        BLENDER_FORMAT="PNG" ;;
esac

# ═══════════════════════════════════════════════════════════════
# 10. CREATE RENDER SETUP SCRIPT
# ═══════════════════════════════════════════════════════════════
mkdir -p /root/output

cat > /root/render_setup.py << 'PYEOF'
import bpy
import sys

# Parse custom args after "--"
argv = sys.argv
args = argv[argv.index("--") + 1:] if "--" in argv else []

if len(args) < 6:
    print("[Foton] render_setup.py: not enough args, skipping setup")
else:
    res_x = int(args[0])
    res_y = int(args[1])
    camera_name = args[2]
    engine = args[3]
    fmt = args[4]
    output_path = args[5]

    scene = bpy.context.scene

    # Resolution
    scene.render.resolution_x = res_x
    scene.render.resolution_y = res_y
    scene.render.resolution_percentage = 100

    # Camera
    if camera_name and camera_name in bpy.data.objects:
        scene.camera = bpy.data.objects[camera_name]

    # Render engine
    if engine:
        scene.render.engine = engine

    # Output format & path
    scene.render.image_settings.file_format = fmt
    scene.render.filepath = output_path
    scene.render.use_file_extension = True

    # GPU setup for Cycles
    if engine == "CYCLES":
        scene.cycles.device = "GPU"
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "CUDA"
        prefs.get_devices()
        for device in prefs.devices:
            device.use = True
        print(f"[Foton] GPU devices: {[d.name for d in prefs.devices if d.use]}")

    print(f"[Foton] Scene setup: {res_x}x{res_y}, camera={camera_name}, engine={engine}, format={fmt}")
PYEOF

echo "[Foton] Render setup script created."

# ═══════════════════════════════════════════════════════════════
# 11. TRANSITION TO RENDERING
# ═══════════════════════════════════════════════════════════════
curl -s -X POST "${FOTON_API_URL}/instances/report" \
  -H "Content-Type: application/json" \
  -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"status\": \"rendering\"}"
echo "[Foton] Status → rendering"

# ═══════════════════════════════════════════════════════════════
# 12. RENDER LOOP — frame by frame
# ═══════════════════════════════════════════════════════════════
RENDER_FAILED=false
FAILED_FRAME=""

for FRAME in $(seq "$FRAME_START" "$FRAME_INC" "$FRAME_END"); do
  PADDED=$(printf "%04d" "$FRAME")
  OUTPUT_PREFIX="/root/output/${OUTPUT_NAMING}_####"
  EXPECTED_FILE="/root/output/${OUTPUT_NAMING}_${PADDED}.${FILE_EXT}"

  echo "──────────────────────────────────────────"
  echo "[Foton] Rendering frame ${FRAME} / ${FRAME_END}..."

  # Render single frame
  /opt/blender/blender -b /root/scene.blend \
    -P /opt/blender/activate_gpu.py \
    -P /root/render_setup.py \
    -f "$FRAME" \
    -- "$RES_X" "$RES_Y" "$CAMERA" "$RENDER_ENGINE" "$BLENDER_FORMAT" "$OUTPUT_PREFIX"

  BLENDER_EXIT=$?

  # Verify output file exists
  if [ $BLENDER_EXIT -ne 0 ] || [ ! -f "$EXPECTED_FILE" ]; then
    echo "[Foton] ERROR: Frame ${FRAME} failed (exit code: ${BLENDER_EXIT})"
    RENDER_FAILED=true
    FAILED_FRAME=$FRAME
    break
  fi

  FILE_SIZE=$(stat -c%s "$EXPECTED_FILE" 2>/dev/null || echo "?")
  echo "[Foton] Frame ${FRAME} rendered (${FILE_SIZE} bytes). Uploading..."

  # Get presigned upload URL
  UPLOAD_RESPONSE=$(curl -s -X POST "${FOTON_API_URL}/instances/frame-upload-url" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"frameNumber\": ${FRAME}}")

  UPLOAD_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uploadUrl',''))" 2>/dev/null)

  if [ -z "$UPLOAD_URL" ]; then
    echo "[Foton] ERROR: Failed to get upload URL for frame ${FRAME}"
    RENDER_FAILED=true
    FAILED_FRAME=$FRAME
    break
  fi

  # Upload rendered frame to R2
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$UPLOAD_URL" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${EXPECTED_FILE}")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "[Foton] ERROR: Upload failed for frame ${FRAME} (HTTP ${HTTP_CODE})"
    RENDER_FAILED=true
    FAILED_FRAME=$FRAME
    break
  fi

  echo "[Foton] Frame ${FRAME} uploaded to R2."

  # Report progress
  curl -s -X POST "${FOTON_API_URL}/instances/progress" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"currentFrame\": ${FRAME}, \"completedFrame\": ${FRAME}}"

  # Clean up local file to save disk space
  rm -f "$EXPECTED_FILE"

done

echo "══════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════
# 13. REPORT FINAL STATUS
# ═══════════════════════════════════════════════════════════════
if [ "$RENDER_FAILED" = true ]; then
  echo "[Foton] Render FAILED at frame ${FAILED_FRAME}."
  FINAL_STATUS="failed"
else
  echo "[Foton] All frames rendered and uploaded successfully!"
  FINAL_STATUS="completed"
fi

curl -s -X POST "${FOTON_API_URL}/instances/report" \
  -H "Content-Type: application/json" \
  -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"status\": \"${FINAL_STATUS}\"}"

echo "[Foton] Reported status: ${FINAL_STATUS}. Instance will be destroyed by API."
