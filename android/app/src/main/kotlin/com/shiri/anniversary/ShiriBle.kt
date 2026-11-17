package com.shiri.anniversary

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Discovery contains only a local address. Authentication and encrypted payloads stay in Dart. */
@SuppressLint("MissingPermission")
internal class ShiriBle(private val context: Context, private val onDevice: (Map<String, Any>) -> Unit, private val onError: (String) -> Unit) {
    private val serviceId = UUID.fromString("9b5971e4-3790-4bd0-b670-ef6e28d22a01")
    private val characteristicId = UUID.fromString("9b5971e4-3790-4bd0-b670-ef6e28d22a02")
    private val handler = Handler(Looper.getMainLooper())
    private val manager get() = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? get() = manager.adapter
    private var server: BluetoothGattServer? = null
    private val connections = ConcurrentHashMap<String, BluetoothGatt>()
    private val visited = ConcurrentHashMap<String, Long>()
    private var record = byteArrayOf()
    private var started = false
    private var completion: ((Boolean, String?) -> Unit)? = null
    private val timeout = Runnable { finishStart(false, "蓝牙发现启动超时") }

    fun start(name: String, host: String, port: Int, done: (Boolean, String?) -> Unit) {
        stop()
        require(port in 0..65535 && host.length in 1..255) { "Invalid local endpoint" }
        val radio = adapter
        if (radio == null || !radio.isEnabled || radio.bluetoothLeScanner == null) {
            done(false, "此设备暂不支持蓝牙发现，仍可输入地址连接")
            return
        }
        completion = done
        started = true
        if (port == 0) {
            // Sending phones have no listening endpoint. They are BLE centrals only.
            try { beginScan(); finishStart(true, null) }
            catch (_: Exception) { finishStart(false, "无法搜索附近设备") }
            return
        }
        if (!radio.isMultipleAdvertisementSupported || radio.bluetoothLeAdvertiser == null) {
            finishStart(false, "此设备暂不支持蓝牙广播，可使用地址接收")
            return
        }
        record = JSONObject().put("name", name.take(60)).put("host", host).put("port", port).toString().toByteArray(Charsets.UTF_8)
        if (record.size > 512) { finishStart(false, "本机发现信息过长"); return }
        server = manager.openGattServer(context, serverCallback)
        if (server == null) { finishStart(false, "无法启动蓝牙接收"); return }
        val service = BluetoothGattService(serviceId, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(characteristicId, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        if (server?.addService(service) != true) { finishStart(false, "无法发布蓝牙发现服务"); return }
        handler.postDelayed(timeout, 8000)
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            handler.post {
                if (!started) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) { finishStart(false, "蓝牙服务不可用"); return@post }
                try {
                    val settings = AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).setConnectable(true).setTimeout(0).build()
                    val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(serviceId)).setIncludeDeviceName(false).build()
                    adapter?.bluetoothLeAdvertiser?.startAdvertising(settings, data, advertiseCallback)
                } catch (_: SecurityException) { finishStart(false, "未允许附近设备权限") }
            }
        }
        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
            if (characteristic.uuid != characteristicId || offset < 0 || offset > record.size) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
            } else server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, record.copyOfRange(offset, record.size))
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            handler.post {
                if (!started) return@post
                try {
                    beginScan()
                    finishStart(true, null)
                } catch (_: Exception) { finishStart(false, "无法搜索附近设备") }
            }
        }
        override fun onStartFailure(errorCode: Int) { handler.post { finishStart(false, "蓝牙广播不可用（$errorCode）") } }
    }

    private fun beginScan() {
        val scanner = adapter?.bluetoothLeScanner ?: error("Bluetooth scanner is unavailable")
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceId)).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(filters, settings, scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) { connect(result.device) }
        override fun onBatchScanResults(results: MutableList<ScanResult>) { results.forEach { connect(it.device) } }
        override fun onScanFailed(errorCode: Int) {
            handler.post {
                if (completion != null) finishStart(false, "蓝牙搜索不可用（$errorCode）")
                else { stop(); onError("蓝牙搜索已停止（$errorCode），可输入地址连接") }
            }
        }
    }

    private fun connect(device: BluetoothDevice) {
        if (!started || connections.size >= 8) return
        val address = device.address
        val now = System.currentTimeMillis()
        if (connections.containsKey(address) || now - (visited[address] ?: 0) < 30000) return
        visited[address] = now
        try {
            val gatt = device.connectGatt(context, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
            connections[address] = gatt
            handler.postDelayed({ connections.remove(address)?.let { it.disconnect(); it.close() } }, 12000)
        } catch (_: Exception) { connections.remove(address)?.close() }
    }

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS && started) {
                if (!gatt.requestMtu(512)) gatt.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) close(gatt)
        }
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) { if (started) gatt.discoverServices() else close(gatt) }
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val characteristic = gatt.getService(serviceId)?.getCharacteristic(characteristicId)
            if (status != BluetoothGatt.GATT_SUCCESS || characteristic == null || !gatt.readCharacteristic(characteristic)) close(gatt)
        }
        @Deprecated("Used on Android 12 and older")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT < 33) receive(gatt, characteristic.value ?: byteArrayOf(), status)
        }
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) { receive(gatt, value, status) }
    }

    private fun receive(gatt: BluetoothGatt, bytes: ByteArray, status: Int) {
        try {
            if (status != BluetoothGatt.GATT_SUCCESS || bytes.size > 512 || !started) return
            val json = JSONObject(String(bytes, Charsets.UTF_8))
            val name = json.getString("name").take(60)
            val host = json.getString("host")
            val port = json.getInt("port")
            if (host.length !in 1..255 || port !in 1..65535) return
            handler.post { if (started) onDevice(mapOf("name" to name, "host" to host, "port" to port)) }
        } catch (_: Exception) { /* Ignore malformed discovery records; no user data is exchanged here. */ }
        finally { close(gatt) }
    }

    private fun close(gatt: BluetoothGatt) { connections.remove(gatt.device.address, gatt); gatt.disconnect(); gatt.close() }

    private fun finishStart(success: Boolean, error: String?) {
        handler.removeCallbacks(timeout)
        val done = completion
        completion = null
        if (!success) stop()
        done?.invoke(success, error)
    }

    fun stop() {
        started = false
        handler.removeCallbacksAndMessages(null)
        try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) { }
        try { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) { }
        connections.values.toList().forEach { try { it.disconnect(); it.close() } catch (_: Exception) { } }
        connections.clear(); visited.clear()
        try { server?.clearServices(); server?.close() } catch (_: Exception) { }
        server = null; record = byteArrayOf()
        val pending = completion
        completion = null
        pending?.invoke(false, "蓝牙发现已停止")
    }
}
