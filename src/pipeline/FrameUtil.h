// Small CoreVideo helpers shared by the app and the headless test tool.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates an IOSurface-backed, Metal-compatible pixel buffer pool (at least 3 buffers).
CVPixelBufferPoolRef _Nullable BackdropCreatePool(size_t width, size_t height, OSType format) CF_RETURNS_RETAINED;

/// Converts any buffer to an IOSurface-backed buffer of `format` and size (scales, no crop).
CVPixelBufferRef _Nullable FUConvert(CVPixelBufferRef src, OSType format, size_t width, size_t height) CF_RETURNS_RETAINED;

/// Scales the `rect` part of `src` (pixels, origin top-left) to fill `dst` (IOSurface-backed),
/// with `src`'s colour tags (FUCopyColorTags). `rect` should have `dst`'s aspect ratio, or the picture is
/// stretched. `src` itself is left untouched (it may be on screen at the same time).
BOOL FUCropScale(CVPixelBufferRef src, CGRect rect, CVPixelBufferRef dst);

/// Sets `dst`'s colour tags (YCbCr matrix, primaries, transfer function) to `src`'s, with HD
/// video's (BT.709) for any `src` lacks; `src` may be `dst`. Some USB webcams (an OBSBOT Meet 2)
/// tag nothing.
void FUCopyColorTags(CVPixelBufferRef src, CVPixelBufferRef dst);

/// The part of a `frame`-sized picture to send to an `aspect` (width / height) output: `crop`
/// (0…1 of the frame, origin top-left) narrowed around its centre to `aspect`, in pixels.
CGRect FUFillRect(CGSize frame, CGRect crop, CGFloat aspect);

/// Draws `image` aspect-filled (cropped) into a new BGRA buffer. `focusY` 0…1 picks which
/// vertical band survives the crop (0 = top, 0.5 = centre).
CVPixelBufferRef _Nullable FUBufferFromImage(CGImageRef image, size_t width, size_t height, CGFloat focusY) CF_RETURNS_RETAINED;

/// Writes a pixel buffer (any format CoreImage reads, incl. one-component mattes) as PNG.
BOOL FUWritePNG(CVPixelBufferRef buffer, NSURL *url);

/// What a webcam's picture is like, for the background to match it.
typedef struct {
  double noise;         // luma noise: standard deviation, 0…1
  double black, white;  // luma's 2nd and 98th percentiles, 0…1
  double mean;          // mean luma
  double cb, cr;        // mean chroma of near-neutral mid-tones (−0.5…0.5): the light's colour cast
} FUCameraStats;

/// Measures a 4:2:0 frame ('420v' or '420f') on a grid of samples; NO if it isn't one. The noise
/// is Immerkær's estimator: the median absolute response of a 3×3 Laplacian (edges don't count).
BOOL FUMeasureCamera(CVPixelBufferRef buffer, FUCameraStats *stats);

/// A '420v' frame with animated stripes, for tests without a video file.
CVPixelBufferRef _Nullable FUSyntheticBackground(size_t width, size_t height, double t) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
