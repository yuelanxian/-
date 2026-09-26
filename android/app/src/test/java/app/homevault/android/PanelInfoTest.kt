package app.homevault.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PanelInfoTest {
    // Byte-exact output of the panel's handleInfo (Go encoding/json, SetEscapeHTML(true)).
    private val panel = "{\"app\":\"homevault-panel\",\"login\":\"nextcloud-login-flow-v2\"," +
        "\"name\":\"HomeVault 管理面板\",\"nextcloud_url\":\"https://192.168.1.10:8444\"," +
        "\"version\":\"1.0.0\\u003c\\u0026\\u003e\\\"q\\\"\"}\n"

    @Test
    fun recognisesThePanel() {
        val info = PanelInfo.parse(panel)
        assertEquals("1.0.0<&>\"q\"", info?.version)
        assertEquals("https://192.168.1.10:8444", info?.nextcloudUrl)
        val spaced = PanelInfo.parse("{ \"app\" : \"homevault-panel\" }")
        assertEquals(PanelInfo(null, null), spaced)
    }

    @Test
    fun rejectsEverythingElse() {
        assertNull(PanelInfo.parse(""))
        assertNull(PanelInfo.parse("<!DOCTYPE html><html>wg-easy</html>"))
        assertNull(PanelInfo.parse("{\"app\":\"homevault-panelx\"}"))
        assertNull(PanelInfo.parse("{\"app\":1}"))
        assertNull(PanelInfo.parse("{\"error\":\"请先登录\"}"))
        // malformed escape
        assertNull(PanelInfo.parse("{\"app\":\"homevault-\\x\"}"))
        assertNull(PanelInfo.stringField("{\"k\":\"\\u12g4\"}", "k"))
    }

    @Test
    fun nextcloudStatus() {
        val status = "{\"installed\":true,\"maintenance\":false,\"needsDbUpgrade\":false," +
            "\"version\":\"34.0.4.1\",\"versionstring\":\"34.0.4\",\"edition\":\"\"," +
            "\"productname\":\"Nextcloud\",\"extendedSupport\":false}"
        assertTrue(PanelInfo.isNextcloudStatus(status))
        assertFalse(PanelInfo.isNextcloudStatus(panel))
        assertNull(PanelInfo.parse(status))
    }

    @Test
    fun longVersionIsCut() {
        val info = PanelInfo.parse("{\"app\":\"homevault-panel\",\"version\":\"" + "9".repeat(100) + "\"}")
        assertEquals(40, info?.version?.length)
    }
}
