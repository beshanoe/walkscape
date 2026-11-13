// backdrop-test: runs BackdropEngine headless on a photo or video "camera" and writes PNGs.
//
//   backdrop-test --person face.jpg [--focus-y 0.3] [--background bg.mp4|synthetic|<scene>]
//                 [--speed 3.5] [--height 1.15] [--tilt 10] [--fov 66] [--blur 4]   (scenes)
//                 [--match 0.6] (Match the webcam; 0: the scene's own look)          (scenes)
//                 [--param key=value]… [--seed N] [--distance metres] [--each key]  (scenes)
//                 [--frames 60] [--size 1280x720] [--types 0x40] [--every 15]
//                 [--engine apple|vision [--no-crop] [--no-refine]]
//                 [--vcam [--crop x,y,w,h]] --out dir
//   backdrop-test --list-scenes
//   backdrop-test --treadmill host:port|this-mac|<bonjour name> [--seconds 10]
//   backdrop-test --treadmill browse [--seconds 5]
//
// Writes out/frame-NNNN.png (+ matte-NNNN.png, bg-NNNN.png, input-NNNN.png: the camera frame, only
// the first for a photo) and prints per-frame timing. --engine picks who cuts
// the person out: Apple's Video Effects engine (default) or the Vision one (public API; --no-crop:
// Vision sees the whole frame, --no-refine: its mask as it is, for comparisons). --vcam also writes
// vcam-NNNN.png: the frame as the virtual camera gets it (1920×1080; --crop in 0…1 of the frame).
// Scenes: <scene> is a scene's identifier (forest, …; --list-scenes prints them with their
// settings). --param sets one of the scene's settings (a number, or a choice's title);
// --each <key> renders the whole run once per choice of that setting, from the same distance,
// writing <choice>-frame-NNNN.png etc.
// --treadmill reads a DirCon treadmill (a Direct Connect treadmill app, QZ …) with the app's TreadmillLink and
// prints each step and reading; exits 1 if no reading arrived. `browse` lists the sources found.

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#import "BackdropEngine.h"
#import "SceneRenderer.h"
#import "VisionBackdropEngine.h"
#import "FrameUtil.h"
#import "Treadmill.h"
#import "VideoSources.h"
#import "VirtualCameraShared.h"

static NSString *Arg(NSArray<NSString *> *args, NSString *name, NSString *fallback) {
  NSUInteger i = [args indexOfObject:name];
  return (i != NSNotFound && i + 1 < args.count) ? args[i + 1] : fallback;
}

/// Every value given for `name` (repeatable options).
static NSArray<NSString *> *Args(NSArray<NSString *> *args, NSString *name) {
  NSMutableArray *values = [NSMutableArray array];
  for (NSUInteger i = 0; i + 1 < args.count; i++) {
    if ([args[i] isEqualToString:name]) [values addObject:args[i + 1]];
  }
  return values;
}

static SceneInfo *SceneNamed(NSString *name) {
  for (SceneInfo *info in SceneRenderer.scenes) {
    if ([info.identifier isEqualToString:name]) return info;
  }
  return nil;
}

static SceneParameter *ParameterNamed(SceneInfo *scene, NSString *key) {
  for (SceneParameter *p in scene.parameters) {
    if ([p.key isEqualToString:key]) return p;
  }
  return nil;
}

static void ListScenes(void) {
  NSArray *groups = @[ @[ @"(every scene)", SceneRenderer.commonParameters ] ];
  for (SceneInfo *info in SceneRenderer.scenes) {
    groups = [groups arrayByAddingObject:@[ [NSString stringWithFormat:@"%@ (%@)", info.identifier, info.title], info.parameters ]];
  }
  for (NSArray *group in groups) {
    printf("%s\n", [group[0] UTF8String]);
    for (SceneParameter *p in group[1]) {
      NSString *range = @"";
      switch (p.kind) {
        case SceneParameterKindSlider: range = [NSString stringWithFormat:@"%@ … %@", [p describe:p.minimum], [p describe:p.maximum]]; break;
        case SceneParameterKindChoice: range = [p.choices componentsJoinedByString:@" | "]; break;
        case SceneParameterKindToggle: range = @"on | off"; break;
        case SceneParameterKindSeed: range = @"seed"; break;
      }
      printf("  %-14s %-22s default %-12s %s%s\n", p.key.UTF8String, p.title.UTF8String, [p describe:p.defaultValue].UTF8String,
             range.UTF8String, p.changesLayout ? "  (relayout)" : "");
    }
  }
}

/// --treadmill: runs the main run loop (the link reports on the main queue) for `seconds`.
static int ReadTreadmill(NSString *source, double seconds) {
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  void (^print)(NSString *) = ^(NSString *line) {
    printf("%6.2f  %s\n", CFAbsoluteTimeGetCurrent() - start, line.UTF8String);
    fflush(stdout);
  };
  if ([source isEqualToString:@"browse"]) {
    TreadmillBrowser *browser = [[TreadmillBrowser alloc] init];
    __weak TreadmillBrowser *weak = browser;
    browser.changeHandler = ^{
      NSMutableArray *names = [NSMutableArray array];
      for (TreadmillEndpoint *e in weak.endpoints) [names addObject:[NSString stringWithFormat:@"\"%@\"", e.name]];
      print([NSString stringWithFormat:@"found: %@%@", names.count ? [names componentsJoinedByString:@", "] : @"none",
                                       weak.problem ? [@"  problem: " stringByAppendingString:weak.problem] : @""]);
    };
    [browser start];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    [browser stop];
    return 0;
  }
  TreadmillEndpoint *endpoint = [TreadmillEndpoint endpointWithIdentifier:source];
  NSRange colon = [source rangeOfString:@":" options:NSBackwardsSearch];
  if (!endpoint && colon.location != NSNotFound) {
    endpoint = [TreadmillEndpoint host:[source substringToIndex:colon.location]
                                  port:(uint16_t)[source substringFromIndex:colon.location + 1].intValue];
  }
  if (!endpoint) endpoint = [TreadmillEndpoint bonjourService:source];
  TreadmillLink *link = [[TreadmillLink alloc] initWithEndpoint:endpoint];
  __block int readings = 0;
  __block double last = -1;
  link.logHandler = print;
  link.stateHandler = ^(BOOL connected, NSString *problem) {
    print([NSString stringWithFormat:@"state: %@%@", connected ? @"connected" : @"not connected", problem ? [@" — " stringByAppendingString:problem] : @""]);
  };
  link.readingHandler = ^(TreadmillReading r) {
    readings++;
    if (r.speedKmh == last) return;  // the source repeats its last reading every second
    last = r.speedKmh;
    print([NSString stringWithFormat:@"speed %.2f km/h  incline %.1f %%  distance %.0f m  elapsed %d s  HR %d",
                                     r.speedKmh, r.inclinePercent, r.distanceMetres, r.elapsedSeconds, r.heartRate]);
  };
  print([NSString stringWithFormat:@"reading %@", endpoint.name]);
  [link start];
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
  [link stop];
  print([NSString stringWithFormat:@"%d readings", readings]);
  return readings > 0 ? 0 : 1;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    if ([args containsObject:@"--list-scenes"]) {
      ListScenes();
      return 0;
    }
    if (Arg(args, @"--treadmill", nil)) {
      NSString *source = Arg(args, @"--treadmill", nil);
      return ReadTreadmill(source, Arg(args, @"--seconds", [source isEqualToString:@"browse"] ? @"5" : @"10").doubleValue);
    }
    NSString *person = Arg(args, @"--person", nil);
    NSString *outDir = Arg(args, @"--out", nil);
    if (!person || !outDir) {
      fprintf(stderr, "usage: backdrop-test --person <image|video> --out <dir> [--background <video>|synthetic|<scene>] [--frames N] "
                      "[--size WxH] [--types 0x40] [--every N] [--focus-y 0..1] [--param key=value]… [--each key]\n"
                      "       [--engine apple|vision [--no-crop] [--no-refine]]\n"
                      "       backdrop-test --list-scenes\n"
                      "       backdrop-test --treadmill host:port|this-mac|browse|<bonjour name> [--seconds N]\n");
      return 2;
    }
    NSString *background = Arg(args, @"--background", @"synthetic");
    int frames = Arg(args, @"--frames", @"60").intValue;
    int every = Arg(args, @"--every", @"15").intValue;
    NSArray<NSString *> *wh = [Arg(args, @"--size", @"1280x720") componentsSeparatedByString:@"x"];
    size_t width = (size_t)wh[0].integerValue, height = (size_t)wh[1].integerValue;
    uint64_t types = strtoull(Arg(args, @"--types", @"0x40").UTF8String, NULL, 0);
    CGFloat focusY = Arg(args, @"--focus-y", @"0.3").doubleValue;
    BOOL vcam = [args containsObject:@"--vcam"];
    NSArray<NSString *> *c = [Arg(args, @"--crop", @"0,0,1,1") componentsSeparatedByString:@","];
    CGRect crop = c.count == 4 ? CGRectMake(c[0].doubleValue, c[1].doubleValue, c[2].doubleValue, c[3].doubleValue) : CGRectMake(0, 0, 1, 1);
    CVPixelBufferPoolRef vcamPool = vcam ? BackdropCreatePool(kVCWidth, kVCHeight, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) : NULL;
    double vcamTotal = 0;
    [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Camera stand-in: a still image (every frame identical) or a video file.
    CVPixelBufferRef still = NULL;
    VideoFileReader *personVideo = nil;
    NSURL *personURL = [NSURL fileURLWithPath:person];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)personURL, NULL);
    CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (image) {
      CVPixelBufferRef bgra = FUBufferFromImage(image, width, height, focusY);
      still = FUConvert(bgra, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width, height);
      CVPixelBufferRelease(bgra);
      CGImageRelease(image);
    } else {
      NSError *err = nil;
      personVideo = [[VideoFileReader alloc] initWithURL:personURL error:&err];
      if (!personVideo) {
        fprintf(stderr, "cannot read person %s: %s\n", person.UTF8String, err.localizedDescription.UTF8String);
        return 1;
      }
    }
    if (src) CFRelease(src);

    VideoFileReader *bgVideo = nil;
    SceneRenderer *scenes = nil;
    SceneInfo *scene = SceneNamed(background);
    NSArray<NSString *> *variants = @[ @"" ];  // --each: one run per choice
    SceneParameter *eachParam = nil;
    double startDistance = Arg(args, @"--distance", @"0").doubleValue;
    if (scene) {
      NSError *serr = nil;
      scenes = [[SceneRenderer alloc] initWithDevice:MTLCreateSystemDefaultDevice() error:&serr];
      if (!scenes || ![scenes selectScene:scene.identifier error:&serr]) {
        fprintf(stderr, "scene: %s\n", serr.localizedDescription.UTF8String);
        return 1;
      }
      scenes.speedKmh = Arg(args, @"--speed", @"3.5").doubleValue;
      scenes.eyeHeight = Arg(args, @"--height", @"1.15").doubleValue;
      scenes.tiltDeg = Arg(args, @"--tilt", @"10").doubleValue;
      scenes.hFovDeg = Arg(args, @"--fov", @"66").doubleValue;
      scenes.blurSigma = Arg(args, @"--blur", @"4").doubleValue;
      if (Arg(args, @"--match", nil)) scenes.matchCamera = Arg(args, @"--match", nil).doubleValue;
      NSMutableArray<NSString *> *params = [Args(args, @"--param") mutableCopy];
      if (Arg(args, @"--seed", nil)) [params addObject:[@"seed=" stringByAppendingString:Arg(args, @"--seed", nil)]];
      for (NSString *kv in params) {
        NSRange eq = [kv rangeOfString:@"="];
        SceneParameter *p = eq.location == NSNotFound ? nil : ParameterNamed(scene, [kv substringToIndex:eq.location]);
        double v = 0;
        if (!p || ![p parse:[kv substringFromIndex:eq.location + 1] value:&v]) {
          fprintf(stderr, "--param %s: not a setting of %s, or a bad value (--list-scenes)\n", kv.UTF8String, scene.identifier.UTF8String);
          return 2;
        }
        [scenes setValue:v forParameter:p.key scene:scene.identifier];
      }
      NSString *each = Arg(args, @"--each", nil);
      if (each) {
        eachParam = ParameterNamed(scene, each);
        if (eachParam.kind != SceneParameterKindChoice) {
          fprintf(stderr, "--each %s: not a choice setting of %s\n", each.UTF8String, scene.identifier.UTF8String);
          return 2;
        }
        variants = eachParam.choices;
      }
    } else if (![background isEqualToString:@"synthetic"]) {
      NSError *err = nil;
      bgVideo = [[VideoFileReader alloc] initWithURL:[NSURL fileURLWithPath:background] error:&err];
      if (!bgVideo) {
        fprintf(stderr, "cannot read background: %s\n", err.localizedDescription.UTF8String);
        return 1;
      }
    }

    NSError *err = nil;
    NSString *engineName = Arg(args, @"--engine", @"apple");
    id<BackdropRendering> engine = nil;
    VisionBackdropEngine *vision = nil;
    if ([engineName isEqualToString:@"vision"]) {
      engine = vision = [[VisionBackdropEngine alloc] initWithDevice:MTLCreateSystemDefaultDevice() error:&err];
      vision.cropToPerson = ![args containsObject:@"--no-crop"];
      vision.refineEdges = ![args containsObject:@"--no-refine"];
    } else if ([engineName isEqualToString:@"apple"]) {
      BackdropEngine *apple = [[BackdropEngine alloc] initWithError:&err];
      apple.effectTypes = types;
      engine = apple;
    } else {
      fprintf(stderr, "--engine is apple or vision\n");
      return 2;
    }
    if (!engine) {
      fprintf(stderr, "%s\n", err.localizedDescription.UTF8String);
      return 1;
    }
    engine.wantsMatte = YES;

    double total = 0;
    int counted = 0;
    for (NSString *variant in variants) {
    NSString *prefix = variant.length ? [NSString stringWithFormat:@"/%@-", [variant.lowercaseString stringByReplacingOccurrencesOfString:@" " withString:@"-"]] : @"/";
    if (scenes) {
      if (eachParam) {
        double v = 0;
        [eachParam parse:variant value:&v];
        [scenes setValue:v forParameter:eachParam.key scene:scene.identifier];
        printf("%s = %s\n", eachParam.key.UTF8String, variant.UTF8String);
      }
      [scenes jumpToDistance:startDistance];
    }
    for (int i = 0; i < frames; i++) {
      double t = i / 30.0;
      CVPixelBufferRef cam = NULL;
      if (still) {
        cam = CVPixelBufferRetain(still);
      } else {
        CVPixelBufferRef raw = [personVideo copyNextFrame];
        cam = raw ? FUConvert(raw, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width, height) : NULL;
        if (raw) CVPixelBufferRelease(raw);
      }
      FUCameraStats stats;
      if (scenes && i % 15 == 0 && FUMeasureCamera(cam, &stats)) {  // as Pipeline does
        scenes.cameraNoise = fmin(stats.noise, 0.03);
        [scenes measuredCamera:stats];
        if (i == 0) printf("camera: noise %.4f, levels %.3f…%.3f, mean %.3f, cast %+.3f %+.3f\n", stats.noise, stats.black, stats.white, stats.mean, stats.cb, stats.cr);
      }
      CVPixelBufferRef bg = scenes  ? [scenes copyFrameAtTime:t width:1280 height:(1280 * height / width) & ~(size_t)1]
                            : bgVideo ? [bgVideo copyNextFrame]
                                      : FUSyntheticBackground(width, height, t);
      CVPixelBufferRef matte = NULL;
      NSError *rerr = nil;
      CVPixelBufferRef out = [engine renderCamera:cam background:bg time:t outMatte:&matte error:&rerr];
      if (!out) {
        fprintf(stderr, "frame %d: %s\n", i, rerr.localizedDescription.UTF8String);
        return 1;
      }
      if (i > 0) {
        total += engine.lastRenderMs;
        counted++;
      }
      printf("frame %3d  effect %.1f ms%s", i, engine.lastRenderMs, i == 0 ? "  (includes model init)" : "");
      if (vision) {
        CGRect c = vision.lastCrop;
        printf("  (Vision %.1f ms, crop x %.3f…%.3f)", vision.lastMaskMs, c.origin.x, CGRectGetMaxX(c));
      }
      if (scenes) printf("  scene gpu %.2f ms, %lu instances, %.1f m", scenes.lastGpuMs, (unsigned long)scenes.instanceCount, scenes.distanceMetres);
      printf("\n");
      // The virtual camera's copy, as VirtualCameraOutput makes it.
      CVPixelBufferRef vcamFrame = NULL;
      if (vcamPool) {
        CFTimeInterval t0 = CACurrentMediaTime();
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, vcamPool, &vcamFrame);
        CGRect r = FUFillRect(CGSizeMake(CVPixelBufferGetWidth(out), CVPixelBufferGetHeight(out)), crop, (CGFloat)kVCWidth / kVCHeight);
        if (!vcamFrame || !FUCropScale(out, r, vcamFrame)) {
          fprintf(stderr, "frame %d: cannot scale for the virtual camera\n", i);
          return 1;
        }
        vcamTotal += (CACurrentMediaTime() - t0) * 1000;
        if (i == 0) printf("vcam: %.0f,%.0f %.0fx%.0f of the frame → %dx%d\n", r.origin.x, r.origin.y, r.size.width, r.size.height, kVCWidth, kVCHeight);
      }
      if (i % every == 0 || i == frames - 1) {
        if (vcamFrame) FUWritePNG(vcamFrame, [NSURL fileURLWithPath:[outDir stringByAppendingFormat:@"%@vcam-%04d.png", prefix, i]]);
        FUWritePNG(out, [NSURL fileURLWithPath:[outDir stringByAppendingFormat:@"%@frame-%04d.png", prefix, i]]);
        if (matte) FUWritePNG(matte, [NSURL fileURLWithPath:[outDir stringByAppendingFormat:@"%@matte-%04d.png", prefix, i]]);
        if (bg) FUWritePNG(bg, [NSURL fileURLWithPath:[outDir stringByAppendingFormat:@"%@bg-%04d.png", prefix, i]]);
        // The camera frame too: the first one for a photo, each saved one for a video.
        if (i == 0 || personVideo) FUWritePNG(cam, [NSURL fileURLWithPath:[outDir stringByAppendingFormat:@"/input-%04d.png", i]]);
      }
      if (matte) CVPixelBufferRelease(matte);
      if (vcamFrame) CVPixelBufferRelease(vcamFrame);
      CVPixelBufferRelease(out);
      if (bg) CVPixelBufferRelease(bg);
      CVPixelBufferRelease(cam);
    }
    }
    if (counted) printf("mean %.2f ms/frame over %d frames (after the first)\n", total / counted, counted);
    if (vcamPool) {
      printf("vcam scale %.2f ms/frame (CPU wall time)\n", vcamTotal / frames);
      CVPixelBufferPoolRelease(vcamPool);
    }
    if (still) CVPixelBufferRelease(still);
  }
  return 0;
}
