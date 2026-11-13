# Apple's Video Effects: how they work and how WalkScape uses them

Notes from reverse-engineering macOS 27.2 (26B123) on an M4 Pro, November 2026. Sources: ObjC
runtime metadata (classes, methods, ivars), C strings, Metal shader names, Espresso network
graphs, and disassembly of the methods named below. Parts marked _inferred_ come from names and
structure only; everything WalkScape relies on was confirmed by disassembly or by experiment.

## Where the effects run

```
cameracaptured (user _cmiodalassistants)
  └─ CMCapture.framework: capture graph
       └─ BWBackgroundBlurNode ── soft-links ──► Portrait.framework
                                                   PTEffect → PTEffectRenderer
```

- The effects in Control Center → Video Effects (Portrait, Studio Light, Background, Reactions)
  run in the system camera daemon. Frames are modified **before any app receives them**, so
  they work in every app, and they stack with anything an app does itself.
- `-[BWBackgroundBlurNode prepareForCurrentConfigurationToBecomeLive]` calls
  `-[BWBackgroundBlurNode _configurePTEffect]` (an `objc_direct` method, so it's not in the
  method list), which builds the `PTEffectDescriptor` and creates the `PTEffect`.
  `BackdropEngine.m` mirrors that configuration.
- One renderer, `PTEffectRenderer`, handles all effects.

## Background replacement

1. **Segmentation: a video model with memory.** Classes
   `PTEffectPersonSegmentationViSegHQVisionCore(E5)` run Apple's "ViSegHQ" v2.1.0 models from
   `/System/Library/PrivateFrameworks/ANSTKit.framework/Resources/Models/`
   (`visegHQ_memory.mlmodelc`, `visegHQ_mask_memory_shared.mlmodelc`, about 15 MB) on the
   Neural Engine through Espresso/E5RT. Three graphs:
   - **Memory encoder**: `input_image [1,4,320,576]`, `mask`, `hidden_state [1,64,20,36]` →
     `key [1,1440,1,64]`, a value and `hidden`. The memory lives on a 1/16 grid.
   - **Mask decoder**: current frame + previous frame's matte and probability + attention over
     the stored keys/values + the recurrent hidden state → probability and a soft alpha matte.
   - **Mask + memory update**: decodes and refreshes the memory in one pass. Frames are labelled
     Initial, Regular or Update.
   - Input sizes: 576×320 for 16:9, 512×384 for 4:3, and the rotated versions. This is the
     memory-based video object segmentation family (XMem/STCN). Each frame "remembers" the
     person, so the mask doesn't flicker. _Inferred from the graphs._
2. **Edges from the camera colours: a guided filter** (`PTSpillCorrection` shaders: compute,
   average and apply upsampling coefficients; constraints from min/max-filtered mattes;
   diffusion). Eroding and dilating the matte gives "surely person", "surely background" and an
   uncertain band. In the band a per-pixel linear model `alpha ≈ a·Y + b·U + c·V + d` is fitted
   at low resolution and smoothed, and the composite evaluates it at full resolution. That's
   why hair and shoulder edges stay sharp although the mask is 576×320.
3. **Composite** (`backgroundReplacement` shader): runs in the camera's YUV with `coeffY/U/V`
   from the guided filter, a **colour-temperature correction**
   (`PTEffectColorTemperatureEstimation`) that matches the person to the background, and a
   slight portrait blur on the background.
4. **Backgrounds are still images**: `.heic` files and built-in gradients
   (`PTEffectBackgroundURL`, `PTEffectBackgroundURLManager`). Switching background cross-fades
   (below).

## The other effects (_inferred_)

- **Portrait blur**: monocular depth (AppleDepth `ADMonocularVideoPipeline`) on some frames,
  propagated with optical flow and smoothed over time (`PTLKTFlow`, `PTFilterEMA_LKT`,
  Lucas–Kanade); the bokeh is ray-traced through the depth (`PTRaytracingV6001`, ray count,
  aperture and focus parameters).
- **Studio Light** (`PTEffectRelighting`): an elliptical light mask from face and eye positions,
  normals from disparity, a gain map that brightens the face, background dimming; face
  brightness from `PTEffectFaceLuxEstimation` (auto-exposure statistics).
- **Reactions / gestures**: `PTEffectReaction*` classes; not used here.

## Calling it in-process (what `BackdropEngine.m` does)

The classes are loaded from the dyld shared cache with `NSClassFromString` after
`Portrait.framework` is linked or loaded. Declarations: `src/cutout/apple/PTPrivate.h`.

**Setup**

```objc
PTEffectDescriptor *d = [PTEffectDescriptor new];
d.colorSize = size;                      // camera size
d.externalDisparitySize = CGSizeZero;    // no depth input
d.availableEffectTypes = d.activeEffectType = types;   // e.g. 0x40
d.effectQuality = 100;
d.allowSkipOutColorBufferWrite = NO;
d.externalCamera = YES;
d.syncInitialization = YES;
// no metalCommandQueue: see "Synchronous rendering". The daemon also sets a GPU priority, its own
// metalCommandQueue and async init/processing queues; WalkScape leaves those out.
PTEffect *effect = [[PTEffect alloc] initWithDescriptor:d];
[effect waitForInitialization];
```

**Per frame**: a `PTEffectRenderRequest` with `inColorBuffer`, `outColorBuffer`,
`inBackgroundReplacementBuffer`, optional `outPersonSegmentationMatteBuffer` (format from
`+[PTEffect personSegmentationMatteFormatForColorSize:]`), `frameTimeSeconds`, `effectType`,
`effectQuality`, optional `apertureSDOF` / `relightStrengthStudioLight`, then
`-[PTEffect render:]` (returns `int`, 0 = success).

**Effect type bits** (from the bit tests in `-[PTEffectRenderer render:waitUntilCompleted:gpuCompleted:]`):

| Bit    | Effect                                                    |
| ------ | --------------------------------------------------------- |
| `0x02` | Studio Light (confirmed by experiment)                    |
| `0x10` | Reactions                                                 |
| `0x20` | Gesture-triggered reactions (needs `0x10`)                |
| `0x40` | Background replacement (needs `inBackgroundReplacementBuffer`) |

**Pixel formats**: `-[PTEffect validPixelBuffer:]` accepts `420v`/`420f` and their compressed
variants. Buffers must be IOSurface-backed (`BackdropCreatePool`).

**Synchronous rendering**: `-[PTEffect render:]` calls
`-[PTEffectRenderer render:waitUntilCompleted:gpuCompleted:]` with "wait" = `!_hasExternalCommandQueue`
(`PTEffect` ivar). Leave `metalCommandQueue` unset and the output is complete when `render:`
returns.

**The cross-fade.** `-[PTBackgroundReplacement initWithMetalContext:effectDescriptor:sharedSDOFRenderRequest:renderPipeline:]`
stores `0x3F4CCCCD` (0.8 f) into `_transitionDuration` (`f`, offset 240), and
`-updateAndGetBackgroundState:frameIndex:` starts a new transition whenever the background
buffer changes, unless `frameIndex == 0`. With a new buffer every frame, the fade restarts every
frame and the picture freezes on the first background. The fix (`-[BackdropEngine disableBackgroundCrossfade]`):
`PTEffect.unsafeDelegateDirectAccess` → `PTEffectRenderer._backgroundReplacement` →
set `_transitionDuration` to 1e-4 once per `PTBackgroundReplacement` instance. It checks the
ivars exist and that the type encoding is `f`; if Apple renames them, the background freezes
instead of crashing.

## Re-checking after a macOS update

Build the tools: `tools/build.sh` (→ `build/tools/`). All of them load the framework into their
own process (the shared cache has no standalone files; `dyld_info` can't read them, and lldb
needs Developer Mode).

```sh
P=/System/Library/PrivateFrameworks/Portrait.framework/Portrait
C=/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture

# Do the classes and selectors in src/cutout/apple/PTPrivate.h still exist?
build/tools/imgdump $P methods PTEffectDescriptor
build/tools/imgdump $P methods PTEffectRenderRequest
build/tools/imgdump $P methods PTEffect

# The cross-fade ivars (expect "240 _transitionDuration f" and "80 _backgroundReplacement ...")
build/tools/ivars $P PTBackgroundReplacement | grep transition
build/tools/ivars $P PTEffectRenderer | grep _backgroundReplacement

# Is 0.8 still stored at that offset? (mov/movk 0x3F4CCCCD, then str w8, [xN, #240])
build/tools/objcdis $P -- '-[PTBackgroundReplacement initWithMetalContext:effectDescriptor:sharedSDOFRenderRequest:renderPipeline:]' 3000 | grep -n -B3 '#240\]'

# How the camera daemon configures the effect: find the call, then disassemble at its address
build/tools/objcdis $C $P -- '-[BWBackgroundBlurNode prepareForCurrentConfigurationToBecomeLive]' | grep _configurePTEffect
build/tools/objcdis $C $P -- @0x<address from the bl line + its #offset> 3000

# Other places worth reading
build/tools/objcdis $P -- '-[PTEffect render:]'
build/tools/objcdis $P -- '-[PTEffectRenderer render:waitUntilCompleted:gpuCompleted:]' 3000
build/tools/objcdis $P -- '-[PTBackgroundReplacement updateAndGetBackgroundState:frameIndex:]' 3000

# Strings and class lists (Metal function names, log messages, model names)
build/tools/imgdump $P strings | grep -i transition
build/tools/imgdump $P classes

# Segmentation network graphs
python3 -I tools/espresso_summary.py /System/Library/PrivateFrameworks/ANSTKit.framework/Resources/Models/visegHQ_memory.mlmodelc/visegHQ_memory_v210_576x320.espresso.net
```

Notes on reading `objcdis` output:

- Calls are annotated with `objc_msgSend$<selector>` (shared-cache selector stubs), import stubs
  with the target symbol, `adrp`+`add` with the string, CFString, class or selector they point at.
- Ivar loads through `ldrsw` are annotated with ivar names (from the method's class, or `CLS=<Class>`
  in `@address` mode). The shared cache often inlines ivar offsets as immediates
  (`[x23, #240]`), so match those against `ivars` output by hand.
- In `@address` mode the start must be a function entry: the target of a `bl` (address of the
  `bl` plus its `#offset`). `objc_direct` methods start with a nil check (`cbz x0`) before `pacibsp`.

## Without the private API

What the public APIs offer, and how WalkScape's fallback (`VisionBackdropEngine`,
`VisionBackdrop.metal`) gets close to Apple's engine with them. Measured on the M4 Pro, macOS
27.2, against Apple's engine on the same frames: the test portraits, synthetic noisy and swaying
clips, and a real 1080p webcam clip (a bald head, a navy t-shirt, a white wall, a wooden wardrobe).

**What's public.** No API lets an app give the system's background replacement its own
(moving) background: `AVCaptureDevice.isBackgroundReplacementEnabled/Active` are read-only.
Vision's `VNGeneratePersonSegmentationRequest` (also `CIPersonSegmentation`) is the public
segmentation. Its models, in `/System/Library/Frameworks/Vision.framework/Resources/` (LZFSE
inside a `pbze` header: `tail -c +29 f | compression_tool -decode -a lzfse`):

| Level    | Generator (Vision class)                    | Network                                             | Mask      | ms (1080p) |
| -------- | ------------------------------------------- | --------------------------------------------------- | --------- | ---------- |
| fast     | `VNPersonSegmentationGeneratorFast`         | `personsegmentation-si-01`: MobileNetV2, 256×192 + previous mask | 256×192   | 2–3.5 |
| balanced | `VNPersonSegmentationGeneratorLearnedMatting` | the same, then `learnedmatting-f16-v2` (mask 208×192 + image 832×768) | 512×384 | 8 (RGB in), 13 (4:2:0 in) |
| accurate | `…LearnedMattingTiled`                      | `learned-matting-1512x2016`                         | 2016×1512 | 31–35      |

The mask is always 4:3 (squashed onto a 16:9 frame) unless `regionOfInterest` picks a 4:3 part,
which Vision honours (the mask then covers just that part). Reuse the request with a
`VNSequenceRequestHandler`: it keeps state (the previous mask is a network input). ViSegHQ, the
video model Apple's engine uses, isn't reachable from Vision.

**Raw Vision vs Apple's engine.** Balanced is as steady as Apple's on still footage and doesn't
lag on motion (±25 px/frame swaying), and its mask edge sits within ~2 px of Apple's. What gives
it away is colour: the camera's soft edge pixels are part old background, so a light wall
shows as a rim around you. Fast shimmers (1,300+ pixels jumping per frame on webcam noise).

**What the fallback adds**, and why:

- **RGB in, not 4:2:0**: Vision converts 4:2:0 itself at ~5 ms per 1080p frame; a GPU copy
  (`vb_to_rgb`, ≤ 1280 wide) costs a fraction of that.
- **A 4:3 crop around you** via `regionOfInterest` (placed from last frame's mask columns): the
  mask isn't squashed and all of it lands on you; on the webcam clip it was crisper than the
  whole frame's. Whole frame when you plus margins don't fit, when nobody is found, and for a
  second after something moves outside the crop (a hand reaching out).
- **Edges from Vision's mask, a guided filter only where colours are clearly apart.** A guided
  filter (alpha ≈ a·Y + b·U + c·V + d, fitted at 1/4 size) follows the camera's colours, which
  is right for a navy shirt against a white wall and wrong for a bald head against a pale wall:
  there it read the skin's shading as transparency and blurred a 10 px edge to 24 px ("glow").
  So it takes over only where R² (how much of the mask the colours explain) and the distance
  between the person's and the old background's local colours are both high. Its alpha may
  move the edge in by 8 px but out by only 4: outward, a dark door gap next to a dark shirt grew
  out of the shoulder as spikes.
- **Two alphas (Apple's spill correction, reconstructed from its output).** Apple keeps the
  camera's light shirt fringe fully opaque but darkens it (camera 53 → 40 next to an interior
  of ~30): its colours are unmixed (`F = (C − (1 − α)·B_old) / α`, `B_old` the old background's
  local colour) with a soft alpha that follows the camera's edge, while the composite uses a
  crisper one. The fallback does the same: the guided filter's alpha for the colours, the same
  edge 1.5× steeper for the composite. Near the edge, colours come from a [1 2 1]² blur of the
  camera, which takes out the single dark pixels the camera's sharpening leaves.
- **Steadier mask**: the guided filter's mask keeps half of last frame's where the picture
  didn't change (no lag where you move).
- **No light wrap** (Google Meet's background light around the edges): it read as a glow.

Dead ends worth not repeating: a min/max band computed on the 1/4 grid (4-pixel stairs along
edges); one chroma sample per 2×2 block for alpha (2-pixel stairs on colour edges); painting the
outer edge with the person's local average colour (a light rim on shaded skin); clamping edge
brightness to the range "just inside" (that range spans skin and shirt, so it clamps nothing).

**Comparing with Apple's engine.** `outPersonSegmentationMatteBuffer` looks like the network's
matte *before* the guided filter (smooth, no hair detail, while Apple's composite has strands),
so tuning a matte toward it misleads: compare composites (row samples across an edge) instead.
Apple's composite also blurs the background slightly, which removes most of the scene's grain;
the fallback shows the scene exactly as rendered. A running WalkScape shares the GPU and Neural
Engine with `backdrop-test` and inflates its timings (8 → 11–18 ms for Vision): quit it first.

Open: on a still taken from the webcam (leaning into a black chair) both engines were clean,
but live the background reportedly wasn't fully removed in that pose; a recorded clip (File →
Record Camera Clip) of it would show what happens.
