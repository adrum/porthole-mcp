import SwiftUI
#if DEBUG
import Porthole
#endif

/// One small app for tvOS, visionOS and watchOS: a count and a button, for
/// the e2e tests to launch on each Simulator, inspect and drive.
@main
struct PlatformsDemoApp: App {
    init() {
        #if DEBUG
        Porthole.start()
        Porthole.registerHook("reset") { Counter.shared.count = 0 }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            CounterView()
        }
    }
}

final class Counter: ObservableObject {
    static let shared = Counter()
    @Published var count = 0
}

struct CounterView: View {
    @ObservedObject var counter = Counter.shared

    var body: some View {
        VStack(spacing: 12) {
            Text("Count: \(counter.count)")
                .accessibilityIdentifier("count")
            Button("Add") { counter.count += 1 }
                .accessibilityIdentifier("add")
        }
    }
}
