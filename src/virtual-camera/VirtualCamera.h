// The app's side of the virtual camera, "WalkScape Camera": a CoreMediaIO camera extension in
// Contents/Library/SystemExtensions (extension/CameraExtension.m) that other apps open like a webcam.
//   - VirtualCameraInstaller installs, updates and removes the extension. macOS only does that for
//     a copy in /Applications signed with a provisioning profile that allows system extensions, and asks the user to approve it once.
//   - VirtualCameraOutput finds the camera's device and pushes every finished frame into the
//     extension's sink stream; the extension passes it on to whoever has the camera open.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What other apps call the camera.
extern NSString *const VirtualCameraName;

/// The device's AVCaptureDevice uniqueID (the camera list leaves it out: it shows this app).
extern NSString *const VirtualCameraDeviceID;

typedef NS_ENUM(NSInteger, VirtualCameraInstallState) {
  VirtualCameraInstallStateUnknown = 0,     // asking the system
  VirtualCameraInstallStateNotInstalled,
  VirtualCameraInstallStateNeedsApproval,   // System Settings → General → Login Items & Extensions
  VirtualCameraInstallStateInstalled,
  VirtualCameraInstallStateRestartNeeded,   // finishes after a restart
  VirtualCameraInstallStateUnavailable,     // this copy of the app can't install it; see `message`
};

/// Main queue only.
@interface VirtualCameraInstaller : NSObject
@property(nonatomic, readonly) VirtualCameraInstallState state;
/// Why it's unavailable, or what the last request failed with.
@property(nonatomic, readonly, nullable) NSString *message;
/// Called on the main queue after `state` or `message` changes.
@property(nonatomic, copy, nullable) void (^changeHandler)(void);

/// Asks the system whether the extension is installed; if it is, also updates it to the copy in
/// this app (macOS replaces it only when the version differs).
- (void)refresh;
- (void)install;
- (void)uninstall;
@end

@interface VirtualCameraOutput : NSObject

/// Watches for the device and connects to it whenever it appears. Safe to call again (it then
/// retries at once): call it after camera access is granted, and after installing.
- (void)start;

/// YES while frames go to the virtual camera.
@property(atomic, readonly) BOOL connected;
/// Called on the main queue when `connected` changes, with why connecting failed (or nil).
@property(nonatomic, copy, nullable) void (^stateHandler)(BOOL connected, NSString *_Nullable problem);

/// The part of each frame to send, in 0…1 of the frame with the origin top-left; the whole frame
/// by default. Narrowed around its centre to the camera's 16:9.
@property(atomic) CGRect crop;

/// Camera queue: scales `frame` (IOSurface-backed '420v') to the virtual camera's 1920×1080 and
/// sends it. Returns at once while not connected, or while the extension is behind.
- (void)sendFrame:(CVPixelBufferRef)frame;

@end

NS_ASSUME_NONNULL_END
