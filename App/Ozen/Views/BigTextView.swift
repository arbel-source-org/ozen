import SwiftUI
import OzenKit

/// Words in letters big enough to read across a table.
///
/// Where captions can't keep up (a noisy café, a name the recognizer keeps
/// getting wrong), the other person can type on her phone and she reads it
/// here. And what she typed can be turned around, upside down to her, so
/// the person facing her reads it instead of hearing it.
struct BigTextView: View {
    @Binding var text: String
    let display: DisplayPreferences
    let canSpeak: Bool
    let onSpeak: (String) -> Void

    @State private var isFlipped = false
    @FocusState private var isTyping: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let fontSize: CGFloat = 52

    private var theme: CaptionTheme { CaptionTheme(display.theme) }
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            words
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            controls
        }
        .accessibilityIdentifier("bigTextScreen")
        .background(theme.background.ignoresSafeArea())
        .preferredColorScheme(theme.colorScheme)
        .onAppear { isTyping = !isFlipped }
    }

    @ViewBuilder
    private var words: some View {
        if isFlipped {
            // Read-only while upside down: editing text that is drawn
            // rotated would put the cursor where no one expects it.
            //
            // Centered vertically (falling back to top-anchored, scrollable
            // once it outgrows the space): on an iPad-sized screen, a short
            // phrase left at the scroll view's natural top edge landed at
            // the bottom once flipped, right against the control buttons,
            // with the rest of the screen the other person is reading it
            // from left blank above it.
            GeometryReader { geometry in
                ScrollView {
                    Text(text)
                        .font(.system(size: Self.fontSize, weight: .bold))
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                        .padding(24)
                }
            }
            .rotationEffect(.degrees(180))
            .accessibilityLabel(text)
        } else {
            ZStack(alignment: .topLeading) {
                if isEmpty {
                    Text(tr("כתבו כאן…", "Type here…"))
                        .font(.system(size: Self.fontSize, weight: .bold))
                        .foregroundStyle(theme.pendingText)
                        .padding(.horizontal, 29)
                        .padding(.vertical, 32)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .font(.system(size: Self.fontSize, weight: .bold))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .focused($isTyping)
                    .padding(24)
                    .accessibilityLabel(tr("טקסט גדול", "Big text"))
            }
        }
    }

    // Two to a row above accessibility sizes; even that was too narrow at
    // the largest one, where a single Hebrew word like "ניקוי" wrapped
    // letter by letter down its half of the row, and the whole grid grew
    // tall enough to push the text area up under the status bar.
    private var gridColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    private var controls: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            Button {
                text = ""
                isFlipped = false
                isTyping = true
            } label: {
                Label(tr("ניקוי", "Clear"), systemImage: "eraser")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isEmpty)

            Button {
                isFlipped.toggle()
                isTyping = !isFlipped
            } label: {
                Label(isFlipped ? tr("חזרה", "Back") : tr("להפוך", "Flip"), systemImage: "arrow.up.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isEmpty)
            .accessibilityHint(tr("הופך את הטקסט כדי שמי שיושב מולך יוכל לקרוא", "Flips the text so the person sitting across from you can read it"))

            if canSpeak {
                Button {
                    onSpeak(text)
                } label: {
                    Label(tr("להשמיע", "Speak"), systemImage: "speaker.wave.3.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isEmpty)
            }

            Button {
                dismiss()
            } label: {
                Label(tr("סגירה", "Close"), systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.headline)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(theme.chrome)
        .padding(16)
    }
}
