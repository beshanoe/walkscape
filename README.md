# WalkScape

<img width="1313" height="732" alt="Untitled" src="https://github.com/user-attachments/assets/95a7bb29-67b3-47a7-acf8-f1616c3abbd0" />

A macOS app that puts you on a walk during video calls. It runs **Apple's own Video
Effects engine** (the one behind Control Center → Video Effects → Background) inside the app
and feeds it a **moving** background rendered with Metal, walking at your speed: an endless
forest road, a mountain trail, a Paris street, a medieval market street, a seaside promenade or
an indoor corridor. Video apps (FaceTime, Zoom, Meet, Teams and others) get the result from a
virtual camera, **WalkScape Camera**.

> **Private API.** Apple's background replacement only accepts still images, so WalkScape calls
> the private `Portrait.framework` directly, the same way the camera daemon does, and hands it a
> new background frame every camera frame. Nothing here is documented or supported. It was
> reconstructed on macOS 27.2 (26B123) and can break with any macOS update. The Mac App Store
> doesn't accept private API use, so WalkScape is shared as a Developer ID–signed, notarized
> download instead.
>
> When the private engine is missing or fails, a second cutout engine, **Vision**, does the job
> with public APIs only: Apple's Vision person segmentation plus WalkScape's own edge work in
> Metal. It's close to Apple's engine at the edges and takes about twice the time.

## Download

Get the disk image (`WalkScape-<version>-<build>.dmg`) from the
[Releases page](https://github.com/beshanoe/walkscape/releases). It is signed with a Developer
ID and notarized by Apple, so it opens without Gatekeeper warnings.

## Requirements

- An Apple silicon Mac (the app is arm64 only).
- macOS 15 or later. Apple's engine needs a macOS whose private engine matches what WalkScape
  expects (checked on 27.2); otherwise the panel says so and Vision does the cutout.
- A webcam.

## Install

1. Open the disk image and drag **WalkScape** onto **Applications**. The virtual camera only
   installs from `/Applications`.
2. Open WalkScape. macOS asks once whether to open an app downloaded from the Internet
   (**Open**), then asks for camera access.
3. In the settings panel, **Virtual camera → Install Virtual Camera**, then allow it in System
   Settings → General → Login Items & Extensions, under **Camera Extensions** (**Media
   Extensions** on macOS 27). Every virtual camera needs this approval, App Store ones included.
   The dot in the panel turns green.
4. In your video app, pick **WalkScape Camera** as the camera.

WalkScape Camera shows exactly what the preview shows, at 1920×1080, 30 fps, unmirrored like
any webcam (video apps mirror your self-view themselves). While WalkScape is closed, it shows a
card saying it's waiting for the app.

After updating WalkScape, copy the new app to Applications and open it: it swaps in the new
camera extension by itself. When the extension itself changed, macOS often starts the new one
only after a restart; until then video apps don't list WalkScape Camera.

To remove the virtual camera: **WalkScape → Remove Virtual Camera…** (or delete the app).

## Settings

The settings are in a panel on the right (**View → Hide/Show Settings**, ⌥⌘I; drag its edge to
resize). Values are saved between launches.

- **Camera**: which camera (remembered, and used whenever it's connected), and whether the
  preview is mirrored.
- **Virtual camera**: whether other apps can use the picture, with the one button that's needed
  next (**Install Virtual Camera**, **Open System Settings**).
- **Show**: **Both** (you in front of the background, the normal mode), **Camera** (the raw
  camera, to compare) or **Background** (the background alone).
- **Walk and picture**: **Speed**; **Blur** (how soft distant things are, like a lens focused on
  you); **Brightness**, to match the background to your room; **Grain**, as a multiple of the
  noise measured in your camera's picture (1× matches it); **Match the webcam**, how far the
  background takes on your camera's look (brightness, the colour of your room's light, black
  and white levels, a webcam lens's slight distortion and colour fringes; 0 turns it off).
- **Webcam position** makes the scene's camera match your real one: **Height above floor** (the
  lens height above the floor you stand on, the treadmill deck), **Tilt (up)** from −30° to 60°
  (laptop webcams usually look up 5–15°; over a laptop with its lid opened to 45°, about 45°),
  and **Field of view** (the webcam's horizontal angle).
- **Scene**: **Forest road** (default), **Mountain trail**, **Medieval street**, **Paris
  street**, **Seaside promenade**, **Corridor**, or **Video**: **Select Video…** picks a file
  (also ⌘O, or drag a video onto the window). With no video the camera shows as it is, its real
  background included.
- **Lighting**, per scene: outdoors from **Sunny**, **Morning sun**, **Golden hour** and
  overcast to **Foggy** and **After rain**; the Paris and medieval streets also have **Dusk**,
  **Night** and **Rainy night**; the seaside has **Golden hour**, **Overcast** and **Stormy**;
  the mountains have **Alpenglow**, **Valley mist** and **Night** (moon, stars, the Milky Way);
  the corridor has **Bright**, **Warm evening**, **Fluorescent**, **Sunlight through windows**
  and **Night**.
- **Each scene's own settings** follow: for example tree species, season and density in the
  forest; peaks and snow on the mountain trail; street width, market stalls and washing lines
  in the medieval street; street type, sidewalk side and café terraces in Paris; which side the
  sea is on and its waves at the seaside; style, walls, floor and windows in the corridor. Each
  scene has a **New …** button for another layout.

If the system's own Video Effects are on for WalkScape, a warning at the top of the panel says
so: they run before frames reach the app, so they would stack with this one.

### Hidden settings

Two settings are hidden until they're proven on more setups. To show one, run the command and
relaunch WalkScape (`defaults delete …` hides it again; the choices made in it are kept):

- `defaults write dev.walkscape.app featureCutoutSwitch -bool true` shows the **Cutout** switch
  (**Video Effects** or **Vision**). Without it, Apple's engine cuts you out and Vision takes
  over only when it is missing or keeps failing.
- `defaults write dev.walkscape.app featureTreadmill -bool true` shows the **Treadmill**
  section. With **Speed from → Treadmill**, the walk follows your treadmill: WalkScape reads its
  live data over **Direct Connect** (Wahoo's "DirCon": Bluetooth's Fitness Machine Service
  carried over TCP, the protocol Zwift and others use for treadmills on the network). The scene
  eases into each new speed and stops when the belt stops (or when no reading arrived for 3 s).
  WalkScape only reads: it never sends a command to the treadmill. So far this has been checked
  only against a DirCon treadmill app's demo mode, not on a real walk.
  - **Treadmill app on this Mac** (the default source): a Direct Connect treadmill app sharing
    its treadmill on 127.0.0.1:36866. No permission needed.
  - **Sources on your network** appear in the same menu: QZ (qdomyos-zwift), Wahoo treadmills,
    or a treadmill app on another Mac. Finding them asks once for Local Network access (System
    Settings → Privacy & Security → Local Network).

  The status line says what's happening: the speed while readings arrive, "Waiting for …"
  while the source isn't there (it retries every 2 s), "No readings from …" when it's connected
  but its treadmill is quiet.

## Privacy

Everything runs locally: no telemetry, no internet. The camera picture goes to the preview and
to WalkScape Camera, for the video apps you pick it in. The only connection WalkScape makes is
to a treadmill app on this Mac or your local network, and only when the hidden Treadmill
setting is on and **Speed from** is **Treadmill**. The scenes are all procedural: no models,
textures or videos are bundled or downloaded.

## Building from source

```sh
./build.sh                  # → build/WalkScape.app, build/backdrop-test
open build/WalkScape.app    # asks for camera access the first time
```

Needs Xcode (the command-line tools are enough) and an Apple silicon Mac on macOS 15 or later.
There's no Xcode project. The build is signed ad hoc: everything works except the virtual
camera, which macOS only installs from a build signed with a paid Apple Developer team and a
bundle ID registered to it; macOS may also ask for camera access again after a rebuild.
`build/backdrop-test` renders scenes and cutouts headless, to PNGs.

- [CONTRIBUTING.md](CONTRIBUTING.md): building, checking a change, pull requests.
- [AGENTS.md](AGENTS.md): the technical guide to the code, for people and coding agents.
- [docs/how-it-works.md](docs/how-it-works.md): the pipeline, the scenes, the cross-fade fix,
  the Vision cutout, measured timings, the headless test and a map of the files.
- [docs/apple-video-effects.md](docs/apple-video-effects.md): what Apple's engine does, and
  how to re-check the private API after a macOS update.

## License

GPL-3.0. See [LICENSE](LICENSE).
