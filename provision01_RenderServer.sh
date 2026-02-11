#!/bin/bash
                                          
# --- FOTONLABS PROVISIONING PROTOCOL ---      
                                     
# 1. MARKER: Create a flag so we know installation is in progress
touch /root/installing               
echo "[Foton] Starting Provisioning..."    
                                       
# 2. INSTALL SYSTEM DEPENDENCIES           
apt-get update -qq                      
apt-get install -y -qq wget xz-utils libgl1 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxxf86vm1 libsm6 libxext6 openssh-server python3

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
  echo "[Foton] Heartbeat started."
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
  curl -o /root/scene.blend "$BLEND_URL"

  # Report blend downloaded
  curl -s -X POST "${FOTON_API_URL}/instances/report" \
    -H "Content-Type: application/json" \
    -d "{\"taskId\": \"${FOTON_TASK_ID}\", \"token\": \"${FOTON_INSTANCE_TOKEN}\", \"blendDownloaded\": true}"
  echo "[Foton] Blend file ready."
fi

# 8. MARKER: DONE                              
rm /root/installing                    
touch /root/ready                               
echo "[Foton] Node Fully Provisioned & Ready."
