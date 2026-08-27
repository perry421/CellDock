import SwiftUI

@main
struct CellDockRemoteApp: App {
    @StateObject private var client = BridgeClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .onAppear { client.start() }
                .onDisappear { client.stop() }
        }
    }
}
