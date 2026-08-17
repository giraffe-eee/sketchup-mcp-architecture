import importlib.util
import sys
import uuid


ROOT = r"D:\project\sketchup-mcp-architecture"
SERVER = ROOT + r"\mcp-server\sketchup_mcp_server.py"

spec = importlib.util.spec_from_file_location("skp", SERVER)
skp = importlib.util.module_from_spec(spec)
sys.modules["skp"] = skp
spec.loader.exec_module(skp)


def box(name, x, y, z, width, depth, height, color):
    return {
        "action": "create_box",
        "params": {
            "name": name, "x": x, "y": y, "z": z,
            "width": width, "depth": depth, "height": height, "color": color,
        },
    }


def cylinder(name, x, y, z, radius, height, color, segments=36):
    return {
        "action": "create_cylinder",
        "params": {
            "name": name, "x": x, "y": y, "z": z,
            "radius": radius, "height": height, "segments": segments, "color": color,
        },
    }


WHITE = "#F3F1E8"
BLACK = "#202326"
PINK = "#F2B7B1"
PINK_DARK = "#CF8C8B"
GRASS = "#78A94D"
SHADOW = "#497938"
TEXT = "#141414"


stages = [
    {
        "name": "Cow terrain and rounded body",
        "commands": [
            {"action": "create_slab", "params": {"name": "Grass field", "points": [[-11000, -10000], [13000, -10000], [13000, 9000], [-11000, 9000]], "z": -120, "thickness": 120, "color": GRASS}},
            cylinder("Soft ground shadow", 800, -50, 1, 5150, 28, SHADOW, 48),
            cylinder("Rounded body front", 850, 100, 28, 3050, 1710, WHITE, 48),
            cylinder("Rounded body rear", 3250, 350, 28, 2850, 1630, WHITE, 48),
            cylinder("Raised back volume", 2150, 450, 28, 2700, 1940, WHITE, 48),
            cylinder("Rounded head", -3200, -1300, 28, 1900, 1480, WHITE, 48),
            cylinder("Cheek volume", -2450, -1900, 28, 1340, 1120, WHITE, 40),
        ],
    },
    {
        "name": "Cow face ears and feet",
        "commands": [
            cylinder("Left black ear", -4520, -850, 1260, 720, 220, BLACK, 32),
            cylinder("Left ear inner", -4520, -850, 1485, 500, 38, PINK, 32),
            cylinder("Right black ear", -3000, 520, 1260, 680, 220, BLACK, 32),
            cylinder("Right ear inner", -3000, 520, 1485, 475, 38, PINK, 32),
            cylinder("Pink muzzle", -3450, -1950, 1480, 1290, 210, PINK, 40),
            cylinder("Muzzle highlight", -3650, -2150, 1692, 730, 24, "#F8CDCA", 32),
            cylinder("Near front hoof", -1950, -2500, 28, 880, 510, WHITE, 36),
            cylinder("Far front hoof", -650, -2100, 28, 780, 420, WHITE, 36),
            cylinder("Near rear hoof", 4420, -1750, 28, 840, 460, WHITE, 36),
            cylinder("Far rear hoof", 5200, 450, 28, 730, 400, WHITE, 36),
            cylinder("Warm belly detail", 1850, -1920, 28, 1180, 340, "#E7D6C4", 36),
            cylinder("Udder", 2950, -1520, 28, 620, 310, PINK_DARK, 32),
            cylinder("Udder teat near", 2670, -1830, 28, 190, 300, PINK_DARK, 24),
            cylinder("Udder teat rear", 3200, -1740, 28, 180, 280, PINK_DARK, 24),
        ],
    },
    {
        "name": "Cow markings and rear details",
        "commands": [
            cylinder("Forehead black patch", -3770, -830, 1485, 720, 45, BLACK, 32),
            cylinder("Face black patch", -2800, -820, 1485, 540, 45, BLACK, 32),
            cylinder("Left eye", -3780, -1450, 1705, 150, 42, BLACK, 24),
            cylinder("Right eye", -3140, -1550, 1705, 150, 42, BLACK, 24),
            cylinder("Eye shine left", -3825, -1495, 1747, 42, 18, "#FFFFFF", 16),
            cylinder("Eye shine right", -3185, -1595, 1747, 42, 18, "#FFFFFF", 16),
            cylinder("Nostril left", -3830, -2130, 1718, 105, 32, BLACK, 20),
            cylinder("Nostril right", -3310, -2200, 1718, 105, 32, BLACK, 20),
            cylinder("Large shoulder patch", 520, -180, 1740, 1060, 56, BLACK, 36),
            cylinder("Large back patch", 2220, 720, 1980, 940, 56, BLACK, 36),
            cylinder("Side oval patch", 2650, -1620, 1650, 900, 56, BLACK, 36),
            cylinder("Rump patch", 4700, 520, 1680, 780, 56, BLACK, 36),
            cylinder("Small flank patch", 3950, -1450, 1580, 500, 56, BLACK, 30),
            box("Tail stem", 5780, 980, 850, 150, 180, 1180, BLACK),
            cylinder("Tail tuft", 5855, 1070, 18, 330, 240, BLACK, 28),
            cylinder("Rear hoof mark", 4420, -1750, 505, 560, 48, BLACK, 32),
            cylinder("Front hoof mark", -1950, -2500, 505, 590, 48, BLACK, 32),
        ],
    },
]

# Block-style raised text, deliberately drawn as independent strokes so it remains editable.
text_commands = []

def h(name, x, y, w, t=130):
    text_commands.append(box(name, x, y, 4, w, t, 82, TEXT))


def v(name, x, y, hgt, t=130):
    text_commands.append(box(name, x, y, 4, t, hgt, 82, TEXT))


# 牛
x, y = -3900, -5700
h("Text 牛 top", x, y + 980, 1050); h("Text 牛 middle", x, y + 540, 1050); h("Text 牛 low", x + 120, y + 180, 810)
v("Text 牛 vertical", x + 455, y, 1200); v("Text 牛 left", x + 110, y + 690, 520)
# 不
x = -2100
h("Text 不 top", x, y + 980, 1050); h("Text 不 lower", x + 250, y + 320, 620)
v("Text 不 vertical", x + 455, y, 1200); v("Text 不 left branch", x + 100, y + 400, 420)
v("Text 不 right branch", x + 790, y + 400, 420)
# 行
x = -400
v("Text 行 left one", x + 100, y + 720, 420); h("Text 行 left top", x, y + 1040, 390); h("Text 行 left mid", x, y + 700, 420)
v("Text 行 right one", x + 700, y, 1250); h("Text 行 right top", x + 470, y + 1080, 650); h("Text 行 right mid", x + 470, y + 640, 680); h("Text 行 right low", x + 470, y + 140, 680)
# 了
x = 1500
h("Text 了 top", x, y + 1030, 1040); h("Text 了 middle", x + 110, y + 620, 790); v("Text 了 vertical", x + 715, y + 80, 920); h("Text 了 hook", x + 400, y + 80, 440)
stages.append({"name": "Raised Chinese title", "commands": text_commands})

start_stage = int(sys.argv[1]) if len(sys.argv) > 1 else 1

for index, stage in enumerate(stages, start=1):
    if index < start_stage:
        continue
    result = skp.execute_action("apply_batch", {"name": stage["name"], "commands": stage["commands"]}, request_id="cow-%s-%s" % (index, uuid.uuid4().hex[:10]))
    if result.get("error") or result.get("ok") is False:
        raise RuntimeError(result)
    print("completed:", stage["name"])

result = skp.execute_action("quality_check", {}, request_id="cow-check-" + uuid.uuid4().hex[:10])
print(result)
