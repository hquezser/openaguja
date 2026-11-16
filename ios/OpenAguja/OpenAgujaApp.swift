import SwiftUI
import OpenAgujaCore

@main
struct OpenAgujaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(delegate.bluetooth)
                .environmentObject(delegate.bridge)
                .environmentObject(delegate.macd)
                .environmentObject(delegate.log)
                .environmentObject(delegate.router)
                .environmentObject(delegate.weather)
                .environmentObject(delegate.activity)
                .environmentObject(delegate.settings)
                .environmentObject(delegate.music)
                .environmentObject(delegate.calls)
                .environmentObject(delegate.phone)
                .environmentObject(delegate.calendar)
                .environmentObject(delegate.heartRate)
                .environmentObject(delegate.telemetryUploader)
                .environmentObject(delegate.telemetryHistory)
        }
    }
}
