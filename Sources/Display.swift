import Cocoa
import IOKit.pwr_mgt

// The optional virtual display while the lid is closed (#37), for agents that work from screenshots: with the lid
// shut and no external display, macOS has no active display and every screenshot is empty. An assertion keeps it
// from sleeping, which also keeps the screen from locking. Both die with the process, so a crash needs no handling.

// The numbers a display reports for itself (from its EDID, or set by whoever created a virtual one).
struct DisplayIdentity: Equatable { let vendor, product, serial: UInt32 }

// Fixed, so macOS keeps a single entry for it in its display configuration.
// 0xDECA has the top bit set, which EDID reserves as 0 in a vendor ID: no real display reports it.
let virtualDisplayIdentity = DisplayIdentity(vendor: 0xDECA, product: 1, serial: 1)

func countsAsExternal(builtin: Bool, _ id: DisplayIdentity) -> Bool { !builtin && id != virtualDisplayIdentity }

let virtualDisplayWidth = 1280, virtualDisplayHeight = 800
let virtualDisplayMillimeters = CGSize(width: 286, height: 179)

// A resilience fallback: a future macOS may drop the private classes. They are weak-linked, so the app runs either way.
let virtualDisplayClassesFound = ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
    .allSatisfy { NSClassFromString($0) != nil }

var virtualDisplay: CGVirtualDisplay?
var displayAssertion: IOPMAssertionID?

// Idempotent: the app calls it on every state change, restore() with false.
func setVirtualDisplay(_ on: Bool) {
    if !on {
        virtualDisplay = nil
        if let a = displayAssertion { IOPMAssertionRelease(a) }
        displayAssertion = nil
        return
    }
    guard virtualDisplayClassesFound, virtualDisplay == nil else { return }
    guard let display = makeVirtualDisplay() else { NSLog("Decaffeinate: macOS refused the virtual display"); return }
    virtualDisplay = display
    var a = IOPMAssertionID(0)
    if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                   "Decaffeinate: virtual display with the lid closed" as CFString, &a) == kIOReturnSuccess {
        displayAssertion = a
    }
}

func makeVirtualDisplay() -> CGVirtualDisplay? {
    let desc = CGVirtualDisplayDescriptor()
    desc.queue = .main
    desc.name = "Decaffeinate"
    desc.maxPixelsWide = UInt32(virtualDisplayWidth)
    desc.maxPixelsHigh = UInt32(virtualDisplayHeight)
    desc.sizeInMillimeters = virtualDisplayMillimeters
    desc.vendorID = virtualDisplayIdentity.vendor
    desc.productID = virtualDisplayIdentity.product
    desc.serialNum = virtualDisplayIdentity.serial
    guard let display = CGVirtualDisplay(descriptor: desc) else { return nil }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: UInt(virtualDisplayWidth), height: UInt(virtualDisplayHeight), refreshRate: 60)]
    return display.applySettings(settings) ? display : nil
}
