// Background video sources.
//  - VideoFileReader: decodes every frame in order (deterministic, for the test tool).
//  - LoopingVideoPlayer: plays in real time and loops (for the app).
// Both hand out IOSurface-backed '420v' buffers.

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VideoFileReader : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
/// Next frame, looping at the end of the file. +1 reference.
- (nullable CVPixelBufferRef)copyNextFrame CF_RETURNS_RETAINED;
@end

@interface LoopingVideoPlayer : NSObject
- (instancetype)initWithURL:(NSURL *)url;
@property(nonatomic, readonly) NSURL *url;
/// The frame that should be on screen now (the last one if no new frame is due). +1 reference.
- (nullable CVPixelBufferRef)copyCurrentFrame CF_RETURNS_RETAINED;
- (void)play;
- (void)pause;
@end

NS_ASSUME_NONNULL_END
