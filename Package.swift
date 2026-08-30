// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Trace",
    platforms: [.macOS(.v14)],
    targets: [
        // Logique pure (géométrie, GPX, modèle, statistiques) : testable par XCTest.
        .target(
            name: "TraceCore",
            path: "Sources/TraceCore"
        ),
        // L'application SwiftUI + MapKit.
        .executableTarget(
            name: "Trace",
            dependencies: ["TraceCore"],
            path: "Sources/Trace",
            resources: [.copy("Assets")]
        ),
        .testTarget(
            name: "TraceCoreTests",
            dependencies: ["TraceCore"],
            path: "Tests/TraceCoreTests"
        ),
    ]
)
