//
//  PlatformGuards.swift
//  RedditApp
//
//  Created by Codex on 2025-02-14.
//

#if os(macOS)
#error("This target only supports iPhone and iPad builds. Select an iOS device or simulator.")
#endif

#if targetEnvironment(macCatalyst)
#error("Mac Catalyst builds are disabled for this target.")
#endif
