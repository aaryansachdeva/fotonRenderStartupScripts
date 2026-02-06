#!/bin/bash

# --- FOTONLABS PROVISIONING PROTOCOL ---

# 1. MARKER: Create a flag so we know installation is in progress
touch /root/installing
echo "[Foton] Starting Provisioning..."

# 2. INSTALL SYSTEM DEPENDENCIES
# We use -qq (quiet) to keep the logs clean
# These are the exact libraries we verified manually earlier
apt-get update -qq
apt-get install -y -qq wget xz-utils libgl1 libxrandr2 libxinerama1 \
    libxcursor1 libxi6 libxxf86vm1 libsm6 libxext6 openssh-server python3

# 3. INSTALL BLENDER 5.0.1
# We check if it exists first. This makes restarts instant (idempotency).
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
# We overwrite this every time so you can update logic via GitHub instantly
echo "[Foton] Fetching GPU Logic from GitHub..."
wget -q -O /opt/blender/activate_gpu.py https://raw.githubusercontent.com/aaryansachdeva/fotonRenderStartupScripts/refs/heads/main/activate_gpu.py

# 5. SETUP SSH
# This ensures the SSH daemon is running so your Desktop App can connect
mkdir -p /var/run/sshd
service ssh start

# 6. MARKER: DONE
# We remove the 'installing' flag and create 'ready'.
# Your Desktop App will look for this file to know it can start uploading.
rm /root/installing
touch /root/ready
echo "[Foton] Node Fully Provisioned & Ready."
