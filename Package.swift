// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import PackageDescription

let package = Package(
    name: "Roundhouse",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Roundhouse", targets: ["Roundhouse"]),
    ],
    targets: [
        // Pure logic – no UI, tested.
        .target(name: "RoundhouseCore"),
        .executableTarget(
            name: "Roundhouse",
            dependencies: ["RoundhouseCore"],
            // Localizable.strings files are copied into the .app by scripts/build-app.sh
            exclude: ["Resources"]
        ),
        .testTarget(name: "RoundhouseCoreTests", dependencies: ["RoundhouseCore"]),
    ]
)
