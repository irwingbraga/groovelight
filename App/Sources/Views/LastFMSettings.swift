import SwiftUI

/// Settings, Last.fm: the API account, connecting the user's Last.fm account, and what is sent.
struct LastFMSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(LastFMStore.Keys.scrobble) private var scrobble = true
    @AppStorage(LastFMStore.Keys.nowPlaying) private var nowPlaying = true
    @AppStorage(LastFMStore.Keys.syncLoves) private var syncLoves = true

    var body: some View {
        @Bindable var lastfm = model.lastfm
        Form {
            Section {
                if lastfm.isConnected {
                    LabeledContent("Connected as") {
                        HStack(spacing: 10) {
                            if let url = lastfm.profileURL {
                                Link(lastfm.username ?? "", destination: url)
                            } else {
                                Text(lastfm.username ?? "")
                            }
                            Button("Disconnect") { lastfm.disconnect() }
                        }
                    }
                } else {
                    TextField("API key", text: $lastfm.apiKey, prompt: Text("Paste the API key"))
                        .textContentType(.none)
                        .autocorrectionDisabled()
                    SecureField("Shared secret", text: $lastfm.secret, prompt: Text("Paste the shared secret"))
                    HStack {
                        if lastfm.isConnecting {
                            ProgressView().controlSize(.small)
                            Text("Allow Groovelight on the Last.fm page that opened in your browser…")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { lastfm.cancelConnecting() }
                        } else {
                            Spacer()
                            Button("Connect to Last.fm…") { lastfm.connect() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!lastfm.hasCredentials)
                        }
                    }
                }
            } header: {
                Text("Account")
            } footer: {
                if !lastfm.isConnected {
                    Text("Last.fm needs an API account for Groovelight: create one at [last.fm/api/account/create](https://www.last.fm/api/account/create) (any name and description; the callback URL can stay empty), then paste its API key and shared secret here. The secret and your session are kept in the keychain.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Scrobble songs", isOn: $scrobble)
                Toggle("Show what is playing now on Last.fm", isOn: $nowPlaying)
                Toggle("Love and unlove songs on Last.fm too", isOn: $syncLoves)
            } header: {
                Text("Sharing")
            } footer: {
                Text("A song is scrobbled when it is longer than 30 seconds and was played for half of its length or 4 minutes, whichever comes first. Scrobbles made offline are sent later.")
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Waiting to be sent") {
                    HStack(spacing: 10) {
                        Text("\(lastfm.pendingCount)")
                            .monospacedDigit()
                        if lastfm.isSending { ProgressView().controlSize(.small) }
                        Button("Send Now") { lastfm.sendNow() }
                            .disabled(!lastfm.isConnected || lastfm.pendingCount == 0 || lastfm.isSending)
                    }
                }
                if let date = lastfm.lastSentAt {
                    LabeledContent("Last sent", value: date.formatted(.relative(presentation: .named)))
                }
                if let problem = lastfm.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
