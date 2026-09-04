import Foundation

/// Display units. Stored under NOOP's own `units.system` key so the two apps agree if both are installed;
/// Vital defaults to imperial when the key is unset. Conversions come from NOOP's `UnitFormatter`
/// (compiled in), so every number matches what NOOP would print.
enum VitalUnits {
    static var system: UnitSystem {
        get {
            UserDefaults.standard.string(forKey: UnitPrefs.systemKey).flatMap(UnitSystem.init(rawValue:)) ?? .imperial
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: UnitPrefs.systemKey) }
    }

    static var isImperial: Bool { system == .imperial }
    static var temperature: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: system,
                                     override: UserDefaults.standard.string(forKey: UnitPrefs.temperatureKey) ?? "")
    }

    // MARK: Display

    static func weight(kg: Double) -> String { UnitFormatter.massFromKilograms(kg, system: system) }
    static var weightUnit: String { UnitFormatter.massUnit(system) }

    static func height(cm: Double) -> String { UnitFormatter.heightFromCentimeters(cm, system: system) }

    static func distance(meters: Double) -> String { UnitFormatter.distanceFromMeters(meters, system: system) }
    static var distanceUnit: String { UnitFormatter.distanceUnit(system) }

    /// Absolute temperature (a WHOOP-export skin temp is stored absolute).
    static func temperature(celsius: Double) -> String {
        UnitFormatter.temperatureFromCelsius(celsius, unit: temperature)
    }
    /// A deviation from baseline (NOOP's on-device skin temp).
    static func temperatureDelta(celsius: Double) -> String {
        UnitFormatter.temperatureDeltaFromCelsius(celsius, unit: temperature)
    }
    static var temperatureUnit: String { UnitFormatter.temperatureUnit(temperature) }

    // MARK: Editing helpers (profile fields)

    static func kgFromDisplay(_ value: Double) -> Double {
        isImperial ? value / UnitFormatter.poundsPerKilogram : value
    }
    static func displayFromKg(_ kg: Double) -> Double {
        isImperial ? UnitFormatter.kgToPounds(kg) : kg
    }
    static func cm(feet: Int, inches: Int) -> Double {
        Double(feet * 12 + inches) * UnitFormatter.centimetersPerInch
    }
    static func feetInches(cm: Double) -> (feet: Int, inches: Int) { UnitFormatter.cmToFeetInches(cm) }
}
