// Environments: the lighting model a scene lives in, between the host (camera, walking, the
// picture's look) and the scene (layout, geometry). An environment owns its lighting presets,
// fills the lighting part of FrameUniforms from them, and draws what is behind the scene where
// it drew nothing (outdoors: the sky). Scenes name theirs (+[WalkScene environment]) and offer
// a subset of its presets as their "lighting" setting.
//
//   OutdoorEnvironment: sun, sky and clouds, weather and time of day (Sunny … Night).
//   IndoorEnvironment:  light fixtures, daylight through windows (Bright … Night).
//   CoastEnvironment:   the open sky over the sea, clouds with volume, rain (Golden hour … Stormy).
//   AlpineEnvironment:  the coast's sky in thin mountain air (Clear day … Night).
//
// The host's machinery works for both: a shadow map for the key light (the sun, also through
// windows) when the preset has shadows, light shafts when the sky shows the sun, bloom, grade.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "Scene.h"

NS_ASSUME_NONNULL_BEGIN

/// One preset's light. Colours are linear RGB; light colours include their intensity. The key
/// light's direction is relative to the view: the camera looks along −z (back along the walk);
/// azimuth 0 is straight ahead in the picture, negative to the left, positive to the right.
typedef struct {
  const char *name;
  float elevation, azimuth;  // degrees
  simd_float3 sun;           // key light: the sun (or moon, or daylight through windows)
  simd_float3 skyAmbient, groundAmbient;
  simd_float3 zenith, horizon;  // sky; indoors, what shiny surfaces reflect
  simd_float3 fog;
  float fogDensity, fogFalloff, inscatter;
  float cloudCover;
  simd_float3 cloud;
  float sunDisk, shadow, wetness, night, stars;
  simd_float3 lamp;  // street lamps, light fixtures (on as much as `night` says)
  float exposure, saturation, contrast, bloom, shafts, vignette;
  simd_float3 whiteBalance;
} LightPreset;

/// Fills the lighting and grade fields of `u` from `preset`.
void LightPresetApply(const LightPreset *preset, FrameUniforms *u);

@interface SceneEnvironment : NSObject

/// Every preset, in menu order.
@property(class, nonatomic, readonly) NSArray<NSString *> *presetNames;
/// The shader files the host compiles into its library for this environment (after
/// SceneShared.h and Common.metal), e.g. @[@"Outdoor.metal"]. None by default.
@property(class, nonatomic, readonly) NSArray<NSString *> *shaderSources;
/// A scene's "lighting" choice: `presets` (from presetNames, in that order), `preset` first selected.
+ (SceneParameter *)lightingParameter:(NSArray<NSString *> *)presets default:(NSString *)preset;

/// Created once by the host. `library` holds Common.metal and the environments' shaders.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library error:(NSError **)error;
/// Fills the lighting part of `u` for `preset` (an unknown name gives the first preset).
- (void)applyPreset:(NSString *)preset to:(FrameUniforms *)u;
/// Draws, after the scene and in its pass, what is behind it: only where the depth is still at
/// the far plane. Nothing by default.
- (void)encodeBackdrop:(id<MTLRenderCommandEncoder>)encoder frame:(const SceneFrame *)frame;

@end

NS_ASSUME_NONNULL_END
