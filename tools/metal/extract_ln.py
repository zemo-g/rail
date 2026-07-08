import json, struct, sys, os

ST = os.environ.get("RAILML_ST", os.path.expanduser("~/.ledatic/railml-trial/canonical_bestpass.safetensors"))
OUT = "/tmp/agk/ln_P.txt"

def pq_pow2(k): return 1 if k < 1 else (1 << k)
def pq_f32(b0,b1,b2,b3):
    bits = b0 + b1*256 + b2*65536 + b3*16777216
    sign = bits // 2147483648
    rest = bits - sign*2147483648
    exp  = rest // 8388608
    mant = rest - exp*8388608
    if exp == 0: return 0
    mag = 8388608 + mant
    sh = exp - 126
    if sh >= 0: xabs = mag * pq_pow2(sh)
    else:
        d = pq_pow2(-sh); xabs = (mag + d//2)//d
    return -xabs if sign==1 else xabs

with open(ST,"rb") as f:
    hlen = struct.unpack("<Q", f.read(8))[0]
    hdr = json.loads(f.read(hlen))
    data0 = 8 + hlen
    def tensor_bytes(name):
        m = hdr[name]; s,e = m["data_offsets"]
        f.seek(data0 + s); return f.read(e - s), m["shape"], m["dtype"]
    tok,_,_ = tensor_bytes("tok.weight")
    pos,_,_ = tensor_bytes("pos.weight")
    g,_,_   = tensor_bytes("blocks.0.ln1.weight")
    b,_,_   = tensor_bytes("blocks.0.ln1.bias")

D = 768
ids = [328,2432,554,183,12154,533,197,27,661]
last, lp = ids[-1], len(ids)-1   # last token id, position 8

def decf(buf, idx):
    o = idx*4; return pq_f32(buf[o],buf[o+1],buf[o+2],buf[o+3])

hidden = [decf(tok, last*D + j) + decf(pos, lp*D + j) for j in range(D)]
gamma  = [decf(g, j) for j in range(D)]
beta   = [decf(b, j) for j in range(D)]

# reference LayerNorm (replicate gp_layernorm at F=24) for a full-vector twin check
def mul_shr(a,bv,s): return (a*bv) >> s   # floor, matches Rail smulh/mul
s = sum(hidden); mean = int(s / D) if s>=0 else -int((-s)//D) if False else (s // D if s>=0 else -((-s)//D))
# Rail integer / truncates toward zero:
def tdiv(a,bv):
    q = abs(a)//abs(bv)
    return q if (a<0)==(bv<0) else -q
mean = tdiv(s, D)
vs = sum(mul_shr(hidden[i]-mean, hidden[i]-mean, 24) for i in range(D)); var = tdiv(vs, D)
# fxrsqrt24
def sqrt_le(r,xq):
    hr = mul_shr(r,r,24)
    if hr < xq: return True
    if hr > xq: return False
    c = r - tdiv(r,16777216)*16777216; cc = c*c
    return (cc - tdiv(cc,16777216)*16777216)==0
def fxsqrt24(xq):
    if xq<1: return 0
    lo,hi = 0,(16384*16384)*4096
    while lo+1<hi:
        mid=(lo+hi)//2
        if sqrt_le(mid,xq): lo=mid
        else: hi=mid
    return lo
q = fxsqrt24(var+168); inv = 0 if q==0 else 281474976710656//q
ref = [mul_shr(mul_shr(hidden[i]-mean,inv,24), gamma[i],24) + beta[i] for i in range(D)]

with open(OUT,"w") as o:
    for v in hidden+gamma+beta: o.write(f"{v}\n")
with open("/tmp/agk/ln_ref.txt","w") as o:
    for v in ref: o.write(f"{v}\n")
print("wrote P (2304 vals) + ref (768).  ref[0..2] =", ref[0], ref[1], ref[2])
print("golden expected            = -3450268 6448591 1702770")
print("MATCH" if ref[:3]==[-3450268,6448591,1702770] else "MISMATCH (decode/format off)")
