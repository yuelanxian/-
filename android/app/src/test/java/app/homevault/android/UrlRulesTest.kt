package app.homevault.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UrlRulesTest {
    private fun ok(input: String): UrlRules.Parsed.Ok {
        val parsed = UrlRules.parsePanelUrl(input)
        assertTrue("expected Ok for '$input' but was $parsed", parsed is UrlRules.Parsed.Ok)
        return parsed as UrlRules.Parsed.Ok
    }

    private fun problem(input: String): UrlRules.Problem {
        val parsed = UrlRules.parsePanelUrl(input)
        assertTrue("expected Error for '$input' but was $parsed", parsed is UrlRules.Parsed.Error)
        return (parsed as UrlRules.Parsed.Error).problem
    }

    @Test
    fun bareHostGetsHttpsAndDefaultPanelPort() {
        val parsed = ok("192.168.1.10")
        assertEquals("https://192.168.1.10:9443", parsed.url)
        assertTrue(parsed.portAdded)
    }

    @Test
    fun explicitPortIsKept() {
        val parsed = ok(" 192.168.1.10:9443 ")
        assertEquals("https://192.168.1.10:9443", parsed.url)
        assertFalse(parsed.portAdded)
        assertEquals("https://nas.example.com:10443", ok("HTTPS://NAS.Example.com:10443/").url)
    }

    @Test
    fun port443IsOmittedAndPanelUrlIsReducedToItsOrigin() {
        assertEquals("https://nas.example.com", ok("https://nas.example.com:443").url)
        assertFalse(ok("https://nas.example.com:9443/").extraDropped)
        // The panel only lives at "/": paths, queries and copied "#/route" fragments are dropped.
        val withPath = ok("https://nas.example.com:9443/panel/")
        assertEquals("https://nas.example.com:9443", withPath.url)
        assertTrue(withPath.extraDropped)
        assertEquals("https://192.168.1.10:9443", ok("https://192.168.1.10:9443/#/storage").url)
        assertEquals("https://192.168.1.10:9443", ok("192.168.1.10:9443/?a=b").url)
        assertTrue(ok("192.168.1.10:9443/?a=b").extraDropped)
    }

    @Test
    fun schemeTyposAreRejected() {
        assertEquals(UrlRules.Problem.INVALID, problem("https:/192.168.1.10:9443"))
        assertEquals(UrlRules.Problem.INVALID, problem("https:192.168.1.10"))
        assertEquals(UrlRules.Problem.INVALID, problem("https//192.168.1.10:9443"))
        assertEquals(UrlRules.Problem.NOT_HTTPS, problem("http:192.168.1.10"))
        assertEquals(UrlRules.Problem.NOT_HTTPS, problem("javascript:alert(1)"))
        assertEquals(UrlRules.Problem.NOT_HTTPS, problem("file:///sdcard/x"))
        // host:port without a scheme is still fine
        assertEquals("https://nas.lan:9443", ok("nas.lan:9443").url)
    }

    @Test
    fun ipv6LiteralIsAccepted() {
        assertEquals("https://[fd00::10]:9443", ok("https://[fd00::10]:9443").url)
    }

    @Test
    fun onlyHttpsIsAccepted() {
        assertEquals(UrlRules.Problem.NOT_HTTPS, problem("http://192.168.1.10:9443"))
        assertEquals(UrlRules.Problem.NOT_HTTPS, problem("ftp://192.168.1.10"))
    }

    @Test
    fun invalidInputsAreRejected() {
        assertEquals(UrlRules.Problem.EMPTY, problem("   "))
        assertEquals(UrlRules.Problem.CREDENTIALS, problem("https://admin:secret@192.168.1.10:9443"))
        assertEquals(UrlRules.Problem.CREDENTIALS, problem("admin@192.168.1.10:9443"))
        assertEquals(UrlRules.Problem.BAD_PORT, problem("https://192.168.1.10:99999"))
        assertEquals(UrlRules.Problem.BAD_PORT, problem("https://192.168.1.10:0"))
        assertEquals(UrlRules.Problem.INVALID, problem("https://my host:9443"))
        assertEquals(UrlRules.Problem.INVALID, problem("https://bad_host.lan:9443"))
        assertEquals(UrlRules.Problem.INVALID, problem("https://"))
    }

    @Test
    fun nextcloudUrlDefaultsTo443() {
        val parsed = UrlRules.parseNextcloudUrl("nas.example.com") as UrlRules.Parsed.Ok
        assertEquals("https://nas.example.com", parsed.url)
        assertFalse(parsed.portAdded)
        assertEquals("https://192.168.1.10", UrlRules.defaultNextcloudUrl("https://192.168.1.10:9443"))
        assertEquals("https://[fd00::10]", UrlRules.defaultNextcloudUrl("https://[fd00::10]:9443"))
        // Nextcloud keeps its path but never a query / fragment (could carry tokens).
        val nc = UrlRules.parseNextcloudUrl("https://192.168.1.10:8444/apps/files/?dir=/x#y") as UrlRules.Parsed.Ok
        assertEquals("https://192.168.1.10:8444/apps/files", nc.url)
        assertTrue(nc.extraDropped)
    }

    @Test
    fun sameOriginRequiresSchemeHostAndPort() {
        val panel = "https://192.168.1.10:9443"
        assertTrue(UrlRules.isSameOrigin(panel, "https://192.168.1.10:9443/logs?file=a|b"))
        assertTrue(UrlRules.isSameOrigin("https://NAS.example.com", "https://nas.example.com:443/x"))
        assertFalse(UrlRules.isSameOrigin(panel, "https://192.168.1.10/index.php/login/v2/flow"))
        assertFalse(UrlRules.isSameOrigin(panel, "http://192.168.1.10:9443/"))
        assertFalse(UrlRules.isSameOrigin(panel, "https://192.168.1.100:9443/"))
        assertFalse(UrlRules.isSameOrigin(panel, "about:blank"))
        assertFalse(UrlRules.isSameOrigin(panel, "javascript:alert(1)"))
        assertFalse(UrlRules.isSameOrigin(panel, "data:text/html,hi"))
    }

    @Test
    fun userInfoCannotSpoofTheOrigin() {
        val panel = "https://192.168.1.10:9443"
        assertFalse(UrlRules.isSameOrigin(panel, "https://192.168.1.10:9443@evil.example/"))
        assertFalse(UrlRules.isSameOrigin(panel, "https://evil.example\\@192.168.1.10:9443/"))
        assertEquals("evil.example", UrlRules.origin("https://192.168.1.10:9443@evil.example/")?.host)
    }

    @Test
    fun originParsing() {
        assertEquals(UrlRules.Origin("https", "[fd00::10]", 9443), UrlRules.origin("https://[fd00::10]:9443/x"))
        assertEquals(UrlRules.Origin("http", "a", 80), UrlRules.origin("http://a/"))
        assertNull(UrlRules.origin("https://a:70000/"))
        assertNull(UrlRules.origin("mailto:a@b.c"))
    }

    @Test
    fun helpers() {
        assertEquals("192.168.1.10:9443", UrlRules.displayHost("https://192.168.1.10:9443"))
        assertEquals("nas.example.com", UrlRules.displayHost("https://nas.example.com"))
        assertEquals("https://192.168.1.10:9443/ca.crt", UrlRules.caCertificateUrl("https://192.168.1.10:9443/"))
        // Always at the root, even for an address saved with a path by an older version.
        assertEquals("https://192.168.1.10:9443/ca.crt", UrlRules.caCertificateUrl("https://192.168.1.10:9443/x/y"))
        assertEquals("https://nas.example.com/api/info", UrlRules.panelInfoUrl("https://NAS.example.com:443/a"))
        assertEquals("https://192.168.1.10/status.php", UrlRules.nextcloudStatusUrl("https://192.168.1.10"))
        assertEquals("https://[fd00::10]:9443", UrlRules.originUrl("https://[fd00::10]:9443/x?y"))
        assertNull(UrlRules.originUrl("about:blank"))
        assertTrue(UrlRules.isHttps("https://x"))
        assertFalse(UrlRules.isHttps("blob:https://x/1"))
    }
}
