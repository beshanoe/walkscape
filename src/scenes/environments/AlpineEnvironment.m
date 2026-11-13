#import "AlpineEnvironment.h"

#define RGB(r, g, b) ((simd_float3){r, g, b})

// Heights are relative to the trail (y ≈ 0, about 2,300 m above the sea): the fog's density is
// that of the air at the trail, thicker down in the valley (falloff). Colours are linear.
static const CoastPreset kPresets[] = {
  {.light = {.name = "Clear day", .elevation = 45, .azimuth = 140, .sun = RGB(3.9, 3.7, 3.35),
             .skyAmbient = RGB(0.16, 0.32, 0.62), .groundAmbient = RGB(0.10, 0.11, 0.08),
             .zenith = RGB(0.004, 0.25, 0.72), .horizon = RGB(0.50, 0.78, 0.96), .fog = RGB(0.36, 0.62, 0.92),
             .fogDensity = 0.00002f, .fogFalloff = 0.0009f, .inscatter = 0.5f, .cloudCover = 0.2f, .cloud = RGB(0.62, 0.72, 0.9),
             .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 1, .shadow = 1, .exposure = 1.0f, .saturation = 1.04f, .contrast = 1.12f,
             .bloom = 0.05f, .shafts = 0.15f, .vignette = 0.1f, .whiteBalance = RGB(1, 1, 1)},
   .skySun = RGB(3.3, 3.1, 2.8), .cloudBase = 3000, .cloudDepth = 900, .clearHorizon = 0.3f, .clearDistance = 26000,
   .cirrus = 0.3f, .storm = 0, .wind = 4, .contrails = 1, .cumulus = 1},
  {.light = {.name = "Morning", .elevation = 17, .azimuth = 162, .sun = RGB(3.1, 2.35, 1.6),
             .skyAmbient = RGB(0.24, 0.32, 0.52), .groundAmbient = RGB(0.12, 0.11, 0.09),
             .zenith = RGB(0.05, 0.15, 0.48), .horizon = RGB(0.80, 0.78, 0.82), .fog = RGB(0.62, 0.68, 0.84),
             .fogDensity = 0.00005f, .fogFalloff = 0.0016f, .inscatter = 1.2f, .cloudCover = 0.22f, .cloud = RGB(0.50, 0.52, 0.64),
             .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 1, .shadow = 1, .exposure = 1.05f, .saturation = 1.06f, .contrast = 1.06f,
             .bloom = 0.07f, .shafts = 0.3f, .vignette = 0.12f, .whiteBalance = RGB(1.02, 1.0, 0.96)},
   .skySun = RGB(3.1, 2.35, 1.6), .cloudBase = 1250, .cloudDepth = 500, .clearHorizon = 0.6f, .clearDistance = 20000,
   .cirrus = 0.55f, .storm = 0, .wind = 3, .contrails = 0.7f, .cumulus = 1},
  // The sun at the horizon behind the camera: only the walls and the summits still catch it.
  {.light = {.name = "Alpenglow", .elevation = 3.5f, .azimuth = 122, .sun = RGB(3.0, 1.1, 0.42),
             .skyAmbient = RGB(0.21, 0.25, 0.44), .groundAmbient = RGB(0.10, 0.08, 0.09),
             .zenith = RGB(0.035, 0.09, 0.32), .horizon = RGB(1.0, 0.50, 0.42), .fog = RGB(0.42, 0.36, 0.56),
             .fogDensity = 0.00005f, .fogFalloff = 0.0014f, .inscatter = 0.6f, .cloudCover = 0.3f, .cloud = RGB(0.20, 0.17, 0.28),
             .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 1, .shadow = 1, .exposure = 1.25f, .saturation = 1.1f, .contrast = 1.05f,
             .bloom = 0.08f, .shafts = 0.2f, .vignette = 0.14f, .whiteBalance = RGB(1.02, 1.0, 0.97)},
   .skySun = RGB(3.0, 1.2, 0.5), .cloudBase = 1300, .cloudDepth = 500, .clearHorizon = 0.7f, .clearDistance = 16000,
   .cirrus = 0.6f, .storm = 0, .wind = 3, .contrails = 0.5f, .cumulus = 1},
  {.light = {.name = "Overcast", .elevation = 50, .azimuth = 138, .sun = RGB(0, 0, 0),
             .skyAmbient = RGB(0.62, 0.66, 0.72), .groundAmbient = RGB(0.17, 0.17, 0.16),
             .zenith = RGB(0.62, 0.66, 0.72), .horizon = RGB(0.80, 0.83, 0.87), .fog = RGB(0.62, 0.66, 0.71),
             .fogDensity = 0.00009f, .fogFalloff = 0.0005f, .inscatter = 0, .cloudCover = 0.97f, .cloud = RGB(1.5, 1.55, 1.63),
             .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0.2f, .shadow = 0, .exposure = 1.15f, .saturation = 0.95f, .contrast = 1.03f,
             .bloom = 0.04f, .shafts = 0, .vignette = 0.12f, .whiteBalance = RGB(1, 1, 1)},
   .skySun = RGB(0.4, 0.4, 0.42), .cloudBase = 1050, .cloudDepth = 700, .clearHorizon = 0.1f, .clearDistance = 30000,
   .cirrus = 0, .storm = 0.15f, .wind = 6, .contrails = 0},
  // The scene draws the mist (it lies below the eye); the sky above is clear and cold.
  {.light = {.name = "Valley mist", .elevation = 24, .azimuth = 158, .sun = RGB(3.2, 2.7, 2.1),
             .skyAmbient = RGB(0.28, 0.38, 0.62), .groundAmbient = RGB(0.16, 0.17, 0.18),
             .zenith = RGB(0.05, 0.16, 0.52), .horizon = RGB(0.66, 0.76, 0.94), .fog = RGB(0.60, 0.70, 0.90),
             .fogDensity = 0.00003f, .fogFalloff = 0.0009f, .inscatter = 0.8f, .cloudCover = 0.1f, .cloud = RGB(0.55, 0.6, 0.72),
             .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 1, .shadow = 1, .exposure = 1.0f, .saturation = 1.05f, .contrast = 1.06f,
             .bloom = 0.07f, .shafts = 0.25f, .vignette = 0.12f, .whiteBalance = RGB(1.0, 1.0, 1.0)},
   .skySun = RGB(3.2, 2.7, 2.1), .cloudBase = 1400, .cloudDepth = 400, .clearHorizon = 0.8f, .clearDistance = 15000,
   .cirrus = 0.7f, .storm = 0, .wind = 2, .contrails = 0.6f, .cumulus = 1},
  {.light = {.name = "Night", .elevation = 38, .azimuth = 132, .sun = RGB(0.075, 0.09, 0.125),
             .skyAmbient = RGB(0.012, 0.017, 0.032), .groundAmbient = RGB(0.005, 0.006, 0.008),
             .zenith = RGB(0.0025, 0.0045, 0.013), .horizon = RGB(0.012, 0.017, 0.032), .fog = RGB(0.01, 0.014, 0.026),
             .fogDensity = 0.00003f, .fogFalloff = 0.0009f, .inscatter = 0.3f, .cloudCover = 0.18f, .cloud = RGB(0.012, 0.015, 0.024),
             .lamp = RGB(1.0, 0.72, 0.42), .sunDisk = 0, .shadow = 1, .night = 1, .stars = 1, .exposure = 4.2f, .saturation = 0.8f,
             .contrast = 1.04f, .bloom = 0.1f, .shafts = 0, .vignette = 0.18f, .whiteBalance = RGB(0.97, 1.0, 1.05)},
   .skySun = RGB(0.075, 0.09, 0.125), .cloudBase = 1300, .cloudDepth = 450, .clearHorizon = 0.5f, .clearDistance = 20000,
   .cirrus = 0.25f, .storm = 0, .wind = 3, .contrails = 0, .cumulus = 1},
};

static const size_t kPresetCount = sizeof kPresets / sizeof kPresets[0];

@implementation AlpineEnvironment

+ (NSArray<NSString *> *)presetNames {
  NSMutableArray *names = [NSMutableArray array];
  for (size_t i = 0; i < kPresetCount; i++) [names addObject:@(kPresets[i].light.name)];
  return names;
}

- (void)applyPreset:(NSString *)preset to:(FrameUniforms *)u {
  const CoastPreset *p = &kPresets[0];
  for (size_t i = 0; i < kPresetCount; i++) {
    if (strcmp(kPresets[i].light.name, preset.UTF8String) == 0) p = &kPresets[i];
  }
  CoastPresetApply(p, u);
  u->windDir = simd_normalize(simd_make_float2(0.5f, -0.86f));
}

@end
