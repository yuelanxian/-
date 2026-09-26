package app.homevault.android

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.URLUtil
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toolbar
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import java.util.Locale

/** Full-screen WebView of the HomeVault management panel with native menu actions. */
class MainActivity : Activity() {
    private lateinit var config: ServerConfig
    private lateinit var webView: WebView
    private lateinit var progress: ProgressBar
    private lateinit var errorView: View
    private lateinit var errorMessage: TextView
    private lateinit var errorCertButton: Button

    private var panelUrl = ""
    private var webViewAlive = false
    private var mainFrameFailed = false
    private var clearHistoryAfterLoad = false
    private var certDialogShown = false
    /** onReceivedSslError already explained the current failure; keep that message. */
    private var certErrorShown = false
    private var lastSslError: SslError? = null
    private var dialog: AlertDialog? = null
    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private var backCallback: Any? = null
    private var backCallbackRegistered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        config = ServerConfig(this)
        val savedUrl = config.panelUrl
        if (savedUrl == null) {
            startActivity(Intent(this, SetupActivity::class.java))
            finish()
            return
        }
        panelUrl = savedUrl

        setContentView(R.layout.activity_main)
        setActionBar(findViewById<Toolbar>(R.id.toolbar))
        SystemBars.applyInsets(findViewById(R.id.root), findViewById(R.id.app_bar))

        webView = findViewById(R.id.webview)
        progress = findViewById(R.id.progress)
        errorView = findViewById(R.id.error_view)
        errorMessage = findViewById(R.id.error_message)
        errorCertButton = findViewById(R.id.error_cert)
        findViewById<Button>(R.id.error_retry).setOnClickListener { retry() }
        errorCertButton.setOnClickListener { showCertificateHelp() }
        findViewById<Button>(R.id.error_vpn).setOnClickListener { HomeVaultActions.openVpn(this) }
        findViewById<Button>(R.id.error_change_server).setOnClickListener { openSetup() }

        configureWebView()
        updateTitle()
        if (config.sessionUrl != panelUrl) {
            // Cookies / storage / cache still belong to another server (e.g. the server was changed and
            // the process was killed before this activity resumed): wipe them before the first load.
            resetWebSession { webView.loadUrl(panelUrl) }
            return
        }
        // Only restore a WebView state saved for this very server.
        val state = savedInstanceState?.takeIf { it.getString(STATE_PANEL_URL) == panelUrl }
        if (state == null || webView.restoreState(state) == null) {
            webView.loadUrl(panelUrl)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView() {
        webViewAlive = true
        // chrome://inspect for panel developers, debug builds only.
        if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
            // Lets the panel recognise the app (e.g. to hide its "download the app" hint).
            userAgentString = "$userAgentString HomeVaultApp/${BuildConfig.VERSION_NAME}"
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, false)
        }
        webView.webViewClient = PanelWebViewClient()
        webView.webChromeClient = PanelChromeClient()
        webView.setDownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
            startDownload(url, userAgent, contentDisposition, mimeType)
        }
    }

    private fun updateTitle() {
        actionBar?.title = getString(R.string.toolbar_title)
        actionBar?.subtitle = UrlRules.displayHost(panelUrl)
    }

    override fun onResume() {
        super.onResume()
        if (!webViewAlive) return
        webView.onResume()
        val savedUrl = config.panelUrl
        when {
            savedUrl == null -> {
                startActivity(Intent(this, SetupActivity::class.java))
                finish()
            }
            savedUrl != panelUrl -> switchServer(savedUrl)
            // Back from the VPN app / certificate settings: try again automatically.
            mainFrameFailed -> retry()
        }
    }

    override fun onPause() {
        if (webViewAlive) {
            webView.onPause()
            CookieManager.getInstance().flush()
        }
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (webViewAlive) {
            webView.saveState(outState)
            outState.putString(STATE_PANEL_URL, panelUrl)
        }
    }

    override fun onDestroy() {
        dialog?.dismiss()
        dialog = null
        fileCallback?.onReceiveValue(null)
        fileCallback = null
        destroyWebView()
        super.onDestroy()
    }

    private fun destroyWebView() {
        if (!webViewAlive) return
        webViewAlive = false
        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.destroy()
    }

    /** A different server was saved in SetupActivity: drop the old session completely. */
    private fun switchServer(newUrl: String) {
        panelUrl = newUrl
        updateTitle()
        hideError()
        webView.stopLoading()
        resetWebSession { webView.loadUrl(panelUrl) }
    }

    /**
     * Removes cookies, web storage, HTTP cache and history of the previous server, records that the
     * WebView now belongs to [panelUrl], then runs [then]. Cookies are removed asynchronously and are
     * not port-scoped, so nothing is loaded before the removal has finished.
     */
    private fun resetWebSession(then: () -> Unit) {
        val target = panelUrl
        certDialogShown = false
        lastSslError = null
        clearHistoryAfterLoad = true
        WebStorage.getInstance().deleteAllData()
        webView.clearCache(true)
        webView.clearHistory()
        val cookies = CookieManager.getInstance()
        cookies.removeAllCookies {
            cookies.flush()
            config.sessionUrl = target
            if (webViewAlive && target == panelUrl) then()
        }
    }

    private fun retry() {
        if (!webViewAlive) return
        hideError()
        val current = webView.url
        if (current.isNullOrEmpty() || !UrlRules.isSameOrigin(current, panelUrl)) {
            webView.loadUrl(panelUrl)
        } else {
            webView.reload()
        }
    }

    private fun refresh() {
        if (mainFrameFailed) retry() else if (webViewAlive) webView.reload()
    }

    private fun showError(message: String, certificateProblem: Boolean) {
        mainFrameFailed = true
        errorMessage.text = message
        errorCertButton.visibility = if (certificateProblem) View.VISIBLE else View.GONE
        errorView.visibility = View.VISIBLE
        progress.visibility = View.GONE
    }

    private fun hideError() {
        mainFrameFailed = false
        certErrorShown = false
        errorView.visibility = View.GONE
    }

    private fun showCertificateHelp() {
        dialog?.dismiss()
        dialog = HomeVaultActions.showCertificateHelp(
            this,
            panelUrl,
            HomeVaultActions.certificateReason(this, lastSslError),
            HomeVaultActions.certificateIssuer(lastSslError),
        )
    }

    private fun openSetup() {
        startActivity(Intent(this, SetupActivity::class.java).putExtra(SetupActivity.EXTRA_CHANGE_SERVER, true))
    }

    // ---- navigation policy -------------------------------------------------------------------

    /** Returns true when the WebView must NOT load [url] itself. */
    private fun handleNavigation(url: String, isMainFrame: Boolean): Boolean {
        if (UrlRules.isSameOrigin(url, panelUrl)) return false
        val scheme = Uri.parse(url).scheme?.lowercase(Locale.ROOT)
        when (scheme) {
            "about" -> return false
            "http", "https", "mailto", "tel" -> if (isMainFrame) HomeVaultActions.openExternal(this, url)
            else -> if (isMainFrame) HomeVaultActions.toast(this, getString(R.string.link_blocked, scheme ?: url))
        }
        return true
    }

    private fun errorText(errorCode: Int, description: CharSequence?): String {
        val host = UrlRules.displayHost(panelUrl)
        return when (errorCode) {
            WebViewClient.ERROR_HOST_LOOKUP -> getString(R.string.error_host_lookup, host)
            WebViewClient.ERROR_CONNECT,
            WebViewClient.ERROR_TIMEOUT,
            WebViewClient.ERROR_IO,
            -> getString(R.string.error_connect, host)
            // Certificate problems arrive in onReceivedSslError; this is a TLS failure without one
            // (not an HTTPS port, no certificate for this address, protocol error).
            WebViewClient.ERROR_FAILED_SSL_HANDSHAKE -> getString(R.string.error_tls, host)
            else -> getString(R.string.error_generic, description?.toString() ?: errorCode.toString())
        }
    }

    private inner class PanelWebViewClient : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            handleNavigation(request.url.toString(), request.isForMainFrame)

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
            progress.visibility = View.VISIBLE
        }

        override fun onPageFinished(view: WebView, url: String?) {
            progress.visibility = View.GONE
            if (clearHistoryAfterLoad) {
                clearHistoryAfterLoad = false
                view.clearHistory()
            }
            updateBackHandling()
        }

        override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) {
            updateBackHandling()
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (!request.isForMainFrame || certErrorShown) return
            val ssl = error.errorCode == ERROR_FAILED_SSL_HANDSHAKE
            showError(errorText(error.errorCode, error.description), ssl)
        }

        override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, errorResponse: WebResourceResponse) {
            if (request.isForMainFrame && errorResponse.statusCode >= 500) {
                showError(getString(R.string.error_http, errorResponse.statusCode), false)
            }
        }

        /** Never proceed on certificate errors: cancel, then explain how to install the HomeVault CA. */
        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            handler.cancel()
            if (!UrlRules.isSameOrigin(error.url, panelUrl)) return
            lastSslError = error
            showError(getString(R.string.error_ssl), true)
            certErrorShown = true
            if (!certDialogShown) {
                certDialogShown = true
                showCertificateHelp()
            }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            // The renderer crashed or was killed: this WebView is unusable, rebuild the activity.
            if (view === webView && webViewAlive) {
                HomeVaultActions.toast(this@MainActivity, getString(R.string.error_renderer_gone))
                destroyWebView()
                recreate()
            }
            return true
        }
    }

    private inner class PanelChromeClient : WebChromeClient() {
        override fun onProgressChanged(view: WebView, newProgress: Int) {
            progress.progress = newProgress
            progress.visibility = if (newProgress in 1..99 && !mainFrameFailed) View.VISIBLE else View.GONE
        }

        override fun onShowFileChooser(
            webView: WebView,
            filePathCallback: ValueCallback<Array<Uri>>,
            fileChooserParams: FileChooserParams,
        ): Boolean {
            fileCallback?.onReceiveValue(null)
            fileCallback = filePathCallback
            return try {
                startActivityForResult(fileChooserParams.createIntent(), REQUEST_FILE_CHOOSER)
                true
            } catch (e: ActivityNotFoundException) {
                fileCallback = null
                HomeVaultActions.toast(this@MainActivity, getString(R.string.file_chooser_failed))
                false
            }
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            request.deny()
        }

        override fun onGeolocationPermissionsShowPrompt(origin: String?, callback: GeolocationPermissions.Callback?) {
            callback?.invoke(origin, false, false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_FILE_CHOOSER) {
            fileCallback?.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(resultCode, data))
            fileCallback = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    // ---- downloads -----------------------------------------------------------------------------

    private fun startDownload(url: String, userAgent: String?, contentDisposition: String?, mimeType: String?) {
        if (!UrlRules.isHttps(url)) {
            HomeVaultActions.toast(this, getString(R.string.download_unsupported))
            return
        }
        val fileName = URLUtil.guessFileName(url, contentDisposition, mimeType)
        try {
            val request = DownloadManager.Request(Uri.parse(url))
                .setTitle(fileName)
                .setDescription(UrlRules.displayHost(url))
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            if (!mimeType.isNullOrBlank()) request.setMimeType(mimeType)
            if (!userAgent.isNullOrBlank()) request.addRequestHeader("User-Agent", userAgent)
            // The panel session cookie (HttpOnly) is readable here; DownloadManager needs it for authenticated
            // downloads. Only for the panel itself: cookies are not port-scoped, so getCookie() would also
            // hand the panel session to any other service on the same host (e.g. Nextcloud on 443).
            if (UrlRules.isSameOrigin(url, panelUrl)) {
                CookieManager.getInstance().getCookie(url)?.takeIf { it.isNotBlank() }?.let {
                    request.addRequestHeader("Cookie", it)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileName)
            } else {
                // Android 8/9: public Downloads would need WRITE_EXTERNAL_STORAGE; use the app's own folder.
                request.setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, fileName)
            }
            getSystemService(DownloadManager::class.java).enqueue(request)
            HomeVaultActions.toast(this, getString(R.string.download_started, fileName))
        } catch (e: RuntimeException) {
            HomeVaultActions.toast(this, getString(R.string.download_failed, e.message ?: e.javaClass.simpleName))
        }
    }

    // ---- menu & back ---------------------------------------------------------------------------

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.main, menu)
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        when (item.itemId) {
            R.id.action_refresh -> refresh()
            R.id.action_files -> HomeVaultActions.openFiles(this, config.nextcloudUrl)
            R.id.action_vpn -> HomeVaultActions.openVpn(this)
            R.id.action_change_server -> openSetup()
            R.id.action_about -> HomeVaultActions.showAbout(this, config)
            else -> return super.onOptionsItemSelected(item)
        }
        return true
    }

    private fun goBackInWebView(): Boolean {
        if (!webViewAlive || !webView.canGoBack()) return false
        hideError()
        webView.goBack()
        return true
    }

    /** Android 13+: predictive back. Intercept back only while the WebView has history. */
    private fun updateBackHandling() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val wanted = webViewAlive && webView.canGoBack()
        if (wanted == backCallbackRegistered) return
        val callback = backCallback as? OnBackInvokedCallback
            ?: OnBackInvokedCallback {
                goBackInWebView()
                updateBackHandling()
            }.also { backCallback = it }
        if (wanted) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
        } else {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(callback)
        }
        backCallbackRegistered = wanted
    }

    /**
     * Android 8–12 only: on 13+ the manifest enables OnBackInvokedCallback (see [updateBackHandling]),
     * so the system no longer calls this. The framework has no other back API before 13 (no AndroidX).
     */
    @SuppressLint("GestureBackNavigation")
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onBackPressed() {
        if (goBackInWebView()) return
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    private companion object {
        const val REQUEST_FILE_CHOOSER = 1001
        const val STATE_PANEL_URL = "app.homevault.android.PANEL_URL"
    }
}
