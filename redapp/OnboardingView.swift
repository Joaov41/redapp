//  OnboardingView.swift
//  RedditApp

import SwiftUI

struct OnboardingView: View {
    @State private var geminiApiKey: String = ""
    @State private var redditClientId: String = ""
    @State private var redditClientSecret: String = ""
    @State private var redditUsername: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""

    var onComplete: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Text("Enter Your API Keys")
                .font(.title)
                .padding()

            Form {
                Section(header: Text("Gemini API Key")) {
                    TextField("Gemini API Key", text: $geminiApiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
#if os(iOS)
                        .autocapitalization(.none)
#endif
                }

                Section(header: Text("Reddit Client ID")) {
                    TextField("Client ID", text: $redditClientId)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
#if os(iOS)
                        .autocapitalization(.none)
#endif
                }

                Section(header: Text("Reddit Client Secret")) {
                    TextField("Client Secret", text: $redditClientSecret)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
#if os(iOS)
                        .autocapitalization(.none)
#endif
                }

                Section(header: Text("Reddit Username")) {
                    TextField("Username", text: $redditUsername)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
#if os(iOS)
                        .autocapitalization(.none)
#endif
                }
            }
            .frame(maxHeight: 400)

            Button("Save Credentials") {
                saveCredentials()
            }
            .padding()
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Info"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }

    private func saveCredentials() {
        guard !geminiApiKey.isEmpty,
              !redditClientId.isEmpty,
              !redditClientSecret.isEmpty,
              !redditUsername.isEmpty else {
            alertMessage = "Please fill in all fields."
            showAlert = true
            return
        }

        KeychainHelper.shared.save(geminiApiKey, forKey: "geminiApiKey")
        KeychainHelper.shared.save(redditClientId, forKey: "redditClientId")
        KeychainHelper.shared.save(redditClientSecret, forKey: "redditClientSecret")
        KeychainHelper.shared.save(redditUsername, forKey: "redditUsername")

        UserDefaults.standard.set(true, forKey: "isOnboarded")

        alertMessage = "Credentials saved successfully."
        showAlert = true

        onComplete?()
    }
}
