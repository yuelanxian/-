package app.homevault.android

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.net.http.SslError
import android.provider.Settings
import android.widget.Toast

/** Menu actions and help dialogs shared by MainActivity and SetupActivity. */
object HomeVaultActions {
    const val NEXTCLOUD_PACKAGE = "com.nextcloud.client"

    /** WG Tunnel first (auto-tunnel by Wi-Fi, follows DDNS changes), then the official app. */
    val VPN_PACKAGES = listOf("com.zaneschepke.wireguardautotunnel", "com.wireguard.android")

    private const val WG_TUNNEL_DOWNLOAD = "https://github.com/wgtunnel/android/releases/latest"
    private const val WIREGUARD_DOWNLOAD = "https://download.wireguard.com/android-client/"
    private const val NEXTCLOUD_DOWNLOAD = "https://github.com/nextcloud/android/releases/latest"

    fun toast(activity: Activity, text: CharSequence) {
        Toast.makeText(activity, text, Toast.LENGTH_LONG).show()
    }

    /** Opens a link outside the app (browser, mail, dialer). */
    fun openExternal(activity: Activity, url: String) {
        val uri = Uri.parse(url)
        val intent = Intent(Intent.ACTION_VIEW, uri)
        val scheme = uri.scheme?.lowercase()
        if (scheme == "http" || scheme == "https") intent.addCategory(Intent.CATEGORY_BROWSABLE)
        try {
            activity.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            toast(activity, activity.getString(R.string.no_app_for_link))
        }
    }

    private fun launchPackage(activity: Activity, packageName: String): Boolean {
        val intent = activity.packageManager.getLaunchIntentForPackage(packageName) ?: return false
        return try {
            activity.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    /** "VPN": WG Tunnel or WireGuard if installed, otherwise explain how to set it up. */
    fun openVpn(activity: Activity) {
        if (VPN_PACKAGES.any { launchPackage(activity, it) }) return
        AlertDialog.Builder(activity)
            .setTitle(R.string.vpn_missing_title)
            .setMessage(R.string.vpn_missing_message)
            .setPositiveButton(R.string.vpn_download_wgtunnel) { _, _ -> openExternal(activity, WG_TUNNEL_DOWNLOAD) }
            .setNeutralButton(R.string.vpn_download_wireguard) { _, _ -> openExternal(activity, WIREGUARD_DOWNLOAD) }
            .setNegativeButton(R.string.action_close, null)
            .show()
    }

    /** "文件": the Nextcloud app if installed, otherwise offer the Nextcloud web UI. */
    fun openFiles(activity: Activity, nextcloudUrl: String?) {
        if (launchPackage(activity, NEXTCLOUD_PACKAGE)) return
        val web = nextcloudUrl ?: ""
        val builder = AlertDialog.Builder(activity)
            .setTitle(R.string.nc_missing_title)
            .setMessage(activity.getString(R.string.nc_missing_message, web))
            .setNeutralButton(R.string.nc_download) { _, _ -> openExternal(activity, NEXTCLOUD_DOWNLOAD) }
            .setNegativeButton(R.string.action_close, null)
        if (web.isNotEmpty()) {
            builder.setPositiveButton(R.string.nc_open_web) { _, _ -> openExternal(activity, web) }
        }
        builder.show()
    }

    fun certificateReason(activity: Activity, error: SslError?): String = activity.getString(
        when (error?.primaryError) {
            null -> R.string.cert_reason_unknown
            SslError.SSL_UNTRUSTED -> R.string.cert_reason_untrusted
            SslError.SSL_IDMISMATCH -> R.string.cert_reason_mismatch
            SslError.SSL_EXPIRED -> R.string.cert_reason_expired
            SslError.SSL_NOTYETVALID -> R.string.cert_reason_not_yet_valid
            SslError.SSL_DATE_INVALID -> R.string.cert_reason_expired
            else -> R.string.cert_reason_other
        },
    )

    fun certificateIssuer(error: SslError?): String? {
        val issuer = error?.certificate?.issuedBy ?: return null
        return issuer.cName?.takeIf { it.isNotBlank() } ?: issuer.dName?.takeIf { it.isNotBlank() }
    }

    /**
     * Explains how to install the HomeVault root CA. The certificate error itself is never bypassed;
     * the CA is downloaded from <panel>/ca.crt in the external browser.
     */
    fun showCertificateHelp(activity: Activity, panelUrl: String, reason: String, issuer: String?): AlertDialog {
        val caUrl = UrlRules.caCertificateUrl(panelUrl)
        val message = activity.getString(
            R.string.cert_message,
            reason,
            issuer ?: activity.getString(R.string.cert_issuer_unknown),
            caUrl,
        )
        return AlertDialog.Builder(activity)
            .setTitle(R.string.cert_title)
            .setMessage(message)
            .setPositiveButton(R.string.cert_download) { _, _ -> openExternal(activity, caUrl) }
            .setNeutralButton(R.string.cert_open_settings) { _, _ -> openSecuritySettings(activity) }
            .setNegativeButton(R.string.action_close, null)
            .show()
    }

    private fun openSecuritySettings(activity: Activity) {
        for (action in listOf(Settings.ACTION_SECURITY_SETTINGS, Settings.ACTION_SETTINGS)) {
            try {
                activity.startActivity(Intent(action))
                return
            } catch (e: ActivityNotFoundException) {
                // try the next one
            }
        }
        toast(activity, activity.getString(R.string.no_app_for_link))
    }

    fun showAbout(activity: Activity, config: ServerConfig) {
        val message = activity.getString(
            R.string.about_message,
            BuildConfig.VERSION_NAME,
            BuildConfig.VERSION_CODE,
            config.panelUrl ?: "-",
            config.nextcloudUrl ?: "-",
        )
        AlertDialog.Builder(activity)
            .setTitle(R.string.about_title)
            .setMessage(message)
            .setPositiveButton(R.string.action_close, null)
            .show()
    }
}
