// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Todo",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TodoKit", targets: ["TodoKit"])],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.12.0"),
        .package(url: "https://github.com/vapor/fluent-mysql-driver.git", from: "4.7.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.8.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Already pulled in by Vapor; declared directly for the SMTP client (Sources/TodoKit/Mail). Package.resolved pins the versions.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/swift-server/webauthn-swift.git", from: "1.0.0-beta.1"),
    ],
    targets: [
        .target(name: "TodoKit", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
            .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            .product(name: "WebAuthn", package: "webauthn-swift"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .executableTarget(name: "App", dependencies: ["TodoKit"]),
        .testTarget(name: "TodoKitTests", dependencies: [
            "TodoKit", .product(name: "XCTVapor", package: "vapor"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
    ]
)
