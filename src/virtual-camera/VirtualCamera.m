#import "VirtualCamera.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <QuartzCore/QuartzCore.h>
#import <SystemExtensions/SystemExtensions.h>
#import <os/lock.h>
#import <os/log.h>

#import "FrameUtil.h"
#import "VirtualCameraShared.h"

NSString *const VirtualCameraName = kVCDeviceName;
NSString *const VirtualCameraDeviceID = kVCDeviceUID;

static os_log_t Log(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    log = os_log_create("dev.walkscape.app", "virtual-camera");
  });
  return log;
}

#pragma mark Installer

@interface VirtualCameraInstaller () <OSSystemExtensionRequestDelegate>
@end

@implementation VirtualCameraInstaller {
  OSSystemExtensionRequest *_activation;
  OSSystemExtensionRequest *_deactivation;
}

- (void)setState:(VirtualCameraInstallState)state message:(NSString *)message {
  _state = state;
  _message = [message copy];
  if (self.changeHandler) self.changeHandler();
}

- (void)submit:(OSSystemExtensionRequest *)request {
  request.delegate = self;
  [OSSystemExtensionManager.sharedManager submitRequest:request];
}

- (void)refresh {
  [self submit:[OSSystemExtensionRequest propertiesRequestForExtension:kVCExtensionID queue:dispatch_get_main_queue()]];
}

- (void)install {
  _activation = [OSSystemExtensionRequest activationRequestForExtension:kVCExtensionID queue:dispatch_get_main_queue()];
  [self submit:_activation];
}

- (void)uninstall {
  _deactivation = [OSSystemExtensionRequest deactivationRequestForExtension:kVCExtensionID queue:dispatch_get_main_queue()];
  [self submit:_deactivation];
}

- (void)request:(OSSystemExtensionRequest *)request foundProperties:(NSArray<OSSystemExtensionProperties *> *)properties {
  BOOL enabled = NO, waiting = NO;
  for (OSSystemExtensionProperties *p in properties) {
    if (p.isUninstalling) continue;
    enabled |= p.isEnabled;
    waiting |= p.isAwaitingUserApproval;
  }
  if (!enabled && !waiting) {
    [self setState:VirtualCameraInstallStateNotInstalled message:nil];
    return;
  }
  [self setState:enabled ? VirtualCameraInstallStateInstalled : VirtualCameraInstallStateNeedsApproval message:nil];
  [self install];  // swaps in this app's copy if it's a different version; nothing to approve otherwise
}

- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request
                  actionForReplacingExtension:(OSSystemExtensionProperties *)existing
                                withExtension:(OSSystemExtensionProperties *)extension {
  os_log(Log(), "replacing camera extension %{public}@ with %{public}@", existing.bundleVersion, extension.bundleVersion);
  return OSSystemExtensionReplacementActionReplace;
}

- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
  [self setState:VirtualCameraInstallStateNeedsApproval message:nil];
}

- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
  if (request != _activation && request != _deactivation) return;  // a properties request: see foundProperties
  if (result == OSSystemExtensionRequestWillCompleteAfterReboot) [self setState:VirtualCameraInstallStateRestartNeeded message:nil];
  else [self setState:request == _deactivation ? VirtualCameraInstallStateNotInstalled : VirtualCameraInstallStateInstalled message:nil];
}

- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
  os_log_error(Log(), "system extension request failed: %{public}@", error);
  NSInteger code = [error.domain isEqualToString:OSSystemExtensionErrorDomain] ? error.code : 0;
  NSString *message = nil;
  switch (code) {
    case OSSystemExtensionErrorRequestCanceled:
    case OSSystemExtensionErrorRequestSuperseded:
      return;
    case OSSystemExtensionErrorUnsupportedParentBundleLocation:
      message = @"To install the virtual camera, move WalkScape to the Applications folder and open it from there.";
      break;
    case OSSystemExtensionErrorMissingEntitlement:
    case OSSystemExtensionErrorCodeSignatureInvalid:
      message = @"This copy of WalkScape can't install the virtual camera: it has to be signed with your Apple Developer "
                @"certificate and a provisioning profile that allows system extensions.";
      break;
    case OSSystemExtensionErrorExtensionNotFound:
      message = @"The camera extension is missing from this copy of WalkScape.";
      break;
    case OSSystemExtensionErrorForbiddenBySystemPolicy:
      message = @"This Mac's settings (a configuration profile) don't allow camera extensions.";
      break;
    default:
      message = [NSString stringWithFormat:@"macOS refused the virtual camera: %@", error.localizedDescription];
  }
  if (request == _deactivation) [self setState:_state message:message];
  else [self setState:VirtualCameraInstallStateUnavailable message:message];
}

@end

#pragma mark CoreMediaIO helpers

static NSArray<NSNumber *> *ObjectIDs(CMIOObjectID object, CMIOObjectPropertySelector selector) {
  CMIOObjectPropertyAddress addr = {selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
  UInt32 size = 0, used = 0;
  if (CMIOObjectGetPropertyDataSize(object, &addr, 0, NULL, &size) != noErr || size == 0) return @[];
  NSMutableData *data = [NSMutableData dataWithLength:size];
  if (CMIOObjectGetPropertyData(object, &addr, 0, NULL, size, &used, data.mutableBytes) != noErr) return @[];
  NSMutableArray *ids = [NSMutableArray array];
  const CMIOObjectID *p = data.bytes;
  for (UInt32 i = 0; i < used / sizeof(CMIOObjectID); i++) [ids addObject:@(p[i])];
  return ids;
}

static NSString *StringProperty(CMIOObjectID object, CMIOObjectPropertySelector selector) {
  CMIOObjectPropertyAddress addr = {selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
  CFStringRef value = NULL;
  UInt32 used = 0;
  if (CMIOObjectGetPropertyData(object, &addr, 0, NULL, sizeof(value), &used, &value) != noErr) return nil;
  return CFBridgingRelease(value);
}

static UInt32 UInt32Property(CMIOObjectID object, CMIOObjectPropertySelector selector, UInt32 fallback) {
  CMIOObjectPropertyAddress addr = {selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
  UInt32 value = fallback, used = 0;
  if (CMIOObjectGetPropertyData(object, &addr, 0, NULL, sizeof(value), &used, &value) != noErr) return fallback;
  return value;
}

// The WalkScape Camera device by UID (or by name, should the UID ever be reported differently).
static CMIODeviceID FindDevice(void) {
  CMIODeviceID byName = kCMIODeviceUnknown;
  for (NSNumber *n in ObjectIDs(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices)) {
    CMIODeviceID device = n.unsignedIntValue;
    NSString *uid = StringProperty(device, kCMIODevicePropertyDeviceUID);
    if (uid && [uid caseInsensitiveCompare:kVCDeviceUID] == NSOrderedSame) return device;
    if ([StringProperty(device, kCMIOObjectPropertyName) isEqualToString:kVCDeviceName]) byName = device;
  }
  return byName;
}

// The extension's sink is a CMIO output stream: direction 0 (1 is input).
static CMIOStreamID FindSinkStream(CMIODeviceID device) {
  for (NSNumber *n in ObjectIDs(device, kCMIODevicePropertyStreams)) {
    if (UInt32Property(n.unsignedIntValue, kCMIOStreamPropertyDirection, 1) == 0) return n.unsignedIntValue;
  }
  return kCMIOObjectUnknown;
}

static void SinkQueueAltered(CMIOStreamID stream, void *token, void *refCon) {}

#pragma mark Output

@interface VirtualCameraOutput ()
@property(atomic, readwrite) BOOL connected;
@property(atomic, copy, nullable) NSString *problem;
@end

@implementation VirtualCameraOutput {
  dispatch_queue_t _queue;  // finding the device, starting and stopping its sink
  BOOL _listening;
  BOOL _retryScheduled;
  CMIODeviceID _device;
  CMIOStreamID _sink;
  id<NSObject> _activity;

  os_unfair_lock _lock;
  CMSimpleQueueRef _sinkQueue;  // under _lock; the camera queue fills it

  // Camera queue only.
  CVPixelBufferPoolRef _pool;
  CMVideoFormatDescriptionRef _format;
  CFTimeInterval _fullSince;
}

- (instancetype)init {
  if (!(self = [super init])) return nil;
  _queue = dispatch_queue_create("vcam.control", DISPATCH_QUEUE_SERIAL);
  _lock = OS_UNFAIR_LOCK_INIT;
  _crop = CGRectMake(0, 0, 1, 1);
  return self;
}

- (void)dealloc {
  if (_sinkQueue) CFRelease(_sinkQueue);
  if (_pool) CVPixelBufferPoolRelease(_pool);
  if (_format) CFRelease(_format);
}

#pragma mark Connection (_queue)

- (void)start {
  dispatch_async(_queue, ^{
    if (!self->_listening) {
      self->_listening = YES;
      CMIOObjectPropertyAddress addr = {kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
      __weak VirtualCameraOutput *weakSelf = self;
      CMIOObjectAddPropertyListenerBlock(kCMIOObjectSystemObject, &addr, self->_queue, ^(UInt32 count, const CMIOObjectPropertyAddress *addresses) {
        [weakSelf connect];
      });
    }
    [self connect];
  });
}

- (BOOL)hasSinkQueue {
  os_unfair_lock_lock(&_lock);
  BOOL has = _sinkQueue != NULL;
  os_unfair_lock_unlock(&_lock);
  return has;
}

- (void)connect {
  CMIODeviceID device = FindDevice();
  if (device != kCMIODeviceUnknown && device == _device && [self hasSinkQueue]) return;
  [self disconnect];
  if (device == kCMIODeviceUnknown) {
    [self reportProblem:nil];
    // Look again in a moment: the devices listener stayed silent when macOS started an updated
    // extension (macOS 27.2), so it can't be the only way to notice the camera coming back.
    [self retryLater];
    return;
  }
  CMIOStreamID sink = FindSinkStream(device);
  CMSimpleQueueRef queue = NULL;
  OSStatus st = sink == kCMIOObjectUnknown ? kCMIOHardwareBadStreamError : CMIOStreamCopyBufferQueue(sink, SinkQueueAltered, NULL, &queue);
  if (st == noErr) st = CMIODeviceStartStream(device, sink);
  if (st != noErr) {
    if (queue) CFRelease(queue);
    os_log_error(Log(), "cannot start the virtual camera's sink: %d", (int)st);
    [self reportProblem:[NSString stringWithFormat:@"%@ doesn't take WalkScape's frames (error %d); trying again.", kVCDeviceName, (int)st]];
    [self retryLater];
    return;
  }
  _device = device;
  _sink = sink;
  os_unfair_lock_lock(&_lock);
  _sinkQueue = queue;
  os_unfair_lock_unlock(&_lock);
  // Calls need the frames when the window is hidden behind the call app too: no App Nap.
  _activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
                                                           reason:@"Sending video to WalkScape Camera"];
  os_log(Log(), "sending frames to the virtual camera");
  [self reportProblem:nil];
}

- (void)disconnect {
  os_unfair_lock_lock(&_lock);
  CMSimpleQueueRef queue = _sinkQueue;
  _sinkQueue = NULL;
  os_unfair_lock_unlock(&_lock);
  if (queue) {
    CMIODeviceStopStream(_device, _sink);
    CFRelease(queue);
  }
  _device = kCMIODeviceUnknown;
  _sink = kCMIOObjectUnknown;
  if (_activity) [NSProcessInfo.processInfo endActivity:_activity];
  _activity = nil;
}

- (void)retryLater {
  if (_retryScheduled) return;
  _retryScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), _queue, ^{
    self->_retryScheduled = NO;
    [self connect];
  });
}

- (void)reportProblem:(NSString *)problem {
  BOOL connected = [self hasSinkQueue];
  NSString *old = self.problem;
  if (connected == self.connected && (problem == old || [problem isEqualToString:old])) return;
  self.connected = connected;
  self.problem = problem;
  void (^handler)(BOOL, NSString *) = self.stateHandler;
  if (handler) dispatch_async(dispatch_get_main_queue(), ^{
      handler(connected, problem);
    });
}

#pragma mark Frames (camera queue)

- (void)sendFrame:(CVPixelBufferRef)frame {
  os_unfair_lock_lock(&_lock);
  CMSimpleQueueRef queue = _sinkQueue ? (CMSimpleQueueRef)CFRetain(_sinkQueue) : NULL;
  os_unfair_lock_unlock(&_lock);
  if (!queue) return;
  if (CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue)) {
    [self queueIsFull];  // the extension is behind: drop this frame
    CFRelease(queue);
    return;
  }
  _fullSince = 0;
  CVPixelBufferRef out = [self copyScaledFrame:frame];
  CMSampleBufferRef sample = out ? [self copySampleWithBuffer:out] : NULL;
  // On success the queue owns the sample; the extension releases it when it takes it.
  if (sample && CMSimpleQueueEnqueue(queue, sample) != noErr) CFRelease(sample);
  if (out) CVPixelBufferRelease(out);
  CFRelease(queue);
}

// The extension takes frames whether or not anyone watches, so a queue that stays full means the
// connection is dead (e.g. the extension was replaced): connect again.
- (void)queueIsFull {
  CFTimeInterval now = CACurrentMediaTime();
  if (_fullSince == 0) _fullSince = now;
  if (now - _fullSince < 2) return;
  _fullSince = 0;
  os_log_error(Log(), "the virtual camera stopped taking frames; reconnecting");
  dispatch_async(_queue, ^{
    [self disconnect];
    [self connect];
  });
}

- (CVPixelBufferRef)copyScaledFrame:(CVPixelBufferRef)frame CF_RETURNS_RETAINED {
  if (!_pool) _pool = BackdropCreatePool(kVCWidth, kVCHeight, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
  CVPixelBufferRef out = NULL;
  if (!_pool || CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &out) != kCVReturnSuccess) return NULL;
  CGSize size = CGSizeMake(CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame));
  if (!FUCropScale(frame, FUFillRect(size, self.crop, (CGFloat)kVCWidth / kVCHeight), out)) {
    CVPixelBufferRelease(out);
    return NULL;
  }
  return out;
}

- (CMSampleBufferRef)copySampleWithBuffer:(CVPixelBufferRef)buffer CF_RETURNS_RETAINED {
  if (!_format || !CMVideoFormatDescriptionMatchesImageBuffer(_format, buffer)) {
    if (_format) CFRelease(_format);
    _format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &_format) != noErr) return NULL;
  }
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, kVCFrameRate), .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()), .decodeTimeStamp = kCMTimeInvalid};
  CMSampleBufferRef sample = NULL;
  CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, _format, &timing, &sample);
  return sample;
}

@end
