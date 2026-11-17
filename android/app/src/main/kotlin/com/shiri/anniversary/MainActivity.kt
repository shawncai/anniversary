package com.shiri.anniversary

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var platform: ShiriPlatform? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        platform = ShiriPlatform(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (platform?.onActivityResult(requestCode, resultCode, data) != true) super.onActivityResult(requestCode, resultCode, data)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (platform?.onRequestPermissionsResult(requestCode) != true) super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); platform?.onNewIntent(intent) }
    override fun onStop() { platform?.onStop(); super.onStop() }
    override fun onDestroy() { platform?.dispose(); platform = null; super.onDestroy() }
}
