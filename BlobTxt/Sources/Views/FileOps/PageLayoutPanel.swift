import SwiftUI

// The Page Layout panel: a window-level overlay (same chrome as Merge Blobs) for managing the
// app-global layout profiles that drive Print/PDF export. Left column lists the profiles; the right
// column edits the selected one with a buffered Save/Cancel.
struct PageLayoutPanel: View {
    @EnvironmentObject var appColors: AppColors
    @ObservedObject private var store = LayoutStore.shared

    // Closes the panel and returns to the File Ops sidebar (mirrors Merge Blobs' cancel).
    let onExit: () -> Void

    // The profile shown on the right. The default is shown read-only; a custom profile is editable,
    // and `draft` is its working copy (committed to the store only on Save).
    @State private var selectedID: UUID?
    @State private var draft: LayoutProfile?

    // A row tap / Add deferred behind the unsaved-changes prompt.
    private enum PendingAction { case select(UUID), addNew }
    @State private var pending: PendingAction?
    @State private var showDiscardPrompt = false
    @State private var escMonitor: Any?

    private let leftColumnWidth: CGFloat = 200
    private let panelSize: CGFloat = 640

    var body: some View {
        ZStack {
            // Dimming scrim; a tap does nothing, so the panel leaves only through Exit/Save/Cancel.
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            GeometryReader { geo in
                panel
                    .frame(
                        width: min(geo.size.width - 80, panelSize),
                        height: min(geo.size.height - 80, panelSize)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        // Open with the go-to profile already selected, rather than an empty detail pane.
        .onAppear {
            perform(.select(store.goToProfileID))
            // Escape mirrors the footer's leading button: Cancel the edit if a custom profile is open,
            // otherwise Exit. Installed here so it wins over the editor behind the panel. Yields while
            // the unsaved-changes alert is up so that alert handles its own Escape.
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard NSApp.mainWindow?.isKeyWindow == true else { return event }
                guard event.keyCode == 53, !showDiscardPrompt else { return event } // Escape
                if isEditingCustom { cancelEdit() } else { onExit() }
                return nil
            }
        }
        .onDisappear {
            if let mon = escMonitor { NSEvent.removeMonitor(mon); escMonitor = nil }
        }
        .alert("Unsaved Changes", isPresented: $showDiscardPrompt) {
            Button("Save") { commitDraft(); resolvePending() }
            Button("Discard", role: .destructive) { resolvePending() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("This profile has unsaved changes.")
        }
    }

    // header band • content (list | detail) • footer band — the shared bands give both columns the
    // same vertical extent.
    private var panel: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                leftColumn
                    .frame(width: leftColumnWidth)
                    .background(appColors.uiSurface)
                detailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(appColors.uiSurface)
            }
            footer
        }
        .background(appColors.uiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }

    private var header: some View {
        HStack {
            Text("Layout Profiles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(appColors.uiTextHeading)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Left column

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.allProfiles) { profile in
                    profileRow(profile)
                }
                addRow
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: LayoutProfile) -> some View {
        let isSelected = selectedID == profile.id
        let row = ProfileRow(
            name: profile.name,
            isGoTo: store.isGoTo(profile.id),
            isSelected: isSelected,
            onTap: { attempt(.select(profile.id)) }
        )
        if profile.isDefault {
            // The default can't be edited, duplicated, or removed, but it can still be made the go-to.
            row.contextMenu {
                Button("Set as go-to") { store.setGoTo(profile.id) }
            }
        } else {
            row.contextMenu {
                Button("Edit") { attempt(.select(profile.id)) }
                Button("Duplicate") { store.duplicate(profile) }
                Button("Set as go-to") { store.setGoTo(profile.id) }
                Divider()
                Button("Remove", role: .destructive) { removeProfile(profile.id) }
            }
        }
    }

    private var addRow: some View {
        AddProfileRow { attempt(.addNew) }
    }

    // MARK: - Right column

    // A nil-safe binding into `draft`. A force-unwrapping `Binding($draft)` would trap when the open
    // profile is removed (draft → nil) and SwiftUI re-reads the still-mounted detail pane before it
    // unmounts; this returns a throwaway default in that transient frame instead.
    private var draftBinding: Binding<LayoutProfile> {
        Binding(
            get: { draft ?? .defaultProfile },
            set: { draft = $0 }
        )
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let id = selectedID {
            LayoutDetailPane(draft: draftBinding, readOnly: id == LayoutProfile.defaultID)
                .id(id)
        } else {
            VStack {
                Spacer()
                Text("Select a profile to edit, or add a new one.")
                    .font(.system(size: 13))
                    .foregroundColor(appColors.uiTextMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isEditingCustom {
                SecondaryButton(title: "Cancel") { cancelEdit() }
                Spacer()
                PrimaryButton(title: "Save", enabled: true) { commitDraft(); cancelEdit() }
            } else {
                SecondaryButton(title: "Exit", action: onExit)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(appColors.surface)
    }

    // MARK: - Selection / editing logic

    // True when a custom (editable) profile is open. The default opens read-only and is not "editing".
    private var isEditingCustom: Bool {
        guard let id = selectedID else { return false }
        return id != LayoutProfile.defaultID
    }

    private var isDirty: Bool {
        guard isEditingCustom, let id = selectedID, let d = draft else { return false }
        return d != store.profile(for: id)
    }

    // Routes a selection/add through the unsaved-changes guard.
    private func attempt(_ action: PendingAction) {
        if isDirty {
            pending = action
            showDiscardPrompt = true
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case .select(let id):
            selectedID = id
            draft = store.profile(for: id)
        case .addNew:
            let created = store.addProfile()
            selectedID = created.id
            draft = created
        }
    }

    private func resolvePending() {
        guard let action = pending else { return }
        pending = nil
        perform(action)
    }

    private func commitDraft() {
        guard let d = draft else { return }
        store.update(d)
    }

    // Discards the working copy and returns to the no-selection state (Exit becomes available again).
    private func cancelEdit() {
        selectedID = nil
        draft = nil
    }

    private func removeProfile(_ id: UUID) {
        store.remove(id)
        if selectedID == id { cancelEdit() }
    }
}

// MARK: - Rows

private struct ProfileRow: View {
    @EnvironmentObject var appColors: AppColors
    let name: String
    let isGoTo: Bool
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 13))
                .foregroundColor(appColors.uiTextResting)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isGoTo {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(appColors.uiConfirmation)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowBackground))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return appColors.uiSunken.opacity(0.5)
        } else if hovering {
            return appColors.uiSunken.opacity(0.25)
        } else {
            return .clear
        }
    }
}

private struct AddProfileRow: View {
    @EnvironmentObject var appColors: AppColors
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text("+ Add a new profile")
                .font(.system(size: 13))
                .foregroundColor(hovering ? appColors.uiTextBody : appColors.uiTextMuted)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

// MARK: - Footer buttons (same styling as the Merge Blobs panel)

private struct SecondaryButton: View {
    @EnvironmentObject var appColors: AppColors
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(hovering ? appColors.textBody : appColors.textResting)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PrimaryButton: View {
    @EnvironmentObject var appColors: AppColors
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(enabled ? (hovering ? appColors.surface : appColors.metaIndication) : appColors.textMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(enabled && hovering ? appColors.metaIndication : appColors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(enabled ? appColors.metaIndication : appColors.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = enabled ? $0 : false }
    }
}

#Preview {
    PageLayoutPanel(onExit: {})
        .environmentObject(AppColors.shared)
        .frame(width: 1100, height: 760)
}
