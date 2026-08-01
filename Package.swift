// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "QSwitcher",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "QSwitcher",
            path: "Sources/QSwitcher",
            resources: [
                .copy("Resources/ru.txt"),
                .copy("Resources/en.txt"),
                .copy("Resources/bad_ngrams.json"),
                .copy("Resources/layout_map.json"),
                .copy("Resources/short_ru.txt"),
                .copy("Resources/short_en.txt"),
            ]
        )
    ]
)
