// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AutoSwitcher",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "AutoSwitcher",
            path: "Sources/AutoSwitcher",
            resources: [
                .copy("Resources/ru.txt"),
                .copy("Resources/en.txt"),
                .copy("Resources/bad_ngrams.json"),
                .copy("Resources/layout_map.json"),
            ]
        )
    ]
)
