// The window: the camera preview, with the settings in an inspector panel on the right.

import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Bindable var model: AppModel

  var body: some View {
    PreviewView(displayLayer: model.pipeline.displayLayer, introLayer: model.pipeline.introLayer, mirrored: model.mirrored) { url in
      model.setBackgroundVideo(url)
    }
    .overlay(alignment: .bottom) {
      if let status = model.previewStatus {
        PreviewStatusView(status: status)
          .frame(maxWidth: 480)  // a longer message wraps; a short one keeps its own width
          .padding(.horizontal, 16)
          .padding(.bottom, 28)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.35), value: model.previewStatus)
    .frame(minWidth: 420, minHeight: 480)
    .inspector(isPresented: $model.showSettings) {
      SettingsPanel(model: model)
        .inspectorColumnWidth(min: 270, ideal: 320, max: 400)
    }
    .frame(minWidth: 720)
    // Check for Updates…'s answer.
    .alert(model.updates.report?.title ?? "", isPresented: updateReportShown, presenting: model.updates.report) { report in
      if report.newer {
        Button("Open Release Page") { model.updates.openReleasePage() }
        Button("Later", role: .cancel) {}
      } else {
        Button("OK", role: .cancel) {}
      }
    } message: { report in
      Text(report.message)
    }
    .fileImporter(isPresented: $model.choosingVideo, allowedContentTypes: [.movie]) { result in
      if case .success(let url) = result { model.setBackgroundVideo(url) }
    }
  }

  private var updateReportShown: Binding<Bool> {
    Binding(get: { model.updates.report != nil }, set: { if !$0 { model.updates.report = nil } })
  }
}

/// What the preview waits for while it starts, or what keeps the camera from showing.
struct PreviewStatusView: View {
  let status: AppModel.PreviewStatus

  var body: some View {
    HStack(spacing: 9) {
      if status.problem {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
      } else {
        ProgressView()
          .controlSize(.small)
      }
      Text(status.text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .environment(\.colorScheme, .dark)  // over the video, whatever the system's appearance
  }
}

/// Shows the pipeline's display layer over its intro layer; accepts a movie file dropped on it as
/// the background.
struct PreviewView: NSViewRepresentable {
  let displayLayer: AVSampleBufferDisplayLayer
  let introLayer: AVSampleBufferDisplayLayer
  var mirrored: Bool
  var onDropVideo: @MainActor (URL) -> Void

  func makeNSView(context: Context) -> PreviewNSView {
    PreviewNSView(displayLayer: displayLayer, introLayer: introLayer)
  }

  func updateNSView(_ view: PreviewNSView, context: Context) {
    view.mirrored = mirrored
    view.onDropVideo = onDropVideo
  }
}

final class PreviewNSView: NSView {
  private let layers: [AVSampleBufferDisplayLayer]  // the intro, then the display layer on top
  var onDropVideo: (@MainActor (URL) -> Void)?
  var mirrored = false {
    didSet {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for layer in layers { layer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity) }
      CATransaction.commit()
    }
  }

  init(displayLayer: AVSampleBufferDisplayLayer, introLayer: AVSampleBufferDisplayLayer) {
    layers = [introLayer, displayLayer]
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    for sublayer in layers { layer?.addSublayer(sublayer) }
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    // bounds + position rather than frame, which is undefined while the layer is mirrored.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in layers {
      layer.bounds = CGRect(origin: .zero, size: bounds.size)
      layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    CATransaction.commit()
  }

  override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation {
    movieURL(info) == nil ? [] : .copy
  }

  override func performDragOperation(_ info: any NSDraggingInfo) -> Bool {
    guard let url = movieURL(info) else { return false }
    onDropVideo?(url)
    return true
  }

  private func movieURL(_ info: any NSDraggingInfo) -> URL? {
    let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    guard let url = urls?.first as? URL, let type = UTType(filenameExtension: url.pathExtension) else { return nil }
    return type.conforms(to: .movie) ? url : nil
  }
}
