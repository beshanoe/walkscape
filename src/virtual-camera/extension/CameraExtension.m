// WalkScape Camera: the CoreMediaIO camera extension, a system extension inside the app
// (Contents/Library/SystemExtensions/dev.walkscape.app.camera.systemextension). Once the user has
// approved it, macOS runs it in its own sandboxed process and video apps list "WalkScape Camera".
//
// One device, two streams:
//   source  what video apps open: 1920×1080 '420v' at 30 fps (VirtualCameraShared.h).
//   sink    the WalkScape app pushes its finished frames into it (a CMIO output stream, see
//           VirtualCamera.m); each goes on to the source as is, IOSurface-backed, no copy.
// While no frames arrive (the app is closed, or its camera is off), the source shows a card
// saying so.
//
// Logs: os_log subsystem dev.walkscape.app.camera. `--selftest <dir>` builds the device in this
// process (without registering it with the system) and writes the card to <dir>/card.png; use the
// unsandboxed build/camera-extension for that.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOExtension.h>
#import <CoreText/CoreText.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOKit/audio/IOAudioTypes.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import <os/log.h>

#import "VirtualCameraShared.h"

static const int kSinkQueueSize = 4;                             // frames the app may queue ahead
static const uint64_t kAppFrameTimeoutNs = 500 * NSEC_PER_MSEC;  // then the card takes over

static os_log_t Log(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    log = os_log_create("dev.walkscape.app.camera", "extension");
  });
  return log;
}

static uint64_t HostTimeNs(void) {
  return (uint64_t)CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), NSEC_PER_SEC, kCMTimeRoundingMethod_Default).value;
}

static CMVideoFormatDescriptionRef CreateFormat(void) CF_RETURNS_RETAINED {
  NSDictionary *extensions = @{
    (id)kCMFormatDescriptionExtension_ColorPrimaries : (id)kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
    (id)kCMFormatDescriptionExtension_TransferFunction : (id)kCMFormatDescriptionTransferFunction_ITU_R_709_2,
    (id)kCMFormatDescriptionExtension_YCbCrMatrix : (id)kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
  };
  CMVideoFormatDescriptionRef format = NULL;
  CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kVCWidth, kVCHeight,
                                 (__bridge CFDictionaryRef)extensions, &format);
  return format;
}

#pragma mark The card

static void DrawCentredLine(CGContextRef ctx, NSString *text, CTFontUIFontType type, CGFloat size, CGColorRef color, CGFloat centreY) {
  CTFontRef font = CTFontCreateUIFontForLanguage(type, size, NULL);
  NSDictionary *attrs = @{(id)kCTFontAttributeName : (__bridge id)font, (id)kCTForegroundColorAttributeName : (__bridge id)color};
  CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:text attributes:attrs]);
  CGRect b = CTLineGetBoundsWithOptions(line, 0);
  CGContextSetTextPosition(ctx, (kVCWidth - b.size.width) / 2 - b.origin.x, centreY - b.size.height / 2 - b.origin.y);
  CTLineDraw(line, ctx);
  CFRelease(line);
  CFRelease(font);
}

// Dark forest green, a row of tree silhouettes, two lines of text. Drawn once at launch.
static void DrawCard(CGContextRef ctx) {
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  const CGFloat sky[] = {0.08, 0.14, 0.11, 1, 0.17, 0.26, 0.21, 1};  // bottom, top
  CGGradientRef gradient = CGGradientCreateWithColorComponents(cs, sky, NULL, 2);
  CGContextDrawLinearGradient(ctx, gradient, CGPointZero, CGPointMake(0, kVCHeight), 0);
  CGGradientRelease(gradient);
  CGColorSpaceRelease(cs);

  CGContextSetRGBFillColor(ctx, 0.05, 0.09, 0.07, 1);
  uint32_t r = 7;
  for (double x = -40; x < kVCWidth + 40; x += 64) {
    r = r * 1664525u + 1013904223u;
    double h = 150 + (r >> 16) % 150, w = h * 0.42;
    CGContextMoveToPoint(ctx, x - w / 2, 0);
    CGContextAddLineToPoint(ctx, x, h);
    CGContextAddLineToPoint(ctx, x + w / 2, 0);
    CGContextClosePath(ctx);
  }
  CGContextFillPath(ctx);

  CGColorRef title = CGColorCreateSRGB(0.93, 0.95, 0.92, 1);
  CGColorRef body = CGColorCreateSRGB(0.68, 0.75, 0.70, 1);
  DrawCentredLine(ctx, kVCDeviceName, kCTFontUIFontEmphasizedSystem, 88, title, kVCHeight * 0.57);
  DrawCentredLine(ctx, @"Waiting for the WalkScape app. Open it to start the walk.", kCTFontUIFontSystem, 42, body, kVCHeight * 0.45);
  CGColorRelease(title);
  CGColorRelease(body);
}

static void Set709(CVPixelBufferRef buffer) {
  CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
}

// The card as a '420v' buffer in the stream's format (IOSurface-backed, so it can be sent).
static CVPixelBufferRef CreateCardBuffer(void) CF_RETURNS_RETAINED {
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  CVPixelBufferRef bgra = NULL, yuv = NULL;
  CVPixelBufferCreate(kCFAllocatorDefault, kVCWidth, kVCHeight, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &bgra);
  CVPixelBufferCreate(kCFAllocatorDefault, kVCWidth, kVCHeight, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)attrs, &yuv);
  OSStatus st = (bgra && yuv) ? noErr : kCVReturnAllocationFailed;
  if (st == noErr) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CVPixelBufferLockBaseAddress(bgra, 0);
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(bgra), kVCWidth, kVCHeight, 8, CVPixelBufferGetBytesPerRow(bgra), cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    DrawCard(ctx);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(bgra, 0);
    CVBufferSetAttachment(bgra, kCVImageBufferCGColorSpaceKey, cs, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRelease(cs);

    VTPixelTransferSessionRef session = NULL;
    st = VTPixelTransferSessionCreate(kCFAllocatorDefault, &session);
    if (st == noErr) {
      VTSessionSetProperty(session, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
      VTSessionSetProperty(session, kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
      VTSessionSetProperty(session, kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
      st = VTPixelTransferSessionTransferImage(session, bgra, yuv);
      VTPixelTransferSessionInvalidate(session);
      CFRelease(session);
    }
  }
  if (bgra) CVPixelBufferRelease(bgra);
  if (st != noErr) {
    os_log_error(Log(), "cannot draw the card: %d", (int)st);
    if (yuv) CVPixelBufferRelease(yuv);
    return NULL;
  }
  Set709(yuv);
  return yuv;
}

#pragma mark Streams

@class WSDevice;

@interface WSDevice : NSObject <CMIOExtensionDeviceSource>
@property(nonatomic, readonly) CMIOExtensionDevice *device;
@property(nonatomic, readonly, nullable) CVPixelBufferRef card;
- (BOOL)authorizeSinkClient:(CMIOExtensionClient *)client;
- (void)startSource;
- (void)stopSource;
- (void)startSink;
- (void)stopSink;
- (void)clientDisconnected:(CMIOExtensionClient *)client;
@end

/// Either stream; the device does the work.
@interface WSStream : NSObject <CMIOExtensionStreamSource>
@property(nonatomic, readonly) CMIOExtensionStream *stream;
@end

@implementation WSStream {
  __weak WSDevice *_device;
  CMIOExtensionStreamFormat *_format;
  BOOL _sink;
}

- (instancetype)initWithName:(NSString *)name uid:(NSString *)uid sink:(BOOL)sink format:(CMIOExtensionStreamFormat *)format device:(WSDevice *)device {
  if (!(self = [super init])) return nil;
  _device = device;
  _format = format;
  _sink = sink;
  _stream = [CMIOExtensionStream streamWithLocalizedName:name
                                                streamID:[[NSUUID alloc] initWithUUIDString:uid]
                                               direction:sink ? CMIOExtensionStreamDirectionSink : CMIOExtensionStreamDirectionSource
                                               clockType:CMIOExtensionStreamClockTypeHostTime
                                                  source:self];
  return self;
}

- (NSArray<CMIOExtensionStreamFormat *> *)formats {
  return @[ _format ];
}

- (NSSet<CMIOExtensionProperty> *)availableProperties {
  NSMutableSet *set = [NSMutableSet setWithObjects:CMIOExtensionPropertyStreamActiveFormatIndex, CMIOExtensionPropertyStreamFrameDuration, nil];
  if (_sink) {
    [set addObjectsFromArray:@[
      CMIOExtensionPropertyStreamSinkBufferQueueSize, CMIOExtensionPropertyStreamSinkBuffersRequiredForStartup,
      CMIOExtensionPropertyStreamSinkBufferUnderrunCount, CMIOExtensionPropertyStreamSinkEndOfData
    ]];
  }
  return set;
}

- (CMIOExtensionStreamProperties *)streamPropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError **)outError {
  CMIOExtensionStreamProperties *p = [CMIOExtensionStreamProperties streamPropertiesWithDictionary:@{}];
  if ([properties containsObject:CMIOExtensionPropertyStreamActiveFormatIndex]) p.activeFormatIndex = @0;
  if ([properties containsObject:CMIOExtensionPropertyStreamFrameDuration]) {
    p.frameDuration = CFBridgingRelease(CMTimeCopyAsDictionary(CMTimeMake(1, kVCFrameRate), kCFAllocatorDefault));
  }
  if (_sink) {
    if ([properties containsObject:CMIOExtensionPropertyStreamSinkBufferQueueSize]) p.sinkBufferQueueSize = @(kSinkQueueSize);
    if ([properties containsObject:CMIOExtensionPropertyStreamSinkBuffersRequiredForStartup]) p.sinkBuffersRequiredForStartup = @1;
    if ([properties containsObject:CMIOExtensionPropertyStreamSinkBufferUnderrunCount]) p.sinkBufferUnderrunCount = @0;
    if ([properties containsObject:CMIOExtensionPropertyStreamSinkEndOfData]) p.sinkEndOfData = @0;
  }
  return p;
}

// One format at one frame rate: nothing a client can change.
- (BOOL)setStreamProperties:(CMIOExtensionStreamProperties *)streamProperties error:(NSError **)outError {
  return YES;
}

- (BOOL)authorizedToStartStreamForClient:(CMIOExtensionClient *)client {
  return _sink ? [_device authorizeSinkClient:client] : YES;
}

- (BOOL)startStreamAndReturnError:(NSError **)outError {
  if (_sink) [_device startSink];
  else [_device startSource];
  return YES;
}

- (BOOL)stopStreamAndReturnError:(NSError **)outError {
  if (_sink) [_device stopSink];
  else [_device stopSource];
  return YES;
}

@end

#pragma mark Device

@implementation WSDevice {
  WSStream *_source;
  WSStream *_sink;
  dispatch_queue_t _queue;  // the card timer and the sink's consume loop
  dispatch_source_t _timer;
  CMVideoFormatDescriptionRef _cardFormat;

  os_unfair_lock _lock;  // guards the rest
  CMIOExtensionClient *_sinkClient;
  uint64_t _sinkGeneration;  // bumped on every sink start/stop; ends older consume loops
  int _sourceStarts;
  uint64_t _lastAppFrameNs;
  BOOL _loggedBadFrame;
  BOOL _loggedConsumeError;
}

- (instancetype)init {
  if (!(self = [super init])) return nil;
  _lock = OS_UNFAIR_LOCK_INIT;
  _queue = dispatch_queue_create("dev.walkscape.app.camera", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
  _device = [CMIOExtensionDevice deviceWithLocalizedName:kVCDeviceName
                                                deviceID:[[NSUUID alloc] initWithUUIDString:kVCDeviceUID]
                                          legacyDeviceID:nil
                                                  source:self];
  CMVideoFormatDescriptionRef fd = CreateFormat();
  CMTime frame = CMTimeMake(1, kVCFrameRate);
  CMIOExtensionStreamFormat *format = [CMIOExtensionStreamFormat streamFormatWithFormatDescription:fd maxFrameDuration:frame minFrameDuration:frame validFrameDurations:nil];
  CFRelease(fd);
  _source = [[WSStream alloc] initWithName:kVCDeviceName uid:kVCSourceStreamUID sink:NO format:format device:self];
  _sink = [[WSStream alloc] initWithName:@"WalkScape app input" uid:kVCSinkStreamUID sink:YES format:format device:self];
  NSError *err = nil;
  if (![_device addStream:_source.stream error:&err] || ![_device addStream:_sink.stream error:&err]) {
    os_log_error(Log(), "cannot add a stream: %{public}@", err);
  }
  _card = CreateCardBuffer();
  if (_card) CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, _card, &_cardFormat);
  return self;
}

- (void)dealloc {
  if (_card) CVPixelBufferRelease(_card);
  if (_cardFormat) CFRelease(_cardFormat);
}

- (NSSet<CMIOExtensionProperty> *)availableProperties {
  return [NSSet setWithObjects:CMIOExtensionPropertyDeviceTransportType, CMIOExtensionPropertyDeviceModel, nil];
}

- (CMIOExtensionDeviceProperties *)devicePropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError **)outError {
  CMIOExtensionDeviceProperties *p = [CMIOExtensionDeviceProperties devicePropertiesWithDictionary:@{}];
  if ([properties containsObject:CMIOExtensionPropertyDeviceTransportType]) p.transportType = @(kIOAudioDeviceTransportTypeVirtual);
  if ([properties containsObject:CMIOExtensionPropertyDeviceModel]) p.model = kVCDeviceName;
  return p;
}

- (BOOL)setDeviceProperties:(CMIOExtensionDeviceProperties *)deviceProperties error:(NSError **)outError {
  return YES;
}

#pragma mark Source: video apps

- (void)startSource {
  os_unfair_lock_lock(&_lock);
  BOOL first = _sourceStarts++ == 0;
  os_unfair_lock_unlock(&_lock);
  if (first) dispatch_async(_queue, ^{
      [self startTimer];
    });
}

- (void)stopSource {
  os_unfair_lock_lock(&_lock);
  if (_sourceStarts > 0) _sourceStarts--;
  BOOL last = _sourceStarts == 0;
  os_unfair_lock_unlock(&_lock);
  if (last) dispatch_async(_queue, ^{
      [self stopTimer];
    });
}

// _queue. Ticks at the frame rate while the source streams; sends the card when the app doesn't.
- (void)startTimer {
  if (_timer) return;
  _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / kVCFrameRate, NSEC_PER_MSEC);
  __weak WSDevice *weakSelf = self;
  dispatch_source_set_event_handler(_timer, ^{
    [weakSelf sendCardIfIdle];
  });
  dispatch_resume(_timer);
}

- (void)stopTimer {
  if (!_timer) return;
  dispatch_source_cancel(_timer);
  _timer = nil;
}

- (void)sendCardIfIdle {
  uint64_t now = HostTimeNs();
  os_unfair_lock_lock(&_lock);
  uint64_t last = _lastAppFrameNs;  // may be a little after `now`: set on another thread
  os_unfair_lock_unlock(&_lock);
  BOOL idle = now > last && now - last > kAppFrameTimeoutNs;
  if (!idle || !_card || !_cardFormat) return;
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, kVCFrameRate), .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()), .decodeTimeStamp = kCMTimeInvalid};
  CMSampleBufferRef sample = NULL;
  if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, _card, _cardFormat, &timing, &sample) != noErr) return;
  [_source.stream sendSampleBuffer:sample discontinuity:CMIOExtensionStreamDiscontinuityFlagNone hostTimeInNanoseconds:now];
  CFRelease(sample);
}

#pragma mark Sink: the WalkScape app

// Refuses a client that CoreMediaIO identifies as another app: only WalkScape should put its
// picture into people's calls. On macOS 27.2 CoreMediaIO reports the signing ID of WalkScape
// itself as "unknown", so a client it can't identify is let through (it still needs the camera
// permission to open the device at all).
- (BOOL)authorizeSinkClient:(CMIOExtensionClient *)client {
  NSString *signingID = client.signingID;
  BOOL identified = signingID.length > 0 && ![signingID isEqualToString:@"unknown"];
  if (identified && ![signingID isEqualToString:kVCAppSigningID]) {
    os_log_error(Log(), "sink: refused %{public}@ (pid %d); only %{public}@ may send frames", signingID, client.pid, kVCAppSigningID);
    return NO;
  }
  if (!identified) os_log(Log(), "sink: accepting pid %d (CoreMediaIO gives no signing ID)", client.pid);
  os_unfair_lock_lock(&_lock);
  _sinkClient = client;
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (void)startSink {
  os_unfair_lock_lock(&_lock);
  CMIOExtensionClient *client = _sinkClient;
  uint64_t generation = ++_sinkGeneration;
  _loggedConsumeError = NO;
  os_unfair_lock_unlock(&_lock);
  if (!client) return;
  os_log(Log(), "sink started by pid %d", client.pid);
  dispatch_async(_queue, ^{
    [self consumeFrom:client generation:generation];
  });
}

- (void)stopSink {
  os_unfair_lock_lock(&_lock);
  _sinkGeneration++;
  _sinkClient = nil;
  _lastAppFrameNs = 0;  // show the card at once
  os_unfair_lock_unlock(&_lock);
  os_log(Log(), "sink stopped");
}

- (void)clientDisconnected:(CMIOExtensionClient *)client {
  os_unfair_lock_lock(&_lock);
  if (_sinkClient && [_sinkClient.clientID isEqual:client.clientID]) {
    _sinkGeneration++;
    _sinkClient = nil;
    _lastAppFrameNs = 0;
  }
  os_unfair_lock_unlock(&_lock);
}

- (BOOL)isCurrentSinkGeneration:(uint64_t)generation {
  os_unfair_lock_lock(&_lock);
  BOOL current = generation == _sinkGeneration;
  os_unfair_lock_unlock(&_lock);
  return current;
}

// Takes the app's frames one at a time, for as long as this sink session lasts. After "nothing
// queued" it asks again a little later rather than spinning.
- (void)consumeFrom:(CMIOExtensionClient *)client generation:(uint64_t)generation {
  __weak WSDevice *weakSelf = self;
  [_sink.stream consumeSampleBufferFromClient:client
                            completionHandler:^(CMSampleBufferRef sample, uint64_t sequence, CMIOExtensionStreamDiscontinuityFlags discontinuity, BOOL more,
                                                NSError *error) {
                              WSDevice *me = weakSelf;
                              if (!me || ![me isCurrentSinkGeneration:generation]) return;
                              if (sample) [me forwardAppFrame:sample sequence:sequence];
                              else if (error) [me logConsumeError:error];
                              dispatch_time_t when = sample ? DISPATCH_TIME_NOW : dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_MSEC);
                              dispatch_after(when, me->_queue, ^{
                                if ([me isCurrentSinkGeneration:generation]) [me consumeFrom:client generation:generation];
                              });
                            }];
}

- (void)logConsumeError:(NSError *)error {
  os_unfair_lock_lock(&_lock);
  BOOL log = !_loggedConsumeError;
  _loggedConsumeError = YES;
  os_unfair_lock_unlock(&_lock);
  if (log) os_log_error(Log(), "sink: %{public}@", error);
}

- (void)forwardAppFrame:(CMSampleBufferRef)sample sequence:(uint64_t)sequence {
  uint64_t now = HostTimeNs();
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
  BOOL valid = pb && CVPixelBufferGetWidth(pb) == kVCWidth && CVPixelBufferGetHeight(pb) == kVCHeight &&
               CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  os_unfair_lock_lock(&_lock);
  if (valid) _lastAppFrameNs = now;
  BOOL streaming = _sourceStarts > 0;
  BOOL logInvalid = !valid && !_loggedBadFrame;
  if (!valid) _loggedBadFrame = YES;
  os_unfair_lock_unlock(&_lock);
  if (logInvalid) os_log_error(Log(), "sink: dropping frames that aren't %dx%d 420v", kVCWidth, kVCHeight);
  if (valid && streaming) {
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    uint64_t ns = CMTIME_IS_NUMERIC(pts) ? (uint64_t)CMTimeConvertScale(pts, NSEC_PER_SEC, kCMTimeRoundingMethod_Default).value : now;
    [_source.stream sendSampleBuffer:sample discontinuity:CMIOExtensionStreamDiscontinuityFlagNone hostTimeInNanoseconds:ns];
  }
  [_sink.stream notifyScheduledOutputChanged:[CMIOExtensionScheduledOutput scheduledOutputWithSequenceNumber:sequence hostTimeInNanoseconds:now]];
}

@end

#pragma mark Provider

@interface WSProvider : NSObject <CMIOExtensionProviderSource>
@property(nonatomic, readonly) CMIOExtensionProvider *provider;
@property(nonatomic, readonly) WSDevice *device;
@end

@implementation WSProvider

- (instancetype)init {
  if (!(self = [super init])) return nil;
  _provider = [CMIOExtensionProvider providerWithSource:self clientQueue:nil];
  _device = [WSDevice new];
  NSError *err = nil;
  if (![_provider addDevice:_device.device error:&err]) os_log_error(Log(), "cannot add the device: %{public}@", err);
  return self;
}

- (BOOL)connectClient:(CMIOExtensionClient *)client error:(NSError **)outError {
  return YES;
}

- (void)disconnectClient:(CMIOExtensionClient *)client {
  [_device clientDisconnected:client];
}

- (NSSet<CMIOExtensionProperty> *)availableProperties {
  return [NSSet setWithObjects:CMIOExtensionPropertyProviderManufacturer, CMIOExtensionPropertyProviderName, nil];
}

- (CMIOExtensionProviderProperties *)providerPropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError **)outError {
  CMIOExtensionProviderProperties *p = [CMIOExtensionProviderProperties providerPropertiesWithDictionary:@{}];
  if ([properties containsObject:CMIOExtensionPropertyProviderManufacturer]) p.manufacturer = kVCManufacturer;
  if ([properties containsObject:CMIOExtensionPropertyProviderName]) p.name = kVCDeviceName;
  return p;
}

- (BOOL)setProviderProperties:(CMIOExtensionProviderProperties *)providerProperties error:(NSError **)outError {
  return YES;
}

@end

#pragma mark Main

// Builds everything without registering with the system, and writes the card.
static int SelfTest(NSString *dir) {
  WSProvider *p = [WSProvider new];
  CMIOExtensionDevice *device = p.provider.devices.firstObject;
  printf("devices %lu: \"%s\" %s\n", (unsigned long)p.provider.devices.count, device.localizedName.UTF8String, device.deviceID.UUIDString.UTF8String);
  for (CMIOExtensionStream *s in device.streams) {
    CMIOExtensionStreamFormat *f = s.source.formats.firstObject;
    CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
    printf("  stream \"%s\" %s, %dx%d, %.0f fps\n", s.localizedName.UTF8String, s.direction == CMIOExtensionStreamDirectionSink ? "sink" : "source",
           d.width, d.height, 1 / CMTimeGetSeconds(f.minFrameDuration));
  }
  if (!p.device.card) {
    printf("no card\n");
    return 1;
  }
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"card.png"]];
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  BOOL ok = [[CIContext contextWithOptions:nil] writePNGRepresentationOfImage:[CIImage imageWithCVPixelBuffer:p.device.card]
                                                                         toURL:url
                                                                        format:kCIFormatRGBA8
                                                                    colorSpace:cs
                                                                       options:@{}
                                                                         error:nil];
  CGColorSpaceRelease(cs);
  printf("%s %s\n", ok ? "wrote" : "cannot write", url.path.UTF8String);
  return ok && device.streams.count == 2 ? 0 : 1;
}

static WSProvider *gProvider;  // CMIO holds its source weakly

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc == 3 && strcmp(argv[1], "--selftest") == 0) return SelfTest(@(argv[2]));
    gProvider = [WSProvider new];
    [CMIOExtensionProvider startServiceWithProvider:gProvider.provider];
  }
  CFRunLoopRun();
  return 0;
}
