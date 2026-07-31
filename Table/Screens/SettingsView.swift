import SwiftUI
import TableCore

/// DESIGN §5's settings screen. The fields are edited locally and only reach the stores on Save.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var hostURL = ""
    @State private var apiKey = ""
    @State private var allowInsecureHTTP = false
    @State private var isKeyVisible = false

    private var edited: TableSettings {
        TableSettings(hostURL: hostURL, apiKey: apiKey, allowInsecureHTTP: allowInsecureHTTP)
    }

    var body: some View {
        Form {
            Section {
                TextField("Host URL", text: $hostURL, prompt: Text("https://files.example.com"))
                    .textContentType(.URL)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                apiKeyField
            }
            Section {
                // Conformance rule 13: refused unless the user turns this on deliberately.
                Toggle("Allow plain http://", isOn: $allowInsecureHTTP)
                Text("Only for a server you trust on your own network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Save") { model.save(edited) }
                        .disabled(!edited.isConfigured)
                    Button("Test connection") { model.testConnection(edited) }
                        .disabled(!edited.isConfigured)
                }
                if let test = model.connectionTest {
                    ConnectionTestResult(test)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(macOS)
        .frame(width: 460)
        .scenePadding()
        #endif
        .onAppear {
            hostURL = model.settings.hostURL
            apiKey = model.settings.apiKey
            allowInsecureHTTP = model.settings.allowInsecureHTTP
        }
    }

    @ViewBuilder
    private var apiKeyField: some View {
        HStack {
            if isKeyVisible {
                TextField("API key", text: $apiKey)
            } else {
                SecureField("API key", text: $apiKey)
            }
            Button(
                isKeyVisible ? "Hide API key" : "View API key",
                systemImage: isKeyVisible ? "eye.slash" : "eye"
            ) {
                isKeyVisible.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }
}

private struct ConnectionTestResult: View {
    private let test: ConnectionTest

    init(_ test: ConnectionTest) {
        self.test = test
    }

    var body: some View {
        switch test {
        case .running:
            Text("Testing…")
        case .reachable(let fileCount):
            Text("Connected — \(fileCount) file(s) on the table.")
        case .unreachable(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}
