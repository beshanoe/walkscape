// Declarations for the private Portrait.framework classes that macOS's camera daemon
// (cameracaptured → CMCapture → BWBackgroundBlurNode) uses for Video Effects.
// Reconstructed from the ObjC runtime metadata and the call sequence in
// -[BWBackgroundBlurNode _configurePTEffect] on macOS 27.2 (26B123). Private API: it can
// change with any macOS update. Classes are looked up at runtime (NSClassFromString), never
// linked, so the app still launches if they disappear.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// PTEffect type bits, as tested in -[PTEffectRenderer render:…] and
// -[BWBackgroundBlurNode _getActivePTEffectTypes].
typedef NS_OPTIONS(uint64_t, PTEffectTypeBits) {
  PTEffectTypeBit0 = 1u << 0,
  PTEffectTypeBit1 = 1u << 1,
  PTEffectTypeBit2 = 1u << 2,
  PTEffectTypeBit3 = 1u << 3,
  PTEffectTypeReactions = 1u << 4,
  PTEffectTypeGestures = 1u << 5,           // needs Reactions
  PTEffectTypeBackgroundReplacement = 1u << 6,  // needs inBackgroundReplacementBuffer
};

typedef struct {
  CGSize size;
  OSType pixelFormat;
} PTEffectPixelBufferDescriptor;

@interface PTEffectDescriptor : NSObject <NSCopying>
@property(nonatomic, strong, nullable) id<MTLCommandQueue> metalCommandQueue;
@property(nonatomic) CGSize colorSize;
@property(nonatomic) CGSize externalDisparitySize;
@property(nonatomic) uint64_t availableEffectTypes;
@property(nonatomic) uint64_t activeEffectType;
@property(nonatomic) int64_t effectQuality;
@property(nonatomic) BOOL allowSkipOutColorBufferWrite;
@property(nonatomic) BOOL externalCamera;
@property(nonatomic) BOOL syncInitialization;
@property(nonatomic) BOOL prewarmOnly;
@end

@interface PTEffectRenderRequest : NSObject
@property(nonatomic, nullable) CVPixelBufferRef inColorBuffer;
@property(nonatomic, nullable) CVPixelBufferRef outColorBuffer;
@property(nonatomic, nullable) CVPixelBufferRef inBackgroundReplacementBuffer;
@property(nonatomic, nullable) CVPixelBufferRef outPersonSegmentationMatteBuffer;
@property(nonatomic) double frameTimeSeconds;
@property(nonatomic) uint64_t effectType;
@property(nonatomic) int64_t effectQuality;
@property(nonatomic) CGAffineTransform transform;
@property(nonatomic) float apertureSDOF;
@property(nonatomic) float relightStrengthStudioLight;
@property(nonatomic) float focalLength;
@property(nonatomic) float luxLevel;
@property(nonatomic) BOOL outColorBufferWriteSkipped;
+ (float)apertureSDOFDefault;
+ (float)relightStrengthStudioLightDefault;
@end

@interface PTEffect : NSObject
- (nullable instancetype)initWithDescriptor:(PTEffectDescriptor *)descriptor;
- (int)waitForInitialization;
- (int)render:(PTEffectRenderRequest *)request;  // 0 = success
- (int)setEffectType:(uint64_t)type;
- (void)reset;
+ (PTEffectPixelBufferDescriptor)personSegmentationMatteFormatForColorSize:(CGSize)size;
@end

NS_ASSUME_NONNULL_END
