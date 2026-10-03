//
//  PlatformGuards.swift
//  RedditApp
//
//  Created by Codex on 2025-02-14.
//

#if os(macOS)
enum UIUserInterfaceIdiom {
    case phone
    case pad
    case mac
}

struct UIDevice {
    static let current = UIDevice()

    var userInterfaceIdiom: UIUserInterfaceIdiom {
        .mac
    }
}
#endif
