// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "porthole-mcp",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "Porthole", targets: ["Porthole"]),
        // A self-starting dylib for apps that don't embed Porthole: porthole-mcp
        // loads it with lldb (attach) or DYLD_INSERT_LIBRARIES (launch).
        .library(name: "PortholeInject", type: .dynamic, targets: ["PortholeInject"]),
    ],
    targets: [
        // Objective-C helpers for private UIKit touch synthesis (DEBUG only; empty on macOS).
        .target(name: "PortholeTouch", path: "Sources/PortholeTouch"),
        .target(name: "Porthole", dependencies: ["PortholeTouch"], path: "Sources/Porthole"),
        .target(name: "PortholeInject", dependencies: ["Porthole"], path: "Sources/PortholeInject"),
        .testTarget(name: "PortholeTests", dependencies: ["Porthole"], path: "Tests/PortholeTests"),
    ]
)
