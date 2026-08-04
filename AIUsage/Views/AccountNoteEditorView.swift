import SwiftUI

struct AccountNoteEditorView: View {
    let providerTitle: String
    let accountLabel: String
    let note: String?
    let onSave: (String?) -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftNote: String

    init(providerTitle: String, accountLabel: String, note: String?, onSave: @escaping (String?) -> Void) {
        self.providerTitle = providerTitle
        self.accountLabel = accountLabel
        self.note = note
        self.onSave = onSave
        _draftNote = State(initialValue: note ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Edit Account Note", "编辑账号注释"))
                .font(.title3)
                .bold()

            Text("\(providerTitle) · \(accountLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(L("e.g. Main account / Work account / Test machine", "例如：主账号 / 工作账号 / 测试机器"), text: $draftNote)
                .textFieldStyle(.roundedBorder)

            Spacer()

            HStack {
                Button(L("Cancel", "取消")) {
                    dismiss()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(L("Save", "保存")) {
                    onSave(draftNote.nilIfBlank)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460, height: 200)
        .appPageChrome(colorScheme)
    }
}
