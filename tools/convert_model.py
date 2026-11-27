# يحوّل نماذج Informative Drawings (رخصة MIT) إلى Core ML حتى تشتغل داخل الآيفون بدون إنترنت.
# المصدر: https://github.com/carolineec/informative-drawings
# contour: https://huggingface.co/OzzyGT/lineart (MIT)
# opensketch: https://huggingface.co/backnotprop/informative-drawings-image-to-opensketch-onnx (MIT)
import glob, json, os, sys, time, urllib.request
import numpy as np, torch, torch.nn as nn, coremltools as ct
from PIL import Image
from scipy import ndimage as ndi

sys.path.insert(0, 'informative-drawings')
from model import Generator

out = 'model-out'
os.makedirs(out, exist_ok=True)
nets = {}

def hf_files(repo):
    url = f'https://huggingface.co/api/models/{repo}/tree/main?recursive=1'
    return [f['path'] for f in json.load(urllib.request.urlopen(url)) if f['type'] == 'file']

# contour (safetensors)
urllib.request.urlretrieve('https://huggingface.co/OzzyGT/lineart/resolve/main/lineart.safetensors', 'contour.safetensors')
from safetensors.torch import load_file
g = Generator(3, 1, 3); g.load_state_dict({k.replace('module.', ''): v for k, v in load_file('contour.safetensors').items()}); g.eval()
nets['contour'] = g

# opensketch (ONNX -> torch)
repo = 'backnotprop/informative-drawings-image-to-opensketch-onnx'
files = hf_files(repo); print(repo, files)
onnx_file = [f for f in files if f.endswith('.onnx')][0]
urllib.request.urlretrieve(f'https://huggingface.co/{repo}/resolve/main/{onnx_file}', 'opensketch.onnx')
import onnx
from onnx2torch import convert
m = onnx.load('opensketch.onnx')
print('onnx inputs', [(i.name, [d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim]) for i in m.graph.input])
print('onnx outputs', [(o.name, [d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim]) for o in m.graph.output])
os_net = convert(m).eval()
nets['opensketch'] = os_net

def dodge(gray):
    sc = max(gray.shape) / 1000
    inv = ndi.gaussian_filter(1 - gray, 7 * sc)
    return np.clip(gray / np.maximum(1 - inv, 1e-3), 0, 1)

def run(name, x):
    with torch.no_grad():
        y = nets[name](x)
    if isinstance(y, (list, tuple)): y = y[0]
    return y[0, 0].numpy()

samples = sorted(glob.glob('informative-drawings/examples/test/*'))[:3]
rows = []
for p in samples:
    im = Image.open(p).convert('RGB'); im.thumbnail((768, 768))
    w, h = im.width // 4 * 4, im.height // 4 * 4
    im = im.crop((0, 0, w, h))
    x = torch.from_numpy(np.asarray(im, np.float32) / 255).permute(2, 0, 1)[None]
    gray = np.asarray(im.convert('L'), np.float32) / 255
    tiles = [im, Image.fromarray((dodge(gray) * 255).astype(np.uint8))]
    for name in nets:
        t = time.time(); y = run(name, x); print(name, 'took', round(time.time() - t, 2), 's, range', float(y.min()), float(y.max()))
        tiles.append(Image.fromarray((np.clip(y, 0, 1) * 255).astype(np.uint8)))
    row = Image.new('RGB', (w * len(tiles), h), 'white')
    for i, t in enumerate(tiles): row.paste(t.convert('RGB'), (i * w, 0))
    rows.append(row)
W = max(r.width for r in rows); H = sum(r.height for r in rows)
sheet = Image.new('RGB', (W, H), 'gray'); y = 0
for r in rows: sheet.paste(r, (0, y)); y += r.height
sheet.thumbnail((2400, 2400)); sheet.save(f'{out}/samples.jpg', quality=85)

class Wrap(nn.Module):
    def __init__(self, g): super().__init__(); self.g = g
    def forward(self, x):
        y = self.g(x)
        if isinstance(y, (list, tuple)): y = y[0]
        return torch.clamp(y, 0, 1) * 255.0

for name in nets:
    try:
        traced = torch.jit.trace(Wrap(nets[name]).eval(), torch.rand(1, 3, 768, 768))
        model = ct.convert(traced,
                           inputs=[ct.ImageType(name='image', shape=(1, 3, 768, 768), scale=1 / 255.0,
                                                color_layout=ct.colorlayout.RGB)],
                           outputs=[ct.ImageType(name='lines', color_layout=ct.colorlayout.GRAYSCALE)],
                           minimum_deployment_target=ct.target.iOS17,
                           convert_to='mlprogram', compute_precision=ct.precision.FLOAT16)
        model.short_description = f'Informative Drawings {name} (MIT, Caroline Chan 2022)'
        model.save(f'{out}/LineArt_{name}.mlpackage')
        print('converted', name)
    except Exception as e:
        print('convert failed', name, e)
print('done')
