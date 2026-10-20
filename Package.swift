// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacropadMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacropadMenuBar", targets: ["MacropadMenuBar"]),
        .library(name: "MacropadCore", targets: ["MacropadCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // Pure logic: key tables, action syntax, USB packet building, layout files, presets.
        .target(name: "MacropadCore", dependencies: ["Yams"]),
        // The menu bar app: SwiftUI + IOUSBHost.
        .executableTarget(name: "MacropadMenuBar", dependencies: ["MacropadCore"]),
        .testTarget(
            name: "MacropadCoreTests",
            dependencies: ["MacropadCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
