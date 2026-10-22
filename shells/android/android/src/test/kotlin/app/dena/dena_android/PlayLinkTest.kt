// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/shortcuts.md (Acceptance tests)
package app.dena.dena_android

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PlayLinkTest {
    private val sha = "0123456789abcdef0123456789ABCDEF01234567"

    @Test
    fun acceptsPlayLinksCaseInsensitively() {
        assertEquals(sha.lowercase(), PlayLink.parse("dena://play/$sha"))
        assertEquals(sha.lowercase(), PlayLink.parse("DENA://PLAY/$sha/"))
        assertEquals("dena://play/abc", PlayLink.of("abc"))
    }

    @Test
    fun rejectsEverythingElse() {
        assertNull(PlayLink.parse(null))
        assertNull(PlayLink.parse("dena://open/$sha"))
        assertNull(PlayLink.parse("https://play/$sha"))
        assertNull(PlayLink.parse("dena://play/${sha.dropLast(1)}"))
        assertNull(PlayLink.parse("dena://play/$sha/extra"))
        assertNull(PlayLink.parse("dena://play/${sha.dropLast(1)}g"))
    }
}
