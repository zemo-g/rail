// neural_renderer.m — Real-time neural MHD plasma renderer
// Loads trained weights, runs neural forward pass as physics engine
// Renders density as a heatmap in a Metal window
//
// Usage: train first with neural_mhd_gpu, then run this

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#define NN 64
#define NN2 (NN*NN)
#define NFIELDS 6
#define DX (2.0*M_PI/NN)
#define MIN(a,b) ((a)<(b)?(a):(b))
#define MAX(a,b) ((a)>(b)?(a):(b))

// Loaded from weights file
static int IN_DIM, HIDDEN, OUT_DIM;
static float *W1, *b1, *W2, *b2;
static float *x_mean, *x_std, *y_mean, *y_std;

// MHD state (double precision)
static double state[NFIELDS * NN2];
static double next_state[NFIELDS * NN2];

static inline int wrap(int i) { return (i<0)?i+NN:(i>=NN)?i-NN:i; }
#define G(f,x,y) (state[(f)*NN2 + wrap(y)*NN + wrap(x)])

static void init_state(void) {
    for (int y=0; y<NN; y++) for (int x=0; x<NN; x++) {
        double xp=x*DX, yp=y*DX;
        double rho=25.0/(36.0*M_PI), vx=-sin(yp), vy=sin(xp);
        double bx=-sin(yp), by=sin(2.0*xp);
        double p=5.0/(12.0*M_PI);
        double ke=0.5*rho*(vx*vx+vy*vy), me=0.5*(bx*bx+by*by);
        int i=y*NN+x;
        state[0*NN2+i]=rho; state[1*NN2+i]=rho*vx; state[2*NN2+i]=rho*vy;
        state[3*NN2+i]=bx; state[4*NN2+i]=by; state[5*NN2+i]=p/(2.0/3.0)+ke+me;
    }
}

static int load_weights(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open %s\n", path); return 0; }
    int dims[3];
    fread(dims, sizeof(int), 3, f);
    IN_DIM = dims[0]; HIDDEN = dims[1]; OUT_DIM = dims[2];
    W1 = malloc(IN_DIM*HIDDEN*sizeof(float));
    b1 = malloc(HIDDEN*sizeof(float));
    W2 = malloc(HIDDEN*OUT_DIM*sizeof(float));
    b2 = malloc(OUT_DIM*sizeof(float));
    x_mean = malloc(IN_DIM*sizeof(float));
    x_std = malloc(IN_DIM*sizeof(float));
    y_mean = malloc(OUT_DIM*sizeof(float));
    y_std = malloc(OUT_DIM*sizeof(float));
    fread(W1, sizeof(float), IN_DIM*HIDDEN, f);
    fread(b1, sizeof(float), HIDDEN, f);
    fread(W2, sizeof(float), HIDDEN*OUT_DIM, f);
    fread(b2, sizeof(float), OUT_DIM, f);
    fread(x_mean, sizeof(float), IN_DIM, f);
    fread(x_std, sizeof(float), IN_DIM, f);
    fread(y_mean, sizeof(float), OUT_DIM, f);
    fread(y_std, sizeof(float), OUT_DIM, f);
    fclose(f);
    printf("Loaded model: %d -> %d -> %d\n", IN_DIM, HIDDEN, OUT_DIM);
    return 1;
}

// Neural forward pass for one cell
static void neural_predict(int x, int y) {
    float stencil[30];
    for (int f=0; f<6; f++) {
        stencil[f]    = (float)G(f,x,y);
        stencil[f+6]  = (float)G(f,x-1,y);
        stencil[f+12] = (float)G(f,x+1,y);
        stencil[f+18] = (float)G(f,x,y-1);
        stencil[f+24] = (float)G(f,x,y+1);
    }
    // Normalize
    for (int j=0; j<IN_DIM; j++) stencil[j] = (stencil[j]-x_mean[j])/x_std[j];
    // Layer 1
    float h[256]; // max hidden
    for (int j=0; j<HIDDEN; j++) {
        float v = b1[j];
        for (int k=0; k<IN_DIM; k++) v += stencil[k] * W1[k*HIDDEN+j];
        h[j] = fmaxf(0, v);
    }
    // Layer 2
    int i = y*NN+x;
    for (int j=0; j<OUT_DIM; j++) {
        float v = b2[j];
        for (int k=0; k<HIDDEN; k++) v += h[k] * W2[k*OUT_DIM+j];
        // Denormalize + residual
        double delta = (double)(v * y_std[j] + y_mean[j]);
        next_state[j*NN2+i] = state[j*NN2+i] + 0.7 * delta;
    }
    // Clamp
    next_state[0*NN2+i] = MAX(0.01, MIN(5.0, next_state[0*NN2+i]));
    next_state[5*NN2+i] = MAX(0.1, MIN(50.0, next_state[5*NN2+i]));
    for (int f=1; f<5; f++)
        next_state[f*NN2+i] = MAX(-10.0, MIN(10.0, next_state[f*NN2+i]));
}

static void neural_step(void) {
    for (int i=0; i<NN2; i++) neural_predict(i%NN, i/NN);
    memcpy(state, next_state, sizeof(state));
}

// ═══════════════════════════════════════════════════════════
// METAL RENDERER
// ═══════════════════════════════════════════════════════════

@interface PlasmaView : MTKView
@property BOOL simPaused;
@property int stepCount;
@end
@implementation PlasmaView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent*)e {
    if ([e.characters isEqualToString:@" "]) _simPaused = !_simPaused;
    if ([e.characters isEqualToString:@"r"]) { init_state(); _stepCount=0; }
}
@end

@interface Renderer : NSObject <MTKViewDelegate>
@property id<MTLDevice> device;
@property id<MTLCommandQueue> queue;
@property id<MTLRenderPipelineState> renderPipe;
@property id<MTLBuffer> vertexBuf;
@property id<MTLTexture> texture;
@property (weak) PlasmaView *pv;
@end

@implementation Renderer

- (instancetype)initWithView:(PlasmaView*)view lib:(id<MTLLibrary>)lib {
    self = [super init];
    _pv = view; _device = view.device;
    _queue = [_device newCommandQueue];

    NSError *err;
    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = [lib newFunctionWithName:@"vertex_passthrough"];
    rpd.fragmentFunction = [lib newFunctionWithName:@"fragment_heatmap"];
    rpd.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    _renderPipe = [_device newRenderPipelineStateWithDescriptor:rpd error:&err];

    // Fullscreen quad vertices (pos + uv)
    float verts[] = {
        -1,-1, 0,1,  1,-1, 1,1,  -1,1, 0,0,
         1,-1, 1,1,  1, 1, 1,0,  -1,1, 0,0
    };
    _vertexBuf = [_device newBufferWithBytes:verts length:sizeof(verts) options:MTLResourceStorageModeShared];

    // Density texture (NN x NN, RGBA8)
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:NN height:NN mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    _texture = [_device newTextureWithDescriptor:td];

    return self;
}

- (void)updateTexture {
    uint8_t pixels[NN2 * 4];
    // Find density range
    double dmin = 1e10, dmax = -1e10;
    for (int i=0; i<NN2; i++) {
        if (state[i] < dmin) dmin = state[i];
        if (state[i] > dmax) dmax = state[i];
    }
    double range = fmax(dmax - dmin, 1e-6);
    // Inferno-ish colormap
    for (int i=0; i<NN2; i++) {
        float t = (float)((state[i] - dmin) / range);
        t = fmaxf(0, fminf(1, t));
        // Dark → orange → yellow → white
        uint8_t r, g, b;
        if (t < 0.33f) {
            r = (uint8_t)(t*3*200); g = (uint8_t)(t*3*50); b = (uint8_t)(80-t*3*80);
        } else if (t < 0.66f) {
            float s = (t-0.33f)*3;
            r = 200+(uint8_t)(s*55); g = 50+(uint8_t)(s*150); b = 0;
        } else {
            float s = (t-0.66f)*3;
            r = 255; g = 200+(uint8_t)(s*55); b = (uint8_t)(s*200);
        }
        pixels[i*4] = r; pixels[i*4+1] = g; pixels[i*4+2] = b; pixels[i*4+3] = 255;
    }
    [_texture replaceRegion:MTLRegionMake2D(0,0,NN,NN) mipmapLevel:0
                  withBytes:pixels bytesPerRow:NN*4];
}

- (void)drawInMTKView:(MTKView*)view {
    if (!_pv.simPaused) {
        neural_step();
        _pv.stepCount++;
    }
    [self updateTexture];

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (rpd) {
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        [enc setRenderPipelineState:_renderPipe];
        [enc setVertexBuffer:_vertexBuf offset:0 atIndex:0];
        [enc setFragmentTexture:_texture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [enc endEncoding];
        [cmd presentDrawable:view.currentDrawable];
    }
    [cmd commit];

    if (_pv.stepCount % 30 == 0) {
        double mass = 0;
        for (int i=0; i<NN2; i++) mass += state[i];
        NSString *title = [NSString stringWithFormat:@"Neural Plasma — step %d  mass=%.1f %@",
            _pv.stepCount, mass, _pv.simPaused?@"[PAUSED]":@""];
        dispatch_async(dispatch_get_main_queue(), ^{ self->_pv.window.title = title; });
    }
}

- (void)mtkView:(MTKView*)v drawableSizeWillChange:(CGSize)s {}
@end

// ═══════════════════════════════════════════════════════════
// METAL SHADERS (inline as string, compiled at runtime)
// ═══════════════════════════════════════════════════════════

static NSString *shaderSrc = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VOut { float4 pos [[position]]; float2 uv; };\n"
"vertex VOut vertex_passthrough(uint vid [[vertex_id]],\n"
"    device const float4 *verts [[buffer(0)]]) {\n"
"    VOut o; o.pos = float4(verts[vid].xy, 0, 1); o.uv = verts[vid].zw; return o;\n"
"}\n"
"fragment float4 fragment_heatmap(VOut in [[stage_in]],\n"
"    texture2d<float> tex [[texture(0)]]) {\n"
"    constexpr sampler s(filter::nearest);\n"
"    return tex.sample(s, in.uv);\n"
"}\n";

// ═══════════════════════════════════════════════════════════
// APP
// ═══════════════════════════════════════════════════════════

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) Renderer *renderer;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification*)n {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err;
    id<MTLLibrary> lib = [dev newLibraryWithSource:shaderSrc options:nil error:&err];
    if (!lib) { NSLog(@"Shader: %@", err); exit(1); }

    NSRect frame = NSMakeRect(200, 200, 640, 640);
    _window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    PlasmaView *v = [[PlasmaView alloc] initWithFrame:frame device:dev];
    v.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    v.preferredFramesPerSecond = 30;
    _renderer = [[Renderer alloc] initWithView:v lib:lib];
    v.delegate = _renderer;
    _window.contentView = v;
    _window.title = @"Neural Plasma — Loading...";
    [_window center];
    [_window makeKeyAndOrderFront:nil];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)a { return YES; }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        printf("Neural Plasma Renderer\n");
        if (!load_weights("/tmp/neural_mhd_weights.bin")) {
            fprintf(stderr, "Run neural_mhd_gpu first to train and save weights\n");
            return 1;
        }
        init_state();
        printf("Initial density[0] = %.4f\n", state[0]);

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu *mb = [NSMenu new]; NSMenuItem *mi = [NSMenuItem new]; [mb addItem:mi];
        NSMenu *am = [NSMenu new];
        [am addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [mi setSubmenu:am]; [app setMainMenu:mb];
        AppDelegate *d = [AppDelegate new]; app.delegate = d;
        [app activateIgnoringOtherApps:YES]; [app run];
    }
    return 0;
}
