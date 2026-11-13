// FrameLog: diagnostics for the live camera path, which backdrop-test can't reproduce (timing,
// colour tags, what the preview is handed). Off unless asked for at launch:
//   WalkScape -camera <uniqueID> -frameTimingLog <file.csv> [-frameDumpDir <dir>]
// (launch arguments, or the same defaults keys). One CSV line per camera frame:
//   pts, arrive, ready   the camera's timestamp, when the frame arrived and when it was ready to
//                        show, in host-clock seconds (CACurrentMediaTime)
//   engine               Video Effects, Vision, raw (the camera as it is) or bg (Show: Background)
//   camTags … afterTags  colour tags (matrix/primaries/transfer, "-" when missing): the camera's,
//                        the engine output's, what the preview got, and the same buffer after the
//                        virtual camera's copy
//   surface              the output's IOSurface ID (which pool buffer)
//   camY, bgY, outY      mean luma (0…255) of camera, background and output
//   dOut                 the largest change from the previous output in a 16×9 grid of cells
//   prevMod              how much the previous output changed after it was shown (should be 0)
// With -frameDumpDir, the camera and output frames from 10 to 11.6 s in are saved there as
// 640×360 PNGs (cam-NNN.png, out-NNN.png). Camera queue only.

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FrameLog : NSObject

/// The log the defaults ask for, or nil.
+ (nullable instancetype)fromDefaults;

/// A buffer's colour tags as matrix/primaries/transfer ("-" when missing).
+ (NSString *)tagsOf:(CVPixelBufferRef)buffer;
/// A buffer's mean luma, 0…255 (-1 if it can't be read).
+ (float)meanLumaOf:(CVPixelBufferRef)buffer;

- (void)logFrameAt:(CMTime)pts
           arrived:(CFTimeInterval)arrived
             ready:(CFTimeInterval)ready
            engine:(NSString *)engine
        engineTags:(NSString *)engineTags
         shownTags:(NSString *)shownTags
            camera:(CVPixelBufferRef)camera
            output:(CVPixelBufferRef)output
    backgroundLuma:(float)backgroundLuma;

@end

NS_ASSUME_NONNULL_END
