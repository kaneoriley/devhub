# Renders the DevHub app icon with Cycles, following the macOS icon grid
# (824 px squircle body on a 1024 px canvas, light from the top).
# Usage: blender -b --factory-startup --python icon/icon.py -- icon/AppIcon.png [size] [samples] [layer]
# The app ships icon/AppIcon.icon, whose layers come from the grid, phone and droid
# layer renders. Run `swift icon/apple.swift` for the Apple-logo layer. Without a
# layer this previews the Blender layers only; the complete icon is compiled by build.sh.
#
# The bugdroid head is based on the Android robot, created and shared by Google
# under the Creative Commons Attribution 3.0 License.
import math
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "AppIcon.png"
SIZE = int(argv[1]) if len(argv) > 1 else 1024
SAMPLES = int(argv[2]) if len(argv) > 2 else 256
# With a layer name, renders only that part on a transparent canvas the size of the
# squircle, as a layer for icon/AppIcon.icon. The system draws the squircle itself.
LAYER = argv[3] if len(argv) > 3 else ""
LAYERS = {"grid": ("Grid",), "phone": ("Phone",), "droid": ("Head", "Antenna", "Eye")}

# 1 unit = 100 px of the 1024 px canvas.
CANVAS = 10.24
BODY = 8.24


def rgb(hex_color):
    """sRGB hex to linear RGBA."""
    c = [int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return tuple(((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c) + (1.0,)


def superellipse(a, n=5, steps=256):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((a * math.copysign(abs(c) ** (2 / n), c), a * math.copysign(abs(s) ** (2 / n), s)))
    return pts


def rounded_rect(w, h, r, steps=16):
    pts = []
    for cx, cy, start in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)):
        for i in range(steps + 1):
            a = math.radians(start + 90 * i / steps)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def dome(r, steps=96):
    """Half disc with the flat side down, closed by the cyclic spline."""
    return [(r * math.cos(math.pi * i / steps), r * math.sin(math.pi * i / steps)) for i in range(steps + 1)]


def material(name, top, bottom, half, alpha=1.0, roughness=0.4, coat=0.0, emission=0.0):
    """Principled BSDF with a vertical gradient over the object's local Y in [-half, half]."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    bsdf = nodes["Principled BSDF"]
    coords = nodes.new("ShaderNodeTexCoord")
    xyz = nodes.new("ShaderNodeSeparateXYZ")
    span = nodes.new("ShaderNodeMapRange")
    span.inputs["From Min"].default_value = -half
    span.inputs["From Max"].default_value = half
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = rgb(bottom)
    ramp.color_ramp.elements[1].color = rgb(top)
    links.new(coords.outputs["Object"], xyz.inputs[0])
    links.new(xyz.outputs["Y"], span.inputs["Value"])
    links.new(span.outputs["Result"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Alpha"].default_value = alpha
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Coat Weight"].default_value = coat
    if emission:
        links.new(ramp.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = emission
    return m


def slab(name, pts, mat, loc=(0, 0), z=0.0, depth=0.2, bevel=0.1, rot=0.0):
    """Extruded 2D outline with rounded edges. The outline keeps its size; z is the bottom."""
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "2D"
    cu.fill_mode = "BOTH"
    cu.extrude = depth / 2
    cu.bevel_depth = bevel
    cu.bevel_resolution = 8
    cu.offset = -bevel
    spline = cu.splines.new("POLY")
    spline.points.add(len(pts) - 1)
    for p, (x, y) in zip(spline.points, pts):
        p.co = (x, y, 0, 1)
    spline.use_cyclic_u = True
    ob = bpy.data.objects.new(name, cu)
    ob.location = (loc[0], loc[1], z + depth / 2 + bevel)
    ob.rotation_euler.z = rot
    ob.data.materials.append(mat)
    bpy.context.collection.objects.link(ob)
    return ob


def quad(name, x0, y0, x1, y1, z, mat):
    me = bpy.data.meshes.new(name)
    me.from_pydata([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new(name, me)
    ob.data.materials.append(mat)
    bpy.context.collection.objects.link(ob)
    return ob


for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob)

# Base: light squircle with a blueprint grid, like the other Xcode developer tools.
half = BODY / 2
base_depth, base_bevel = 0.2, 0.1
slab("Base", superellipse(half), material("Base", "#FFFFFF", "#EDF0F4", half, roughness=0.6, emission=0.2), depth=base_depth, bevel=base_bevel)
top = base_depth + 2 * base_bevel + 0.002
grid = material("Grid", "#C6D7EE", "#BFD1EA", half)
w = 0.028
for g in (-half / 2, 0, half / 2):
    reach = half if LAYER else half * (1 - abs(g / half) ** 5) ** (1 / 5) - base_bevel - 0.12
    quad(f"GridV{g}", g - w, -reach, g + w, reach, top, grid)
    quad(f"GridH{g}", -reach, g - w, reach, g + w, top + 0.001, grid)  # lifted so crossings don't z-fight

# Phone: blue glass slab.
phone_h = 5.6
slab("Phone", rounded_rect(3.25, phone_h, 0.7),
     material("Phone", "#6CB2FF", "#1E66F0", phone_h / 2, alpha=0.62, roughness=0.25, coat=1.0, emission=0.4),
     loc=(-1.0, 0.55), z=0.75, depth=0.14, bevel=0.1)

# Bugdroid head: green glass dome with antennae and eyes, over the phone's lower half.
r = 1.98
head = (1.05, -1.8)
green = material("Droid", "#86F2B4", "#34CF7E", r / 2, alpha=0.56, roughness=0.25, coat=1.0, emission=0.4)
# Centered on its own origin so the gradient spans the whole dome. Kept thin: seen
# through the glass, a tall wall along the flat base stacks into a dark line.
slab("Head", [(x, y - r / 2) for x, y in dome(r)], green, loc=(head[0], head[1] + r / 2), z=1.25, depth=0.08, bevel=0.06)
for angle in (58, 122):
    a = math.radians(angle)
    d = r + 0.3
    slab(f"Antenna{angle}", rounded_rect(0.2, 0.78, 0.1), green,
         loc=(head[0] + d * math.cos(a), head[1] + d * math.sin(a)), z=1.25, depth=0.08, bevel=0.05, rot=a - math.pi / 2)
eye = material("Eye", "#FFFFFF", "#F2F5F8", 0.2, roughness=0.3, emission=0.6)
for side in (-1, 1):
    slab(f"Eye{side}", superellipse(0.19, n=2, steps=64), eye, loc=(head[0] + side * 0.78, head[1] + 0.8), z=1.6, depth=0.04, bevel=0.03)

# Shadow catcher so the base casts its shadow into the transparent canvas.
catcher = quad("Catcher", -20, -20, 20, 20, -0.001, material("Catcher", "#FFFFFF", "#FFFFFF", 1))
catcher.is_shadow_catcher = True

# Camera straight on, light from the top like every macOS icon.
cam = bpy.data.cameras.new("Camera")
cam.type = "ORTHO"
cam.ortho_scale = BODY if LAYER else CANVAS
cam.clip_end = 100
cam_ob = bpy.data.objects.new("Camera", cam)
cam_ob.location = (0, 0, 30)
bpy.context.collection.objects.link(cam_ob)


def area(name, loc, size, power):
    light = bpy.data.lights.new(name, "AREA")
    light.size = size
    light.energy = power
    ob = bpy.data.objects.new(name, light)
    ob.location = loc
    ob.rotation_euler = (Vector((0, 0, 0)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    bpy.context.collection.objects.link(ob)


area("Key", (0, 10, 14), 12, 3200)
area("Fill", (0, -12, 10), 14, 1400)

if LAYER:
    for ob in bpy.data.objects:
        if ob.type in ("CURVE", "MESH") and not ob.name.startswith(LAYERS[LAYER]):
            ob.hide_render = True

scene = bpy.context.scene
scene.camera = cam_ob
scene.world = bpy.data.worlds.new("World")
scene.world.use_nodes = True
scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.85
scene.render.engine = "CYCLES"
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = SIZE
scene.render.resolution_percentage = 100
scene.view_settings.view_transform = "Standard"
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.filepath = OUT
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for device in prefs.devices:
        device.use = True
    scene.cycles.device = "GPU"
except Exception:
    pass

bpy.ops.render.render(write_still=True)
