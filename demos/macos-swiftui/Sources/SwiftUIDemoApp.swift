import SwiftUI
#if DEBUG
import Porthole
#endif

final class Model: ObservableObject {
    @Published var name = ""
    @Published var secret = ""
    @Published var notify = false
    @Published var airplane = false
    @Published var count = 0
    @Published var level = 0.5
    @Published var showSheet = false
    @Published var selected: Int?

    func reset() {
        name = ""
        secret = ""
        notify = false
        airplane = false
        count = 0
        level = 0.5
        showSheet = false
        selected = nil
    }
}

struct ContentView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hello, \(model.name.isEmpty ? "stranger" : model.name)")
                .accessibilityIdentifier("greeting")
            TextField("Name", text: $model.name)
                .accessibilityIdentifier("name")
            SecureField("Secret", text: $model.secret)
                .accessibilityIdentifier("secret")
            Toggle("Notifications", isOn: $model.notify)
                .accessibilityIdentifier("notify")
            Toggle("Airplane mode", isOn: $model.airplane)
                .toggleStyle(.switch)
                .accessibilityIdentifier("airplane")
            HStack {
                Button("Increment") { model.count += 1 }
                    .accessibilityIdentifier("increment")
                Text("Count: \(model.count)")
                    .accessibilityIdentifier("count")
                Button("Show Sheet") { model.showSheet = true }
                    .accessibilityIdentifier("show-sheet")
            }
            Slider(value: $model.level) { Text("Level") }
                .accessibilityIdentifier("level")
            Text(model.selected.map { "Selected \($0)" } ?? "Nothing selected")
                .accessibilityIdentifier("selection")
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(1...50, id: \.self) { i in
                        Button("Fruit \(i)") { model.selected = i }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("fruit-\(i)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .accessibilityIdentifier("fruits")
        }
        .padding(20)
        .frame(width: 420)
        .sheet(isPresented: $model.showSheet) {
            VStack(spacing: 12) {
                Text("A sheet")
                Button("Done") { model.showSheet = false }
                    .accessibilityIdentifier("done")
            }
            .padding(30)
        }
    }
}

@main
struct SwiftUIDemoApp: App {
    @StateObject private var model = Model()

    init() {
        #if DEBUG
        Porthole.start()
        #endif
    }

    var body: some Scene {
        WindowGroup("SwiftUI Demo") {
            ContentView(model: model)
                .onAppear {
                    #if DEBUG
                    Porthole.registerHook("reset") { [model] in model.reset() }
                    #endif
                }
        }
        .windowResizability(.contentSize)
    }
}
