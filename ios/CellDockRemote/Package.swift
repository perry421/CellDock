// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CellDockRemote",
    platforms: [
        .iOS(.v16)
    ],
    targets: [
        .target(
            name: "CellDockRemote",
            dependencies: [],
            path: "Sources/CellDockRemote"
        )
    ]
)
