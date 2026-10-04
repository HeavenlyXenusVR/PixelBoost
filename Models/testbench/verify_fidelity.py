import numpy as np
from PIL import Image, ImageFilter
rng=np.random.default_rng(1)
# Source: textured "render" with hard edges.
H,W=96,128
y,x=np.mgrid[0:H,0:W]
src=(120+40*np.sin(x/2.1)*np.cos(y/1.7)+rng.normal(0,6,(H,W)))  # fine texture
src[20:70,30:90]+=60  # bright object w/ hard edge
src=np.clip(src,0,255).astype(np.uint8)
s=4
def up(a,size): return np.asarray(Image.fromarray(a).resize(size,Image.LANCZOS)).astype(np.float64)
def down(a,size): return np.asarray(Image.fromarray(np.clip(a,0,255).astype(np.uint8)).resize(size,Image.LANCZOS)).astype(np.float64)
# "GAN" model: smooths texture (painterly) + overshoots edges (dark/bright halos).
base=up(src,(W*s,H*s))
smooth=np.asarray(Image.fromarray(base.astype(np.uint8)).filter(ImageFilter.GaussianBlur(5))).astype(np.float64)
edges=base-np.asarray(Image.fromarray(base.astype(np.uint8)).filter(ImageFilter.GaussianBlur(2))).astype(np.float64)
model=np.clip(smooth+3.0*edges,0,255)
def psnr(a,b): m=np.mean((a-b)**2); return 10*np.log10(255**2/m)
def refine(c,step,tol):
    c=c.copy()
    if step>0:
        for _ in range(2):
            d=down(c,(W,H)); r=np.clip(128+src.astype(int)-d,0,255).astype(np.uint8)
            u=up(r,(W*s,H*s)); c=np.clip(c+np.floor((u-128)*int(step*256)/256),0,255)
    if tol is not None:
        from numpy.lib.stride_tricks import sliding_window_view as sw
        p=np.pad(src,1,mode='edge'); win=sw(p,(3,3)); lo=win.min((2,3)).astype(int); hi=win.max((2,3)).astype(int)
        sy=(np.arange(H*s)*H//(H*s)); sx=(np.arange(W*s)*W//(W*s))
        LO=lo[sy][:,sx]-tol; HI=hi[sy][:,sx]+tol; c=np.clip(c,LO,HI)
    return c
def halo(c):  # overshoot beyond local source range
    from numpy.lib.stride_tricks import sliding_window_view as sw
    p=np.pad(src,1,mode='edge'); win=sw(p,(3,3)); lo=win.min((2,3)); hi=win.max((2,3))
    sy=(np.arange(H*s)*H//(H*s)); sx=(np.arange(W*s)*W//(W*s))
    return np.mean(np.maximum(0,lo[sy][:,sx]-c)+np.maximum(0,c-hi[sy][:,sx]))
def detail(c): # high-frequency energy at source scale
    d=down(c,(W,H)); return np.mean(np.abs(d-np.asarray(Image.fromarray(d.astype(np.uint8)).filter(ImageFilter.GaussianBlur(1)))))
print("source detail      %.2f"%detail(np.asarray(Image.fromarray(src).resize((W*s,H*s),Image.NEAREST)).astype(float)))
for name,step,tol in [("raw model",0,None),("natural",0.55,10),("faithful",1.0,4)]:
    c=model if name=="raw model" else refine(model,step,tol)
    print(f"{name:10s} fidelity {psnr(down(c,(W,H)),src.astype(float)):5.2f} dB  halo {halo(c):5.2f}  detail {detail(c):.2f}")
