// swift-tools-version: 6.0
//
// DrJitCore - Swift Package
//
// Layer diagram:
//   DrJitKit  (Swift, .interoperabilityMode(.Cxx))
//     - DrJitBridge  (Obj-C++ wrapper, compiled by SPM)
//          - DrJitBinary  (static XCFramework bootstrapped into vendor/)
//
// To bootstrap:
//   make bootstrap
// or:
//   Scripts/bootstrap-drjit.sh
//
// The bootstrap builds drjit-core + nanothread from DRJIT_SRC, the canonical
// GitHub/mitsuba-renderer/drjit clone, or the legacy sibling clone at ../DrJit
// with the Metal backend enabled (LLVM, CUDA, Python all off), then stages a
// multi-platform STATIC XCFramework into vendor/.
//
// Static library xcframework: no embedding required, no rpath issues.
// Metal is the JIT backend: drjit-core compiles expressions to MSL at runtime
// and evaluates them on the GPU. No JIT entitlement required.

import PackageDescription

let package = Package(
    name: "DrJitCore",
    platforms: [
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "DrJitKit", targets: ["DrJitKit"]),
    ],
    targets: [
        // DrJitBinary - prebuilt static XCFramework (.a per platform)
        .binaryTarget(
            name: "DrJitBinary",
            path: "vendor/DrJitBinary.xcframework"
        ),

        // DrJitBridge - Obj-C++ wrapper over the C99 jit.h API.
        // Metal must be linked explicitly: with a static xcframework the linker
        // no longer picks it up transitively from a dylib.
        .target(
            name: "DrJitBridge",
            dependencies: ["DrJitBinary"],
            path: "Sources/DrJitBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../vendor/drjit-include"),
                .headerSearchPath("../../vendor/drjit-include/drjit-core"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Foundation"),
            ]
        ),

        // DrJitKit - idiomatic Swift API
        .target(
            name: "DrJitKit",
            dependencies: ["DrJitBridge"],
            path: "Sources/DrJitKit",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
