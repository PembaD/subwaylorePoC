// swift-tools-version: 6.0
import PackageDescription

// Foundation-based domain tests can run on macOS without launching the iOS app.
let package = Package(
    name: "SubwayLoreCoreTests",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "SubwayLore",
            path: "SubwayLore/SubwayLore",
            exclude: [
                "Assets.xcassets", "Resources", "SubwayLore.entitlements",
                "ContentView.swift", "SubwayLoreApp.swift", "App", "Features/NearbySession", "Features/Profile",
                "Features/Chat/ChatHistoryView.swift",
                "Features/Game/GamePickerView.swift", "Features/Game/TimeItGameView.swift", "Features/Game/LeaderboardView.swift",
                "Features/Game/TriviaGameView.swift",
                "Networking/PeerConnection.swift", "Networking/PeerDiscovery.swift",
                "Networking/PeerTransport.swift", "Networking/TransportConfiguration.swift", "Networking/NetworkActivityTransport.swift"
            ]
        ),
        .testTarget(name: "SubwayLoreTests", dependencies: ["SubwayLore"], path: "SubwayLore/SubwayLoreTests")
    ]
)
