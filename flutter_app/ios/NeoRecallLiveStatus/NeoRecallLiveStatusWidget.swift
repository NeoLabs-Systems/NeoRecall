import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NeoRecallLiveStatusBundle: WidgetBundle {
  var body: some Widget {
    NeoRecallLiveStatusWidget()
  }
}

struct NeoRecallLiveStatusWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: NeoRecallLiveStatusAttributes.self) { context in
      LockScreenStatusView(state: context.state)
        .activityBackgroundTint(Color(red: 0.055, green: 0.047, blue: 0.11))
        .activitySystemActionForegroundColor(.white)
        .widgetURL(URL(string: "neorecall://status"))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          PhaseMark(phase: context.state.phase, size: 28)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if let startedAt = context.state.recordingStartedAt,
             context.state.phase == "recording" {
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
              .font(.system(.caption, design: .rounded, weight: .semibold))
              .monospacedDigit()
              .foregroundStyle(.cyan)
          }
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.title)
            .font(.headline)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 8) {
            Text(context.state.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
            StatusProgress(state: context.state)
            StopControl(state: context.state)
          }
        }
      } compactLeading: {
        PhaseMark(phase: context.state.phase, size: 18)
      } compactTrailing: {
        CompactValue(state: context.state)
      } minimal: {
        PhaseMark(phase: context.state.phase, size: 16)
      }
      .widgetURL(URL(string: "neorecall://status"))
      .keylineTint(.cyan)
    }
  }
}

private struct LockScreenStatusView: View {
  let state: NeoRecallLiveStatusAttributes.ContentState

  var body: some View {
    HStack(spacing: 14) {
      PhaseMark(phase: state.phase, size: 34)
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(state.title)
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .lineLimit(1)
          Spacer(minLength: 8)
          CompactValue(state: state)
        }
        Text(state.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        StatusProgress(state: state)
      }
      StopControl(state: state)
    }
    .padding(16)
  }
}

private struct PhaseMark: View {
  let phase: String
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle().fill(color.opacity(0.2))
      Circle().stroke(color.opacity(0.75), lineWidth: 1)
      Image(systemName: icon)
        .font(.system(size: size * 0.45, weight: .semibold))
        .foregroundStyle(color)
    }
    .frame(width: size, height: size)
  }

  private var color: Color {
    phase == "storageFull" ? .red : phase == "recording" ? .cyan : .purple
  }

  private var icon: String {
    switch phase {
    case "recording": return "waveform"
    case "watchTransfer": return "applewatch.radiowaves.left.and.right"
    case "uploading": return "arrow.up.circle.fill"
    case "transcribing": return "text.bubble.fill"
    case "finalizing": return "checkmark.seal.fill"
    case "storageFull": return "externaldrive.badge.exclamationmark"
    case "connected": return "link"
    default: return "clock.fill"
    }
  }
}

private struct CompactValue: View {
  let state: NeoRecallLiveStatusAttributes.ContentState

  var body: some View {
    if let startedAt = state.recordingStartedAt, state.phase == "recording" {
      Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
        .monospacedDigit()
    } else if let progress = state.progress {
      Text(progress, format: .percent.precision(.fractionLength(0)))
    } else if let eta = state.etaSeconds, eta > 0 {
      Text("~\(max(1, (eta + 59) / 60))m")
    } else {
      Image(systemName: state.phase == "storageFull" ? "exclamationmark" : "ellipsis")
    }
  }
}

private struct StatusProgress: View {
  let state: NeoRecallLiveStatusAttributes.ContentState

  @ViewBuilder
  var body: some View {
    if let progress = state.progress {
      ProgressView(value: progress)
        .tint(state.phase == "storageFull" ? .red : .cyan)
    } else if ["watchTransfer", "uploading", "transcribing", "finalizing"].contains(state.phase) {
      ProgressView().tint(.cyan)
    }
  }
}

private struct StopControl: View {
  let state: NeoRecallLiveStatusAttributes.ContentState

  @ViewBuilder
  var body: some View {
    if state.phase == "recording" {
      if #available(iOSApplicationExtension 17.0, *) {
        Button(intent: StopNeoRecallIntent()) {
          Image(systemName: "stop.fill")
            .font(.caption.bold())
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .accessibilityLabel("Stop recording")
      }
    }
  }
}
