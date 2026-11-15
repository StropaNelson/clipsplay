// swift-tools-version: 5.6
// ClipStudio - Editor de Vídeos para Criação de Episódios
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "ClipStudio",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .iOSApplication(
            name: "ClipStudio",
            targets: ["App"],
            displayVersion: "1.0.0",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .photoLibraryAddOnly,
                .fileAccess([.userSelectedFiles, .userSelectedFilesReadWrite])
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "App",
            path: "App",
            resources: [
                .process("Assets.xcassets"),
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)