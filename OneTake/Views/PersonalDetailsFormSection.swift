import SwiftUI
import UIKit

enum HeightUnit: String, CaseIterable, Hashable {
    case feetInches = "ft / in"
    case centimetres = "cm"
}

enum RepresentationKind: String, CaseIterable, Hashable {
    case selfRepresented = "Self-represented"
    case agency = "Agency / Manager"
}

struct PersonalDetailsDraft: Equatable {
    var name: String = ""
    var email: String = ""
    var heightUnit: HeightUnit = .feetInches
    var feet: Int = 0
    var inches: Int = 0
    var centimetres: Int = 0
    var age: Int = 0
    var basedIn: String = ""
    var representationKind: RepresentationKind = .selfRepresented
    var agencyName: String = ""

    init() {}

    init(user: UserProfile?) {
        guard let user else { return }
        name = user.name
        email = user.email
        age = (5...99).contains(user.age) ? user.age : 0
        basedIn = user.basedIn
        parseHeight(user.height)

        let trimmedRep = user.representation.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRep.isEmpty || trimmedRep.caseInsensitiveCompare("Self-represented") == .orderedSame {
            representationKind = .selfRepresented
            agencyName = ""
        } else {
            representationKind = .agency
            agencyName = trimmedRep
        }
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedBasedIn: String {
        basedIn.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var formattedHeight: String {
        switch heightUnit {
        case .feetInches:
            guard feet > 0 else { return "" }
            return "\(feet)′ \(inches)″"
        case .centimetres:
            guard centimetres > 0 else { return "" }
            return "\(centimetres) cm"
        }
    }

    var ageString: String {
        age > 0 ? "\(age)" : ""
    }

    var resolvedRepresentation: String {
        switch representationKind {
        case .selfRepresented:
            return RepresentationKind.selfRepresented.rawValue
        case .agency:
            let trimmed = agencyName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? RepresentationKind.selfRepresented.rawValue : trimmed
        }
    }

    mutating func setHeightUnit(to newUnit: HeightUnit) {
        guard newUnit != heightUnit else { return }
        switch newUnit {
        case .centimetres:
            if feet > 0 {
                let totalInches = (feet * 12) + inches
                centimetres = min(240, max(90, Int((Double(totalInches) * 2.54).rounded())))
            } else {
                centimetres = 0
            }
        case .feetInches:
            if centimetres > 0 {
                let totalInches = max(36, Int((Double(centimetres) / 2.54).rounded()))
                feet = min(8, max(3, totalInches / 12))
                inches = totalInches % 12
            } else {
                feet = 0
                inches = 0
            }
        }
        heightUnit = newUnit
    }

    private mutating func parseHeight(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            heightUnit = .feetInches
            feet = 0
            inches = 0
            centimetres = 0
            return
        }

        let numbers = trimmed
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }

        let lowercased = trimmed.lowercased()
        let hasImperialMarkers = trimmed.contains("′")
            || trimmed.contains("'")
            || trimmed.contains("″")
            || trimmed.contains("\"")
            || lowercased.contains("ft")
            || lowercased.contains("in")

        if lowercased.contains("cm") || (!hasImperialMarkers && numbers.count == 1 && (numbers.first ?? 0) >= 90) {
            heightUnit = .centimetres
            if let value = numbers.first, value > 0 {
                centimetres = min(240, max(90, value))
            } else {
                centimetres = 0
            }
            feet = 0
            inches = 0
        } else {
            heightUnit = .feetInches
            if let parsedFeet = numbers.first, parsedFeet > 0 {
                feet = min(8, max(3, parsedFeet))
                inches = min(11, max(0, numbers.count > 1 ? numbers[1] : 0))
            } else {
                feet = 0
                inches = 0
            }
            centimetres = 0
        }
    }
}

struct PersonalDetailsFormRows: View {
    private enum FocusField: Hashable {
        case name
        case email
        case basedIn
        case agency
    }

    @Binding var draft: PersonalDetailsDraft
    var includeEmail: Bool = false

    @FocusState private var focusedField: FocusField?

    var body: some View {
        LabeledContent("Name") {
            TextField("Full Name", text: $draft.name)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: .name)
                .onSubmit {
                    focusedField = includeEmail ? .email : .basedIn
                }
        }

        if includeEmail {
            LabeledContent("Email") {
                TextField("Email", text: $draft.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .email)
                    .onSubmit {
                        focusedField = .basedIn
                    }
            }
        }

        LabeledContent("Height") {
            Picker("Unit", selection: Binding(
                get: { draft.heightUnit },
                set: { draft.setHeightUnit(to: $0) }
            )) {
                ForEach(HeightUnit.allCases, id: \.self) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 150)
        }

        if draft.heightUnit == .feetInches {
            HStack {
                Text("Feet & Inches")
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                Picker("Feet", selection: Binding(
                    get: { draft.feet },
                    set: { newValue in
                        draft.feet = newValue
                        if newValue == 0 {
                            draft.inches = 0
                        }
                    }
                )) {
                    Text("Not set").tag(0)
                    ForEach(3...8, id: \.self) { ft in
                        Text("\(ft) ft").tag(ft)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Picker("Inches", selection: $draft.inches) {
                    ForEach(0...11, id: \.self) { inch in
                        Text("\(inch) in").tag(inch)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(draft.feet == 0)
            }
        } else {
            Picker("Centimetres", selection: $draft.centimetres) {
                Text("Not set").tag(0)
                ForEach(90...240, id: \.self) { cm in
                    Text("\(cm) cm").tag(cm)
                }
            }
            .pickerStyle(.menu)
        }

        Picker("Age", selection: $draft.age) {
            Text("Not set").tag(0)
            ForEach(5...99, id: \.self) { value in
                Text("\(value)").tag(value)
            }
        }
        .pickerStyle(.menu)

        LabeledContent("Based In") {
            TextField("City", text: $draft.basedIn)
                .textContentType(.addressCity)
                .textInputAutocapitalization(.words)
                .submitLabel(draft.representationKind == .agency ? .next : .done)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: .basedIn)
                .onSubmit {
                    focusedField = draft.representationKind == .agency ? .agency : nil
                }
        }

        Picker("Representation", selection: $draft.representationKind) {
            ForEach(RepresentationKind.allCases, id: \.self) { kind in
                Text(kind.rawValue).tag(kind)
            }
        }
        .pickerStyle(.menu)

        if draft.representationKind == .agency {
            LabeledContent("Agency") {
                TextField("Agency or manager name", text: $draft.agencyName)
                    .textContentType(.organizationName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .agency)
                    .onSubmit {
                        focusedField = nil
                    }
            }
        }
    }
}

func dismissActiveKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
