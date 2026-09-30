// swift-tools-version:5.7
import PackageDescription
import Foundation

// Модели и эталоны, которые make-app.sh кладёт в Resources перед сборкой (в гите их нет, в бандл
// их копирует сам make-app.sh): SwiftPM их не трогает. Исключаются только те, что уже лежат, —
// иначе на свежем клоне было бы предупреждение про несуществующий путь.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let stagedByMakeApp = ["qsnet.bin", "qsnet-selftest.json", "qsnet-replay.json", "qsvec.bin", "qsvec-topics.json",
                       "qsngram.bin", "qschar.bin", "core5-selftest.json"]
    .map { "Resources/" + $0 }
    .filter { FileManager.default.fileExists(atPath: packageRoot + "/Sources/QSwitcher/" + $0) }

let package = Package(
    name: "QSwitcher",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "QSwitcher",
            path: "Sources/QSwitcher",
            exclude: stagedByMakeApp,
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
