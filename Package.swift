// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RimeQ",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RimeQ", targets: ["RimeQ"])],
    targets: [
        .target(name: "QRimeBridge", path: "macos/Bridge", publicHeadersPath: "include"),
        .executableTarget(name: "RimeQ", dependencies: ["QRimeBridge"], path: "macos/Sources",
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("InputMethodKit"),
                                           .linkedFramework("Carbon")])
    ],
    cxxLanguageStandard: .cxx17
)
