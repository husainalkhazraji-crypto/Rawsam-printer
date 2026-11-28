# يحوّل نموذج TEED (رخصة MIT) إلى Core ML حتى يشتغل داخل الآيفون بدون إنترنت.
# المصدر: https://github.com/xavysp/TEED  — الأوزان: https://huggingface.co/fal-ai/teed
import inspect, os
import numpy as np, torch, torch.nn as nn, coremltools as ct
from PIL import Image
from skimage import data
import controlnet_aux as ca
import controlnet_aux.teed as teed_module

out = 'model-out'; os.makedirs(out, exist_ok=True)
det = ca.TEEDdetector.from_pretrained('fal-ai/teed', filename='5_model.pth')
src = inspect.getsource(type(det).__call__)
print(src)
net = det.model.eval().cpu()

class Wrap(nn.Module):
    """نفس معالجة controlnet_aux: متوسط المخرجات، sigmoid، وبعدين نعكس حتى الخطوط تصير غامقة على أبيض."""
    def __init__(self, g): super().__init__(); self.g = g
    def forward(self, x):                   # x: صورة RGB بقيم 0..255
        edges = self.g(x)
        if not isinstance(edges, (list, tuple)): edges = [edges]
        edge = torch.sigmoid(torch.stack([e[:, :1] for e in edges], 0).mean(0))
        return (1 - edge) * 255.0

wrap = Wrap(net).eval()

# نتأكد أن الغلاف يطلع نفس نتيجة controlnet_aux
im = Image.fromarray(data.astronaut()).resize((768, 768))
ref = np.asarray(det(im, detect_resolution=768, safe_steps=0).convert('L').resize((768, 768)), np.float32)
x = torch.from_numpy(np.asarray(im, np.float32)).permute(2, 0, 1)[None]
with torch.no_grad(): mine = wrap(x)[0, 0].numpy()
print('mean abs diff vs controlnet_aux (0..255):', float(np.abs((255 - mine) - ref).mean()))
Image.fromarray(mine.clip(0, 255).astype(np.uint8)).save(f'{out}/teed_check.png')

traced = torch.jit.trace(wrap, torch.rand(1, 3, 768, 768) * 255)
model = ct.convert(traced,
                   inputs=[ct.ImageType(name='image', shape=(1, 3, 768, 768), scale=1.0,
                                        color_layout=ct.colorlayout.RGB)],
                   outputs=[ct.ImageType(name='lines', color_layout=ct.colorlayout.GRAYSCALE)],
                   minimum_deployment_target=ct.target.iOS17,
                   convert_to='mlprogram', compute_precision=ct.precision.FLOAT16)
model.short_description = 'TEED edge detection (MIT, Xavier Soria Poma 2022)'
model.save(f'{out}/LineArt_teed.mlpackage')
print('done')
