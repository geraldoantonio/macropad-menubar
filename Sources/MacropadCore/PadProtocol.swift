/// The pad's slots. Raw values match the `macropad` CLI and its layout file.
public enum Slot: String, CaseIterable, Identifiable, Sendable {
    case key1, key2, key3, key4, key5, key6
    case knobLeft = "knob-left"
    case knobPress = "knob-press"
    case knobRight = "knob-right"

    public var id: String { rawValue }

    /// The slot ID the firmware uses: buttons 1–6, knob 13–15.
    public var deviceID: UInt8 {
        switch self {
        case .key1: 1
        case .key2: 2
        case .key3: 3
        case .key4: 4
        case .key5: 5
        case .key6: 6
        case .knobLeft: 13
        case .knobPress: 14
        case .knobRight: 15
        }
    }

    public var title: String {
        switch self {
        case .key1, .key2, .key3, .key4, .key5, .key6: L("Tecla %@", String(rawValue.dropFirst(3)))
        case .knobLeft: L("Knob ↺ esquerda")
        case .knobPress: L("Knob pressionar")
        case .knobRight: L("Knob ↻ direita")
        }
    }
}

/// Builds the 64-byte packets written to the pad's config endpoint.
///
/// Decoded from the vendor's Windows tool by the `macropad` CLI (see its `docs/protocol.md`).
/// Each packet is report ID 0x03, then the payload, zero-padded to 64 bytes.
/// Binding one slot = select layer, one or more binding payloads, commit.
public enum PadProtocol {
    public static let vendorID = 0x1189
    public static let productID = 0x8890
    public static let reportID: UInt8 = 0x03
    public static let packetSize = 64
    public static let layers = 1...3
    public static let ledModes = 0...2

    private static let typeKeys: UInt8 = 0x1
    private static let typeMedia: UInt8 = 0x2
    private static let typeMouse: UInt8 = 0x3
    private static let typeLED: UInt8 = 0x8
    private static let selectLayer: UInt8 = 0xA1
    private static let commit: UInt8 = 0xAA
    private static let commitKeys: UInt8 = 0xAA
    private static let commitLED: UInt8 = 0xA1
    private static let ledTarget: UInt8 = 0xB0

    /// Packets that bind `action` to `slot` on `layer`; nil clears the slot.
    public static func bindPackets(slot: Slot, layer: Int, action: Action?) -> [[UInt8]] {
        precondition(layers.contains(layer), "layer must be 1–3")
        let id = slot.deviceID
        var body: [[UInt8]]
        switch action ?? .empty {
        case .media(let code):
            body = [packet(id, kind(layer, typeMedia), UInt8(code & 0xFF), UInt8(code >> 8))]
        case .mouse(let buttons, let wheel, let mods):
            body = [packet(id, kind(layer, typeMouse), buttons, 0, 0, UInt8(bitPattern: wheel), mods)]
        case .keys(let steps):
            let count = UInt8(steps.count)
            // Index 0 carries only the first step's modifiers; indexes 1…n are the keystrokes.
            body = [packet(id, kind(layer, typeKeys), count, 0, steps[0].mods, 0)]
            for (i, step) in steps.enumerated() {
                body.append(packet(id, kind(layer, typeKeys), count, UInt8(i + 1), step.mods, step.code))
            }
        }
        return [packet(selectLayer, UInt8(layer))] + body + [packet(commit, commitKeys)]
    }

    /// Packets that set the backlight: 0 off, 1 last-pressed key lit, 2 rainbow wave.
    public static func ledPackets(mode: Int) -> [[UInt8]] {
        precondition(ledModes.contains(mode), "LED mode must be 0–2")
        return [
            packet(selectLayer, 1),
            packet(ledTarget, kind(1, typeLED), UInt8(mode)),
            packet(commit, commitLED),
        ]
    }

    /// Every packet needed to make the pad match `layout`; slots it doesn't map are cleared.
    ///
    /// Some pads ignore the layer and keep the last write to each slot, so clears go first
    /// and layer 1 goes last (same order as `macropad apply`).
    public static func applyPackets(_ layout: Layout) throws -> [[UInt8]] {
        var bindings: [(layer: Int, slot: Slot, action: Action?)] = []
        for layer in layers {
            for slot in Slot.allCases {
                let action = try layout.text(layer: layer, slot: slot).map { try Action(parsing: $0) }
                bindings.append((layer, slot, action))
            }
        }
        let ordered = bindings.enumerated().sorted { a, b in
            let ka = (a.element.action != nil ? 1 : 0, -a.element.layer)
            let kb = (b.element.action != nil ? 1 : 0, -b.element.layer)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        var packets = ordered.flatMap { bindPackets(slot: $0.slot, layer: $0.layer, action: $0.action) }
        if let led = layout.led { packets += ledPackets(mode: led) }
        return packets
    }

    /// Temporary mapping used to learn the physical layout: key1–6 type 1–6, knob types 7/8/9.
    public static let identifyMapping: [(Slot, String)] = [
        (.key1, "1"), (.key2, "2"), (.key3, "3"), (.key4, "4"), (.key5, "5"), (.key6, "6"),
        (.knobLeft, "7"), (.knobPress, "8"), (.knobRight, "9"),
    ]

    public static func identifyPackets() -> [[UInt8]] {
        identifyMapping.flatMap { slot, text in
            bindPackets(slot: slot, layer: 1, action: try? Action(parsing: text))
        }
    }

    private static func kind(_ layer: Int, _ type: UInt8) -> UInt8 { UInt8(layer << 4) | type }

    private static func packet(_ payload: UInt8...) -> [UInt8] {
        var bytes = [reportID] + payload
        bytes += Array(repeating: 0, count: packetSize - bytes.count)
        return bytes
    }
}
