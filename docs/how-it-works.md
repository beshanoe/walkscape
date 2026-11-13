# How WalkScape works

The technical side of WalkScape: how a camera frame becomes the picture video apps see, how the
scenes are built, the one hack that makes a moving background possible, the public-API
fallback, what it costs per frame, how to test it headless, and where everything lives. For
installing and using the app, see the [README](../README.md).

Apple's background replacement only accepts still images, so the app calls the private
`Portrait.framework` directly, the same way the camera daemon (`cameracaptured` → `CMCapture` →
`BWBackgroundBlurNode`) does, and hands it a new background frame every camera frame. It was
reconstructed from the runtime metadata and disassembly on macOS 27.2 (26B123) and can break
with any macOS update.

## How it works

```
camera (420v) ─┐
               ├─► PTEffectRenderRequest ─► -[PTEffect render:] ─► output (420v) ─┬─► display
background ────┘    inColorBuffer               (synchronous: no external Metal queue) │
(420v, any size)    inBackgroundReplacementBuffer                                     └─► virtual camera
                    outPersonSegmentationMatteBuffer (optional)
```

The virtual camera: `VirtualCameraOutput` (in the app) scales each output frame to 1920×1080
with VideoToolbox (≈1 ms) and puts it in the sink stream of the WalkScape Camera device, a
`CMSimpleQueue` shared with the extension's process. The extension (`CameraExtension.m`,
sandboxed, started by macOS) passes each frame on to the video apps as is (an IOSurface, no
copy). It refuses senders that CoreMediaIO identifies as another app; macOS 27.2 identifies
none (WalkScape itself shows up as "unknown"), so in practice any app with camera access may send.

`BackdropEngine.m` mirrors `-[BWBackgroundBlurNode _configurePTEffect]`: a
`PTEffectDescriptor` (colour size, effect types, quality 100) → `-[PTEffect initWithDescriptor:]`,
then one `PTEffectRenderRequest` per frame. Without a `metalCommandQueue` on the descriptor,
`render:` waits for the GPU, so the output is complete when it returns.

Effect type bits (from the bit tests in `-[PTEffectRenderer render:…]`; 0x2 confirmed by
experiment):

| Bit    | Effect                                              |
| ------ | --------------------------------------------------- |
| `0x02` | Studio Light (face relighting + background dimming) |
| `0x10` | Reactions                                           |
| `0x20` | Gesture-triggered reactions (needs `0x10`)          |
| `0x40` | Background replacement (needs a background buffer)  |

### The one hack: the cross-fade

Apple's engine treats each new background buffer as "the user picked another background"
and cross-fades to it over `PTBackgroundReplacement._transitionDuration` (0.8 s, set once in
its `init`). A new frame every 33 ms restarts the fade every frame, which freezes the picture
on the first background. `BackdropEngine` sets that ivar to 0.1 ms after the effect is
created, so each new frame takes over on the next render (one frame of delay). If the ivar is
renamed in a future macOS, the background will freeze again instead of crashing.

### Without the private API: the Vision cutout

`VisionBackdropEngine` does the same job with public APIs, as the fallback. Vision's
`VNGeneratePersonSegmentationRequest` (balanced) finds you; `VisionBackdrop.metal` does the rest,
borrowing Apple's tricks:

- **Crop**: Vision's mask is always 512×384 (4:3). It gets a 4:3 crop around you, so the mask
  isn't squashed and lands on you; the whole frame when you don't fit or something moves outside.
- **RGB in**: Vision converts 4:2:0 frames itself, slowly (13 ms at 1080p); a GPU copy to RGB
  first makes it 8 ms.
- **Edges**: Vision's mask is crisp and well placed. Where the colours behind you and on you are
  clearly apart (a dark shirt against a white wall, hair against the sky), a guided filter in
  the camera's YUV places the edge on the camera's own colours instead.
- **Edge colours** (Apple's "spill correction"): the camera's soft edge pixels are part old
  background. Their colour is unmixed with a soft alpha that follows the camera's edge, and the
  composite uses a crisper one, so the old wall doesn't show as a light rim; the camera's
  sharpening specks are smoothed out.

Choices behind it, measured on a real webcam clip against Apple's output, are in
[docs/apple-video-effects.md](apple-video-effects.md#without-the-private-api).

### Measured (M4 Pro, macOS 27.2)

| Step                                           | Time per frame       |
| ---------------------------------------------- | -------------------- |
| Forest road at 1280×720, sunny (shadows, blur) | ~2.5–3.5 ms GPU      |
| Paris street at 1280×720, sunny avenue (rue)   | ~4–4.5 ms (2.5 ms) GPU |
| Seaside promenade at 1280×720 (overcast)       | ~3.5–4 ms (3–3.5 ms) GPU |
| Mountain trail at 1280×720 (clear day)         | ~5.6–5.9 ms GPU (another WalkScape running) |
| Medieval street at 1280×720 (foggy)            | ~3 ms GPU (another WalkScape running) |
| Corridor at 1280×720 (sun through windows)     | ~1 ms (1.7 ms) GPU   |
| Apple's effect, 1920×1080 camera               | ~3–5 ms (mostly ANE) |
| Vision cutout, 1920×1080 camera                | ~10.5 ms (8.7 in Vision) |


## What Apple's engine does (short version)

Segmentation is a memory-based video segmentation network (`ANSTKit` `visegHQ`, 576×320,
Neural Engine) that sees the previous frame's matte; a guided filter refines edges from
the full-resolution colours; the composite runs in YUV with colour-temperature matching and
a slight blur on the background. Details, and how to re-check the private API after a macOS
update with the tools in `tools/`: [docs/apple-video-effects.md](apple-video-effects.md).

## The scenes (`src/scenes/`)

Every scene is endless and the same for the same seed, and is all procedural: no models or
textures are bundled; what needs a texture (the foliage) is drawn by a kernel at launch.
Four layers, each building only on the ones before it:

- **Host** (`SceneRenderer`), the same for every scene: walks (the speed eases in), keeps a
  floating origin snapped every 512 m so precision stays fine after hours of walking, and puts
  the camera on the scene's walking line, looking back along it, so the scenery recedes as you
  walk toward the webcam. It renders the key light's shadow map in two cascades when the
  lighting has one, lets the scene draw into a 4× MSAA pass, then post-processes: ambient
  occlusion (on the share of each pixel's light the scene marks as ambient, for scenes that ask),
  motion blur from the camera's movement, depth-aware blur, bloom, light shafts, tone mapping
  (Khronos PBR Neutral, its toe keeping dark colours' hue), grade, the webcam match (levels,
  colour cast, lens), vignette and grain, written by a compute kernel as BT.709 video-range 4:2:0
  straight into the IOSurface-backed `420v` buffer the effect engine reads. No CPU copies, no
  video decoding.
- **Environment** (`Environment.h`): the lighting model a scene lives in, with its presets and
  what is behind the scene. `OutdoorEnvironment`: sun, sky with drifting clouds and stars
  (`Outdoor.metal`), height fog, weather and time of day. `IndoorEnvironment`: light fixtures
  (which the scene places), bounce light, the sun only as daylight through windows, no sky.
  `CoastEnvironment`: the open sky over the sea (`CoastSky.metal`): a cloud layer with volume,
  raymarched through a noise texture baked at launch (lit edges and shaded cores, a deck thick
  and thin in cells, ragged storm bases, rain curtains, cirrus), clouds giving way to clear sky
  toward the horizon, haze lit by the sun beyond a storm. Scenes that mirror it (the sea)
  compile the same file.
- **Kit** (`src/scenes/kit/`): parts more than one scene uses. `Plants`: the plant meshes, the
  foliage atlas and the instanced pipeline (`Plants.metal`: `plant_vs`/`plant_fs`) that draws
  every scene's trees and props; `Furniture`: the bench. Scenes never use each other's files
  (`build.sh` checks): what a second scene needs moves here first.
- **Scenes**, each a folder of its own, in an environment:
- **Forest road** (`ForestScene`, `Forest.metal`): trees, bushes and stones per
  24 m tile with a per-tile random generator (no popping when tiles are rebuilt), a row of tall
  trees along each side of the path, undergrowth near the walk. Trunks and branches are bark
  tubes; foliage is cards cut out of the baked atlas (leaf clusters, spruce sprays, pine tufts,
  fern fronds, grass) with alpha-to-coverage, lit as rounded crowns, with light through the
  leaves. Three variants per species, lighter meshes for distant trees, bare ones in winter.
- **Paris street** (`ParisScene`, `ParisProps`, `Paris.metal`): 160 m blocks, each starting with
  a cross street, with a building per 12–21 m lot: Haussmann (ashlar, balconies on corbels,
  folding metal shutters) or older and plastered (wooden shutters, small panes), more of those on
  a rue; corner buildings are cut at 45°. Openings are geometry: reveals, sills, the glass, shop
  window or door set back; a shader draws the stone (each block its tone, streaks under ledges,
  soot by age) and the windows by interior mapping (a room behind each pane). Ground floors are
  shops of one to three bays, each a kind of shop with its name on the fascia (a small stroke
  font, French shop words), its interior and light, or a roller shutter. Light is worked out in
  the street's cross-section: the sky between the rooflines, the sunlit facades across, the
  street; reflections (windows, car paint, wet ground) find the facade a ray meets through a
  table of the buildings in view. At night shop windows light the sidewalk and lamps streak the
  wet ground. London plane trees (mottled bark), lofted cars and scooters, lamps, bike racks,
  benches, signs, pedestrian lights and café terraces use the forest's plant meshes and
  surfaces.
- **Medieval street** (`MedievalScene`, `MedievalTown`, `Medieval.metal`), an old market lane
  between tall stone houses, after a photo: 48 m segments, each with a house per 4.6–9 m lot on
  both sides (corbelled upper storeys, bay windows on stepped corbels, piers, deep arches over two
  storeys, half-timbered top floors, arched and leaded windows with shutters, balconies, carved
  panels of a winged beast, tiled roofs and chimneys), maybe an arch with a parapet or a covered
  passage across the street, market stalls under patched canvas (jars, crates of produce, bread,
  cloth, pots, shelves, drying herbs, sacks and barrels), wall lanterns and hanging shop signs on
  iron brackets, washing lines and ivy. The street bends gently (a shear in the vertex shader), so
  its far end closes into houses in the mist. A shader draws the ashlar (blocks of varied size,
  flush or weathered-out mortar, water streaks, algae and moss, grime at the foot), the granite
  setts and everything else; light comes from the strip of sky between the eaves and the facades
  across, the lanterns light what is near them (the nearest few, from a table of the lanterns in
  view), and the mist in the lane is lit by the lane, brightening with distance.
- **Mountain trail** (`MountainScene`, `MountainProps`, `MountainTerrain.metal`,
  `Mountain.metal`), high in the Dolomites: a stony path contouring a steep grass slope, the
  valley 600 m below on one side, and across it a range of pale rock towers with scree at their
  feet and snow in their gullies. The ground is one height function (the trail's bench, spurs
  and gullies, outcrops, cliff bands, the range's ridged crests with their needles, far ranges), baked on
  the GPU into ten nested levels around the walker, 0.25 m cells near the feet to 128 m ones
  40 km away, each level's rim morphing into the next; the sun's shadow across the terrain is
  baked the same way, and clouds drift their shadows over it. Turf with flowers and wind running
  through it, limestone with bedding and water streaks, scree, forest below the tree line and
  the trail's rubble are shaded from the baked normals and masks; grass tufts, flower clumps,
  stones, dwarf pine, spruces far below, cairns, signposts and a summit cross stand on it. The
  air turns distance blue; the sky is the coast's with heaped fair-weather clouds, contrails
  and, at night, stars.
- **Seaside promenade** (`SeasideScene`, `SeasideProps`, `Seaside.metal`), by the sea: a paved
  promenade along a gently curving coast, a stone balustrade (lathed balusters, piers, coping)
  with cast-iron crook lamp posts, benches facing the sea, wind-bent umbrella, maritime and
  Aleppo pines leaning inland, a sea wall and a beach with surf. The sea is a ring grid around
  the camera moved by the longest waves; 40 waves (a wind sea from the weather's wind, down to
  ripples, and a swell) shape every pixel's normal where the pixel resolves them, and the slopes
  of those it doesn't become roughness, which spreads the sun into a glitter path far out. It
  mirrors the coast's sky (clouds and all) and the far shore, scatters light from inside
  (turquoise in backlit crests), breaks into whitecaps in wind and into bores, swash and foam on
  the beach, and shows the sand through shallow water. Beyond the far plane a full-screen pass
  draws the sea to the curved horizon and the hazy hills and headlands along the coast.
- **Corridor** (`CorridorScene`, `Corridor.metal`), indoors: 32 m segments, each starting with a
  fire-door portal and an exit sign; doors (or windows) and pictures per wall. The shader lights
  each point from the nearest ceiling fixtures (with highlights on wood and polished stone),
  darkens the corners, and draws the carpet, wood or terrazzo, the ceiling (tiles with light
  panels, downlights, plaster with hanging globes), the doors and the paintings. With windows,
  the sun comes in through them and casts their frames on the floor.
- **Adding a scene**: a class conforming to `WalkScene` (`Scene.h`): its environment, its
  settings as `SceneParameter`s (the panel and `backdrop-test` build their controls from them),
  its walking line, its geometry and draw calls; `XScene.h` holds the types its shaders share.
  Put its files in a folder of their own (`src/scenes/<name>/`) and have the class add itself
  (`+ (void)load { [SceneRegistry registerScene:self]; }`; the menu is alphabetical by identifier).
  That is all: no list to edit. `build.sh` picks the folder up by itself (it compiles every
  `.m` and embeds the `.h`/`.metal`), and deleting the folder removes the scene;
  shaders are compiled at launch (Xcode 26 ships the offline Metal compiler separately), a
  scene's the first time it's chosen.

## Testing and building

### Headless test

```sh
build/backdrop-test --person testdata/person1.jpg --background forest --tilt 12 --fov 70 \
  --frames 90 --size 1920x1080 --out /tmp/backdrop
build/backdrop-test --list-scenes      # every scene and its settings
build/backdrop-test --person testdata/person1.jpg --background paris --param street=Boulevard \
  --each lighting --frames 2 --every 1 --out /tmp/paris   # one run per lighting preset
```

Writes output frames, mattes and inputs (`bg-*.png` is the background alone) as PNGs and
prints the time per frame. `--background` takes a scene (`forest`, `paris`), a video file or
`synthetic`. `--param key=value` sets a scene setting (a number, or a choice's name);
`--each key` runs once per choice of a setting, from the same spot, prefixing the files with
the choice; `--distance` starts the walk further on; `--seed` picks another layout. `--vcam`
also writes `vcam-*.png`, each frame as the virtual camera gets it (1920×1080; `--crop x,y,w,h`
in 0…1 of the frame picks a part, as cropping will). `build/camera-extension --selftest <dir>`
builds the extension's device in-process and writes its "waiting" card to `<dir>/card.png`.
`--types` takes raw effect bits (above). `--engine vision` uses the Vision cutout instead of
Apple's (`--no-crop`: Vision sees the whole frame; `--no-refine`: its mask as it is). With a
video as `--person`, each saved frame's camera picture is written too (`input-NNNN.png`).
`testdata/` has two public-domain portraits to use as the camera.

To reproduce what your own camera sees: **File → Record Camera Clip (15 s)** in the app saves
the raw camera frames (before any effect) as ProRes to `~/Movies/WalkScape/`; pass that file as
`--person`, once per engine.

`build/backdrop-test --treadmill this-mac|host:port|<Bonjour name> [--seconds 10]` reads a
treadmill source with the app's code and prints each protocol step and each new speed (exit 1 if
no reading arrived); `--treadmill browse` lists the Direct Connect sources on the network.
Treadmill logs: `log stream --predicate 'subsystem == "dev.walkscape.app" AND category == "treadmill"'`.

## Files

| File                       | Role                                                      |
| -------------------------- | --------------------------------------------------------- |
| `src/app/`                 | The app's UI (SwiftUI): window, settings panel, state     |
| `src/pipeline/`            | Camera → background → cutout → display and virtual camera; camera and video sources, pixel buffer helpers, the embedded shaders |
| `src/cutout/apple/`        | Apple's engine: PTEffect wrapper (+ the cross-fade fix) and the private declarations: the only private-API code |
| `src/cutout/vision/`       | The Vision cutout (public API): engine and Metal kernels  |
| `src/virtual-camera/`      | Installs the virtual camera and sends it the frames; `extension/` is the CoreMediaIO camera extension itself (+ its plist and entitlements templates) |
| `src/treadmill/`           | Treadmill speed over Direct Connect: FTMS parser, client, browser |
| `src/scenes/`              | The 3D scenes: `host/`, `environments/`, `kit/`, and a folder per scene: `forest/`, `medieval/`, `mountain/`, `paris/`, `seaside/`, `corridor/` (above) |
| `tools/backdrop-test.m`    | Headless test tool                                        |
| `build.sh`, `bundle/`      | Build without an Xcode project; the app's `Info.plist` and entitlements |
| `resources/AppIcon.icns`   | App icon, drawn by `tools/make-icon.swift`                |
| `tools/`                   | Analysis tools for the private frameworks, image checks   |
| `testdata/`                | Public-domain portraits for the headless test             |
| `docs/`                    | This page; how Apple's Video Effects work                 |
| `README.md`                | Installing and using the app                              |
| `CONTRIBUTING.md`          | How to build, check and propose a change                  |
| `AGENTS.md`                | Notes for coding agents (and humans) working on the repo  |
