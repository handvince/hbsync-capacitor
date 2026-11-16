// swift-tools-version: 5.9

// Nom « Hbsync » (et non « HbSync ») : c'est le nom que Capacitor déduit du paquet npm « hbsync »
// quand il génère CapApp-SPM/Package.swift. Ainsi, aucun correctif n'est nécessaire dans les applis.

import PackageDescription

let package = Package(
    name: "Hbsync",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "Hbsync",
            targets: ["HbSyncPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "HbSyncPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/HbSyncPlugin"
        )
    ]
)
