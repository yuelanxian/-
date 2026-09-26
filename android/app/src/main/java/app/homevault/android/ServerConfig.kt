package app.homevault.android

import android.content.Context

/** Server addresses remembered in SharedPreferences (private to the app, excluded from backups). */
class ServerConfig(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    val panelUrl: String?
        get() = prefs.getString(KEY_PANEL_URL, null)?.takeIf { it.isNotBlank() }

    /** Custom Nextcloud address, or null to derive it from the panel host. */
    val customNextcloudUrl: String?
        get() = prefs.getString(KEY_NEXTCLOUD_URL, null)?.takeIf { it.isNotBlank() }

    val nextcloudUrl: String?
        get() = customNextcloudUrl ?: panelUrl?.let { UrlRules.defaultNextcloudUrl(it) }

    fun save(panelUrl: String, customNextcloudUrl: String?) {
        prefs.edit()
            .putString(KEY_PANEL_URL, panelUrl)
            .putString(KEY_NEXTCLOUD_URL, customNextcloudUrl)
            .apply()
    }

    private companion object {
        const val PREFS = "homevault"
        const val KEY_PANEL_URL = "panel_url"
        const val KEY_NEXTCLOUD_URL = "nextcloud_url"
    }
}
