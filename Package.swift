// swift-tools-version:5.10
import PackageDescription

// WorkLog — 임시 코드명. 표시 이름·bundle id·데이터 경로는 AppIdentity에서 교체한다.
let package = Package(
    name: "WorkLog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkLogCore", targets: ["WorkLogCore"]),
        .executable(name: "WorkLogApp", targets: ["WorkLogApp"]),
        .executable(name: "worklog", targets: ["worklog"]),
    ],
    dependencies: [
        // Apple 공식 swift-crypto: Apple 플랫폼에서는 CryptoKit을 그대로 재노출하고
        // Linux에서는 같은 API를 BoringSSL로 제공한다. 자체 암호 구현을 하지 않기 위함.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
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
            dependencies: ["WorkLogCore"]
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
