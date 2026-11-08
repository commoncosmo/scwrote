// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "scredit",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Scredit", targets: ["Scredit"]),
    ],
    dependencies: [
        // Pinned exactly: libghostty's API is not stable yet, and this package
        // tracks Ghostty's main branch weekly.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026110702"),
    ],
    targets: [
        // Pure logic with no AppKit or Ghostty dependency, so it can be unit tested.
        .target(name: "ScreditCore"),
        .executableTarget(
            name: "Scredit",
            dependencies: [
                "ScreditCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        ),
        .testTarget(name: "ScreditCoreTests", dependencies: ["ScreditCore"]),
    ],
    swiftLanguageModes: [.v6]
)
