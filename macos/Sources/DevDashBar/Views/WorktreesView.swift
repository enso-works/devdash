import SwiftUI

// MARK: - Worktrees

/// Linked git worktrees of every repository devdash knows about, with what's safe to remove.
struct WorktreesView: View {
    @Environment(Store.self) private var store
    let repo: String?
    @State private var cleanup: Bool

    init(repo: String?, cleanup: Bool) {
        self.repo = repo
        _cleanup = State(initialValue: cleanup)
    }

    private var repos: [WorktreeRepo] {
        store.worktreeRepos.filter { repo == nil || $0.root == repo }
    }

    private func shown(_ repo: WorktreeRepo) -> [Worktree] {
        guard cleanup else { return repo.worktrees }
        let idle = Set(store.idleMergedWorktrees)
        return repo.worktrees.filter(idle.contains)
    }

    var body: some View {
        VStack(spacing: 0) {
            SubPageHeader(title: title, subtitle: subtitle) {
                IconButton(symbol: "arrow.clockwise", help: "Scan again") { store.refreshWorktrees() }
            }
            Divider().opacity(0.5)
            Picker("Show", selection: $cleanup) {
                Text("All").tag(false)
                Text("Merged and idle (\(store.idleMergedWorktrees.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            let sections = repos.map { ($0, shown($0)) }.filter { !$0.1.isEmpty }
            if sections.isEmpty {
                EmptyState(
                    symbol: "arrow.triangle.branch",
                    title: cleanup ? "Nothing to clean up" : "No worktrees",
                    message: cleanup
                        ? "Merged worktrees appear here once nothing has run in them for a day."
                        : "Repositories you work in that have linked worktrees, such as the ones Claude Code creates, show up here."
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections, id: \.0.id) { repo, worktrees in
                            RepoHeader(repo: repo, count: worktrees.count)
                            ForEach(worktrees) { WorktreeRow(worktree: $0, repo: repo) }
                        }
                        Text("Worktrees with uncommitted changes, or with a server or a Claude or Codex session running in them, can't be removed here.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 10)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.never)
                .task(id: sections.flatMap(\.1).map(\.path)) {
                    await store.loadSizes(for: sections.flatMap(\.1))
                }
            }
        }
    }

    private var title: String {
        if let repo, let name = store.worktreeRepos.first(where: { $0.root == repo })?.name { return "\(name) worktrees" }
        return "Worktrees"
    }

    private var subtitle: String {
        let count = repos.reduce(0) { $0 + $1.worktrees.count }
        let repoCount = repos.count
        return repo == nil
            ? "\(count) in \(repoCount) repositor\(repoCount == 1 ? "y" : "ies")"
            : "\(count) worktree\(count == 1 ? "" : "s")"
    }
}

private struct RepoHeader: View {
    let repo: WorktreeRepo
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(repo.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if !repo.defaultBranch.isEmpty {
                Text(repo.defaultBranch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.primary.opacity(0.06), in: .capsule)
                    .help("Branches merged into \(repo.defaultBranch) count as merged")
            }
            Text(Format.shortPath(repo.root))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            CountBadge(count: count).fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .padding(.top, 8)
    }
}

private struct WorktreeRow: View {
    @Environment(Store.self) private var store
    let worktree: Worktree
    let repo: WorktreeRepo

    var body: some View {
        let status = store.status(of: worktree)
        HoverRow(onTap: { store.openInEditor(worktree.path) }) {
            HStack(spacing: 8) {
                CreatorBadge(worktree: worktree)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(worktree.displayBranch)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if worktree.isMain {
                            Text("main checkout").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                        if worktree.locked {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Locked")
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(worktree.subject.isEmpty ? worktree.path : "\(worktree.subject)\n\(worktree.path)")
        } metrics: {
            WorktreeStatusChip(status: status, changes: worktree.changes)
        } actions: {
            IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") {
                store.openInEditor(worktree.path)
            }
            IconButton(symbol: "terminal", help: "Open in Terminal") { Launcher.launchClaude(.shell, in: worktree.path) }
            if let reason = blocker(status: status) {
                IconButton(symbol: "folder", help: "Reveal in Finder. \(reason)") { Launcher.revealInFinder(worktree.path) }
            } else {
                ConfirmIconButton(
                    symbol: "trash", help: removeHelp, confirmLabel: "Remove?",
                    busy: store.isPending("wt-\(worktree.path)")
                ) {
                    store.remove(worktree, deleteBranch: worktree.merged)
                }
            }
        }
        .contextMenu {
            Button("Open in Editor") { store.openInEditor(worktree.path) }
            Button("Open in Terminal") { Launcher.launchClaude(.shell, in: worktree.path) }
            if store.hasClaude {
                Button("New Claude Session") { Launcher.launchClaude(.new, in: worktree.path) }
            }
            if store.hasCodex {
                Button("New Codex Session") { Launcher.launchCodex(.new, in: worktree.path) }
            }
            Button("Reveal in Finder") { Launcher.revealInFinder(worktree.path) }
            Divider()
            Button("Copy Path") { Pasteboard.copy(worktree.path) }
            if !worktree.branch.isEmpty {
                Button("Copy Branch Name") { Pasteboard.copy(worktree.branch) }
            }
            Divider()
            if let reason = blocker(status: status) {
                Button("Can't remove: \(reason)") {}.disabled(true)
            } else {
                Button("Remove Worktree", role: .destructive) { store.remove(worktree, deleteBranch: false) }
                if worktree.merged && !worktree.branch.isEmpty {
                    Button("Remove Worktree and Branch", role: .destructive) { store.remove(worktree, deleteBranch: true) }
                }
            }
        }
    }

    private var subtitle: String {
        // The repository header already shows the main checkout's folder.
        var parts = worktree.isMain ? [] : [worktree.folder]
        parts.append(worktree.lastActivity.formatted(.relative(presentation: .named)))
        if let size = store.worktreeSizes[worktree.path] { parts.append(ByteFormat.string(size)) }
        let activity = store.activity(in: worktree)
        if !activity.servers.isEmpty { parts.append("\(activity.servers.count) server\(activity.servers.count == 1 ? "" : "s")") }
        if !activity.sessions.isEmpty { parts.append("Claude") }
        if !activity.codex.isEmpty { parts.append("Codex") }
        return parts.joined(separator: "  ·  ")
    }

    private var removeHelp: String {
        worktree.merged && !worktree.branch.isEmpty
            ? "Remove the worktree and delete branch \(worktree.branch)"
            : "Remove the worktree (the branch stays)"
    }

    /// Why this worktree can't be removed from devdash, if it can't.
    private func blocker(status: String) -> String? {
        if worktree.isMain { return "it's the main checkout" }
        if status == "running" { return "something is running in it" }
        if worktree.changes > 0 { return "it has uncommitted changes" }
        if worktree.locked { return "it's locked" }
        return nil
    }
}

/// Who made the worktree: Claude Code gets its mark, the main checkout a house, the rest a branch.
private struct CreatorBadge: View {
    let worktree: Worktree

    var body: some View {
        if worktree.createdBy == "claude" && !worktree.isMain {
            RuntimeBadge(runtime: "claude")
        } else {
            let color = worktree.isMain ? Color.secondary : Color.accentColor
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16))
                Image(systemName: worktree.isMain ? "house.fill" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .help(worktree.createdBy.isEmpty ? "Worktree" : "Created by \(worktree.createdBy)")
        }
    }
}

struct WorktreeStatusChip: View {
    let status: String
    var changes = 0

    var body: some View {
        let style = Self.style(status, changes: changes)
        Text(style.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(style.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(style.color.opacity(0.14), in: .capsule)
    }

    static func style(_ status: String, changes: Int) -> (label: String, color: Color) {
        switch status {
        case "running": ("Running", .green)
        case "changes": ("\(changes) change\(changes == 1 ? "" : "s")", .orange)
        case "merged": ("Merged", .purple)
        case "stale": ("Stale", .secondary)
        case "missing": ("Missing", .red)
        default: ("Active", .accentColor)
        }
    }
}
