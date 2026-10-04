import numpy as np, itertools, random
# Port of ImageTiler.plan + PixelPlane.copyTile + native-scale row-copy stitch.
def plan(W,H,T,ov):
    core=T-2*ov; tiles=[]
    y=0
    while y<H:
        ch=min(core,H-y); x=0
        while x<W:
            cw=min(core,W-x)
            tiles.append(((x-ov,y-ov),(ov,ov,cw,ch)))
            x+=core
        y+=core
    return tiles
def copy_tile(src,origin,T):
    H,W=src.shape[:2]; ox,oy=origin
    out=np.empty((T,T)+src.shape[2:],src.dtype)
    mid_s=max(ox,0); mid_e=min(ox+T,W); mid=max(0,mid_e-mid_s); left=min(T,max(0,-ox))
    for r in range(T):
        sy=min(max(oy+r,0),H-1); row=src[sy]
        if mid>0:
            out[r,:left]=row[0]
            out[r,left:left+mid]=row[mid_s:mid_e]
            out[r,left+mid:]=row[W-1]
        else:
            for c in range(T): out[r,c]=row[min(max(ox+c,0),W-1)]
    return out
def model(tile,s):  # pointwise "model": nearest-neighbour s-x upscale, so stitched == reference exactly
    return tile.repeat(s,0).repeat(s,1)
def run(W,H,T,ov,s):
    rng=np.random.default_rng(W*1000+H)
    src=rng.integers(0,2**31,(H,W),dtype=np.int64)
    canvas=np.full((H*s,W*s),-1,np.int64); writes=np.zeros((H*s,W*s),np.int32)
    for (ox,oy),(kx,ky,cw,ch) in plan(W,H,T,ov):
        inp=copy_tile(src,(ox,oy),T)
        # clamp-to-edge check
        for r in range(T):
            for c in (0,T-1):
                assert inp[r,c]==src[min(max(oy+r,0),H-1),min(max(ox+c,0),W-1)]
        out=model(inp,s)
        cx,cy=ox+kx,oy+ky
        for row in range(ch*s):
            canvas[cy*s+row, cx*s:cx*s+cw*s]=out[ky*s+row, kx*s:kx*s+cw*s]
            writes[cy*s+row, cx*s:cx*s+cw*s]+=1
    assert (writes==1).all(), "pixel written != once"
    assert (canvas==model(src,s)).all(), "mismatch vs untiled"
cases=[(1,1,128,8,4),(5,300,128,8,4),(113,97,128,8,2),(1000,333,128,16,4),(224,224,128,8,4),(129,511,128,24,1),(640,480,128,8,4)]
for c in cases: run(*c); print("ok",c)
