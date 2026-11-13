#import "Environment.h"

void LightPresetApply(const LightPreset *p, FrameUniforms *u) {
  float el = p->elevation * (float)M_PI / 180, az = p->azimuth * (float)M_PI / 180;
  u->sunDir = simd_make_float3(sinf(az) * cosf(el), sinf(el), -cosf(az) * cosf(el));
  u->sunColor = p->sun;
  u->skyAmbient = p->skyAmbient;
  u->groundAmbient = p->groundAmbient;
  u->skyZenith = p->zenith;
  u->skyHorizon = p->horizon;
  u->fogColor = p->fog;
  u->fogDensity = p->fogDensity;
  u->fogFalloff = p->fogFalloff;
  u->inscatter = p->inscatter;
  u->cloudCover = p->cloudCover;
  u->cloudColor = p->cloud;
  u->sunDisk = p->sunDisk;
  u->shadowStrength = p->shadow;
  u->wetness = p->wetness;
  u->night = p->night;
  u->stars = p->stars;
  u->lampColor = p->lamp;
  u->exposure = p->exposure;
  u->saturation = p->saturation;
  u->contrast = p->contrast;
  u->bloom = p->bloom;
  u->shafts = p->shafts;
  u->vignette = p->vignette;
  u->whiteBalance = p->whiteBalance;
}

@implementation SceneEnvironment

+ (NSArray<NSString *> *)presetNames {
  return @[];
}

+ (NSArray<NSString *> *)shaderSources {
  return @[];
}

+ (SceneParameter *)lightingParameter:(NSArray<NSString *> *)presets default:(NSString *)preset {
  NSUInteger index = [presets indexOfObject:preset];
  return [SceneParameter choiceWithKey:@"lighting" title:@"Light" section:@"Lighting" choices:presets
                                 value:index == NSNotFound ? 0 : (NSInteger)index];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library error:(NSError **)error {
  return [super init];
}

- (void)applyPreset:(NSString *)preset to:(FrameUniforms *)u {
}

- (void)encodeBackdrop:(id<MTLRenderCommandEncoder>)encoder frame:(const SceneFrame *)frame {
}

@end
