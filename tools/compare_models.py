# يقارن نماذج تحويل الصور لخطوط (مجانية وتشتغل داخل التلفون) جنب الرسم العادي.
# الصور: صور عامة من scikit-image (رائدة فضاء من ناسا، قطة، قهوة) وأمثلة informative-drawings.
import glob, os, traceback, urllib.request
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi
from skimage import data

out = 'compare-out'; os.makedirs(out, exist_ok=True)
imgs = [Image.fromarray(data.astronaut()), Image.fromarray(data.chelsea()), Image.fromarray(data.coffee())]
imgs += [Image.open(p).convert('RGB') for p in sorted(glob.glob('informative-drawings/examples/test/*'))[:2]]
for i in range(len(imgs)):
    im = imgs[i]; im.thumbnail((640, 640)); imgs[i] = im.crop((0, 0, im.width // 8 * 8, im.height // 8 * 8))

def clean(black, area=10):
    lab, n = ndi.label(black, np.ones((3, 3)))
    if n == 0: return black
    sz = ndi.sum(black, lab, range(1, n + 1)); keep = np.zeros(n + 1, bool); keep[1:] = sz >= area
    return keep[lab]

def to_stencil(lines01, cut):  # lines01: 0 = black line, 1 = white
    return Image.fromarray(np.where(clean(lines01 < cut), 0, 255).astype(np.uint8))

def normal(im):
    g = np.asarray(im.convert('L'), np.float32) / 255
    inv = ndi.gaussian_filter(1 - g, 7 * max(g.shape) / 1000)
    return to_stencil(np.clip(g / np.maximum(1 - inv, 1e-3), 0, 1), 0.86)

methods = [('Normal (current)', normal)]

def add(name, fn): methods.append((name, fn))

try:
    import onnxruntime as ort
    urllib.request.urlretrieve('https://huggingface.co/backnotprop/informative-drawings-image-to-opensketch-onnx/resolve/main/model.onnx', 'os.onnx')
    sess = ort.InferenceSession('os.onnx')
    def opensketch(im):
        x = (np.asarray(im, np.float32) / 255).transpose(2, 0, 1)[None]
        y = sess.run(None, {'input': x})[0][0, 0]
        return to_stencil(np.clip(y, 0, 1), 0.53)
    add('AI opensketch (current)', opensketch)
except Exception: traceback.print_exc()

def aux(name, factory, call):
    try:
        det = factory()
        def fn(im):
            r = call(det, im).convert('L').resize(im.size)
            a = 1 - np.asarray(r, np.float32) / 255   # الخطوط بيضاء على أسود، نعكسها
            return to_stencil(a, 0.6)
        fn(imgs[0]); add(name, fn); print('ok', name)
    except Exception:
        print('FAILED', name); traceback.print_exc()

import controlnet_aux as ca
aux('TEED', lambda: ca.TEEDdetector.from_pretrained('fal-ai/teed', filename='5_model.pth'),
    lambda d, im: d(im, detect_resolution=640))
aux('Anyline (MistoLine)', lambda: ca.AnylineDetector.from_pretrained('TheMistoAI/MistoLine', filename='MTEED.pth', subfolder='Anyline'),
    lambda d, im: d(im, detect_resolution=640, guassian_sigma=2.0, intensity_threshold=3))
aux('PiDiNet', lambda: ca.PidiNetDetector.from_pretrained('lllyasviel/Annotators'),
    lambda d, im: d(im, detect_resolution=640, image_resolution=640, safe=True))
aux('HED', lambda: ca.HEDdetector.from_pretrained('lllyasviel/Annotators'),
    lambda d, im: d(im, detect_resolution=640, image_resolution=640, safe=True))
aux('Lineart realistic', lambda: ca.LineartDetector.from_pretrained('lllyasviel/Annotators'),
    lambda d, im: d(im, detect_resolution=640, image_resolution=640))
aux('Lineart coarse', lambda: ca.LineartDetector.from_pretrained('lllyasviel/Annotators'),
    lambda d, im: d(im, detect_resolution=640, image_resolution=640, coarse=True))
aux('Lineart anime', lambda: ca.LineartAnimeDetector.from_pretrained('lllyasviel/Annotators'),
    lambda d, im: d(im, detect_resolution=640, image_resolution=640))

# ورقة المقارنة: كل عمود طريقة، كل صف صورة
cell = 300; label = 26
names = ['Original'] + [m[0] for m in methods]
sheet = Image.new('RGB', (cell * len(names), label + cell * len(imgs)), 'white')
d = ImageDraw.Draw(sheet)
for j, n in enumerate(names): d.text((j * cell + 6, 6), f'{j}. {n}', fill='black')
for i, im in enumerate(imgs):
    tiles = [im] + [fn(im) for _, fn in methods]
    for j, t in enumerate(tiles):
        t = t.convert('RGB'); t.thumbnail((cell - 6, cell - 6))
        sheet.paste(t, (j * cell + 3, label + i * cell + 3))
sheet.save(f'{out}/compare.jpg', quality=88)
for j, (n, fn) in enumerate(methods):  # نسخة كبيرة لصورة الوجه
    fn(imgs[0]).save(f'{out}/face_{j + 1}.png')
print('done')
