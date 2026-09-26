package app.homevault.android

import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.security.cert.CertificateExpiredException
import java.security.cert.CertificateNotYetValidException
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException

/**
 * "测试连接": one HTTPS request to the panel with the app's normal trust rules
 * (network_security_config: system + user CAs). Never bypasses certificate checks.
 * Blocking; call it off the main thread.
 */
object ConnectionTester {
    sealed class Outcome {
        data class Reachable(val httpCode: Int, val looksLikeNextcloud: Boolean) : Outcome()
        object CertUntrusted : Outcome()
        object CertDate : Outcome()
        object CertMismatch : Outcome()
        object HostUnknown : Outcome()
        object Timeout : Outcome()
        object Refused : Outcome()
        object Closed : Outcome()
        data class Failed(val message: String) : Outcome()
    }

    fun test(panelUrl: String): Outcome {
        var connection: HttpsURLConnection? = null
        return try {
            connection = URL(panelUrl.trimEnd('/') + "/").openConnection() as HttpsURLConnection
            connection.connectTimeout = 8_000
            connection.readTimeout = 10_000
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("User-Agent", "HomeVaultApp/${BuildConfig.VERSION_NAME} (connection-test)")
            val code = connection.responseCode
            Outcome.Reachable(code, looksLikeNextcloud(connection.headerFields))
        } catch (e: SSLPeerUnverifiedException) {
            Outcome.CertMismatch
        } catch (e: SSLHandshakeException) {
            when {
                hasCause(e, CertificateExpiredException::class.java) ||
                    hasCause(e, CertificateNotYetValidException::class.java) -> Outcome.CertDate
                hasCause(e, java.security.cert.CertificateException::class.java) -> Outcome.CertUntrusted
                else -> Outcome.Failed(describe(e))
            }
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
            if (e.message?.contains("end of stream", ignoreCase = true) == true) Outcome.Closed
            else Outcome.Failed(describe(e))
        } catch (e: RuntimeException) {
            Outcome.Failed(describe(e))
        } finally {
            connection?.disconnect()
        }
    }

    /** Nextcloud sets its nc_sameSiteCookie* / oc<instanceid> cookies on every page. */
    private fun looksLikeNextcloud(headers: Map<String?, List<String>>): Boolean =
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
