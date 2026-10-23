import SwiftUI
import AppKit

struct StylePage: View {
    @ObservedObject private var store = StyleStore.shared
    @State private var expanded: String? = "mail"

    var body: some View {
        DictumPageFrame(page: .style) {
            ScrollView {
                VStack(spacing: 26) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            controls(formality: $store.global.formality, tone: $store.global.tone, emoji: $store.global.emoji)
                            HStack {
                                Text("Sign-off", tableName: "DictumStyle")
                                Spacer()
                                TextField("", text: Binding(get: { store.global.signOff ?? "" }, set: { store.global.signOff = $0 }))
                                    .frame(width: 180).accessibilityLabel(Text("Sign-off", tableName: "DictumStyle"))
                            }.frame(height: 46).overlay(alignment: .top) { DictumTheme.separator.frame(height: 0.5) }
                        }.padding(.vertical, 6).padding(.horizontal, 18)
                        preview(formality: store.global.formality, tone: store.global.tone, emoji: store.global.emoji,
                                signOff: store.global.formality == .formal ? store.global.signOff : nil, showsInput: true)
                            .frame(width: 300)
                    }.background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(spacing: 10) {
                        HStack {
                            Text("Per app", tableName: "DictumStyle").font(DictumTheme.Typography.section)
                            Spacer()
                            Menu {
                                Section {
                                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                                        Button { addApp(app.bundleURL) } label: {
                                            if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                            Text(verbatim: app.localizedName ?? app.bundleIdentifier ?? "")
                                        }
                                    }
                                } header: { Text("Running", tableName: "DictumStyle") }
                                Button { chooseApp() } label: { Text("Choose from Applications…", tableName: "DictumStyle") }
                            } label: { Text("Add App", tableName: "DictumStyle") }.fixedSize()
                        }
                        VStack(spacing: 1) {
                            ForEach($store.apps) { $app in
                                VStack(spacing: 0) {
                                    Button {
                                        withAnimation(DictumTheme.Motion.spring) { expanded = expanded == app.id ? nil : app.id }
                                    } label: {
                                        HStack(spacing: 12) {
                                            HStack(spacing: -6) {
                                                ForEach(Array(app.bundleIDs.prefix(4)), id: \.self) { id in
                                                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                                                    }
                                                }
                                            }.frame(width: 66, alignment: .leading)
                                            if app.isBuiltIn {
                                                Text(LocalizedStringKey(app.name), tableName: "DictumStyle").frame(width: 110, alignment: .leading)
                                            } else { Text(verbatim: app.name).frame(width: 110, alignment: .leading) }
                                            Text(summary(app)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                            Spacer(minLength: 0)
                                            Image(systemName: expanded == app.id ? "chevron.down" : "chevron.right").foregroundStyle(.tertiary)
                                        }.frame(height: 48).padding(.horizontal, 12).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .background(expanded == app.id ? DictumTheme.selected.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                    if expanded == app.id {
                                        HStack(alignment: .top, spacing: 20) {
                                            VStack(spacing: 0) {
                                                controls(formality: $app.formality, tone: $app.tone, emoji: $app.emoji, rowHeight: 42)
                                                HStack {
                                                    Text("Add sign-off", tableName: "DictumStyle")
                                                    Spacer()
                                                    Toggle(isOn: $app.addSignOff) { Text("Add sign-off", tableName: "DictumStyle") }
                                                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                                }.frame(height: 42).overlay(alignment: .top) { DictumTheme.separator.frame(height: 0.5) }
                                                TextField(text: $app.extraInstructions, axis: .vertical) {
                                                    Text("Extra instructions, e.g. use bullet lists", tableName: "DictumStyle")
                                                }.lineLimit(2...4).frame(height: 54).padding(.top, 8)
                                                HStack {
                                                    if app.isBuiltIn {
                                                        Text("Built-in: \(app.applicationCount) apps", tableName: "DictumStyle")
                                                            .font(.caption).foregroundStyle(.secondary)
                                                    }
                                                    Spacer()
                                                    if app.isBuiltIn {
                                                        Button { if let original = AppStyle.defaults.first(where: { $0.id == app.id }) { app = original } } label: {
                                                            Text("Restore Default", tableName: "DictumStyle")
                                                        }
                                                    } else {
                                                        Button(role: .destructive) { store.apps.removeAll { $0.id == app.id } } label: {
                                                            Text("Remove", tableName: "DictumStyle")
                                                        }
                                                    }
                                                }.padding(.top, 10)
                                            }
                                            preview(formality: app.formality, tone: app.tone, emoji: app.emoji,
                                                    signOff: app.addSignOff ? store.global.signOff : nil, showsInput: false).frame(width: 250)
                                        }.padding(.leading, 90).padding(.trailing, 12).padding(.top, 6).padding(.bottom, 14)
                                    }
                                }
                            }
                        }.padding(4).background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: 760).padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 28).frame(maxWidth: .infinity)
            }
        }
    }

    private func controls(formality: Binding<StyleFormality>, tone: Binding<StyleTone>, emoji: Binding<StyleEmoji>, rowHeight: CGFloat = 46) -> some View {
        VStack(spacing: 0) {
            choice("Formality", selection: formality, values: StyleFormality.allCases).frame(height: rowHeight)
            DictumTheme.separator.frame(height: 0.5)
            choice("Tone", selection: tone, values: StyleTone.allCases).frame(height: rowHeight - 0.5)
            DictumTheme.separator.frame(height: 0.5)
            choice("Emoji", selection: emoji, values: StyleEmoji.allCases).frame(height: rowHeight - 0.5)
        }
    }

    private func choice<T: RawRepresentable & Hashable>(_ title: LocalizedStringKey, selection: Binding<T>, values: [T]) -> some View where T.RawValue == String {
        HStack(spacing: 12) {
            Text(title, tableName: "DictumStyle")
            Spacer(minLength: 8)
            Picker(selection: selection) {
                ForEach(values, id: \.self) { value in Text(LocalizedStringKey(value.rawValue), tableName: "DictumStyle").tag(value) }
            } label: { Text(title, tableName: "DictumStyle") }
                .labelsHidden().pickerStyle(.segmented).frame(width: 144)
        }
    }

    private func preview(formality: StyleFormality, tone: StyleTone, emoji: StyleEmoji, signOff: String?, showsInput: Bool) -> some View {
        VStack(alignment: .leading, spacing: showsInput ? 10 : 8) {
            if showsInput {
                Text("You said", tableName: "DictumStyle").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).frame(height: 16, alignment: .leading)
                Text(StylePreview.spoken).font(.system(size: 12.5)).lineSpacing(5).foregroundStyle(.secondary).frame(minHeight: 40)
            }
            Text(showsInput ? "dictum writes" : "Example", tableName: "DictumStyle").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).frame(height: 16, alignment: .leading)
            StylePreviewWell(text: StylePreview.text(formality: formality, tone: tone, emoji: emoji, signOff: signOff),
                             minimumHeight: showsInput ? 84 : 0)
        }.padding(.horizontal, showsInput ? 18 : 0).padding(.vertical, showsInput ? 16 : 8)
            .frame(maxWidth: .infinity, alignment: .leading).background(showsInput ? DictumTheme.inset : .clear)
    }

    private func summary(_ app: AppStyle) -> String {
        let choices = [app.formality.rawValue, app.tone.rawValue, "summary.emoji." + app.emoji.rawValue]
            + (app.addSignOff ? ["Sign-off"] : [])
        return choices.map {
            String(localized: String.LocalizationValue($0), table: "DictumStyle")
        }.joined(separator: " · ") + (app.extraInstructions.isEmpty ? "" : " · " + app.extraInstructions)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK { addApp(panel.url) }
    }

    private func addApp(_ url: URL?) {
        guard let url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              !store.apps.contains(where: { !$0.isBuiltIn && $0.bundleIDs.contains(id) }) else { return }
        let global = store.global
        let app = AppStyle(id: UUID().uuidString, kind: .userApp, name: FileManager.default.displayName(atPath: url.path),
                           bundleIDs: [id], urlPatterns: [], formality: global.formality, tone: global.tone, emoji: global.emoji)
        store.apps.append(app)
        expanded = app.id
    }
}
