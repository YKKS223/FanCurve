"""Builds and renders a fixed CPU-bound scene, so two runs do identical work.

Generated rather than shipped as a .blend so the workload is reproducible anywhere and
cannot drift. Cycles on the CPU with a fixed seed and sample count: every frame is the same
amount of arithmetic, which is what makes an A/B comparison meaningful.

Usage: Blender -b --factory-startup -P benchmark-scene.py -- <frames> <samples>
"""
import sys
import time

import bpy
import mathutils

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
# Calibrated on an M3 Max: 1920x1080 at 2048 samples on the GPU takes ~44.6 s a frame and
# holds the die at ~113 °C — the range where the thermal limiter actually does something.
# Frame times came out within 0.2 % of each other, which is what makes small differences
# between two runs detectable at all.
frames = int(argv[0]) if argv else 13
samples = int(argv[1]) if len(argv) > 1 else 2048
width = int(argv[2]) if len(argv) > 2 else 1920
# GPU by default: a local LLM leans on Metal too, the GPU is the bigger heat source on an
# M3 Max, and AppleCLPC budgets the whole SoC — so this is both the more representative and
# the more demanding load.
device = (argv[3] if len(argv) > 3 else "GPU").upper()

# Empty the factory scene so nothing from a default file affects the timing.
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

scene.render.engine = "CYCLES"

if device == "GPU":
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    enabled = []
    for d in prefs.devices:
        d.use = d.type == "METAL"
        if d.use:
            enabled.append(d.name)
    if enabled:
        scene.cycles.device = "GPU"
        print(f"BENCH_DEVICE GPU {'; '.join(enabled)}", flush=True)
    else:
        scene.cycles.device = "CPU"
        print("BENCH_DEVICE CPU (Metal が使えないため CPU に落としました)", flush=True)
else:
    scene.cycles.device = "CPU"
    print("BENCH_DEVICE CPU", flush=True)
scene.cycles.samples = samples
scene.cycles.use_denoising = False   # denoising time varies with content; exclude it
scene.cycles.seed = 1
scene.cycles.use_adaptive_sampling = False
scene.render.resolution_x = width
scene.render.resolution_y = width * 9 // 16
scene.render.resolution_percentage = 100
scene.render.filepath = "/tmp/fancurve-bench/frame_"
scene.render.image_settings.file_format = "PNG"
scene.frame_start = 1
scene.frame_end = frames

# A deterministic pile of geometry with glossy and transmissive materials: enough bounces to
# keep every core busy for a while, and identical every run.
for i in range(60):
    angle = i * 0.61
    radius = 1.2 + (i % 5) * 0.35
    bpy.ops.mesh.primitive_ico_sphere_add(
        subdivisions=3,
        radius=0.28,
        location=(radius * mathutils.Vector((1, 0, 0)).x * __import__("math").cos(angle),
                  radius * __import__("math").sin(angle),
                  (i % 7) * 0.22 - 0.6))
    obj = bpy.context.active_object
    mat = bpy.data.materials.new(f"m{i}")
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = ((i % 3) / 3, (i % 5) / 5, (i % 7) / 7, 1)
    bsdf.inputs["Roughness"].default_value = 0.05 + (i % 4) * 0.1
    bsdf.inputs["Metallic"].default_value = 1.0 if i % 2 else 0.0
    obj.data.materials.append(mat)

bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, -1.2))

bpy.ops.object.camera_add(location=(7, -7, 4.5), rotation=(1.1, 0, 0.785))
scene.camera = bpy.context.active_object
bpy.ops.object.light_add(type="AREA", location=(5, -4, 8))
bpy.context.active_object.data.energy = 4000

# One untimed frame first: Metal compiles its kernels on first use, which cost 85 s of the
# 90 s "first frame" during calibration. Measuring that would drown the signal.
print("BENCH_WARMUP start", flush=True)
warm = time.time()
scene.frame_set(1)
bpy.ops.render.render(write_still=False)
print(f"BENCH_WARMUP {time.time() - warm:.2f}", flush=True)

print(f"BENCH_START frames={frames} samples={samples} width={width}", flush=True)
overall = time.time()
for frame in range(1, frames + 1):
    scene.frame_set(frame)
    started = time.time()
    bpy.ops.render.render(write_still=True)
    print(f"BENCH_FRAME {frame} {time.time() - started:.2f}", flush=True)
print(f"BENCH_TOTAL {time.time() - overall:.2f}", flush=True)
