// swift-tools-version: 6.0
import PackageDescription

/// Session: phones (and other Macs) join a Hot Mic session and sing takes into it.
/// Shared by the Mac app (host) and the iPhone app (contributor), so it stays platform-neutral:
/// Foundation, Network, Accelerate only.
let package = Package(
    name: "SessionKit",
    platforms: [.macOS("14.2"), .iOS("17.0")],
    products: [.library(name: "SessionKit", targets: ["SessionKit"])],
    targets: [.target(name: "SessionKit")],
    swiftLanguageModes: [.v5]
)
