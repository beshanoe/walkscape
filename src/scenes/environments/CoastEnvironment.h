// The coast: the open sky over the sea (CoastSky.metal). Its clouds have volume: a raymarched
// layer, lit edges and darker cores, ragged storm bases, rain curtains, high cirrus; toward the
// horizon they give way to clear sky. Presets: Golden hour (low sun over the sea), Overcast,
// Stormy (no sun on the scene, a bright band under the deck, rain, wet ground, lamps on). The sun
// stands over the sea on the left of the picture; a scene with the sea on the right mirrors it
// (-adjustLighting:values:), as it sets the wind's direction (FrameUniforms.windDir).

#import "Environment.h"

NS_ASSUME_NONNULL_BEGIN

/// A coast preset: the light, and the sky's clouds and weather (FrameUniforms' coast fields).
typedef struct {
  LightPreset light;
  simd_float3 skySun;
  float cloudBase, cloudDepth, clearHorizon, clearDistance, cirrus, storm, wind, contrails, cumulus;
} CoastPreset;

/// Fills the lighting and the coast fields of `u` from `preset`.
void CoastPresetApply(const CoastPreset *preset, FrameUniforms *u);

/// Draws CoastSky.metal's sky behind the scene. Subclasses with other presets (the mountains'
/// AlpineEnvironment) override +presetNames and -applyPreset:to:.
@interface CoastEnvironment : SceneEnvironment
@end

/// The clouds' noise (CoastSky.h), drawn by coast_bake_noise in `library` and mipmapped. Scenes
/// that mirror the sky bake their own copy (it is the same).
id<MTLTexture> _Nullable CoastCloudNoise(id<MTLDevice> device, id<MTLLibrary> library, NSError **error);

NS_ASSUME_NONNULL_END
