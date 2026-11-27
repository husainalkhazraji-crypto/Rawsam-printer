# يحوّل نموذج Informative Drawings (رخصة MIT) إلى Core ML حتى يشتغل داخل الآيفون بدون إنترنت.
# المصدر: https://github.com/carolineec/informative-drawings
# الأوزان: https://huggingface.co/OzzyGT/lineart (نفس رخصة MIT)
import glob, os, sys, urllib.request
import numpy as np, torch, torch.nn as nn, coremltools as ct
from PIL import Image

sys.path.insert(0, 'informative-drawings')
from model import Generator

out = 'model-out'
os.makedirs(out, exist_ok=True)
import json
files = [f['path'] for f in json.load(urllib.request.urlopen('https://huggingface.co/api/models/OzzyGT/lineart/tree/main?recursive=1')) if f['type'] == 'file']
print('repo files:', files)
weights = {p.split('/')[0]: p for p in files if p.endswith('.pth') and '/' in p}
styles = sorted(weights)
print('styles:', styles)
nets = {}
for style in styles:
    path = f'{style}.pth'
    urllib.request.urlretrieve(f'https://huggingface.co/OzzyGT/lineart/resolve/main/{weights[style]}', path)
    state = torch.load(path, map_location='cpu')
    state = {k.replace('module.', ''): v for k, v in state.items()}
    net = Generator(3, 1, 3)
    net.load_state_dict(state)
    net.eval()
    nets[style] = net

# عيّنات للمقارنة
samples = sorted(glob.glob('informative-drawings/examples/test/*'))[:4] + sorted(glob.glob('tools/samples/*'))
rows = []
for p in samples:
    im = Image.open(p).convert('RGB'); im.thumbnail((512, 512))
    w, h = im.width // 4 * 4, im.height // 4 * 4
    im = im.crop((0, 0, w, h))
    x = torch.from_numpy(np.asarray(im, np.float32) / 255).permute(2, 0, 1)[None]
    tiles = [im]
    with torch.no_grad():
        for s in styles:
            y = nets[s](x)[0, 0].numpy()
            tiles.append(Image.fromarray((y * 255).clip(0, 255).astype(np.uint8)).convert('RGB'))
    row = Image.new('RGB', (w * len(tiles), h), 'white')
    for i, t in enumerate(tiles): row.paste(t, (i * w, 0))
    rows.append(row)
W = max(r.width for r in rows); H = sum(r.height for r in rows)
sheet = Image.new('RGB', (W, H), 'gray'); y = 0
for r in rows: sheet.paste(r, (0, y)); y += r.height
sheet.save(f'{out}/samples.jpg', quality=85)

class Wrap(nn.Module):
    def __init__(self, g): super().__init__(); self.g = g
    def forward(self, x): return self.g(x) * 255.0

for style in styles:
    traced = torch.jit.trace(Wrap(nets[style]).eval(), torch.rand(1, 3, 512, 512))
    side = ct.RangeDim(lower_bound=128, upper_bound=1536, default=512)
    model = ct.convert(traced,
                       inputs=[ct.ImageType(name='image', shape=(1, 3, side, side), scale=1 / 255.0,
                                            color_layout=ct.colorlayout.RGB)],
                       outputs=[ct.ImageType(name='lines', color_layout=ct.colorlayout.GRAYSCALE)],
                       minimum_deployment_target=ct.target.iOS17,
                       convert_to='mlprogram', compute_precision=ct.precision.FLOAT16)
    model.short_description = 'Informative Drawings line art (MIT, Caroline Chan 2022)'
    model.save(f'{out}/LineArt_{style}.mlpackage')
print('done')
