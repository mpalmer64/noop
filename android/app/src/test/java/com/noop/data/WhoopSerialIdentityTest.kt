package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift WhoopSerialIdentityTests. The REFUSALS matter more than the composition: adoption
 * migrates every device-scoped row onto the id this returns, so a junk serial must yield null and leave
 * the strap on its existing id rather than move a history onto a garbage key (#1303).
 */
class WhoopSerialIdentityTest {

    @Test fun composesTheSerialId() {
        assertEquals("whoop-5AG12345678", WhoopSerialIdentity.adoptedId("5AG12345678"))
    }

    @Test fun upperCasesSoOneStrapCannotBecomeTwoIds() {
        assertEquals(
            WhoopSerialIdentity.adoptedId("5ag12345678"),
            WhoopSerialIdentity.adoptedId("5AG12345678"),
        )
    }

    @Test fun trimsSurroundingWhitespaceFromTheGattString() {
        assertEquals("whoop-5AG12345678", WhoopSerialIdentity.adoptedId("  5AG12345678\n"))
    }

    @Test fun refusesBlankOrMissing() {
        assertNull(WhoopSerialIdentity.adoptedId(null))
        assertNull(WhoopSerialIdentity.adoptedId(""))
        assertNull(WhoopSerialIdentity.adoptedId("   \n "))
    }

    @Test fun refusesATruncatedRead() {
        // A partial GATT response must not become an id: it would collide across straps.
        assertNull(WhoopSerialIdentity.adoptedId("5AG"))
    }

    @Test fun refusesADescriptiveStringThatIsNotASerial() {
        // Some peripherals answer DIS with prose. Never let that become a device id.
        assertNull(WhoopSerialIdentity.adoptedId("Not Available"))
        assertNull(WhoopSerialIdentity.adoptedId("serial#1234"))
    }

    @Test fun alreadyAdoptedIsTheReconnectEarlyOut() {
        assertTrue(WhoopSerialIdentity.isAlreadyAdopted("whoop-5AG12345678", "5AG12345678"))
        assertFalse(WhoopSerialIdentity.isAlreadyAdopted("whoop-ABCDEF-0123", "5AG12345678"))
        // An unusable serial is never "already adopted" — otherwise a junk read would silently
        // suppress a later good one.
        assertFalse(WhoopSerialIdentity.isAlreadyAdopted("whoop-5AG12345678", "  "))
    }

    @Test fun logSafeNeverLeaksTheFullSerial() {
        assertEquals("5AG…", WhoopSerialIdentity.logSafe("5AG12345678"))
        assertEquals("?", WhoopSerialIdentity.logSafe(null))
        assertFalse(WhoopSerialIdentity.logSafe("5AG12345678").contains("12345678"))
    }
}
