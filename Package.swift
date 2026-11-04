// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Buckets",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Buckets",
            path: "Sources/Buckets"
        )
    ]
)
