// gpu_host.m — minimal Metal compute host
// Loads a .metallib, runs a kernel, prints results
// Usage: ./gpu_host <metallib_path> <kernel_name> <n_elements>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "Usage: gpu_host <metallib> <kernel> <n>\n");
        return 1;
    }
    @autoreleasepool {
        NSString *libPath = [NSString stringWithUTF8String:argv[1]];
        NSString *kernelName = [NSString stringWithUTF8String:argv[2]];
        int n = atoi(argv[3]);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "No Metal device\n"); return 1; }

        NSError *err = nil;
        NSURL *url = [NSURL fileURLWithPath:libPath];
        id<MTLLibrary> lib = [device newLibraryWithURL:url error:&err];
        if (!lib) { fprintf(stderr, "Load failed: %s\n", [[err description] UTF8String]); return 1; }

        id<MTLFunction> fn = [lib newFunctionWithName:kernelName];
        if (!fn) { fprintf(stderr, "Kernel '%s' not found\n", argv[2]); return 1; }

        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:fn error:&err];
        if (!pipeline) { fprintf(stderr, "Pipeline failed\n"); return 1; }

        // Create buffer with integers 0..n-1
        int *input = malloc(n * sizeof(int));
        for (int i = 0; i < n; i++) input[i] = i;

        id<MTLBuffer> buf = [device newBufferWithBytes:input length:n*sizeof(int) options:MTLResourceStorageModeShared];
        free(input);

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];

        [enc setComputePipelineState:pipeline];
        [enc setBuffer:buf offset:0 atIndex:0];

        MTLSize grid = MTLSizeMake(n, 1, 1);
        NSUInteger tw = pipeline.maxTotalThreadsPerThreadgroup;
        if (tw > (NSUInteger)n) tw = n;
        MTLSize threadgroup = MTLSizeMake(tw, 1, 1);
        [enc dispatchThreads:grid threadsPerThreadgroup:threadgroup];
        [enc endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        // Print results
        int *result = (int *)[buf contents];
        for (int i = 0; i < n && i < 16; i++) {
            printf("%d", result[i]);
            if (i < n-1 && i < 15) printf(",");
        }
        if (n > 16) printf(",...");
        printf("\n");
    }
    return 0;
}
