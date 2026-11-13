#import "VisionBackdropEngine.h"

#import <QuartzCore/QuartzCore.h>
#import <Vision/Vision.h>
#import <os/log.h>

#import "FrameUtil.h"
#import "ShaderFiles.h"
#import "VisionBackdropShared.h"

static NSErrorDomain const VisionBackdropErrorDomain = @"VisionBackdropEngine";

static NSError *VBError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:VisionBackdropErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

static BOOL IsYUV420(CVPixelBufferRef buffer) {
  OSType f = CVPixelBufferGetPixelFormatType(buffer);
  return f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

// A Metal view of one plane of an IOSurface-backed buffer; `ref` keeps it alive until released.
static id<MTLTexture> PlaneTexture(CVMetalTextureCacheRef cache, CVPixelBufferRef buffer, size_t plane, MTLPixelFormat format,
                                   CVMetalTextureRef *ref) {
  BOOL planar = CVPixelBufferIsPlanar(buffer);
  size_t w = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer);
  size_t h = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer);
  *ref = NULL;
  if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, NULL, format, w, h, plane, ref) != kCVReturnSuccess) {
    return nil;
  }
  return CVMetalTextureGetTexture(*ref);
}

// Guided filter settings, for a 1080-line camera (scaled with the height).
static const double kRadius1080 = 4;  // low-res pixels (×4 camera pixels)
static const float kEpsilon = 1.5e-4f;
static const double kBandRadius1080 = 8;   // camera pixels the edge may move from Vision's
// Where the colour model decides the edge instead of Vision's mask: R² (how much of the mask the
// colours explain) and how far apart the person's and the old background's local colours are.
static const float kExplainedFrom = 0.5f, kExplainedTo = 0.9f;
static const float kContrastFrom = 0.2f, kContrastTo = 0.4f;
static const float kEdgeSharpen = 1.5f;  // the composite's alpha vs the colour model's (Apple-like spill correction)
// Crop placement (0…1 of the frame's width).
static const double kCropMargin = 0.04;  // room beside the person inside the crop
static const float kMovedOutside = 0.04f;  // share of a column's pixels moving outside the crop → whole frame
static const int kWholeFrameHold = 30;  // frames to stay on the whole frame after that

@implementation VisionBackdropEngine {
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  id<MTLComputePipelineState> _toRGB, _prepare, _statsH, _statsV, _boxH, _boxV, _columns, _composite;
  CVMetalTextureCacheRef _cache;
  VNSequenceRequestHandler *_sequence;
  VNGeneratePersonSegmentationRequest *_request;
  NSLock *_lock;
  os_log_t _log;
  MTLPixelFormat _sampledFormat;  // rgba32Float if the GPU filters it, else rgba16Float

  // Per camera size and format.
  size_t _width, _height;
  OSType _format;
  vector_uint2 _low;
  CVPixelBufferPoolRef _outPool, _mattePool, _rgbPool;  // _rgbPool: what Vision gets
  id<MTLTexture> _guide, _state[2], _sums[4], _coef, _coefTmp, _coefMean, _fit, _person, _behind;
  id<MTLTexture> _emptyMask, _noMatte;
  id<MTLBuffer> _columnsBuffer;
  int _stateIndex;
  BOOL _hasPrevious;
  CGRect _crop;  // what Vision looks at next (0…1, top-left origin)
  int _wholeFrameHold;
}

@synthesize wantsMatte = _wantsMatte, lastRenderMs = _lastRenderMs;

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error {
  if (!(self = [super init])) return nil;
  if (!device) {
    if (error) *error = VBError(1, @"No Metal device");
    return nil;
  }
  _device = device;
  _queue = [device newCommandQueue];
  _log = os_log_create("dev.walkscape.app", "vision");

  // Compiled at runtime, like the scenes (build.sh embeds the files).
  NSString *shared = ShaderFileText(@"VisionBackdropShared.h"), *kernels = ShaderFileText(@"VisionBackdrop.metal");
  if (!shared || !kernels) {
    if (error) *error = VBError(2, @"Vision cutout shaders missing from this build");
    return nil;
  }
  NSString *source = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\n%@", shared, kernels];
  MTLCompileOptions *options = [MTLCompileOptions new];
  options.mathMode = MTLMathModeSafe;  // the guided filter divides small numbers
  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:source options:options error:&err];
  if (!lib) {
    if (error) *error = VBError(2, [NSString stringWithFormat:@"Vision cutout shaders: %@", err.localizedDescription]);
    return nil;
  }
  id<MTLComputePipelineState> __strong *slots[] = {&_toRGB, &_prepare, &_statsH, &_statsV, &_boxH, &_boxV, &_columns, &_composite};
  NSArray *names = @[ @"vb_to_rgb", @"vb_prepare", @"vb_stats_h", @"vb_stats_v", @"vb_box_h", @"vb_box_v", @"vb_columns", @"vb_composite" ];
  for (NSUInteger i = 0; i < names.count; i++) {
    id<MTLFunction> fn = [lib newFunctionWithName:names[i]];
    *slots[i] = fn ? [device newComputePipelineStateWithFunction:fn error:&err] : nil;
    if (!*slots[i]) {
      if (error) *error = VBError(3, [NSString stringWithFormat:@"Vision cutout kernel %@: %@", names[i], err.localizedDescription ?: @"missing"]);
      return nil;
    }
  }
  if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_cache) != kCVReturnSuccess) {
    if (error) *error = VBError(4, @"Cannot create a Metal texture cache");
    return nil;
  }
  _sampledFormat = device.supports32BitFloatFiltering ? MTLPixelFormatRGBA32Float : MTLPixelFormatRGBA16Float;

  _request = [VNGeneratePersonSegmentationRequest new];
  _request.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
  _request.outputPixelFormat = kCVPixelFormatType_OneComponent16Half;
  _sequence = [VNSequenceRequestHandler new];  // the request keeps state across frames this way

  _emptyMask = [self textureWithFormat:MTLPixelFormatR16Float width:1 height:1 private:NO];
  uint16_t zero = 0;
  [_emptyMask replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&zero bytesPerRow:2];
  _noMatte = [self textureWithFormat:MTLPixelFormatR8Unorm width:1 height:1 private:YES];

  _cropToPerson = YES;
  _refineEdges = YES;
  _temporal = 0.5f;
  _crop = CGRectMake(0, 0, 1, 1);
  _lastCrop = _crop;
  _lock = [NSLock new];
  return self;
}

- (void)dealloc {
  if (_outPool) CVPixelBufferPoolRelease(_outPool);
  if (_mattePool) CVPixelBufferPoolRelease(_mattePool);
  if (_rgbPool) CVPixelBufferPoolRelease(_rgbPool);
  if (_cache) CFRelease(_cache);
}

- (id<MTLTexture>)textureWithFormat:(MTLPixelFormat)format width:(NSUInteger)w height:(NSUInteger)h private:(BOOL)private {
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  d.storageMode = private ? MTLStorageModePrivate : MTLStorageModeShared;
  return [_device newTextureWithDescriptor:d];
}

- (void)configureForWidth:(size_t)width height:(size_t)height format:(OSType)format {
  _width = width;
  _height = height;
  _format = format;
  _low = (vector_uint2){(uint32_t)((width + kVBScale - 1) / kVBScale), (uint32_t)((height + kVBScale - 1) / kVBScale)};
  if (_outPool) CVPixelBufferPoolRelease(_outPool);
  if (_mattePool) CVPixelBufferPoolRelease(_mattePool);
  if (_rgbPool) CVPixelBufferPoolRelease(_rgbPool);
  _outPool = BackdropCreatePool(width, height, format);
  _mattePool = BackdropCreatePool(width, height, kCVPixelFormatType_OneComponent8);
  // Vision's mask is 512×384 whatever it's given; more than 1280 wide only costs memory.
  size_t rgbWidth = MIN(width, (size_t)1280), rgbHeight = (height * rgbWidth / width) & ~(size_t)1;
  _rgbPool = BackdropCreatePool(rgbWidth, rgbHeight, kCVPixelFormatType_32BGRA);
  MTLPixelFormat f32 = MTLPixelFormatRGBA32Float;
  _guide = [self textureWithFormat:f32 width:_low.x height:_low.y private:YES];
  for (int i = 0; i < 2; i++) _state[i] = [self textureWithFormat:MTLPixelFormatRGBA16Float width:_low.x height:_low.y private:YES];
  for (int i = 0; i < 4; i++) _sums[i] = [self textureWithFormat:f32 width:_low.x height:_low.y private:YES];
  _coef = [self textureWithFormat:f32 width:_low.x height:_low.y private:YES];
  _coefTmp = [self textureWithFormat:f32 width:_low.x height:_low.y private:YES];
  _coefMean = [self textureWithFormat:_sampledFormat width:_low.x height:_low.y private:YES];
  _fit = [self textureWithFormat:_sampledFormat width:_low.x height:_low.y private:YES];
  _person = [self textureWithFormat:_sampledFormat width:_low.x height:_low.y private:YES];
  _behind = [self textureWithFormat:_sampledFormat width:_low.x height:_low.y private:YES];
  _columnsBuffer = [_device newBufferWithLength:_low.x * sizeof(vector_float2) options:MTLResourceStorageModeShared];
  _hasPrevious = NO;
  _crop = CGRectMake(0, 0, 1, 1);
  _wholeFrameHold = 0;
  os_log(_log, "Vision cutout: %zux%zu, low-res %ux%u", width, height, _low.x, _low.y);
}

static void Dispatch(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pipeline, NSUInteger w, NSUInteger h) {
  [enc setComputePipelineState:pipeline];
  NSUInteger tw = pipeline.threadExecutionWidth, th = MAX(pipeline.maxTotalThreadsPerThreadgroup / tw, 1);
  if (h == 1) th = 1;
  [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(tw, MIN(th, h), 1)];
}

- (CVPixelBufferRef)renderCamera:(CVPixelBufferRef)camera
                      background:(CVPixelBufferRef)background
                            time:(double)seconds
                        outMatte:(CVPixelBufferRef *)outMatte
                           error:(NSError **)error {
  [_lock lock];
  CFTimeInterval t0 = CACurrentMediaTime();
  CVPixelBufferRef out = [self lockedRenderCamera:camera background:background outMatte:outMatte error:error];
  _lastRenderMs = (CACurrentMediaTime() - t0) * 1000;
  [_lock unlock];
  return out;
}

- (CVPixelBufferRef)lockedRenderCamera:(CVPixelBufferRef)camera
                            background:(CVPixelBufferRef)background
                              outMatte:(CVPixelBufferRef *)outMatte
                                 error:(NSError **)error {
  if (outMatte) *outMatte = NULL;
  size_t width = CVPixelBufferGetWidth(camera), height = CVPixelBufferGetHeight(camera);
  OSType format = CVPixelBufferGetPixelFormatType(camera);
  if (!IsYUV420(camera) || (width | height) & 1) {
    if (error) *error = VBError(5, @"The camera frame isn't 4:2:0 YUV ('420v'/'420f') with an even size");
    return NULL;
  }
  if (!background) return CVPixelBufferRetain(camera);  // nothing to put behind you
  if (!IsYUV420(background)) {
    if (error) *error = VBError(6, @"The background frame isn't 4:2:0 YUV ('420v'/'420f')");
    return NULL;
  }
  if (width != _width || height != _height || format != _format) [self configureForWidth:width height:height format:format];

  BOOL refine = self.refineEdges;
  CGRect crop = refine && self.cropToPerson ? _crop : CGRectMake(0, 0, 1, 1);

  // Vision: the person mask for (the crop of) this frame, from an RGB copy. Its regionOfInterest
  // has a bottom-left origin; the crop is always full height, so only x matters.
  CFTimeInterval tv = CACurrentMediaTime();
  CVPixelBufferRef rgb = [self copyRGBOfCamera:camera videoRange:format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
  if (!rgb) {
    if (error) *error = VBError(11, @"Cannot convert the camera frame for Vision");
    return NULL;
  }
  _request.regionOfInterest = CGRectMake(crop.origin.x, 1 - CGRectGetMaxY(crop), crop.size.width, crop.size.height);
  NSError *visionError = nil;
  BOOL segmented = [_sequence performRequests:@[ _request ] onCVPixelBuffer:rgb orientation:kCGImagePropertyOrientationUp error:&visionError];
  CVPixelBufferRelease(rgb);
  if (!segmented) {
    if (error) *error = VBError(7, [NSString stringWithFormat:@"Vision person segmentation failed: %@", visionError.localizedDescription]);
    return NULL;
  }
  CVPixelBufferRef maskBuffer = _request.results.firstObject.pixelBuffer;
  _lastMaskMs = (CACurrentMediaTime() - tv) * 1000;
  _lastCrop = crop;

  CVPixelBufferRef out = NULL, matte = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _outPool, &out) != kCVReturnSuccess) {
    if (error) *error = VBError(8, @"Output pixel buffer pool exhausted");
    return NULL;
  }
  BOOL wantsMatte = self.wantsMatte && outMatte;
  if (wantsMatte) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _mattePool, &matte);

  CVMetalTextureRef refs[8] = {0};
  id<MTLTexture> camY = PlaneTexture(_cache, camera, 0, MTLPixelFormatR8Unorm, &refs[0]);
  id<MTLTexture> camC = PlaneTexture(_cache, camera, 1, MTLPixelFormatRG8Unorm, &refs[1]);
  id<MTLTexture> bgY = PlaneTexture(_cache, background, 0, MTLPixelFormatR8Unorm, &refs[2]);
  id<MTLTexture> bgC = PlaneTexture(_cache, background, 1, MTLPixelFormatRG8Unorm, &refs[3]);
  id<MTLTexture> outY = PlaneTexture(_cache, out, 0, MTLPixelFormatR8Unorm, &refs[4]);
  id<MTLTexture> outC = PlaneTexture(_cache, out, 1, MTLPixelFormatRG8Unorm, &refs[5]);
  id<MTLTexture> mask = _emptyMask;
  if (maskBuffer) {
    OSType mf = CVPixelBufferGetPixelFormatType(maskBuffer);
    MTLPixelFormat f = mf == kCVPixelFormatType_OneComponent16Half ? MTLPixelFormatR16Float
                       : mf == kCVPixelFormatType_OneComponent32Float ? MTLPixelFormatR32Float
                                                                      : MTLPixelFormatR8Unorm;
    mask = PlaneTexture(_cache, maskBuffer, 0, f, &refs[6]) ?: _emptyMask;
  }
  id<MTLTexture> matteTex = matte ? PlaneTexture(_cache, matte, 0, MTLPixelFormatR8Unorm, &refs[7]) : nil;

  CVPixelBufferRef result = NULL;
  if (camY && camC && bgY && bgC && outY && outC) {
    VBParams p = {0};
    p.size = (vector_uint2){(uint32_t)width, (uint32_t)height};
    p.low = _low;
    p.roi = (vector_float4){(float)crop.origin.x, (float)crop.origin.y, (float)CGRectGetMaxX(crop), (float)CGRectGetMaxY(crop)};
    // Aspect fill: the background's middle part with the camera's aspect.
    double camAspect = (double)width / height;
    double bgAspect = (double)CVPixelBufferGetWidth(background) / CVPixelBufferGetHeight(background);
    vector_float2 scale = {1, 1};
    if (bgAspect > camAspect) scale.x = (float)(camAspect / bgAspect);
    else scale.y = (float)(bgAspect / camAspect);
    p.bgScale = scale;
    p.bgOffset = (vector_float2){(1 - scale.x) / 2, (1 - scale.y) / 2};
    p.camVideoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    p.bgVideoRange = CVPixelBufferGetPixelFormatType(background) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    p.eps = kEpsilon;
    p.temporal = self.temporal;
    p.explainedFrom = kExplainedFrom;
    p.explainedTo = kExplainedTo;
    p.contrastFrom = kContrastFrom;
    p.contrastTo = kContrastTo;
    p.edgeSharpen = kEdgeSharpen;
    p.bandRadius = (float)(kBandRadius1080 * height / 1080.0);
    p.radius = MAX((int)lround(kRadius1080 * height / 1080.0), 2);
    p.refine = refine;
    p.hasPrevious = _hasPrevious;
    p.writeMatte = matteTex != nil;

    id<MTLTexture> previous = _state[_stateIndex], next = _state[_stateIndex ^ 1];
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];  // serial: each pass sees the last
    [enc setBytes:&p length:sizeof p atIndex:0];
    if (refine) {
      [enc setTextures:(id<MTLTexture>[]){camY, camC, mask, previous, _guide, next} withRange:NSMakeRange(0, 6)];
      Dispatch(enc, _prepare, _low.x, _low.y);
      [enc setTextures:(id<MTLTexture>[]){_guide, _sums[0], _sums[1], _sums[2], _sums[3]} withRange:NSMakeRange(0, 5)];
      Dispatch(enc, _statsH, _low.x, _low.y);
      [enc setTextures:(id<MTLTexture>[]){_sums[0], _sums[1], _sums[2], _sums[3], _coef, _fit, _person, _behind} withRange:NSMakeRange(0, 8)];
      Dispatch(enc, _statsV, _low.x, _low.y);
      [enc setTextures:(id<MTLTexture>[]){_coef, _coefTmp} withRange:NSMakeRange(0, 2)];
      Dispatch(enc, _boxH, _low.x, _low.y);
      [enc setTextures:(id<MTLTexture>[]){_coefTmp, _coefMean} withRange:NSMakeRange(0, 2)];
      Dispatch(enc, _boxV, _low.x, _low.y);
      [enc setTexture:next atIndex:0];
      [enc setBuffer:_columnsBuffer offset:0 atIndex:1];
      Dispatch(enc, _columns, _low.x, 1);
    }
    [enc setTextures:(id<MTLTexture>[]){camY, camC, bgY, bgC, mask, _coefMean, _fit, _person, _behind, outY, outC, matteTex ?: _noMatte}
           withRange:NSMakeRange(0, 12)];
    Dispatch(enc, _composite, width / 2, height / 2);
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusCompleted) {
      result = out;
      out = NULL;
      CVBufferPropagateAttachments(camera, result);
      if (refine) {
        _stateIndex ^= 1;
        _hasPrevious = YES;
        [self placeCropWithColumns:(const vector_float2 *)_columnsBuffer.contents count:_low.x aspect:camAspect];
      } else {
        _hasPrevious = NO;
      }
      if (matte && outMatte) {
        *outMatte = matte;
        matte = NULL;
      }
    } else if (error) {
      *error = VBError(9, [NSString stringWithFormat:@"Vision cutout GPU work failed: %@", cb.error.localizedDescription]);
    }
  } else if (error) {
    *error = VBError(10, @"Cannot map the frames to Metal textures");
  }
  for (int i = 0; i < 8; i++)
    if (refs[i]) CFRelease(refs[i]);
  if (out) CVPixelBufferRelease(out);
  if (matte) CVPixelBufferRelease(matte);
  return result;
}

// The camera frame as RGB (≤ 1280 wide) for Vision, which converts 4:2:0 itself much more slowly.
- (CVPixelBufferRef)copyRGBOfCamera:(CVPixelBufferRef)camera videoRange:(BOOL)videoRange CF_RETURNS_RETAINED {
  CVPixelBufferRef rgb = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _rgbPool, &rgb) != kCVReturnSuccess) return NULL;
  CVMetalTextureRef refs[3] = {0};
  id<MTLTexture> y = PlaneTexture(_cache, camera, 0, MTLPixelFormatR8Unorm, &refs[0]);
  id<MTLTexture> c = PlaneTexture(_cache, camera, 1, MTLPixelFormatRG8Unorm, &refs[1]);
  id<MTLTexture> out = PlaneTexture(_cache, rgb, 0, MTLPixelFormatBGRA8Unorm, &refs[2]);
  BOOL ok = NO;
  if (y && c && out) {
    VBParams p = {0};
    p.camVideoRange = videoRange;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setBytes:&p length:sizeof p atIndex:0];
    [enc setTextures:(id<MTLTexture>[]){y, c, out} withRange:NSMakeRange(0, 3)];
    Dispatch(enc, _toRGB, out.width, out.height);
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    ok = cb.status == MTLCommandBufferStatusCompleted;
  }
  for (int i = 0; i < 3; i++)
    if (refs[i]) CFRelease(refs[i]);
  if (!ok) {
    CVPixelBufferRelease(rgb);
    return NULL;
  }
  CVBufferPropagateAttachments(camera, rgb);
  return rgb;
}

// Where Vision looks next frame. Its mask is 4:3 whatever it's given; a 4:3 crop of a wider frame
// around the person gets their shape unsquashed and a third more mask pixels across them. Whole
// frame: nobody found, the person (plus margins) wider than the crop, or something moving
// outside it (a hand reaching out, someone walking in), the latter for a second.
- (void)placeCropWithColumns:(const vector_float2 *)columns count:(NSUInteger)n aspect:(double)aspect {
  CGRect whole = CGRectMake(0, 0, 1, 1);
  double width = (4.0 / 3.0) / aspect;
  if (!self.cropToPerson || width > 0.98 || n == 0) {
    _crop = whole;
    return;
  }
  BOOL cropped = _crop.size.width < 0.999;
  if (cropped) {
    for (NSUInteger i = 0; i < n; i++) {
      double x = (i + 0.5) / n;
      if ((x < _crop.origin.x || x > CGRectGetMaxX(_crop)) && columns[i].y > kMovedOutside) {
        _crop = whole;
        _wholeFrameHold = kWholeFrameHold;
        return;
      }
    }
  } else if (_wholeFrameHold > 0) {
    _wholeFrameHold--;
    return;
  }
  NSInteger first = -1, last = -1;
  for (NSUInteger i = 0; i < n; i++) {
    if (columns[i].x < 0.5f) continue;
    if (first < 0) first = (NSInteger)i;
    last = (NSInteger)i;
  }
  if (first < 0) {
    _crop = whole;
    return;
  }
  double x0 = (double)first / n, x1 = (double)(last + 1) / n;
  if (x1 - x0 + 2 * kCropMargin > width) {
    if (cropped) _wholeFrameHold = kWholeFrameHold;
    _crop = whole;
    return;
  }
  // Keep the crop while the person stays clear of its sides; else centre it on them.
  if (cropped && x0 >= _crop.origin.x + kCropMargin / 2 && x1 <= CGRectGetMaxX(_crop) - kCropMargin / 2) return;
  double left = fmin(fmax((x0 + x1) / 2 - width / 2, 0), 1 - width);
  _crop = CGRectMake(left, 0, width, 1);
}

@end
