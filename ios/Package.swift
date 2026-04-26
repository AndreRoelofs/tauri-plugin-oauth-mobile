// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "tauri-plugin-oauth-session",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "tauri-plugin-oauth-session",
            type: .static,
            targets: ["tauri-plugin-oauth-session"])
    ],
    dependencies: [
        .package(name: "Tauri", path: "../.tauri/tauri-api")
    ],
    targets: [
        .target(
            name: "tauri-plugin-oauth-session",
            dependencies: [
                .byName(name: "Tauri")
            ],
            path: "Sources")
    ]
)
