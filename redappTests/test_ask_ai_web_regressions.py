import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTENT_VIEW = ROOT / "redapp" / "ContentView.swift"
INFOGRAPHIC_VIEW = ROOT / "redapp" / "InfographicView.swift"
WEB_AI_HANDOFF_VIEW = ROOT / "redapp" / "WebAIHandoffView.swift"


class AskAIWebRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = CONTENT_VIEW.read_text()
        cls.infographic = INFOGRAPHIC_VIEW.read_text()
        cls.web_ai_handoff = WEB_AI_HANDOFF_VIEW.read_text()

    def test_selectable_text_exposes_standard_and_web_actions(self):
        self.assertIn("askAISelectionHandler", self.content)
        self.assertIn("askAIWebSelectionHandler", self.content)
        self.assertIn('UIMenuItem(title: "Ask AI"', self.content)
        self.assertIn('UIMenuItem(title: "Ask AI Web"', self.content)
        self.assertIn('UIAction(title: "Ask AI"', self.content)
        self.assertIn('UIAction(title: "Ask AI Web"', self.content)

    def test_batch_summary_wires_selected_provider_and_web_paths(self):
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
        self.assertRegex(
            self.content,
            r"PostSummaryView\([\s\S]*onAskAI:\s*\{ selection, onPartial in[\s\S]*useWebPath:\s*false[\s\S]*onAskAIWeb:\s*\{ selection, onPartial in[\s\S]*useWebPath:\s*true",
        )
        self.assertRegex(
            self.content,
            r"CommentSummaryView\([\s\S]*onAskAI:\s*\{ selection, onPartial in[\s\S]*useWebPath:\s*false[\s\S]*onAskAIWeb:\s*\{ selection, onPartial in[\s\S]*useWebPath:\s*true",
        )
        self.assertRegex(
            self.content,
            r"struct PostSummaryView[\s\S]*@State private var showAskAIResponse[\s\S]*\.sheet\(isPresented: \$showAskAIResponse\)",
        )
        self.assertRegex(
            self.content,
            r"struct CommentSummaryView[\s\S]*@State private var showAskAIResponse[\s\S]*\.sheet\(isPresented: \$showAskAIResponse\)",
        )
        self.assertRegex(self.content, r"ResizableTextBox\([\s\S]*onSummarizeClicked:\s*summarizeAnswer,[\s\S]*onAskAI:\s*askAIHandler[\s\S]*onAskAIWeb:\s*askAIWebHandler")

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

    def test_reddit_comment_question_row_uses_selected_provider(self):
        self.assertRegex(
            self.content,
            r"private func askQuestion\(\)[\s\S]*let provider = summaryService\.settings\.selectedSummaryProvider[\s\S]*if provider == \.webAI[\s\S]*performWebAIRequestAsync",
        )
        self.assertRegex(
            self.content,
            r"private func askQuestion\(\)[\s\S]*prepareAppleLocalCommentPrompt[\s\S]*SummaryService\.shared\.summarize",
        )

    def test_reddit_comment_summary_and_batch_web_surfaces_use_shared_web_handoff(self):
        self.assertRegex(
            self.content,
            r"private func openWebCommentSummary\(isShort: Bool\)[\s\S]*appState\.performWebAIRequest\(",
        )
        self.assertRegex(
            self.content,
            r"private func generateFinalSummary\(subreddit: String\) async[\s\S]*selectedSummaryProvider == \.webAI[\s\S]*performWebAIRequestAsync",
        )
        self.assertRegex(
            self.content,
            r"private func openWebOverallSummary\(\)[\s\S]*appState\.performWebAIRequest\(",
        )
        self.assertRegex(
            self.content,
            r"private func openWebCategorizedSummary\(\)[\s\S]*appState\.performWebAIRequest\(",
        )
        self.assertRegex(
            self.content,
            r"private func openWebTableSummary\(\)[\s\S]*appState\.performWebAIRequest\(",
        )

    def test_comment_summary_sheet_matches_mac_web_question_path(self):
        self.assertRegex(
            self.content,
            r"struct CommentSummaryView[\s\S]*if summaryService\.settings\.selectedSummaryProvider != \.webAI \{[\s\S]*Button\(action: openWebCommentQuestion\)",
        )
        self.assertRegex(
            self.content,
            r"struct CommentSummaryView[\s\S]*private func openWebCommentQuestion\(\)[\s\S]*performWebAIRequestAsync",
        )

    def test_reddit_deep_analysis_sheet_routes_standard_and_forced_web_paths(self):
        self.assertRegex(
            self.content,
            r"struct CommentAnalyticsView[\s\S]*var forceWebAI: Bool = false",
        )
        self.assertRegex(
            self.content,
            r"struct RedditCommentsView[\s\S]*private enum AnalyticsLaunchMode",
        )
        self.assertRegex(
            self.content,
            r"activeAnalyticsLaunchMode = \.standard",
        )
        self.assertRegex(
            self.content,
            r"\.sheet\(item: \$activeAnalyticsLaunchMode\)[\s\S]*forceWebAI: launchMode\.forceWebAI",
        )
        self.assertRegex(
            self.content,
            r"private func openWebCommentAnalysis\(\)[\s\S]*activeAnalyticsLaunchMode = \.webAI",
        )
        self.assertRegex(
            self.content,
            r"struct CommentAnalyticsView[\s\S]*if forceWebAI \|\| SummaryService\.shared\.settings\.selectedSummaryProvider == \.webAI[\s\S]*performWebAIRequestAsync",
        )

    def test_shared_web_handoff_uses_mac_prompt_injection_and_capture_flow(self):
        self.assertIn("WKUIDelegate", self.web_ai_handoff)
        self.assertIn("window.__webAICapture.start", self.web_ai_handoff)
        self.assertIn("javaScriptCanOpenWindowsAutomatically = true", self.web_ai_handoff)
        self.assertIn("webView.uiDelegate = coordinator", self.web_ai_handoff)
        self.assertIn("handlePromptInjectionSucceeded(in: webView)", self.web_ai_handoff)
        self.assertIn("captureFallbackExtractionBaseline(in: webView)", self.web_ai_handoff)
        self.assertIn("startFallbackExtractionPollingIfNeeded(in: webView)", self.web_ai_handoff)
        self.assertIn('document.execCommand("insertText", false, inserted)', self.web_ai_handoff)
        self.assertIn("function findGeminiSendButton(input)", self.web_ai_handoff)
        self.assertIn("performNativeWebClick(payload: payload, in: webView)", self.web_ai_handoff)
        self.assertIn("window.__codexGeminiLiteSelectionState", self.web_ai_handoff)
        self.assertIn("function isGeminiBoilerplateText(value)", self.web_ai_handoff)
        self.assertIn("function stripGeminiBoilerplate(value)", self.web_ai_handoff)
        self.assertIn("message-content", self.web_ai_handoff)
        self.assertIn('baselineText: cleanText(baselineNode)', self.web_ai_handoff)
        self.assertIn('const latestText = cleanText(latest);', self.web_ai_handoff)

    def test_ios_chatgpt_handoff_matches_working_mac_launch_and_visible_composer_selection(self):
        self.assertRegex(
            self.web_ai_handoff,
            r"func webView\(_ webView: WKWebView, didCommit navigation: WKNavigation!\)[\s\S]*parent\.request\.provider == \.chatgpt",
        )
        self.assertIn('if ((provider === "chatgpt" || provider === "gemini") && shouldAutoCapture)', self.web_ai_handoff)
        self.assertIn('status == "chatgptVerify"', self.web_ai_handoff)
        self.assertIn("checkChatGPTSubmissionStarted", self.web_ai_handoff)
        self.assertIn("function findChatGPTSendButton(input)", self.web_ai_handoff)
        self.assertIn("function looksLikeChatGPTSendButton(node)", self.web_ai_handoff)
        self.assertIn("function dispatchSyntheticInput(node, inserted, inputType)", self.web_ai_handoff)
        self.assertIn('dispatchSyntheticInput(node, inserted, "insertFromPaste")', self.web_ai_handoff)
        self.assertIn('window.__codexChatGPTSendState = "activate"', self.web_ai_handoff)
        self.assertIn('window.__codexChatGPTSendState = "click"', self.web_ai_handoff)
        self.assertIn('window.__codexChatGPTSendState = "enter"', self.web_ai_handoff)
        self.assertIn('return "chatgptVerify";', self.web_ai_handoff)
        self.assertIn("blurComposer(input);", self.web_ai_handoff)
        self.assertIn("private func stagePromptIfNeeded", self.web_ai_handoff)
        self.assertIn("private func validateStagedPrompt", self.web_ai_handoff)
        self.assertIn("private func capturePromptFallbackText()", self.web_ai_handoff)
        self.assertIn("if parent.request.provider == .gemini,", self.web_ai_handoff)
        self.assertIn("window.__codexPendingPromptText = parts.join(\"\")", self.web_ai_handoff)
        self.assertIn("window.__codexCapturePromptText = window.__codexPendingPromptText;", self.web_ai_handoff)
        self.assertIn('window.__codexCapturePromptRequestId = "', self.web_ai_handoff)
        self.assertIn('"(window.__codexPendingPromptText || \\"\\"', self.web_ai_handoff)
        self.assertIn("const text = \\(textSource);", self.web_ai_handoff)
        self.assertRegex(
            self.web_ai_handoff,
            r"guard !didStagePromptForCurrentRequest else \{[\s\S]*validateStagedPrompt\(in: webView\)[\s\S]*self\.didStagePromptForCurrentRequest = false[\s\S]*self\.stagePromptIfNeeded\(in: webView, completion: completion\)",
        )
        self.assertIn("let expectedLength = parent.request.prompt.utf16.count", self.web_ai_handoff)
        self.assertIn("pendingLength == expectedLength", self.web_ai_handoff)
        self.assertIn("captureLength == expectedLength", self.web_ai_handoff)
        self.assertRegex(
            self.web_ai_handoff,
            r"guard index < scripts\.count else \{[\s\S]*self\.validateStagedPrompt\(in: webView\)[\s\S]*guard isStillStaged else \{[\s\S]*self\.didStagePromptForCurrentRequest = true",
        )

    def test_ios_gemini_submit_verifies_after_js_click_even_without_native_click(self):
        self.assertRegex(
            self.web_ai_handoff,
            r"status\.hasPrefix\(\"nativeClick:\"\)[\s\S]*_ = self\.performNativeWebClick\(payload: payload, in: webView\)[\s\S]*self\.startFallbackExtractionPollingIfNeeded\(in: webView\)[\s\S]*self\.checkGeminiSubmissionStarted\(in: webView\)[\s\S]*self\.attemptGeminiSubmitRetry\(in: webView\)",
        )
        self.assertRegex(
            self.web_ai_handoff,
            r"status == \"nativeEnter\"[\s\S]*self\.startFallbackExtractionPollingIfNeeded\(in: webView\)[\s\S]*self\.checkGeminiSubmissionStarted\(in: webView\)[\s\S]*self\.attemptGeminiSubmitRetry\(in: webView\)",
        )
        self.assertRegex(
            self.web_ai_handoff,
            r"private func checkGeminiSubmissionStarted[\s\S]*function isVisibleEditable\(node\)[\s\S]*const composerNodes = Array\.from\(document\.querySelectorAll\([\s\S]*filter\(isVisibleEditable\)[\s\S]*const hasEnabledSendButton",
        )
        self.assertRegex(
            self.web_ai_handoff,
            r"private func attemptGeminiSubmitRetry\(in webView: WKWebView, completion: @escaping \(Bool\) -> Void\)[\s\S]*function findGeminiSendButton\(input\)[\s\S]*form\.requestSubmit\(\)[\s\S]*dispatchEnter\(input\)",
        )
        self.assertIn('const capturePrompt = window.__codexCapturePromptRequestId === "\\(requestID)"', self.web_ai_handoff)
        self.assertIn('prompt: capturePrompt || "\\(escapedPrompt)"', self.web_ai_handoff)
        self.assertIn('const prompt = capturePrompt || "\\(escapedPrompt)";', self.web_ai_handoff)
        self.assertIn("function assistantContentFromContainer(container)", self.web_ai_handoff)
        self.assertIn("function chatGPTCandidates()", self.web_ai_handoff)
        self.assertIn("function geminiCandidates()", self.web_ai_handoff)
        self.assertIn("function genericCandidates()", self.web_ai_handoff)
        self.assertIn("function pickLatestCandidate(candidates)", self.web_ai_handoff)
        self.assertIn('node.closest("message-content") ||', self.web_ai_handoff)
        self.assertIn('node.closest("[class*=\'response\']") ||', self.web_ai_handoff)
        self.assertIn("stripGeminiBoilerplate(stripPromptEcho(candidate.text))", self.web_ai_handoff)
        self.assertRegex(
            self.web_ai_handoff,
            r"text = stripPromptEcho\(text, s\.promptText\);[\s\S]*if \(s\.provider === \"gemini\"\) \{[\s\S]*text = stripGeminiBoilerplate\(text\);",
        )
        self.assertIn("const providerSpecific = provider === \"chatgpt\" ? chatGPTCandidates() : geminiCandidates();", self.web_ai_handoff)
        self.assertIn("const latest = pickLatestCandidate(providerSpecific.concat(genericCandidates()));", self.web_ai_handoff)

    def test_no_rss_sources_are_referenced_by_regression_tests(self):
        self.assertNotIn("RSSReaderApp", str(CONTENT_VIEW))
        self.assertNotIn("rss mac", str(INFOGRAPHIC_VIEW))


if __name__ == "__main__":
    unittest.main()
