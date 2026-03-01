import SwiftUI

struct ChromaticKeyboardView: View {
    @EnvironmentObject var vm: SamplerViewModel
    @State private var activeKeys: Set<Int> = []

    // Note names for display
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    // Computer keyboard mapping: 2 octaves
    // Lower row: A-L for white keys (C3 to C4), W-U for black keys
    // Upper row: same pattern shifted up an octave
    private static let whiteKeyMap: [(key: String, semitone: Int)] = [
        ("A", -12), ("S", -10), ("D", -8), ("F", -7), ("G", -5), ("H", -3), ("J", -1),
        ("K", 0), ("L", 2), (";", 4), ("'", 5)
    ]
    private static let blackKeyMap: [(key: String, semitone: Int)] = [
        ("W", -11), ("E", -9), ("T", -6), ("Y", -4), ("U", -2),
        ("O", 1), ("P", 3)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Chromatic Keyboard")
                    .font(.headline)
                Spacer()

                // Octave shift
                HStack(spacing: 4) {
                    Button(action: { vm.keyboardOctave = max(-3, vm.keyboardOctave - 1) }) {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("Oct \(vm.keyboardOctave >= 0 ? "+" : "")\(vm.keyboardOctave)")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50)

                    Button(action: { vm.keyboardOctave = min(3, vm.keyboardOctave + 1) }) {
                        Image(systemName: "chevron.up")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: { vm.stopAllKeyboardNotes() }) {
                    Label("Panic", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }

            if vm.sampleFile == nil {
                Text("Load a sample to use the keyboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                // Info
                if let key = vm.sampleFile?.keyDisplay {
                    HStack(spacing: 8) {
                        Text("Detected key: \(key)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if vm.loopEnabled, vm.loopRegion != nil {
                            Text("• Playing loop region")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                // On-screen piano keyboard — 2 octaves
                PianoKeyboard(
                    octaveOffset: vm.keyboardOctave,
                    activeKeys: activeKeys,
                    onKeyDown: { keyIndex, semitone in
                        let shifted = semitone + (vm.keyboardOctave * 12)
                        activeKeys.insert(keyIndex)
                        vm.playKeyboardNote(keyIndex: keyIndex, semitoneOffset: shifted)
                    },
                    onKeyUp: { keyIndex in
                        activeKeys.remove(keyIndex)
                        vm.stopKeyboardNote(keyIndex: keyIndex)
                    }
                )
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Computer keyboard hint
                Text("Keys: A-; (white) / W E T Y U O P (black) / Z/X (octave down/up)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(KeyboardNoteListener(onKeyDown: { char in
            handleKeyDown(char)
        }, onKeyUp: { char in
            handleKeyUp(char)
        }))
    }

    private func handleKeyDown(_ char: Character) {
        let upper = String(char).uppercased()

        // Z/X for octave change
        if upper == "Z" {
            vm.keyboardOctave = max(-3, vm.keyboardOctave - 1)
            return
        }
        if upper == "X" {
            vm.keyboardOctave = min(3, vm.keyboardOctave + 1)
            return
        }

        // Check white keys
        if let mapping = Self.whiteKeyMap.first(where: { $0.key == upper }) {
            let keyIndex = mapping.semitone + 12 // offset to 0-24 range
            let shifted = mapping.semitone + (vm.keyboardOctave * 12)
            activeKeys.insert(keyIndex)
            vm.playKeyboardNote(keyIndex: keyIndex, semitoneOffset: shifted)
            return
        }

        // Check black keys
        if let mapping = Self.blackKeyMap.first(where: { $0.key == upper }) {
            let keyIndex = mapping.semitone + 12
            let shifted = mapping.semitone + (vm.keyboardOctave * 12)
            activeKeys.insert(keyIndex)
            vm.playKeyboardNote(keyIndex: keyIndex, semitoneOffset: shifted)
            return
        }
    }

    private func handleKeyUp(_ char: Character) {
        let upper = String(char).uppercased()

        if let mapping = Self.whiteKeyMap.first(where: { $0.key == upper }) {
            let keyIndex = mapping.semitone + 12
            activeKeys.remove(keyIndex)
            vm.stopKeyboardNote(keyIndex: keyIndex)
            return
        }

        if let mapping = Self.blackKeyMap.first(where: { $0.key == upper }) {
            let keyIndex = mapping.semitone + 12
            activeKeys.remove(keyIndex)
            vm.stopKeyboardNote(keyIndex: keyIndex)
            return
        }
    }
}

// MARK: - Piano Keyboard View

struct PianoKeyboard: View {
    let octaveOffset: Int
    let activeKeys: Set<Int>
    let onKeyDown: (Int, Int) -> Void  // (keyIndex, semitoneOffset)
    let onKeyUp: (Int) -> Void

    // 2 octaves: 14 white keys + 10 black keys
    private let whiteNotes: [(semitone: Int, name: String)] = {
        var notes: [(Int, String)] = []
        let pattern = [0, 2, 4, 5, 7, 9, 11]
        let names = ["C", "D", "E", "F", "G", "A", "B"]
        for oct in 0..<2 {
            for i in 0..<7 {
                notes.append((pattern[i] + oct * 12 - 12, "\(names[i])\(3 + oct)"))
            }
        }
        notes.append((12, "C5"))  // Top C
        return notes
    }()

    private let blackNotes: [(semitone: Int, position: CGFloat)] = {
        var notes: [(Int, CGFloat)] = []
        // Black key positions relative to white keys (0-indexed)
        let blackPattern: [(semitone: Int, afterWhiteIdx: Int)] = [
            (1, 0), (3, 1), (6, 3), (8, 4), (10, 5)
        ]
        for oct in 0..<2 {
            for bp in blackPattern {
                let s = bp.semitone + oct * 12 - 12
                let whitePos = CGFloat(bp.afterWhiteIdx + oct * 7)
                notes.append((s, whitePos + 0.65))
            }
        }
        return notes
    }()

    var body: some View {
        GeometryReader { geo in
            let whiteKeyWidth = geo.size.width / CGFloat(whiteNotes.count)
            let blackKeyWidth = whiteKeyWidth * 0.6
            let blackKeyHeight = geo.size.height * 0.6

            ZStack(alignment: .topLeading) {
                // White keys
                HStack(spacing: 1) {
                    ForEach(0..<whiteNotes.count, id: \.self) { i in
                        let note = whiteNotes[i]
                        let keyIndex = note.semitone + 12
                        let isActive = activeKeys.contains(keyIndex)

                        Rectangle()
                            .fill(isActive ? Color.blue.opacity(0.5) : Color.white)
                            .overlay(
                                VStack {
                                    Spacer()
                                    Text(note.name)
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(.gray)
                                        .padding(.bottom, 4)
                                }
                            )
                            .overlay(
                                Rectangle()
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        if !activeKeys.contains(keyIndex) {
                                            onKeyDown(keyIndex, note.semitone)
                                        }
                                    }
                                    .onEnded { _ in
                                        onKeyUp(keyIndex)
                                    }
                            )
                    }
                }

                // Black keys
                ForEach(0..<blackNotes.count, id: \.self) { i in
                    let note = blackNotes[i]
                    let keyIndex = note.semitone + 12
                    let isActive = activeKeys.contains(keyIndex)
                    let xPos = note.position * whiteKeyWidth

                    Rectangle()
                        .fill(isActive ? Color.blue : Color(white: 0.15))
                        .frame(width: blackKeyWidth, height: blackKeyHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .offset(x: xPos - blackKeyWidth / 2)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if !activeKeys.contains(keyIndex) {
                                        onKeyDown(keyIndex, note.semitone)
                                    }
                                }
                                .onEnded { _ in
                                    onKeyUp(keyIndex)
                                }
                        )
                }
            }
        }
    }
}

// MARK: - Keyboard Listener (key up + key down)

struct KeyboardNoteListener: NSViewRepresentable {
    let onKeyDown: (Character) -> Void
    let onKeyUp: (Character) -> Void

    func makeNSView(context: Context) -> KeyNoteListenerNSView {
        let view = KeyNoteListenerNSView()
        view.onKeyDown = onKeyDown
        view.onKeyUp = onKeyUp
        return view
    }

    func updateNSView(_ nsView: KeyNoteListenerNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        nsView.onKeyUp = onKeyUp
    }
}

class KeyNoteListenerNSView: NSView {
    var onKeyDown: ((Character) -> Void)?
    var onKeyUp: ((Character) -> Void)?

    private var heldKeys: Set<UInt16> = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Prevent key repeat from firing multiple downs
        guard !event.isARepeat else { return }
        guard let chars = event.characters?.lowercased(), let char = chars.first else {
            super.keyDown(with: event)
            return
        }
        let validKeys: Set<Character> = Set("asdfghjkl;'wetyuopzx ".map { $0 })
        if validKeys.contains(char) {
            heldKeys.insert(event.keyCode)
            onKeyDown?(char)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let chars = event.characters?.lowercased(), let char = chars.first else {
            super.keyUp(with: event)
            return
        }
        if heldKeys.contains(event.keyCode) {
            heldKeys.remove(event.keyCode)
            onKeyUp?(char)
        } else {
            super.keyUp(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
