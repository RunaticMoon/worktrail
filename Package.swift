// swift-tools-version:5.10
import PackageDescription

var appDependencies: [Target.Dependency] = ["WorkLogCore"]
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
]
#if os(macOS)
// Sparkle contains macOS binary targets; exclude the package entirely on Linux.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
#endif

// WorkLog — 임시 코드명. 표시 이름·bundle id·데이터 경로는 AppIdentity에서 교체한다.
let package = Package(
    name: "WorkLog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkLogCore", targets: ["WorkLogCore"]),
        .executable(name: "WorkLogApp", targets: ["WorkLogApp"]),
        .executable(name: "worklog", targets: ["worklog"]),
    ],
    dependencies: dependencies,
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "WorkLogCore",
            dependencies: [
                "CSQLite",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "WorkLogApp",
            dependencies: appDependencies,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"], .when(platforms: [.macOS]))]
        ),
        .executableTarget(
            name: "worklog",
            dependencies: ["WorkLogCore"]
        ),
        .testTarget(
            name: "WorkLogCoreTests",
            dependencies: ["WorkLogCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
