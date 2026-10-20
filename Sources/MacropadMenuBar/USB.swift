import Foundation
import IOKit
import IOKit.usb
import PadUSBC
import MacropadCore

enum PadUSBError: LocalizedError {
    case notConnected
    case noConfigEndpoint([String])
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            L("Macropad não encontrado (USB 1189:8890). Ele está conectado?")
        case .noConfigEndpoint(let details):
            L("Não achei o canal de configuração do pad.") + (details.isEmpty ? "" : "\n" + details.joined(separator: "\n"))
        case .writeFailed(let detail):
            L("Falha ao gravar no pad: %@. Tente de novo.", detail)
        }
    }
}

/// Raw USB access to the pad's config channel.
///
/// The config channel is a HID-class interface whose only endpoint is an interrupt OUT pipe.
/// macOS binds no driver to it, so IOUSBLib can open the interface directly — no
/// permissions or entitlements needed for a non-sandboxed app.
enum PadUSB {
    static func matching(_ className: String) -> CFDictionary {
        let dict = IOServiceMatching(className) as NSMutableDictionary
        dict["idVendor"] = PadProtocol.vendorID
        dict["idProduct"] = PadProtocol.productID
        return dict
    }

    static var isConnected: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching("IOUSBHostDevice"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    /// Writes `packets` in order to the first interface that has an interrupt OUT endpoint
    /// (interface 1 on real hardware). Done in C with IOUSBLib — the API libusb uses — see
    /// Sources/PadUSBC/padusb.c.
    static func send(_ packets: [[UInt8]]) throws {
        let flat = packets.flatMap { $0 }
        var err = [CChar](repeating: 0, count: 2048)
        let result = flat.withUnsafeBufferPointer { buffer in
            padusb_send(UInt16(PadProtocol.vendorID), UInt16(PadProtocol.productID),
                        buffer.baseAddress, packets.count, PadProtocol.packetSize, &err, err.count)
        }
        let detail = String(cString: err).trimmingCharacters(in: .whitespacesAndNewlines)
        switch Int(result) {
        case Int(PADUSB_OK): return
        case Int(PADUSB_NOT_FOUND): throw PadUSBError.notConnected
        case Int(PADUSB_WRITE_FAILED): throw PadUSBError.writeFailed(detail)
        default: throw PadUSBError.noConfigEndpoint(detail.split(separator: "\n").map(String.init))
        }
    }
}

/// Watches the USB bus for the pad being plugged in or removed.
final class PadMonitor {
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var count = 0
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let added: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<PadMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.count += PadMonitor.drain(iterator)
            monitor.onChange(monitor.count > 0)
        }
        let removed: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<PadMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.count = max(0, monitor.count - PadMonitor.drain(iterator))
            monitor.onChange(monitor.count > 0)
        }

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, PadUSB.matching("IOUSBHostDevice"),
                                         added, refcon, &addedIterator)
        count = PadMonitor.drain(addedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, PadUSB.matching("IOUSBHostDevice"),
                                         removed, refcon, &removedIterator)
        _ = PadMonitor.drain(removedIterator)
        onChange(count > 0)
    }

    private static func drain(_ iterator: io_iterator_t) -> Int {
        var n = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            n += 1
        }
        return n
    }

    deinit {
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let port { IONotificationPortDestroy(port) }
    }
}
