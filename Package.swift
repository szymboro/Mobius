// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibreTube",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LibreTube", targets: ["LibreTube"]),
    ],
    targets: [
        .target(name: "LibreTubeCore"),
        .target(
            name: "LibreTube",
            dependencies: ["LibreTubeCore"],
            linkerSettings: [
                // SwiftPM stamps LC_BUILD_VERSION with sdk = deployment target (17.0), which makes
                // iOS run the app in compatibility mode (old keyboard, no Liquid Glass). Record the
                // SDK we actually build against.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "27.2"]),
            ]
        ),
    ]
)
