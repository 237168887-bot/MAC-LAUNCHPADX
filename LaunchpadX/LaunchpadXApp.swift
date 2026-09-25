//
//  LaunchpadXApp.swift
//  LaunchpadX
//
//  Created by 张航 on 2026/7/29.
//

import SwiftUI

@main
struct LaunchpadXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(environment: appDelegate.environment)
                .frame(minWidth: 1_200, minHeight: 800)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Divider()
                Button("编辑布局") { appDelegate.editLayout() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("选择应用") { appDelegate.selectApplications() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
    }
}
