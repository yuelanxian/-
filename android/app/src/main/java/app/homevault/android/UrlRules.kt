package app.homevault.android

import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/**
 * URL rules of the app. Pure JVM code (no Android APIs) so it is covered by local unit tests.
 */
object UrlRules {
    /** Default port of the HomeVault management panel (HV_PANEL_PORT). */
    const val DEFAULT_PANEL_PORT = 9443

    enum class Problem { EMPTY, NOT_HTTPS, INVALID, NO_HOST, CREDENTIALS, QUERY, BAD_PORT }

    sealed class Parsed {
        /** [url] is normalized: https, lower-case host, no default port, no trailing slash. */
        data class Ok(val url: String, val portAdded: Boolean) : Parsed()
        data class Error(val problem: Problem) : Parsed()
    }

    data class Origin(val scheme: String, val host: String, val port: Int)

    /** Validates user input for the panel address; a missing port becomes [DEFAULT_PANEL_PORT]. */
    fun parsePanelUrl(input: String): Parsed = parse(input, DEFAULT_PANEL_PORT)

    /** Validates user input for the optional Nextcloud address; a missing port means 443. */
    fun parseNextcloudUrl(input: String): Parsed = parse(input, null)

    private fun parse(input: String, defaultPort: Int?): Parsed {
        var text = input.trim()
        if (text.isEmpty()) return Parsed.Error(Problem.EMPTY)
        val lower = text.lowercase(Locale.ROOT)
        if (!lower.startsWith("https://")) {
            if (lower.contains("://")) return Parsed.Error(Problem.NOT_HTTPS)
            text = "https://$text"
        }
        val uri = try {
            URI(text)
        } catch (e: URISyntaxException) {
            return Parsed.Error(Problem.INVALID)
        }
        if (!"https".equals(uri.scheme, ignoreCase = true)) return Parsed.Error(Problem.NOT_HTTPS)
        if (uri.rawUserInfo != null) return Parsed.Error(Problem.CREDENTIALS)
        if (uri.rawQuery != null || uri.rawFragment != null) return Parsed.Error(Problem.QUERY)
        val host = uri.host
        if (host.isNullOrEmpty()) {
            // java.net.URI falls back to a registry-based authority for invalid host names.
            return Parsed.Error(if (uri.rawAuthority.isNullOrEmpty()) Problem.NO_HOST else Problem.INVALID)
        }
        val explicitPort = uri.port
        if (explicitPort == 0 || explicitPort > 65535) return Parsed.Error(Problem.BAD_PORT)
        val port = if (explicitPort == -1) defaultPort ?: 443 else explicitPort
        val path = (uri.rawPath ?: "").trimEnd('/')
        val portPart = if (port == 443) "" else ":$port"
        val url = "https://" + host.lowercase(Locale.ROOT) + portPart + path
        return Parsed.Ok(url, portAdded = explicitPort == -1 && defaultPort != null)
    }

    private val SCHEME_AUTHORITY = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#\\\\]*)")

    /**
     * Lenient origin parser for URLs coming from the WebView (already canonicalized by Chromium).
     * Returns null for URLs without an authority (about:, data:, blob:, javascript:, mailto: ...).
     */
    fun origin(url: String): Origin? {
        val match = SCHEME_AUTHORITY.find(url.trim()) ?: return null
        val scheme = match.groupValues[1].lowercase(Locale.ROOT)
        var authority = match.groupValues[2]
        val at = authority.lastIndexOf('@')
        if (at >= 0) authority = authority.substring(at + 1)
        val host: String
        val portText: String?
        if (authority.startsWith("[")) {
            val end = authority.indexOf(']')
            if (end < 0) return null
            host = authority.substring(0, end + 1)
            val rest = authority.substring(end + 1)
            portText = when {
                rest.isEmpty() -> null
                rest.startsWith(":") -> rest.substring(1)
                else -> return null
            }
        } else {
            val colon = authority.lastIndexOf(':')
            if (colon >= 0) {
                host = authority.substring(0, colon)
                portText = authority.substring(colon + 1)
            } else {
                host = authority
                portText = null
            }
        }
        if (host.isEmpty()) return null
        val port = if (portText.isNullOrEmpty()) {
            defaultPort(scheme)
        } else {
            portText.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
        }
        return Origin(scheme, host.lowercase(Locale.ROOT), port)
    }

    fun isSameOrigin(a: String, b: String): Boolean {
        val first = origin(a) ?: return false
        return first == origin(b)
    }

    fun isHttps(url: String): Boolean = origin(url)?.scheme == "https"

    /** "host:port" for display (port omitted when it is 443). */
    fun displayHost(url: String): String {
        val o = origin(url) ?: return url
        return if (o.port == 443 || o.port == -1) o.host else "${o.host}:${o.port}"
    }

    /** Default Nextcloud web address: same host as the panel, https default port. */
    fun defaultNextcloudUrl(panelUrl: String): String? {
        val o = origin(panelUrl) ?: return null
        return "https://${o.host}"
    }

    /** The panel serves the HomeVault root CA certificate at /ca.crt. */
    fun caCertificateUrl(panelUrl: String): String = panelUrl.trimEnd('/') + "/ca.crt"

    private fun defaultPort(scheme: String): Int = when (scheme) {
        "https" -> 443
        "http" -> 80
        else -> -1
    }
}
