import AppKit
import SwiftUI

struct SettingsRootView: View {
    let environment: AppEnvironment
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            Group {
                switch section {
                case .general: GeneralSettingsView(environment: environment)
                case .appearance: AppearanceSettingsView(environment: environment)
                case .shortcuts: ShortcutSettingsView(environment: environment)
                case .sources: ApplicationSourcesSettingsView(environment: environment)
                case .hiddenApps: HiddenApplicationsSettingsView(environment: environment)
                case .layout: LayoutSettingsView(environment: environment)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 900, height: 620)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, sources, hiddenApps, layout
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "slider.horizontal.3"
        case .shortcuts: "command"
        case .sources: "folder"
        case .hiddenApps: "eye.slash"
        case .layout: "square.grid.3x3"
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .general: "常规"
        case .appearance: "外观"
        case .shortcuts: "快捷键"
        case .sources: "应用来源"
        case .hiddenApps: "隐藏的应用"
        case .layout: "布局"
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(.title.bold())
            content
        }
    }
}

private struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var loginItems: LoginItemManager

    init(environment: AppEnvironment) {
        settings = environment.settings
        loginItems = environment.loginItems
    }

    var body: some View {
        SettingsPage(title: "常规") {
            Form {
                Toggle("开机自启动", isOn: Binding(get: { loginItems.isEnabled }, set: { loginItems.setEnabled($0) }))
                    .accessibilityIdentifier("settings.launchAtLogin")
                Toggle("在菜单栏显示图标", isOn: $settings.showMenuBarIcon)
                    .accessibilityIdentifier("settings.showMenuBarIcon")
                if loginItems.needsApproval {
                    LabeledContent("登录项") {
                        Button("打开系统设置") { loginItems.openSystemSettings() }
                    }
                    Text("请在系统设置中允许 LaunchpadX 作为登录项运行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = loginItems.lastError {
                    Text("开机自启动设置失败：\(error)")
                        .foregroundStyle(.red)
                }
                Toggle("打开时聚焦搜索框", isOn: $settings.focusSearchOnShow)
                Toggle("反转翻页方向", isOn: $settings.reversePageDirection)
            }
            .formStyle(.grouped)
        }
        .onAppear { loginItems.refresh() }
    }
}

private struct AppearanceSettingsView: View {
    @Bindable var settings: SettingsStore

    init(environment: AppEnvironment) { settings = environment.settings }

    var body: some View {
        SettingsPage(title: "外观") {
            Form {
                Picker("打开方式", selection: $settings.presentationMode) {
                    ForEach(LauncherPresentationMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                Picker("网格方式", selection: $settings.gridMode) {
                    ForEach(LauncherGridMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                Picker("显示器", selection: $settings.displayStrategy) {
                    ForEach(DisplayStrategy.allCases) { strategy in
                        Text(strategy.localizedTitle).tag(strategy)
                    }
                }
                if settings.displayStrategy == .fixed {
                    Picker("选择显示器", selection: Binding(
                        get: { settings.fixedDisplayID ?? 0 },
                        set: { settings.fixedDisplayID = $0 == 0 ? nil : $0 }
                    )) {
                        Text("选择显示器").tag(CGDirectDisplayID(0))
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { item in
                            Text(item.element.localizedName).tag(item.element.displayID ?? 0)
                        }
                    }
                }
                LabeledContent("列数：\(settings.columns)") {
                    Slider(value: Binding(get: { Double(settings.columns) }, set: { settings.columns = Int($0.rounded()) }), in: 3...8, step: 1)
                        .frame(width: 220)
                }
                LabeledContent("行数：\(settings.rows)") {
                    Slider(value: Binding(get: { Double(settings.rows) }, set: { settings.rows = Int($0.rounded()) }), in: 3...6, step: 1)
                        .frame(width: 220)
                }
                LabeledContent("图标大小：\(Int(settings.iconSize))") {
                    Slider(value: $settings.iconSize, in: 64...128, step: 2)
                        .frame(width: 220)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct ShortcutSettingsView: View {
    let environment: AppEnvironment
    @Bindable var settings: SettingsStore
    @State private var errorMessage: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        settings = environment.settings
    }

    var body: some View {
        SettingsPage(title: "快捷键") {
            Form {
                LabeledContent("唤起 LaunchpadX") {
                    HotKeyRecorder(
                        hotKey: $settings.hotKey,
                        requiresModifier: true,
                        onBegin: { environment.suspendLauncherHotKey() },
                        onCancel: { try? environment.reregisterHotKey() }
                    ) { hotKey in
                        let previous = settings.hotKey
                        do {
                            try environment.registerLauncherHotKey(hotKey)
                            settings.hotKey = hotKey
                        }
                        catch {
                            try? environment.registerLauncherHotKey(previous)
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                if environment.usesTemporaryHotKeyForLaunchOSCompatibility {
                    Text("已安装 LaunchOS，暂时使用 ⌃⌥空格 唤起。移除 LaunchOS 后，默认的 ⌥空格 将生效。也可以在上方设置自己的快捷键。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("上一页") {
                    HotKeyRecorder(hotKey: $settings.previousPageHotKey, requiresModifier: false) {
                        settings.previousPageHotKey = $0
                    }
                }
                LabeledContent("下一页") {
                    HotKeyRecorder(hotKey: $settings.nextPageHotKey, requiresModifier: false) {
                        settings.nextPageHotKey = $0
                    }
                }
                Toggle("启用 F4 快捷键", isOn: $settings.f4ShortcutEnabled)
                    .onChange(of: settings.f4ShortcutEnabled) { _, _ in
                        do { try environment.refreshInvocationBindings() }
                        catch { settings.f4ShortcutEnabled = false; errorMessage = error.localizedDescription }
                    }
                Picker("触发角", selection: $settings.hotCorner) {
                    ForEach(HotCornerLocation.allCases) { corner in
                        Text(corner.localizedTitle).tag(corner)
                    }
                }
                .onChange(of: settings.hotCorner) { _, _ in
                    do { try environment.refreshInvocationBindings() }
                    catch { settings.hotCorner = .off; errorMessage = error.localizedDescription }
                }
                Toggle("启用触控板唤起", isOn: $settings.trackpadWakeEnabled)
                    .onChange(of: settings.trackpadWakeEnabled) { _, _ in
                        do { try environment.refreshInvocationBindings() }
                        catch { settings.trackpadWakeEnabled = false; errorMessage = error.localizedDescription }
                    }
            }
            .formStyle(.grouped)
            Button("恢复默认快捷键") {
                let previous = settings.hotKey
                settings.hotKey = .defaultLauncher
                do { try environment.reregisterHotKey() }
                catch {
                    settings.hotKey = previous
                    try? environment.reregisterHotKey()
                    errorMessage = error.localizedDescription
                }
                settings.previousPageHotKey = .defaultPreviousPage
                settings.nextPageHotKey = .defaultNextPage
            }
        }
        .alert(String(localized: "快捷键错误"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}

private struct ApplicationSourcesSettingsView: View {
    let environment: AppEnvironment
    @Bindable var settings: SettingsStore

    init(environment: AppEnvironment) {
        self.environment = environment
        settings = environment.settings
    }

    var body: some View {
        SettingsPage(title: "应用来源") {
            Text("LaunchpadX 会扫描系统应用文件夹，以及你在这里添加的文件夹。")
                .foregroundStyle(.secondary)
            List {
                ForEach(settings.additionalScanRoots, id: \.path) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("移除", role: .destructive) { remove(root) }
                    }
                }
            }
            HStack {
                Button("添加文件夹…") { addFolder() }
                Button("立即重新扫描") { Task { await environment.launcherViewModel.rescan() } }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let normalized = url.standardizedFileURL
        guard !settings.allScanRoots.contains(where: { $0.standardizedFileURL == normalized }) else { return }
        settings.additionalScanRoots.append(normalized)
        environment.refreshScanRoots()
    }

    private func remove(_ root: URL) {
        settings.additionalScanRoots.removeAll { $0.standardizedFileURL == root.standardizedFileURL }
        environment.refreshScanRoots()
    }
}

private struct HiddenApplicationsSettingsView: View {
    @Bindable var viewModel: LauncherViewModel

    init(environment: AppEnvironment) { viewModel = environment.launcherViewModel }

    var body: some View {
        SettingsPage(title: "隐藏的应用") {
            if viewModel.snapshot.hiddenRecordIDs.isEmpty {
                ContentUnavailableView("没有隐藏的应用", systemImage: "eye")
            } else {
                List(viewModel.snapshot.hiddenRecordIDs.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    HStack {
                        Text(viewModel.snapshot.applications[id]?.displayName ?? String(localized: "未知应用"))
                        Spacer()
                        Button("显示") { viewModel.unhide(recordID: id) }
                    }
                }
            }
        }
        .onAppear { try? viewModel.reloadSnapshot() }
    }
}

private struct LayoutSettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        SettingsPage(title: "布局") {
            Text("按名称重建应用网格。保留已扫描应用，但会清除手动排列。")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440, alignment: .leading)
            Button("重置应用排列") {
                environment.launcherViewModel.resetLayout()
            }
            Divider()
            Button("重新扫描应用") {
                Task { await environment.launcherViewModel.rescan() }
            }
        }
    }
}
