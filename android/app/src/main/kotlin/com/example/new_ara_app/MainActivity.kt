package com.example.new_ara_app

import android.os.Build
import android.window.OnBackInvokedDispatcher
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hardware back button is intercepted at the Activity level — Flutter's
 * PopScope+canPop path was racing OnBackInvokedCallback on real Android
 * 13+ devices (predictive back), so the system would occasionally finish
 * the activity before the Dart handler ran. Registering directly on the
 * activity's OnBackInvokedDispatcher (and overriding the legacy
 * onBackPressed for API < 33) puts us authoritatively in front of the
 * dispatch and lets Dart decide what to do via a method channel.
 *
 * The Kotlin callback intentionally does no work other than notifying
 * Dart: it consumes the back invocation by virtue of being registered.
 */
class MainActivity : FlutterActivity() {
    private var backChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        backChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACK_CHANNEL,
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT,
            ) {
                backChannel?.invokeMethod("pressed", null)
            }
        }
    }

    @Suppress("OVERRIDE_DEPRECATION", "MissingSuperCall")
    override fun onBackPressed() {
        // Pre-Android 13. The new dispatcher is unavailable, so we
        // override the legacy callback. We deliberately don't call super
        // because the parent would finish the activity.
        if (backChannel != null) {
            backChannel?.invokeMethod("pressed", null)
        } else {
            // Channel not yet set up (very early in cold start) — let
            // the platform behave normally.
            @Suppress("DEPRECATION")
            super.onBackPressed()
        }
    }

    companion object {
        private const val BACK_CHANNEL = "ara/back"
    }
}
