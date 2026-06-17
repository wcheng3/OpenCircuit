import SwiftUI
import OpenRingKit

@MainActor
struct UserProfileSettingsView: View {
    @AppStorage("userProfile.age") private var age = 35
    @AppStorage("userProfile.weightKg") private var weightKg = 70.0
    @AppStorage("userProfile.heightCm") private var heightCm = 170.0
    @AppStorage("userProfile.sex") private var sexRaw = BiologicalSex.male.rawValue
    // Periodic auto-measure toggle — same UserDefaults key RingSession reads. Default true
    // (the user opted into periodic measuring); flip off to save ring battery.
    @AppStorage(RingSession.autoMeasureEnabledKey) private var autoMeasureEnabled = true

    // Sleep schedule (manual). Persisted as minutes-since-midnight so it's timezone-free
    // and feeds OpenRingKit's `SleepWindow` math directly. Keys/defaults are shared with
    // `ManualSleepSchedule` via `SleepScheduleDefaults`. Disabled by default: until the
    // user opts in, the night-temp window keeps using the detected sleep span.
    @AppStorage(SleepScheduleDefaults.enabled) private var sleepEnabled = false
    @AppStorage(SleepScheduleDefaults.bedMinutes)
    private var bedMinutes = SleepScheduleDefaults.defaultBedMinutes
    @AppStorage(SleepScheduleDefaults.wakeMinutes)
    private var wakeMinutes = SleepScheduleDefaults.defaultWakeMinutes

    // Health-alert thresholds (#73) + skin-temp/fever toggle (#85) + the shared quiet-hours (DND)
    // window. Keys/defaults shared with the notification engine via `HealthAlertDefaults`.
    @AppStorage(HealthAlertDefaults.highHREnabled) private var highHREnabled = true
    @AppStorage(HealthAlertDefaults.highHRBpm) private var highHRBpm = HealthAlertDefaults.defaultHighHRBpm
    @AppStorage(HealthAlertDefaults.lowSpO2Enabled) private var lowSpO2Enabled = true
    @AppStorage(HealthAlertDefaults.lowSpO2Percent) private var lowSpO2Percent = HealthAlertDefaults.defaultLowSpO2Percent
    @AppStorage(HealthAlertDefaults.elevatedHREnabled) private var elevatedHREnabled = true
    @AppStorage(HealthAlertDefaults.elevatedHRBpm) private var elevatedHRBpm = HealthAlertDefaults.defaultElevatedHRBpm
    @AppStorage(HealthAlertDefaults.tempFeverEnabled) private var tempFeverEnabled = true
    @AppStorage(HealthAlertDefaults.quietEnabled) private var quietEnabled = false
    @AppStorage(HealthAlertDefaults.quietStartMinutes) private var quietStart = HealthAlertDefaults.defaultQuietStart
    @AppStorage(HealthAlertDefaults.quietEndMinutes) private var quietEnd = HealthAlertDefaults.defaultQuietEnd

    var body: some View {
        Form {
            Section("Profile") {
                Stepper(value: $age, in: 13...120) {
                    LabeledContent("Age", value: "\(age)")
                }
                LabeledContent("Weight") {
                    HStack(spacing: 4) {
                        TextField("lb", value: weightLb, format: .number.precision(.fractionLength(0)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("lb").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Height") {
                    HStack(spacing: 4) {
                        TextField("ft", value: heightFeet, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 36)
                        Text("ft").foregroundStyle(.secondary)
                        TextField("in", value: heightInches, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 36)
                        Text("in").foregroundStyle(.secondary)
                    }
                }
                Picker("Sex", selection: $sexRaw) {
                    ForEach(BiologicalSex.allCases, id: \.rawValue) { sex in
                        Text(sex.rawValue.capitalized).tag(sex.rawValue)
                    }
                }
            }

            Section("Tracking") {
                Toggle("Auto-measure HR & SpO₂", isOn: $autoMeasureEnabled)
                Text("While connected, the ring re-measures heart rate (~every 10 min) and "
                     + "blood oxygen on its own, so the dashboard stays fresh — like the "
                     + "official app. Uses more ring battery; turn off to measure only on tap.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sleep schedule") {
                Toggle("Use manual sleep schedule", isOn: $sleepEnabled)
                if sleepEnabled {
                    DatePicker("Bedtime", selection: bedTimeBinding,
                               displayedComponents: .hourAndMinute)
                    DatePicker("Wake", selection: wakeTimeBinding,
                               displayedComponents: .hourAndMinute)
                }
                Text("Bounds the overnight skin-temp window. When Apple Health is "
                     + "authorized, your iOS Sleep schedule is used instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Health alerts") {
                Toggle("High heart rate", isOn: $highHREnabled)
                if highHREnabled {
                    Stepper(value: $highHRBpm, in: 80...200, step: 5) {
                        LabeledContent("Notify above", value: "\(highHRBpm) bpm")
                    }
                }
                Toggle("Low blood oxygen", isOn: $lowSpO2Enabled)
                if lowSpO2Enabled {
                    Stepper(value: $lowSpO2Percent, in: 80...99) {
                        LabeledContent("Notify below", value: "\(lowSpO2Percent)%")
                    }
                }
                Toggle("Elevated HR while inactive", isOn: $elevatedHREnabled)
                if elevatedHREnabled {
                    Stepper(value: $elevatedHRBpm, in: 80...160, step: 5) {
                        LabeledContent("Sustained above", value: "\(elevatedHRBpm) bpm")
                    }
                    Text("Notifies if heart rate stays above this for 10 minutes while inactive. "
                         + "Sharpens once activity detection lands.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Skin-temp & fever alerts", isOn: $tempFeverEnabled)
                Text("Note: OpenRingConn is not a medical device. These reminders are based on ring "
                     + "sensor data only and are not a diagnosis. If you feel unwell, consult a "
                     + "qualified medical professional.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Quiet hours") {
                Toggle("Mute alerts overnight", isOn: $quietEnabled)
                if quietEnabled {
                    DatePicker("From", selection: timeBinding($quietStart),
                               displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: timeBinding($quietEnd),
                               displayedComponents: .hourAndMinute)
                }
                Text("Health alerts are held during this window (delivered once it ends if still "
                     + "relevant).")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .navigationTitle("User Profile")
    }

    // MARK: Imperial display over metric storage
    // Storage stays kg/cm (OpenRingKit's BMR math expects metric); these bindings present
    // and edit it in lb / ft+in, converting on the way through.

    private static let lbPerKg = 2.2046226218
    private static let cmPerIn = 2.54

    private var weightLb: Binding<Double> {
        Binding(get: { weightKg * Self.lbPerKg },
                set: { weightKg = max($0, 0) / Self.lbPerKg })
    }

    /// Total height in whole inches (rounded), the basis for the ft/in split.
    private var totalInches: Int { Int((heightCm / Self.cmPerIn).rounded()) }

    private var heightFeet: Binding<Int> {
        Binding(get: { totalInches / 12 },
                set: { newFeet in
                    let inches = totalInches % 12
                    heightCm = Double(max(newFeet, 0) * 12 + inches) * Self.cmPerIn
                })
    }

    private var heightInches: Binding<Int> {
        Binding(get: { totalInches % 12 },
                set: { newInches in
                    let feet = totalInches / 12
                    heightCm = Double(feet * 12 + min(max(newInches, 0), 11)) * Self.cmPerIn
                })
    }

    // MARK: Sleep-schedule bindings (minutes-since-midnight <-> Date for DatePicker)

    private var bedTimeBinding: Binding<Date> { timeBinding($bedMinutes) }
    private var wakeTimeBinding: Binding<Date> { timeBinding($wakeMinutes) }

    /// Bridges an `Int` minutes-since-midnight store to a `Date` an `.hourAndMinute`
    /// `DatePicker` can edit (anchored to today; only the time component is used).
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        let cal = Calendar.current
        return Binding(
            get: {
                cal.startOfDay(for: Date())
                    .addingTimeInterval(TimeInterval(minutes.wrappedValue * 60))
            },
            set: { newValue in
                let c = cal.dateComponents([.hour, .minute], from: newValue)
                minutes.wrappedValue = SleepWindow.minutes(hour: c.hour ?? 0, minute: c.minute ?? 0)
            }
        )
    }
}
