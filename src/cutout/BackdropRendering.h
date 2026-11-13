// BackdropRendering: what Pipeline and backdrop-test need from a background-replacement engine.
// Two implement it: Apple's Video Effects engine (cutout/apple/BackdropEngine, private API, the
// only code that touches Portrait.framework) and the Vision cutout (cutout/vision/
// VisionBackdropEngine, public API).

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BackdropRendering <NSObject>
/// Also produce the person matte (see -renderCamera:… outMatte:).
@property(atomic) BOOL wantsMatte;
/// Renders one frame synchronously. `camera` and `background` must be IOSurface-backed
/// '420v' or '420f' buffers; `background` may have any size (the engine crops/scales it).
/// Returns a +1 output buffer (same size/format as `camera`), or NULL with `error` set.
- (nullable CVPixelBufferRef)renderCamera:(CVPixelBufferRef)camera
                               background:(nullable CVPixelBufferRef)background
                                     time:(double)seconds
                                 outMatte:(CVPixelBufferRef _Nullable *_Nullable)outMatte
                                    error:(NSError **)error CF_RETURNS_RETAINED;
/// Milliseconds spent in the last -renderCamera call.
@property(atomic, readonly) double lastRenderMs;
@end

NS_ASSUME_NONNULL_END
