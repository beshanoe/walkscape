#import "IndoorEnvironment.h"

#define RGB(r, g, b) ((simd_float3){r, g, b})

// The key light (sun) is daylight through windows, coming from the right of the picture; a
// scene with windows on the left mirrors it (-adjustLighting:values:).
static const LightPreset kPresets[] = {
  {.name = "Bright", .elevation = 30, .azimuth = 70, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(0.30, 0.30, 0.29), .groundAmbient = RGB(0.20, 0.19, 0.18),
   .zenith = RGB(0.75, 0.75, 0.73), .horizon = RGB(0.45, 0.44, 0.42), .fog = RGB(0.30, 0.30, 0.29),
   .fogDensity = 0.006, .fogFalloff = 0.0, .lamp = RGB(1.0, 0.92, 0.82), .night = 1,
   .exposure = 1.0, .saturation = 1.0, .contrast = 1.03, .bloom = 0.08, .vignette = 0.14, .whiteBalance = RGB(1, 1, 1)},
  {.name = "Warm evening", .elevation = 30, .azimuth = 70, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(0.13, 0.10, 0.08), .groundAmbient = RGB(0.09, 0.07, 0.05),
   .zenith = RGB(0.40, 0.32, 0.25), .horizon = RGB(0.25, 0.20, 0.16), .fog = RGB(0.12, 0.10, 0.08),
   .fogDensity = 0.008, .fogFalloff = 0.0, .lamp = RGB(1.0, 0.68, 0.38), .night = 0.8,
   .exposure = 1.5, .saturation = 1.04, .contrast = 1.05, .bloom = 0.12, .vignette = 0.18, .whiteBalance = RGB(1, 1, 1)},
  {.name = "Fluorescent", .elevation = 30, .azimuth = 70, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(0.30, 0.33, 0.32), .groundAmbient = RGB(0.20, 0.22, 0.21),
   .zenith = RGB(0.72, 0.78, 0.76), .horizon = RGB(0.42, 0.45, 0.44), .fog = RGB(0.28, 0.30, 0.29),
   .fogDensity = 0.006, .fogFalloff = 0.0, .lamp = RGB(0.86, 1.0, 0.94), .night = 1,
   .exposure = 1.05, .saturation = 0.86, .contrast = 0.98, .bloom = 0.06, .vignette = 0.12, .whiteBalance = RGB(0.98, 1.0, 1.0)},
  {.name = "Sunlight through windows", .elevation = 24, .azimuth = 72, .sun = RGB(3.2, 2.75, 2.1),
   .skyAmbient = RGB(0.34, 0.38, 0.46), .groundAmbient = RGB(0.22, 0.19, 0.15),
   .zenith = RGB(0.70, 0.72, 0.74), .horizon = RGB(0.50, 0.50, 0.50), .fog = RGB(0.36, 0.36, 0.36),
   .fogDensity = 0.005, .fogFalloff = 0.0, .lamp = RGB(1.0, 0.92, 0.82), .night = 0.15, .shadow = 1,
   .exposure = 1.0, .saturation = 1.04, .contrast = 1.06, .bloom = 0.1, .vignette = 0.14, .whiteBalance = RGB(1.02, 1.0, 0.97)},
  {.name = "Night", .elevation = 30, .azimuth = 70, .sun = RGB(0, 0, 0),
   .skyAmbient = RGB(0.03, 0.03, 0.035), .groundAmbient = RGB(0.02, 0.02, 0.02),
   .zenith = RGB(0.12, 0.10, 0.08), .horizon = RGB(0.06, 0.05, 0.05), .fog = RGB(0.03, 0.03, 0.03),
   .fogDensity = 0.012, .fogFalloff = 0.0, .lamp = RGB(1.0, 0.74, 0.48), .night = 0.3,
   .exposure = 1.7, .saturation = 0.92, .contrast = 1.06, .bloom = 0.18, .vignette = 0.2, .whiteBalance = RGB(1, 1, 1)},
};

static const size_t kPresetCount = sizeof kPresets / sizeof kPresets[0];

@implementation IndoorEnvironment

+ (NSArray<NSString *> *)presetNames {
  NSMutableArray *names = [NSMutableArray array];
  for (size_t i = 0; i < kPresetCount; i++) [names addObject:@(kPresets[i].name)];
  return names;
}

- (void)applyPreset:(NSString *)preset to:(FrameUniforms *)u {
  const LightPreset *p = &kPresets[0];
  for (size_t i = 0; i < kPresetCount; i++) {
    if (strcmp(kPresets[i].name, preset.UTF8String) == 0) p = &kPresets[i];
  }
  LightPresetApply(p, u);
}

@end
