// AppModel: the app's UI state. Changes are pushed to the Objective-C Pipeline, which owns
// everything that touches frames; the pipeline reports stats and errors back on the main queue.

import AVFoundation
import AppKit
import Observation

@MainActor @Observable
final class AppModel {
  static let shared = AppModel()

  /// WALKSCAPE_SNAPSHOT=out.png: lay the window out off screen, save it as a PNG and quit without
  /// touching the camera (for checking the UI from a script). See AppDelegate.
  nonisolated static let snapshotPath: String? = {
    let path = ProcessInfo.processInfo.environment["WALKSCAPE_SNAPSHOT"] ?? ""
    return path.isEmpty ? nil : path
  }()

  let pipeline: Pipeline

  // Camera
  private(set) var cameras: [AVCaptureDevice] = []
  /// The selected camera's uniqueID; setting it starts that camera.
  var cameraID: String? {
    didSet { if cameraID != oldValue { startSelectedCamera() } }
  }
  /// The Camera menu. A pick is saved ("camera") and used whenever that camera is connected.
  var cameraChoice: String? {
    get { cameraID }
    set {
      UserDefaults.standard.set(newValue, forKey: "camera")
      cameraID = newValue
    }
  }
  var mirrored = true

  // What the preview shows and what's behind you
  var mode: ViewMode {
    didSet {
      pipeline.mode = mode
      UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
    }
  }
  /// Who cuts you out: Apple's Video Effects engine (private API) or Vision (public API).
  var cutout: CutoutEngine {
    didSet {
      pipeline.cutout = cutout
      UserDefaults.standard.set(cutout.rawValue, forKey: "cutout")
    }
  }
  /// Apple's engine can't load on this Mac (Vision does the cutout whatever is chosen).
  var videoEffectsUnavailable: Bool { pipeline.engineError != nil }
  /// What's behind you: a scene's identifier ("forest") or `videoTag`. A chosen scene is saved.
  var background: String {
    didSet {
      guard background != oldValue else { return }
      if background == Self.videoTag {
        pipeline.useScene = false
      } else {
        pipeline.scenes?.sceneID = background  // loads it in the background if needed
        pipeline.useScene = true
        UserDefaults.standard.set(background, forKey: "scene")
      }
    }
  }
  static let videoTag = "video"
  /// The chosen video's file name (it isn't kept between launches). With Video chosen and no
  /// video, the camera shows as it is.
  private(set) var videoName: String?
  /// The scenes the renderer offers (none if it failed to start).
  var sceneChoices: [SceneInfo] { pipeline.scenes == nil ? [] : SceneRenderer.scenes }
  /// The scene being shown, nil while the video is.
  var currentScene: SceneInfo? { sceneChoices.first { $0.identifier == background } }

  // Virtual camera ("WalkScape Camera" for other apps)
  let virtualCameraInstaller = VirtualCameraInstaller()
  private(set) var virtualCameraInstall: VirtualCameraInstallState = .unknown
  private(set) var virtualCameraMessage: String?
  private(set) var virtualCameraConnected = false
  private var virtualCameraProblem: String?

  // Treadmill: the walking speed from a Direct Connect treadmill app (QZ …) over DirCon instead of the
  // slider. Hidden unless Features.treadmill; then always the slider.
  enum SpeedSource: String { case slider, treadmill }
  var speedSource: SpeedSource {
    didSet {
      guard speedSource != oldValue else { return }
      UserDefaults.standard.set(speedSource.rawValue, forKey: "speedSource")
      updateTreadmill()
    }
  }
  /// The chosen source's `TreadmillEndpoint.identifier` ("this-mac", "bonjour:<name>").
  var treadmillSourceID: String {
    didSet {
      guard treadmillSourceID != oldValue else { return }
      UserDefaults.standard.set(treadmillSourceID, forKey: "treadmillSource")
      updateTreadmill()
    }
  }
  private(set) var treadmillConnected = false
  private(set) var treadmillProblem: String?
  /// The last reading's speed while connected (km/h).
  private(set) var treadmillSpeed: Double?
  /// Why the network can't be searched (Local Network access off), if so.
  private(set) var treadmillBrowseProblem: String?
  private var treadmillFound: [TreadmillEndpoint] = []
  private var treadmillLink: TreadmillLink?
  private let treadmillBrowser = TreadmillBrowser()
  private var started = false

  // Window
  var showSettings: Bool {
    didSet { UserDefaults.standard.set(showSettings, forKey: "showSettings") }
  }
  var choosingVideo = false

  // Status
  private(set) var stats = "Starting camera…"
  /// A camera clip being recorded or just saved (File → Record Camera Clip).
  private(set) var recordingClip = false
  private(set) var clipStatus: String?
  private var cameraError: String?
  private var renderError: String?
  private var systemEffects: String?

  /// Problems to show at the top of the settings panel.
  var warnings: [String] {
    let engine = pipeline.engineError.map { "Apple's Video Effects engine is unavailable (\($0)), so Vision does the cutout." }
    let scene = pipeline.scenes?.sceneError.map { "Scene unavailable: \($0)" }
    return [engine, scene, cameraError, renderError, systemEffects].compactMap { $0 }
  }

  private init() {
    let pipeline = Pipeline()
    let defaults = UserDefaults.standard
    self.pipeline = pipeline
    mode = ViewMode(rawValue: min(max(defaults.integer(forKey: "viewMode"), 0), 2)) ?? .both
    // Hidden features (Features) keep their saved choices for when they're shown again.
    cutout = Features.cutoutSwitch ? CutoutEngine(rawValue: defaults.integer(forKey: "cutout")) ?? .videoEffects : .videoEffects
    showSettings = defaults.object(forKey: "showSettings") as? Bool ?? true
    speedSource = Features.treadmill ? defaults.string(forKey: "speedSource").flatMap(SpeedSource.init) ?? .slider : .slider
    treadmillSourceID = defaults.string(forKey: "treadmillSource") ?? TreadmillEndpoint.thisMac.identifier
    // Saved settings → renderer; the saved scene (or the first one) is the background.
    let scenes = pipeline.scenes == nil ? [] : SceneRenderer.scenes
    let savedScene = defaults.string(forKey: "scene")
    let scene = (scenes.first { $0.identifier == savedScene } ?? scenes.first)?.identifier
    background = scene ?? Self.videoTag
    if let renderer = pipeline.scenes {
      for parameter in SceneRenderer.commonParameters {
        renderer.setValue(parameter.savedValue(scene: nil), forKey: parameter.key)
      }
      for info in scenes {
        for parameter in info.parameters {
          renderer.setValue(parameter.savedValue(scene: info.identifier), forParameter: parameter.key, scene: info.identifier)
        }
      }
      if let scene { renderer.sceneID = scene }
    }

    pipeline.mode = mode
    pipeline.cutout = cutout
    pipeline.statsHandler = { [weak self] stats in self?.stats = stats }
    pipeline.renderErrorHandler = { [weak self] message in self?.renderError = message }
    pipeline.virtualCamera.stateHandler = { [weak self] connected, problem in
      self?.virtualCameraConnected = connected
      self?.virtualCameraProblem = problem
    }
    treadmillBrowser.changeHandler = { [weak self] in
      guard let self else { return }
      treadmillFound = treadmillBrowser.endpoints
      treadmillBrowseProblem = treadmillBrowser.problem
    }
    if speedSource == .treadmill { pipeline.scenes?.speedKmh = 0 }  // until the first reading
    virtualCameraInstaller.changeHandler = { [weak self] in
      guard let self else { return }
      virtualCameraInstall = virtualCameraInstaller.state
      virtualCameraMessage = virtualCameraInstaller.message
      // Once installed, the device appears and the pipeline's output connects to it by itself.
    }
  }

  /// Starts the camera and keeps the camera list and the system-effects warning current.
  func start() {
    started = true
    updateTreadmill()
    virtualCameraInstaller.refresh()
    refreshCameras()
    for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshCameras() }
      }
    }
    Task {
      while true {
        checkSystemEffects()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// Saves the next 15 s of raw camera frames to ~/Movies/WalkScape, for reproducing what the
  /// camera saw with `backdrop-test --person <movie> --engine apple|vision`.
  func recordCameraClip() {
    guard !recordingClip else { return }
    let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
    let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/WalkScape/camera-\(stamp).mov")
    recordingClip = true
    clipStatus = "Recording 15 s of camera…"
    pipeline.recordCamera(for: 15, to: url) { [weak self] error in
      MainActor.assumeIsolated {
        self?.recordingClip = false
        self?.clipStatus = error.map { "Camera clip failed: \($0.localizedDescription)" } ?? "Camera clip saved: ~/Movies/WalkScape/\(url.lastPathComponent)"
      }
    }
  }

  func setBackgroundVideo(_ url: URL) {
    pipeline.setBackgroundVideo(url, activate: true)
    videoName = url.lastPathComponent
    background = Self.videoTag
  }

  /// Removes the chosen video (Clear): Video stays chosen, and the camera shows as it is.
  func clearBackgroundVideo() {
    pipeline.setBackgroundVideo(nil, activate: false)
    videoName = nil
  }

  // The saved camera whenever it's connected; else keeps the current one if it's still there,
  // otherwise picks the system default.
  private func refreshCameras() {
    cameras = CameraSource.availableDevices()
    let saved = UserDefaults.standard.string(forKey: "camera")
    if let saved, cameras.contains(where: { $0.uniqueID == saved }) {
      cameraID = saved
      return
    }
    if cameras.contains(where: { $0.uniqueID == cameraID }) { return }
    let preferred = AVCaptureDevice.default(for: .video)?.uniqueID
    cameraID = (cameras.first { $0.uniqueID == preferred } ?? cameras.first)?.uniqueID
  }

  private func startSelectedCamera() {
    guard let device = cameras.first(where: { $0.uniqueID == cameraID }) else { return }
    Task {
      do {
        try await pipeline.startCamera(device)
        cameraError = nil
      } catch {
        cameraError = error.localizedDescription
      }
    }
  }

  /// One line about the virtual camera, for the settings panel.
  var virtualCameraStatus: String {
    if virtualCameraConnected {
      return "On: choose “\(VirtualCameraName)” as the camera in FaceTime, Zoom, Meet or any other video app."
    }
    if let problem = virtualCameraProblem { return problem }
    let message = virtualCameraMessage
    switch virtualCameraInstall {
    case .unknown: return "Checking…"
    case .notInstalled: return message ?? "Lets FaceTime, Zoom, Meet and other video apps use this picture as a camera."
    case .needsApproval:
      return "Allow it in System Settings → General → Login Items & Extensions, under Camera (or Media) Extensions."
    case .installed:
      return message
        ?? "Installed; waiting for WalkScape Camera to start. If it doesn't within a minute, restart the Mac "
        + "(macOS often starts an updated camera only after a restart)."
    case .restartNeeded: return "Restart the Mac to finish."
    case .unavailable: return message ?? "Unavailable."
    @unknown default: return message ?? ""
    }
  }

  // MARK: Treadmill

  /// A DirCon server on this Mac, the sources found on the network, and the chosen one even while it isn't
  /// found (so the picker can show it).
  var treadmillSources: [TreadmillEndpoint] {
    var sources = [TreadmillEndpoint.thisMac] + treadmillFound
    if let chosen = TreadmillEndpoint(identifier: treadmillSourceID), !sources.contains(chosen) { sources.append(chosen) }
    return sources
  }

  /// One line about the treadmill, for the settings panel.
  var treadmillStatus: String {
    let source = TreadmillEndpoint(identifier: treadmillSourceID) ?? .thisMac
    if let problem = treadmillProblem {
      if !treadmillConnected && source == .thisMac {
        return "Waiting for a treadmill app on this Mac to share its data over Direct Connect."
      }
      return problem
    }
    if treadmillConnected, let speed = treadmillSpeed { return String(format: "%.1f km/h from %@", speed, source.name) }
    return treadmillConnected ? "Connected to \(source.name)" : "Connecting to \(source.name)…"
  }

  /// Starts or stops reading the treadmill for the current settings. The speed goes straight to
  /// the renderer, which eases toward it.
  private func updateTreadmill() {
    guard started else { return }
    treadmillLink?.stop()
    treadmillLink = nil
    treadmillConnected = false
    treadmillProblem = nil
    treadmillSpeed = nil
    guard speedSource == .treadmill else {
      treadmillBrowser.stop()
      // Back to the slider's saved speed.
      if let speed = SceneRenderer.commonParameters.first(where: { $0.key == "speedKmh" }) {
        pipeline.scenes?.setValue(speed.savedValue(scene: nil), forKey: speed.key)
      }
      return
    }
    pipeline.scenes?.speedKmh = 0
    treadmillBrowser.start()
    let link = TreadmillLink(endpoint: TreadmillEndpoint(identifier: treadmillSourceID) ?? .thisMac)
    link.stateHandler = { [weak self, weak link] connected, problem in
      guard let self, let link, link === treadmillLink else { return }
      treadmillConnected = connected
      treadmillProblem = problem
      if !connected {
        treadmillSpeed = nil
        pipeline.scenes?.speedKmh = 0
      }
    }
    link.readingHandler = { [weak self, weak link] reading in
      guard let self, let link, link === treadmillLink else { return }
      treadmillSpeed = reading.speedKmh
      pipeline.scenes?.speedKmh = max(reading.speedKmh, 0)
    }
    treadmillLink = link
    link.start()
  }

  func openCameraExtensionSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }

  // The system Video Effects (Control Center) run before frames reach this app, so they would
  // stack with ours. Point that out.
  private func checkSystemEffects() {
    var active: [String] = []
    if let device = pipeline.cameraDevice {  // they stack with either cutout engine
      if device.isPortraitEffectActive { active.append("Portrait") }
      if device.isStudioLightActive { active.append("Studio Light") }
      if device.isBackgroundReplacementActive { active.append("Background") }
    }
    let warning =
      active.isEmpty
      ? nil
      : "System Video Effects are on for this app (\(active.joined(separator: ", "))). "
        + "Turn them off in Control Center → Video Effects, or they run before ours."
    if warning != systemEffects { systemEffects = warning }
  }
}
