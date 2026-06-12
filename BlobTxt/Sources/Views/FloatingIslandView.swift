import SwiftUI

enum IslandButton: CaseIterable, Hashable {
    case navigator, search, metadata

    var icon: String {
        switch self {
        case .navigator: return "tray.full"
        case .search:    return "magnifyingglass"
        case .metadata:  return "info.circle"
        }
    }

    var notification: Notification.Name {
        switch self {
        case .navigator: return .toggleNavigator
        case .search:    return .toggleSearch
        case .metadata:  return .toggleMetadata
        }
    }

    var panel: SidebarPanel? {
        switch self {
        case .navigator: return .navigator
        case .search:    return .search
        case .metadata:  return .metadata
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
                .fill(colors.chromePanel)

            if isExpanded {
                let slotW = floatWidth / CGFloat(IslandButton.allCases.count)

                // Active panel indicator: metaIndication, shown only when a panel is open
                if isSidebarOpen,
                   let activeBtn = IslandButton.allCases.first(where: { $0.panel == activePanel }),
                   hoveredButton != activeBtn,
                   let activeIdx = IslandButton.allCases.firstIndex(of: activeBtn) {
                    RoundedRectangle(cornerRadius: radius - 3)
                        .fill(colors.metaIndication.opacity(0.9))
                        .frame(width: slotW - 6, height: height - 6)
                        .offset(x: CGFloat(activeIdx) * slotW + 3)
                        .animation(.spring(response: 0.2, dampingFraction: 0.92), value: activePanel)
                }

                // Hover indicator: slides to whichever button the cursor is over
                if let hovered = hoveredButton {
                    let idx = CGFloat(IslandButton.allCases.firstIndex(of: hovered) ?? 0)
                    RoundedRectangle(cornerRadius: radius - 3)
                        .fill(colors.surfaceRaised)
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
                                    hasRaisedOverlay ? colors.textBody
                                    : hasColorOverlay ? colors.surface
                                    : colors.textResting
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
                    NotificationCenter.default.post(name: .toggleNavigator, object: nil)
                } label: {
                    Image(systemName: "command")
                        .foregroundColor(colors.textResting)
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
