// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "scwrote",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Scwrote", targets: ["Scwrote"]),
    ],
    dependencies: [
        // Pinned exactly: libghostty's API is not stable yet, and this package
        // tracks Ghostty's main branch weekly.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026110702"),
    ],
    targets: [
        // Pure logic with no AppKit or Ghostty dependency, so it can be unit tested.
        .target(name: "ScwroteCore"),
        .executableTarget(
            name: "Scwrote",
            dependencies: [
                "ScwroteCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                // The C API, for reading theme colors out of the Ghostty config.
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
        .testTarget(name: "ScwroteCoreTests", dependencies: ["ScwroteCore"]),
    ],
    swiftLanguageModes: [.v6]
)
