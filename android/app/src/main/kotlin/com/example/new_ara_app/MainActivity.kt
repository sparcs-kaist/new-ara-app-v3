package com.example.new_ara_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    // The root PopScope always intercepts back. Never let a framework toggle or an
    // Activity re-creation leave the system default (finish) in charge.
    override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean) {
        super.setFrameworkHandlesBack(true)
    }

    override fun onResume() {
        super.onResume()
        setFrameworkHandlesBack(true)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("ara_default", "알림", NotificationManager.IMPORTANCE_HIGH)
            )
        }
        if (Build.VERSION.SDK_INT < 30) return
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ara/keyboard")
        val density = resources.displayMetrics.density
        fun imeBottom() = window.decorView.rootWindowInsets?.getInsets(WindowInsets.Type.ime())?.bottom ?: 0
        // One event at IME animation start with the final height; the web replays the curve.
        window.decorView.setWindowInsetsAnimationCallback(
            object : WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                private var before = 0

                override fun onPrepare(animation: WindowInsetsAnimation) {
                    if (animation.typeMask and WindowInsets.Type.ime() != 0) before = imeBottom()
                }

                override fun onStart(
                    animation: WindowInsetsAnimation,
                    bounds: WindowInsetsAnimation.Bounds,
                ): WindowInsetsAnimation.Bounds {
                    if (animation.typeMask and WindowInsets.Type.ime() != 0) {
                        val after = imeBottom()
                        val visible = after > before
                        channel.invokeMethod("changed", mapOf(
                            "height" to (if (visible) after else 0) / density,
                            "visible" to visible,
                            "durationMs" to animation.durationMillis,
                        ))
                    }
                    return bounds
                }

                override fun onProgress(
                    insets: WindowInsets,
                    runningAnimations: MutableList<WindowInsetsAnimation>,
                ): WindowInsets = insets
            }
        )
    }
}
