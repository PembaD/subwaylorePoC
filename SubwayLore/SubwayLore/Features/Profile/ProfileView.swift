import SwiftUI

struct ProfileView: View {
    @ObservedObject var model: NearbySessionViewModel
    let isInitialSetup: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var firstName: String
    @State private var lastName: String
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var focusedField: NameField?

    private enum NameField: Hashable {
        case first, last
    }

    init(model: NearbySessionViewModel, isInitialSetup: Bool = false) {
        self.model = model
        self.isInitialSetup = isInitialSetup
        _firstName = State(initialValue: model.identity.firstName ?? "")
        _lastName = State(initialValue: model.identity.lastName ?? "")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.loreInk.ignoresSafeArea()

            RadialGradient(
                colors: [Color.loreGreen.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 300
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heading
                    nameFields

                    Label("Your name is visible to nearby riders.", systemImage: "person.2.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)

                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.loreOrange)
                    }

                    actions
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .tint(.loreGreen)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.loreGreen)
                    .frame(width: 44, height: 44)
                    .background(Color.loreGreen.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))

                Text(isInitialSetup ? "MEET YOUR CAR" : "YOUR PROFILE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(Color.loreGreen)
            }

            Text(isInitialSetup ? "What’s your name?" : "Make yourself known.")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)

            Text("Give nearby riders a name to say hello to.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var nameFields: some View {
        VStack(spacing: 14) {
            nameField("First name", text: $firstName, field: .first)
            nameField("Last name", text: $lastName, field: .last)
        }
        .disabled(isSaving)
    }

    private func nameField(_ title: String, text: Binding<String>, field: NameField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))

            TextField(title, text: text)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .textContentType(field == .first ? .givenName : .familyName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(field == .first ? .next : .done)
                .focused($focusedField, equals: field)
                .padding(16)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            focusedField == field ? Color.loreGreen.opacity(0.7) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                }
                .onSubmit {
                    if field == .first {
                        focusedField = .last
                    } else if canSave {
                        save()
                    }
                }
        }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            Button(action: save) {
                HStack(spacing: 10) {
                    if isSaving {
                        ProgressView().tint(Color.loreInk)
                    }
                    Text(isSaving ? "Saving…" : "Save profile")
                    if !isSaving {
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                }
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.loreInk)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Color.loreGreen.opacity(canSave ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 17))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)

            Button(isInitialSetup ? "Not now" : "Cancel") { dismiss() }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(isSaving)
        }
    }

    private var canSave: Bool {
        !isSaving
            && !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        focusedField = nil
        isSaving = true
        Task {
            do {
                try await model.saveProfile(firstName: firstName, lastName: lastName)
                dismiss()
            } catch {
                saveError = "Your profile could not be saved. Please try again."
            }
            isSaving = false
        }
    }
}
