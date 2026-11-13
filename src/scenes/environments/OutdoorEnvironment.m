#import "OutdoorEnvironment.h"

#import <simd/simd.h>

#define RGB(r, g, b) ((simd_float3){r, g, b})

static const LightPreset kPresets[] = {
  {.name = "Sunny", .elevation = 48, .azimuth = -60, .sun = RGB(3.0, 2.85, 2.58),
   .skyAmbient = RGB(0.39, 0.50, 0.68), .groundAmbient = RGB(0.15, 0.14, 0.10),
   .zenith = RGB(0.20, 0.40, 0.80), .horizon = RGB(0.70, 0.80, 0.92), .fog = RGB(0.66, 0.75, 0.86),
   .fogDensity = 0.0022, .fogFalloff = 0.012, .inscatter = 0.35, .cloudCover = 0.35, .cloud = RGB(1.25, 1.25, 1.25),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 1, .shadow = 1, .exposure = 1.0, .saturation = 1.05, .contrast = 1.05, .bloom = 0.06, .shafts = 0.25, .vignette = 0.12,
   .whiteBalance = RGB(1, 1, 1)},
  {.name = "Morning sun", .elevation = 13, .azimuth = 25, .sun = RGB(2.6, 2.08, 1.5),
   .skyAmbient = RGB(0.33, 0.37, 0.47), .groundAmbient = RGB(0.12, 0.10, 0.08),
   .zenith = RGB(0.32, 0.48, 0.76), .horizon = RGB(0.98, 0.86, 0.72), .fog = RGB(0.86, 0.82, 0.76),
   .fogDensity = 0.0065, .fogFalloff = 0.05, .inscatter = 1.4, .cloudCover = 0.2, .cloud = RGB(1.2, 1.1, 1.02),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 1, .shadow = 1, .exposure = 1.1, .saturation = 1.0, .contrast = 1.05, .bloom = 0.08, .shafts = 0.8, .vignette = 0.14,
   .whiteBalance = RGB(1.03, 1.0, 0.95)},
  {.name = "Golden hour", .elevation = 5, .azimuth = -55, .sun = RGB(2.4, 1.44, 0.72),
   .skyAmbient = RGB(0.25, 0.26, 0.34), .groundAmbient = RGB(0.10, 0.08, 0.05),
   .zenith = RGB(0.28, 0.38, 0.62), .horizon = RGB(1.0, 0.70, 0.45), .fog = RGB(0.92, 0.72, 0.55),
   .fogDensity = 0.0028, .fogFalloff = 0.02, .inscatter = 1.2, .cloudCover = 0.4, .cloud = RGB(1.1, 0.75, 0.53),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 1, .shadow = 1, .exposure = 1.15, .saturation = 1.08, .contrast = 1.05, .bloom = 0.08, .shafts = 0.5, .vignette = 0.15,
   .whiteBalance = RGB(1.04, 1.0, 0.93)},
  {.name = "Bright overcast", .elevation = 65, .azimuth = -30, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(1.30, 1.35, 1.45), .groundAmbient = RGB(0.23, 0.23, 0.20),
   .zenith = RGB(0.93, 0.96, 1.03), .horizon = RGB(1.12, 1.14, 1.17), .fog = RGB(0.80, 0.84, 0.88),
   .fogDensity = 0.0022, .fogFalloff = 0.01, .inscatter = 0, .cloudCover = 1.0, .cloud = RGB(1.10, 1.13, 1.17),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0, .shadow = 0, .exposure = 1.2, .saturation = 0.95, .contrast = 1.0, .bloom = 0.04, .shafts = 0, .vignette = 0.12,
   .whiteBalance = RGB(1, 1, 1)},
  {.name = "Cloudy", .elevation = 60, .azimuth = -30, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(0.82, 0.86, 0.92), .groundAmbient = RGB(0.15, 0.15, 0.14),
   .zenith = RGB(0.52, 0.55, 0.60), .horizon = RGB(0.68, 0.70, 0.73), .fog = RGB(0.56, 0.59, 0.63),
   .fogDensity = 0.0028, .fogFalloff = 0.01, .inscatter = 0, .cloudCover = 1.0, .cloud = RGB(0.60, 0.62, 0.66),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0, .shadow = 0, .exposure = 1.3, .saturation = 0.85, .contrast = 0.97, .bloom = 0.03, .shafts = 0, .vignette = 0.14,
   .whiteBalance = RGB(1, 1, 1.01)},
  {.name = "Foggy", .elevation = 30, .azimuth = -20, .sun = RGB(0.35, 0.33, 0.31),
   .skyAmbient = RGB(1.06, 1.08, 1.13), .groundAmbient = RGB(0.24, 0.24, 0.23),
   .zenith = RGB(0.78, 0.80, 0.83), .horizon = RGB(0.78, 0.80, 0.83), .fog = RGB(0.74, 0.76, 0.79),
   .fogDensity = 0.02, .fogFalloff = 0.015, .inscatter = 0.4, .cloudCover = 1.0, .cloud = RGB(0.78, 0.80, 0.83),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0.3, .shadow = 0.25, .exposure = 1.25, .saturation = 0.8, .contrast = 0.97, .bloom = 0.05, .shafts = 0, .vignette = 0.1,
   .whiteBalance = RGB(1, 1, 1)},
  {.name = "After rain", .elevation = 55, .azimuth = -40, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(0.86, 0.91, 1.0), .groundAmbient = RGB(0.12, 0.13, 0.12),
   .zenith = RGB(0.55, 0.60, 0.67), .horizon = RGB(0.72, 0.75, 0.78), .fog = RGB(0.60, 0.64, 0.68),
   .fogDensity = 0.003, .fogFalloff = 0.02, .inscatter = 0, .cloudCover = 0.95, .cloud = RGB(0.65, 0.68, 0.72),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0, .shadow = 0, .wetness = 1, .exposure = 1.35, .saturation = 1.12, .contrast = 1.04, .bloom = 0.04, .shafts = 0,
   .vignette = 0.14, .whiteBalance = RGB(0.99, 1, 1.02)},
  {.name = "Dusk", .elevation = -3, .azimuth = -40, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(0.14, 0.16, 0.26), .groundAmbient = RGB(0.05, 0.045, 0.05),
   .zenith = RGB(0.06, 0.10, 0.26), .horizon = RGB(0.62, 0.42, 0.38), .fog = RGB(0.32, 0.30, 0.38),
   .fogDensity = 0.004, .fogFalloff = 0.015, .inscatter = 0, .cloudCover = 0.3, .cloud = RGB(0.33, 0.21, 0.21),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0, .shadow = 0, .night = 0.7, .exposure = 2.4, .saturation = 1.0, .contrast = 1.03, .bloom = 0.12, .shafts = 0,
   .vignette = 0.16, .whiteBalance = RGB(0.98, 0.98, 1.04)},
  {.name = "Night", .elevation = 35, .azimuth = 30, .sun = RGB(0.055, 0.065, 0.09),
   .skyAmbient = RGB(0.035, 0.045, 0.077), .groundAmbient = RGB(0.01, 0.01, 0.012),
   .zenith = RGB(0.004, 0.007, 0.02), .horizon = RGB(0.03, 0.035, 0.06), .fog = RGB(0.025, 0.03, 0.045),
   .fogDensity = 0.004, .fogFalloff = 0.015, .inscatter = 0, .cloudCover = 0.25, .cloud = RGB(0.05, 0.055, 0.07),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0.4, .shadow = 0.6, .night = 1, .stars = 1, .exposure = 3.8, .saturation = 0.85, .contrast = 1.03, .bloom = 0.15,
   .shafts = 0, .vignette = 0.18, .whiteBalance = RGB(1, 1, 1)},
  // Overcast, wet, the clouds lit orange by the city.
  {.name = "Rainy night", .elevation = 35, .azimuth = 30, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(0.05, 0.048, 0.05), .groundAmbient = RGB(0.012, 0.011, 0.01),
   .zenith = RGB(0.02, 0.018, 0.02), .horizon = RGB(0.06, 0.045, 0.04), .fog = RGB(0.05, 0.042, 0.04),
   .fogDensity = 0.007, .fogFalloff = 0.015, .inscatter = 0, .cloudCover = 1.0, .cloud = RGB(0.07, 0.05, 0.045),
   .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0, .shadow = 0, .wetness = 1, .night = 1, .exposure = 3.4, .saturation = 0.9, .contrast = 1.04, .bloom = 0.18,
   .shafts = 0, .vignette = 0.18, .whiteBalance = RGB(1, 1, 1)},
};

static const size_t kPresetCount = sizeof kPresets / sizeof kPresets[0];

@implementation OutdoorEnvironment {
  id<MTLRenderPipelineState> _skyPipe;
  id<MTLDepthStencilState> _skyDepth;
}

+ (NSArray<NSString *> *)presetNames {
  NSMutableArray *names = [NSMutableArray array];
  for (size_t i = 0; i < kPresetCount; i++) [names addObject:@(kPresets[i].name)];
  return names;
}

+ (NSArray<NSString *> *)shaderSources {
  return @[ @"Outdoor.metal" ];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)lib error:(NSError **)error {
  if (!(self = [super initWithDevice:device library:lib error:error])) return nil;
  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  SceneDescribeMainPass(pd, NO);
  pd.vertexFunction = [lib newFunctionWithName:@"sky_vs"];
  pd.fragmentFunction = [lib newFunctionWithName:@"sky_fs"];
  _skyPipe = [device newRenderPipelineStateWithDescriptor:pd error:error];
  if (!_skyPipe) return nil;
  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLessEqual;  // at the far plane: only where nothing was drawn
  dd.depthWriteEnabled = NO;
  _skyDepth = [device newDepthStencilStateWithDescriptor:dd];
  return self;
}

- (void)applyPreset:(NSString *)preset to:(FrameUniforms *)u {
  const LightPreset *p = &kPresets[0];
  for (size_t i = 0; i < kPresetCount; i++) {
    if (strcmp(kPresets[i].name, preset.UTF8String) == 0) p = &kPresets[i];
  }
  LightPresetApply(p, u);
}

// The sky (gradient, sun, clouds, stars, haze): its clouds are only computed where the scene left
// the depth at the far plane.
- (void)encodeBackdrop:(id<MTLRenderCommandEncoder>)re frame:(const SceneFrame *)frame {
  [re setVertexBytes:&frame->uniforms length:sizeof frame->uniforms atIndex:kBufferFrame];
  [re setFragmentBytes:&frame->uniforms length:sizeof frame->uniforms atIndex:kBufferFrame];
  [re setRenderPipelineState:_skyPipe];
  [re setDepthStencilState:_skyDepth];
  [re setCullMode:MTLCullModeNone];
  [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

@end
