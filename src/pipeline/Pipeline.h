// Pipeline: camera → background (3D scene or video) → cutout engine (Apple's Video Effects, or Vision)
// → display layer + virtual camera.
// Everything that touches frames lives here, in Objective-C, and runs on the camera queue; the
// SwiftUI app (src/app/) only sets the properties below and shows `displayLayer`.

#import <AVFoundation/AVFoundation.h>

#import "SceneRenderer.h"
#import "VideoSources.h"
#import "VirtualCamera.h"

NS_ASSUME_NONNULL_BEGIN

/// What the preview shows (the "Show" switch, saved as "viewMode").
typedef NS_ENUM(NSInteger, ViewMode) {
  ViewModeBoth = 0,        // you in front of the background (the effect)
  ViewModeCamera = 1,      // the raw camera
  ViewModeBackground = 2,  // the background alone
};

/// Who cuts you out of the camera picture (the "Cutout" switch, saved as "cutout").
typedef NS_ENUM(NSInteger, CutoutEngine) {
  CutoutEngineVideoEffects = 0,  // Apple's Video Effects engine (BackdropEngine, private API): the best edges
  CutoutEngineVision = 1,        // Vision's person segmentation + our Metal (VisionBackdropEngine, public API)
};

@interface Pipeline : NSObject

/// Creates the effect engine and the scene renderer. Failures are reported through `engineError`
/// and a nil `scenes`; the pipeline still works (raw camera, video or synthetic background).
- (instancetype)init;

/// The layer frames are enqueued to. Put it in a view.
@property(nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
/// Why Apple's Video Effects engine is unavailable (Vision does the cutout then), or nil.
@property(nonatomic, readonly, nullable) NSString *engineError;
/// The chosen cutout engine. Vision stands in when Apple's is unavailable, and for the rest of the
/// session once Apple's has failed for a second (choosing it again retries).
@property(atomic) CutoutEngine cutout;
/// The 3D scenes (forest, Paris street). Nil when the renderer failed to start (e.g. a shader error).
@property(nonatomic, readonly, nullable) SceneRenderer *scenes;
/// The background video, if one was chosen. Without one, the video background is no background:
/// frames show the camera as it is.
@property(atomic, readonly, nullable) LoopingVideoPlayer *player;

/// The 3D scene (YES) or the video (NO) is the background. Pauses the video while unused.
@property(atomic) BOOL useScene;
@property(atomic) ViewMode mode;

/// Gets every frame the preview shows (unmirrored), for other apps. Started once camera access
/// is granted.
@property(nonatomic, readonly) VirtualCameraOutput *virtualCamera;

/// The camera being shown, once started.
@property(nonatomic, readonly, nullable) AVCaptureDevice *cameraDevice;

/// Called on the main queue about once a second with camera, effect and scene numbers.
@property(nonatomic, copy, nullable) void (^statsHandler)(NSString *stats);
/// Called on the main queue when the effect starts failing (with the reason) or recovers (nil).
@property(nonatomic, copy, nullable) void (^renderErrorHandler)(NSString *_Nullable message);

/// Asks for camera access if needed, then switches to `device` (and starts `virtualCamera`).
/// Calls back on the main queue.
- (void)startCamera:(AVCaptureDevice *)device completion:(void (^)(NSError *_Nullable error))completion;
/// Loads a looping background video; `activate` also makes it the background. Nil removes the
/// video: while the video is the background, the camera then shows as it is.
- (void)setBackgroundVideo:(nullable NSURL *)url activate:(BOOL)activate;
/// Records the next `seconds` of raw camera frames (before any effect, as the engines get them)
/// into a ProRes movie, to reproduce what the camera saw with `backdrop-test --person <movie>`.
/// Calls back on the main queue when the file is written (or failed).
- (void)recordCameraFor:(double)seconds toURL:(NSURL *)url completion:(void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
