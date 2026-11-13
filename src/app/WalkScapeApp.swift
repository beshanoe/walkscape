// WalkScape: camera → Apple's Video Effects engine (Portrait.framework, in-process) with a
// moving 3D scene (forest road, …) or a looping video as the replacement background → preview window.
// The UI is SwiftUI; the frame path is Objective-C (Pipeline, BackdropEngine, SceneRenderer).

import AppKit
import SwiftUI

@main
struct WalkScapeApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  private let model = AppModel.shared

  var body: some Scene {
    Window("WalkScape", id: "main") {
      ContentView(model: model)
    }
    .defaultSize(width: 1300, height: 720)
    .defaultPosition(.center)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(AppModel.snapshotPath == nil ? .presented : .suppressed)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Open Background Video…") { model.choosingVideo = true }
          .keyboardShortcut("o")
        Button("Record Camera Clip (15 s)") { model.recordCameraClip() }
          .disabled(model.recordingClip)
      }
      CommandGroup(after: .appInfo) {
        Button("Remove Virtual Camera…") { model.virtualCameraInstaller.uninstall() }
          .disabled(model.virtualCameraInstall != .installed && model.virtualCameraInstall != .needsApproval)
      }
      CommandGroup(after: .sidebar) {
        Button(model.showSettings ? "Hide Settings" : "Show Settings") { model.showSettings.toggle() }
          .keyboardShortcut("i", modifiers: [.command, .option])
      }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var snapshotWindow: NSWindow?

  func applicationWillFinishLaunching(_ notification: Notification) {
    // No Dock icon while taking a snapshot.
    if AppModel.snapshotPath != nil { NSApp.setActivationPolicy(.prohibited) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let path = AppModel.snapshotPath {
      writeSnapshot(to: path)
    } else {
      AppModel.shared.start()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
    true
  }

  // The SwiftUI window is suppressed in snapshot mode; the same view goes into a window placed
  // far outside every display.
  private func writeSnapshot(to path: String) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1300, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "WalkScape"
    window.contentView = NSHostingView(rootView: ContentView(model: AppModel.shared))
    snapshotWindow = window
    Task {
      // Creating the window off screen and ordering it in at once gave no image; moving it and
      // ordering it in after launch has settled works.
      try? await Task.sleep(for: .milliseconds(300))
      window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
      window.orderFrontRegardless()
      try? await Task.sleep(for: .milliseconds(500))
      let rep = Self.windowServerImage(of: window) ?? Self.cachedImage(of: window)
      if rep == nil { print("snapshot: could not capture the window") }
      try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      NSApp.terminate(nil)
    }
  }

  // The whole window as the window server composites it, title bar included. An app may capture
  // its own windows without the Screen Recording permission. CGWindowListCreateImage is marked
  // obsolete in the macOS 15 SDK (ScreenCaptureKit would need the permission), so look it up at
  // runtime.
  private static func windowServerImage(of window: NSWindow) -> NSBitmapImageRep? {
    typealias CreateImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }  // RTLD_DEFAULT
    let createImage = unsafeBitCast(symbol, to: CreateImage.self)
    let image = createImage(
      .null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber),
      CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue)
    return image.map { NSBitmapImageRep(cgImage: $0.takeRetainedValue()) }
  }

  // Fallback: AppKit drawing of the content view. Misses vibrancy (grey labels, popup and slider
  // chrome, check marks).
  private static func cachedImage(of window: NSWindow) -> NSBitmapImageRep? {
    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
  }
}
