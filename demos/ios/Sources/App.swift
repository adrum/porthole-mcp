import UIKit
import SwiftUI
#if DEBUG
import Porthole
#endif

/// Shared state so the reset hook can clear both screens.
final class DemoState: ObservableObject {
    static let shared = DemoState()
    @Published var name = ""
    @Published var wifi = false
    @Published var count = 0
    @Published var showSheet = false
    @Published var picked: Int?
    var onReset: [() -> Void] = []

    func reset() {
        name = ""
        wifi = false
        count = 0
        showSheet = false
        picked = nil
        onReset.forEach { $0() }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        Porthole.start()
        Porthole.registerHook("reset") { DemoState.shared.reset() }
        #endif
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: session.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: FormViewController())
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// UIKit screen: a form, a gesture-recognizer tap area, a modal and a table.
final class FormViewController: UIViewController, UITextFieldDelegate, UITableViewDataSource {
    let email = UITextField()
    let status = UILabel()
    let edits = UILabel()
    let notify = UISwitch()
    let tapped = UILabel()
    let table = UITableView()
    var editCount = 0
    var tapCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "UIKit Form"
        view.backgroundColor = .systemBackground

        email.placeholder = "Email"
        email.borderStyle = .roundedRect
        email.autocapitalizationType = .none
        email.accessibilityIdentifier = "email"
        email.delegate = self
        email.addTarget(self, action: #selector(emailChanged), for: .editingChanged)

        let save = UIButton(type: .system)
        save.setTitle("Save", for: .normal)
        save.accessibilityIdentifier = "save"
        save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        notify.accessibilityIdentifier = "notify"
        notify.accessibilityLabel = "Notify me"
        let notifyLabel = UILabel()
        notifyLabel.text = "Notify me"
        let notifyRow = UIStackView(arrangedSubviews: [notifyLabel, notify])

        status.text = "Not saved"
        status.accessibilityIdentifier = "status"
        edits.text = "Edits: 0"
        edits.accessibilityIdentifier = "edits"

        // A plain view with a gesture recognizer: only real touches reach it.
        let tapArea = UIView()
        tapArea.backgroundColor = .systemTeal
        tapArea.accessibilityIdentifier = "tap-area"
        tapArea.isAccessibilityElement = true
        tapArea.accessibilityLabel = "Tap area"
        tapArea.accessibilityTraits = .button
        tapArea.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(areaTapped)))
        tapArea.heightAnchor.constraint(equalToConstant: 44).isActive = true
        tapped.text = "Taps: 0"
        tapped.accessibilityIdentifier = "taps"

        // Two deliberate accessibility bugs for audits: visible text that
        // VoiceOver skips, and a touch target VoiceOver can't reach.
        let finePrint = UILabel()
        finePrint.text = "Terms apply"
        finePrint.font = .systemFont(ofSize: 11)
        finePrint.textColor = .lightGray
        finePrint.isAccessibilityElement = false
        let secretTap = UIView()
        secretTap.backgroundColor = .systemOrange
        secretTap.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(areaTapped)))
        secretTap.widthAnchor.constraint(equalToConstant: 30).isActive = true
        secretTap.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let auditRow = UIStackView(arrangedSubviews: [finePrint, secretTap])
        auditRow.alignment = .center

        let modal = UIButton(type: .system)
        modal.setTitle("Present Modal", for: .normal)
        modal.accessibilityIdentifier = "present-modal"
        modal.addTarget(self, action: #selector(presentModal), for: .touchUpInside)

        let swiftUI = UIButton(type: .system)
        swiftUI.setTitle("Open SwiftUI", for: .normal)
        swiftUI.accessibilityIdentifier = "open-swiftui"
        swiftUI.addTarget(self, action: #selector(openSwiftUI), for: .touchUpInside)

        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.accessibilityIdentifier = "items"

        let buttons = UIStackView(arrangedSubviews: [save, modal, swiftUI])
        buttons.distribution = .equalSpacing
        let stack = UIStackView(arrangedSubviews: [email, buttons, notifyRow, status, edits, tapArea, tapped, auditRow, table])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        DemoState.shared.onReset.append { [weak self] in
            guard let self else { return }
            self.email.text = ""
            self.email.resignFirstResponder()
            self.status.text = "Not saved"
            self.editCount = 0
            self.edits.text = "Edits: 0"
            self.tapCount = 0
            self.tapped.text = "Taps: 0"
            self.notify.isOn = false
            self.table.setContentOffset(.zero, animated: false)
            self.presentedViewController?.dismiss(animated: false)
            self.navigationController?.popToRootViewController(animated: false)
        }
    }

    @objc func emailChanged() {
        editCount += 1
        edits.text = "Edits: \(editCount)"
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        saveTapped()
        textField.resignFirstResponder()
        return true
    }

    @objc func saveTapped() {
        status.text = "Saved \(email.text ?? "")\(notify.isOn ? " (notify)" : "")"
        print("save tapped: \(email.text ?? "")")
    }

    @objc func areaTapped() {
        tapCount += 1
        tapped.text = "Taps: \(tapCount)"
    }

    @objc func presentModal() {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.accessibilityIdentifier = "close-modal"
        close.addAction(UIAction { [weak vc] _ in vc?.dismiss(animated: true) }, for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(close)
        NSLayoutConstraint.activate([
            close.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            close.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 40),
        ])
        vc.modalPresentationStyle = .pageSheet
        present(vc, animated: true)
    }

    @objc func openSwiftUI() {
        let host = UIHostingController(rootView: SwiftUIScreen(state: DemoState.shared))
        host.title = "SwiftUI"
        navigationController?.pushViewController(host, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 60 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = "Row \(indexPath.row + 1)"
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "row-\(indexPath.row + 1)"
        return cell
    }
}

struct SwiftUIScreen: View {
    @ObservedObject var state: DemoState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hi \(state.name.isEmpty ? "there" : state.name)")
                .accessibilityIdentifier("hello")
            TextField("Your name", text: $state.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("name")
            Toggle("Wi-Fi", isOn: $state.wifi)
                .accessibilityIdentifier("wifi")
            HStack {
                Button("Increment") { state.count += 1 }
                    .accessibilityIdentifier("increment")
                Text("Count: \(state.count)")
                    .accessibilityIdentifier("count")
                Spacer()
                Button("Show Sheet") { state.showSheet = true }
                    .accessibilityIdentifier("show-sheet")
            }
            Text(state.picked.map { "Picked \($0)" } ?? "Nothing picked")
                .accessibilityIdentifier("picked")
            List(1...40, id: \.self) { i in
                Button("Fruit \(i)") { state.picked = i }
                    .accessibilityIdentifier("fruit-\(i)")
            }
            .listStyle(.plain)
            .accessibilityIdentifier("fruits")
        }
        .padding()
        .sheet(isPresented: $state.showSheet) {
            VStack(spacing: 16) {
                Text("A SwiftUI sheet")
                Button("Done") { state.showSheet = false }
                    .accessibilityIdentifier("done")
            }
            .presentationDetents([.medium])
        }
    }
}
