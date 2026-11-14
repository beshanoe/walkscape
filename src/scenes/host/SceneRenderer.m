#import "SceneRenderer.h"

#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>
#import <simd/simd.h>

#import "Environment.h"
#import "FrameUtil.h"
#import "Scene.h"
#import "SceneRegistry.h"
#import "SceneUtil.h"
#import "ShaderFiles.h"

static const double kOriginSnap = 512.0;
static const NSUInteger kShadowSize = 2048;
static const float kCascadeFar[kShadowCascades] = {22, 120};  // view depth (m)

#pragma mark - Shader sources

/// SceneShared.h + Common.metal, then `files`, as one Metal source.
static NSString *ShaderSource(NSArray<NSString *> *files, NSError **error) {
  NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"];
  for (NSString *name in [@[ @"SceneShared.h", @"Common.metal" ] arrayByAddingObjectsFromArray:files]) {
    NSString *text = ShaderFileText(name);
    if (!text) {
      if (error) *error = SceneError(@"No shader file named %@ in this build", name);
      return nil;
    }
    [src appendFormat:@"\n// ---- %@ ----\n%@", name, text];
  }
  return src;
}

#pragma mark - Settings

@implementation SceneValues {
  NSArray<SceneParameter *> *_parameters;
  NSDictionary<NSString *, NSNumber *> *_values;
}

- (instancetype)initWithParameters:(NSArray<SceneParameter *> *)parameters values:(NSDictionary<NSString *, NSNumber *> *)values
                        generation:(uint64_t)generation layoutGeneration:(uint64_t)layoutGeneration {
  if ((self = [super init])) {
    _parameters = parameters;
    _values = [values copy];
    _generation = generation;
    _layoutGeneration = layoutGeneration;
  }
  return self;
}

- (double)number:(NSString *)key {
  NSNumber *v = _values[key];
  if (v) return v.doubleValue;
  for (SceneParameter *p in _parameters) {
    if ([p.key isEqualToString:key]) return p.defaultValue;
  }
  return 0;
}

- (NSInteger)index:(NSString *)key {
  return (NSInteger)llround([self number:key]);
}

- (BOOL)flag:(NSString *)key {
  return [self number:key] != 0;
}

- (NSString *)choice:(NSString *)key {
  for (SceneParameter *p in _parameters) {
    if ([p.key isEqualToString:key]) return [p describe:[self number:key]];
  }
  return nil;
}

@end

/// One scene's settings as the UI last set them (guarded by SceneRenderer._valuesLock).
@interface SceneSettings : NSObject
@property(nonatomic) NSArray<SceneParameter *> *parameters;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *values;
@property(nonatomic) uint64_t generation, layoutGeneration;
@property(nonatomic, nullable) SceneValues *snapshot;
@end

@implementation SceneSettings
@end

@implementation SceneInfo

- (instancetype)initWithClass:(Class<WalkScene>)cls {
  if ((self = [super init])) {
    _identifier = [cls identifier];
    _title = [cls title];
    _parameters = [cls parameters];
  }
  return self;
}

@end

#pragma mark - Shadow cascades

/// World → light clip space for a cascade covering the camera's view between `near` and `far`
/// (view depth): an orthographic box around the slice's bounding sphere, snapped to whole texels
/// so the shadows don't shimmer as the camera moves. Depth runs from the sun (0) away from it.
static simd_float4x4 CascadeMatrix(simd_float3 eye, simd_float3 fwd, simd_float3 right, simd_float3 up, float tanX, float tanY,
                                   float near, float far, simd_float3 sun, float *texelSize) {
  simd_float3 center = 0;
  simd_float3 corners[8];
  for (int i = 0; i < 8; i++) {
    float d = i < 4 ? near : far;
    corners[i] = eye + fwd * d + right * (d * tanX * (i & 1 ? 1 : -1)) + up * (d * tanY * (i & 2 ? 1 : -1));
    center += corners[i] / 8;
  }
  float r = 0;
  for (int i = 0; i < 8; i++) r = fmaxf(r, simd_length(corners[i] - center));
  r = ceilf(r);
  simd_float3 lz = sun;
  simd_float3 lx = simd_normalize(simd_cross(fabsf(sun.y) > 0.99f ? (simd_float3){1, 0, 0} : (simd_float3){0, 1, 0}, lz));
  simd_float3 ly = simd_cross(lz, lx);
  float texel = 2 * r / kShadowSize;
  float cx = floorf(simd_dot(center, lx) / texel) * texel, cy = floorf(simd_dot(center, ly) / texel) * texel;
  float cz = simd_dot(center, lz);
  float zmin = cz - r, zmax = cz + r + 260;  // tall casters toward the sun
  float dz = zmax - zmin;
  *texelSize = texel;
  return (simd_float4x4){{{lx.x / r, ly.x / r, -lz.x / dz, 0},
                          {lx.y / r, ly.y / r, -lz.y / dz, 0},
                          {lx.z / r, ly.z / r, -lz.z / dz, 0},
                          {-cx / r, -cy / r, zmax / dz, 1}}};
}

#pragma mark - Renderer

@interface SceneRenderer ()
@property(atomic, readwrite, nullable, copy) NSString *sceneError;
@end

@implementation SceneRenderer {
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  id<MTLComputePipelineState> _composePipe, _bloomPipe, _shaftsPipe, _ssaoPipe, _ssaoBlurPipe, _applyAOPipe, _motionPipe;
  id<MTLDepthStencilState> _shadowDepth;
  NSDictionary<NSString *, SceneEnvironment *> *_environments;  // by class name
  CVMetalTextureCacheRef _textureCache;
  CVPixelBufferPoolRef _pool;
  size_t _width, _height;
  id<MTLTexture> _msaaColor, _msaaDepth, _scene, _depth, _blurMid, _blurFull, _bloomA, _bloomB, _shafts;
  id<MTLTexture> _msaaAmbient, _ambient, _aoRaw, _ao, _motion;
  id<MTLTexture> _shadowMap, _black;
  MPSImageGaussianBlur *_midBlur, *_fullBlur, *_bloomBlur;
  double _blurSigmaPx;
  uint32_t _frameCounter;
  os_unfair_lock _cameraLock;
  FUCameraStats _camera;  // the webcam's look, eased (guarded by _cameraLock)
  BOOL _cameraMeasured;
  double _matchIn;  // 0…1, how much of the measured match applies (matchEaseIn); frames only
  BOOL _hasPrevious;  // the last frame's camera, for motion blur
  simd_double3 _prevEye;
  simd_float3 _prevDir;

  NSLock *_lock;  // one frame at a time; guards everything down to _valuesLock
  double _lastTime;
  double _speed;  // m/s, eased
  double _distance;
  id<WalkScene> _current;
  NSString *_currentID;
  NSMutableDictionary<NSString *, id<WalkScene>> *_loaded;
  NSString *_loadingID, *_failedID, *_lastWanted;
  dispatch_queue_t _loadQueue;

  os_unfair_lock _valuesLock;
  NSDictionary<NSString *, SceneSettings *> *_settings;  // scene ID → settings; fixed keys
}

+ (NSArray<SceneInfo *> *)scenes {
  static NSArray<SceneInfo *> *scenes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray *list = [NSMutableArray array];
    for (Class cls in SceneRegistry.scenes) [list addObject:[[SceneInfo alloc] initWithClass:cls]];
    scenes = list;
  });
  return scenes;
}

+ (NSArray<SceneParameter *> *)commonParameters {
  static NSArray<SceneParameter *> *params;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *bg = @"Walk and picture", *cam = @"Webcam position";
    params = @[
      [SceneParameter sliderWithKey:@"speedKmh" title:@"Speed" section:bg minimum:0 maximum:8 step:0.1 value:3.5 format:@"%.1f km/h"],
      [SceneParameter sliderWithKey:@"blurSigma" title:@"Blur" section:bg minimum:0 maximum:12 step:0.1 value:4 format:@"%.1f"],
      [SceneParameter sliderWithKey:@"brightness" title:@"Brightness" section:bg minimum:-1.5 maximum:1.5 step:0.1 value:0 format:@"%+.1f EV"],
      [SceneParameter sliderWithKey:@"grain" title:@"Grain" section:bg minimum:0 maximum:2 step:0.1 value:1 format:@"%.1f× camera"],
      [SceneParameter sliderWithKey:@"matchCamera" title:@"Match the webcam" section:bg minimum:0 maximum:1 step:0.05 value:0.6 format:@"%.2f"],
      [SceneParameter sliderWithKey:@"eyeHeight" title:@"Height above floor" section:cam minimum:0.3 maximum:2.5 step:0.05 value:1.15
                             format:@"%.2f m"],
      [SceneParameter sliderWithKey:@"tiltDeg" title:@"Tilt (up)" section:cam minimum:-30 maximum:60 step:1 value:10 format:@"%.0f°"],
      [SceneParameter sliderWithKey:@"hFovDeg" title:@"Field of view" section:cam minimum:40 maximum:130 step:1 value:66 format:@"%.0f°"],
    ];
  });
  return params;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _device = device;
  _queue = [device newCommandQueue];
  _lock = [NSLock new];
  _valuesLock = OS_UNFAIR_LOCK_INIT;
  _cameraLock = OS_UNFAIR_LOCK_INIT;
  _loaded = [NSMutableDictionary dictionary];
  _loadQueue = dispatch_queue_create("dev.walkscape.scene-load", DISPATCH_QUEUE_SERIAL);
  _lastTime = NAN;
  _cameraNoise = 0.006;  // a typical webcam until Pipeline measures the real one
  for (SceneParameter *p in SceneRenderer.commonParameters) [self setValue:@(p.defaultValue) forKey:p.key];

  NSMutableDictionary *settings = [NSMutableDictionary dictionary];
  for (SceneInfo *info in SceneRenderer.scenes) {
    SceneSettings *s = [SceneSettings new];
    s.parameters = info.parameters;
    s.values = [NSMutableDictionary dictionary];
    settings[info.identifier] = s;
  }
  _settings = settings;

  // The host's library: the post kernels (Common.metal) and the environments' shaders.
  NSMutableArray<NSString *> *environmentFiles = [NSMutableArray array];
  for (Class cls in SceneRegistry.scenes) {
    for (NSString *file in [[cls environment] shaderSources]) {
      if (![environmentFiles containsObject:file]) [environmentFiles addObject:file];
    }
  }
  NSString *source = ShaderSource(environmentFiles, error);
  id<MTLLibrary> lib = source ? [device newLibraryWithSource:source options:nil error:error] : nil;
  if (!lib) return nil;
  _composePipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"compose_yuv420"] error:error];
  _bloomPipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bloom_prefilter"] error:error];
  _shaftsPipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"light_shafts"] error:error];
  _ssaoPipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"ssao"] error:error];
  _ssaoBlurPipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"ssao_blur"] error:error];
  _applyAOPipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"apply_ao"] error:error];
  _motionPipe = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"motion_blur"] error:error];
  if (!_composePipe || !_bloomPipe || !_shaftsPipe || !_ssaoPipe || !_ssaoBlurPipe || !_applyAOPipe || !_motionPipe) return nil;
  NSMutableDictionary *environments = [NSMutableDictionary dictionary];
  for (Class cls in SceneRegistry.scenes) {
    Class env = [cls environment];
    NSString *name = NSStringFromClass(env);
    if (environments[name]) continue;
    environments[name] = [[env alloc] initWithDevice:device library:lib error:error];
    if (!environments[name]) return nil;
  }
  _environments = environments;

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionLess;
  dd.depthWriteEnabled = YES;
  _shadowDepth = [device newDepthStencilStateWithDescriptor:dd];

  MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kShadowFormat width:kShadowSize height:kShadowSize mipmapped:NO];
  sd.textureType = MTLTextureType2DArray;
  sd.arrayLength = kShadowCascades;
  sd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  sd.storageMode = MTLStorageModePrivate;
  _shadowMap = [device newTextureWithDescriptor:sd];
  // Stands in for bloom and shafts when they're off (a 1×1 black texture).
  MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:1 height:1 mipmapped:NO];
  bd.storageMode = MTLStorageModeShared;
  _black = [device newTextureWithDescriptor:bd];
  uint16_t zero[4] = {0};
  [_black replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:sizeof zero];
  CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_textureCache);

  if (![self selectScene:SceneRenderer.scenes.firstObject.identifier error:error]) return nil;
  return self;
}

- (void)dealloc {
  if (_textureCache) CFRelease(_textureCache);
  if (_pool) CVPixelBufferPoolRelease(_pool);
}

#pragma mark Scenes

- (nullable id<WalkScene>)loadScene:(NSString *)sceneID error:(NSError **)error {
  Class cls = [SceneRegistry sceneWithIdentifier:sceneID];
  if (!cls) {
    if (error) *error = SceneError(@"No scene named “%@”", sceneID);
    return nil;
  }
  NSString *source = ShaderSource([cls shaderSources], error);
  id<MTLLibrary> lib = source ? [_device newLibraryWithSource:source options:nil error:error] : nil;
  if (!lib) return nil;
  return [[cls alloc] initWithDevice:_device library:lib error:error];
}

- (BOOL)selectScene:(NSString *)sceneID error:(NSError **)error {
  [_lock lock];
  id<WalkScene> scene = _loaded[sceneID];
  [_lock unlock];
  if (!scene) {
    NSError *err = nil;
    scene = [self loadScene:sceneID error:&err];
    if (!scene) {
      self.sceneError = err.localizedDescription;
      if (error) *error = err;
      return NO;
    }
    [_lock lock];
    _loaded[sceneID] = scene;
    [_lock unlock];
  }
  self.sceneError = nil;
  self.sceneID = sceneID;
  return YES;
}

- (BOOL)waitingForScene {
  NSString *wanted = self.sceneID;
  if (!wanted) return NO;
  [_lock lock];
  BOOL waiting = !_current && !_loaded[wanted] && ![wanted isEqualToString:_failedID];
  [_lock unlock];
  return waiting;
}

// Under _lock: switch to the wanted scene once it's loaded; start loading it otherwise.
- (void)updateCurrentScene {
  NSString *wanted = self.sceneID;
  if (!wanted || [wanted isEqualToString:_currentID]) return;
  if (![wanted isEqualToString:_lastWanted]) _failedID = nil;
  _lastWanted = wanted;
  id<WalkScene> loaded = _loaded[wanted];
  if (loaded) {
    _current = loaded;
    _currentID = wanted;
    return;
  }
  if (_loadingID || [wanted isEqualToString:_failedID]) return;
  _loadingID = wanted;
  __weak SceneRenderer *weakSelf = self;
  dispatch_async(_loadQueue, ^{
    SceneRenderer *me = weakSelf;
    if (!me) return;
    NSError *err = nil;
    id<WalkScene> scene = [me loadScene:wanted error:&err];
    [me->_lock lock];
    if (scene) me->_loaded[wanted] = scene;
    else me->_failedID = wanted;
    me->_loadingID = nil;
    [me->_lock unlock];
    me.sceneError = scene ? nil : err.localizedDescription;
  });
}

#pragma mark Settings

- (void)setValue:(double)value forParameter:(NSString *)key scene:(NSString *)sceneID {
  os_unfair_lock_lock(&_valuesLock);
  SceneSettings *s = _settings[sceneID];
  for (SceneParameter *p in s.parameters) {
    if (![p.key isEqualToString:key]) continue;
    double v = [p clamp:value];
    NSNumber *old = s.values[key];
    if (old && old.doubleValue == v) break;
    s.values[key] = @(v);
    s.generation++;
    if (p.changesLayout) s.layoutGeneration++;
    s.snapshot = nil;
    break;
  }
  os_unfair_lock_unlock(&_valuesLock);
}

- (double)valueForParameter:(NSString *)key scene:(NSString *)sceneID {
  return [[self valuesForScene:sceneID] number:key];
}

- (SceneValues *)valuesForScene:(NSString *)sceneID {
  os_unfair_lock_lock(&_valuesLock);
  SceneSettings *s = _settings[sceneID];
  if (s && !s.snapshot) {
    s.snapshot = [[SceneValues alloc] initWithParameters:s.parameters values:s.values generation:s.generation layoutGeneration:s.layoutGeneration];
  }
  SceneValues *values = s.snapshot ?: [[SceneValues alloc] initWithParameters:@[] values:@{} generation:0 layoutGeneration:0];
  os_unfair_lock_unlock(&_valuesLock);
  return values;
}

- (void)measuredCamera:(FUCameraStats)stats {
  os_unfair_lock_lock(&_cameraLock);
  if (!_cameraMeasured) {
    _camera = stats;
  } else {  // ease: a person moving in the picture shouldn't make the background flicker
    double k = 0.25;
    _camera.black += (stats.black - _camera.black) * k;
    _camera.white += (stats.white - _camera.white) * k;
    _camera.mean += (stats.mean - _camera.mean) * k;
    _camera.cb += (stats.cb - _camera.cb) * k;
    _camera.cr += (stats.cr - _camera.cr) * k;
    _camera.noise += (stats.noise - _camera.noise) * k;
  }
  _cameraMeasured = YES;
  os_unfair_lock_unlock(&_cameraLock);
}

/// The webcam match for this frame (display space, after tone mapping): white balance toward its
/// cast, its black and white levels; exposure toward its brightness.
- (void)matchCameraInto:(FrameUniforms *)u dt:(double)dt {
  u->matchTint = simd_make_float3(1, 1, 1);
  u->matchGain = 1;
  u->matchLift = 0;
  double m = fmin(fmax(self.matchCamera, 0), 1);
  u->lens = (float)m;
  os_unfair_lock_lock(&_cameraLock);
  FUCameraStats c = _camera;
  BOOL measured = _cameraMeasured;
  os_unfair_lock_unlock(&_cameraLock);
  double ease = self.matchEaseIn;
  _matchIn = !measured ? 0 : ease > 0 ? fmin(_matchIn + dt / ease, 1) : 1;
  m *= _matchIn * _matchIn * (3 - 2 * _matchIn);
  if (!measured || m <= 0) return;
  u->exposure *= (float)fmin(fmax(pow(fmax(c.mean, 0.05) / 0.42, 0.5 * m), 0.7), 1.35);
  // The cast: the mid-tones' mean chroma as RGB around a mid grey (BT.709), at unit luminance.
  double y = 0.5, cb = fmin(fmax(c.cb, -0.08), 0.08), cr = fmin(fmax(c.cr, -0.08), 0.08);
  simd_float3 rgb = simd_make_float3((float)(y + 1.5748 * cr), (float)(y - 0.1873 * cb - 0.4681 * cr), (float)(y + 1.8556 * cb));
  rgb /= simd_dot(rgb, simd_make_float3(0.2126f, 0.7152f, 0.0722f));
  u->matchTint = simd_mix(simd_make_float3(1, 1, 1), rgb, simd_make_float3(1, 1, 1) * (float)(0.6 * m));
  u->matchLift = (float)(fmin(fmax(c.black, 0), 0.12) * 0.9 * m);
  u->matchGain = (float)(1 + (fmin(fmax(c.white, 0.75), 1.0) - 1) * m);
}

- (void)jumpToDistance:(double)metres {
  [_lock lock];
  _distance = metres;
  _speed = 0;
  _lastTime = NAN;
  _distanceMetres = metres;
  [_lock unlock];
}

#pragma mark Frames

static id<MTLTexture> NewTexture(id<MTLDevice> device, MTLPixelFormat format, size_t w, size_t h, MTLTextureUsage usage) {
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
  d.usage = usage;
  d.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:d];
}

- (void)ensureTargetsWidth:(size_t)w height:(size_t)h {
  double sigma = self.blurSigma * h / 720.0;
  if (w == _width && h == _height && fabs(sigma - _blurSigmaPx) < 1e-3) return;
  if (w != _width || h != _height) {
    _width = w;
    _height = h;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kSceneColorFormat width:w height:h mipmapped:NO];
    td.textureType = MTLTextureType2DMultisample;
    td.sampleCount = kSceneSampleCount;
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeMemoryless;
    _msaaColor = [_device newTextureWithDescriptor:td];
    td.pixelFormat = kSceneAmbientFormat;
    _msaaAmbient = [_device newTextureWithDescriptor:td];
    td.pixelFormat = kSceneDepthFormat;
    _msaaDepth = [_device newTextureWithDescriptor:td];
    MTLTextureUsage rw = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _scene = NewTexture(_device, kSceneColorFormat, w, h, rw);
    _depth = NewTexture(_device, kSceneDepthFormat, w, h, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    _ambient = NewTexture(_device, kSceneAmbientFormat, w, h, rw);
    _aoRaw = NewTexture(_device, MTLPixelFormatRG16Float, w / 2, h / 2, rw);
    _ao = NewTexture(_device, MTLPixelFormatRG16Float, w / 2, h / 2, rw);
    _motion = NewTexture(_device, kSceneColorFormat, w, h, rw);
    _blurMid = NewTexture(_device, kSceneColorFormat, w, h, rw);
    _blurFull = NewTexture(_device, kSceneColorFormat, w, h, rw);
    _bloomA = NewTexture(_device, kSceneColorFormat, w / 2, h / 2, rw);
    _bloomB = NewTexture(_device, kSceneColorFormat, w / 2, h / 2, rw);
    _shafts = NewTexture(_device, MTLPixelFormatR16Float, w / 2, h / 2, rw);
    _bloomBlur = [[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:(float)(h / 2 / 360.0 * 9)];
    _bloomBlur.edgeMode = MPSImageEdgeModeClamp;
    if (_pool) CVPixelBufferPoolRelease(_pool);
    _pool = BackdropCreatePool(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  }
  _blurSigmaPx = sigma;
  _midBlur = sigma / 2 > 0.3 ? [[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:(float)(sigma / 2)] : nil;
  _fullBlur = sigma > 0.3 ? [[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:(float)sigma] : nil;
  _midBlur.edgeMode = MPSImageEdgeModeClamp;
  _fullBlur.edgeMode = MPSImageEdgeModeClamp;
}

static void Dispatch(id<MTLComputeCommandEncoder> ce, id<MTLComputePipelineState> pipe, size_t w, size_t h) {
  [ce setComputePipelineState:pipe];
  [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
}

- (CVPixelBufferRef)copyFrameAtTime:(double)seconds width:(size_t)width height:(size_t)height {
  [_lock lock];
  [self updateCurrentScene];
  id<WalkScene> scene = _current;
  if (!scene) {
    [_lock unlock];
    return NULL;
  }
  width &= ~(size_t)1;
  height &= ~(size_t)1;

  // Motion: ease the speed (≈0.6 s), integrate distance along the walk.
  double dt = isnan(_lastTime) ? 0 : fmin(fmax(seconds - _lastTime, 0), 0.1);
  _lastTime = seconds;
  double target = fmax(self.speedKmh, 0) / 3.6;
  _speed += (target - _speed) * (1 - exp(-dt / 0.6));
  _distance += _speed * dt;
  _distanceMetres = _distance;

  // Camera: eyeHeight above the walking line, looking back along it, tilted up by tiltDeg.
  SceneValues *values = [self valuesForScene:_currentID];
  WalkPoint wp = [scene walkPointAtDistance:_distance values:values];
  double originZ = floor(wp.position.z / kOriginSnap) * kOriginSnap;
  simd_float3 eye = simd_make_float3((float)wp.position.x, (float)(wp.position.y + self.eyeHeight), (float)(wp.position.z - originZ));
  simd_float3 back = simd_normalize(simd_make_float3((float)-wp.forward.x, 0, (float)-wp.forward.z));
  float tilt = (float)(self.tiltDeg * M_PI / 180);
  simd_float3 dir = simd_normalize(simd_make_float3(back.x * cosf(tilt), sinf(tilt), back.z * cosf(tilt)));
  float aspect = (float)width / (float)height;
  float tanX = tanf((float)(self.hFovDeg * M_PI / 360)), tanY = tanX / aspect;
  float fovy = 2 * atanf(tanY);
  simd_float4x4 view = LookDirection(eye, dir);
  // The depth range: 0.1 m … 900 m unless the scene asks for another (mountains kilometres away).
  simd_float2 range = simd_make_float2(0.1f, 900);
  if ([scene.class respondsToSelector:@selector(depthRange)]) range = [scene.class depthRange];
  simd_float4x4 vp = simd_mul(Perspective(fovy, aspect, range.x, range.y), view);

  SceneFrame frame = {0};
  frame.time = seconds;
  frame.distance = _distance;
  frame.originZ = originZ;
  frame.eye = simd_make_double3(wp.position.x, wp.position.y + self.eyeHeight, wp.position.z);
  frame.width = width;
  frame.height = height;
  FrameUniforms *u = &frame.uniforms;
  u->viewProj = vp;
  u->invViewProj = simd_inverse(vp);
  if (range.y / range.x > 20000) {
    // A deep range (near 0.3 m, far 60 km) makes the matrix ill-conditioned: inverted in single
    // precision, positions rebuilt from depth were off by percents (motion blur smeared a still
    // picture). In double the inverse is exact to the last float bit.
    simd_double4x4 vpd = simd_matrix(simd_double(vp.columns[0]), simd_double(vp.columns[1]), simd_double(vp.columns[2]), simd_double(vp.columns[3]));
    simd_double4x4 inv = simd_inverse(vpd);
    u->invViewProj = simd_matrix(simd_float(inv.columns[0]), simd_float(inv.columns[1]), simd_float(inv.columns[2]), simd_float(inv.columns[3]));
  }
  u->camPos = eye;
  u->camForward = dir;
  u->originZ = (float)originZ;
  u->time = (float)fmod(seconds, 10000.0);
  u->frameIndex = (float)(_frameCounter++ % 100000);
  u->focusDistance = 0.8f;
  u->projScale = (float)height * 0.5f / tanY;
  u->aoRadius = 0.6f;
  // Motion blur: a webcam's shutter is open about half the frame time. Last frame's camera is
  // rebuilt around this frame's origin (it may have snapped); a jump (new scene, seek) has none.
  u->motionBlur = 0.5f;
  u->prevViewProj = vp;
  simd_double3 eyeAbs = simd_make_double3(wp.position.x, wp.position.y + self.eyeHeight, wp.position.z);
  if (_hasPrevious && simd_distance(eyeAbs, _prevEye) < 1.0) {
    simd_float3 prevEye = simd_make_float3((float)_prevEye.x, (float)_prevEye.y, (float)(_prevEye.z - originZ));
    u->prevViewProj = simd_mul(Perspective(fovy, aspect, range.x, range.y), LookDirection(prevEye, _prevDir));
  }
  _hasPrevious = YES;
  _prevEye = eyeAbs;
  _prevDir = dir;

  // Lighting: the scene's preset from its environment, the scene's own adjustments, then the
  // user's brightness and grain.
  SceneEnvironment *environment = _environments[NSStringFromClass([scene.class environment])];
  [environment applyPreset:[values choice:@"lighting"] ?: @"" to:u];
  if ([scene respondsToSelector:@selector(adjustLighting:values:)]) [scene adjustLighting:u values:values];
  u->exposure *= (float)exp2(self.brightness);
  u->grain = (float)(self.cameraNoise * self.grain);
  [self matchCameraInto:u dt:dt];

  // The sun: shadow cascades, and where it is on screen (light shafts).
  simd_float3 right = simd_make_float3(view.columns[0].x, view.columns[1].x, view.columns[2].x);
  simd_float3 up = simd_make_float3(view.columns[0].y, view.columns[1].y, view.columns[2].y);
  float texel[kShadowCascades];
  for (int c = 0; c < kShadowCascades; c++) {
    u->shadowViewProj[c] = CascadeMatrix(eye, dir, right, up, tanX, tanY, c == 0 ? 0.1f : kCascadeFar[c - 1], kCascadeFar[c], u->sunDir, &texel[c]);
  }
  u->shadowSplits = simd_make_float4(kCascadeFar[0], kCascadeFar[1], texel[0], texel[1]);
  simd_float4 sunClip = simd_mul(vp, simd_make_float4(eye + u->sunDir * 500, 1));
  if (sunClip.w > 0 && u->sunDir.y > 0) {
    simd_float2 ndc = sunClip.xy / sunClip.w;
    u->sunScreen = simd_make_float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
    float outside = fmaxf(fabsf(ndc.x), fabsf(ndc.y));
    u->sunOnScreen = (1 - fminf(fmaxf((outside - 1.2f) / 0.8f, 0), 1)) * fminf(u->sunDir.y * 8, 1);
  }
  BOOL shafts = u->shafts > 0 && u->sunOnScreen > 0 && simd_reduce_max(u->sunColor) > 0;

  [scene prepareFrame:&frame values:values];
  _instanceCount = scene.instanceCount;
  [self ensureTargetsWidth:width height:height];

  CVPixelBufferRef out = NULL;
  CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &out);
  if (!out) {
    [_lock unlock];
    return NULL;
  }
  CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVMetalTextureRef lumaRef = NULL, chromaRef = NULL;
  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, out, NULL, MTLPixelFormatR8Unorm, width, height, 0, &lumaRef);
  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, out, NULL, MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, &chromaRef);

  id<MTLCommandBuffer> cb = [_queue commandBuffer];

  // Shadow map: one depth pass per cascade, the scene's casters seen from the sun.
  BOOL casters = u->shadowStrength > 0 && [scene respondsToSelector:@selector(encodeShadowCasters:frame:)];
  for (int c = 0; c < kShadowCascades; c++) {
    MTLRenderPassDescriptor *sp = [MTLRenderPassDescriptor renderPassDescriptor];
    sp.depthAttachment.texture = _shadowMap;
    sp.depthAttachment.slice = c;
    sp.depthAttachment.loadAction = MTLLoadActionClear;
    sp.depthAttachment.storeAction = MTLStoreActionStore;
    sp.depthAttachment.clearDepth = 1;
    id<MTLRenderCommandEncoder> se = [cb renderCommandEncoderWithDescriptor:sp];
    if (casters) {
      SceneFrame shadowFrame = frame;
      shadowFrame.uniforms.viewProj = u->shadowViewProj[c];
      shadowFrame.uniforms.shadowPass = 1;
      [se setVertexBytes:&shadowFrame.uniforms length:sizeof shadowFrame.uniforms atIndex:kBufferFrame];
      [se setFragmentBytes:&shadowFrame.uniforms length:sizeof shadowFrame.uniforms atIndex:kBufferFrame];
      [se setDepthStencilState:_shadowDepth];
      [se setDepthClipMode:MTLDepthClipModeClamp];
      [se setDepthBias:0 slopeScale:2.0f clamp:0.002f];
      [se setCullMode:MTLCullModeNone];
      [scene encodeShadowCasters:se frame:&shadowFrame];
    }
    [se endEncoding];
  }

  MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = _msaaColor;
  rp.colorAttachments[0].resolveTexture = _scene;
  rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(u->fogColor.x, u->fogColor.y, u->fogColor.z, 1);
  rp.colorAttachments[1].texture = _msaaAmbient;
  rp.colorAttachments[1].resolveTexture = _ambient;
  rp.colorAttachments[1].loadAction = MTLLoadActionClear;
  rp.colorAttachments[1].storeAction = MTLStoreActionMultisampleResolve;
  rp.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rp.depthAttachment.texture = _msaaDepth;
  rp.depthAttachment.resolveTexture = _depth;
  rp.depthAttachment.loadAction = MTLLoadActionClear;
  rp.depthAttachment.storeAction = MTLStoreActionMultisampleResolve;
  rp.depthAttachment.depthResolveFilter = MTLMultisampleDepthResolveFilterMin;
  rp.depthAttachment.clearDepth = 1;
  id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
  [re setVertexBytes:u length:sizeof *u atIndex:kBufferFrame];
  [re setFragmentBytes:u length:sizeof *u atIndex:kBufferFrame];
  [re setFragmentTexture:_shadowMap atIndex:kTextureShadow];
  [scene encodeScene:re frame:&frame];
  [environment encodeBackdrop:re frame:&frame];  // outdoors the sky, where the scene left it empty
  [re endEncoding];

  // Post: ambient occlusion and motion blur (when on), two blur levels for the depth-aware blur,
  // bloom, light shafts, then compose + 420v.
  id<MTLTexture> image = _scene;
  if (u->aoStrength > 0 || u->motionBlur > 0) {
    id<MTLComputeCommandEncoder> pe = [cb computeCommandEncoder];
    [pe setBytes:u length:sizeof *u atIndex:kBufferFrame];
    if (u->aoStrength > 0) {
      [pe setTexture:_depth atIndex:0];
      [pe setTexture:_aoRaw atIndex:1];
      Dispatch(pe, _ssaoPipe, _aoRaw.width, _aoRaw.height);
      [pe setTexture:_aoRaw atIndex:0];
      [pe setTexture:_ao atIndex:1];
      Dispatch(pe, _ssaoBlurPipe, _ao.width, _ao.height);
      id<MTLTexture> t[4] = {_scene, _ambient, _depth, _ao};
      for (int i = 0; i < 4; i++) [pe setTexture:t[i] atIndex:i];
      Dispatch(pe, _applyAOPipe, width, height);
    }
    if (u->motionBlur > 0 && !simd_equal(u->prevViewProj, vp)) {
      id<MTLTexture> t[3] = {_scene, _depth, _motion};
      for (int i = 0; i < 3; i++) [pe setTexture:t[i] atIndex:i];
      Dispatch(pe, _motionPipe, width, height);
      image = _motion;
    }
    [pe endEncoding];
  }
  id<MTLTexture> mid = image, full = image;
  if (_fullBlur) {
    [_fullBlur encodeToCommandBuffer:cb sourceTexture:image destinationTexture:_blurFull];
    full = _blurFull;
    if (_midBlur) {
      [_midBlur encodeToCommandBuffer:cb sourceTexture:image destinationTexture:_blurMid];
      mid = _blurMid;
    }
  }
  id<MTLTexture> bloom = _black, shaftTex = _black;
  if (u->bloom > 0) {
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setTexture:image atIndex:0];
    [ce setTexture:_bloomA atIndex:1];
    Dispatch(ce, _bloomPipe, _bloomA.width, _bloomA.height);
    [ce endEncoding];
    [_bloomBlur encodeToCommandBuffer:cb sourceTexture:_bloomA destinationTexture:_bloomB];
    bloom = _bloomB;
  }
  id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
  [ce setBytes:u length:sizeof *u atIndex:kBufferFrame];
  if (shafts) {
    [ce setTexture:_depth atIndex:0];
    [ce setTexture:_shafts atIndex:1];
    Dispatch(ce, _shaftsPipe, _shafts.width, _shafts.height);
    shaftTex = _shafts;
  }
  uint32_t blurred = _fullBlur != nil;
  id<MTLTexture> inputs[8] = {image, mid, full, _depth, bloom, shaftTex, CVMetalTextureGetTexture(lumaRef), CVMetalTextureGetTexture(chromaRef)};
  for (int i = 0; i < 8; i++) [ce setTexture:inputs[i] atIndex:i];
  [ce setBytes:&blurred length:sizeof blurred atIndex:1];
  Dispatch(ce, _composePipe, width / 2, height / 2);
  [ce endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  if (cb.status == MTLCommandBufferStatusCompleted) _lastGpuMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
  else NSLog(@"scene frame failed: %@", cb.error);
  if (lumaRef) CFRelease(lumaRef);
  if (chromaRef) CFRelease(chromaRef);
  [_lock unlock];
  return out;
}

@end
