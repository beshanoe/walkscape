# WalkScape: notes for working on this repo

A macOS app for video calls: camera → **Apple's private Video Effects engine** (Portrait.framework
`PTEffect`, run in-process) → preview window and a **virtual camera** ("WalkScape Camera", a
CoreMediaIO camera extension), with a **Metal-rendered 3D scene** (forest road, mountain trail, medieval
street, Paris street, seaside promenade, indoor corridor) as a moving replacement background. The goal is a background that walks at the speed of the walking pad you're on.
A public-API fallback, the **Vision cutout** (`VisionBackdropEngine`: Vision's person segmentation
+ Metal), takes over when the private engine is missing or failing, or when chosen (Cutout switch).
User-facing docs: `README.md`. Apple internals and how to re-check them: `docs/apple-video-effects.md`.

## Ground rules

- **Everything runs locally**: no telemetry, no internet, no cloud services. The one connection
  is to a treadmill source (DirCon) on this Mac or the local network, while Speed from = Treadmill.
- **Private API**: Portrait.framework is undocumented. Reach it only through `src/cutout/apple/` (`PTPrivate.h`) and
  `NSClassFromString`, and fail with an error (never crash) when a class, selector or ivar is
  missing. Never on the Mac App Store (guideline 2.5.1).
- Don't run installers or downloads; ask the person you work with to install software.

## Layout

Source is grouped by feature; each folder is an include path (`build.sh`), so `#import "X.h"`
works anywhere and file names stay unique across `src/` (the build checks).

| Path                       | What                                                                 |
| -------------------------- | -------------------------------------------------------------------- |
| `src/app/`                 | SwiftUI: `WalkScapeApp` (window, menus, snapshot mode), `ContentView` (preview + inspector), `SettingsPanel` (rows built from `SceneParameter`s), `AppModel` (UI state, pushed to `Pipeline`), `Features` (flags for hidden UI), `WalkScape-Bridging.h` (the Objective-C Swift sees) |
| `src/pipeline/`            | Frame plumbing: `Pipeline` (camera → background → cutout engine → `AVSampleBufferDisplayLayer` + virtual camera), `CameraSource` (AVCaptureSession, 420v, ≤ 1080p, 30 fps), `FrameLog` (per-frame diagnostics of the live path, `-frameTimingLog`), `VideoSources` (looping AVPlayer, frame-exact AVAssetReader), `FrameUtil` (pixel buffer pools, VTPixelTransferSession conversion, PNG out, `FUMeasureCamera`), `ShaderFiles` (the embedded Metal sources) |
| `src/cutout/`              | `BackdropRendering.h`: what an engine does. `apple/`: `BackdropEngine` (`PTEffect` wrapper, the cross-fade ivar patch) and `PTPrivate.h`, **the only private-API code**. `vision/`: the Vision cutout (public API): `VisionBackdropEngine` (Vision request, crop placement), `VisionBackdrop.metal` (guided filter, spill correction, composite), `VisionBackdropShared.h` (params struct) |
| `src/virtual-camera/`      | `VirtualCamera` (app side: installer `OSSystemExtensionRequest`, sink client, CMIO C API), `VirtualCameraShared.h` (bundle IDs, device/stream UUIDs, the 1920×1080 420v 30 fps format). `extension/`: the camera extension (its own sandboxed process): `CameraExtension.m` (device, source + sink streams, "waiting" card) and its `Info.plist`/entitlements templates (`build.sh` fills in `@TEAM_ID@`, versions) |
| `src/treadmill/`           | Treadmill speed over DirCon (FTMS over TCP): FTMS parser, `TreadmillLink` (client), `TreadmillBrowser` (Bonjour) |
| `src/scenes/host/`         | `SceneRenderer` (walking, floating origin, webcam camera, shadows, sky, post, 420v), `SceneRegistry` (the scene list: scenes add themselves in `+load`), `Scene.h` (`WalkScene`, `SceneValues`, `WalkPoint`, `SceneFrame`, pass formats), `SceneParameter` (setting descriptors), `SceneShared.h` (C/Metal types: `FrameUniforms`, `MeshVertex`, slots), `SceneUtil` (SplitMix `Rng`, `Hex`, matrices, `MeshBuilder`), `Common.metal` (noise, sky, fog, shadow lookup, `Surface` shading, post kernels) |
| `src/scenes/environments/` | `Environment` (`SceneEnvironment` base, `LightPreset` → `FrameUniforms`), `OutdoorEnvironment` + `Outdoor.metal` (sun, sky, clouds, fog, wetness, night, grade), `IndoorEnvironment` (fixtures, bounce light, daylight through windows), `CoastEnvironment` + `CoastSky.h`/`CoastSky.metal` (the sky over the sea: raymarched cloud layer, rain, haze, stars, contrails; shared with the sea's reflections), `AlpineEnvironment` (the mountains' presets on the coast's sky) |
| `src/scenes/kit/`          | What more than one scene uses: `Plants` (`Plants.h`: `PlantUniforms`, `PlantInstance`, materials, atlas cells; plant meshes, `FoliageAtlas`; `Plants.metal`: foliage atlas kernel, `plant_vs`/`plant_fs`, `plantSurface`), `Furniture` (the bench) |
| `src/scenes/forest/`       | `ForestScene`, `Forest.metal`: placement, ground with its path |
| `src/scenes/mountain/`     | `MountainScene` (clipmap levels, baking, placement), `MountainProps`, `MountainTerrain.metal` (the height function and the bake kernels), `Mountain.metal` (terrain and prop shading, the air) |
| `src/scenes/paris/`        | `ParisScene`, `ParisProps`, `Paris.metal`: lots, facade geometry, shops, lot table, props (lofted cars …); canyon light, reflections, facade/window/street shaders, lettering |
| `src/scenes/seaside/`      | `SeasideScene`, `SeasideProps`, `Seaside.metal`: strip tiles (paving, balustrade rails and piers, sea wall, beach), park ground, the sea (ring grid + far pass to the horizon, waves, surf), balusters, crook lamps, wind-bent pines |
| `src/scenes/medieval/`     | `MedievalScene` (settings, segment streaming, the lantern light table, drawing), `MedievalTown` (per-segment plan and meshes: lots/houses, bridges, stalls, lanterns, signs, washing, ivy), `Medieval.metal`: the bend (shear), every material, canyon light, lane-lit mist |
| `src/scenes/corridor/`     | `CorridorScene`, `Corridor.metal`: segments (doors, windows, pictures, portals), fixture lighting, surfaces |
| `bundle/`                  | The app's `Info.plist` and `WalkScape.entitlements`                  |
| `tools/backdrop-test.m`    | Headless test tool (built by `build.sh`, with every `src/` object)   |
| `tools/`                   | Reverse-engineering and image-check tools (`tools/build.sh`)         |
| `testdata/`                | Public-domain portraits used as a fake camera                        |
| `docs/`                    | Apple Video Effects notes; how it works                              |
| `media/`                   | Optional local demo clip, gitignored                                 |
| `resources/AppIcon.icns`   | App icon, generated by `tools/make-icon.swift` (committed)           |
| `signing/`                 | Optional local provisioning profile for `build.sh` (gitignored)      |

## Commands

```sh
./build.sh                       # → build/WalkScape.app (+ extension), build/backdrop-test, build/camera-extension
open build/WalkScape.app
build/camera-extension --selftest "$TMPDIR/ext"   # builds the CMIO device in-process, writes card.png
tools/build.sh                   # → build/tools/{imgdump,ivars,objcdis,montage,rowsample,crop,make-icon}

# Redraw the icon after editing tools/make-icon.swift (--preview out.png for one 1024 px PNG)
build/tools/make-icon build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o resources/AppIcon.icns

# Headless check: portrait as the camera, forest behind, PNGs + timings out
build/backdrop-test --person testdata/person1.jpg --background forest \
  --frames 60 --every 59 --size 1280x720 --out "$TMPDIR/bt"
```

`backdrop-test` flags: `--background forest|medieval|mountain|paris|seaside|corridor|synthetic|<video>`, `--types 0x40` (effect
bits), `--size WxH`, `--frames N`, `--every N` (PNG interval), `--focus-y`, scene flags `--speed
--height --tilt --fov --blur --seed --distance --match` (Match the webcam; `--match 0` shows the scene's
own look, for comparing with a reference photo), `--param key=value` (repeatable; a number or a
choice's title), `--each key` (one run per choice, files prefixed `<choice>-`), `--list-scenes`,
`--vcam [--crop x,y,w,h]` (the virtual camera's copy, same code as the app), `--engine apple|vision`
(`--no-crop`, `--no-refine`: the Vision cutout without its crop / with Vision's mask as it is;
it prints Vision's ms and the crop per frame), and `--treadmill
this-mac|host:port|<Bonjour name>|browse [--seconds N]` (reads a treadmill source with the app's
`TreadmillLink`, prints each step and speed; exit 1 without a reading). It writes
`frame-*.png` (output), `matte-*.png`, `bg-*.png` (background alone), `vcam-*.png`,
`input-0000.png` (with a video as `--person`: `input-NNNN.png` for every saved frame), and
prints effect ms, scene GPU ms, instances, distance. Look at a lighting
or season sheet with `--each lighting` + `build/tools/montage`.

`build.sh` signs ad hoc unless `signing/development.provisionprofile` exists (or
`PROVISIONING_PROFILE` is set): then with the first "Apple Development" identity (or
`SIGN_IDENTITY`), hardened runtime, the profile embedded and the team ID from the profile.

## Verifying a change

- There are no unit tests. Build with zero warnings, run `backdrop-test`, and **look at the PNGs**
  (Read them). `build/tools/montage out.png a.png b.png` puts images side by side;
  `build/tools/rowsample <y> a.png …` prints a row of pixel colours to compare numerically;
  `build/tools/crop in.png x y w h [scale] out.png` enlarges a detail (the bg PNGs are always
  1280 wide). To see what a shader term contributes, write it straight to the colour for a
  moment (e.g. the canyon ambient on the road) and `rowsample` it.
- Baseline on the M4 Pro at 1280×720: effect ≈ 3–5 ms per frame; forest (Sunny, mixed) ≈ 2.5–3.5
  ms GPU with ≈ 2,900 instances (beech forest ≈ 4 ms); Paris (Sunny avenue) ≈ 4–4.5 ms, rue ≈ 2.5
  ms, Night ≈ 5 ms; seaside (Golden hour, Stormy) ≈ 3.5–4 ms, Overcast ≈ 3–3.5 ms, ≈ 1,000
  instances (judged against Paris with another WalkScape running); mountain (Clear day) ≈ 5.6–5.9
  ms with ≈ 6,500 instances, 3 ms of it the bare relief and sky (measured with another WalkScape
  running, the forest at 2.75 ms beside it); corridor ≈ 1 ms (1.7 ms with sun through windows); medieval street (Foggy) ≈ 3 ms (forest 2.8 ms beside it,
another WalkScape running). GPU times are noisy
  (clocks ramp): compare medians over 60+ frames. A large jump is a regression.
- Long walks: `--speed 8 --frames 9000` crosses the 512 m floating-origin snap; or start near it
  (`--distance 509 --every 1`) and compare the frames around 512 m.
- Scene refactors: render the same frames before and after (`cmp` the `bg-*.png`, e.g. every
  preset with `--each lighting`); the scene split and the environment split were byte-identical
  this way. Renders are deterministic run to run.
- **UI layout**: `WALKSCAPE_SNAPSHOT=/path/out.png build/WalkScape.app/Contents/MacOS/WalkScape`
  lays the window out off screen (no Dock icon, camera not started), saves it as a PNG and quits.
  The camera menu says "No camera" and the preview is black in that mode. It reads the real
  saved settings. The PNG is the whole window (title bar included) as the window server draws
  it; if that capture fails it falls back to AppKit drawing, which misses vibrancy (grey labels,
  popup and slider chrome, check marks), so don't read those as bugs in a 1440-px-tall PNG.
- The live camera path can't be checked headless (no camera access from the shell). Say so
  instead of claiming it works; ask the person you work with to look. But the app itself may use the camera, and
  it can log what happens: `open -n build/WalkScape.app --args -camera <uniqueID> -frameTimingLog
  <file.csv> [-frameDumpDir <dir>]`, wait, `osascript -e 'tell application id "dev.walkscape.app"
  to quit'` (quit any running WalkScape first; camera IDs from `system_profiler SPCameraDataType`;
  in zsh write the arguments out, `set -- $var` doesn't split). One line per frame: timestamps,
  engine, colour tags at each step, mean luma, the largest change from the previous frame, and
  whether a shown buffer changed afterwards (`src/pipeline/FrameLog.h`); the dump saves 1.6 s of
  camera and output frames as PNGs. It found the OBSBOT Meet 2's preview flicker (untagged
  frames, below) and its 25 fps. For problems in the person's own picture,
  ask for **File → Record Camera Clip (15 s)** (raw camera frames, ProRes, in
  `~/Movies/WalkScape/`) and run both engines on it with `backdrop-test --person <clip>
  --size 1920x1080 [--engine vision]`; row/column samples across an edge, next to Apple's
  output, beat eyeballing crops.
- Vision cutout baseline (1080p webcam clip): ≈ 10.5 ms per frame (8.7 in Vision), Apple's
  engine ≈ 5 ms. A running WalkScape shares the GPU/ANE and inflates every `backdrop-test`
  timing (Vision 8 → 11–18 ms): quit it before measuring.
- Virtual camera: `backdrop-test --vcam` checks the crop/scale; `build/camera-extension
  --selftest` checks the extension's objects and card. Installing, approval and frames reaching a
  video app need a team-signed build in /Applications; ask the person to check. CoreMediaIO
  enumeration does work from the shell (a throwaway tool listing `kCMIOHardwarePropertyDevices`).

## Finishing a feature

1. The checks above pass (zero warnings, `backdrop-test` run and its PNGs looked at; say what
   couldn't be checked headless).
2. Work on a branch of its own, one topic per branch, and open a pull request that says what was
   checked (before/after PNGs for visual changes).

Releases are made by the maintainer. Don't bump versions or build numbers in a pull request.

## Code notes

- Two languages. The UI is SwiftUI (Swift 6 language mode, warnings are errors). Everything on
  the frame path is Objective-C with ARC, C-style helpers, 2-space indent, long lines OK. Keep
  frames and the private API in Objective-C: Swift can't catch the `NSException`s Portrait may
  throw (`BackdropEngine` wraps `render:` in `@try`), and Swift 6 flags pixel buffers crossing
  to the camera queue.
- `build.sh`: every `.m` under `src/` goes into both the app and `backdrop-test`, except
  `src/virtual-camera/extension/` (its own binary); Swift files are `src/app/*.swift`. A new
  file needs no build change. Swift sees Objective-C through `src/app/WalkScape-Bridging.h`. Editors'
  SourceKit doesn't know about the bridging header and shows false "Cannot find type" errors;
  `./build.sh` is the check.
- Shaders: `build.sh` embeds every `.h` and `.metal` of each folder that has a `.metal` file
  (`xxd -i` → `build/ShaderFiles.inc`, a table by file name; `ShaderFileText()` in
  `src/pipeline/ShaderFiles.m`). `SceneRenderer` pastes `SceneShared.h` +
  `Common.metal` + the scene's `shaderSources` into one source and compiles it with
  `newLibraryWithSource:` (Xcode 26's offline Metal compiler is a separate download): the host's
  own pipelines at launch, a scene's the first time it's shown (in the background; the old scene
  keeps showing). Shader errors surface from `-[SceneRenderer initWithDevice:error:]` /
  `sceneError`; `backdrop-test --background <scene>` prints them.
- Types shared by C and Metal live in headers compiled as both (`SceneShared.h`, `XScene.h`):
  `vector_float3`/`matrix_float4x4`, plain float arrays in vertices, `#ifndef __METAL_VERSION__`
  around Objective-C. Functions both sides need (Paris: `ParisHash`, `ParisBayKind`,
  `ParisLevelHeight`) are `static inline` there. Still mirrored by hand: the forest's
  `PathX`/`GroundHeight` (`ForestScene.m` ↔ `Forest.metal`) and Paris's `StoneColor` ↔ `stoneColor`.
- Environments (`Environment.h`) sit between host and scene: a scene's `+environment` names one
  (`OutdoorEnvironment`, `IndoorEnvironment`); it owns the lighting presets (`LightPreset` tables;
  the scene's "lighting" setting offers a subset via `+lightingParameter:default:`), fills the
  lighting part of `FrameUniforms`, and draws the backdrop after the scene (outdoors the sky,
  where depth is still 1). The host keeps camera, walking, key-light shadows (when the preset's
  `shadow` > 0), shafts and post. Indoors `night` is the fixtures' power and `lampColor` their
  colour; the scene places the fixtures and lights from them itself (Corridor: nearest few per
  pixel, like Paris's lamps); `skyZenith`/`skyHorizon` are what glossy surfaces reflect.
  An environment lists the shader files the host compiles for it (`+shaderSources`).
  `CoastEnvironment` (the seaside's) fills `FrameUniforms`' coast fields too (zero elsewhere):
  `skySun` (the sun as the sky and the distant sea see it; `sunColor` is what reaches the scene:
  zero under a storm's deck while the horizon toward the sun is bright), `cloudBase`/`cloudDepth`,
  `clearHorizon`/`clearDistance` (clouds give way to clear sky toward the horizon, sooner toward
  the sun), `cirrus`, `storm`, `wind`, `windDir`. Its sky (`CoastSky.metal`) marches a cloud slab
  through a baked tileable noise (`CoastCloudNoise`); the scene compiles the same file and bakes
  its own copy to mirror the sky. Tune its look at the webcam's angles (0–30° up: rays cross
  kilometres of the slab, so thin cloud turns opaque) and with a typical blur (often ≈ 1.4, not
  4); preset colours are linear (a "peach" display colour needs a deep orange value).
- A scene: `WalkScene` class (its environment, settings as `SceneParameter`s, `relayout` on those that move things;
  `walkPointAtDistance:`; `prepareFrame:` rebuilds instances when the tile, origin or
  `layoutGeneration` changes; `encodeScene:`, optional `encodeShadowCasters:` and
  `adjustLighting:`) in its own folder, adding itself to `SceneRegistry` in `+load` (the menu is alphabetical by identifier = folder
  name). No list anywhere:
  a new folder is a new scene. Draw roughly front to back: the sky is drawn last where depth is
  still 1. Trees and props go through the kit's `plant_vs`/`plant_fs` (materials in `Plants.h`;
  a scene's own fragment function around `plantSurface` can add materials from 7 up).
- Scene layering, checked by `build.sh`: nothing outside `src/scenes/<scene>/` may name a file in
  it (the check greps for the quoted file name, comments included). Scenes build on `host/`,
  `environments/` and `kit/`; what a second scene needs moves to `kit/` first (the bench did).
  `segDist` and `bump` are in `Common.metal`. The plant pipeline reads `PlantUniforms` at
  `kBufferScene`; the forest's ground rebinds `ForestUniforms` there. The split was byte-identical
  (every scene and preset, `cmp`).
- Output buffers are IOSurface-backed `420v` (BT.709 video range) from `BackdropCreatePool`; the
  host writes the planes directly through `CVMetalTextureCache`. Set 709 attachments on new
  buffers. Every frame made from the camera gets the camera frame's colour tags, BT.709 for any it
  lacks, just before it's shown (`FUCopyColorTags` in `Pipeline`): an OBSBOT Meet 2 tags nothing
  (its format says 709), the engines pass that on, and the display side writes an odd primaries
  tag (`ColorPrimaries#2`) onto buffers it has shown, which comes back on recycled pool buffers;
  the preview flickered every few seconds on that mix while the virtual camera's copy didn't.
- `CameraSource` asks for 30 fps after `startRunning` (starting applies the preset, which resets
  the frame rate) and with a tolerance: USB cameras give intervals in 100 ns units, so the
  OBSBOT lists 30.00003 fps, and an exact `<= 30` check had left it at its default 25 fps.
- Settings that cross threads (camera queue vs main) are `atomic` properties (host) or go through
  `setValue:forParameter:scene:` (scene settings, snapshotted per frame). The scene renders on the
  camera queue, synchronously (`waitUntilCompleted`), before the effect.
- Scene facts: camera on the walking line looking back along it (scenery recedes as the person
  walks toward the webcam); per-tile placement seeded with SplitMix64 (deterministic, no
  popping); floating origin snapped every 512 m; forest trees 13–34 m, so the canopy fills the
  top of a laptop webcam's frame (tilt −30…60°, positive upward; laptop cameras look up 5–15°,
  more with the lid opened far back). Paris: straight street along z, 160 m blocks with a cross
  street each, block meshes cached; the walker keeps ≥ 1 m from every prop (on a rue's 2.4 m
  sidewalk most furniture is left out).
- Paris in more detail. Rules both sides need are `static inline` in `ParisScene.h`: building
  types (`ParisBuildingType`: Haussmann or old/plastered), level heights, `ParisOpeningIn` (each
  bay's opening and how deep it's set), shutters, shop units/types/sign words. Facades are built
  in a frame (`Facade`, `FP(u, v, d)`): street side, cut corner (`kChamfer`), cross street; walls
  around real openings (reveals, the glass or door set back = `kCityWindow`). Block triangles
  are sorted by group (`ParisMaterialGroup`: ground, walls, glass) and drawn with `city_fs`
  specialised per group (function constant 0). Light: `canyonAmbient` integrates the sky,
  facades and street over the street's cross-section (wedges); `parisEnvironment` traces a
  reflected ray to the facade plane and reads the **lot table** (`ParisLot`, rebuilt with the
  blocks: each building's facade span, code, lit shops) to know what it hits; `shopLight` is
  Lambert's polygon formula per lit shop window; `lampStreaks` mirror the lanterns in wet ground.
  Signs use a stroke font generated into `Paris.metal` (letters needed by `kSignWords`; add a
  letter there before using it in a word).
- Seaside in more detail. The coast follows `SeasidePathX(z)` (C and Metal, `SeasideScene.h`;
  the walker's copy in double); everything is placed by `s`, metres seaward of the sea wall's
  face (`seaSign` mirrors it for the sea on the right; the sun and wind mirror in
  `adjustLighting:`). The coping is 0.88 m high and the walker 0.9 m from the balustrade so that a
  1.15 m webcam sees the sea over it. 22 m strip tiles (a lamp pier at each start) are cached
  like Paris's blocks; balusters are instances within 160 m (`balusterFarZ`), beyond it the
  strip's screen draws their filtered silhouette. The sea: a ring grid around the camera (centre
  snapped to 2 m) moved by the 16 longest waves (filtered by the grid's spacing); `seaShade` sums
  all 40 waves with the pixel's footprint worked out from the view ray (derivatives of a displaced
  mesh jump at triangle edges: arcs in the glitter) and keeps only waves ≥ ~8 px (shorter ones
  alias into dots of glitter); the rest's slope variance is Beckmann roughness. Wave phases are
  computed per frame in double at the eye (positions in the shader are relative to it). Rough
  water mirrors sky higher than its mean surface would and with less Fresnel (the facets seen at
  a glance face the eye). The far pass (a full-screen triangle at depth 0.9999998, before the
  sky) draws the sea to the curved horizon, the far shore and the skyline; it discards the sky.
  The water blends (premultiplied) over the beach mesh where shallow. Surf: a bore per period
  from the breaker line, the swash up the beach (`surfAt`, shared by the sea and the sand).
- Mountain in more detail. The ground is `mtnTerrain(x, z)` in `MountainTerrain.metal`, and only
  there: no C mirror. `MountainScene` bakes it into a geometry clipmap (`kMtnLevels` 10 levels of
  513² vertices, cells 0.25 m × 2^level; texture arrays: height R32F, normal/occlusion/curvature,
  rock/scree/gully masks, the terrain's sun shadow for levels ≥ 3) and reads levels 0–3 back to
  stand instances on it (`height:atX:z:`). Only the trail's line is in both languages
  (`MountainPathX`, `MountainTrailY` in `MountainScene.h`; the walker's copy in double): the
  slope is built around it. Levels sit off centre, behind the walker and toward the valley
  (where the camera looks), follow in steps of 32 cells with hysteresis, and are re-baked
  synchronously on the scene's own queue when they move (and all shadows when the sun moves).
  Drawing: 64-cell blocks, culled in plan against the view's wedge; a coarser level is clipped
  (`clip_distance`) where the finer one covers it, less a 4-cell rim, and each level's rim morphs
  to the coarser heights and textures, so there are no cracks or pops. `mtnTerrain` takes the
  cell size and fades shapes under three cells (`mtnBand`), or coarse levels alias. The scene
  asks the host for a 0.3 m … 60 km depth range (`+depthRange`; the near plane sets the
  precision, not the far one) and bends the far terrain down with the earth's curvature; past
  24 km it fades into `coastSky`'s horizon. Shading pitfalls met: screen-derivative `bump()`
  with relief of centimetres hatches at a glance (large relief tilts the normal by the noise's
  analytic gradient instead, `mtnNoiseD`); every fine pattern fades by the pixel's footprint
  (`mtnSeen`); fine noise is drawn in z modulo 4096 m (`mtnWrapped`) to keep float precision on
  long walks. The range: ridged fractal noise raised to a power (`mtnRidged`: crests stand as
  towers, the hollows between run down as scree gullies) inside an eroded-noise envelope,
  needles (`mtnSpires`) on the crests; plateau walls cut by thresholds looked like mesas.
  The look was tuned against a reference photo of a Dolomites trail (not in the repo), side by side (portrait
  frames: `--size 768x1024 --height 1.6 --tilt 6 --fov 52 --blur 0 --speed 0 --distance 3000`
  + `montage`), sampling the photo's colours with `rowsample`. What that taught: (1) albedos
  must be real ones, then the grade can stay neutral: sunlit turf in the photo is sRGB ≈
  (115, 125, 60), which with a sun of 3–4 means a linear albedo of ≈ 0.07 (sRGB 60–90), four
  times darker than a "grass green"; rock ≈ 0.13–0.19, scree and gravel ≈ 0.3. Bright albedos
  were the "acid" look. (2) The sky is cyan-blue (zenith green ≈ a third of blue, almost no
  red), not violet. (3) A flat pattern on ground seen at a glance is squeezed into horizontal
  streaks; the camera always looks along z, so turf and gravel patterns are drawn 2.5× longer
  in z (`mtnDetail`/`mtnStones`'s `along`), blades as strokes along z, and round only at the
  camera's feet. (4) Voronoi cell edges read as mosaic: tufts and stones are round blobs
  around cell centres (`.z`), stones with a shadow offset toward the sun. (5) The noon sun
  stands behind the right shoulder (azimuth 140°, 45° up): from behind the left one the range
  showed only its shaded side. (6) Work the pixel can't show is skipped (`mtnSeen(...) > 0`
  guards, rock only where there is rock): the fragment shader had doubled the GPU time.
  The host inverts the view-projection in double for a deep range (far/near > 20,000): in
  single precision positions rebuilt from depth were off by percents.
  `WALKSCAPE_MOUNTAIN_RELIEF=1` draws the terrain plain grey, to judge its shape. Valley on the
  right mirrors the shape, the sun and the wind. "Valley mist" is drawn by the scene (`mtnAir`),
  not the sky: the mist lies below the eye.
- Medieval street in more detail. Built from a reference photo (not in the repo: a misty market
  lane: corbelled stone houses, arch bridges, washing lines, a stall with jars under a patched
  awning, lanterns, ivy), compared side by side round after round (portrait frames: `--size
  768x1376 --height 1.6 --tilt 8 --fov 58 --blur 0 --speed 0 --match 0 --distance 300`; the bg PNGs
  come out 1280 wide, so sample them at the photo's fractions, not its pixels). Street space: s
  across, facades at ±halfWidth; `MedievalPathX(z)` bends it as a shear in `town_vs` (periods 512,
  256, 128 m divide the origin snap; normals get n.z −= slope·n.x). `MedievalTown.m`: a plan per 48 m
  segment (`MakePlan`: lots, one bridge, stalls, wall lanterns, washing lines; the same plan gives
  the mesh and the lights), houses in wall space (`Wall`, d metres into the wall), openings cut as
  vertical strips with arch heads (`Band`, `Inside`), opaque triangles first then the ivy cards
  (a second pipeline with alpha to coverage). Boxes standing on the street get no bottom face
  (it z-fought the cobbles). Lanterns light through a table of 6 m buckets (`kLightsPerBucket`,
  the shader reads ±1 bucket; reach 6 m). What the photo taught: (1) the mist must be lit by the
  lane, not the open sky: near and low it is a fifth of the sky's brightness, as bright as the
  sky only 70 m off (`townSceneColor`); white mist at 10 % veiled the near walls; (2) the stone is
  grey-green, not beige: thin flush or weathered-out joints, mottled, streaks and soft moss
  patches; dark crisp joints read as toy brickwork; (3) the paving is rectangular granite setts in
  running bond with thin joints, not rounded pebbles; (4) reflections across the street must be
  blurred by roughness and the street position clamped to the facades (a negative distance made
  a bright patch under recessed houses); (5) noise inputs stay small (the cobbles' z wraps at 64 m;
  past ~10,000 the hash streaks). Exposure is raised 1.3× (and up to 1.8× more under clear skies):
  the lane gets a fraction of the sky's light, and a camera in it exposes for the stone.
- Grain follows the camera: `Pipeline` measures the camera every 15 frames (`FUMeasureCamera`:
  luma noise by median Laplacian, 2nd/98th percentile levels, mean, the cast of near-neutral
  pixels) into `SceneRenderer.cameraNoise` and `measuredCamera:`; the Grain setting multiplies
  the noise, **Match the webcam** (`matchCamera`, every scene) moves exposure, white balance and
  black/white levels toward the camera's and turns on a lens (barrel distortion, colour fringes)
  in `composePixel`. `backdrop-test` measures its input the same way (and prints it).
- Host passes a scene opts into (`adjustLighting:`; zero leaves a scene as it was): ambient
  occlusion (`aoStrength`) darkens only the share of each pixel's light the scene marks as ambient,
  written to the main pass's second attachment (`SceneColor.ambient`, `kSceneAmbientFormat`;
  pipelines declare it with `SceneDescribeMainPass(pd, writes)`); soft shadows (`shadowSoftAt`,
  `shadowSoftness`: blocker search + wider filter, near cascade only). Motion blur (camera
  movement, `prevViewProj`) is on for every scene. `lightSurfaceIn` lights a surface with the
  scene's own ambient and reflection (`lightSurface` stays as it was for forest and corridor).
- Metal pitfalls met here: `half` is a type (not a variable name); under fast math
  `atan2(d, -0.0)` came out −π/2 (Paris's road went navy; keep y > 0); every call site inlines
  its callee, so a big function (reflections) called from ten places doubled the GPU time: call
  heavy functions once per fragment and split übershaders with function constants.
- UI: a SwiftUI `Window` with the preview (`PreviewView`, hosting `Pipeline.displayLayer`; movie
  files can be dropped on it) and `.inspector` holding `SettingsPanel`. Panel order: app settings
  (camera, virtual camera, treadmill, Show, Cutout), then the settings every scene shares, then
  the scene picker and the scene's own sections. It should look like a finished product, so
  features not yet proven are hidden behind `Features` flags: **Treadmill** and **Cutout**
  (`Features.swift`: defaults keys `featureTreadmill`, `featureCutoutSwitch`, read at launch);
  while hidden, the speed comes from the slider and Apple's engine is chosen (saved choices are
  ignored, not overwritten). No UI text names a particular treadmill app (the this-Mac source is
  "Treadmill app on this Mac"). The scene menu ends with **Video** (after a separator); choosing
  it opens no dialog: **Select Video…** under the menu, and once a video is chosen its file name
  and **Clear**. With no video, `Pipeline` has no background (`copyBackgroundForCamera` → NULL)
  and sends the camera as it is, not the synthetic stripes. No sample video is bundled. The **Cutout** switch is key `cutout`;
  **File → Record Camera Clip** writes 15 s of raw camera to `~/Movies/WalkScape/`. `AppModel` (main actor)
  holds the UI state and pushes changes to `Pipeline` in `didSet`; `Pipeline` reports stats and
  render errors back on the main queue. The panel's rows are `ParameterRow`s built from
  `SceneRenderer.commonParameters` (keys = `SceneRenderer` properties, set by KVC: `speedKmh`,
  `blurSigma`, `brightness`, `grain`, `eyeHeight`, `tiltDeg`, `hFovDeg`) and the current scene's
  parameters, grouped by `section`. `UserDefaults` (domain `dev.walkscape.app`, `@AppStorage`):
  common ones under their key, scene ones as `<scene>_<key>` (no dots: KVO); the chosen scene
  under `scene`, the picked camera under `camera` (used whenever it's connected; a `-camera
  <uniqueID>` launch argument overrides it for one run). A new setting is a `SceneParameter` plus the code that reads it, nothing in
  Swift. Don't give `Slider` a `step:` (it draws a tick per step); `ParameterRow` rounds.
  The **Show** switch (`ViewMode`, key `viewMode`) picks Both (effect), Camera (raw) or
  Background (the background buffer displayed as is). Panel visibility: key `showSettings`.

## The virtual camera in brief

- `CameraExtension.m` publishes one CMIO device, "WalkScape Camera" (UID in
  `VirtualCameraShared.h`, also the `AVCaptureDevice.uniqueID`), with a **source** stream (what
  video apps open) and a **sink** stream (the app pushes frames; a CMIO *output* stream,
  direction 0). Each app frame goes to the source as is; after 0.5 s without one, a static card.
  The sink refuses clients whose `signingID` names another app; on macOS 27.2 CoreMediaIO reports
  "unknown" even for WalkScape, so unidentified clients are accepted.
- One format: 1920×1080 `420v` at 30 fps. The app scales every frame to it
  (`VirtualCameraOutput` → `FUFillRect` + `FUCropScale`: VideoToolbox, cropping through the clean
  aperture of a second `CVPixelBuffer` around the same IOSurface, copying only the colour tags).
  The extension drops frames of any other size. `crop` (0…1, top-left origin) is ready for a
  cropping UI.
- `VirtualCameraOutput` connects when the device appears (CMIO devices listener, plus a 2 s re-check while it is missing: the listener stayed silent when an updated extension started), keeps an
  App Nap activity while connected, and reconnects if its queue stays full for 2 s (the
  extension takes frames even when nobody watches, so a full queue means a dead connection).
  `Pipeline` starts it once camera access is granted. Sends what the preview shows (Show switch),
  unmirrored.
- `CameraSource.availableDevices` leaves out WalkScape Camera (feedback loop).
- Install: `VirtualCameraInstaller` (main queue). At launch a properties request; if installed,
  an activation request swaps in this build's copy. macOS only replaces an extension whose
  `CFBundleVersion` differs, and on 27.2 a replaced camera extension stayed stopped (gone from every
  app) until a restart; so `build.sh` derives that version from a checksum of the extension's
  sources, and app-only rebuilds don't replace it.
  The extension's app group and Mach service name are `<TEAM>.dev.walkscape.app.camera`; the
  host app needs `com.apple.developer.system-extension.install`, which only a provisioning profile
  grants (without one AMFI kills the app at launch, hence `build.sh` adds it only with a profile).
- Logs: app `dev.walkscape.app` / `virtual-camera`; extension `dev.walkscape.app.camera`.

## The Vision cutout in brief

- Details and the measurements behind each choice: `docs/apple-video-effects.md` → "Without the
  private API". `Pipeline` picks the engine per frame: Apple's when chosen and loaded; Vision
  otherwise, for any frame Apple's fails on, and after 30 failures in a row until the switch is
  flipped again (while the switch is hidden, until a relaunch). Vision's engine is made on first use.
- Per frame: GPU copy to BGRA ≤ 1280 wide (Vision is 5 ms slower on 4:2:0) → Vision balanced
  (512×384 soft mask, `regionOfInterest` = the 4:3 crop around the person, a
  `VNSequenceRequestHandler` for its state) → compute passes at 1/4 size (guided filter
  statistics, R², the person's and the old background's local colours; the mask keeps half of
  last frame's where luma didn't change) → `vb_composite` per 2×2 block.
- Alpha is Vision's mask, except where the guided filter is sure (R² and colour contrast):
  there its edge, bounded to Vision's ±8 px in / 4 px out (outward: door-gap spikes). Colours:
  unmixed with the guided (soft) alpha, composited with it 1.5× steeper: Apple's spill
  correction, fitted to Apple's output. Don't tune against Apple's matte buffer (pre-refinement).
- `kVBScale` (4) sets the low-res grid; radius and band scale with the camera height (constants
  at the top of `VisionBackdropEngine.m`). `VBParams` is shared C/Metal (simd types).

## The treadmill in brief

- Hidden in the UI unless `defaults write dev.walkscape.app featureTreadmill -bool true`
  (`backdrop-test --treadmill` works either way).
- The source is a treadmill app that shares its live data as a DirCon treadmill (Direct Connect,
  FTMS over TCP): on this Mac at TCP 36866 on 127.0.0.1 (`TreadmillEndpoint.thisMac`), or on the
  local network, advertised over Bonjour as `_wahoo-fitness-tnp._tcp` (QZ, Wahoo treadmills,
  treadmill apps in "local network" mode). WalkScape only reads; a source may refuse every write.
- DirCon wire format (no official spec; QZ's `dirconpacket.cpp` is the reference): 6-byte
  header (version 1, id, sequence, response code, BIG-endian length), 16-byte UUIDs on the
  Bluetooth base; ids 01 discover services, 02 characteristics, 03 read, 04 write, 05 enable
  notifications, 06 notification. Values keep FTMS's little endian.
- `TreadmillLink` (private queue, Network.framework C API): discover → subscribe to 0x2ACD (and
  0x2ADA) → readings to the main queue; retries every 2 s; TCP keepalive notices a vanished
  source; speed 0 after 3 s without a reading. It has no write at all. `AppModel` sets
  `SceneRenderer.speedKmh` from each reading (the renderer's 0.6 s easing smooths the 1 Hz
  steps), 0 when disconnected, and the slider's saved value when switched back.
- Loopback needs no Local Network permission; Bonjour browsing (WalkScape, only in treadmill
  mode) and a source's advertising do. `TreadmillBrowser` hides the this-Mac source's own
  Bonjour advertisement (`_ownName` in `Treadmill.m`): the this-Mac entry covers it.

## The private engine in brief

- Configure like the camera daemon's `-[BWBackgroundBlurNode _configurePTEffect]`: descriptor with
  `colorSize`, `externalDisparitySize = 0`, available/active effect types, quality 100,
  `externalCamera = YES`, `syncInitialization = YES`, **no `metalCommandQueue`** (then `render:`
  waits for the GPU, so the output is ready when it returns).
- Effect bits: `0x02` Studio Light (removed from the app: it dims and relights the background
  too, which looks wrong with a moving scene), `0x10` Reactions, `0x20` gestures, `0x40` background
  replacement (needs `inBackgroundReplacementBuffer`). Formats: `420v`/`420f`.
- **Cross-fade patch**: each new background buffer restarts a 0.8 s fade
  (`PTBackgroundReplacement._transitionDuration`), which freezes a moving background.
  `BackdropEngine` sets it to 1e-4 through `PTEffect.unsafeDelegateDirectAccess` →
  `PTEffectRenderer._backgroundReplacement`. If a moving background ever freezes again, check
  these ivars first (`docs/apple-video-effects.md` → "Re-checking after a macOS update").
- The system's own Video Effects (Control Center) run before frames reach the app and stack with
  ours; the app warns when they're on.

## Environment gotchas

- The app is signed ad hoc unless `signing/development.provisionprofile` exists, so every rebuild
  changes its signature and macOS may ask for camera access again (team-signed builds keep it).
- Developer Mode is off: lldb can't attach or load shared-cache images. `dyld_info` can't read
  shared-cache dylibs either. Use `tools/` (in-process `dlopen` + ObjC runtime + libLTO's
  disassembler).
- `os_log` subsystem: `dev.walkscape.app` (category `engine`).
- Run Python with `python3 -I`.
- zsh has a `log` builtin: call `/usr/bin/log show|stream`, or you get nothing back silently.
- A WalkScape left running (e.g. one opened to try) slows `backdrop-test`: both
  use the GPU and the Neural Engine.
- After an Xcode update, `clang`, `swiftc`, `git` and `python3` all fail until someone runs
  `sudo xcodebuild -license accept`. Meanwhile `DEVELOPER_DIR=/Library/Developer/CommandLineTools`
  works for checks, but its Swift 6.0.3 rejects `AppModel.startSelectedCamera` (sending
  `pipeline`), which Xcode's Swift accepts.

## Open work

- **Treadmill speed**: done over DirCon (above), checked against one treadmill app's demo walk,
  not yet on a real walk. Next maybe: incline in the scene; RSC (0x1814) for apps that
  want it; reading a pad directly over Bluetooth (the treadmill takes one connection, so only
  when no treadmill app holds it; the parser in `Treadmill.m` would be reused).
- **Virtual camera**: works end to end only with a team-signed build; not yet checked on a real
  call. Next: a cropping UI (`VirtualCameraOutput.crop`), maybe more formats (1280×720).
- **Vision cutout**: done and tuned on one real clip. Open: the background was seen not fully
  removed while leaning into a black chair (a still of that pose was clean in both engines; a
  recorded clip would show it); a 1–2 px dark mark where an edge crosses a corner of two old
  backgrounds (one local "old background" colour per neighbourhood).
- **Scenes**: forest road, mountain trail, medieval street, Paris street, seaside promenade and corridor, all procedural (no
  bundled models or textures, no traffic or pedestrians; lighting presets per environment,
  outdoor vs indoor; the seaside has three presets, Golden hour, Overcast, Stormy). Seaside,
  possible next: rock groynes into the sea, a belvedere with a pine at the balustrade, gulls.
  Mountain trail (built from a reference photo of a Dolomites trail; the first version looked
  toyish with acid colours, the aim is photorealism, judged against the photo side by side).
  Still short of the photo: the range's walls are smooth between their
  crests (no crags at 5–30 m; the clipmap has 8–16 m cells there), near rock is plain, grass is
  a flat texture plus tufts. Possible next: softer cumulus seen from below, a
  tarn or a hut in the valley, sections that differ along the walk (a saddle, a scree
  crossing), choughs, the treadmill's incline following the trail's.
  Medieval street (built from a reference photo, see above). Still short of it: the
  facades are tidier and flatter than the photo's crowded, leaning ones (no wooden galleries,
  no hanging plants or baskets on the upper floors), the stalls carry less than the photo's, the
  awnings are smooth sheets, and the far end shows mist rather than towers' silhouettes.
  Possible next: more scenes (see "A scene" above), a quality setting if slower Macs struggle
  (a beech forest or a sunny Paris avenue takes ≈ 4–4.5 ms GPU on the M4 Pro). Paris has no
  traffic or pedestrians by choice; its procedural look stops short of photo textures (also by
  choice), which would be the next big step toward photoreal.
