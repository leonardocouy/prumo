// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Prumo",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Prumo", targets: ["Prumo"])],
    targets: [
        .systemLibrary(name: "PrumoCoreFFI", path: "Sources/PrumoCoreFFI"),
        .target(
            name: "PrumoCore", dependencies: ["PrumoCoreFFI"],
            linkerSettings: [
                .unsafeFlags([Context.packageDirectory + "/core/target/aarch64-apple-darwin/release/libprumo_core.a"])
            ]),
        .executableTarget(name: "Prumo", dependencies: ["PrumoCore"]),
    ]
)
