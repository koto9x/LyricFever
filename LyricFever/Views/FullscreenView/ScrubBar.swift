//
//  ScrubBar.swift
//  Lyric Fever
//
//  Draggable playback scrubber for the FullscreenView. Lives between the
//  artist label and the volume / play / lyric-tool buttons. Renders a thin
//  horizontal track + draggable thumb + `mm:ss / mm:ss` time labels. Drag
//  to seek the current player (Apple Music / Spotify / Plexamp), release to
//  commit. Updates live from `viewmodel.currentTime` while not being dragged.
//

import SwiftUI

#if os(macOS)
struct ScrubBar: View {
    @Environment(ViewModel.self) var viewmodel
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var tick = Date()

    /// Drives a 0.5s timer so the slider crawls forward while playing without
    /// us having to listen to every player-state change. SwiftUI re-renders
    /// when `tick` changes; the binding's getter pulls the freshest
    /// `currentTime` from the player on each render.
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var totalMs: Double {
        Double(max(viewmodel.duration, 1))
    }

    private var currentMs: Double {
        // While dragging we surface the user's in-flight drag value so the
        // thumb stays where their finger is. Otherwise read the live player
        // position; the @State `tick` re-render keeps this fresh.
        if isDragging { return dragValue }
        if let live = viewmodel.currentPlayerInstance.currentTime { return live }
        return viewmodel.currentTime.currentTime
    }

    var body: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { currentMs },
                    set: { newValue in
                        dragValue = newValue
                    }
                ),
                in: 0...totalMs,
                onEditingChanged: { editing in
                    if editing {
                        isDragging = true
                    } else {
                        // Commit the seek when the drag ends.
                        viewmodel.currentPlayerInstance.seek(toMillis: Int(dragValue))
                        viewmodel.currentTime = CurrentTimeWithStoredDate(currentTime: dragValue)
                        // Tiny delay so the player has a moment to update before
                        // we switch the slider back to "live read" mode.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            isDragging = false
                        }
                    }
                }
            )
            .controlSize(.mini)
            .tint(.white.opacity(0.85))
            HStack {
                Text(format(currentMs))
                Spacer()
                Text(format(totalMs))
            }
            .font(.system(size: 11, weight: .light, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
        }
        .onReceive(timer) { _ in tick = Date() }
    }

    private func format(_ ms: Double) -> String {
        let total = Int(ms / 1000)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
#endif
