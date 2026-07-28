import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func normalizedHex(_ value: String) -> String? {
    guard !value.isEmpty,
          value.count <= 8,
          value.allSatisfy({ $0.isHexDigit }),
          let number = UInt32(value, radix: 16) else {
        return nil
    }
    return String(number, radix: 16)
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else {
        fail("could not count online displays")
    }
    guard displayCount > 0 else {
        fail("requested display is not online")
    }

    var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    var enumeratedDisplayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(displayCount, &displays, &enumeratedDisplayCount) == .success else {
        fail("could not list online displays")
    }
    guard enumeratedDisplayCount == displayCount else {
        fail("online display list changed while enumerating")
    }

    var finalDisplayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &finalDisplayCount) == .success else {
        fail("could not recheck online displays")
    }
    guard finalDisplayCount == displayCount else {
        fail("online display list changed while enumerating")
    }

    var recheckedDisplays = [CGDirectDisplayID](repeating: 0, count: Int(finalDisplayCount))
    var recheckedDisplayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(finalDisplayCount, &recheckedDisplays, &recheckedDisplayCount) == .success else {
        fail("could not recheck online displays")
    }
    guard recheckedDisplayCount == finalDisplayCount,
          displays.sorted() == recheckedDisplays.sorted() else {
        fail("online display list changed while enumerating")
    }
    return displays.sorted()
}

func exactTargetDisplay(
    in displays: [CGDirectDisplayID],
    vendorID: UInt32,
    productID: UInt32
) -> CGDirectDisplayID {
    let matchingDisplays = displays.filter {
        CGDisplayVendorNumber($0) == vendorID && CGDisplayModelNumber($0) == productID
    }

    guard matchingDisplays.count == 1, let targetDisplay = matchingDisplays.first else {
        if matchingDisplays.isEmpty {
            fail("requested display is not online")
        }
        fail("multiple online displays match the requested vendor and product id")
    }
    return targetDisplay
}

var vendorValue: String?
var productValue: String?
var index = 1
let arguments = CommandLine.arguments

while index < arguments.count {
    let argument = arguments[index]
    guard index + 1 < arguments.count else {
        fail("missing value for \(argument)")
    }

    switch argument {
    case "--vendor-id":
        vendorValue = arguments[index + 1]
    case "--product-id":
        productValue = arguments[index + 1]
    default:
        fail("unknown option \(argument)")
    }
    index += 2
}

guard let vendorText = vendorValue,
      let productText = productValue,
      let normalizedVendor = normalizedHex(vendorText),
      let normalizedProduct = normalizedHex(productText),
      let vendorID = UInt32(normalizedVendor, radix: 16),
      let productID = UInt32(normalizedProduct, radix: 16) else {
    fail("vendor id and product id must be hexadecimal values")
}

let initialDisplays = onlineDisplays()
let targetDisplay = exactTargetDisplay(
    in: initialDisplays,
    vendorID: vendorID,
    productID: productID
)
let targetSerialNumber = CGDisplaySerialNumber(targetDisplay)

guard CGDisplayIsOnline(targetDisplay) != 0,
      CGDisplayVendorNumber(targetDisplay) == vendorID,
      CGDisplayModelNumber(targetDisplay) == productID,
      CGDisplaySerialNumber(targetDisplay) == targetSerialNumber else {
    fail("requested display changed before mode enumeration")
}

guard let modes = CGDisplayCopyAllDisplayModes(
    targetDisplay,
    [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
) as? [CGDisplayMode] else {
    fail("could not enumerate target display modes")
}

let finalDisplays = onlineDisplays()
guard finalDisplays == initialDisplays else {
    fail("online display list changed while enumerating modes")
}
let recheckedTargetDisplay = exactTargetDisplay(
    in: finalDisplays,
    vendorID: vendorID,
    productID: productID
)
guard recheckedTargetDisplay == targetDisplay else {
    fail("requested display changed while enumerating modes")
}
guard CGDisplayIsOnline(targetDisplay) != 0,
      CGDisplayVendorNumber(targetDisplay) == vendorID,
      CGDisplayModelNumber(targetDisplay) == productID,
      CGDisplaySerialNumber(targetDisplay) == targetSerialNumber else {
    fail("requested display changed while enumerating modes")
}
guard !modes.isEmpty else {
    fail("target display exposes no modes")
}

print("target|vendor-id=\(normalizedVendor)|product-id=\(normalizedProduct)")
for mode in modes {
    let refresh = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), mode.refreshRate)
    print("mode|logical=\(mode.width)x\(mode.height)|pixels=\(mode.pixelWidth)x\(mode.pixelHeight)|refresh=\(refresh)|flags=\(mode.ioFlags)")
}
