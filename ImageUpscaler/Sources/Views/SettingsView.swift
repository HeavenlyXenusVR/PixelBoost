import SwiftUI

struct SettingsView: View {
    @AppStorage(ServerConfig.baseURLDefaultsKey) private var serverURLString: String = ""

    var body: some View {
        Form {
            Section {
                TextField("https://your-server.example.com", text: $serverURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Upscaler-Bridge Server")
            } footer: {
                Text("Optional. If set, every upscale (success or failure) is logged here — source image size, technique/model used, tile config, timing. Leave empty to disable logging entirely. See server/README.md in the repo for how to deploy one.")
            }

            Section {
                LabeledContent("Device ID", value: DeviceIdentity.current)
            } header: {
                Text("This Device")
            } footer: {
                Text("A random identifier generated once per install — there are no user accounts, so this is just how history entries are grouped per device.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
