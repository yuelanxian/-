package app.homevault.android

/**
 * The panel's public `GET /api/info` answer (panel/INTEGRATION.md §8), used by "测试连接" to confirm that
 * an address really is the HomeVault panel. Pure JVM code (no org.json) so it is covered by unit tests.
 */
data class PanelInfo(val version: String?, val nextcloudUrl: String?) {
    companion object {
        const val APP_ID = "homevault-panel"

        /** Returns null unless [json] is a HomeVault panel /api/info response. */
        fun parse(json: String): PanelInfo? {
            if (stringField(json, "app") != APP_ID) return null
            return PanelInfo(
                version = stringField(json, "version")?.trim()?.takeIf { it.isNotEmpty() }?.take(40),
                nextcloudUrl = stringField(json, "nextcloud_url")?.trim()?.takeIf { it.isNotEmpty() },
            )
        }

        /** Nextcloud's public /status.php answer ({"installed":true,…,"productname":"Nextcloud"}). */
        fun isNextcloudStatus(json: String): Boolean =
            stringField(json, "versionstring") != null && stringField(json, "productname") != null

        /** First `"key": "string"` pair in a flat JSON object; null if missing, not a string or malformed. */
        internal fun stringField(json: String, key: String): String? {
            val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"").find(json)
                ?: return null
            return unescape(match.groupValues[1])
        }

        private fun unescape(s: String): String? {
            val out = StringBuilder(s.length)
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c != '\\') {
                    out.append(c)
                    i++
                    continue
                }
                if (i + 1 >= s.length) return null
                when (val e = s[i + 1]) {
                    '"', '\\', '/' -> out.append(e)
                    'b' -> out.append('\b')
                    'f' -> out.append('\u000C')
                    'n' -> out.append('\n')
                    'r' -> out.append('\r')
                    't' -> out.append('\t')
                    'u' -> {
                        if (i + 6 > s.length) return null
                        val hex = s.substring(i + 2, i + 6)
                        if (!hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
                        out.append(hex.toInt(16).toChar())
                        i += 6
                        continue
                    }
                    else -> return null
                }
                i += 2
            }
            return out.toString()
        }
    }
}
