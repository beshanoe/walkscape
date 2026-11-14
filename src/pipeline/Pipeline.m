#import "Pipeline.h"

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>
#import <stdatomic.h>

#import "BackdropEngine.h"
#import "CameraSource.h"
#import "FrameLog.h"
#import "FrameUtil.h"
#import "VisionBackdropEngine.h"

@interface Pipeline ()
@property(atomic, readwrite, nullable) LoopingVideoPlayer *player;
@end

static const double kIntroFadeSeconds = 0.6;  // the camera's picture fading in over the intro

static void EnqueueFrame(AVSampleBufferDisplayLayer *layer, CMVideoFormatDescriptionRef *desc, CVPixelBufferRef buffer, CMTime pts);

@implementation Pipeline {
  BackdropEngine *_engine;  // Apple's; nil when Portrait.framework is missing
  id<MTLDevice> _device;
  CameraSource *_camera;
  dispatch_queue_t _frameQueue;  // the camera's frames and the intro's
  _Atomic(BOOL) _useScene;
  _Atomic(NSInteger) _cutout;
  _Atomic(int) _appleFailures;  // Apple's engine's failures in a row; ≥ kAppleGiveUp: Vision until re-chosen
  _Atomic(int) _engineWarmUps;  // Apple's engine loading ahead of the camera (warmUpEngineForSize:)
  _Atomic(BOOL) _wentLive;      // the camera's picture has shown (goLive)
  os_log_t _log;
  CFTimeInterval _launched;

  // Camera queue only.
  CMVideoFormatDescriptionRef _formatDesc;
  // The intro (startIntro): the background alone until the camera's picture fades in.
  dispatch_source_t _introTimer;  // its frames until the camera's first; then the camera's drive it
  CMVideoFormatDescriptionRef _introFormat;
  BOOL _introShown;               // the intro layer has a picture
  BOOL _cameraArrived;
  BOOL _live;                     // the camera's picture is shown (from goLive:)
  CFTimeInterval _introFadeEnd;   // while fading in: until then the intro keeps moving under it
  PreviewStage _stage;
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
  _launched = CACurrentMediaTime();
  _log = os_log_create("dev.walkscape.app", "preview");
  _frameQueue = dispatch_queue_create("camera.frames", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
  _introLayer = [AVSampleBufferDisplayLayer layer];
  _introLayer.videoGravity = AVLayerVideoGravityResizeAspect;
  _displayLayer = [AVSampleBufferDisplayLayer layer];
  _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
  _displayLayer.opacity = 0;  // until the camera's picture fades in (goLive:)

  NSError *err = nil;
  _engine = [[BackdropEngine alloc] initWithError:&err];
  _engineError = [err.localizedDescription copy];

  _device = MTLCreateSystemDefaultDevice();
  NSError *sceneErr = nil;
  _scenes = [[SceneRenderer alloc] initWithDevice:_device error:&sceneErr];
  if (!_scenes) NSLog(@"scene renderer: %@", sceneErr);
  _scenes.matchEaseIn = 1.0;  // the intro shows the scene before the camera is measured
  _useScene = _scenes != nil;
  _virtualCamera = [VirtualCameraOutput new];
  _frameLog = [FrameLog fromDefaults];
  return self;
}

- (void)dealloc {
  if (_formatDesc) CFRelease(_formatDesc);
  if (_introFormat) CFRelease(_introFormat);
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
    _camera = [[CameraSource alloc] initWithQueue:_frameQueue
                                          handler:^(CMSampleBufferRef sb) {
                                            [weakSelf handleCameraFrame:sb];
                                          }];
  }
  // At launch only: later the current camera's frames would load it back for their size meanwhile.
  CGSize size = [CameraSource frameSizeForDevice:device];
  if (_engine && size.width > 0 && self.cutout == CutoutEngineVideoEffects && !atomic_load(&_wentLive)) [self warmUpEngineForSize:size];
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

// Apple's engine loads for the camera's frames while the camera starts, rather than on its first
// frame (≈ 0.2 s; seconds when its models aren't cached). The intro holds the camera back
// meanwhile (introHolds:).
- (void)warmUpEngineForSize:(CGSize)size {
  BackdropEngine *engine = _engine;
  os_log_t log = _log;
  _Atomic(int) *warmUps = &_engineWarmUps;
  atomic_fetch_add(warmUps, 1);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *err = nil;
    if (![engine prepareForSize:size format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange error:&err]) {
      os_log_error(log, "Apple's engine didn't load ahead of the camera: %{public}@", err.localizedDescription);
    }
    atomic_fetch_sub(warmUps, 1);
  });
}

- (void)startIntro {
  __weak Pipeline *weakSelf = self;
  dispatch_async(_frameQueue, ^{
    Pipeline *me = weakSelf;
    if (!me || me->_introTimer || me->_cameraArrived) return;
    me->_introTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, me->_frameQueue);
    dispatch_source_set_timer(me->_introTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(me->_introTimer, ^{
      [weakSelf introTick];
    });
    dispatch_resume(me->_introTimer);
  });
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

// Until the camera's picture can be shown as chosen, the background moves on its own: while the
// scene is still compiling (at launch), or Apple's engine is still loading (warmUpEngineForSize:).
- (BOOL)introHolds:(ViewMode)mode {
  if (mode == ViewModeCamera) return NO;
  if (self.useScene) {
    if (_scenes.waitingForScene) return YES;
  } else if (!self.player) {
    return NO;  // no background: the camera as it is
  }
  return [self engineLoadingFor:mode];
}

- (BOOL)engineLoadingFor:(ViewMode)mode {
  return mode == ViewModeBoth && self.cutout == CutoutEngineVideoEffects && _engine && atomic_load(&_engineWarmUps) > 0;
}

// The intro's frames until the camera's first.
- (void)introTick {
  if (_cameraArrived || _live) {
    [self stopIntroTimer];
    return;
  }
  double t = CACurrentMediaTime();
  [self showIntroWidth:1280 height:720 time:t pts:CMTimeMakeWithSeconds(t, 1000000000)];
}

- (void)stopIntroTimer {
  if (!_introTimer) return;
  dispatch_source_cancel(_introTimer);
  _introTimer = nil;
}

// One frame of the intro: the background alone, in the intro layer (none while Show is Camera).
- (void)showIntroWidth:(size_t)width height:(size_t)height time:(double)t pts:(CMTime)pts {
  ViewMode mode = self.mode;
  CVPixelBufferRef bg = NULL;
  if (mode != ViewModeCamera) {
    SceneRenderer *scenes = self.useScene ? _scenes : nil;
    bg = scenes ? [scenes copyFrameAtTime:t width:width height:height] : [self.player copyCurrentFrame];
  }
  if (bg) {
    EnqueueFrame(_introLayer, &_introFormat, bg, pts);
    _introShown = YES;
    CVPixelBufferRelease(bg);
  } else {
    [self clearIntro];
  }
  [self reportStage:!bg ? PreviewStageStarting : _cameraArrived && [self engineLoadingFor:mode] ? PreviewStageLoadingEffect : PreviewStageBackground];
}

- (void)clearIntro {
  if (!_introShown) return;
  [_introLayer.sampleBufferRenderer flushWithRemovalOfDisplayedImage:YES completionHandler:nil];
  _introShown = NO;
}

// The camera's picture fades in over the intro, which keeps moving under it meanwhile
// (keepIntroUnder:).
- (void)goLive {
  _live = YES;
  atomic_store(&_wentLive, YES);
  [self stopIntroTimer];
  _introFadeEnd = CACurrentMediaTime() + kIntroFadeSeconds + 0.1;
  [self reportStage:PreviewStageLive];
  AVSampleBufferDisplayLayer *layer = _displayLayer;
  dispatch_async(dispatch_get_main_queue(), ^{
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0;
    fade.toValue = @1;
    fade.duration = kIntroFadeSeconds;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.opacity = 1;
    [layer addAnimation:fade forKey:@"fadeIn"];
    [CATransaction commit];
  });
}

// During the fade-in: `under`, the background alone of this frame (NULL when the camera shows as
// it is), goes to the intro layer; after it the intro layer is emptied.
- (void)keepIntroUnder:(CVPixelBufferRef)under pts:(CMTime)pts {
  if (under && CACurrentMediaTime() < _introFadeEnd) {
    EnqueueFrame(_introLayer, &_introFormat, under, pts);
    _introShown = YES;
    return;
  }
  _introFadeEnd = 0;
  [self clearIntro];
}

- (void)reportStage:(PreviewStage)stage {
  if (stage == _stage) return;
  _stage = stage;
  static const char *const names[] = {"nothing to show", "the background alone", "loading Apple's engine", "the camera"};
  os_log(_log, "showing %{public}s after %.2f s", names[stage], CACurrentMediaTime() - _launched);
  void (^handler)(PreviewStage) = self.stageHandler;
  if (handler) dispatch_async(dispatch_get_main_queue(), ^{
      handler(stage);
    });
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
  if (!_cameraArrived) {
    _cameraArrived = YES;
    [self stopIntroTimer];
    os_log(_log, "the camera's first frame after %.2f s (%zux%zu)", CACurrentMediaTime() - _launched, CVPixelBufferGetWidth(cam),
           CVPixelBufferGetHeight(cam));
  }
  if (_scenes && _noiseFrames++ % 15 == 0) {  // the background follows the camera's noise and levels
    FUCameraStats stats;
    if (FUMeasureCamera(cam, &stats)) {
      _noise = _noise > 0 ? _noise * 0.7 + stats.noise * 0.3 : stats.noise;
      _scenes.cameraNoise = fmin(_noise, 0.03);
      [_scenes measuredCamera:stats];
    }
  }
  ViewMode mode = self.mode;
  if (!_live) {
    if ([self introHolds:mode]) {  // the camera waits; the intro moves on at its pace
      size_t cw = CVPixelBufferGetWidth(cam), ch = CVPixelBufferGetHeight(cam), bw = MIN(cw, (size_t)1280);
      [self showIntroWidth:bw height:(bw * ch / cw) & ~(size_t)1 time:t pts:pts];
      return;
    }
    [self goLive];
  }
  CVPixelBufferRef out = NULL, bg = NULL;
  double renderMs = 0;
  NSString *renderError = nil;
  float bgLuma = -1;
  if (mode == ViewModeBackground) {
    out = [self copyBackgroundForCamera:cam time:t];
  } else if (mode == ViewModeBoth) {
    bg = [self copyBackgroundForCamera:cam time:t];
    if (bg && _frameLog) bgLuma = [FrameLog meanLumaOf:bg];
    if (bg) out = [self copyCutoutOfCamera:cam background:bg time:t renderMs:&renderMs message:&renderError];
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
  EnqueueFrame(_displayLayer, &_formatDesc, out, pts);
  if (_introFadeEnd > 0) [self keepIntroUnder:mode == ViewModeBoth ? bg : mode == ViewModeBackground ? out : NULL pts:pts];
  if (bg) CVPixelBufferRelease(bg);
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

// Shows `buffer` in `layer` at once. `*desc` caches the layer's format description.
static void EnqueueFrame(AVSampleBufferDisplayLayer *layer, CMVideoFormatDescriptionRef *desc, CVPixelBufferRef buffer, CMTime pts) {
  if (!*desc || !CMVideoFormatDescriptionMatchesImageBuffer(*desc, buffer)) {
    if (*desc) CFRelease(*desc);
    *desc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, desc);
  }
  if (!*desc) return;
  CMSampleTimingInfo timing = {.duration = kCMTimeInvalid, .presentationTimeStamp = pts, .decodeTimeStamp = kCMTimeInvalid};
  CMSampleBufferRef sample = NULL;
  if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, *desc, &timing, &sample) != noErr) return;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
  CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
  CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
  AVSampleBufferVideoRenderer *renderer = layer.sampleBufferRenderer;
  if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) [renderer flush];
  if (renderer.readyForMoreMediaData) [renderer enqueueSampleBuffer:sample];
  CFRelease(sample);
}

@end
