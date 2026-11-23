import MomentumCore
import SwiftUI

/// Plans: a folder of Markdown documents for each habit, project and hobby. Edit on the left, rendered on the right.
struct PlansView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [PlansStore.File] = []
    @State private var selectedFile: PlansStore.File?
    @State private var text = ""
    @State private var loadedText = ""
    @State private var mode: Mode = .split
    @State private var renaming: PlansStore.File?
    @State private var newName = ""
    @State private var confirmTrash: PlansStore.File?

    enum Mode: String, CaseIterable, Identifiable {
        case edit = "Edit", split = "Split", preview = "Preview"
        var id: String { rawValue }
    }

    private var kinds: [BucketKind] { [.mainWork, .anchor, .hobby] }

    var body: some View {
        @Bindable var model = model
        let _ = model.revision
        HStack(spacing: 0) {
          if !model.planFocus {
            List(selection: $model.planActivityID) {
                ForEach(kinds) { kind in
                    let items = model.activities(in: kind)
                    if !items.isEmpty {
                        Section(kind.title) {
                            ForEach(items) { a in
                                HStack {
                                    Label(a.name, systemImage: kind.icon).lineLimit(1)
                                    Spacer()
                                    let n = PlansStore.count(for: a.id)
                                    if n > 0 { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                }
                                .tag(a.id)
                            }
                        }
                    }
                }
            }
            .frame(width: 200)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Documents").font(.headline)
                    Spacer()
                    Button { newFile() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New document (⌘⇧D)")
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                        .disabled(model.planActivityID == nil)
                    Button { if let id = model.planActivityID { PlansStore.reveal(id) } } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                        .disabled(model.planActivityID == nil)
                }
                .padding(10)
                if model.planActivityID == nil {
                    placeholder("Pick something on the left.")
                } else if files.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No documents yet.").foregroundStyle(.secondary)
                        Button("Start a plan") { newFile(template: true) }.buttonStyle(.borderedProminent)
                    }
                    .padding(10)
                    Spacer()
                } else {
                    List(selection: Binding(get: { selectedFile }, set: { open($0) })) {
                      ForEach(files) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).lineLimit(1)
                            Text(f.modified.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .tag(f)
                        .contextMenu {
                            Button("Rename…") { newName = f.name; renaming = f }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { confirmTrash = f }
                        }
                      }
                      .onMove { from, to in
                          guard let id = model.planActivityID else { return }
                          files.move(fromOffsets: from, toOffset: to)
                          PlansStore.setOrder(files, for: id)
                      }
                    }
                }
            }
            .frame(width: 180)

            Divider()
          }

            Group {
                if let file = selectedFile {
                    switch mode {
                    case .edit: editor
                    case .preview: preview
                    case .split: HSplitView { editor.frame(minWidth: 240); preview.frame(minWidth: 240) }
                    }
                    let _ = file
                } else {
                    placeholder(model.planActivityID == nil ? "" : "Pick or create a document.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Plans")
        .navigationSubtitle(model.planActivityID.flatMap { model.activity($0)?.name } ?? "")
        .toolbar {
            ToolbarItem {
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .disabled(selectedFile == nil)
            }
            ToolbarItem {
                Button { setFocus(!model.planFocus) } label: {
                    Label(model.planFocus ? "Show Lists" : "Focus",
                          systemImage: model.planFocus ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help(model.planFocus ? "Show lists (⇧⌘F / Esc)" : "Focus on this document (⇧⌘F)")
                .disabled(selectedFile == nil)
            }
        }
        .onExitCommand { if model.planFocus { setFocus(false) } }
        .onDisappear { if model.planFocus { setFocus(false) } }
        .onAppear {
            if model.planActivityID == nil { model.planActivityID = model.activities(in: .mainWork).first?.id }
            reload()
        }
        .onChange(of: model.planActivityID) { _, _ in save(); selectedFile = nil; reload() }
        .onDisappear { save() }
        // Autosave shortly after typing stops.
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { save() }
        }
        .alert("Rename document", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let f = renaming, let renamed = PlansStore.rename(f, to: newName) {
                    let wasOpen = selectedFile == f
                    reload()
                    if wasOpen { selectedFile = renamed }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move \(confirmTrash?.name ?? "") to the Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let f = confirmTrash {
                    if selectedFile == f { selectedFile = nil; text = ""; loadedText = "" }
                    PlansStore.trash(f)
                    reload()
                }
                confirmTrash = nil
            }
        } message: {
            Text("You can still restore it from the Trash.")
        }
    }

    /// Focus mode: hide the Plans lists so the document gets the whole area (the main sidebar stays).
    private func setFocus(_ on: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { model.planFocus = on }
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
    }

    private var preview: some View {
        ScrollView {
            MarkdownView(source: text) { toggleTask($0) }
                .padding(model.planFocus ? 40 : 20)
                .frame(maxWidth: model.planFocus ? 820 : .infinity)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        guard let id = model.planActivityID else { files = []; return }
        files = PlansStore.files(for: id)
        if selectedFile == nil || !files.contains(where: { $0.url == selectedFile?.url }) {
            open(files.first)
        }
    }

    private func open(_ f: PlansStore.File?) {
        save()
        selectedFile = f
        text = f.map(PlansStore.read) ?? ""
        loadedText = text
    }

    private func save() {
        guard let f = selectedFile, text != loadedText else { return }
        PlansStore.write(text, to: f)
        loadedText = text
    }

    private func newFile(template: Bool = false) {
        guard let id = model.planActivityID, let a = model.activity(id) else { return }
        let contents = template
            ? "# \(a.name)\n\n## Goal\n\n\n## Next steps\n- [ ] \n\n## Notes\n"
            : "# New document\n\n"
        if let f = try? PlansStore.create(in: id, name: template ? "Plan" : "Untitled", contents: contents) {
            reload()
            open(f)
            mode = mode == .preview ? .split : mode
        }
    }

    /// Ticking a box in the preview flips the n-th task in the source.
    private func toggleTask(_ n: Int) {
        var lines = text.components(separatedBy: "\n")
        var seen = 0
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- [") || t.hasPrefix("* [") || t.hasPrefix("+ [") else { continue }
            if seen == n {
                if let r = lines[i].range(of: "[ ]") { lines[i].replaceSubrange(r, with: "[x]") }
                else if let r = lines[i].range(of: "[x]") ?? lines[i].range(of: "[X]") { lines[i].replaceSubrange(r, with: "[ ]") }
                break
            }
            seen += 1
        }
        text = lines.joined(separator: "\n")
    }
}
