import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct InfographicView: View {
    let htmlData: Data?
    var title: String = "Infographic"
    var filePrefix: String = "infographic"
    var loadingLabel: String? = nil
    var emptyLabel: String? = nil
    var onMinimize: (() -> Void)? = nil
    var onAskAI: ((String, (@MainActor @Sendable (String) -> Void)?) async throws -> String)? = nil
    var onAskAIWeb: ((String, (@MainActor @Sendable (String) -> Void)?) async throws -> String)? = nil
    @Environment(\.dismiss) var dismiss
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var isLoading = true
    @State private var isCapturingSnapshot = false
    @State private var webViewRef: WKWebView?
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var showAskAIResponse = false
    @State private var isAskingAI = false
    @State private var askAIResponse: String?
    @State private var askAIError: String?
    @State private var askAITask: Task<Void, Never>?
    
    private var loadingText: String {
        loadingLabel ?? "Rendering \(title.lowercased())…"
    }
    
    private var emptyText: String {
        emptyLabel ?? "Unable to load \(title.lowercased())"
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let data = htmlData, let htmlString = String(data: data, encoding: .utf8) {
                    ZStack {
                        WebView(htmlContent: htmlString,
                                webView: $webViewRef,
                                isLoading: $isLoading,
                                onAskAI: onAskAI == nil ? nil : { selection in
                                    handleAskAISelection(selection, useWebPath: false)
                                },
                                onAskAIWeb: onAskAIWeb == nil ? nil : { selection in
                                    handleAskAISelection(selection, useWebPath: true)
                                })
                            .edgesIgnoringSafeArea(.bottom)
                        if isLoading {
                            ProgressView(loadingText)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .cornerRadius(12)
                        }
                    }
                        .edgesIgnoringSafeArea(.bottom)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(emptyText)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    HStack(spacing: 12) {
                        Button("Close") {
                            dismiss()
                        }
                        if onMinimize != nil {
                            Button(action: {
                                onMinimize?()
                                dismiss()
                            }) {
                                Label("Minimize", systemImage: "minus.circle")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: snapshotAndCopyImage) {
                        Label("Copy Image", systemImage: "square.on.square")
                    }
                    .disabled(htmlData == nil || webViewRef == nil || isLoading || isCapturingSnapshot)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: snapshotAndSaveImage) {
                        Label("Save Image", systemImage: "arrow.down.doc")
                    }
                    .disabled(htmlData == nil || webViewRef == nil || isLoading || isCapturingSnapshot || isSaving)
                }
            }
            .overlay(alignment: .bottom) {
                if let message = saveMessage {
                    Text(message)
                        .font(.caption)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    saveMessage = nil
                                }
                            }
                        }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showShareSheet, onDismiss: { shareURL = nil }) {
                if let shareURL {
                    ShareSheet(activityItems: [shareURL])
                        .presentationDetents([.medium, .large])
                }
            }
            #endif
            .sheet(isPresented: $showAskAIResponse) {
                AskAIResponseSheet(
                    isLoading: isAskingAI,
                    response: askAIResponse,
                    errorMessage: askAIError,
                    onClose: { showAskAIResponse = false },
                    onCopy: copyAskAIResponse
                )
            }
        }
        .webAIHandoffPresenter(appState: AppState.shared)
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 800)
        #endif
    }

    private func handleAskAISelection(_ selection: String, useWebPath: Bool) {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let handler = useWebPath ? onAskAIWeb : onAskAI
        guard !trimmed.isEmpty, let handler else { return }
        askAITask?.cancel()
        isAskingAI = true
        askAIResponse = ""
        askAIError = nil
        showAskAIResponse = true
        askAITask = Task {
            do {
                let response = try await handler(trimmed, { token in
                    self.askAIResponse = (self.askAIResponse ?? "") + token
                })
                await MainActor.run {
                    self.askAIResponse = response
                    self.isAskingAI = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isAskingAI = false
                }
            } catch {
                await MainActor.run {
                    self.askAIError = error.localizedDescription
                    self.isAskingAI = false
                }
            }
        }
    }
    
    private func copyHTMLToClipboard() {
        guard let data = htmlData, let htmlString = String(data: data, encoding: .utf8) else { return }
        #if os(iOS)
        UIPasteboard.general.string = htmlString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(htmlString, forType: .string)
        #endif
        withAnimation {
            saveMessage = "Copied HTML to clipboard"
        }
    }

    private func captureSnapshot(_ completion: @escaping (Data?) -> Void) {
        guard let webViewRef else { completion(nil); return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let contentSize = webViewRef.scrollView.contentSize
        if contentSize.width > 0 && contentSize.height > 0 {
            #if os(iOS)
            let maxPixels: CGFloat = 24_000_000
            let scale = UIScreen.main.scale
            let maxPointsArea = maxPixels / max(1, (scale * scale))
            let area = contentSize.width * contentSize.height

            if area > maxPointsArea {
                let aspect = max(0.1, contentSize.height / max(1, contentSize.width))
                let targetWidth = min(contentSize.width, sqrt(maxPointsArea / aspect))
                let targetHeight = min(contentSize.height, targetWidth * aspect)
                config.rect = CGRect(origin: .zero, size: CGSize(width: targetWidth, height: targetHeight))
                DispatchQueue.main.async {
                    withAnimation {
                        saveMessage = "Snapshot cropped (content too large)"
                    }
                }
            } else {
                config.rect = CGRect(origin: .zero, size: contentSize)
            }
            #else
            config.rect = CGRect(origin: .zero, size: contentSize)
            #endif
        }

        webViewRef.takeSnapshot(with: config) { image, error in
            DispatchQueue.main.async {
                guard error == nil else { completion(nil); return }
                #if os(iOS)
                completion(image?.pngData())
                #elseif os(macOS)
                if let image, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    completion(png)
                } else {
                    completion(nil)
                }
                #endif
            }
        }
    }

    private func snapshotAndCopyImage() {
        guard htmlData != nil else {
            withAnimation { saveMessage = "Nothing to copy" }
            return
        }
        isCapturingSnapshot = true
        captureSnapshot { data in
            DispatchQueue.main.async {
                self.isCapturingSnapshot = false
                guard let data else {
                    withAnimation { self.saveMessage = "Snapshot failed" }
                    return
                }
                #if os(iOS)
                if let image = UIImage(data: data) {
                    UIPasteboard.general.image = image
                    withAnimation { self.saveMessage = "Copied image to clipboard" }
                } else {
                    withAnimation { self.saveMessage = "Snapshot failed" }
                }
                #elseif os(macOS)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
                withAnimation { self.saveMessage = "Copied image to clipboard" }
                #endif
            }
        }
    }

    private func snapshotAndSaveImage() {
        guard htmlData != nil else {
            withAnimation { saveMessage = "Nothing to save" }
            return
        }
        isCapturingSnapshot = true
        isSaving = true
        captureSnapshot { data in
            DispatchQueue.main.async {
                self.isCapturingSnapshot = false
                self.isSaving = false
                guard let data else {
                    withAnimation { self.saveMessage = "Save failed" }
                    return
                }
                #if os(iOS)
                if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let filename = "\(filePrefix)-\(Int(Date().timeIntervalSince1970)).png"
                    let url = documents.appendingPathComponent(filename)
                    do {
                        try data.write(to: url)
                        withAnimation { self.saveMessage = "Saved to Files: \(filename)" }
                        self.shareURL = url
                        self.showShareSheet = true
                    } catch {
                        withAnimation { self.saveMessage = "Save failed" }
                    }
                } else {
                    withAnimation { self.saveMessage = "Save failed" }
                }
                #elseif os(macOS)
                if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    let filename = "\(filePrefix)-\(Int(Date().timeIntervalSince1970)).png"
                    let url = downloads.appendingPathComponent(filename)
                    do {
                        try data.write(to: url)
                        withAnimation { self.saveMessage = "Saved to \(url.lastPathComponent)" }
                    } catch {
                        withAnimation { self.saveMessage = "Save failed" }
                    }
                } else {
                    withAnimation { self.saveMessage = "Save failed" }
                }
                #endif
            }
        }
    }

    private func copyAskAIResponse() {
        guard let askAIResponse, !askAIResponse.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = askAIResponse
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(askAIResponse, forType: .string)
        #endif
    }
}

#if os(iOS)
struct AskAIResponseSheet: View {
    let isLoading: Bool
    let response: String?
    let errorMessage: String?
    let onClose: () -> Void
    let onCopy: () -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    ProgressView("Asking AI…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let response {
                    ScrollView {
                        ReadableReplyText(content: response, fontScale: 0.9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onClose()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if response != nil {
                        Button("Copy") {
                            onCopy()
                        }
                    }
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool
    var onAskAI: ((String) -> Void)? = nil
    var onAskAIWeb: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = onAskAI != nil || onAskAIWeb != nil
        let webView: WKWebView
        if onAskAI != nil || onAskAIWeb != nil {
            let askAIWebView = AskAIWebView(frame: .zero, configuration: config)
            askAIWebView.onAskAI = onAskAI
            askAIWebView.onAskAIWeb = onAskAIWeb
            askAIWebView.installAskAIMenuItemIfNeeded()
            webView = askAIWebView
        } else {
            webView = WKWebView(frame: .zero, configuration: config)
        }
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
#if os(iOS)
        if (onAskAI != nil || onAskAIWeb != nil), #available(iOS 16.0, *) {
            context.coordinator.installEditMenuInteraction(on: webView)
        }
#endif
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        DispatchQueue.main.async {
            self.webView = webView
        }
        context.coordinator.lastHTML = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        uiView.loadHTMLString(htmlContent, baseURL: nil)

        if let askAIWebView = uiView as? AskAIWebView {
            askAIWebView.onAskAI = onAskAI
            askAIWebView.onAskAIWeb = onAskAIWeb
            askAIWebView.installAskAIMenuItemIfNeeded()
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, UIEditMenuInteractionDelegate {
        var parent: WebView
        var lastHTML: String?
        weak var webView: WKWebView?
        private var editMenuInteraction: UIEditMenuInteraction?
        init(parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        // Handle link clicks - open external links in Safari
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            // For link clicks, open in Safari
            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }

        @available(iOS 16.0, *)
        func installEditMenuInteraction(on webView: WKWebView) {
            guard editMenuInteraction == nil else { return }
            let interaction = UIEditMenuInteraction(delegate: self)
            webView.addInteraction(interaction)
            editMenuInteraction = interaction
        }

        @available(iOS 16.0, *)
        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard parent.onAskAI != nil || parent.onAskAIWeb != nil else {
                return UIMenu(children: suggestedActions)
            }
            var actions: [UIMenuElement] = []
            if parent.onAskAI != nil {
                actions.append(UIAction(title: "Ask AI", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                    self?.sendSelectionToAskAI(useWebPath: false)
                })
            }
            if parent.onAskAIWeb != nil {
                actions.append(UIAction(title: "Ask AI Web", image: UIImage(systemName: "globe")) { [weak self] _ in
                    self?.sendSelectionToAskAI(useWebPath: true)
                })
            }
            return UIMenu(children: suggestedActions + actions)
        }

        private func sendSelectionToAskAI(useWebPath: Bool) {
            guard let webView else { return }
            webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, error in
                guard error == nil, let selection = result as? String else { return }
                let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                DispatchQueue.main.async {
                    if useWebPath {
                        self?.parent.onAskAIWeb?(trimmed)
                    } else {
                        self?.parent.onAskAI?(trimmed)
                    }
                }
            }
        }
    }
}

final class AskAIWebView: WKWebView {
    var onAskAI: ((String) -> Void)?
    var onAskAIWeb: ((String) -> Void)?

    override var canBecomeFirstResponder: Bool {
        true
    }

    func installAskAIMenuItemIfNeeded() {
        guard onAskAI != nil || onAskAIWeb != nil else { return }
        let askSelector = #selector(askAI(_:))
        let askWebSelector = #selector(askAIWeb(_:))
        let existingItems = UIMenuController.shared.menuItems ?? []
        var newItems = existingItems
        if onAskAI != nil && !newItems.contains(where: { $0.action == askSelector }) {
            newItems.append(UIMenuItem(title: "Ask AI", action: askSelector))
        }
        if onAskAIWeb != nil && !newItems.contains(where: { $0.action == askWebSelector }) {
            newItems.append(UIMenuItem(title: "Ask AI Web", action: askWebSelector))
        }
        UIMenuController.shared.menuItems = newItems
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(askAI(_:)) {
            return onAskAI != nil
        }
        if action == #selector(askAIWeb(_:)) {
            return onAskAIWeb != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func askAI(_ sender: Any?) {
        askSelectedText(useWebPath: false)
    }

    @objc private func askAIWeb(_ sender: Any?) {
        askSelectedText(useWebPath: true)
    }

    private func askSelectedText(useWebPath: Bool) {
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, error in
            guard let self, error == nil, let selection = result as? String else { return }
            let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async {
                if useWebPath {
                    self.onAskAIWeb?(trimmed)
                } else {
                    self.onAskAI?(trimmed)
                }
            }
        }
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        var actions: [UIMenuElement] = []
        if onAskAI != nil {
            actions.append(UIAction(title: "Ask AI", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.askAI(nil)
            })
        }
        if onAskAIWeb != nil {
            actions.append(UIAction(title: "Ask AI Web", image: UIImage(systemName: "globe")) { [weak self] _ in
                self?.askAIWeb(nil)
            })
        }
        guard !actions.isEmpty else { return }
        let menu = UIMenu(title: "", options: .displayInline, children: actions)
        builder.insertChild(menu, atEndOfMenu: .edit)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
struct WebView: NSViewRepresentable {
    let htmlContent: String
    @Binding var webView: WKWebView?
    @Binding var isLoading: Bool
    var onAskAI: ((String) -> Void)? = nil
    var onAskAIWeb: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        DispatchQueue.main.async {
            self.webView = webView
        }
        context.coordinator.lastHTML = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != htmlContent else { return }
        context.coordinator.lastHTML = htmlContent
        nsView.loadHTMLString(htmlContent, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        var lastHTML: String?
        init(parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        // Handle link clicks - open external links in default browser
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial HTML load
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            // For link clicks, open in default browser
            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }
    }
}
#endif
