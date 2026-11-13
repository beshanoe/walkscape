#import "CoastEnvironment.h"

#import "CoastSky.h"
#import "SceneUtil.h"

#define RGB(r, g, b) ((simd_float3){r, g, b})

static const CoastPreset kPresets[] = {
  // The sun a few degrees over the sea, scattered clouds lit from below, clear sky at the horizon.
  {.light = {.name = "Golden hour", .elevation = 6, .azimuth = -30, .sun = RGB(2.8, 1.3, 0.38),
             .skyAmbient = RGB(0.17, 0.21, 0.32), .groundAmbient = RGB(0.10, 0.07, 0.05),
             .zenith = RGB(0.045, 0.11, 0.30), .horizon = RGB(1.25, 0.52, 0.17), .fog = RGB(0.9, 0.48, 0.22),
             .fogDensity = 0.00012f, .fogFalloff = 0.002f, .inscatter = 1.0f, .cloudCover = 0.5f, .cloud = RGB(0.13, 0.12, 0.19),
             .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 1, .shadow = 1, .exposure = 0.95f, .saturation = 1.08f, .contrast = 1.08f,
             .bloom = 0.1f, .shafts = 0.35f, .vignette = 0.15f, .whiteBalance = RGB(1.02, 1.0, 0.95)},
   .skySun = RGB(2.8, 1.3, 0.38), .cloudBase = 2200, .cloudDepth = 500, .clearHorizon = 0.95f, .clearDistance = 9000,
   .cirrus = 0.35f, .storm = 0, .wind = 4},
  // A grey deck of stratus, soft light from everywhere, no shadows.
  {.light = {.name = "Overcast", .elevation = 35, .azimuth = -25, .sun = RGB(0, 0, 0),
             .skyAmbient = RGB(0.5, 0.52, 0.56), .groundAmbient = RGB(0.14, 0.14, 0.13),
             .zenith = RGB(0.62, 0.66, 0.72), .horizon = RGB(0.80, 0.83, 0.86), .fog = RGB(0.62, 0.65, 0.68),
             .fogDensity = 0.0003f, .fogFalloff = 0.002f, .inscatter = 0, .cloudCover = 0.97f, .cloud = RGB(1.45, 1.5, 1.58),
             .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0.3f, .shadow = 0, .exposure = 1.1f, .saturation = 0.9f, .contrast = 1.04f,
             .bloom = 0.04f, .shafts = 0, .vignette = 0.12f, .whiteBalance = RGB(1, 1, 1)},
   .skySun = RGB(0.35, 0.35, 0.36), .cloudBase = 650, .cloudDepth = 700, .clearHorizon = 0.15f, .clearDistance = 20000,
   .cirrus = 0, .storm = 0.1f, .wind = 7},
  // A low, heavy deck with rain under it, the scene in its shade; toward the sun it ends, and the
  // sky and the sea out there are bright.
  {.light = {.name = "Stormy", .elevation = 9, .azimuth = -30, .sun = RGB(0, 0, 0),
             .skyAmbient = RGB(0.30, 0.33, 0.38), .groundAmbient = RGB(0.06, 0.07, 0.07),
             .zenith = RGB(0.30, 0.34, 0.40), .horizon = RGB(0.95, 0.92, 0.86), .fog = RGB(0.30, 0.33, 0.36),
             .fogDensity = 0.00045f, .fogFalloff = 0.002f, .inscatter = 1.0f, .cloudCover = 1, .cloud = RGB(0.62, 0.68, 0.76),
             .wetness = 1, .night = 0.3f, .lamp = RGB(1.0, 0.75, 0.45), .sunDisk = 0.35f, .shadow = 0, .exposure = 1.25f,
             .saturation = 0.85f, .contrast = 1.1f, .bloom = 0.06f, .shafts = 0, .vignette = 0.18f, .whiteBalance = RGB(1, 1, 1)},
   .skySun = RGB(2.0, 1.75, 1.45), .cloudBase = 420, .cloudDepth = 2200, .clearHorizon = 0.95f, .clearDistance = 7000,
   .cirrus = 0, .storm = 1, .wind = 15},
};

static const size_t kPresetCount = sizeof kPresets / sizeof kPresets[0];

void CoastPresetApply(const CoastPreset *p, FrameUniforms *u) {
  LightPresetApply(&p->light, u);
  u->skySun = p->skySun;
  u->cloudBase = p->cloudBase;
  u->cloudDepth = p->cloudDepth;
  u->clearHorizon = p->clearHorizon;
  u->clearDistance = p->clearDistance;
  u->cirrus = p->cirrus;
  u->storm = p->storm;
  u->wind = p->wind;
  u->contrails = p->contrails;
  u->cumulus = p->cumulus;
  u->windDir = simd_make_float2(1, 0);  // onshore for the sea on the left; scenes set their own
}

@implementation CoastEnvironment {
  id<MTLRenderPipelineState> _skyPipe;
  id<MTLDepthStencilState> _skyDepth;
  id<MTLTexture> _noise;
}

+ (NSArray<NSString *> *)presetNames {
  NSMutableArray *names = [NSMutableArray array];
  for (size_t i = 0; i < kPresetCount; i++) [names addObject:@(kPresets[i].light.name)];
  return names;
}

+ (NSArray<NSString *> *)shaderSources {
  return @[ @"CoastSky.h", @"CoastSky.metal" ];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)lib error:(NSError **)error {
  if (!(self = [super initWithDevice:device library:lib error:error])) return nil;
  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(pd, NO);
  pd.vertexFunction = [lib newFunctionWithName:@"coast_sky_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"coast_sky_fs"];
  _skyPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  _noise = CoastCloudNoise(device, lib, error);
  if (!_skyPipe || !_noise) return nil;
  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLessEqual;  // at the far plane: only where nothing was drawn
  dd.depthWriteEnabled = NO;
  _skyDepth = [device newDepthStencilStateWithDescriptor:dd];
  return self;
}

- (void)applyPreset:(NSString *)preset to:(FrameUniforms *)u {
  const CoastPreset *p = &kPresets[0];
  for (size_t i = 0; i < kPresetCount; i++) {
    if (strcmp(kPresets[i].light.name, preset.UTF8String) == 0) p = &kPresets[i];
  }
  CoastPresetApply(p, u);
}

- (void)encodeBackdrop:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [re setVertexBytes:&frame->uniforms length:sizeof frame->uniforms atIndex:kBufferFrame];
  [re setFragmentBytes:&frame->uniforms length:sizeof frame->uniforms atIndex:kBufferFrame];
  [re setFragmentTexture:_noise atIndex:kTextureClouds];
  [re setRenderPipelineState:_skyPipe];
  [re setDepthStencilState:_skyDepth];
  [re setCullMode:MTLCullModeNone];
  [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

@end

id<MTLTexture> CoastCloudNoise(id<MTLDevice> device, id<MTLLibrary> lib, NSError **error) {
  id<MTLFunction> fn = [lib newFunctionWithName:@"coast_bake_noise"];
  if (!fn) {
    if (error) *error = SceneError(@"No coast_bake_noise in the library");
    return nil;
  }
  id<MTLComputePipelineState> bake = [device newComputePipelineStateWithFunction:fn error:error];
  if (!bake) return nil;
  MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:kCloudNoiseSize
                                                                                height:kCloudNoiseSize mipmapped:YES];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  td.storageMode = MTLStorageModePrivate;
  id<MTLTexture> noise = [device newTextureWithDescriptor:td];
  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
  [ce setComputePipelineState:bake];
  [ce setTexture:noise atIndex:0];
  [ce dispatchThreads:MTLSizeMake(noise.width, noise.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
  [ce endEncoding];
  id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
  [be generateMipmapsForTexture:noise];
  [be endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  return noise;
}
