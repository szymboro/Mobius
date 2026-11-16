// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mobius",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Mobius", targets: ["Mobius"]),
    ],
    targets: [
        .target(name: "MobiusCore"),
        .target(
            name: "Mobius",
            dependencies: ["MobiusCore"],
            linkerSettings: [
                // SwiftPM stamps LC_BUILD_VERSION with sdk = deployment target (17.0), which makes
                // iOS run the app in compatibility mode (old keyboard, no Liquid Glass). Record the
                // SDK we actually build against.
                .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "ios", "-Xlinker", "17.0", "-Xlinker", "27.2"]),
                // Keep Objective-C classes nothing references directly, e.g. ones looked up with
                // NSClassFromString (see SettingsLogoExtra); a static archive would drop them.
                .unsafeFlags(["-Xlinker", "-ObjC"]),
            ]
        ),
    ]
)
