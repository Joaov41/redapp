//
//  ChatGPTPlanSettingsView.swift
//  redapp
//
//  Settings → AI Models block for the ChatGPT provider: account, model,
//  reasoning effort, and Fast/Normal. Shown only in local builds.
//

import SwiftUI

struct ChatGPTPlanSettingsView: View {
    @ObservedObject var summaryService: SummaryService
    @ObservedObject private var plan = ChatGPTPlanService.shared
    @State private var isCheckingConnection = false
    @State private var connectionStatus: String?
    @State private var customModel = ""

    private var settings: AppSettings { summaryService.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ChatGPT")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Runs requests on your own ChatGPT Plus or Pro plan. OpenAI allows this for personal apps run locally, so it only appears in builds installed from Xcode.")
                .font(.caption)
                .foregroundColor(.secondary)

            accountRow

            if plan.status == .connected {
                modelControls
            }

            if let lastError = plan.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .task {
            // New models roll out often; reload the account's list each time Settings opens.
            if plan.status == .connected, !plan.isLoadingModels {
                await plan.refreshModels()
            }
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        switch plan.status {
        case .connected:
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundColor(RedappDesign.positive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.accountLabel.map { "Signed in as \($0)" } ?? "Signed in")
                        .font(.subheadline)
                    Text(plan.planUsageGranted ? "Using ChatGPT plan" : "Plan usage not granted")
                        .font(.caption)
                        .foregroundColor(plan.planUsageGranted ? .secondary : .orange)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Link("Manage usage", destination: ChatGPTPlanService.manageUsageURL)
                    .font(.subheadline)

                Spacer()

                Button(role: .destructive) {
                    connectionStatus = nil
                    Task { await plan.disconnect() }
                } label: {
                    Text("Disconnect")
                }
                .buttonStyle(LiquidGlassButtonStyle())
            }
        case .connecting:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Waiting for ChatGPT sign-in…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        case .disconnected, .reauthRequired:
            if plan.status == .reauthRequired {
                Text("Your ChatGPT connection expired. Sign in again to keep using your plan.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Button {
                Task { await plan.signIn() }
            } label: {
                HStack {
                    Image(systemName: "person.badge.key")
                    Text("Sign in with ChatGPT")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiquidGlassButtonStyle(isProminent: true))
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        HStack(spacing: 10) {
            if plan.models.isEmpty {
                Text(plan.isLoadingModels ? "Loading models…" : "No models loaded")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Picker("Model", selection: Binding(
                    get: { settings.chatGPTModel.isEmpty ? (plan.models.first?.slug ?? "") : settings.chatGPTModel },
                    set: { summaryService.setChatGPTModel($0) }
                )) {
                    ForEach(plan.models) { model in
                        Text(model.displayName).tag(model.slug)
                    }
                    ForEach(customModelSlugs, id: \.self) { slug in
                        Text(slug).tag(slug)
                    }
                }
                .pickerStyle(.menu)
            }

            Spacer()

            Button {
                Task { await plan.refreshModels() }
            } label: {
                if plan.isLoadingModels {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .disabled(plan.isLoadingModels)
            .accessibilityLabel("Reload models")
        }

        HStack(spacing: 10) {
            TextField("Other model by name, e.g. gpt-6.1-sol", text: $customModel)
                .textFieldStyle(LiquidGlassTextFieldStyle())
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onSubmit(useCustomModel)

            Button("Use", action: useCustomModel)
                .buttonStyle(LiquidGlassButtonStyle())
                .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if plan.reasoningSupport != .unsupported {
            Picker("Reasoning", selection: Binding(
                get: { settings.chatGPTReasoningEffort },
                set: { summaryService.setChatGPTReasoningEffort($0) }
            )) {
                Text(plan.defaultReasoningEffort(forModel: selectedModelSlug).map { "Default (\(Self.effortLabel($0)))" } ?? "Default").tag("")
                ForEach(plan.reasoningEfforts(forModel: selectedModelSlug), id: \.self) { effort in
                    Text(Self.effortLabel(effort)).tag(effort)
                }
            }
            .pickerStyle(.menu)
        }

        if plan.fastSupport != .unsupported, let fastTier = plan.fastTier(forModel: selectedModelSlug) {
            Picker("Speed", selection: Binding(
                get: { settings.chatGPTFastMode },
                set: { summaryService.setChatGPTFastMode($0) }
            )) {
                Text("Normal").tag(false)
                Text("Fast").tag(true)
            }
            .pickerStyle(.segmented)

            if plan.fastIgnoredModels.contains(selectedModelSlug) {
                Text("OpenAI accepted Fast for this model on your last request but ran it at normal speed, so Fast currently has no effect here.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if settings.chatGPTFastMode {
                Text(fastTier.description.map { "Fast: \($0)." } ?? "Fast uses priority processing and can use your plan allowance faster.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        if plan.reasoningSupport == .unknown || plan.fastSupport == .unknown {
            Text("Check Connection confirms which of these options your plan accepts. Options it rejects are hidden.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        HStack(spacing: 10) {
            Button {
                isCheckingConnection = true
                connectionStatus = nil
                Task {
                    connectionStatus = await plan.checkConnection(settings: settings)
                    isCheckingConnection = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isCheckingConnection {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Text("Check Connection")
                }
            }
            .buttonStyle(LiquidGlassButtonStyle())
            .disabled(isCheckingConnection)

            if let connectionStatus {
                Text(connectionStatus)
                    .font(.caption)
                    .foregroundColor(connectionStatus.hasPrefix("Connected") ? .green : .red)
            }
        }
    }

    private func useCustomModel() {
        let slug = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return }
        plan.rememberCustomModel(slug)
        summaryService.setChatGPTModel(slug)
        customModel = ""
        connectionStatus = nil
    }

    /// Typed-in models that the catalog does not list, plus the current one.
    private var customModelSlugs: [String] {
        var slugs = plan.customModels.filter { slug in !plan.models.contains { $0.slug == slug } }
        let current = settings.chatGPTModel
        if !current.isEmpty, !plan.models.contains(where: { $0.slug == current }), !slugs.contains(current) {
            slugs.append(current)
        }
        return slugs
    }

    private var selectedModelSlug: String {
        settings.chatGPTModel.isEmpty ? (plan.models.first?.slug ?? "") : settings.chatGPTModel
    }

    private static func effortLabel(_ effort: String) -> String {
        switch effort.lowercased() {
        case "xhigh": return "Extra high"
        case "max": return "Max"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}
