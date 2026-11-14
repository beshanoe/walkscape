// CameraSource: AVCaptureSession delivering '420v' frames (≤ 1920×1080, 30 fps) to a block.

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CameraFrameHandler)(CMSampleBufferRef sampleBuffer);

@interface CameraSource : NSObject
+ (NSArray<AVCaptureDevice *> *)availableDevices;
/// The frame size `-startWithDevice:` will get from `device` (its first preset of 1920×1080 and
/// 1280×720), or zero when it falls back to the device's own (High).
+ (CGSize)frameSizeForDevice:(AVCaptureDevice *)device;
/// Frames go to `handler` on `queue` (serial).
- (instancetype)initWithQueue:(dispatch_queue_t)queue handler:(CameraFrameHandler)handler;
/// Switches to `device` (stops the current one). Calls back on the main queue.
- (void)startWithDevice:(AVCaptureDevice *)device completion:(void (^)(NSError *_Nullable error))completion;
- (void)stop;
@property(nonatomic, readonly, nullable) AVCaptureDevice *device;
@end

NS_ASSUME_NONNULL_END
