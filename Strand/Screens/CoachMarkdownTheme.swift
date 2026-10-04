import SwiftUI
import MarkdownUI
import StrandDesign

/// The MarkdownUI theme for Coach replies.
///
/// LLM chat replies (OpenAI / Anthropic / Gemini) arrive as GitHub-flavored
/// Markdown — overwhelmingly bold, bullet/numbered lists, `###` headings, and the
/// occasional table for a weekly plan. This theme renders that set in the Strand
/// look, sized for a chat bubble: headings are capped near body size (a `#` must
/// not shout inside a 560pt bubble), and tables get hairline borders.
extension Theme {
    /// Hanken Grotesk named instances of the bundled variable font. MarkdownUI builds its fonts with
    /// `Font.custom(name:)`, so the v2 weights are reached through the instances' exact PostScript names
    /// (CoreText's "HankenGrotesk-Light" alias resolves on macOS but falls back to Helvetica on iOS).
    /// `FontWeight` is avoided: on this face SwiftUI's `.light` lands near 200 and `.medium` near 600.
    private static let lightFace = "HankenGrotesk-Regular_Light"
    private static let bookFace = "HankenGrotesk-Regular"

    static let strand: Theme = {
        // The faces must be registered before MarkdownUI resolves them by name.
        NoopFonts.registerIfNeeded()
        return Theme()
        // v2 reply copy: 14.5 pt Light in 86 % ink; bold runs step up to Book in full ink.
        .text {
            FontFamily(.custom(Theme.lightFace))
            ForegroundColor(StrandPalette.textPrimary.opacity(0.86))
            FontSize(14.5)
        }
        .strong {
            FontFamily(.custom(Theme.bookFace))
            ForegroundColor(StrandPalette.textPrimary)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(StrandPalette.textPrimary)
            BackgroundColor(NoopVisualStyle.inset)
        }
        .link {
            ForegroundColor(StrandPalette.textPrimary)
            UnderlineStyle(.single)
        }
        // Headings in Book: h1/h2 land at headline size (17), h3 just above body,
        // h4–h6 as overline-ish small caps labels.
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontFamily(.custom(Theme.bookFace))
                    FontSize(17)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontFamily(.custom(Theme.bookFace))
                    FontSize(17)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle {
                    FontFamily(.custom(Theme.bookFace))
                    FontSize(16)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontFamily(.custom(Theme.bookFace))
                    FontSize(15)
                    ForegroundColor(StrandPalette.textPrimary)
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontFamily(.custom(Theme.bookFace))
                    FontSize(13)
                    ForegroundColor(StrandPalette.textSecondary)
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontFamily(.custom(Theme.bookFace))
                    FontSize(12)
                    ForegroundColor(StrandPalette.textSecondary)
                }
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.26))
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.2))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .markdownTextStyle {
                    ForegroundColor(StrandPalette.textSecondary)
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(NoopVisualStyle.borderHighlight)
                        .frame(width: 3)
                }
                .markdownMargin(top: 4, bottom: 8)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                    }
                    .padding(10)
            }
            .background(NoopVisualStyle.inset)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NoopVisualStyle.border, lineWidth: 1))
            .markdownMargin(top: 4, bottom: 8)
        }
        .thematicBreak {
            NoopVisualStyle.border
                .frame(height: 1)
                .markdownMargin(top: 10, bottom: 10)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: NoopVisualStyle.border))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, NoopVisualStyle.inset)
                )
                .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontFamily(.custom(Theme.bookFace))
                    }
                    FontSize(.em(0.9))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .relativeLineSpacing(.em(0.2))
        }
    }()
}
