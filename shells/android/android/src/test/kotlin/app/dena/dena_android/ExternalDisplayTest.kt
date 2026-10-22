// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/external-display.md (Acceptance tests)
package app.dena.dena_android

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class ExternalDisplayTest {
    @Test
    fun routerPrefersTheExternalSurfaceAndFallsBack() {
        val sent = mutableListOf<String?>()
        val r = SurfaceRouter<String> { sent.add(it) }
        r.setPhone("phone")
        r.setExternal("tv")
        r.setPhone("phone2") // hidden behind the TV: nothing sent
        r.setExternal(null)
        r.setPhone(null)
        r.setPhone(null) // unchanged: nothing sent
        assertEquals(listOf("phone", "tv", "phone2", null), sent)
    }

    @Test
    fun fitAspectLetterboxesAndPillarboxes() {
        // 4:3 on 1920x1080: pillarbox, full height.
        assertContentEquals(intArrayOf(240, 0, 1440, 1080), fitAspect(1920, 1080, 4.0 / 3.0))
        // 16:9 on a 4:3 display: letterbox, full width.
        assertContentEquals(intArrayOf(0, 60, 1024, 576), fitAspect(1024, 696, 16.0 / 9.0))
        assertContentEquals(intArrayOf(0, 0, 0, 0), fitAspect(0, 0, 1.0))
    }
}
