# Contributing to WalkScape

Thanks for helping. This page covers building, checking a change and what a pull request needs. [AGENTS.md](AGENTS.md) is the technical guide: the layout of
`src/`, how the pipeline and the scenes work, and what has been measured.

## Building

You need an Apple silicon Mac with macOS 15 or later and Xcode or the Xcode command-line tools.
There is no Xcode project; the scripts call `clang` and `swiftc` directly.

```sh
./build.sh            # → build/WalkScape.app (with its camera extension), build/backdrop-test
open build/WalkScape.app
tools/build.sh        # → build/tools/: montage, rowsample, crop and the other helper tools
```

Without a provisioning profile, `build.sh` signs the app ad hoc. An ad hoc build runs everything:
the camera, the cutout, every scene and the settings. The only thing it can't do is install the
virtual camera, because macOS installs a camera extension only from an app signed by a paid Apple
team. Signing your own build is up to you and isn't covered here; don't commit signing or
bundle ID changes.

## Checking a change

There are no unit tests, so a change is checked by building it and looking at what it draws.

- **Zero warnings.** `./build.sh` and `tools/build.sh` must finish without a single warning
  (Swift warnings are already errors).
- **Run `backdrop-test`.** It feeds a portrait from `testdata/` through the app's own pipeline
  as if it were the camera, and writes PNGs and timings:

  ```sh
  build/backdrop-test --person testdata/person1.jpg --background forest \
    --frames 60 --every 59 --size 1280x720 --out "$TMPDIR/bt"
  ```

  `--background` picks the scene; AGENTS.md lists the other flags.
- **Look at the PNGs.** A shader or cutout change that builds can still look wrong.
  `build/tools/montage out.png a.png b.png` puts images side by side, `build/tools/crop` enlarges
  a detail, and `build/tools/rowsample` prints a row of pixel colours to compare numerically.
- **Refactors stay byte-identical.** Renders are deterministic, so render the same frames before
  and after and compare them with `cmp` (e.g. `cmp before/bg-0059.png after/bg-0059.png`, and
  every preset with `--each lighting`). A refactor that changes a pixel isn't a refactor.
- **Performance: compare medians.** GPU times are noisy while the clocks ramp up, so compare the
  medians over 60 or more frames, before and after, on the same Mac. Quit any running WalkScape
  first: it shares the GPU and inflates every timing.

The live camera path and installing the virtual camera can't be checked from the command line.
If your change touches them, try it in the app and say what you saw.

## Keep AGENTS.md current

People and coding agents (Claude Code, Codex, Cursor and others) learn the code from
[AGENTS.md](AGENTS.md). If your change moves a file, adds a scene or a flag, changes a rule, or
changes a measured number, update AGENTS.md in the same pull request.

## Pull requests

- **One topic each.** A fix, a scene or a refactor, not all three. Small pull requests get
  reviewed sooner.
- **Say what you checked:** the build, the `backdrop-test` runs (with their flags), `cmp` results
  for a refactor, the GPU medians before and after, and anything you couldn't check.
- **Before and after PNGs** for every visual change, from the same `backdrop-test` command.
- **No network access, no telemetry and no bundled assets.** WalkScape draws its scenes in code
  and never sends anything anywhere. No downloaded models, textures, fonts or videos; the test
  portraits in `testdata/` are the only images in the repo besides the icon.
- **Private API stays in `src/cutout/apple/`.** Everything else uses public frameworks only.

By contributing you agree that your contribution is licensed under the GPL-3.0, like the rest of
WalkScape (see [LICENSE](LICENSE)).
