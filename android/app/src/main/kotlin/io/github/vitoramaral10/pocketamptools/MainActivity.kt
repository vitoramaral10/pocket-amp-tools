package io.github.vitoramaral10.pocketamptools

import android.bluetooth.BluetoothManager
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // A paired pedal reconnects to the phone on its own and then stops
    // advertising, so scans miss it: list what Android has paired instead.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pocket_amp/bluetooth")
            .setMethodCallHandler { call, result ->
                if (call.method != "bonded") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
                    result.success(adapter.bondedDevices.map {
                        mapOf("id" to it.address, "name" to (it.name ?: ""))
                    })
                } catch (e: SecurityException) {
                    result.success(emptyList<Map<String, String>>())
                }
            }
    }
}
