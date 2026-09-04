import SwiftUI
import AppKit

public struct ManageVaultsView: View {
    @ObservedObject var vaultManager: VaultManager
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Manage Notebook Vaults")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            List {
                ForEach(vaultManager.vaults) { vault in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vault.name)
                                .font(.headline)
                            Text(vault.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if vault.id == vaultManager.activeVault?.id {
                            Text("Active")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                        Button("Open") {
                            vaultManager.selectVault(vault)
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive, action: { vaultManager.removeVault(vault) }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(vaultManager.vaults.count == 1)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .liquidGlass(cornerRadius: 8)

            HStack {
                Button("Add Existing Folder as Vault…") {
                    pickVaultDirectory()
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 350)
        .background(VisualEffectBlur(material: .hudWindow))
    }

    private func pickVaultDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Vault Folder"
        panel.message = "Select a folder of markdown notes to use as a vault."

        if panel.runModal() == .OK, let selectedURL = panel.url {
            let vaultName = selectedURL.lastPathComponent
            vaultManager.addVault(name: vaultName, path: selectedURL.path)
        }
    }
}
