// plasma_3d_host.m — Real-time 3D MHD plasma (Metal compute + volume render)
// Built from Rail: ./rail_native run tools/plasma/plasma_3d.rail

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include <simd/simd.h>
#include <math.h>

#define GN 128
#define GN2 (GN*GN)
#define GN3 (GN*GN*GN)
#define NFIELDS 8
#define STEPS_PER_FRAME 3
#define DT_FIXED 0.002f
#define DX_F (6.283185307179586f / GN)
#define GAMMA_F 1.6666666666666667f
#define GAMMA_M1_F 0.6666666666666667f

typedef struct { float dt,dx,gamma,gamma_m1; uint32_t n,n2,n3,pad; } MHDParams;
typedef struct {
    simd_float4 eye, right, up, fwd, domain, screen;
} RenderParams;

// ═══════════════════════════════════════════════════════════
// PlasmaView — MTKView + mouse/keyboard
// ═══════════════════════════════════════════════════════════

@interface PlasmaView : MTKView
@property float camTheta, camPhi, camDist;
@property NSPoint lastMouse;
@property BOOL dragging, simPaused;
@end

@implementation PlasmaView
- (instancetype)initWithFrame:(CGRect)f device:(id<MTLDevice>)d {
    self = [super initWithFrame:f device:d];
    if (self) { _camTheta=0.5; _camPhi=0.3; _camDist=1.5; }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)mouseDown:(NSEvent*)e {
    _lastMouse = [self convertPoint:e.locationInWindow fromView:nil]; _dragging=YES;
}
- (void)mouseUp:(NSEvent*)e { _dragging=NO; }
- (void)mouseDragged:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _camTheta += (p.x - _lastMouse.x) * 0.01f;
    _camPhi = fminf(1.5f, fmaxf(-1.5f, _camPhi + (p.y - _lastMouse.y) * 0.01f));
    _lastMouse = p;
}
- (void)scrollWheel:(NSEvent*)e {
    _camDist = fmaxf(0.5f, fminf(5.0f, _camDist - (float)e.deltaY * 0.05f));
}
- (void)keyDown:(NSEvent*)e {
    if ([e.characters isEqualToString:@" "]) _simPaused = !_simPaused;
}
@end

// ═══════════════════════════════════════════════════════════
// Renderer
// ═══════════════════════════════════════════════════════════

@interface Renderer : NSObject <MTKViewDelegate>
@property id<MTLDevice> device;
@property id<MTLCommandQueue> queue;
@property id<MTLComputePipelineState> stepPipe, vizPipe;
@property id<MTLRenderPipelineState> renderPipe;
@property id<MTLBuffer> stateA, stateB, vizBuf;
@property BOOL useA;
@property float simTime;
@property uint32_t frames;
@property (weak) PlasmaView *pv;
@end

@implementation Renderer

- (instancetype)initWithView:(PlasmaView*)view {
    self = [super init];
    if (!self) return nil;
    _pv = view; _device = view.device;
    _queue = [_device newCommandQueue];
    _useA = YES; _simTime = 0; _frames = 0;

    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithURL:
        [NSURL fileURLWithPath:@"/tmp/plasma_3d.metallib"] error:&err];
    if (!lib) { NSLog(@"metallib: %@", err); exit(1); }

    _stepPipe = [_device newComputePipelineStateWithFunction:
        [lib newFunctionWithName:@"mhd3d_step"] error:&err];
    if (!_stepPipe) { NSLog(@"compute pipe: %@", err); exit(1); }

    _vizPipe = [_device newComputePipelineStateWithFunction:
        [lib newFunctionWithName:@"compute_viz"] error:&err];
    if (!_vizPipe) { NSLog(@"viz pipe: %@", err); exit(1); }

    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = [lib newFunctionWithName:@"fullscreen_vertex"];
    rpd.fragmentFunction = [lib newFunctionWithName:@"volume_fragment"];
    rpd.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    _renderPipe = [_device newRenderPipelineStateWithDescriptor:rpd error:&err];
    if (!_renderPipe) { NSLog(@"render pipe: %@", err); exit(1); }

    NSUInteger sz = NFIELDS * GN3 * sizeof(float);
    _stateA = [_device newBufferWithLength:sz options:MTLResourceStorageModeShared];
    _stateB = [_device newBufferWithLength:sz options:MTLResourceStorageModeShared];
    _vizBuf = [_device newBufferWithLength:GN3*sizeof(float) options:MTLResourceStorageModeShared];
    [self initState];
    return self;
}

- (void)initState {
    float *s = (float*)_stateA.contents;
    for (uint32_t z=0; z<GN; z++) for (uint32_t y=0; y<GN; y++) for (uint32_t x=0; x<GN; x++) {
        float xp = x*DX_F, yp = y*DX_F, zp = z*DX_F;
        uint32_t i = z*GN2 + y*GN + x;
        float rho=1.0f;
        float vx=-sinf(yp), vy=sinf(xp), vz=0.5f*sinf(zp);
        float bx=-sinf(yp), by=sinf(2.0f*xp), bz=0.5f*sinf(xp+yp);
        float p = GAMMA_F;
        float ke = 0.5f*rho*(vx*vx+vy*vy+vz*vz);
        float me = 0.5f*(bx*bx+by*by+bz*bz);
        s[0*GN3+i]=rho; s[1*GN3+i]=rho*vx; s[2*GN3+i]=rho*vy; s[3*GN3+i]=rho*vz;
        s[4*GN3+i]=bx;  s[5*GN3+i]=by;     s[6*GN3+i]=bz;     s[7*GN3+i]=p/GAMMA_M1_F+ke+me;
    }
}

- (void)drawInMTKView:(MTKView*)view {
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLBuffer> curBuf = _useA ? _stateA : _stateB;

    // Auto-rotate when not dragging
    if (!_pv.dragging) _pv.camTheta += 0.002f;

    if (!_pv.simPaused) {
        MHDParams mp = {DT_FIXED, DX_F, GAMMA_F, GAMMA_M1_F, GN, GN2, GN3, 0};
        for (int s=0; s<STEPS_PER_FRAME; s++) {
            id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
            [enc setComputePipelineState:_stepPipe];
            [enc setBuffer:(_useA?_stateA:_stateB) offset:0 atIndex:0];
            [enc setBuffer:(_useA?_stateB:_stateA) offset:0 atIndex:1];
            [enc setBytes:&mp length:sizeof(mp) atIndex:2];
            [enc dispatchThreads:MTLSizeMake(GN,GN,GN)
                threadsPerThreadgroup:MTLSizeMake(8,8,4)];
            [enc endEncoding];
            _useA = !_useA;
            _simTime += DT_FIXED;
        }
        curBuf = _useA ? _stateA : _stateB;

        // Compute |j|² visualization buffer
        id<MTLComputeCommandEncoder> venc = [cmd computeCommandEncoder];
        [venc setComputePipelineState:_vizPipe];
        [venc setBuffer:curBuf offset:0 atIndex:0];
        [venc setBuffer:_vizBuf offset:0 atIndex:1];
        [venc dispatchThreads:MTLSizeMake(GN,GN,GN)
            threadsPerThreadgroup:MTLSizeMake(8,8,4)];
        [venc endEncoding];
    }

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd) {
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.01,0.01,0.04,1);
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        id<MTLRenderCommandEncoder> renc = [cmd renderCommandEncoderWithDescriptor:rpd];
        [renc setRenderPipelineState:_renderPipe];
        [renc setFragmentBuffer:curBuf offset:0 atIndex:0];
        RenderParams rp = [self buildRP];
        [renc setFragmentBytes:&rp length:sizeof(rp) atIndex:1];
        [renc setFragmentBuffer:_vizBuf offset:0 atIndex:2];
        [renc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [renc endEncoding];
        [cmd presentDrawable:view.currentDrawable];
    }
    [cmd commit];

    if (++_frames % 60 == 0) {
        NSString *t = [NSString stringWithFormat:@"Rail Plasma 3D — t=%.2f %@",
            _simTime, _pv.simPaused?@"[PAUSED]":@""];
        dispatch_async(dispatch_get_main_queue(), ^{ self->_pv.window.title = t; });
    }
}

- (RenderParams)buildRP {
    float th=_pv.camTheta, ph=_pv.camPhi, d=_pv.camDist*(float)GN;
    float cx=GN*0.5f, cy=GN*0.5f, cz=GN*0.5f;
    simd_float3 eye = (simd_float3){cx+d*sinf(th)*cosf(ph), cy+d*sinf(ph), cz+d*cosf(th)*cosf(ph)};
    simd_float3 cen = (simd_float3){cx,cy,cz};
    simd_float3 f = simd_normalize(cen - eye);
    simd_float3 r = simd_normalize(simd_cross(f, (simd_float3){0,1,0}));
    simd_float3 u = simd_cross(r, f);
    float ht = tanf(0.4f);
    RenderParams rp;
    rp.eye    = (simd_float4){eye.x,eye.y,eye.z,0};
    rp.right  = (simd_float4){r.x,r.y,r.z,0};
    rp.up     = (simd_float4){u.x,u.y,u.z,0};
    rp.fwd    = (simd_float4){f.x,f.y,f.z,ht};
    rp.domain = (simd_float4){cx,cy,cz,(float)GN};
    rp.screen = (simd_float4){(float)_pv.drawableSize.width,(float)_pv.drawableSize.height,0.5f,3.0f};
    return rp;
}

- (void)mtkView:(MTKView*)v drawableSizeWillChange:(CGSize)s {}
@end

// ═══════════════════════════════════════════════════════════
// App
// ═══════════════════════════════════════════════════════════

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) Renderer *renderer;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification*)n {
    NSRect frame = NSMakeRect(100,100,768,768);
    _window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    PlasmaView *v = [[PlasmaView alloc] initWithFrame:frame device:dev];
    v.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    v.preferredFramesPerSecond = 60;
    _renderer = [[Renderer alloc] initWithView:v];
    v.delegate = _renderer;
    _window.contentView = v;
    _window.title = @"Rail Plasma 3D";
    [_window center];
    [_window makeKeyAndOrderFront:nil];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a { return YES; }
@end

int main(int argc, char**argv) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu *mb = [NSMenu new];
        NSMenuItem *mi = [NSMenuItem new]; [mb addItem:mi];
        NSMenu *am = [NSMenu new];
        [am addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [mi setSubmenu:am]; [app setMainMenu:mb];
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
