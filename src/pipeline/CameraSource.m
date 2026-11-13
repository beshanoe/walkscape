#import "CameraSource.h"

#import "VirtualCamera.h"

@interface CameraSource () <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation CameraSource {
  AVCaptureSession *_session;
  AVCaptureVideoDataOutput *_output;
  dispatch_queue_t _sessionQueue;
  dispatch_queue_t _frameQueue;
  CameraFrameHandler _handler;
}

+ (NSArray<AVCaptureDevice *> *)availableDevices {
  NSArray *types = @[ AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeExternal, AVCaptureDeviceTypeContinuityCamera ];
  NSArray<AVCaptureDevice *> *devices = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                                                               mediaType:AVMediaTypeVideo
                                                                                                position:AVCaptureDevicePositionUnspecified]
                                             .devices;
  // Not our own virtual camera: it shows this app's output.
  return [devices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(AVCaptureDevice *d, NSDictionary *bindings) {
                    return [d.uniqueID caseInsensitiveCompare:VirtualCameraDeviceID] != NSOrderedSame &&
                           ![d.localizedName isEqualToString:VirtualCameraName];
                  }]];
}

- (instancetype)initWithHandler:(CameraFrameHandler)handler {
  if (!(self = [super init])) return nil;
  _handler = [handler copy];
  _sessionQueue = dispatch_queue_create("camera.session", DISPATCH_QUEUE_SERIAL);
  _frameQueue = dispatch_queue_create("camera.frames", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
  return self;
}

- (void)startWithDevice:(AVCaptureDevice *)device completion:(void (^)(NSError *))completion {
  dispatch_async(_sessionQueue, ^{
    NSError *error = nil;
    [self->_session stopRunning];
    AVCaptureSession *session = [AVCaptureSession new];
    [session beginConfiguration];
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input && [session canAddInput:input]) {
      [session addInput:input];
      for (AVCaptureSessionPreset preset in @[ AVCaptureSessionPreset1920x1080, AVCaptureSessionPreset1280x720, AVCaptureSessionPresetHigh ]) {
        if ([session canSetSessionPreset:preset]) {
          session.sessionPreset = preset;
          break;
        }
      }
      AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
      output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
      output.alwaysDiscardsLateVideoFrames = YES;
      [output setSampleBufferDelegate:self queue:self->_frameQueue];
      if ([session canAddOutput:output]) [session addOutput:output];
      self->_output = output;
    } else if (!error) {
      error = [NSError errorWithDomain:@"CameraSource" code:1 userInfo:@{NSLocalizedDescriptionKey : @"Cannot use this camera"}];
    }
    [session commitConfiguration];
    if (!error) {
      [session startRunning];
      [CameraSource setThirtyFPS:device];
      self->_session = session;
      self->_device = device;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(error);
    });
  });
}

// 30 fps where the active format offers it, once the session runs: starting it applies the
// preset, which resets the frame rate to the format's default. USB cameras give frame intervals
// in 100 ns units, so "30" may be 30.00003: an OBSBOT Meet 2 lists 30.00003–30.00003 and ran at
// its default 25 fps while this asked for exactly 30 (or before the session started); the
// range's own duration is used then. Setting an unsupported frame duration throws.
+ (void)setThirtyFPS:(AVCaptureDevice *)device {
  AVFrameRateRange *range = nil;
  for (AVFrameRateRange *r in device.activeFormat.videoSupportedFrameRateRanges) {
    if (r.minFrameRate <= 30.05 && r.maxFrameRate >= 29.95) range = r;
  }
  if (!range || ![device lockForConfiguration:nil]) return;
  CMTime duration = range.minFrameRate <= 30 && range.maxFrameRate >= 30 ? CMTimeMake(1, 30) : range.minFrameDuration;
  device.activeVideoMinFrameDuration = duration;
  device.activeVideoMaxFrameDuration = duration;
  [device unlockForConfiguration];
}

- (void)stop {
  dispatch_async(_sessionQueue, ^{
    [self->_session stopRunning];
  });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
  _handler(sampleBuffer);
}

@end
