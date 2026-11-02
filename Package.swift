// swift-tools-version: 6.0
import PackageDescription

// MacAutoDiag (the app) is AppKit. On Linux the manifest drops it so `swift test` can build
// the core and the emulator. macOS still gets the same three products.
var products: [Product] = [
    .library(name: "VazCore", targets: ["VazCore"]),
    .executable(name: "vazemu", targets: ["VazEmuTool"]),
]
var targets: [Target] = [
    // Platform-independent core: no AppKit/SwiftUI imports allowed here.
    .target(name: "VazCore", resources: [.copy("Definitions")]),
    // Январь ECU emulator: 8051/C509 core and board peripherals; no UI.
    // Always optimized: running firmware unoptimized makes tests ~10× slower.
    .target(name: "VazEmu", dependencies: ["VazCore"], swiftSettings: [.unsafeFlags(["-O"])]),
    // Real K-line adapters (POSIX serial; macOS-specific ioctls).
    .target(name: "VazSerial", dependencies: ["VazCore"]),
    .executableTarget(name: "VazEmuTool", dependencies: ["VazEmu", "VazCore"]),
    .testTarget(name: "VazCoreTests", dependencies: ["VazCore"]),
    .testTarget(name: "VazEmuTests", dependencies: ["VazEmu"]),
]
#if os(macOS)
products.append(.executable(name: "MacAutoDiag", targets: ["MacAutoDiag"]))
targets.append(.executableTarget(name: "MacAutoDiag", dependencies: ["VazCore", "VazEmu", "VazSerial"],
                                   resources: [.copy("Resources/AppIcon.png")]))
#endif

let package = Package(
    name: "MacAutoDiag",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
