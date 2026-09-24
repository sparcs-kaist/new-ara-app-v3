package com.example.new_ara_app

import io.flutter.embedding.android.FlutterActivity

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
}
