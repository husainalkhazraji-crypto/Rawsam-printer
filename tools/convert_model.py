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
def tree(rev):
    url = f'https://huggingface.co/api/models/OzzyGT/lineart/tree/{rev}?recursive=1'
    return [f['path'] for f in json.load(urllib.request.urlopen(url)) if f['type'] == 'file']
nets = {}
def load(name, url, safetensors=False):
    path = name + ('.safetensors' if safetensors else '.pth')
    urllib.request.urlretrieve(url, path)
    if safetensors:
        from safetensors.torch import load_file
        state = load_file(path)
    else:
        state = torch.load(path, map_location='cpu')
    state = {k.replace('module.', ''): v for k, v in state.items()}
    net = Generator(3, 1, 3)
    net.load_state_dict(state)
    net.eval()
    nets[name] = net
    print('loaded', name)

load('main', 'https://huggingface.co/OzzyGT/lineart/resolve/main/lineart.safetensors', True)
old = '883121337c69e2a653b16ad4f3ef9fda72b51dd2'
try:
    for p in tree(old):
        if p.endswith('.pth') and '/' in p:
            load(p.split('/')[0], f'https://huggingface.co/OzzyGT/lineart/resolve/{old}/{p}')
except Exception as e:
    print('old revision failed:', e)
styles = list(nets)
print('styles:', styles)

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
