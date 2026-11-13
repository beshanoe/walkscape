#import "Pipeline.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>

#import "BackdropEngine.h"
#import "CameraSource.h"
#import "FrameLog.h"
#import "FrameUtil.h"
#import "VisionBackdropEngine.h"

@interface Pipeline ()
@property(atomic, readwrite, nullable) LoopingVideoPlayer *player;
@end

@implementation Pipeline {
  BackdropEngine *_engine;  // Apple's; nil when Portrait.framework is missing
  id<MTLDevice> _device;
  CameraSource *_camera;
  _Atomic(BOOL) _useScene;
  _Atomic(NSInteger) _cutout;
  _Atomic(int) _appleFailures;  // Apple's engine's failures in a row; ≥ kAppleGiveUp: Vision until re-chosen

  // Camera queue only.
  CMVideoFormatDescriptionRef _formatDesc;
  FrameLog *_frameLog;  // -frameTimingLog: diagnostics, normally nil
  NSString *_lastRenderError;
  // Camera clip recording (-recordCameraFor:…), guarded by @synchronized(self).
  AVAssetWriter *_recorder;
  AVAssetWriterInput *_recorderInput;
  CMTime _recordStart;
  double _recordSeconds;
  void (^_recordCompletion)(NSError *);
  VisionBackdropEngine *_vision;  // made on first use
  NSString *_visionError;
  NSString *_appleProblem;
  NSString *_engineInUse;
  CFTimeInterval _statsStart;
  int _statsFrames;
  double _statsMs;
  double _statsSceneMs;
  int _noiseFrames;
  double _noise;
}

- (instancetype)init {
  if (!(self = [super init])) return nil;
  _displayLayer = [AVSampleBufferDisplayLayer layer];
  _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;

  NSError *err = nil;
  _engine = [[BackdropEngine alloc] initWithError:&err];
  _engineError = [err.localizedDescription copy];

  _device = MTLCreateSystemDefaultDevice();
  NSError *sceneErr = nil;
  _scenes = [[SceneRenderer alloc] initWithDevice:_device error:&sceneErr];
  if (!_scenes) NSLog(@"scene renderer: %@", sceneErr);
  _useScene = _scenes != nil;
  _virtualCamera = [VirtualCameraOutput new];
  _frameLog = [FrameLog fromDefaults];
  return self;
}

- (void)dealloc {
  if (_formatDesc) CFRelease(_formatDesc);
}

#pragma mark Settings (main queue)

- (CutoutEngine)cutout {
  return (CutoutEngine)atomic_load(&_cutout);
}

- (void)setCutout:(CutoutEngine)cutout {
  atomic_store(&_cutout, (NSInteger)cutout);
  atomic_store(&_appleFailures, 0);  // choosing Apple's again retries it
}

- (BOOL)useScene {
  return atomic_load(&_useScene);
}

- (void)setUseScene:(BOOL)useScene {
  atomic_store(&_useScene, useScene && _scenes != nil);
  // Don't decode video nobody sees.
  if (self.useScene) [self.player pause];
  else [self.player play];
}

- (AVCaptureDevice *)cameraDevice {
  return _camera.device;
}

- (void)setBackgroundVideo:(NSURL *)url activate:(BOOL)activate {
  [self.player pause];
  self.player = url ? [[LoopingVideoPlayer alloc] initWithURL:url] : nil;
  self.useScene = activate ? NO : self.useScene;
}

- (void)startCamera:(AVCaptureDevice *)device completion:(void (^)(NSError *))completion {
  if (!_camera) {
    __weak Pipeline *weakSelf = self;
    _camera = [[CameraSource alloc] initWithHandler:^(CMSampleBufferRef sb) {
      [weakSelf handleCameraFrame:sb];
    }];
  }
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL granted) {
                             dispatch_async(dispatch_get_main_queue(), ^{
                               if (!granted) {
                                 NSString *msg = @"Camera access denied. Allow WalkScape in System Settings → Privacy & Security → Camera.";
                                 completion([NSError errorWithDomain:@"WalkScape" code:1 userInfo:@{NSLocalizedDescriptionKey : msg}]);
                                 return;
                               }
                               [self->_virtualCamera start];  // CoreMediaIO wants camera access too
                               [self->_camera startWithDevice:device completion:completion];
                             });
                           }];
}

#pragma mark Frames (camera queue)

// The current background (3D scene, video, or stripes while it has no frame) at about the
// camera's size; NULL when there is none (the video background with no video chosen).
- (CVPixelBufferRef)copyBackgroundForCamera:(CVPixelBufferRef)cam time:(double)t CF_RETURNS_RETAINED {
  CVPixelBufferRef bg = NULL;
  SceneRenderer *scenes = self.useScene ? _scenes : nil;
  if (scenes) {
    // The engine scales the background to the camera size; 1280 wide is plenty once blurred.
    size_t cw = CVPixelBufferGetWidth(cam), ch = CVPixelBufferGetHeight(cam);
    size_t bw = MIN(cw, (size_t)1280);
    bg = [scenes copyFrameAtTime:t width:bw height:(bw * ch / cw) & ~(size_t)1];
    _statsSceneMs += scenes.lastGpuMs;
  } else {
    LoopingVideoPlayer *player = self.player;
    if (!player) return NULL;
    bg = [player copyCurrentFrame];
  }
  return bg ?: FUSyntheticBackground(1280, 720, t);
}

- (void)recordCameraFor:(double)seconds toURL:(NSURL *)url completion:(void (^)(NSError *))completion {
  NSError *err = nil;
  [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&err];
  @synchronized(self) {
    if (writer && !_recorder) {
      _recorder = writer;
      _recorderInput = nil;
      _recordSeconds = seconds;
      _recordCompletion = [completion copy];
      return;
    }
  }
  if (!err) err = [NSError errorWithDomain:@"WalkScape" code:2 userInfo:@{NSLocalizedDescriptionKey : @"Already recording"}];
  dispatch_async(dispatch_get_main_queue(), ^{
    completion(err);
  });
}

// Camera queue: the frame goes into the recording, if one is running.
- (void)recordFrame:(CMSampleBufferRef)sb {
  AVAssetWriter *finished = nil;
  AVAssetWriterInput *finishedInput = nil;
  void (^completion)(NSError *) = nil;
  @synchronized(self) {
    if (!_recorder) return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
    if (!_recorderInput) {
      CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
      NSDictionary *settings = @{
        AVVideoCodecKey : AVVideoCodecTypeAppleProRes422,
        AVVideoWidthKey : @(CVPixelBufferGetWidth(pb)),
        AVVideoHeightKey : @(CVPixelBufferGetHeight(pb)),
      };
      _recorderInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
      _recorderInput.expectsMediaDataInRealTime = YES;
      [_recorder addInput:_recorderInput];
      [_recorder startWriting];
      [_recorder startSessionAtSourceTime:pts];
      _recordStart = pts;
    }
    if (CMTimeGetSeconds(CMTimeSubtract(pts, _recordStart)) < _recordSeconds && _recorder.status == AVAssetWriterStatusWriting) {
      if (_recorderInput.readyForMoreMediaData) [_recorderInput appendSampleBuffer:sb];
      return;
    }
    finished = _recorder;
    finishedInput = _recorderInput;
    completion = _recordCompletion;
    _recorder = nil;
    _recorderInput = nil;
    _recordCompletion = nil;
  }
  [finishedInput markAsFinished];
  [finished finishWritingWithCompletionHandler:^{
    NSError *error = finished.status == AVAssetWriterStatusCompleted ? nil : (finished.error ?: [NSError errorWithDomain:@"WalkScape" code:3 userInfo:@{NSLocalizedDescriptionKey : @"Recording failed"}]);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion) completion(error);
    });
  }];
}

- (void)handleCameraFrame:(CMSampleBufferRef)sb {
  CVPixelBufferRef cam = CMSampleBufferGetImageBuffer(sb);
  if (!cam) return;
  CFTimeInterval arrived = CACurrentMediaTime();
  [self recordFrame:sb];
  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
  double t = CMTimeGetSeconds(pts);
  if (_scenes && _noiseFrames++ % 15 == 0) {  // the background follows the camera's noise and levels
    FUCameraStats stats;
    if (FUMeasureCamera(cam, &stats)) {
      _noise = _noise > 0 ? _noise * 0.7 + stats.noise * 0.3 : stats.noise;
      _scenes.cameraNoise = fmin(_noise, 0.03);
      [_scenes measuredCamera:stats];
    }
  }
  ViewMode mode = self.mode;
  CVPixelBufferRef out = NULL;
  double renderMs = 0;
  NSString *renderError = nil;
  float bgLuma = -1;
  if (mode == ViewModeBackground) {
    out = [self copyBackgroundForCamera:cam time:t];
  } else if (mode == ViewModeBoth) {
    CVPixelBufferRef bg = [self copyBackgroundForCamera:cam time:t];
    if (bg && _frameLog) bgLuma = [FrameLog meanLumaOf:bg];
    if (bg) {
      out = [self copyCutoutOfCamera:cam background:bg time:t renderMs:&renderMs message:&renderError];
      CVPixelBufferRelease(bg);
    }
  }
  [self reportRenderError:renderError];
  if (!out) out = CVPixelBufferRetain(cam);  // the raw camera: Camera shown, no background, or a failed effect
  NSString *engineTags = _frameLog ? [FrameLog tagsOf:out] : nil;
  // Colour tags on every frame made from the camera: the camera frame's own, BT.709 for any it
  // lacks. Some USB webcams tag nothing (an OBSBOT Meet 2, though its format says 709), and the
  // engines pass that on; the display side also writes an odd primaries tag on buffers it has
  // shown, which comes back with the pool's recycled buffers. So the preview got untagged frames
  // mixed with partly tagged ones and flickered every few seconds, while the virtual camera's
  // copy (FUCropScale tags it) didn't. A background shown alone keeps its own tags.
  FUCopyColorTags(mode == ViewModeBackground ? out : cam, out);
  CFTimeInterval ready = CACurrentMediaTime();
  [self enqueue:out pts:pts];
  NSString *shownTags = _frameLog ? [FrameLog tagsOf:out] : nil;
  [_virtualCamera sendFrame:out];
  if (_frameLog) {
    NSString *engine = out == cam ? @"raw" : mode == ViewModeBoth ? _engineInUse : @"bg";
    [_frameLog logFrameAt:pts arrived:arrived ready:ready engine:engine ?: @"?" engineTags:engineTags shownTags:shownTags camera:cam output:out backgroundLuma:bgLuma];
  }
  [self updateStatsWithCamera:cam renderMs:renderMs];
  CVPixelBufferRelease(out);
}

static const int kAppleGiveUp = 30;  // a second of frames

// You in front of the background: Apple's engine when it's chosen and works, else Vision. A frame
// Apple's fails on goes through Vision; after kAppleGiveUp failures in a row Apple's is left
// alone until it's chosen again.
- (CVPixelBufferRef)copyCutoutOfCamera:(CVPixelBufferRef)cam
                            background:(CVPixelBufferRef)bg
                                  time:(double)t
                              renderMs:(double *)renderMs
                               message:(NSString **)message CF_RETURNS_RETAINED {
  NSError *err = nil;
  BOOL appleFailed = NO;
  if (self.cutout == CutoutEngineVideoEffects && _engine && atomic_load(&_appleFailures) < kAppleGiveUp) {
    CVPixelBufferRef out = [_engine renderCamera:cam background:bg time:t outMatte:NULL error:&err];
    *renderMs = _engine.lastRenderMs;
    if (out) {
      atomic_store(&_appleFailures, 0);
      _engineInUse = @"Video Effects";
      return out;
    }
    _appleProblem = err.localizedDescription ?: @"failed";
    atomic_fetch_add(&_appleFailures, 1);
    appleFailed = YES;
  } else if (self.cutout == CutoutEngineVideoEffects && _engine) {
    appleFailed = YES;  // given up on it for now
  }
  if (!_vision && !_visionError) {
    _vision = [[VisionBackdropEngine alloc] initWithDevice:_device error:&err];
    if (!_vision) _visionError = err.localizedDescription ?: @"Vision cutout unavailable";
  }
  CVPixelBufferRef out = _vision ? [_vision renderCamera:cam background:bg time:t outMatte:NULL error:&err] : NULL;
  *renderMs += _vision.lastRenderMs;
  _engineInUse = @"Vision";
  if (!out) {
    *message = _vision ? (err.localizedDescription ?: @"The Vision cutout failed") : _visionError;
  } else if (appleFailed) {
    *message = [NSString stringWithFormat:@"Apple's Video Effects engine failed (%@); Vision does the cutout.", _appleProblem];
  }
  return out;
}

// Only report changes, not every failing frame.
- (void)reportRenderError:(NSString *)message {
  if (message == _lastRenderError || [message isEqualToString:_lastRenderError]) return;
  _lastRenderError = message;
  void (^handler)(NSString *) = self.renderErrorHandler;
  if (handler) dispatch_async(dispatch_get_main_queue(), ^{
      handler(message);
    });
}

- (void)updateStatsWithCamera:(CVPixelBufferRef)cam renderMs:(double)renderMs {
  CFTimeInterval now = CACurrentMediaTime();
  if (_statsStart == 0) _statsStart = now;
  _statsFrames++;
  _statsMs += renderMs;
  if (now - _statsStart < 1.0) return;
  NSString *s = [NSString stringWithFormat:@"Camera %zu×%zu, %.0f fps", CVPixelBufferGetWidth(cam), CVPixelBufferGetHeight(cam),
                                           _statsFrames / (now - _statsStart)];
  if (_statsMs > 0) s = [s stringByAppendingFormat:@"\nEffect %.1f ms per frame (%@)", _statsMs / MAX(_statsFrames, 1), _engineInUse];
  if (_statsSceneMs > 0) {
    s = [s stringByAppendingFormat:@"\nScene %.1f ms GPU, %.0f m walked", _statsSceneMs / MAX(_statsFrames, 1), _scenes.distanceMetres];
  }
  _statsStart = now;
  _statsFrames = 0;
  _statsMs = 0;
  _statsSceneMs = 0;
  void (^handler)(NSString *) = self.statsHandler;
  if (handler) dispatch_async(dispatch_get_main_queue(), ^{
      handler(s);
    });
}

- (void)enqueue:(CVPixelBufferRef)buffer pts:(CMTime)pts {
  if (!_formatDesc || !CMVideoFormatDescriptionMatchesImageBuffer(_formatDesc, buffer)) {
    if (_formatDesc) CFRelease(_formatDesc);
    _formatDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &_formatDesc);
  }
  if (!_formatDesc) return;
  CMSampleTimingInfo timing = {.duration = kCMTimeInvalid, .presentationTimeStamp = pts, .decodeTimeStamp = kCMTimeInvalid};
  CMSampleBufferRef sample = NULL;
  if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, _formatDesc, &timing, &sample) != noErr) return;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
  CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
  CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
  AVSampleBufferVideoRenderer *renderer = _displayLayer.sampleBufferRenderer;
  if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) [renderer flush];
  if (renderer.readyForMoreMediaData) [renderer enqueueSampleBuffer:sample];
  CFRelease(sample);
}

@end
