#import "VideoSources.h"

#import <QuartzCore/QuartzCore.h>

static NSDictionary *OutputSettings(void) {
  return @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
}

@implementation VideoFileReader {
  AVAsset *_asset;
  AVAssetTrack *_track;
  AVAssetReader *_reader;
  AVAssetReaderTrackOutput *_output;
}

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _asset = [AVURLAsset URLAssetWithURL:url options:nil];
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSArray<AVAssetTrack *> *tracks = nil;
  __block NSError *loadError = nil;
  [_asset loadTracksWithMediaType:AVMediaTypeVideo
                completionHandler:^(NSArray<AVAssetTrack *> *t, NSError *e) {
                  tracks = t;
                  loadError = e;
                  dispatch_semaphore_signal(done);
                }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  _track = tracks.firstObject;
  if (!_track) {
    if (error) *error = loadError ?: [NSError errorWithDomain:@"VideoFileReader" code:1 userInfo:@{NSLocalizedDescriptionKey : @"No video track"}];
    return nil;
  }
  return [self restart:error] ? self : nil;
}

- (BOOL)restart:(NSError **)error {
  [_reader cancelReading];
  _reader = [AVAssetReader assetReaderWithAsset:_asset error:error];
  if (!_reader) return NO;
  _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_track outputSettings:OutputSettings()];
  [_reader addOutput:_output];
  return [_reader startReading];
}

- (CVPixelBufferRef)copyNextFrame {
  for (int attempt = 0; attempt < 2; attempt++) {
    CMSampleBufferRef sb = [_output copyNextSampleBuffer];
    if (sb) {
      CVPixelBufferRef pb = CVPixelBufferRetain(CMSampleBufferGetImageBuffer(sb));
      CFRelease(sb);
      if (pb) return pb;
    }
    if (![self restart:nil]) return NULL;
  }
  return NULL;
}

@end

@implementation LoopingVideoPlayer {
  AVPlayer *_player;
  AVPlayerItemVideoOutput *_output;
  id _endObserver;
  CVPixelBufferRef _last;
  NSLock *_lock;
}

- (instancetype)initWithURL:(NSURL *)url {
  if (!(self = [super init])) return nil;
  _url = url;
  _lock = [NSLock new];
  _output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:OutputSettings()];
  AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
  [item addOutput:_output];
  _player = [AVPlayer playerWithPlayerItem:item];
  _player.muted = YES;
  _player.preventsDisplaySleepDuringVideoPlayback = NO;
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  __weak AVPlayer *weakPlayer = _player;
  _endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                 object:item
                                                                  queue:NSOperationQueue.mainQueue
                                                             usingBlock:^(NSNotification *note) {
                                                               [weakPlayer seekToTime:kCMTimeZero
                                                                      toleranceBefore:kCMTimeZero
                                                                       toleranceAfter:kCMTimeZero];
                                                             }];
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:_endObserver];
  [_player pause];
  if (_last) CVPixelBufferRelease(_last);
}

- (CVPixelBufferRef)copyCurrentFrame {
  [_lock lock];
  CMTime t = [_output itemTimeForHostTime:CACurrentMediaTime()];
  if ([_output hasNewPixelBufferForItemTime:t]) {
    CVPixelBufferRef pb = [_output copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
    if (pb) {
      if (_last) CVPixelBufferRelease(_last);
      _last = pb;
    }
  }
  CVPixelBufferRef result = _last ? CVPixelBufferRetain(_last) : NULL;
  [_lock unlock];
  return result;
}

- (void)play {
  [_player play];
}

- (void)pause {
  [_player pause];
}

@end
