import SwiftUI

struct SimpleTableSummaryView: View {
    let tableData: [TableSummaryRow]
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                // Glass background
                GlassBackgroundView(variant: .summary)
                    .ignoresSafeArea()
                
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Header section
                            VStack(alignment: .leading, spacing: 12) {
                                TableHeaderView(
                                    onCopyAction: copyTableToClipboard,
                                    onScrollToBottom: {
                                        withAnimation(.easeInOut(duration: 0.5)) {
                                            proxy.scrollTo("bottomSection", anchor: .bottom)
                                        }
                                    }
                                )
                                .id("topSection")
                                
                                TableContentView(tableData: tableData)
                            }
                            .padding(.horizontal)
                            
                            // Scroll to top button at bottom
                            HStack {
                                Spacer()
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.5)) {
                                        proxy.scrollTo("topSection", anchor: .top)
                                    }
                                }) {
                                    Image(systemName: "arrow.up.circle")
                                }
                                .buttonStyle(LiquidGlassButtonStyle(isProminent: true))
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.bottom)
                            .id("bottomSection")
                        }
                        .padding(.top)
                    }
                }
            }
            .navigationTitle("Table Summary")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 600)
        #endif
    }
    
    private func copyTableToClipboard() {
        var text = "# Overall Summary (Table Format)\n\n"
        text += "| Subject Category | Key Topics & Themes | Common Challenges | Examples |\n"
        text += "|------------------|--------------------|--------------------|----------|\n"
        
        for row in tableData {
            let examplesText = row.examples.map { example in
                if !example.permalink.isEmpty {
                    return "[\(example.title)](\(normalizeRedditPermalink(example.permalink)))"
                } else {
                    return example.title
                }
            }.joined(separator: ", ")
            
            text += "| \(row.subject) | \(row.topics) | \(row.challenges) | \(examplesText) |\n"
        }
        
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}