//
//  vr_playerApp.swift
//  vr-player
//
//  Created by wangdadan on 2026/8/10.
//

import SwiftUI
import SwiftData

@main
struct vr_playerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--hud-preview") {
                VRHUDPreviewScreen()
            } else {
                ContentView()
            }
#else
            ContentView()
#endif
        }
        .modelContainer(for: PlaylistItem.self)
    }
}
