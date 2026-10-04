import SwiftUI
import StrandDesign

// MARK: - Lift sheets v2 chrome
//
// The frame every Lift Log sheet (program editor, exercise line, add exercise, edit sets, session detail,
// import) is drawn in: the kit's sheet header, an optional lead-in sentence, a scrolling column, and the
// v2 sheet presentation. The sheets keep their own fields and actions; this only replaces the page they
// used to borrow from `ScreenScaffold`, whose tab-bar clearance and large title belong to screens, not
// sheets.

/// A v2 sheet page: `NoopSheetHeader` (cancel · title), the lead-in, then `content` in a 20 pt gutter. On iOS
/// it carries `noopSheetPresentation`; on macOS the sheet gradient (the caller keeps its fixed frame there,
/// which a macOS sheet hosting a ScrollView needs).
struct LiftSheetScaffold<Content: View>: View {
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    private let cancelTitle: LocalizedStringKey
    private let onCancel: () -> Void
    @ViewBuilder private var content: () -> Content

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
         cancelTitle: LocalizedStringKey = "Cancel", onCancel: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetHeader(title, cancelTitle: cancelTitle, doneTitle: nil, onCancel: onCancel)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let subtitle {
                        Text(subtitle)
                            .font(StrandFont.light(14, relativeTo: .subheadline))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                    }
                    content()
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .background(NoopSheetBackground())
        #endif
    }
}

/// The destructive row at the end of a sheet ("Delete program", "Discard session"): a red label with a
/// trash icon, no fill.
struct LiftDestructiveLabel: View {
    private let title: Text
    init(_ title: LocalizedStringKey) { self.title = Text(title) }

    var body: some View {
        HStack(spacing: 8) {
            PhIcon("trash", size: 18)
            title
        }
        .font(StrandFont.book(15, relativeTo: .body))
        .foregroundStyle(StrandPalette.statusCritical)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .contentShape(Rectangle())
    }
}
