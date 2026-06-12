// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Porcelain",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Porcelain", targets: ["Porcelain"]),
        .library(name: "PorcelainCore", targets: ["PorcelainCore"])
    ],
    targets: [
        .executableTarget(
            name: "Porcelain",
            dependencies: ["PorcelainCore"],
            path: "Sources/Porcelain"
        ),
        .target(
            name: "PorcelainCore",
            path: "Sources/PorcelainCore",
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "PorcelainCoreTests",
            dependencies: ["PorcelainCore"],
            path: "Tests/PorcelainCoreTests"
        )
    ]
)
