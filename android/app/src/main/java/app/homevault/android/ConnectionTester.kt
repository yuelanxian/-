package app.homevault.android

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.security.cert.CertificateExpiredException
import java.security.cert.CertificateNotYetValidException
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

/**
 * "测试连接": HTTPS requests to the panel with the app's normal trust rules
 * (network_security_config: system + user CAs). Never bypasses certificate checks.
 * Asks the public `GET /api/info` so that only a real HomeVault panel counts as success
 * (a wg-easy page on 8443 or Nextcloud on 443 has a valid certificate too).
 * Blocking; call it off the main thread.
 */
object ConnectionTester {
    sealed class Outcome {
        data class Panel(val info: PanelInfo) : Outcome()
        object Nextcloud : Outcome()
        data class NotPanel(val httpCode: Int) : Outcome()
        data class ServerError(val httpCode: Int) : Outcome()
        object CertUntrusted : Outcome()
        object CertDate : Outcome()
        object CertMismatch : Outcome()
        data class TlsFailed(val message: String) : Outcome()
        object HostUnknown : Outcome()
        object Timeout : Outcome()
        object Refused : Outcome()
        object Closed : Outcome()
        data class Failed(val message: String) : Outcome()
    }

    private const val MAX_BODY = 64 * 1024

    private class Response(val code: Int, val body: String, val headers: Map<String?, List<String>>)

    fun test(panelUrl: String): Outcome = try {
        val info = get(UrlRules.panelInfoUrl(panelUrl))
        val panel = if (info.code == 200) PanelInfo.parse(info.body) else null
        when {
            panel != null -> Outcome.Panel(panel)
            info.code in 500..599 -> Outcome.ServerError(info.code)
            hasNextcloudCookies(info.headers) || isNextcloud(panelUrl) -> Outcome.Nextcloud
            else -> Outcome.NotPanel(info.code)
        }
    } catch (e: SSLPeerUnverifiedException) {
        Outcome.CertMismatch
    } catch (e: SSLHandshakeException) {
        when {
            hasCause(e, CertificateExpiredException::class.java) ||
                hasCause(e, CertificateNotYetValidException::class.java) -> Outcome.CertDate
            hasCause(e, java.security.cert.CertificateException::class.java) -> Outcome.CertUntrusted
            // No usable certificate for this address, not an HTTPS port, protocol error …
            else -> Outcome.TlsFailed(describe(e))
        }
    } catch (e: SSLException) {
        Outcome.TlsFailed(describe(e))
    } catch (e: UnknownHostException) {
        Outcome.HostUnknown
    } catch (e: SocketTimeoutException) {
        Outcome.Timeout
    } catch (e: ConnectException) {
        Outcome.Refused
    } catch (e: NoRouteToHostException) {
        Outcome.Refused
    } catch (e: EOFException) {
        Outcome.Closed
    } catch (e: IOException) {
        // Connection closed without an answer, e.g. Caddy's IP guard ("abort"): OkHttp on Android says
        // "unexpected end of stream", the JDK "Unexpected end of file from server".
        val message = e.message ?: ""
        if (message.contains("end of stream", ignoreCase = true) || message.contains("end of file", ignoreCase = true)) {
            Outcome.Closed
        } else {
            Outcome.Failed(describe(e))
        }
    } catch (e: RuntimeException) {
        Outcome.Failed(describe(e))
    }

    private fun get(url: String): Response {
        val connection = URL(url).openConnection() as HttpsURLConnection
        try {
            connection.connectTimeout = 8_000
            connection.readTimeout = 10_000
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", "HomeVaultApp/${BuildConfig.VERSION_NAME} (connection-test)")
            val code = connection.responseCode
            val stream = if (code < 400) connection.inputStream else connection.errorStream
            val body = stream?.use { readLimited(it) } ?: ""
            return Response(code, body, connection.headerFields ?: emptyMap())
        } finally {
            connection.disconnect()
        }
    }

    private fun readLimited(input: InputStream): String {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (out.size() < MAX_BODY) {
            val n = input.read(buffer, 0, minOf(buffer.size, MAX_BODY - out.size()))
            if (n < 0) break
            out.write(buffer, 0, n)
        }
        return String(out.toByteArray(), Charsets.UTF_8)
    }

    /** Nextcloud's public status.php; any failure simply means "not recognised". */
    private fun isNextcloud(panelUrl: String): Boolean = try {
        val status = get(UrlRules.nextcloudStatusUrl(panelUrl))
        status.code == 200 && PanelInfo.isNextcloudStatus(status.body)
    } catch (e: IOException) {
        false
    } catch (e: RuntimeException) {
        false
    }

    /** Nextcloud sets its nc_sameSiteCookie* / oc_sessionPassphrase cookies on every page. */
    private fun hasNextcloudCookies(headers: Map<String?, List<String>>): Boolean =
        headers.entries.any { (name, values) ->
            name != null && name.equals("Set-Cookie", ignoreCase = true) &&
                values.any { it.startsWith("nc_sameSiteCookie") || it.startsWith("oc_sessionPassphrase") }
        }

    private fun hasCause(error: Throwable, type: Class<out Throwable>): Boolean {
        var current: Throwable? = error
        var depth = 0
        while (current != null && depth < 10) {
            if (type.isInstance(current)) return true
            current = current.cause
            depth++
        }
        return false
    }

    private fun describe(e: Throwable): String = e.message?.takeIf { it.isNotBlank() } ?: e.javaClass.simpleName
}
