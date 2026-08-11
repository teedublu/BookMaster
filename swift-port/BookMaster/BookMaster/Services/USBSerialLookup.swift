import Foundation
import IOKit
import IOKit.usb

/// Resolves a BSD disk name (e.g. "disk4") to the physical USB device's
/// hardware serial number via IOKit, walking up the IORegistry from the
/// disk's IOMedia entry until a USB device node with a serial number
/// property is found. DiskArbitration's own description dictionary
/// doesn't expose this directly, unlike vid/pid/protocol.
///
/// This is what makes "see the history of any block added to the dock"
/// possible: ProductionLog's devices/writes/duplicator_runs tables are
/// all keyed by this exact serial (matching voxmaster's db.py schema).
enum USBSerialLookup {
    static func serialNumber(forBSDName bsdName: String) -> String? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }

        var result: String?
        // Walk up the IOService plane: a disk's IOMedia entry is nested
        // several levels below the actual IOUSBHostDevice/IOUSBDevice
        // node that carries the serial number property. 12 is generous
        // headroom over any real device tree depth seen in practice.
        for _ in 0..<12 {
            if let serial = stringProperty(entry, key: "USB Serial Number"), !serial.isEmpty {
                result = serial
                break
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard status == KERN_SUCCESS, parent != 0 else {
                entry = 0
                break
            }
            entry = parent
        }
        if entry != 0 { IOObjectRelease(entry) }
        return result
    }

    private static func stringProperty(_ entry: io_registry_entry_t, key: String) -> String? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return unmanaged.takeRetainedValue() as? String
    }
}
