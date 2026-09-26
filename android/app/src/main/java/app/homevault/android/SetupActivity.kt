package app.homevault.android

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toolbar

/** First-run setup and "更换服务器": panel URL (validated, https only) + optional Nextcloud URL. */
class SetupActivity : Activity() {
    private lateinit var config: ServerConfig
    private lateinit var panelInput: EditText
    private lateinit var nextcloudInput: EditText
    private lateinit var status: TextView
    private lateinit var testButton: Button

    private var lastCertReason: String? = null
    private var dialog: AlertDialog? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_setup)
        setActionBar(findViewById<Toolbar>(R.id.toolbar))
        actionBar?.title = getString(R.string.setup_title)
        SystemBars.applyInsets(findViewById(R.id.root), findViewById(R.id.app_bar))

        config = ServerConfig(this)
        panelInput = findViewById(R.id.panel_url)
        nextcloudInput = findViewById(R.id.nextcloud_url)
        status = findViewById(R.id.status)
        testButton = findViewById(R.id.test_button)

        if (savedInstanceState == null) {
            config.panelUrl?.let { panelInput.setText(it) }
            config.customNextcloudUrl?.let { nextcloudInput.setText(it) }
        }

        testButton.setOnClickListener { runConnectionTest() }
        findViewById<Button>(R.id.save_button).setOnClickListener { save() }
        findViewById<Button>(R.id.cert_help_button).setOnClickListener { showCertificateHelp() }
        findViewById<Button>(R.id.vpn_button).setOnClickListener { HomeVaultActions.openVpn(this) }
        nextcloudInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) {
                save()
                true
            } else {
                false
            }
        }
    }

    override fun onDestroy() {
        dialog?.dismiss()
        dialog = null
        super.onDestroy()
    }

    private fun problemText(problem: UrlRules.Problem): String = getString(
        when (problem) {
            UrlRules.Problem.EMPTY -> R.string.url_error_empty
            UrlRules.Problem.NOT_HTTPS -> R.string.url_error_not_https
            UrlRules.Problem.INVALID -> R.string.url_error_invalid
            UrlRules.Problem.NO_HOST -> R.string.url_error_no_host
            UrlRules.Problem.CREDENTIALS -> R.string.url_error_credentials
            UrlRules.Problem.QUERY -> R.string.url_error_query
            UrlRules.Problem.BAD_PORT -> R.string.url_error_port
        },
    )

    /** Validates the panel field; shows the error on the field and returns null when invalid. */
    private fun validatedPanelUrl(): String? {
        return when (val parsed = UrlRules.parsePanelUrl(panelInput.text.toString())) {
            is UrlRules.Parsed.Error -> {
                panelInput.error = problemText(parsed.problem)
                panelInput.requestFocus()
                null
            }
            is UrlRules.Parsed.Ok -> {
                panelInput.error = null
                if (panelInput.text.toString().trim() != parsed.url) {
                    panelInput.setText(parsed.url)
                    panelInput.setSelection(parsed.url.length)
                }
                if (parsed.portAdded) showStatus(getString(R.string.setup_port_added))
                parsed.url
            }
        }
    }

    /** Returns "" for an empty field (derive from the panel host), the normalized URL, or null if invalid. */
    private fun validatedNextcloudUrl(): String? {
        val text = nextcloudInput.text.toString().trim()
        if (text.isEmpty()) {
            nextcloudInput.error = null
            return ""
        }
        return when (val parsed = UrlRules.parseNextcloudUrl(text)) {
            is UrlRules.Parsed.Error -> {
                nextcloudInput.error = problemText(parsed.problem)
                nextcloudInput.requestFocus()
                null
            }
            is UrlRules.Parsed.Ok -> {
                nextcloudInput.error = null
                parsed.url
            }
        }
    }

    private fun save() {
        val panelUrl = validatedPanelUrl() ?: return
        val nextcloudUrl = validatedNextcloudUrl() ?: return
        config.save(panelUrl, nextcloudUrl.ifEmpty { null })
        if (!intent.getBooleanExtra(EXTRA_CHANGE_SERVER, false)) {
            startActivity(Intent(this, MainActivity::class.java))
        }
        // When changing servers, MainActivity notices the new address in onResume.
        finish()
    }

    private fun showStatus(text: String) {
        status.text = text
        status.visibility = View.VISIBLE
    }

    private fun runConnectionTest() {
        val panelUrl = validatedPanelUrl() ?: return
        testButton.isEnabled = false
        showStatus(getString(R.string.setup_testing, UrlRules.displayHost(panelUrl)))
        Thread {
            val outcome = ConnectionTester.test(panelUrl)
            runOnUiThread {
                if (!isFinishing && !isDestroyed) showOutcome(outcome)
            }
        }.start()
    }

    private fun showOutcome(outcome: ConnectionTester.Outcome) {
        testButton.isEnabled = true
        lastCertReason = when (outcome) {
            ConnectionTester.Outcome.CertUntrusted -> getString(R.string.cert_reason_untrusted)
            ConnectionTester.Outcome.CertDate -> getString(R.string.cert_reason_expired)
            ConnectionTester.Outcome.CertMismatch -> getString(R.string.cert_reason_mismatch)
            is ConnectionTester.Outcome.Reachable -> null
            else -> lastCertReason
        }
        val text = when (outcome) {
            is ConnectionTester.Outcome.Reachable ->
                if (outcome.looksLikeNextcloud) getString(R.string.test_ok_nextcloud)
                else getString(R.string.test_ok, outcome.httpCode)
            ConnectionTester.Outcome.CertUntrusted -> getString(R.string.test_cert_untrusted)
            ConnectionTester.Outcome.CertDate -> getString(R.string.cert_reason_expired)
            ConnectionTester.Outcome.CertMismatch -> getString(R.string.test_cert_mismatch)
            ConnectionTester.Outcome.HostUnknown -> getString(R.string.test_host_unknown)
            ConnectionTester.Outcome.Timeout -> getString(R.string.test_timeout)
            ConnectionTester.Outcome.Refused -> getString(R.string.test_refused)
            ConnectionTester.Outcome.Closed -> getString(R.string.test_closed)
            is ConnectionTester.Outcome.Failed -> getString(R.string.test_other, outcome.message)
        }
        showStatus(text)
    }

    private fun showCertificateHelp() {
        val parsed = UrlRules.parsePanelUrl(panelInput.text.toString())
        val panelUrl = (parsed as? UrlRules.Parsed.Ok)?.url
        if (panelUrl == null) {
            validatedPanelUrl()
            return
        }
        dialog?.dismiss()
        dialog = HomeVaultActions.showCertificateHelp(
            this,
            panelUrl,
            lastCertReason ?: getString(R.string.cert_reason_unknown),
            null,
        )
    }

    companion object {
        const val EXTRA_CHANGE_SERVER = "app.homevault.android.CHANGE_SERVER"
    }
}
