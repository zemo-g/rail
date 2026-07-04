import json, struct

ST = "/Users/ledaticempire/.ledatic/railml-trial/canonical_bestpass.safetensors"
D = 768

def pq_pow2(k): return 1 if k < 1 else (1 << k)
def pq_f32(b0,b1,b2,b3):
    bits=b0+b1*256+b2*65536+b3*16777216
    sign=bits//2147483648; rest=bits-sign*2147483648
    exp=rest//8388608; mant=rest-exp*8388608
    if exp==0: return 0
    mag=8388608+mant; sh=exp-126
    if sh>=0: xabs=mag*pq_pow2(sh)
    else: d=pq_pow2(-sh); xabs=(mag+d//2)//d
    return -xabs if sign==1 else xabs

with open(ST,"rb") as f:
    hlen=struct.unpack("<Q",f.read(8))[0]; hdr=json.loads(f.read(hlen)); data0=8+hlen
    def tb(name):
        m=hdr[name]; s,e=m["data_offsets"]; f.seek(data0+s); return f.read(e-s)
    tok=tb("tok.weight"); pos=tb("pos.weight")
    g1=tb("blocks.0.ln1.weight"); b1=tb("blocks.0.ln1.bias")
    wq=tb("blocks.0.attn.query_proj.weight")

def decf(buf,idx): o=idx*4; return pq_f32(buf[o],buf[o+1],buf[o+2],buf[o+3])
def mul_shr(a,b,s): return (a*b)>>s
def tdiv(a,b):
    q=abs(a)//abs(b); return q if (a<0)==(b<0) else -q

# real last-token hidden -> real ln1 output (xn), the matvec input
ids=[328,2432,554,183,12154,533,197,27,661]; last,lp=ids[-1],len(ids)-1
hidden=[decf(tok,last*D+j)+decf(pos,lp*D+j) for j in range(D)]
gamma=[decf(g1,j) for j in range(D)]; beta=[decf(b1,j) for j in range(D)]
s=sum(hidden); mean=tdiv(s,D)
vs=sum(mul_shr(hidden[i]-mean,hidden[i]-mean,24) for i in range(D)); var=tdiv(vs,D)
def sqrt_le(r,xq):
    hr=mul_shr(r,r,24)
    if hr<xq: return True
    if hr>xq: return False
    c=r-tdiv(r,16777216)*16777216; cc=c*c
    return (cc-tdiv(cc,16777216)*16777216)==0
def fxsqrt24(xq):
    if xq<1: return 0
    lo,hi=0,(16384*16384)*4096
    while lo+1<hi:
        m=(lo+hi)//2
        if sqrt_le(m,xq): lo=m
        else: hi=m
    return lo
q=fxsqrt24(var+168); inv=0 if q==0 else 281474976710656//q
xn=[mul_shr(mul_shr(hidden[i]-mean,inv,24),gamma[i],24)+beta[i] for i in range(D)]

# query_proj weights -> Q24 (768*768)
Wq=[decf(wq,i) for i in range(D*D)]

# matmul packed: W(768*768) | xn(768)
with open("/tmp/agk/mm_P.txt","w") as o:
    for v in Wq: o.write(f"{v}\n")
    for v in xn: o.write(f"{v}\n")

# GELU sweep: -6.0 .. 6.0 in F24, plus the real MLP-scale range
N=512
gin=[int(round((-6.0 + 12.0*i/(N-1))*16777216)) for i in range(N)]
with open("/tmp/agk/gelu_in.txt","w") as o:
    for v in gin: o.write(f"{v}\n")

print(f"wrote mm_P (589824+768) + gelu_in ({N}).  xn[0..2]={xn[0]} {xn[1]} {xn[2]}")
print(f"Wq[0..2]={Wq[0]} {Wq[1]} {Wq[2]}")
