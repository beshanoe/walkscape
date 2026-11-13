// VisionBackdropEngine: background replacement with public APIs only, the fallback for Apple's
// Video Effects engine (BackdropEngine, private API). Vision's person segmentation
// (VNGeneratePersonSegmentationRequest, balanced: a soft 512×384 mask, ≈ 8 ms on the M4 Pro)
// finds you; VisionBackdrop.metal makes the full-resolution matte and composites, with steps
// borrowed from Apple's engine and Google Meet (docs/apple-video-effects.md → "Without the
// private API"):
//   - crop: Vision's mask is always 4:3; it gets a 4:3 crop around you, so the mask isn't squashed
//     and all of it lands on you. The whole frame when you don't fit, or something moves outside.
//   - edges: Vision's mask, crisp and well placed, except where the camera's colours clearly explain
//     it (hair against the sky): there a guided filter in the camera's YUV (alpha ≈ a·Y + b·U + c·V
//     + d fitted at 1/4 size, evaluated per pixel), kept near the mask's edge.
//   - edge colour: the old background's colour taken out of semi-transparent pixels, and the
//     camera's sharpening halo (a dark line around a dark shirt) out of the outermost ones.
//   - time: Vision's request is stateful; the guided filter's mask also keeps part of last frame's
//     where nothing moved.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "BackdropRendering.h"

NS_ASSUME_NONNULL_BEGIN

@interface VisionBackdropEngine : NSObject <BackdropRendering>

/// Compiles the kernels. Nil (with a reason) when that fails.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error;

/// Give Vision a 4:3 crop around the person (default YES).
@property(atomic) BOOL cropToPerson;
/// Edges from the camera's colours where they're clear, old background and the camera's halo out of
/// them (default YES). NO composites with Vision's mask as it is (and no crop), for comparisons.
@property(atomic) BOOL refineEdges;
/// How much of last frame's mask stays where nothing moved, 0…1.
@property(atomic) float temporal;
/// Milliseconds the last frame spent in Vision (part of lastRenderMs).
@property(atomic, readonly) double lastMaskMs;
/// The part of the last frame Vision looked at (0…1, top-left origin).
@property(atomic, readonly) CGRect lastCrop;

@end

NS_ASSUME_NONNULL_END
