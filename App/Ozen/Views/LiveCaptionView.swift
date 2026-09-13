import SwiftUI
import OzenKit

/// The whole point of the app: a full-screen, large-type, high-contrast
/// scrolling transcript. Dark by default (staring at a bright white
/// caption screen through a whole conversation is unpleasant), one
/// persistent control row, no modals interrupting an active conversation.
struct LiveCaptionView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var showingMicPicker = false
    @State private var showingSettings = false
    @State private var namingSegment: TranscriptSegment?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .trailing, spacing: 18) {
                        ForEach(viewModel.segments) { segment in
                            CaptionRow(
                                segment: segment,
                                speakerName: viewModel.displayName(for: segment)
                            )
                            .id(segment.id)
                            .onTapGesture { namingSegment = segment }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 120)
                }
                .onChange(of: viewModel.segments.last?.text) {
                    guard let lastID = viewModel.segments.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }

            controlBar
        }
        .task { await viewModel.start() }
        .sheet(isPresented: $showingMicPicker) {
            MicPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(item: $namingSegment) { segment in
            NameSpeakerSheet(segment: segment, viewModel: viewModel)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button {
                showingMicPicker = true
            } label: {
                Label(currentInputLabel, systemImage: "mic")
            }
            .buttonStyle(.bordered)

            Spacer()

            statusIndicator

            Spacer()

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
    }

    private var currentInputLabel: String {
        viewModel.availableInputs.first { $0.uid == viewModel.selectedInputUID }?.portName ?? "מיקרופון"
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch viewModel.engineAvailability {
        case .available:
            Label(viewModel.isListening ? "מקשיב" : "מוכן", systemImage: "waveform")
                .foregroundStyle(.green)
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
                .lineLimit(1)
        }
    }
}

/// One utterance. `isCommitted` drives the only visual difference that
/// matters here: committed text is solid and permanent, pending text is
/// dimmer and italic to signal "still settling" — nothing is ever
/// truncated in either state.
private struct CaptionRow: View {
    let segment: TranscriptSegment
    let speakerName: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(speakerName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SpeakerColor.color(forClusterID: segment.speakerClusterID))

            Text(segment.text)
                .font(.system(size: 30, weight: segment.isCommitted ? .medium : .regular))
                .italic(!segment.isCommitted)
                .foregroundStyle(segment.isCommitted ? .white : .white.opacity(0.6))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct NameSpeakerSheet: View {
    let segment: TranscriptSegment
    let viewModel: LiveCaptionViewModel
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("שם", text: $name)
            }
            .navigationTitle("מי זה?")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("שמור") {
                        viewModel.nameSpeaker(of: segment, name: name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
            }
        }
    }
}
