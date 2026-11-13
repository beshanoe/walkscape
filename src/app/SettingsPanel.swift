// The inspector panel: the version (and Update Available), the app's own settings (camera, virtual
// camera, the webcam's position, which goes with the camera, Show; treadmill and Cutout only when
// Features turns them on), then the rest of the settings every scene shares
// (SceneRenderer.commonParameters), then the scene picker (Video last) and the chosen scene's
// settings. Both kinds come from SceneParameter descriptors: ParameterRow saves each
// value in UserDefaults and applies it to the renderer.

import SwiftUI

struct SettingsPanel: View {
  @Bindable var model: AppModel

  private var cutoutNote: String {
    if model.videoEffectsUnavailable { return "Vision (public API) cuts you out: Apple's Video Effects engine isn't available here." }
    switch model.cutout {
    case .vision: return "Apple's Vision framework (public API) plus WalkScape's own edge work."
    default: return "Apple's Video Effects engine (private API): the cleanest edges."
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        versionLine
        ForEach(model.warnings, id: \.self) { warning in
          Text(warning).foregroundStyle(.orange)
        }
        if let status = model.clipStatus {
          Text(status)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        PanelSection("Camera") {
          Picker("Camera", selection: $model.cameraChoice) {
            if model.cameras.isEmpty { Text("No camera").tag(String?.none) }
            ForEach(model.cameras, id: \.uniqueID) { device in
              Text(device.localizedName).tag(Optional(device.uniqueID))
            }
          }
          .labelsHidden()
          Toggle("Mirror preview", isOn: $model.mirrored).toggleStyle(.checkbox)
        }
        Divider()

        PanelSection("Virtual camera") {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
              .fill(virtualCameraColor)
              .frame(width: 8, height: 8)
            Text(model.virtualCameraStatus)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if !model.virtualCameraConnected {
            switch model.virtualCameraInstall {
            case .notInstalled: Button("Install Virtual Camera") { model.virtualCameraInstaller.install() }
            case .needsApproval: Button("Open System Settings") { model.openCameraExtensionSettings() }
            default: EmptyView()
            }
          }
        }
        Divider()

        // Where the webcam is: with the camera, since a different camera means a different position.
        commonSection(Self.webcamSection)
        Divider()

        if Features.treadmill {
          treadmillSection
          Divider()
        }

        PanelSection("Show") {
          Picker("Show", selection: $model.mode) {
            Text("Both").tag(ViewMode.both)
            Text("Camera").tag(ViewMode.camera)
            Text("Background").tag(ViewMode.background)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
        Divider()

        if Features.cutoutSwitch {
          cutoutSection
          Divider()
        }

        // The other settings every scene shares (the walk, the picture) …
        ForEach(Self.sections(of: SceneRenderer.commonParameters).filter { $0 != Self.webcamSection }, id: \.self) { section in
          commonSection(section)
          Divider()
        }

        // … then which scene, and its own settings.
        PanelSection("Scene") {
          Picker("Scene", selection: $model.background) {
            ForEach(model.sceneChoices, id: \.identifier) { scene in
              Text(scene.title).tag(scene.identifier)
            }
            if !model.sceneChoices.isEmpty { Divider() }
            Text("Video").tag(AppModel.videoTag)
          }
          .labelsHidden()
          if model.background == AppModel.videoTag {
            if let name = model.videoName {
              Label(name, systemImage: "film")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(name)
            } else {
              Text("No video selected: your camera shows as it is.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
              Button("Select Video…") { model.choosingVideo = true }
              if model.videoName != nil {
                Button("Clear") { model.clearBackgroundVideo() }
              }
            }
          }
        }
        Divider()

        if let scene = model.currentScene {
          Group {
            ForEach(Self.sections(of: scene.parameters), id: \.self) { section in
              PanelSection(section) {
                ForEach(scene.parameters.filter { $0.section == section }, id: \.key) { parameter in
                  ParameterRow(parameter, scene: scene.identifier, renderer: model.pipeline.scenes)
                }
              }
              Divider()
            }
          }
          .id(scene.identifier)  // new rows (and storage keys) for another scene
        }

        Text(model.stats)
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(16)
    }
  }

  /// The version, and Update Available when a newer release is out (UpdateChecker).
  private var versionLine: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Version \(model.updates.currentVersion)")
        .foregroundStyle(.secondary)
      Spacer()
      if let version = model.updates.available {
        Button("Update Available") { model.updates.openReleasePage() }
          .buttonStyle(.link)
          .help("WalkScape \(version) is out: opens its release page")
      }
    }
    .font(.subheadline)
  }

  /// One section of the settings every scene shares (SceneRenderer.commonParameters).
  private func commonSection(_ section: String) -> some View {
    PanelSection(section) {
      if section == Self.webcamSection {
        Text("Match your real webcam, so the scene lines up with you.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Group {
        // With the treadmill as the source, its speed replaces the slider.
        ForEach(Self.common(in: section).filter { model.speedSource == .slider || $0.key != "speedKmh" }, id: \.key) { parameter in
          ParameterRow(parameter, scene: nil, renderer: model.pipeline.scenes)
        }
      }
      .disabled(model.currentScene == nil)
    }
  }

  /// Speed from the slider or a treadmill app (shown only with Features.treadmill).
  private var treadmillSection: some View {
    PanelSection("Treadmill") {
      Picker("Speed from", selection: $model.speedSource) {
        Text("Slider").tag(AppModel.SpeedSource.slider)
        Text("Treadmill").tag(AppModel.SpeedSource.treadmill)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      if model.speedSource == .treadmill {
        Picker("Source", selection: $model.treadmillSourceID) {
          ForEach(model.treadmillSources, id: \.identifier) { source in
            Text(source.name).tag(source.identifier)
          }
        }
        .labelsHidden()
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Circle()
            .fill(treadmillColor)
            .frame(width: 8, height: 8)
          Text(model.treadmillStatus)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let problem = model.treadmillBrowseProblem {
          Text(problem)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("Or walk at your treadmill's speed: from a treadmill app on this Mac, or a Direct Connect treadmill on your network.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Apple's Video Effects engine or Vision (shown only with Features.cutoutSwitch).
  private var cutoutSection: some View {
    PanelSection("Cutout") {
      Picker("Cutout", selection: $model.cutout) {
        Text("Video Effects").tag(CutoutEngine.videoEffects)
        Text("Vision").tag(CutoutEngine.vision)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .disabled(model.videoEffectsUnavailable)
      Text(cutoutNote)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

extension SettingsPanel {
  fileprivate static let webcamSection = "Webcam position"

  /// The renderer's own settings in one section.
  fileprivate static func common(in section: String) -> [SceneParameter] {
    SceneRenderer.commonParameters.filter { $0.section == section }
  }

  /// Section titles in the order they first appear.
  fileprivate static func sections(of parameters: [SceneParameter]) -> [String] {
    var seen: [String] = []
    for p in parameters where !seen.contains(p.section) { seen.append(p.section) }
    return seen
  }

  fileprivate var treadmillColor: Color {
    if model.treadmillConnected { return model.treadmillProblem == nil ? .green : .orange }
    return .secondary.opacity(0.5)
  }

  fileprivate var virtualCameraColor: Color {
    if model.virtualCameraConnected { return .green }
    switch model.virtualCameraInstall {
    case .needsApproval, .unavailable, .restartNeeded: return .orange
    default: return .secondary.opacity(0.5)
    }
  }
}

/// A bold title over its controls.
private struct PanelSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).fontWeight(.semibold)
      content
    }
  }
}

extension SceneParameter {
  /// The UserDefaults key: the parameter's key for the renderer's own settings ("speedKmh"),
  /// "<scene>_<key>" for a scene's ("forest_density").
  func storageKey(scene: String?) -> String {
    scene.map { "\($0)_\(key)" } ?? key
  }

  /// The saved value, or the default.
  func savedValue(scene: String?) -> Double {
    UserDefaults.standard.object(forKey: storageKey(scene: scene)) as? Double ?? defaultValue
  }
}

/// One setting: a slider (title and value on one line, the slider full width below), a menu, a
/// checkbox or a "New …" button. Saves the value and applies it to the renderer as it changes.
private struct ParameterRow: View {
  let parameter: SceneParameter
  let scene: String?
  let renderer: SceneRenderer?
  @AppStorage private var value: Double

  init(_ parameter: SceneParameter, scene: String?, renderer: SceneRenderer?) {
    self.parameter = parameter
    self.scene = scene
    self.renderer = renderer
    _value = AppStorage(wrappedValue: parameter.defaultValue, parameter.storageKey(scene: scene))
  }

  var body: some View {
    control.onChange(of: value) { apply() }
  }

  @ViewBuilder private var control: some View {
    switch parameter.kind {
    case .choice:
      Picker(parameter.title, selection: Binding(get: { Int(value) }, set: { value = Double($0) })) {
        ForEach(Array(parameter.choices.enumerated()), id: \.offset) { index, title in
          Text(title).tag(index)
        }
      }
    case .toggle:
      Toggle(parameter.title, isOn: Binding(get: { value != 0 }, set: { value = $0 ? 1 : 0 }))
        .toggleStyle(.checkbox)
    case .seed:
      Button(parameter.title) { value = Double(UInt32.random(in: 1...UInt32.max)) }
    default:
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(parameter.title)
          Spacer()
          Text(parameter.describe(value))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        Slider(value: snapped, in: parameter.minimum...parameter.maximum)
      }
    }
  }

  /// Rounds to the step. (`Slider(…, step:)` would draw a tick mark for every step.)
  private var snapped: Binding<Double> {
    Binding(get: { value }, set: { value = ($0 / parameter.step).rounded() * parameter.step })
  }

  private func apply() {
    if let scene {
      renderer?.setValue(value, forParameter: parameter.key, scene: scene)
    } else {
      renderer?.setValue(value, forKey: parameter.key)
    }
  }
}
