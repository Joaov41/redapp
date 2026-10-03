import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTENT_VIEW = ROOT / "redapp" / "ContentView.swift"
INFOGRAPHIC_VIEW = ROOT / "redapp" / "InfographicView.swift"
WEB_AI_HANDOFF_VIEW = ROOT / "redapp" / "WebAIHandoffView.swift"


class MacAskAIWebRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = CONTENT_VIEW.read_text()
        cls.infographic = INFOGRAPHIC_VIEW.read_text()
        cls.web_ai_handoff = WEB_AI_HANDOFF_VIEW.read_text()

    def test_selectable_text_exposes_standard_and_web_actions(self):
        self.assertIn("askAISelectionHandler", self.content)
        self.assertIn("askAIWebSelectionHandler", self.content)
        self.assertIn('NSMenuItem(title: "Ask AI"', self.content)
        self.assertIn('NSMenuItem(title: "Ask AI Web"', self.content)
        self.assertIn('UIMenuItem(title: "Ask AI"', self.content)
        self.assertIn('UIMenuItem(title: "Ask AI Web"', self.content)

    def test_batch_summary_wires_standard_and_web_paths(self):
        self.assertIn("askAIFromBatchSelection(selection)", self.content)
        self.assertIn("askAIWebFromBatchSelection(selection)", self.content)
        self.assertIn("askAIWebResponseForBatchSelection", self.content)
        self.assertRegex(
            self.content,
            r"askAIWebResponseForBatchSelection[\s\S]*performWebAIRequestAsync",
        )
        self.assertRegex(
            self.content,
            r"askQuestionFromSelection[\s\S]*SummaryService\.shared\.summarize",
        )
        self.assertIn(".environment(\\.askAISelectionHandler, askAIHandler)", self.content)
        self.assertIn(".environment(\\.askAIWebSelectionHandler, askAIWebHandler)", self.content)

    def test_table_and_infographic_surfaces_have_web_action(self):
        self.assertRegex(self.content, r"struct TableSummaryView[\s\S]*var onAskAIWeb")
        self.assertRegex(self.content, r"TableSummaryView\([\s\S]*onAskAIWeb:")
        self.assertRegex(self.infographic, r"struct InfographicView[\s\S]*var onAskAIWeb")
        self.assertIn('UIAction(title: "Ask AI Web"', self.infographic)
        self.assertIn('UIMenuItem(title: "Ask AI Web"', self.infographic)

    def test_reddit_summary_and_answer_surfaces_receive_both_actions(self):
        self.assertRegex(self.content, r"struct PostSummaryView[\s\S]*var onAskAIWeb")
        self.assertRegex(self.content, r"struct CommentSummaryView[\s\S]*var onAskAIWeb")
        self.assertRegex(self.content, r"struct ResizableTextBox[\s\S]*var onAskAIWeb")
        self.assertRegex(self.content, r"PostSummaryView\([\s\S]*onAskAI:\s*\{\s*selection,\s*onPartial in[\s\S]*useWebPath:\s*false[\s\S]*onAskAIWeb:\s*\{\s*selection,\s*onPartial in[\s\S]*useWebPath:\s*true")
        self.assertRegex(self.content, r"CommentSummaryView\([\s\S]*onAskAI:\s*\{\s*selection,\s*onPartial in[\s\S]*useWebPath:\s*false[\s\S]*onAskAIWeb:\s*\{\s*selection,\s*onPartial in[\s\S]*useWebPath:\s*true")
        self.assertRegex(self.content, r"ResizableTextBox\([\s\S]*onSummarizeClicked:\s*summarizeAnswer,[\s\S]*onAskAI:\s*askAIHandler[\s\S]*onAskAIWeb:\s*askAIWebHandler")
        self.assertEqual(
            self.content.count(".webAIHandoffPresenter(appState: AppState.shared)"),
            1,
            "The WebAI handoff presenter should be mounted only once at the app root.",
        )

    def test_web_path_uses_hidden_handoff_and_response_sheet(self):
        self.assertRegex(self.content, r"askAIWebFromBatchSelection[\s\S]*showSelectionAskAIResponse\s*=\s*true")
        self.assertRegex(self.content, r"struct TableSummaryView[\s\S]*showAskAIResponse\s*=\s*true")
        self.assertRegex(self.content, r"struct PostSummaryView[\s\S]*showAskAIResponse\s*=\s*true")
        self.assertRegex(self.content, r"struct CommentSummaryView[\s\S]*showSelectionAskAIResponse\s*=\s*true")
        self.assertRegex(self.infographic, r"showAskAIResponse\s*=\s*true")
        self.assertRegex(self.content, r"func performWebAIRequestAsync\([\s\S]*responseFormat:\s*WebAIResponseFormat\s*=\s*\.plainText")
        self.assertRegex(self.content, r"shouldAutoCapture:\s*true,[\s\S]*shouldStartMinimized:\s*true")
        self.assertRegex(self.content, r"if activeWebAIHandoffRequest == nil && !isWebAIBatchHandoffInProgress[\s\S]*isWebAIHandoffMinimized = request\.shouldStartMinimized")
        self.assertRegex(self.web_ai_handoff, r"restoreButton[\s\S]*request\.shouldAutoCapture[\s\S]*Tap to open")
        self.assertRegex(self.web_ai_handoff, r"appState\.minimizeActiveWebAIHandoff\(\)[\s\S]*\.frame\(width:\s*56,\s*height:\s*56\)[\s\S]*\.zIndex\(3\)")

    def test_mac_response_sheet_has_loading_and_empty_states(self):
        self.assertRegex(self.infographic, r"struct AskAIResponseSheet[\s\S]*ProgressView\(\)[\s\S]*Asking AI")
        self.assertRegex(self.infographic, r"struct AskAIResponseSheet[\s\S]*No response received")
        self.assertRegex(self.infographic, r"struct AskAIResponseSheet[\s\S]*@ObservedObject private var appState = AppState\.shared")
        self.assertIn('"Open \\(request.provider.displayName)"', self.infographic)
        self.assertRegex(self.infographic, r"struct AskAIResponseSheet[\s\S]*Button\(\"Minimize\"\)")
        self.assertRegex(self.infographic, r"struct AskAIResponseSheet[\s\S]*minimizeActiveWebAIHandoff\(\)")
        self.assertRegex(self.infographic, r"struct AskAIResponseSheet[\s\S]*restoreMinimizedWebAIHandoff")
        self.assertNotIn(".webAIHandoffPresenter(appState: appState)", self.infographic)

    def test_reddit_standard_path_uses_selected_provider_and_web_path_uses_web_model(self):
        self.assertIn("askAIResponseForRedditSelection", self.content)
        self.assertRegex(
            self.content,
            r"askAIResponseForRedditSelection[\s\S]*if useWebPath[\s\S]*performWebAIRequestAsync",
        )
        self.assertRegex(
            self.content,
            r"askAIResponseForRedditSelection[\s\S]*SummaryService\.shared\.summarize",
        )

    def test_web_handoff_uses_rss_capture_and_selects_gemini_lite_before_submit(self):
        self.assertIn("window.__webAICapture.start", self.web_ai_handoff)
        self.assertIn("WKUIDelegate", self.web_ai_handoff)
        self.assertIn("javaScriptCanOpenWindowsAutomatically = true", self.web_ai_handoff)
        self.assertIn("webView.uiDelegate = coordinator", self.web_ai_handoff)
        self.assertNotIn("chatGPTDiagnosticsScript", self.web_ai_handoff)
        self.assertNotIn('phase: "chatgpt-dom"', self.web_ai_handoff)
        self.assertIn("let usesPrivateStore = provider == .chatgpt", self.web_ai_handoff)
        self.assertIn("let requiresFreshWebView = usesPrivateStore", self.web_ai_handoff)
        self.assertIn("configuration.websiteDataStore = usesPrivateStore ? .nonPersistent() : websiteDataStore", self.web_ai_handoff)
        self.assertIn("let delaysCaptureBootstrap = false", self.web_ai_handoff)
        self.assertIn("webView.customUserAgent = nil", self.web_ai_handoff)
        self.assertNotIn("chatGPTIOSUserAgent", self.web_ai_handoff)
        self.assertNotIn("applicationNameForUserAgent", self.web_ai_handoff)
        self.assertIn("createWebViewWith configuration", self.web_ai_handoff)
        self.assertIn("navigationAction.targetFrame == nil", self.web_ai_handoff)
        self.assertRegex(self.web_ai_handoff, r"func webView\(_ webView: WKWebView, didCommit navigation: WKNavigation!\)[\s\S]*parent\.request\.provider == \.chatgpt[\s\S]*scheduleReadyWork\(in: webView\)")
        self.assertIn("document.querySelector(\"button[aria-label='Send message']\")", self.web_ai_handoff)
        self.assertIn("dispatchEnter(input);", self.web_ai_handoff)
        self.assertIn("function blurComposer(el)", self.web_ai_handoff)
        self.assertNotIn("function chatGPTNeedsLogin()", self.web_ai_handoff)
        self.assertNotIn('return "loginRequired";', self.web_ai_handoff)
        self.assertIn("function chatGPTBlockingError()", self.web_ai_handoff)
        self.assertIn('status: "blocked"', self.web_ai_handoff)
        self.assertIn("ChatGPT showed an error in redapp", self.web_ai_handoff)
        self.assertIn('document.execCommand("insertText", false, inserted)', self.web_ai_handoff)
        self.assertRegex(self.web_ai_handoff, r"if \(provider === \"chatgpt\"\) \{[\s\S]*return insertContentEditableText\(el, value\);[\s\S]*\}")
        self.assertIn("let prefersNativeClick = parent.request.provider == .gemini ? \"true\" : \"false\"", self.web_ai_handoff)
        self.assertIn("const prefersNativeClick = \\(prefersNativeClick);", self.web_ai_handoff)
        self.assertIn('if (prefersNativeClick) return "nativeClick:" + pointFromNode(sendButton);', self.web_ai_handoff)
        self.assertRegex(self.web_ai_handoff, r"if \(provider === \"chatgpt\"\)[\s\S]*sendButton\.click\(\);[\s\S]*blurComposer\(input\);[\s\S]*return \"success\";")
        self.assertRegex(self.web_ai_handoff, r"if \(provider === \"chatgpt\"\)[\s\S]*retryButton\.click\(\);[\s\S]*blurComposer\(input\);[\s\S]*return \"success\";")
        self.assertIn("function findGeminiSendButton(input)", self.web_ai_handoff)
        self.assertIn("function activateAction(node)", self.web_ai_handoff)
        self.assertIn("function pointFromNode(node)", self.web_ai_handoff)
        self.assertIn('return "nativeClick:" + pointFromNode(sendButton);', self.web_ai_handoff)
        self.assertIn("performNativeWebClick(payload: payload, in: webView)", self.web_ai_handoff)
        self.assertIn("checkSubmissionStarted(in: webView)", self.web_ai_handoff)
        self.assertIn("pollForExtractedResponse(in: webView", self.web_ai_handoff)
        self.assertIn("decodeExtractionResult(from: result)", self.web_ai_handoff)
        self.assertIn("[data-testid*='response']", self.web_ai_handoff)
        self.assertIn("[class*='response-container']", self.web_ai_handoff)
        self.assertIn("main [dir='ltr']", self.web_ai_handoff)
        self.assertIn("function isPageBoilerplate(value)", self.web_ai_handoff)
        self.assertIn("gemini is ai and can make mistakes", self.web_ai_handoff)
        self.assertIn("opens in a new window", self.web_ai_handoff)
        self.assertIn("promptInstructionPrefixes", self.web_ai_handoff)
        self.assertIn("answer using only the context above", self.web_ai_handoff)
        self.assertIn('replacingOccurrences(of: "\\u{2028}", with: "\\\\u2028")', self.web_ai_handoff)
        self.assertIn('replacingOccurrences(of: "\\u{2029}", with: "\\\\u2029")', self.web_ai_handoff)
        self.assertIn('"WKJavaScriptExceptionMessage"', self.web_ai_handoff)
        self.assertRegex(self.web_ai_handoff, r"private func buildExtractionScript\(\)[\s\S]*try \{[\s\S]*status: \"waiting\"")
        self.assertIn("document.elementFromPoint(x, y)", self.web_ai_handoff)
        self.assertIn("const staleStreaming = s.responseFormat !== \"strictJSON\"", self.web_ai_handoff)
        self.assertIn("(!streaming || staleStreaming)", self.web_ai_handoff)
        self.assertIn("function isVisibleControl(node)", self.web_ai_handoff)
        self.assertIn("node.getAttribute(\"aria-hidden\") !== \"true\"", self.web_ai_handoff)
        self.assertNotIn("document.querySelector(\"[aria-busy='true']\") ||\\n                  document.querySelector(\"[data-state='streaming']\")", self.web_ai_handoff)
        self.assertIn('return "waiting";', self.web_ai_handoff)
        self.assertIn("minLength: \\(parent.request.responseFormat == .strictJSON ? 40 : 24)", self.web_ai_handoff)
        self.assertIn("let stablePlainText = self.parent.request.responseFormat != .strictJSON", self.web_ai_handoff)
        self.assertRegex(self.web_ai_handoff, r"guard attempt < maxExtractionAttempts else \{[\s\S]*finishWithCaptureFailure\(\)")
        self.assertIn("window.__codexGeminiLiteSelectionState", self.web_ai_handoff)
        self.assertIn('includes("flash-lite")', self.web_ai_handoff)
        self.assertIn('provider === "chatgpt" || provider === "gemini"', self.web_ai_handoff)
        self.assertIn("https://gemini.google.com/app", self.web_ai_handoff)
        self.assertIn("message-content", self.web_ai_handoff)
        self.assertRegex(
            self.web_ai_handoff,
            r"const geminiModelStatus = selectGeminiModelIfNeeded\(\);[\s\S]*if \(geminiModelStatus === \"waiting\"\) return \"waiting\";[\s\S]*if \(!setValue\(input, text\)\) return \"waiting\";",
        )
        self.assertNotIn("performNativeGeminiSubmit", self.web_ai_handoff)
        self.assertNotIn("postWindowMouseClick", self.web_ai_handoff)
        self.assertNotIn("CGEvent(", self.web_ai_handoff)


if __name__ == "__main__":
    unittest.main()
