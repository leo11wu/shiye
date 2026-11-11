// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "PageArchive",
    platforms: [.macOS("14.0")],
    products: [.executable(name: "Shiye", targets: ["PageArchiveApp"]),
               .executable(name: "shiye-check", targets: ["PageArchiveCLI"]),
               .executable(name: "shiye-tests", targets: ["PageArchiveChecks"])],
    targets: [
        .target(name: "PageArchiveCore", resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "PageArchiveApp", dependencies: ["PageArchiveCore"]),
        .executableTarget(name: "PageArchiveCLI", dependencies: ["PageArchiveCore"]),
        .executableTarget(name: "PageArchiveChecks", dependencies: ["PageArchiveCore"], path:"Tests/PageArchiveCoreTests")
    ]
)
