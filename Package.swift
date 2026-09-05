// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanCurve",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fancurved", targets: ["fancurved"]),
        .executable(name: "fancurvectl", targets: ["fancurvectl"]),
        .executable(name: "FanCurveApp", targets: ["FanCurveApp"]),
    ],
    targets: [
        .target(
            name: "CSMC",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(name: "FanCurveKit", dependencies: ["CSMC"]),
        .executableTarget(name: "fancurved", dependencies: ["FanCurveKit"]),
        .executableTarget(name: "fancurvectl", dependencies: ["FanCurveKit"]),
        .executableTarget(name: "FanCurveApp", dependencies: ["FanCurveKit"]),
        .testTarget(name: "FanCurveKitTests", dependencies: ["FanCurveKit"]),
    ]
)
