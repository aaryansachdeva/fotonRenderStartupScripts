import bpy

def enable_gpus():
    print("\n[Foton] Initializing GPU Setup...")
    preferences = bpy.context.preferences
    cycles_prefs = preferences.addons['cycles'].preferences
    cycles_prefs.refresh_devices()
    
    # Set to OPTIX for RTX cards (Faster than CUDA)
    cycles_prefs.compute_device_type = 'OPTIX'
    
    activated = 0
    for device in cycles_prefs.devices:
        if device.type == 'OPTIX':
            device.use = True
            print(f"[Foton] Activated: {device.name}")
            activated += 1
            
    # Fallback to CUDA if OPTIX fails
    if activated == 0:
        cycles_prefs.compute_device_type = 'CUDA'
        for device in cycles_prefs.devices:
            if device.type == 'CUDA':
                device.use = True
                print(f"[Foton] Activated (CUDA): {device.name}")
                activated += 1

    bpy.context.scene.cycles.device = 'GPU'
    print(f"[Foton] Setup Complete. Enabled {activated} GPUs.\n")

enable_gpus()
