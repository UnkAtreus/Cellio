import SwiftUI

/// Uses the existing Settings scroll pane and flat group surface.
@MainActor struct GeneralSettingsContent: View {
    @ObservedObject var login: LoginRegistrationController
    @ObservedObject var updates: ApplicationUpdatesController
    var openMenuBar: () -> Void = {}
    var focusMenuBarOnAppear=false
    @FocusState private var menuBarFocus:Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup {
                switchRow("Start at login", id: "cellio.general.login", value: Binding(
                    get: { login.status.isRegistered }, set: { login.setEnabled($0) }))
                    .disabled(login.isUpdating || login.status == .unavailable)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(login.statusText)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                    .accessibilityIdentifier("cellio.general.login.status")
                    .help(login.operationError?.description ?? (login.status == .notFound
                        ? "Not set up. Turn on to set up Start at login."
                        : (login.diagnostic ?? login.statusText)))
                HStack(spacing: 12) {
                    if !login.isUpdating {
                        if login.operationError != nil {
                            Button("Try Again") { login.retry() }
                                .accessibilityIdentifier("cellio.general.login.retry")
                        }
                        if login.status == .requiresApproval {
                            Button("Open System Settings…") { login.openSystemSettings() }
                                .accessibilityIdentifier("cellio.general.login.settings")
                        } else if login.status == .unavailable && login.operationError == nil {
                            Button("Check Again") { login.refresh() }
                                .help(login.diagnostic ?? "Run a valid signed application bundle.")
                                .accessibilityIdentifier("cellio.general.login.refresh")
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(height: 24)
            }
            SettingsGroup {
                Button(action:openMenuBar) {
                    HStack {
                        Text("Menu Bar"); Spacer(); Image(systemName:"chevron.right").foregroundStyle(.secondary)
                    }.padding(.horizontal,12).frame(height:44).contentShape(Rectangle())
                }.buttonStyle(.plain).focused($menuBarFocus).accessibilityIdentifier("cellio.general.menubar")
            }
            Text("Updates").font(.headline).padding(.top, 8).accessibilityAddTraits(.isHeader)
            if updates.isAvailable {
                SettingsGroup {
                    HStack(spacing: 12) {
                        Text("App updates").frame(maxWidth: .infinity, alignment: .leading)
                        Button(updates.state.isSearching ? "Checking…" : "Check for Updates…") { updates.checkForUpdates() }
                            .frame(width: 156).disabled(!updates.canCheckForUpdates)
                            .help(updateCheckHelp)
                            .accessibilityHint(updateCheckHelp)
                            .accessibilityIdentifier("cellio.general.updates.check")
                    }.padding(.horizontal, 12).frame(minHeight: 44)
                    Divider().padding(.leading, 12)
                    switchRow("Automatically check for updates", id: "cellio.general.updates.automaticChecks", value: Binding(
                        get: { updates.state.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }))
                    Divider().padding(.leading, 12)
                    switchRow("Automatically download and install updates", id: "cellio.general.updates.automaticDownloads", value: Binding(
                        get: { updates.state.automaticallyDownloads }, set: { updates.setAutomaticallyDownloads($0) }))
                        .disabled(!updates.state.automaticallyChecks || !updates.state.allowsAutomaticUpdates)
                }
                Text(!updates.state.automaticallyChecks
                     ? "Automatic checks are off. An update already in progress may still finish."
                     : "Updates may need your approval or a restart.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cellio.general.updates.footer")
            } else {
                SettingsGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Public updates unavailable").font(.body.weight(.medium))
                        Text("Public updates are unavailable for this build. You can keep using this version of Cellio.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("cellio.general.updates.unavailable")
            }
        }.onAppear { login.refresh(); updates.refresh(); menuBarFocus=focusMenuBarOnAppear }
    }
    private var updateCheckHelp: String {
        if updates.state.isSearching { return "Checking…" }
        return updates.state.sessionInProgress ? "An update is already in progress." : "Check for updates to Cellio."
    }
    private func switchRow(_ title: String, id: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .fixedSize().accessibilityLabel(title).accessibilityIdentifier(id)
                .accessibilityValue(id == "cellio.general.login" ? login.accessibilityValue : (value.wrappedValue ? "On" : "Off"))
                .help(id == "cellio.general.login" ? login.accessibilityValue : title)
        }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 44)
            .accessibilityElement(children: .contain)
    }
}
