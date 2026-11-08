import ServerKilnCore
import SwiftUI
import ServerKilnUI

/// Lists hosts from `~/.ssh/config` and lets the user pick which to import.
struct ImportView: View {
    @Environment(AppSettings.self) private var settings
    var onDone: () -> Void

    @State private var hosts: [SSHHostEntry] = []
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("从 SSH 配置导入").font(.headline)
                Spacer()
                Button(allSelected ? "全不选" : "全选") {
                    selected = allSelected ? [] : Set(importable.map(\.alias))
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(importable.isEmpty)
            }
            .padding(14)
            Divider()
            if hosts.isEmpty {
                Text("在 ~/.ssh/config 中没有找到服务器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(hosts) { host in row(host) }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("将使用系统 ssh 与你现有的密钥连接").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("取消", action: onDone)
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("导入 \(selected.count) 台") {
                    settings.addServers(hosts.filter { selected.contains($0.alias) }.map {
                        ServerConfig(name: $0.alias, target: $0.alias)
                    })
                    Monitor.shared.sync()
                    onDone()
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 380)
        .onAppear {
            hosts = SSHConfigParser.loadDefault()
            selected = Set(importable.map(\.alias))
        }
    }

    private var existing: Set<String> { Set(settings.servers.map(\.target)) }
    private var importable: [SSHHostEntry] { hosts.filter { !existing.contains($0.alias) } }
    private var allSelected: Bool { !importable.isEmpty && selected.count == importable.count }

    private func row(_ host: SSHHostEntry) -> some View {
        let added = existing.contains(host.alias)
        let isOn = Binding(
            get: { added || selected.contains(host.alias) },
            set: { on in if on { selected.insert(host.alias) } else { selected.remove(host.alias) } }
        )
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(host.alias).font(.system(size: 12, weight: .medium))
                    if added { Text("已添加").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(host.summary).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .disabled(added)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
