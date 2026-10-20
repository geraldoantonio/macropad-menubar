import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import MacropadCore

enum PadUSBError: LocalizedError {
    case notConnected
    case noConfigEndpoint([String])
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Macropad não encontrado (USB 1189:8890). Ele está conectado?"
        case .noConfigEndpoint(let details):
            "Não achei o canal de configuração do pad." + (details.isEmpty ? "" : "\n" + details.joined(separator: "\n"))
        case .writeFailed(let detail):
            "Falha ao gravar no pad: \(detail). Tente de novo."
        }
    }
}

/// Raw USB access to the pad's config channel.
///
/// The config channel is a HID-class interface whose only endpoint is an interrupt OUT pipe.
/// macOS binds no driver to it, so IOUSBHost can open the interface directly — no
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

    /// Writes `packets` in order to the first interface that has an interrupt OUT endpoint.
    static func send(_ packets: [[UInt8]]) throws {
        guard isConnected else { throw PadUSBError.notConnected }

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching("IOUSBHostInterface"), &iterator)
        guard kr == KERN_SUCCESS else { throw PadUSBError.noConfigEndpoint(["IOKit: 0x\(String(kr, radix: 16))"]) }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 { services.append(service) }
        defer { services.forEach { IOObjectRelease($0) } }
        // Interfaces with no driver attached first: on real hardware that's interface 1, the
        // config channel. The HID ones (0, 2, 3) are only tried as a fallback.
        services.sort { !hasDriver($0) && hasDriver($1) }

        var notes: [String] = []
        for service in services {
            let number = interfaceNumber(service)

            let interface: IOUSBHostInterface
            do {
                interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            } catch {
                // Interfaces 0, 2 and 3 belong to the HID driver; opening them fails, which is fine.
                notes.append("interface \(number): \(error.localizedDescription)")
                continue
            }
            defer { interface.destroy() }

            guard let pipe = interruptOutPipe(of: interface) else {
                notes.append("interface \(number): sem endpoint de saída")
                continue
            }
            for (index, packet) in packets.enumerated() {
                let data = NSMutableData(bytes: packet, length: packet.count)
                var transferred = 0
                do {
                    try pipe.__sendIORequest(with: data, bytesTransferred: &transferred, completionTimeout: 1.0)
                } catch {
                    throw PadUSBError.writeFailed("pacote \(index + 1) de \(packets.count) (\(error.localizedDescription))")
                }
                if transferred != packet.count {
                    throw PadUSBError.writeFailed("pacote \(index + 1) gravou \(transferred) de \(packet.count) bytes")
                }
            }
            return
        }
        throw PadUSBError.noConfigEndpoint(notes)
    }

    private static func interruptOutPipe(of interface: IOUSBHostInterface) -> IOUSBHostPipe? {
        for address in 1...15 {
            guard let pipe = try? interface.copyPipe(withAddress: address) else { continue }
            let attributes = pipe.descriptors.pointee.descriptor.bmAttributes
            if attributes & 0x03 == 0x03 { return pipe }
        }
        return nil
    }

    private static func hasDriver(_ service: io_service_t) -> Bool {
        var child: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(service, kIOServicePlane, &child) == KERN_SUCCESS else { return false }
        IOObjectRelease(child)
        return true
    }

    private static func interfaceNumber(_ service: io_service_t) -> String {
        let value = IORegistryEntryCreateCFProperty(service, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.stringValue ?? "?"
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
