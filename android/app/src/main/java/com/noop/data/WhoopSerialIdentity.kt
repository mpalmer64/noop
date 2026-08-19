package com.noop.data

/**
 * The stable WHOOP device id derived from the strap's own serial (#1303). Byte-parity twin of Swift
 * `WhoopSerialIdentity`.
 *
 * WHOOP strap identity is otherwise a TRANSIENT Bluetooth address/UUID: a re-pair or factory reset mints a
 * fresh one, so the same physical strap forks into a second registry row and orphans its history (#1193).
 * The ring path already solved this — `DeviceRegistry.adoptSerialIdentity` re-points a provisional id onto
 * a serial id and migrates every device-scoped row — and this is the WHOOP half of the same idea.
 *
 * Pure and store-free so both platforms can pin the composition and, more importantly, the REFUSALS: a
 * blank or implausible serial must yield null and leave the existing id alone. Adopting onto a junk id
 * would be worse than not adopting at all, because the migration moves every row onto it.
 */
object WhoopSerialIdentity {

    /**
     * The one place the WHOOP id namespace is spelled. The add-device flow mints `whoop-<address>` and the
     * registry classifies on the same prefix; a serial id joins the same namespace so every existing prefix
     * check keeps working unchanged.
     */
    const val ID_PREFIX = "whoop"

    /**
     * Shortest serial worth adopting. A 5.0/MG DIS serial is far longer; this only rejects a truncated or
     * placeholder read, which a partial GATT response can produce.
     */
    const val MIN_SERIAL_LENGTH = 6

    private val ALLOWED = ('A'..'Z').toSet() + ('0'..'9').toSet() + '-'

    /**
     * The `whoop-<serial>` id for a strap serial, or null when the serial cannot be trusted to identify it.
     *
     * Refuses blank/whitespace, anything under [MIN_SERIAL_LENGTH], and any serial carrying a character
     * outside `[A-Z0-9-]` after upper-casing — a DIS read that returns a descriptive string rather than a
     * serial should never become a device id. Upper-cased so the same strap read twice, in either case,
     * resolves to ONE id rather than two.
     */
    fun adoptedId(serial: String?): String? {
        val raw = serial?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val up = raw.uppercase()
        if (up.length < MIN_SERIAL_LENGTH) return null
        if (!up.all { it in ALLOWED }) return null
        return "$ID_PREFIX-$up"
    }

    /**
     * True when [id] is already the serial id for [serial] — the steady state on every reconnect after the
     * first adoption, and the cheap early-out that keeps re-adoption from doing database work per connect.
     */
    fun isAlreadyAdopted(id: String, serial: String?): Boolean {
        val target = adoptedId(serial) ?: return false
        return id == target
    }

    /**
     * What may be written to a SHAREABLE strap log. The serial identifies the device, so only its leading
     * characters are ever logged — the same rule `noteWhoop5VariantFromDis` already applies to the variant
     * line. Never log [adoptedId]'s result directly.
     */
    fun logSafe(serial: String?): String {
        val raw = serial?.trim().orEmpty()
        if (raw.isEmpty()) return "?"
        return raw.uppercase().take(3) + "…"
    }
}
