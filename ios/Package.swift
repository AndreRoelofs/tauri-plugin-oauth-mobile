// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "tauri-plugin-appauth",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "tauri-plugin-appauth",
            type: .static,
            targets: ["tauri-plugin-appauth"])
    ],
    dependencies: [
        .package(name: "Tauri", path: "../.tauri/tauri-api"),
        .package(url: "https://github.com/openid/AppAuth-iOS", .exact("1.7.6"))
    ],
    targets: [
        .target(
            name: "tauri-plugin-appauth",
            dependencies: [
                .byName(name: "Tauri"),
                .product(name: "AppAuth", package: "AppAuth-iOS")
            ],
            path: "Sources")
    ]
)
