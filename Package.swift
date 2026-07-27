// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "OpenAVFoundation",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "OpenAVFoundation",
            targets: ["OpenAVFoundation"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/1amageek/OpenCoreMedia.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/1amageek/OpenCoreVideo.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/1amageek/OpenAVFoundationDriver.git",
            branch: "main"
        )
    ],
    targets: [
        .target(
            name: "OpenAVFoundation",
            dependencies: [
                "OpenCoreMedia",
                "OpenCoreVideo",
                .product(
                    name: "OpenAVFoundationDriver",
                    package: "OpenAVFoundationDriver"
                )
            ]
        ),
        .testTarget(
            name: "OpenAVFoundationTests",
            dependencies: [
                "OpenAVFoundation",
                .product(
                    name: "OpenAVFoundationDriver",
                    package: "OpenAVFoundationDriver"
                )
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
