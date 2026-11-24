import SwiftUI
import ZittoCore

/// The right side of the window: the song that is open, its parts, the transport.
struct PlayerView: View {
    @ObservedObject var player: PlayerModel
    @State private var assigning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 0) {
                    PartControlsView(player: player, height: geometry.size.height)
                        .frame(width: 190)
                    WaveformHost(view: player.wave)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            transport
            foot
        }
        .background(Color.zBg)
        .sheet(isPresented: $assigning, onDismiss: player.stopLearning) {
            MIDIAssignView(player: player)
        }
    }

    private var head: some View {
        HStack(spacing: 0) {
            if player.hasSong {
                Text(player.timeText + "   ")
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundColor(.zText)
            }
            Text(player.hasSong ? player.title : "Add songs on the left. Double-click one to open it.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(player.hasSong ? .zText : .zDim)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button("Rewind") { player.perform("rewind") }.buttonStyle(FlatButtonStyle())
            Button("Play") { player.perform("play") }.buttonStyle(FlatButtonStyle(active: player.transport == .playing))
            Button("Pause") { player.perform("pause") }.buttonStyle(FlatButtonStyle(active: player.transport == .paused))
            Button("Stop") { player.perform("stop") }.buttonStyle(FlatButtonStyle(active: player.transport == .stopped && player.hasSong))
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button("Loop") { player.toggleLoop() }.buttonStyle(FlatButtonStyle(active: player.loopOn))
            Button("Clear") { player.perform("clear_loop") }.buttonStyle(FlatButtonStyle())
            Button("Zoom to loop") { player.wave.showLoop() }.buttonStyle(FlatButtonStyle())
            Button("Show all") { player.wave.showAll() }.buttonStyle(FlatButtonStyle())
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button("Save...") { player.save() }.buttonStyle(FlatButtonStyle()).disabled(player.saving || !player.hasSong)
            Text(player.loopText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.zDim)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var foot: some View {
        HStack(spacing: 8) {
            Text("MIDI").font(.system(size: 12)).foregroundColor(.zDim)
            Picker("", selection: Binding(get: { player.port }, set: { player.choosePort($0) })) {
                ForEach(player.ports, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 200)
            Button("Assign...") { assigning = true }.buttonStyle(FlatButtonStyle())
            Text("Drag: loop   Click: move   Wheel: zoom   Space: play/pause   Numbers: parts")
                .font(.system(size: 11))
                .foregroundColor(.zDim)
                .lineLimit(1)
            Text(player.message)
                .font(.system(size: 11))
                .foregroundColor(.zText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

/// The waveform, which is drawn by AppKit, inside SwiftUI.
struct WaveformHost: NSViewRepresentable {
    let view: WaveformView

    func makeNSView(context: Context) -> WaveformView {
        view
    }

    func updateNSView(_ nsView: WaveformView, context: Context) {}
}

/// Name, mute, solo and volume of each part, beside its lane.
struct PartControlsView: View {
    @ObservedObject var player: PlayerModel
    let height: CGFloat
    static let buttons: CGFloat = 0.6  // share of the height of a row for name and buttons; the rest is the volume
    static let side: CGFloat = 32

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(player.rows.enumerated()), id: \.element) { item in
                let row = item.offset, i = item.element
                let lane = WaveformView.lane(row, of: player.rows.count, height: height)
                PartRow(player: player, index: i, height: max(lane.height - 2, 4))
                    .padding(.leading, player.isPiece(i) ? 16 : 0)
                    .padding(.trailing, 4)
                    .offset(y: lane.top)
            }
        }
    }
}

private struct PartRow: View {
    @ObservedObject var player: PlayerModel
    let index: Int
    let height: CGFloat

    private var name: String { player.names[index] }
    private var heard: Bool { player.audible.indices.contains(index) && player.audible[index] }
    private var muted: Bool { !player.on[index] }
    private var soloed: Bool { player.solo[index] }

    /// Whether M and S are beside each other: in a low row, one over the other they could not be read.
    private var sideBySide: Bool {
        height * PartControlsView.buttons < PartControlsView.side * 0.85
    }

    var body: some View {
        let top = height * PartControlsView.buttons
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                nameButton
                if sideBySide {
                    small("M", on: muted, color: .zBad) { player.togglePart(index) }
                        .frame(width: PartControlsView.side / 2)
                    small("S", on: soloed, color: .zAccent) { player.toggleSolo(index) }
                        .frame(width: PartControlsView.side / 2)
                } else {
                    VStack(spacing: 1) {
                        small("M", on: muted, color: .zBad) { player.togglePart(index) }
                        small("S", on: soloed, color: .zAccent) { player.toggleSolo(index) }
                    }
                    .frame(width: PartControlsView.side)
                }
            }
            .frame(height: top)
            VolumeSlider(value: player.volume[index], color: heard ? Color.part(name) : .zDim) {
                player.setVolume(index, $0)
            }
            .frame(height: height - top)
        }
        .frame(height: height)
        .background(Color.zPanel)
    }

    private var nameButton: some View {
        HStack(spacing: 4) {
            if player.hasPieces(index) {
                Text(player.opened.contains(name) ? "▾" : "▸")
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { player.togglePieces(index) }
            }
            Text(Parts.label(name))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, player.hasPieces(index) ? 4 : 10)
        .foregroundColor(heard ? .zBg : .zDim)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(heard ? Color.part(name) : Color.zButton)
        .contentShape(Rectangle())
        .onTapGesture { player.togglePart(index) }
        .help("Click: mute. M mutes, S plays only the parts that are soloed.")
    }

    private func small(_ text: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(on ? .zBg : .zDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(on ? color : Color.zButton)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// The line under the name of a part: drag to set its volume.
private struct VolumeSlider: View {
    let value: Float
    let color: Color
    let onChange: (Float) -> Void

    var body: some View {
        GeometryReader { geometry in
            let first: CGFloat = 10, last = max(geometry.size.width - 10, 11)
            let x = first + (last - first) * CGFloat(value)
            let y = geometry.size.height / 2
            let knob = min(5, geometry.size.height / 2 - 1)
            ZStack(alignment: .topLeading) {
                Color.zPanel
                Rectangle().fill(Color.zButton).frame(width: last - first, height: 4).offset(x: first, y: y - 2)
                Rectangle().fill(color).frame(width: max(x - first, 0), height: 4).offset(x: first, y: y - 2)
                Rectangle().fill(Color.zText).frame(width: 4, height: max(2 * knob, 2)).offset(x: x - 2, y: y - knob)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(Float(min(max((drag.location.x - first) / (last - first), 0), 1)))
            })
        }
    }
}

/// Learn the buttons of a MIDI device for the transport.
struct MIDIAssignView: View {
    @ObservedObject var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Press Learn, then the button on your device.\nMMC and Start/Continue/Stop messages work without learning.")
                .font(.system(size: 12))
                .foregroundColor(.zDim)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(MIDI.actions, id: \.self) { action in
                    GridRow {
                        Text(action.capitalized).font(.system(size: 13, weight: .semibold)).frame(width: 70, alignment: .leading)
                        let t = player.bindings.get(action)
                        Text(t.map(MIDI.describe) ?? "not assigned")
                            .foregroundColor(t == nil ? .zDim : .zText)
                            .frame(width: 180, alignment: .leading)
                        Button(player.learning == action ? "Waiting..." : "Learn") { player.learn(action) }
                            .buttonStyle(FlatButtonStyle(active: player.learning == action))
                        Button("Clear") { player.unlearn(action) }.buttonStyle(FlatButtonStyle())
                    }
                }
            }
            HStack {
                Text(player.message).font(.system(size: 11)).foregroundColor(.zDim)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
        .background(Color.zBg)
        .foregroundColor(.zText)
    }
}
