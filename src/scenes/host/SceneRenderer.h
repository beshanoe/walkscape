// SceneRenderer: the moving 3D background, rendered with Metal straight into a '420v' pixel buffer
// that BackdropEngine uses as the background. It hosts the scenes (Scene.h): it walks (speed →
// distance), places the webcam's camera on the scene's walking line, draws the sky, lets the
// scene draw itself, then blurs and converts.
//
// The scene camera stands on the path and looks back the way it came, as if a camera operator
// walked backwards in front of you: when you walk toward the webcam, the scenery recedes.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "FrameUtil.h"
#import "SceneParameter.h"

NS_ASSUME_NONNULL_BEGIN

/// A scene the renderer can show.
NS_SWIFT_SENDABLE
@interface SceneInfo : NSObject
@property(nonatomic, readonly) NSString *identifier;  // "forest"
@property(nonatomic, readonly) NSString *title;       // "Forest road"
@property(nonatomic, readonly) NSArray<SceneParameter *> *parameters;
@end

@interface SceneRenderer : NSObject

/// Compiles the shared shaders and loads the first scene. Nil with an error (e.g. a shader error).
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error;

/// Every scene, in menu order.
@property(class, nonatomic, readonly) NSArray<SceneInfo *> *scenes;
/// The host's own settings, the same for every scene. Their keys are this class's properties
/// (set them with -setValue:forKey:); sections "Walk and picture" and "Webcam position".
@property(class, nonatomic, readonly) NSArray<SceneParameter *> *commonParameters;

/// The scene to show. Setting it loads that scene in the background (compiling its shaders);
/// the current one keeps showing until it's ready. Errors appear in `sceneError`.
@property(atomic, copy) NSString *sceneID;
/// Loads `sceneID` now and shows it from the next frame (tests, start-up).
- (BOOL)selectScene:(NSString *)sceneID error:(NSError **)error;
/// Why the last scene load failed, or nil.
@property(atomic, readonly, nullable, copy) NSString *sceneError;

/// A scene setting (any thread; takes effect on the next frame). Unknown keys are ignored.
- (void)setValue:(double)value forParameter:(NSString *)key scene:(NSString *)sceneID;
- (double)valueForParameter:(NSString *)key scene:(NSString *)sceneID;

/// Target walking speed; the scene eases toward it (~0.6 s).
@property(atomic) double speedKmh;
/// Horizontal field of view of the webcam (degrees).
@property(atomic) double hFovDeg;
/// Camera pitch: positive looks up (laptop lids lean back, so webcams usually look up a bit).
@property(atomic) double tiltDeg;
/// Lens height above the ground (metres).
@property(atomic) double eyeHeight;
/// Blur of distant things: Gaussian sigma in pixels at 720p (scaled with the output height);
/// nearer things get less, like a lens focused on you. 0 = sharp.
@property(atomic) double blurSigma;
/// Exposure compensation in stops, on top of the lighting preset's.
@property(atomic) double brightness;
/// Grain as a multiple of `cameraNoise` (1 = match the camera).
@property(atomic) double grain;
/// The camera's noise (standard deviation of luma, 0…1), measured by Pipeline.
@property(atomic) double cameraNoise;
/// How far the background's look follows the webcam's (0…1): brightness, colour cast, black
/// and white levels, and a lens's distortion and colour fringes.
@property(atomic) double matchCamera;
/// The webcam's picture, measured (Pipeline, every 15 frames): eased toward each new value.
- (void)measuredCamera:(FUCameraStats)stats;

/// Moves the walker to `metres`, standing (tests; the next frame starts there and speeds up).
- (void)jumpToDistance:(double)metres;

@property(atomic, readonly) double distanceMetres;
@property(atomic, readonly) double lastGpuMs;
@property(atomic, readonly) NSUInteger instanceCount;

/// Renders the frame for `seconds` (any monotonic clock; steps are clamped to 0.1 s).
/// Returns a +1 IOSurface-backed '420v' buffer of the given size (even numbers).
- (nullable CVPixelBufferRef)copyFrameAtTime:(double)seconds width:(size_t)width height:(size_t)height CF_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
