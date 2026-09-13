import SwiftUI
import OzenKit

struct SettingsView: View {
    @Bindable var viewModel: LiveCaptionViewModel
    @State private var showingEnrollment = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("מנוע תמלול") {
                    Picker("מנוע", selection: Binding(
                        get: { viewModel.settings.engine },
                        set: { viewModel.setEngine($0) }
                    )) {
                        ForEach(TranscriptionEngineKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("דוברים שמורים") {
                    ForEach(viewModel.settings.speakerProfiles) { profile in
                        Text(profile.name)
                    }
                    Button("הוספת דובר חדש") { showingEnrollment = true }
                }

                Section {
                    HStack {
                        Text("נוצר על ידי")
                        Spacer()
                        Text(viewModel.settings.creditLine)
                            .foregroundStyle(.secondary)
                    }
                    Link("קוד המקור בגיטהאב", destination: URL(string: "https://github.com/arbelonson-source/ozen")!)
                }
            }
            .navigationTitle("הגדרות")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סגור") { dismiss() }
                }
            }
            .sheet(isPresented: $showingEnrollment) {
                SpeakerEnrollmentView(viewModel: viewModel)
            }
        }
    }
}
