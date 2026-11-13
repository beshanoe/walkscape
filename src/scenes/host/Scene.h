// The scene interface. A scene (forest road, Paris street, …) owns its layout, meshes, ground and
// settings; the host (SceneRenderer) owns everything they share: walking (speed → distance), the
// floating origin, the webcam's camera (height, tilt, field of view), the sky, lighting and
// post-processing, and the conversion into the camera-format buffer.
//
// Adding a scene: a folder src/scenes/<name>/ with a class conforming to WalkScene (XScene.h with
// the types its shaders share, XScene.m, X.metal) that registers itself (SceneRegistry.h):
//
//   + (void)load { [SceneRegistry registerScene:self]; }
//
// Nothing else changes: build.sh picks up the files, the menu, the settings panel and
// backdrop-test read the registry. Deleting the folder removes the scene.
//
// What a scene may build on (build.sh checks the imports and the shader lists):
//   host/          this interface, SceneUtil (Rng, MeshBuilder, matrices), Common.metal
//   environments/  the lighting it lives in (Environment.h)
//   kit/           parts scenes share: the plant pipeline (Plants.h), furniture
// and never another scene: what two scenes need moves to kit/ first.
//
// Frame order: -walkPointAtDistance: (where the camera stands) → the environment's lighting
// preset (Environment.h), then -adjustLighting:values: → -prepareFrame:values: (stream tiles,
// react to settings) → -encodeShadowCasters:frame: once per shadow cascade, when the preset has
// key-light shadows → -encodeScene:frame: into a 4× MSAA pass (colour kSceneColorFormat, depth
// kSceneDepthFormat; the shadow map bound at fragment texture kTextureShadow) → the environment
// draws its backdrop (outdoors the sky) where the scene left the depth at the far plane →
// post-processing. Draw roughly front to back: hidden fragments are then skipped.
// Everything runs on the camera queue, one frame at a time.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

#import "SceneParameter.h"
#import "SceneShared.h"

NS_ASSUME_NONNULL_BEGIN

static const MTLPixelFormat kSceneColorFormat = MTLPixelFormatRGBA16Float;  // linear light
static const MTLPixelFormat kSceneDepthFormat = MTLPixelFormatDepth32Float;
static const NSUInteger kSceneSampleCount = 4;
static const MTLPixelFormat kShadowFormat = MTLPixelFormatDepth32Float;  // depth only, one sample
/// The main pass's second colour attachment: the share of each pixel's light that is ambient
/// (sky, bounce), which the host's ambient occlusion darkens (Common.metal: SceneColor). Cleared
/// to 0, so pipelines that don't write it get no occlusion.
static const MTLPixelFormat kSceneAmbientFormat = MTLPixelFormatR16Float;

/// Sets a main-pass pipeline's attachments: colour, ambient share (written only if `ambient`, by
/// a fragment function returning SceneColor), depth, 4× MSAA.
static inline void SceneDescribeMainPass(MTLRenderPipelineDescriptor *pd, BOOL ambient) {
  pd.colorAttachments[0].pixelFormat = kSceneColorFormat;
  pd.colorAttachments[1].pixelFormat = kSceneAmbientFormat;
  pd.colorAttachments[1].writeMask = ambient ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
  pd.depthAttachmentPixelFormat = kSceneDepthFormat;
  pd.rasterSampleCount = kSceneSampleCount;
}

/// Where the walker is: a point on the ground (absolute coordinates; z grows along the walk) and
/// the walking direction (horizontal, need not be unit length). The host puts the webcam
/// eyeHeight above the point, looking back along -forward.
typedef struct {
  simd_double3 position;
  simd_double3 forward;
} WalkPoint;

/// What a scene gets each frame. `uniforms` is also bound at kBufferFrame (vertex and fragment).
typedef struct {
  FrameUniforms uniforms;
  double time;      // seconds (the camera clock)
  double distance;  // metres walked
  double originZ;   // floating origin: world z = absolute z - originZ (snapped every 512 m)
  simd_double3 eye;  // absolute
  size_t width, height;
} SceneFrame;

/// A snapshot of a scene's settings (immutable). Missing values read as the parameter's default.
@interface SceneValues : NSObject
- (instancetype)initWithParameters:(NSArray<SceneParameter *> *)parameters values:(NSDictionary<NSString *, NSNumber *> *)values
                        generation:(uint64_t)generation layoutGeneration:(uint64_t)layoutGeneration;
- (double)number:(NSString *)key;
- (NSInteger)index:(NSString *)key;
- (BOOL)flag:(NSString *)key;
/// A choice's title ("Sunny"), or nil for a key that isn't a parameter.
- (nullable NSString *)choice:(NSString *)key;
/// Changes whenever any value changes.
@property(nonatomic, readonly) uint64_t generation;
/// Changes when a parameter marked `relayout` changes: time to re-place instances.
@property(nonatomic, readonly) uint64_t layoutGeneration;
@end

@protocol WalkScene <NSObject>

/// "forest": the settings' storage prefix, backdrop-test's --background name and the name of
/// its folder. Scenes are listed in the menu in the alphabetical order of their identifiers.
@property(class, nonatomic, readonly) NSString *identifier;
/// "Forest road", for the background menu.
@property(class, nonatomic, readonly) NSString *title;
@property(class, nonatomic, readonly) NSArray<SceneParameter *> *parameters;
/// The files compiled after SceneShared.h and Common.metal: e.g.
/// @[@"Plants.h", @"Plants.metal", @"XScene.h", @"X.metal"]: the kit's it uses, then its own.
@property(class, nonatomic, readonly) NSArray<NSString *> *shaderSources;
/// The environment it lives in (a SceneEnvironment subclass: OutdoorEnvironment,
/// IndoorEnvironment): its lighting presets and what is drawn behind the scene.
@property(class, nonatomic, readonly) Class environment;

/// `library` holds Common.metal's functions and the scene's own.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library error:(NSError **)error;

/// The walking line after `metres` (deterministic: the same distance gives the same point).
- (WalkPoint)walkPointAtDistance:(double)metres values:(SceneValues *)values;
/// Before drawing: rebuild instances when the tile, origin or layout changed.
- (void)prepareFrame:(const SceneFrame *)frame values:(SceneValues *)values;
/// Draws into the host's pass. Buffer kBufferFrame is already set; set pipelines, depth state etc.
- (void)encodeScene:(id<MTLRenderCommandEncoder>)encoder frame:(const SceneFrame *)frame;

@property(nonatomic, readonly) NSUInteger instanceCount;

@optional
/// The camera's near and far planes in metres, for a scene that reaches further than the host's
/// 0.1 m … 900 m (the mountains: peaks kilometres away). With the near plane fixed, a 32-bit
/// depth resolves about z² / near × 6e-8 metres at distance z, whatever the far plane is.
@property(class, nonatomic, readonly) simd_float2 depthRange;
/// Draws what casts the sun's shadow into a depth-only pass (kShadowFormat, no colour attachment,
/// one sample), once per cascade. `frame->uniforms.viewProj` is the cascade's light matrix and
/// `shadowPass` is 1, so the scene's vertex shaders work unchanged; the host has set the depth
/// state, bias and clamping.
- (void)encodeShadowCasters:(id<MTLRenderCommandEncoder>)encoder frame:(const SceneFrame *)frame;
/// Adjusts the preset's lighting for this scene (e.g. denser air in a forest).
- (void)adjustLighting:(FrameUniforms *)uniforms values:(SceneValues *)values;

@end

NS_ASSUME_NONNULL_END
