# يولّد أيقونة التطبيق ولوكو الواجهة من branding/logo.png وقت البناء.
import json, os
from PIL import Image, ImageChops
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
assets = os.path.join(root, 'App', 'Assets.xcassets')

logo = Image.open(os.path.join(root, 'branding', 'logo.png')).convert('RGBA')
flat = Image.new('RGBA', logo.size, 'white'); flat.alpha_composite(logo); flat = flat.convert('RGB')
# نقص الحواف البيضاء
box = ImageChops.difference(flat, Image.new('RGB', flat.size, 'white')).convert('L').point(lambda v: 255 if v > 24 else 0).getbbox()
art = flat.crop(box)

def write(folder, contents, files):
    path = os.path.join(assets, folder); os.makedirs(path, exist_ok=True)
    for name, im in files.items(): im.save(os.path.join(path, name))
    open(os.path.join(path, 'Contents.json'), 'w').write(json.dumps(contents))

# الأيقونة: اللوكو على خلفية بيضاء مع هامش
side = int(max(art.size) * 1.22)
icon = Image.new('RGB', (side, side), 'white')
icon.paste(art, ((side - art.width) // 2, (side - art.height) // 2))
write('AppIcon.appiconset',
      {"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}},
      {'AppIcon.png': icon.resize((1024, 1024), Image.LANCZOS)})

# لوكو الواجهة بخلفية شفافة
h = 240; small = art.resize((int(art.width * h / art.height), h), Image.LANCZOS).convert('RGBA')
px = small.load()
for y in range(small.height):
    for x in range(small.width):
        r, g, b, _ = px[x, y]
        px[x, y] = (r, g, b, 255 - min(r, g, b) if min(r, g, b) > 200 and max(r, g, b) - min(r, g, b) < 40 else 255)
write('Logo.imageset',
      {"images": [{"filename": "Logo.png", "idiom": "universal", "scale": "3x"}], "info": {"author": "xcode", "version": 1}},
      {'Logo.png': small})
open(os.path.join(assets, 'Contents.json'), 'w').write(json.dumps({"info": {"author": "xcode", "version": 1}}))
