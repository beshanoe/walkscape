#import "BackdropEngine.h"

#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/log.h>

#import "FrameUtil.h"
#import "PTPrivate.h"

static NSString *const kPortraitPath = @"/System/Library/PrivateFrameworks/Portrait.framework/Portrait";
static NSErrorDomain const BackdropErrorDomain = @"BackdropEngine";

static NSError *BackdropError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:BackdropErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

@implementation BackdropEngine {
  Class _effectClass;
  Class _descriptorClass;
  Class _requestClass;
  PTEffect *_effect;
  uint64_t _configuredTypes;
  CGSize _colorSize;
  OSType _colorFormat;
  CVPixelBufferPoolRef _outPool;
  CVPixelBufferPoolRef _mattePool;
  NSLock *_lock;
  os_log_t _log;
  __weak id _patchedBackgroundReplacement;
}

@synthesize wantsMatte = _wantsMatte, lastRenderMs = _lastRenderMs;

- (instancetype)initWithError:(NSError **)error {
  if (!(self = [super init])) return nil;
  if (!dlopen(kPortraitPath.fileSystemRepresentation, RTLD_LAZY)) {
    if (error) *error = BackdropError(1, [NSString stringWithFormat:@"Cannot load Portrait.framework: %s", dlerror()]);
    return nil;
  }
  _effectClass = NSClassFromString(@"PTEffect");
  _descriptorClass = NSClassFromString(@"PTEffectDescriptor");
  _requestClass = NSClassFromString(@"PTEffectRenderRequest");
  if (!_effectClass || !_descriptorClass || !_requestClass) {
    if (error) *error = BackdropError(2, @"Portrait.framework no longer has PTEffect / PTEffectDescriptor / PTEffectRenderRequest");
    return nil;
  }
  _effectTypes = BackdropEffectBackground;
  _quality = 100;
  _studioLightStrength = NAN;
  _lock = [NSLock new];
  _log = os_log_create("dev.walkscape.app", "engine");
  return self;
}

- (void)dealloc {
  if (_outPool) CVPixelBufferPoolRelease(_outPool);
  if (_mattePool) CVPixelBufferPoolRelease(_mattePool);
}

// Mirrors -[BWBackgroundBlurNode _configurePTEffect]: descriptor → PTEffect. No external
// Metal queue, so -[PTEffect render:] waits for the GPU and the output is ready on return.
- (BOOL)configureForSize:(CGSize)size format:(OSType)format types:(uint64_t)types error:(NSError **)error {
  PTEffectDescriptor *desc = [[_descriptorClass alloc] init];
  desc.colorSize = size;
  desc.externalDisparitySize = CGSizeZero;
  desc.availableEffectTypes = types;
  desc.activeEffectType = types;
  desc.effectQuality = self.quality;
  desc.allowSkipOutColorBufferWrite = NO;
  desc.externalCamera = YES;
  desc.syncInitialization = YES;

  CFTimeInterval t0 = CACurrentMediaTime();
  PTEffect *effect = [[_effectClass alloc] initWithDescriptor:desc];
  if (!effect) {
    if (error) *error = BackdropError(3, @"PTEffect initWithDescriptor: returned nil");
    return NO;
  }
  int status = [effect waitForInitialization];
  os_log(_log, "PTEffect ready in %.0f ms (status %d, %.0fx%.0f, types 0x%llx)", (CACurrentMediaTime() - t0) * 1000, status,
         size.width, size.height, types);
  if (status != 0) {
    if (error) *error = BackdropError(4, [NSString stringWithFormat:@"PTEffect initialization failed (%d)", status]);
    return NO;
  }
  _effect = effect;
  _configuredTypes = types;
  _colorSize = size;
  _colorFormat = format;
  if (_outPool) CVPixelBufferPoolRelease(_outPool);
  _outPool = BackdropCreatePool((size_t)size.width, (size_t)size.height, format);
  if (_mattePool) CVPixelBufferPoolRelease(_mattePool);
  PTEffectPixelBufferDescriptor m = [(id)_effectClass personSegmentationMatteFormatForColorSize:size];
  _mattePool = m.pixelFormat ? BackdropCreatePool((size_t)m.size.width, (size_t)m.size.height, m.pixelFormat) : NULL;
  return YES;
}

// Apple's engine treats every new background buffer as "the user picked another background"
// and cross-fades to it over PTBackgroundReplacement._transitionDuration (0.8 s, set once in
// its init). A new video frame every 33 ms restarts that fade every frame, which freezes the
// picture on the first background. Shrinking the duration makes each new frame take over on
// the next render (one frame of delay). Returns NO if the ivar layout is not as expected.
- (BOOL)disableBackgroundCrossfade {
  static Ivar rendererBg, duration;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    rendererBg = class_getInstanceVariable(NSClassFromString(@"PTEffectRenderer"), "_backgroundReplacement");
    duration = class_getInstanceVariable(NSClassFromString(@"PTBackgroundReplacement"), "_transitionDuration");
    if (duration && strcmp(ivar_getTypeEncoding(duration), "f") != 0) duration = NULL;
  });
  if (!rendererBg || !duration) return NO;
  id renderer = [_effect valueForKey:@"unsafeDelegateDirectAccess"];
  id bg = renderer ? object_getIvar(renderer, rendererBg) : nil;
  if (!bg || bg == _patchedBackgroundReplacement) return bg != nil;
  float *value = (float *)((uint8_t *)(__bridge void *)bg + ivar_getOffset(duration));
  os_log(_log, "PTBackgroundReplacement %p: transition %.2f s -> %.4f s", bg, *value, 1e-4);
  *value = 1e-4f;
  _patchedBackgroundReplacement = bg;
  return YES;
}

- (BOOL)prepareForSize:(CGSize)size format:(OSType)format error:(NSError **)error {
  [_lock lock];
  BOOL ok = YES;
  @try {
    uint64_t types = self.effectTypes;
    if (!_effect || !CGSizeEqualToSize(size, _colorSize) || format != _colorFormat || (types & ~_configuredTypes)) {
      ok = [self configureForSize:size format:format types:(types | _configuredTypes) error:error];
    }
  } @catch (NSException *e) {
    if (error) *error = BackdropError(7, [NSString stringWithFormat:@"PTEffect threw %@: %@", e.name, e.reason]);
    ok = NO;
  } @finally {
    [_lock unlock];
  }
  return ok;
}

- (CVPixelBufferRef)renderCamera:(CVPixelBufferRef)camera
                      background:(CVPixelBufferRef)background
                            time:(double)seconds
                        outMatte:(CVPixelBufferRef *)outMatte
                           error:(NSError **)error {
  [_lock lock];
  CFTimeInterval t0 = CACurrentMediaTime();
  CVPixelBufferRef result = NULL;
  CVPixelBufferRef matte = NULL;
  @try {
    CGSize size = CGSizeMake(CVPixelBufferGetWidth(camera), CVPixelBufferGetHeight(camera));
    OSType format = CVPixelBufferGetPixelFormatType(camera);
    uint64_t types = self.effectTypes;
    // Background replacement without a background frame is rejected; drop the bit.
    if (!background) types &= ~(uint64_t)BackdropEffectBackground;
    if (!_effect || !CGSizeEqualToSize(size, _colorSize) || format != _colorFormat || (types & ~_configuredTypes)) {
      if (![self configureForSize:size format:format types:(types | _configuredTypes) error:error]) return NULL;
    }

    CVPixelBufferRef out = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _outPool, &out) != kCVReturnSuccess) {
      if (error) *error = BackdropError(5, @"Output pixel buffer pool exhausted");
      return NULL;
    }
    if (self.wantsMatte && _mattePool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _mattePool, &matte);

    PTEffectRenderRequest *req = [[_requestClass alloc] init];
    req.inColorBuffer = camera;
    req.outColorBuffer = out;
    req.inBackgroundReplacementBuffer = background;
    req.outPersonSegmentationMatteBuffer = matte;
    req.frameTimeSeconds = seconds;
    req.effectType = types;
    req.effectQuality = self.quality;
    req.transform = CGAffineTransformIdentity;
    req.apertureSDOF = [(id)_requestClass apertureSDOFDefault];
    float strength = self.studioLightStrength;
    req.relightStrengthStudioLight = isnan(strength) ? [(id)_requestClass relightStrengthStudioLightDefault] : strength;

    int status = [_effect render:req];
    [self disableBackgroundCrossfade];
    if (status != 0) {
      CVPixelBufferRelease(out);
      if (error) *error = BackdropError(6, [NSString stringWithFormat:@"PTEffect render failed (%d)", status]);
      return NULL;
    }
    // With allowSkipOutColorBufferWrite = NO this should never be set, but stay safe.
    if (req.outColorBufferWriteSkipped) {
      CVPixelBufferRelease(out);
      out = CVPixelBufferRetain(camera);
    }
    result = out;
    if (outMatte) {
      *outMatte = matte;
      matte = NULL;
    }
  } @catch (NSException *e) {
    if (error) *error = BackdropError(7, [NSString stringWithFormat:@"PTEffect threw %@: %@", e.name, e.reason]);
    result = NULL;
  } @finally {
    if (matte) CVPixelBufferRelease(matte);
    _lastRenderMs = (CACurrentMediaTime() - t0) * 1000;
    [_lock unlock];
  }
  return result;
}

@end
