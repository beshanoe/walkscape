// BackdropEngine: runs Apple's Video Effects engine (Portrait.framework PTEffect) in-process on
// camera frames, with any pixel buffer, e.g. a video frame, as the replacement background.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#import "BackdropRendering.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(uint64_t, BackdropEffects) {
  BackdropEffectNone = 0,
  BackdropEffectBackground = 1u << 6,  // PTEffect background replacement
};

@interface BackdropEngine : NSObject <BackdropRendering>

/// Loads Portrait.framework. Returns nil (with a reason) when it is missing.
- (nullable instancetype)initWithError:(NSError **)error;

/// Raw PTEffect type bits (see PTPrivate.h); BackdropEffectBackground by default.
@property(atomic) uint64_t effectTypes;
/// 0…100; the camera daemon uses 100 on Apple silicon.
@property(atomic) int64_t quality;
/// Studio Light strength (only used when its effect bit is on); NaN = Apple's default.
@property(atomic) float studioLightStrength;
/// Loads the engine for camera frames of `size` and `format` now, so that the first frame
/// doesn't wait for it (≈ 0.2 s, seconds when its models aren't cached). Any thread; a render
/// meanwhile waits. Frames of another size or format load it again, as without this.
- (BOOL)prepareForSize:(CGSize)size format:(OSType)format error:(NSError **)error;
// wantsMatte, -renderCamera:… and lastRenderMs: see BackdropRendering. The matte is Apple's
// (+[PTEffect personSegmentationMatteFormatForColorSize:]).

@end

NS_ASSUME_NONNULL_END
