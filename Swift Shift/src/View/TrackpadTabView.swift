import SwiftUI

private struct PreferenceSlider: View {
  @Binding var value: Double
  let range: ClosedRange<Double>
  let title: String
  let valueLabel: String
  let lowLabel: String
  let highLabel: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title)
          .font(.system(size: 12, weight: .medium))
        Spacer()
        Text(valueLabel)
          .font(.system(size: 11))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: range) {
        EmptyView()
      } minimumValueLabel: {
        Text(lowLabel).font(.system(size: 10)).foregroundStyle(.tertiary)
      } maximumValueLabel: {
        Text(highLabel).font(.system(size: 10)).foregroundStyle(.tertiary)
      }
      .controlSize(.small)
    }
  }
}

struct TrackpadTabView: View {
  @ObservedObject private var monitor = TrackpadGestureMonitor.shared

  @AppStorage(PreferenceKey.swipeDownMinimize.rawValue) private var swipeDownMinimize = true
  @AppStorage(PreferenceKey.swipeLength.rawValue) private var swipeLength = 0.12
  @AppStorage(PreferenceKey.swipeActsOnBackgroundWindows.rawValue) private var actOnBackgroundWindows = true
  @AppStorage(PreferenceKey.swipeShowsDesktopOnFullScreen.rawValue) private var showDesktopOnFullScreen = true

  @AppStorage(PreferenceKey.twoFingerHoldMove.rawValue) private var holdToMove = false
  @AppStorage(PreferenceKey.twoFingerHoldDuration.rawValue) private var holdDuration = 0.45
  @AppStorage(PreferenceKey.twoFingerHoldSpeed.rawValue) private var holdSpeed = 1.2

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        SectionHeader(title: "Trackpad", icon: "hand.draw")
        Text("Gestures that act on the window under the cursor.")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }

      PreferenceToggle(
        isOn: $swipeDownMinimize,
        title: "Swipe down with three fingers",
        subtitle: "Drop the window into the Dock",
        icon: "arrow.down.to.line"
      )

      if swipeDownMinimize {
        VStack(alignment: .leading, spacing: 8) {
          PreferenceSlider(
            value: $swipeLength,
            range: 0.04...0.30,
            title: "Swipe length",
            valueLabel: "\(Int((swipeLength * 100).rounded()))%",
            lowLabel: "Short",
            highLabel: "Long"
          )

          swipeIndicator

          PreferenceToggle(
            isOn: $actOnBackgroundWindows,
            title: "Background apps too",
            subtitle: "Off: only the active app's windows",
            icon: "macwindow.on.rectangle"
          )

          PreferenceToggle(
            isOn: $showDesktopOnFullScreen,
            title: "Show the desktop on full screen",
            subtitle: "Full-screen windows can't be minimized",
            icon: "desktopcomputer"
          )
        }
        .padding(.leading, 26)
      }

      Divider().opacity(0.5)

      PreferenceToggle(
        isOn: $holdToMove,
        title: "Hold two fingers, then drag",
        subtitle: "Move the window without a keyboard shortcut",
        icon: "hand.point.up.left"
      )

      if holdToMove {
        VStack(alignment: .leading, spacing: 8) {
          PreferenceSlider(
            value: $holdDuration,
            range: 0.25...1.0,
            title: "Hold time",
            valueLabel: String(format: "%.2f s", holdDuration),
            lowLabel: "Quick",
            highLabel: "Deliberate"
          )

          PreferenceSlider(
            value: $holdSpeed,
            range: 0.5...3.0,
            title: "Speed",
            valueLabel: String(format: "%.1f×", holdSpeed),
            lowLabel: "Slow",
            highLabel: "Fast"
          )

          holdIndicator
        }
        .padding(.leading, 26)
      }

      Divider().opacity(0.5)

      Text("If macOS also triggers App Exposé, set that gesture to four fingers in System Settings › Trackpad › More Gestures.")
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .onAppear { monitor.isObserving = true }
    .onDisappear { monitor.isObserving = false }
  }

  private var swipeIndicator: some View {
    HStack(spacing: 8) {
      Text("\(monitor.fingerCount) finger\(monitor.fingerCount == 1 ? "" : "s")")
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(monitor.fingerCount == 3 ? .primary : .secondary)
        .frame(width: 64, alignment: .leading)
      ProgressView(value: monitor.swipeProgress)
    }
  }

  private var holdIndicator: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(holdIndicatorColor)
        .frame(width: 7, height: 7)
      Text(holdIndicatorText)
        .font(.system(size: 11))
        .foregroundStyle(monitor.holdIndicator == .idle ? .secondary : .primary)
    }
  }

  private var holdIndicatorText: String {
    switch monitor.holdIndicator {
    case .idle: return "Rest two fingers on the trackpad"
    case .holding: return "Holding…"
    case .grabbed: return "Grabbed — drag to move"
    }
  }

  private var holdIndicatorColor: Color {
    switch monitor.holdIndicator {
    case .idle: return .secondary.opacity(0.4)
    case .holding: return .orange
    case .grabbed: return .green
    }
  }
}

#Preview {
  TrackpadTabView().frame(width: MAIN_WINDOW_WIDTH)
}
