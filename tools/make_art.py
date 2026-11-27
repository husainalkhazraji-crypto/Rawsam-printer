# يولّد الأيقونة والرسومات التجريبية وقت البناء.
import math, json, os
from PIL import Image, ImageDraw
root=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S=2400
def canvas():
    im=Image.new('L',(S,S),255); return im,ImageDraw.Draw(im)
def save(im,p):
    os.makedirs(os.path.dirname(p),exist_ok=True); im.resize((1200,1200),Image.LANCZOS).save(p,optimize=True)
c=S/2
def pol(r,a): return (c+r*math.cos(a), c+r*math.sin(a))
def petals(d,n,r0,r1,half,w,off=0):
    for i in range(n):
        a=off+2*math.pi*i/n
        pts=[]
        for side in (1,-1):
            seq=range(61) if side==1 else range(60,-1,-1)
            for k in seq:
                t=k/60; pts.append(pol(r0+(r1-r0)*t, a+side*half*math.sin(math.pi*t)))
        d.line(pts+[pts[0]],fill=0,width=w,joint='curve')
def ring(d,r,w): d.ellipse([c-r,c-r,c+r,c+r],outline=0,width=w)
im,d=canvas()
ring(d,120,14); petals(d,8,120,520,.30,14); ring(d,560,12); petals(d,16,560,850,.15,12,math.pi/16)
ring(d,890,12)
for i in range(32):
    x,y=pol(985,2*math.pi*i/32); d.ellipse([x-45,y-45,x+45,y+45],outline=0,width=12)
save(im,root+'/Designs/ماندالا/ماندالا.png')
im,d=canvas()
for R,n,k in [(1050,8,3),(720,6,1)]:
    p=[pol(R,2*math.pi*i/n-math.pi/2) for i in range(n)]
    d.line(p+[p[0]],fill=0,width=16,joint='curve')
    for i in range(n): d.line([p[i],p[(i+k)%n]],fill=0,width=10)
ring(d,180,14)
save(im,root+'/Designs/هندسي/نجمة هندسية.png')
im,d=canvas()
for j in range(5):
    petals(d,5+j,60+j*150,300+j*170,math.pi/(5+j)*.95,13,j*.45)
ring(d,60,14)
save(im,root+'/Designs/ورود/زهرة.png')
# icon: original mark (ink drop over rings), purple on dark
im=Image.new('RGB',(1024,1024),(22,16,36)); d=ImageDraw.Draw(im)
c=512
for r,col in [(400,(70,45,130)),(330,(105,70,190))]:
    d.ellipse([c-r,c-r,c+r,c+r],outline=col,width=14)
pts=[(c,190)]
cy,r=590,200
th=math.acos(r/(cy-190))
for k in range(121):
    a=(-math.pi/2+th)+(2*math.pi-2*th)*k/120
    pts.append((c+r*math.cos(a),cy+r*math.sin(a)))
d.polygon(pts,fill=(150,100,245))
d.arc([c-125,cy-125,c+125,cy+125],25,115,fill=(240,232,255),width=34)
os.makedirs(root+'/App/Assets.xcassets/AppIcon.appiconset',exist_ok=True)
im.save(root+'/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png')
open(root+'/App/Assets.xcassets/Contents.json','w').write(json.dumps({"info":{"author":"xcode","version":1}}))
open(root+'/App/Assets.xcassets/AppIcon.appiconset/Contents.json','w').write(json.dumps({"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}))
