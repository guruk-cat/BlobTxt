import SwiftUI

enum IslandButton: CaseIterable, Hashable {
    case navigator, scratchpad, unfinishedPanelOps, unfinishedPanelMetadata

    var icon: String {
        switch self {
        case .navigator: return "tray.full"
        case .scratchpad: return "text.pad.header"
        case .unfinishedPanelOps: return "arrow.trianglehead.swap"
        case .unfinishedPanelMetadata: return "info.circle"
        }
    }

    var notification: Notification.Name {
        switch self {
        case .navigator: return .toggleNavigator
        case .scratchpad: return .toggleScratchpad
        case .unfinishedPanelOps: return .toggleOps
        case .unfinishedPanelMetadata: return .toggleMetadata
        }
    }

    var panel: SidebarPanel? {
        switch self {
        case .navigator: return .navigator
        case .scratchpad: return .scratchpad
        case .unfinishedPanelOps: return .opsControl
        case .unfinishedPanelMetadata: return .metadataControl
        }
    }
}

struct FloatingIslandView: View {
    @Binding var isSidebarOpen: Bool
    @Binding var activePanel: SidebarPanel
    @ObservedObject private var colors = AppColors.shared

    @State private var isHovering = false
    @State private var hoveredButton: IslandButton? = nil

    private let floatWidth: CGFloat = 254
    private let height: CGFloat = 40
    private let radius: CGFloat = 12
    private let collapsedWidth: CGFloat = 40

    var isExpanded: Bool { isSidebarOpen || isHovering }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: radius)
                .fill(colors.uiPanel)

            if isExpanded {
                let slotW = floatWidth / CGFloat(IslandButton.allCases.count)

                /*
                 Active panel indicator: shown only when a panel is open.
                 The view stays mounted whenever the sidebar is open and is merely hidden
                 (opacity 0) while its own button is hovered. This keeps its position tracking
                 activePanel even while invisible. This way, it never slides in from a
                 stale spot when the cursor leaves the button.
                 */
                if isSidebarOpen,
                    let activeBtn = IslandButton.allCases.first(where: { $0.panel == activePanel }),
                    let activeIdx = IslandButton.allCases.firstIndex(of: activeBtn) {
                    RoundedRectangle(cornerRadius: radius - 3)
                        .fill(colors.uiIndication.opacity(0.9))
                        .frame(width: slotW - 6, height: height - 6)
                        .offset(x: CGFloat(activeIdx) * slotW + 3)
                        .opacity(hoveredButton == activeBtn ? 0 : 1)
                        .animation(nil, value: hoveredButton)
                        .animation(.spring(response: 0.2, dampingFraction: 0.92), value: activePanel)
                }

                // Hover indicator: slides to whichever button the cursor is over
                if let hovered = hoveredButton {
                    let idx = CGFloat(IslandButton.allCases.firstIndex(of: hovered) ?? 0)
                    RoundedRectangle(cornerRadius: radius - 3)
                        .fill(colors.uiSunken)
                        .frame(width: slotW - 6, height: height - 6)
                        .offset(x: idx * slotW + 3)
                        .animation(.spring(response: 0.2, dampingFraction: 0.92), value: hoveredButton)
                }

                HStack(spacing: 0) {
                    ForEach(IslandButton.allCases, id: \.self) { btn in
                        let hasRaisedOverlay = hoveredButton == btn
                        let hasColorOverlay = isSidebarOpen && btn.panel == activePanel
                        Button {
                            NotificationCenter.default.post(name: btn.notification, object: nil)
                        } label: {
                            Image(systemName: btn.icon)
                                .foregroundColor(
                                    hasRaisedOverlay ? colors.uiTextBody
                                    : hasColorOverlay ? colors.uiPanel
                                    : colors.uiTextResting
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: height)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { h in
                            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                                hoveredButton = h ? btn : nil
                            }
                        }
                    }
                }
                .frame(width: floatWidth)
                .transition(.opacity)

            } else {
                Button {
                    // defaults to navigator because it's the first button in the chain
                    NotificationCenter.default.post(name: .toggleNavigator, object: nil)
                } label: {
                    Image(systemName: "command")
                        .foregroundColor(colors.uiTextResting)
                        .frame(width: collapsedWidth, height: height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        // Frame drives the hit area; clipShape rounds corners at every animated width.
        // clipShape must come after frame so the clip tracks the animated size.
        .frame(width: isExpanded ? floatWidth : collapsedWidth, height: height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isExpanded)
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovering = h
                if !h { hoveredButton = nil }
            }
        }
    }
}
