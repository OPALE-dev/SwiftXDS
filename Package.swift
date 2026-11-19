// swift-tools-version:6.2
// SwiftXDS: IHE XDS.b document sharing in Swift (SOAP 1.2, WS-Addressing, MTOM/XOP, ebRIM 3.0).
import PackageDescription

let package = Package(
    name: "SwiftXDS",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftXDS", targets: ["SwiftXDS"]),
        .library(name: "SwiftXDSSOAP", targets: ["SwiftXDSSOAP"]),
        .library(name: "SwiftXDSClient", targets: ["SwiftXDSClient"]),
        .library(name: "SwiftXDSTestRegistry", targets: ["SwiftXDSTestRegistry"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        // XML tree, reader and writer; XDS metadata model, ebRIM 3.0, registry responses, validation. No network.
        .target(name: "SwiftXDS"),
        // SOAP 1.2 envelope, WS-Addressing, faults and MTOM/XOP packaging. No HTTP.
        .target(name: "SwiftXDSSOAP", dependencies: ["SwiftXDS"]),
        // Transactions over HTTP: Document Source (ITI-41), Consumer (ITI-18, ITI-43), Update (ITI-57).
        .target(name: "SwiftXDSClient", dependencies: [
            "SwiftXDS", "SwiftXDSSOAP",
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
        ]),
        // In-memory registry and repository, with a small HTTP server, for tests and simulators.
        .target(name: "SwiftXDSTestRegistry", dependencies: [
            "SwiftXDS", "SwiftXDSSOAP", "SwiftXDSClient",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
        ]),
        .testTarget(name: "SwiftXDSTests", dependencies: ["SwiftXDS"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SwiftXDSSOAPTests", dependencies: ["SwiftXDSSOAP"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SwiftXDSClientTests", dependencies: [
            "SwiftXDSClient", "SwiftXDSTestRegistry",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
        ]),
    ]
)
