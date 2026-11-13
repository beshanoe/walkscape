// What the app (VirtualCamera.m) and the camera extension (CameraExtension.m) agree on: names,
// identifiers and the one video format "WalkScape Camera" offers. Macros, so they can initialize
// constants.

/// The system extension's bundle ID (Contents/Library/SystemExtensions/<ID>.systemextension).
#define kVCExtensionID @"dev.walkscape.app.camera"
/// Code signing identifier of the app; the extension's sink only accepts frames from it.
#define kVCAppSigningID @"dev.walkscape.app"
/// What video apps list. Also the CMIO device name.
#define kVCDeviceName @"WalkScape Camera"
#define kVCManufacturer @"WalkScape"
/// The CMIO device UID, which is also the AVCaptureDevice uniqueID.
#define kVCDeviceUID @"8346CBAE-54CD-4F1A-9BE4-00CAA8D80881"
#define kVCSourceStreamUID @"E46F9090-FABE-4AEC-AD08-ED104BD37B8F"
#define kVCSinkStreamUID @"060A1D13-560D-4D75-9589-5825A9DBF773"

/// The format: 1920×1080 '420v' (BT.709 video range) at 30 fps. The app scales its frames to it.
enum { kVCWidth = 1920, kVCHeight = 1080, kVCFrameRate = 30 };
