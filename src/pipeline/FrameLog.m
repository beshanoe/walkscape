#import "FrameLog.h"

#import <IOSurface/IOSurface.h>

#import "FrameUtil.h"

// Mean luma (0…255) in a 16×9 grid of the Y plane, from every 8th pixel of every 8th row.
typedef struct {
  float cell[16 * 9];
  float mean;
} LumaGrid;

static BOOL MeasureLuma(IOSurfaceRef s, LumaGrid *grid) {
  if (!s || IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return NO;
  const uint8_t *base = IOSurfaceGetBaseAddressOfPlane(s, 0);
  size_t bpr = IOSurfaceGetBytesPerRowOfPlane(s, 0), w = IOSurfaceGetWidthOfPlane(s, 0), h = IOSurfaceGetHeightOfPlane(s, 0);
  double sum[16 * 9] = {0}, all = 0;
  int n[16 * 9] = {0}, count = 0;
  for (size_t y = 4; y < h; y += 8) {
    for (size_t x = 4; x < w; x += 8) {
      int c = (int)(y * 9 / h) * 16 + (int)(x * 16 / w);
      double v = base[y * bpr + x];
      sum[c] += v;
      n[c]++;
      all += v;
      count++;
    }
  }
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  for (int c = 0; c < 16 * 9; c++) grid->cell[c] = n[c] ? (float)(sum[c] / n[c]) : 0;
  grid->mean = count ? (float)(all / count) : -1;
  return YES;
}

static float LargestChange(const LumaGrid *a, const LumaGrid *b) {
  float m = 0;
  for (int c = 0; c < 16 * 9; c++) m = fmaxf(m, fabsf(a->cell[c] - b->cell[c]));
  return m;
}

@implementation FrameLog {
  FILE *_file;
  int _lines;
  IOSurfaceRef _prevSurface;  // the last output shown, to see whether it changes afterwards
  LumaGrid _prevGrid;
  NSString *_dumpDir;
  double _firstPts;
  int _dumped;
}

+ (instancetype)fromDefaults {
  NSString *path = [NSUserDefaults.standardUserDefaults stringForKey:@"frameTimingLog"];
  if (!path.length) return nil;
  FILE *file = fopen(path.fileSystemRepresentation, "w");
  if (!file) return nil;
  FrameLog *log = [FrameLog new];
  log->_file = file;
  log->_dumpDir = [NSUserDefaults.standardUserDefaults stringForKey:@"frameDumpDir"];
  log->_firstPts = NAN;
  fputs("pts,arrive,ready,engine,camTags,engineTags,shownTags,afterTags,surface,camY,bgY,outY,dOut,prevMod\n", file);
  return log;
}

- (void)dealloc {
  if (_file) fclose(_file);
  if (_prevSurface) CFRelease(_prevSurface);
}

+ (NSString *)tagsOf:(CVPixelBufferRef)buffer {
  const CFStringRef keys[] = {kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey};
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (int i = 0; i < 3; i++) {
    CFTypeRef v = CVBufferCopyAttachment(buffer, keys[i], NULL);
    id value = (__bridge id)v;
    [parts addObject:[value isKindOfClass:NSString.class] ? [value stringByReplacingOccurrencesOfString:@"ITU_R_" withString:@""] : (v ? @"?" : @"-")];
    if (v) CFRelease(v);
  }
  return [parts componentsJoinedByString:@"/"];
}

+ (float)meanLumaOf:(CVPixelBufferRef)buffer {
  LumaGrid grid;
  return MeasureLuma(CVPixelBufferGetIOSurface(buffer), &grid) ? grid.mean : -1;
}

- (void)logFrameAt:(CMTime)pts
           arrived:(CFTimeInterval)arrived
             ready:(CFTimeInterval)ready
            engine:(NSString *)engine
        engineTags:(NSString *)engineTags
         shownTags:(NSString *)shownTags
            camera:(CVPixelBufferRef)cam
            output:(CVPixelBufferRef)out
    backgroundLuma:(float)bgY {
  LumaGrid camGrid = {.mean = -1}, outGrid = {.mean = -1}, prevNow;
  MeasureLuma(CVPixelBufferGetIOSurface(cam), &camGrid);
  IOSurfaceRef surface = CVPixelBufferGetIOSurface(out);
  MeasureLuma(surface, &outGrid);
  float prevMod = -1, dOut = -1;
  if (_prevSurface) {
    dOut = LargestChange(&outGrid, &_prevGrid);
    if (MeasureLuma(_prevSurface, &prevNow)) prevMod = LargestChange(&prevNow, &_prevGrid);
    CFRelease(_prevSurface);
  }
  _prevSurface = surface ? (IOSurfaceRef)CFRetain(surface) : NULL;
  _prevGrid = outGrid;
  fprintf(_file, "%.6f,%.6f,%.6f,%s,%s,%s,%s,%s,%u,%.2f,%.2f,%.2f,%.2f,%.2f\n", CMTimeGetSeconds(pts), arrived, ready, engine.UTF8String,
          [FrameLog tagsOf:cam].UTF8String, engineTags.UTF8String, shownTags.UTF8String, [FrameLog tagsOf:out].UTF8String,
          surface ? IOSurfaceGetID(surface) : 0, camGrid.mean, bgY, outGrid.mean, dOut, prevMod);
  if (++_lines % 30 == 0) fflush(_file);

  double t = CMTimeGetSeconds(pts);
  if (isnan(_firstPts)) _firstPts = t;
  if (_dumpDir.length && t - _firstPts >= 10 && t - _firstPts < 11.6) {
    int index = _dumped++;
    for (int i = 0; i < 2; i++) {
      CVPixelBufferRef small = FUConvert(i ? out : cam, kCVPixelFormatType_32BGRA, 640, 360);
      if (!small) continue;
      NSURL *url = [NSURL fileURLWithPath:[_dumpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%03d.png", i ? @"out" : @"cam", index]]];
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FUWritePNG(small, url);
        CVPixelBufferRelease(small);
      });
    }
  }
}

@end
