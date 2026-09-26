# HomeVault Android: framework APIs only, no reflection, no JavaScript interfaces
# (addJavascriptInterface is never used), so the AGP default rules plus the
# manifest-derived keep rules for the two activities are sufficient.

# Keep readable stack traces in crash reports.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
