import SwiftUI
import UIKit

@main
struct SlappApp: App {
    @StateObject private var model = CaptureModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear { LineNotifications.ask() }
                .onAppear {
                    model.ensureMicPermission()
                    model.pairIfPossible()
                    IntentsCoordinator.model = model
                }
        }
    }
}
