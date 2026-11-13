#import "FrameUtil.h"

#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>

CVPixelBufferPoolRef BackdropCreatePool(size_t width, size_t height, OSType format) {
  NSDictionary *attrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(format),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVPixelBufferPoolRef pool = NULL;
  CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef) @{(id)kCVPixelBufferPoolMinimumBufferCountKey : @3},
                          (__bridge CFDictionaryRef)attrs, &pool);
  return pool;
}

CVPixelBufferRef FUConvert(CVPixelBufferRef src, OSType format, size_t width, size_t height) {
  static VTPixelTransferSessionRef session;
  static dispatch_once_t once;
  static NSLock *lock;
  dispatch_once(&once, ^{
    VTPixelTransferSessionCreate(kCFAllocatorDefault, &session);
    VTSessionSetProperty(session, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal);
    lock = [NSLock new];
  });
  NSDictionary *attrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVPixelBufferRef dst = NULL;
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess) {
    return NULL;
  }
  [lock lock];
  OSStatus st = VTPixelTransferSessionTransferImage(session, src, dst);
  [lock unlock];
  if (st != noErr) {
    CVPixelBufferRelease(dst);
    return NULL;
  }
  return dst;
}

BOOL FUCropScale(CVPixelBufferRef src, CGRect rect, CVPixelBufferRef dst) {
  static VTPixelTransferSessionRef session;
  static dispatch_once_t once;
  static NSLock *lock;
  dispatch_once(&once, ^{
    VTPixelTransferSessionCreate(kCFAllocatorDefault, &session);
    VTSessionSetProperty(session, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_CropSourceToCleanAperture);
    lock = [NSLock new];
  });
  // VideoToolbox crops to the source's clean aperture. Put that on a second CVPixelBuffer around
  // the same IOSurface, so `src`'s own attachments don't change.
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(src);
  CVPixelBufferRef view = NULL;
  if (!surface || CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &view) != kCVReturnSuccess) return NO;
  double w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src);
  NSDictionary *aperture = @{
    (id)kCVImageBufferCleanApertureWidthKey : @(rect.size.width),
    (id)kCVImageBufferCleanApertureHeightKey : @(rect.size.height),
    // Offsets of the aperture's centre from the picture's centre; positive is right and down.
    (id)kCVImageBufferCleanApertureHorizontalOffsetKey : @(CGRectGetMidX(rect) - w / 2),
    (id)kCVImageBufferCleanApertureVerticalOffsetKey : @(CGRectGetMidY(rect) - h / 2),
  };
  CVBufferSetAttachment(view, kCVImageBufferCleanApertureKey, (__bridge CFDictionaryRef)aperture, kCVAttachmentMode_ShouldPropagate);
  [lock lock];
  OSStatus st = VTPixelTransferSessionTransferImage(session, view, dst);
  [lock unlock];
  CVPixelBufferRelease(view);
  if (st != noErr) return NO;
  // The source's colour tags, so the copy looks the same wherever it's shown. Only those: a clean
  // aperture copied over would crop the copy.
  FUCopyColorTags(src, dst);
  return YES;
}

void FUCopyColorTags(CVPixelBufferRef src, CVPixelBufferRef dst) {
  const CFStringRef keys[] = {kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey};
  const CFStringRef hd[] = {kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVImageBufferColorPrimaries_ITU_R_709_2,
                            kCVImageBufferTransferFunction_ITU_R_709_2};
  for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
    CFTypeRef value = CVBufferCopyAttachment(src, keys[i], NULL);
    CVBufferSetAttachment(dst, keys[i], value ?: hd[i], kCVAttachmentMode_ShouldPropagate);
    if (value) CFRelease(value);
  }
}

CGRect FUFillRect(CGSize frame, CGRect crop, CGFloat aspect) {
  CGRect r = CGRectIntersection(CGRectMake(crop.origin.x * frame.width, crop.origin.y * frame.height, crop.size.width * frame.width,
                                           crop.size.height * frame.height),
                                CGRectMake(0, 0, frame.width, frame.height));
  if (CGRectIsEmpty(r)) r = CGRectMake(0, 0, frame.width, frame.height);
  if (r.size.width > r.size.height * aspect) return CGRectInset(r, (r.size.width - r.size.height * aspect) / 2, 0);
  return CGRectInset(r, 0, (r.size.height - r.size.width / aspect) / 2);
}

CVPixelBufferRef FUBufferFromImage(CGImageRef image, size_t width, size_t height, CGFloat focusY) {
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}, (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES};
  CVPixelBufferRef buf = NULL;
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &buf) != kCVReturnSuccess) {
    return NULL;
  }
  CVPixelBufferLockBaseAddress(buf, 0);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buf), width, height, 8, CVPixelBufferGetBytesPerRow(buf), cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  double iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
  double scale = MAX(width / iw, height / ih);
  double dw = iw * scale, dh = ih * scale;
  // CG's origin is bottom-left: focusY 0 keeps the top of the image.
  double y = (height - dh) * (1.0 - focusY);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
  CGContextDrawImage(ctx, CGRectMake((width - dw) / 2, y, dw, dh), image);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  CVPixelBufferUnlockBaseAddress(buf, 0);
  return buf;
}

BOOL FUWritePNG(CVPixelBufferRef buffer, NSURL *url) {
  static CIContext *ctx;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ctx = [CIContext contextWithOptions:nil];
  });
  CIImage *img = [CIImage imageWithCVPixelBuffer:buffer];
  if (!img) return NO;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  BOOL ok = [ctx writePNGRepresentationOfImage:img toURL:url format:kCIFormatRGBA8 colorSpace:cs options:@{} error:nil];
  CGColorSpaceRelease(cs);
  return ok;
}

CVPixelBufferRef FUSyntheticBackground(size_t width, size_t height, double t) {
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}, (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES};
  CVPixelBufferRef bgra = NULL;
  CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &bgra);
  if (!bgra) return NULL;
  CVPixelBufferLockBaseAddress(bgra, 0);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(bgra), width, height, 8, CVPixelBufferGetBytesPerRow(bgra), cs,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGContextSetRGBFillColor(ctx, 0.10, 0.18, 0.28, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
  double stripe = width / 8.0;
  double shift = fmod(t * stripe, stripe * 2);
  for (int i = -2; i < 10; i++) {
    double hue = fmod(i * 0.13 + t * 0.05, 1.0);
    NSColor *c = [NSColor colorWithHue:hue saturation:0.55 brightness:0.85 alpha:1];
    CGContextSetFillColorWithColor(ctx, c.CGColor);
    CGContextFillRect(ctx, CGRectMake(i * stripe * 2 + shift, 0, stripe, height));
  }
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  CVPixelBufferUnlockBaseAddress(bgra, 0);
  CVPixelBufferRef out = FUConvert(bgra, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width, height);
  CVPixelBufferRelease(bgra);
  return out;
}

static int CompareFloats(const void *a, const void *b) {
  float x = *(const float *)a, y = *(const float *)b;
  return x < y ? -1 : x > y;
}

BOOL FUMeasureCamera(CVPixelBufferRef buf, FUCameraStats *stats) {
  OSType format = CVPixelBufferGetPixelFormatType(buf);
  BOOL video = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  if (!video && format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NO;
  CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
  const uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(buf, 0), *chroma = CVPixelBufferGetBaseAddressOfPlane(buf, 1);
  size_t w = CVPixelBufferGetWidthOfPlane(buf, 0), h = CVPixelBufferGetHeightOfPlane(buf, 0);
  size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0), cstride = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
  enum { kCols = 64, kRows = 36 };
  float laplace[kCols * kRows], levels[kCols * kRows];
  double sum = 0, cb = 0, cr = 0, neutral = 0;
  int n = 0;
  float yScale = video ? 1.0f / 219 : 1.0f / 255, yOffset = video ? 16 : 0, cScale = video ? 1.0f / 224 : 1.0f / 255;
  for (int j = 0; j < kRows && h > 4 && w > 4; j++) {
    size_t y = 1 + (h - 3) * j / (kRows - 1);
    const uint8_t *r0 = luma + (y - 1) * stride, *r1 = luma + y * stride, *r2 = luma + (y + 1) * stride;
    for (int i = 0; i < kCols; i++) {
      size_t x = 1 + (w - 3) * i / (kCols - 1);
      int v = r0[x - 1] - 2 * r0[x] + r0[x + 1] - 2 * r1[x - 1] + 4 * r1[x] - 2 * r1[x + 1] + r2[x - 1] - 2 * r2[x] + r2[x + 1];
      laplace[n] = (float)abs(v);
      float l = fminf(fmaxf((r1[x] - yOffset) * yScale, 0), 1);
      levels[n] = l;
      const uint8_t *c = chroma + (y / 2) * cstride + (x / 2) * 2;
      float u = (c[0] - 128) * cScale, v2 = (c[1] - 128) * cScale;
      sum += l;
      if (l > 0.15f && l < 0.9f && u * u + v2 * v2 < 0.05f * 0.05f) {  // near-neutral surfaces show the light's colour
        cb += u;
        cr += v2;
        neutral++;
      }
      n++;
    }
  }
  CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
  if (n == 0) return NO;
  qsort(laplace, n, sizeof(float), CompareFloats);
  qsort(levels, n, sizeof(float), CompareFloats);
  // The mask's response to white noise has std 6σ; median |x| = 0.6745 std.
  stats->noise = laplace[n / 2] / (0.6745 * 6) * yScale;
  stats->black = levels[n * 2 / 100];
  stats->white = levels[n * 98 / 100];
  stats->mean = sum / n;
  stats->cb = neutral > n / 20 ? cb / neutral : 0;
  stats->cr = neutral > n / 20 ? cr / neutral : 0;
  return YES;
}
