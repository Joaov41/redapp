# Markdown Rendering Implementation Guide

## Overview
This document details the technical implementation of the markdown rendering system in RedApp, which transforms LLM responses from raw markdown text into beautifully formatted, platform-native UI elements across macOS, iPad, and iPhone.

## Architecture

### Component Hierarchy
```
ResizableTextBox
  └── MarkdownTextView
       └── parseMarkdownContent() → [MarkdownElement]
       └── renderElement() → SwiftUI Views
            └── renderInlineMarkdown()
                 └── parseInlineFormatting() → AttributedString
```

## Core Components

### 1. ResizableTextBox
**Location:** Lines 2924-3109

The main container for displaying LLM responses with markdown support.

```swift
struct ResizableTextBox: View {
    let title: String
    let content: String
    let isAnswer: Bool
    let renderMarkdown: Bool  // Controls markdown rendering
    
    var body: some View {
        ScrollView {
            if renderMarkdown {
                MarkdownTextView(content: content)
                    .padding()
            } else {
                Text(content)
                    .padding()
            }
        }
    }
}
```

**Key Features:**
- Resizable height with drag handle
- Copy-to-clipboard functionality
- Text-to-speech integration (both cloud and local)
- Glass morphism background styling
- Platform-specific sizing

### 2. MarkdownTextView
**Location:** Lines 2602-2921

The core markdown parser and renderer.

```swift
struct MarkdownTextView: View {
    let content: String
    @Environment(\.colorScheme) var colorScheme
    
    private var baseFontSize: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? 16 : 15
        #else
        return 16
        #endif
    }
}
```

**Platform-Aware Font Sizing:**
- macOS: 16pt base
- iPad: 16pt base
- iPhone: 15pt base

### 3. Markdown Element Types

```swift
enum MarkdownElement: Identifiable {
    case text(String)
    case bold(String)
    case italic(String)
    case boldItalic(String)
    case code(String)
    case codeBlock(String, language: String?)
    case heading(String, level: Int)
    case bulletPoint(String)
    case numberedPoint(String, number: Int)
    case link(text: String, url: String)
    case paragraph(String)
}
```

## Parsing Implementation

### Block-Level Parsing
**Function:** `parseMarkdownContent(_ text: String) -> [MarkdownElement]`

The parser processes text line by line, identifying:

1. **Code Blocks**
   ```swift
   if line.starts(with: "```") {
       // Toggle code block state
       // Extract language identifier
   }
   ```

2. **Headings**
   ```swift
   if line.starts(with: "#") {
       let level = line.prefix(while: { $0 == "#" }).count
       // Create heading element
   }
   ```

3. **Lists**
   - Bullet points: `- `, `* `, `+ `
   - Numbered lists: `1. `, `2. `, etc.

4. **Paragraphs**
   - Any non-empty line that doesn't match other patterns

### Inline Parsing
**Function:** `parseInlineFormatting(_ text: String) -> AttributedString`

Processes character by character to identify:

1. **Bold Text**
   - Pattern: `**text**` or `__text__`
   - Implementation:
   ```swift
   if text[currentIndex...].hasPrefix("**") {
       // Find closing delimiter
       // Apply bold font weight
   }
   ```

2. **Italic Text**
   - Pattern: `*text*` or `_text_`
   - Guards against bold markers

3. **Inline Code**
   - Pattern: `` `code` ``
   - Applies monospace font and background

## Rendering Implementation

### Visual Styling

#### Code Blocks
```swift
case .codeBlock(let content, _):
    ScrollView(.horizontal, showsIndicators: false) {
        Text(content)
            .font(.system(size: baseFontSize * 0.85, design: .monospaced))
            .padding()
    }
    .background {
        if #available(macOS 26.0, iOS 26.0, *) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .glassEffect(in: RoundedRectangle(cornerRadius: 12))
        } else {
            // Fallback styling
        }
    }
```

**Features:**
- Horizontal scrolling for long lines
- Glass morphism effect on supported OS versions
- Monospace font at 85% of base size

#### Inline Code
```swift
case .code(let content):
    Text(content)
        .font(.system(size: baseFontSize * 0.9, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .glassEffect(in: Capsule())
        }
```

**Features:**
- Capsule shape for inline elements
- Liquid glass effect matching app buttons
- 90% of base font size

#### Headings
```swift
func headingFont(for level: Int) -> Font {
    let sizes: [CGFloat] = [
        baseFontSize * 2,      // H1: 200%
        baseFontSize * 1.5,    // H2: 150%
        baseFontSize * 1.3,    // H3: 130%
        baseFontSize * 1.15,   // H4: 115%
        baseFontSize * 1.05,   // H5: 105%
        baseFontSize           // H6: 100%
    ]
    return .system(size: sizes[level - 1], weight: .medium)
}
```

#### Lists
- **Bullet Points:** Secondary-colored bullet with 20pt left padding
- **Numbered Lists:** Right-aligned numbers in 20pt minimum width
- Both support inline formatting in content

## Glass Morphism Integration

All code elements use the app's liquid glass design system:

```swift
if #available(macOS 26.0, iOS 26.0, *) {
    // Use native glass effects
    .glassEffect(in: shape)
} else {
    // Fallback with ultra-thin material
    .fill(.ultraThinMaterial)
    .overlay {
        shape.stroke(Color.white.opacity(0.2), lineWidth: 0.5)
    }
}
```

## Text-to-Speech Integration

The system extracts plain text for TTS using `extractPlainText(from:)`:

```swift
static func extractPlainText(from markdown: String) -> String {
    var plainText = markdown
    
    // Remove code blocks
    plainText = plainText.replacingOccurrences(of: #"```[\s\S]*?```"#, 
                                              with: "", 
                                              options: .regularExpression)
    
    // Remove formatting markers
    plainText = plainText.replacingOccurrences(of: #"\*{1,3}([^*]+)\*{1,3}"#, 
                                              with: "$1", 
                                              options: .regularExpression)
    
    // Continue for other markdown elements...
    
    return plainText
}
```

## Usage Examples

### Displaying Post Summary
```swift
ResizableTextBox(
    title: "",
    content: postSummary,
    isAnswer: true,
    renderMarkdown: true,  // Enable markdown rendering
    initialHeight: 400,
    onCloudSpeakClicked: { /* TTS handler */ }
)
```

### Direct Markdown Display
```swift
MarkdownTextView(content: summaryText)
    .padding()
```

## Performance Considerations

1. **Lazy Parsing:** Content is parsed once when view is created
2. **Efficient Rendering:** Uses SwiftUI's built-in text rendering
3. **Platform Optimization:** Font sizes adjusted per device
4. **Memory Efficiency:** Processes text line by line

## Best Practices

1. **Always Enable Markdown:** Set `renderMarkdown: true` for LLM responses
2. **Platform Testing:** Test on all target devices (Mac, iPad, iPhone)
3. **Accessibility:** Maintain text selection and VoiceOver support
4. **Consistent Styling:** Use app's glass morphism theme throughout

## Future Enhancements

1. **Tables Support:** Add markdown table parsing and rendering
2. **Syntax Highlighting:** Language-specific code highlighting
3. **Custom Themes:** User-selectable color schemes
4. **Export Options:** Save formatted text as PDF or HTML
5. **Interactive Elements:** Clickable checkboxes, collapsible sections

## Troubleshooting

### Common Issues

1. **Asterisks Showing:** Ensure `renderMarkdown: true` is set
2. **Formatting Not Applied:** Check that inline parsing is working
3. **Platform Differences:** Test glass effects on target OS versions

### Debug Tips

```swift
// Add debug prints in parseInlineFormatting
print("Parsing: \(text)")
print("Found bold at: \(currentIndex)")
```

## Implementation Tutorial for Your App

### Step 1: Copy Core Components

Create a new Swift file called `MarkdownRenderer.swift` and add these components:

```swift
import SwiftUI

// MARK: - Markdown Element Types
enum MarkdownElement: Identifiable {
    case text(String)
    case bold(String)
    case italic(String)
    case code(String)
    case codeBlock(String, language: String?)
    case heading(String, level: Int)
    case bulletPoint(String)
    case numberedPoint(String, number: Int)
    case paragraph(String)
    
    var id: String {
        // Generate unique ID based on content
        switch self {
        case .text(let content): return "text-\(content.hashValue)"
        case .bold(let content): return "bold-\(content.hashValue)"
        // ... add other cases
        }
    }
}
```

### Step 2: Create the Markdown View

```swift
struct MarkdownTextView: View {
    let content: String
    @Environment(\.colorScheme) var colorScheme
    
    // Platform-aware font sizing
    private var baseFontSize: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? 16 : 15
        #else
        return 16
        #endif
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parseMarkdownContent(content), id: \.id) { element in
                renderElement(element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

### Step 3: Implement the Parser

```swift
extension MarkdownTextView {
    func parseMarkdownContent(_ text: String) -> [MarkdownElement] {
        var elements: [MarkdownElement] = []
        let lines = text.components(separatedBy: .newlines)
        var isInCodeBlock = false
        var codeBlockContent = ""
        
        for line in lines {
            // Handle code blocks
            if line.starts(with: "```") {
                if isInCodeBlock {
                    elements.append(.codeBlock(codeBlockContent, language: nil))
                    codeBlockContent = ""
                    isInCodeBlock = false
                } else {
                    isInCodeBlock = true
                }
                continue
            }
            
            if isInCodeBlock {
                codeBlockContent += line + "\n"
                continue
            }
            
            // Handle headings
            if line.starts(with: "#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let content = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                elements.append(.heading(content, level: min(level, 6)))
                continue
            }
            
            // Handle bullet points
            if line.starts(with: "- ") || line.starts(with: "* ") {
                let content = String(line.dropFirst(2))
                elements.append(.bulletPoint(content))
                continue
            }
            
            // Handle paragraphs
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                elements.append(.paragraph(line))
            }
        }
        
        return elements
    }
}
```

### Step 4: Add Rendering Logic

```swift
extension MarkdownTextView {
    @ViewBuilder
    func renderElement(_ element: MarkdownElement) -> some View {
        switch element {
        case .text(let content):
            Text(content)
                .font(.system(size: baseFontSize))
            
        case .bold(let content):
            Text(content)
                .font(.system(size: baseFontSize))
                .fontWeight(.bold)
            
        case .code(let content):
            Text(content)
                .font(.system(size: baseFontSize * 0.9, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
            
        case .codeBlock(let content, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: baseFontSize * 0.85, design: .monospaced))
                    .padding()
            }
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)
            
        case .heading(let content, let level):
            renderInlineMarkdown(content)
                .font(headingFont(for: level))
                .fontWeight(.bold)
                .padding(.top, level == 1 ? 16 : 8)
            
        case .bulletPoint(let content):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                renderInlineMarkdown(content)
            }
            .padding(.leading, 16)
            
        case .numberedPoint(let content, let number):
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).")
                    .frame(minWidth: 20, alignment: .trailing)
                renderInlineMarkdown(content)
            }
            .padding(.leading, 16)
            
        case .paragraph(let content):
            renderInlineMarkdown(content)
                .lineSpacing(4)
        }
    }
    
    func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: baseFontSize * 2)
        case 2: return .system(size: baseFontSize * 1.5)
        case 3: return .system(size: baseFontSize * 1.3)
        default: return .system(size: baseFontSize * 1.1)
        }
    }
}
```

### Step 5: Add Inline Markdown Support

```swift
extension MarkdownTextView {
    @ViewBuilder
    func renderInlineMarkdown(_ text: String) -> some View {
        Text(parseInlineFormatting(text))
            .textSelection(.enabled)
    }
    
    func parseInlineFormatting(_ text: String) -> AttributedString {
        var result = AttributedString()
        var currentIndex = text.startIndex
        
        while currentIndex < text.endIndex {
            // Check for bold (**text**)
            if text[currentIndex...].hasPrefix("**") {
                if let endRange = text[text.index(currentIndex, offsetBy: 2)...].range(of: "**") {
                    let boldText = String(text[text.index(currentIndex, offsetBy: 2)..<endRange.lowerBound])
                    var boldAttr = AttributedString(boldText)
                    boldAttr.font = .system(size: baseFontSize, weight: .bold)
                    result.append(boldAttr)
                    currentIndex = endRange.upperBound
                    continue
                }
            }
            
            // Check for italic (*text*)
            if text[currentIndex] == "*" {
                if let endIndex = text[text.index(after: currentIndex)...].firstIndex(of: "*") {
                    let italicText = String(text[text.index(after: currentIndex)..<endIndex])
                    var italicAttr = AttributedString(italicText)
                    italicAttr.font = .system(size: baseFontSize).italic()
                    result.append(italicAttr)
                    currentIndex = text.index(after: endIndex)
                    continue
                }
            }
            
            // Check for inline code (`text`)
            if text[currentIndex] == "`" {
                if let endIndex = text[text.index(after: currentIndex)...].firstIndex(of: "`") {
                    let codeText = String(text[text.index(after: currentIndex)..<endIndex])
                    var codeAttr = AttributedString(codeText)
                    codeAttr.font = .system(size: baseFontSize * 0.9, design: .monospaced)
                    codeAttr.backgroundColor = Color.gray.opacity(0.1)
                    result.append(codeAttr)
                    currentIndex = text.index(after: endIndex)
                    continue
                }
            }
            
            // Regular character
            result.append(AttributedString(String(text[currentIndex])))
            currentIndex = text.index(after: currentIndex)
        }
        
        return result
    }
}
```

### Step 6: Create a Container View (Optional)

```swift
struct MarkdownContainer: View {
    let title: String
    let content: String
    @State private var isCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(action: copyContent) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            // Content
            ScrollView {
                MarkdownTextView(content: content)
                    .padding()
            }
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .padding()
    }
    
    func copyContent() {
        #if os(iOS)
        UIPasteboard.general.string = content
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        #endif
        
        withAnimation {
            isCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
    }
}
```

### Step 7: Usage in Your App

```swift
struct ContentView: View {
    @State private var llmResponse = """
    # Welcome to **Markdown** Rendering
    
    This is a paragraph with **bold text** and *italic text*.
    
    ## Features
    - Easy to implement
    - Cross-platform support
    - Beautiful rendering
    
    Here's some `inline code` and a code block:
    
    ```swift
    let greeting = "Hello, World!"
    print(greeting)
    ```
    
    1. First item
    2. Second item
    3. Third item
    """
    
    var body: some View {
        VStack {
            // Option 1: Direct usage
            ScrollView {
                MarkdownTextView(content: llmResponse)
                    .padding()
            }
            
            // Option 2: With container
            MarkdownContainer(
                title: "LLM Response",
                content: llmResponse
            )
        }
    }
}
```

### Step 8: Customization Options

#### Custom Styling
```swift
struct MyAppMarkdownStyle {
    static let baseFontSize: CGFloat = 17
    static let headingColor = Color.blue
    static let codeBackground = Color.blue.opacity(0.1)
    static let bulletColor = Color.orange
}
```

#### Glass Morphism Effects (iOS 15+/macOS 12+)
```swift
.background {
    if #available(iOS 15.0, macOS 12.0, *) {
        Rectangle()
            .fill(.ultraThinMaterial)
    } else {
        Color.gray.opacity(0.1)
    }
}
```

#### Dark Mode Support
```swift
@Environment(\.colorScheme) var colorScheme

var codeBackground: Color {
    colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05)
}
```

### Step 9: Add Text-to-Speech Support

```swift
extension MarkdownTextView {
    static func extractPlainText(from markdown: String) -> String {
        var plainText = markdown
        
        // Remove code blocks
        plainText = plainText.replacingOccurrences(
            of: #"```[\s\S]*?```"#,
            with: "",
            options: .regularExpression
        )
        
        // Remove formatting
        let patterns = [
            (#"\*\*([^*]+)\*\*"#, "$1"),  // Bold
            (#"\*([^*]+)\*"#, "$1"),       // Italic
            (#"`([^`]+)`"#, "$1"),         // Inline code
            (#"^#{1,6}\s+"#, ""),          // Headers
            (#"^[\-\*\+]\s+"#, ""),        // Bullets
            (#"^\d+\.\s+"#, "")            // Numbers
        ]
        
        for (pattern, replacement) in patterns {
            plainText = plainText.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        
        return plainText
    }
}

// Usage
let plainText = MarkdownTextView.extractPlainText(from: llmResponse)
// Use with AVSpeechSynthesizer or NSSpeechSynthesizer
```

### Step 10: Testing Your Implementation

```swift
struct MarkdownTestView: View {
    let testCases = [
        "**Bold** and *italic* text",
        "# Heading 1\n## Heading 2",
        "- Bullet point with **bold**",
        "Here is `inline code` example",
        """
        ```swift
        func hello() {
            print("World")
        }
        ```
        """
    ]
    
    var body: some View {
        List(testCases, id: \.self) { testCase in
            VStack(alignment: .leading) {
                Text("Input:").font(.caption)
                Text(testCase).font(.caption2).foregroundColor(.gray)
                Divider()
                Text("Output:").font(.caption)
                MarkdownTextView(content: testCase)
            }
            .padding(.vertical)
        }
    }
}
```

### Tips for Success

1. **Start Simple:** Begin with basic text rendering, then add features
2. **Test Edge Cases:** Empty strings, malformed markdown, nested formatting
3. **Performance:** For large texts, consider lazy loading with List
4. **Accessibility:** Ensure VoiceOver reads content correctly
5. **Localization:** Test with different languages and RTL text

### Common Pitfalls to Avoid

1. **Don't Parse Everything:** Start with essential markdown features
2. **Memory Usage:** Be careful with very large texts
3. **Platform Differences:** Test on all target platforms
4. **Regex Performance:** Use simple string operations where possible

## Conclusion

This markdown rendering system provides a robust, platform-native way to display formatted LLM responses with beautiful typography and glass morphism effects that match the app's design language. The implementation ensures content is both visually appealing and accessible across all Apple platforms.

With this tutorial, you can implement a professional markdown rendering system in your own SwiftUI app, providing users with a beautiful reading experience for LLM-generated content.