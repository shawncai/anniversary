import Flutter
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import CryptoKit
import CoreBluetooth

/// All persistence is private to this device. The system picker is the only way
/// to bring an external document into the app's temporary staging directory.
final class ShiriPlatformBridge: NSObject, PHPickerViewControllerDelegate,
    UIDocumentPickerDelegate, CBCentralManagerDelegate, CBPeripheralManagerDelegate,
    CBPeripheralDelegate {
    private let channel: FlutterMethodChannel
    private let presenter: () -> UIViewController?
    private let work = DispatchQueue(label: "com.shiri.anniversary.files", qos: .userInitiated)
    private var photoResult: FlutterResult?
    private var documentResult: FlutterResult?
    private var exporting = false
    private var keys: [String: (key: P256.KeyAgreement.PrivateKey, createdAt: Date)] = [:]
    private var initialURL: String?
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var discoveryResult: FlutterResult?
    private var discoveryPayload: Data?
    private var discoveryActive = false
    private var advertisesEndpoint = false
    private var discoveryGeneration = 0
    private var peers: [UUID: CBPeripheral] = [:]
    private var servicesAdded = false
    private let serviceID = CBUUID(string: "9b5971e4-3790-4bd0-b670-ef6e28d22a01")
    private let characteristicID = CBUUID(string: "9b5971e4-3790-4bd0-b670-ef6e28d22a02")
    private let calendar = ShiriCalendar()
    private let appGroup = "group.com.shiri.anniversary"

    init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
        self.channel = FlutterMethodChannel(name: "com.shiri.anniversary/platform", binaryMessenger: messenger)
        self.presenter = presenter
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(FlutterError(code: "unavailable", message: "Native bridge unavailable", details: nil)); return }
            self.handle(call, result: result)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func receive(url: URL, cold: Bool = false) -> Bool {
        guard url.scheme == "shiri", url.host == "anniversary", !url.path.isEmpty else { return false }
        if cold { initialURL = url.absoluteString }
        channel.invokeMethod("onDeepLink", arguments: url.absoluteString)
        return true
    }

    private func finish(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    private func failure(_ error: Error) -> FlutterError {
        FlutterError(code: "native_error", message: error.localizedDescription, details: nil)
    }

    private func nativeError(_ message: String) -> NSError {
        NSError(domain: "Shiri", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func documents() throws -> URL {
        var url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    private func imports() throws -> URL {
        var url = try documents().appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    private func privateFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let roots = [try documents(), FileManager.default.temporaryDirectory]
        guard roots.contains(where: { url.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }),
              FileManager.default.fileExists(atPath: url.path) else { throw nativeError("文件不在本机应用目录中") }
        return url
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "paths":
            do { result(["documents": try documents().path, "temporary": FileManager.default.temporaryDirectory.path]) }
            catch { result(failure(error)) }
        #if targetEnvironment(simulator)
        case "verifyCalendarFixture": calendar.verifyFixture(args["id"] as? String ?? "", result: result)
        #endif
        case "syncReminder": calendar.sync(args, result: result)
        case "takeDayReminders":
            let ids = args["ids"] as? [String] ?? []
            let date = args["date"] as? String ?? ""
            let fresh = ids.filter { UserDefaults.standard.string(forKey: "shiri-seen-" + $0) != date }
            fresh.forEach { UserDefaults.standard.set(date, forKey: "shiri-seen-" + $0) }
            result(fresh)
        case "photoPermission": result(permission(PHPhotoLibrary.authorizationStatus(for: .readWrite)))
        case "requestPhotoPermission":
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in self.finish(result, self.permission(status)) }
        case "pickPhotos":
            guard photoResult == nil, documentResult == nil, let viewController = presenter() else { result(failure(nativeError("请先完成当前选择"))); return }
            photoResult = result
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.filter = .images; config.selectionLimit = 0
            config.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: config); picker.delegate = self
            viewController.present(picker, animated: true)
        case "scanPhotos":
            work.async { do { self.finish(result, try self.scan(args)) } catch { self.finish(result, self.failure(error)) } }
        case "importFile":
            guard documentResult == nil, photoResult == nil, let viewController = presenter() else { result(failure(nativeError("请先完成当前选择"))); return }
            documentResult = result; exporting = false
            let archiveType = UTType(filenameExtension: "shiri") ?? .data
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [archiveType, .data], asCopy: true)
            picker.delegate = self; picker.allowsMultipleSelection = false
            viewController.present(picker, animated: true)
        case "exportFile":
            do {
                guard documentResult == nil, photoResult == nil, let viewController = presenter(), let path = args["path"] as? String else { throw nativeError("请先完成当前选择") }
                let source = try privateFile(path)
                let proposedName = (args["name"] as? String ?? "拾日.shiri") as NSString
                let name = proposedName.lastPathComponent
                guard !name.isEmpty, name != ".", name != ".." else { throw nativeError("备份名称无效") }
                documentResult = result; exporting = true
                work.async {
                    do {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let staged = directory.appendingPathComponent(name)
                        try FileManager.default.copyItem(at: source, to: staged)
                        DispatchQueue.main.async {
                            let picker = UIDocumentPickerViewController(forExporting: [staged], asCopy: true)
                            picker.delegate = self; viewController.present(picker, animated: true)
                        }
                    } catch { DispatchQueue.main.async { self.documentResult = nil; result(self.failure(error)) } }
                }
            } catch { result(failure(error)) }
        case "updateWidgets":
            work.async { do { try self.writeWidget(args); self.finish(result, nil) } catch { self.finish(result, self.failure(error)) } }
        case "requestPinWidget": result(false)
        case "initialLink": result(initialURL); initialURL = nil
        case "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            result(nil)
        case "deviceName": result(UIDevice.current.name)
        case "startDiscovery": startDiscovery(args, result: result)
        case "stopDiscovery": stopDiscovery(); result(nil)
        case "cryptoKeyPair", "cryptoDerive", "cryptoSeal", "cryptoOpen":
            work.async { do { self.finish(result, try self.crypto(call.method, args)) } catch { self.finish(result, self.failure(error)) } }
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func permission(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "full"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "restricted"
        }
    }

    private func photoMetadata(_ original: URL, sourceID: String, date: Date?, originalName: String, mimeType: String) throws -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil) else { throw nativeError("无法读取照片") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1200]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw nativeError("无法生成照片预览") }
        let thumbnail = original.deletingPathExtension().appendingPathExtension("thumb.jpg")
        guard let destination = CGImageDestinationCreateWithURL(thumbnail as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw nativeError("无法保存照片预览") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw nativeError("无法保存照片预览") }
        var captured = date
        if captured == nil, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy:MM:dd HH:mm:ss"; format.timeZone = .current
            captured = format.date(from: value)
        }
        if captured == nil { captured = try? original.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]).contentModificationDate }
        let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
        return ["sourceId": sourceID, "originalPath": original.path, "thumbnailPath": thumbnail.path,
                "capturedAt": formatter.string(from: captured ?? Date()), "originalName": originalName, "mimeType": mimeType]
    }

    private func importAsset(_ asset: PHAsset) throws -> [String: Any] {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo }) ?? resources.first(where: { $0.type == .fullSizePhoto }) else { throw nativeError("照片原件不在本机") }
        let type = UTType(resource.uniformTypeIdentifier)
        let destination = try imports().appendingPathComponent(UUID().uuidString).appendingPathExtension(type?.preferredFilenameExtension ?? "img")
        let semaphore = DispatchSemaphore(value: 0)
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
        var resourceError: Error?
        PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
            resourceError = error; semaphore.signal()
        }
        semaphore.wait()
        if let resourceError { try? FileManager.default.removeItem(at: destination); throw resourceError }
        do {
            return try photoMetadata(destination, sourceID: asset.localIdentifier, date: asset.creationDate,
                                     originalName: resource.originalFilename, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    private func scan(_ args: [String: Any]) throws -> [String: Any] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw nativeError("请允许读取照片") }
        guard let month = args["month"] as? Int, let day = args["day"] as? Int, (1...12).contains(month), (1...31).contains(day) else { throw nativeError("纪念日日期无效") }
        let tolerance = max(0, min(31, args["windowDays"] as? Int ?? 0))
        let offset = max(0, args["offset"] as? Int ?? 0)
        let limit = max(1, min(100, args["limit"] as? Int ?? 50))
        let startYear = args["startYear"] as? Int ?? 1
        let calendar = Calendar(identifier: .gregorian)
        guard (1...9999).contains(startYear),
              let firstDate = calendar.date(from: DateComponents(year: startYear, month: month, day: day)),
              calendar.component(.month, from: firstDate) == month,
              calendar.component(.day, from: firstDate) == day else { throw nativeError("首次日期无效") }
        let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var matching = 0; var page: [PHAsset] = []; var hasMore = false
        assets.enumerateObjects { asset, _, stop in
            guard let date = asset.creationDate else { return }
            let year = calendar.component(.year, from: date)
            let current = calendar.startOfDay(for: date)
            guard current >= firstDate else { return }
            let isMatch = (year - 1 ... year + 1).contains { candidateYear in
                guard candidateYear >= startYear, candidateYear <= 9999,
                      let first = calendar.date(from: DateComponents(year: candidateYear, month: month, day: 1)),
                      let range = calendar.range(of: .day, in: .month, for: first),
                      let target = calendar.date(from: DateComponents(year: candidateYear, month: month, day: min(day, range.count))),
                      let difference = calendar.dateComponents([.day], from: target, to: current).day else { return false }
                return abs(difference) <= tolerance
            }
            guard isMatch else { return }
            if matching >= offset {
                if page.count < limit { page.append(asset) } else { hasMore = true; stop.pointee = true }
            }
            matching += 1
        }
        var items: [[String: Any]] = []; var unavailable = 0
        for asset in page { do { items.append(try importAsset(asset)) } catch { unavailable += 1 } }
        return ["items": items, "nextOffset": hasMore ? offset + page.count : NSNull(), "unavailable": unavailable]
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking selections: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = photoResult else { return }; photoResult = nil
        guard !selections.isEmpty else { result(nil); return }
        work.async {
            var items: [[String: Any]] = []; var lastError: Error?
            for selection in selections {
                if let identifier = selection.assetIdentifier, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                    do { items.append(try self.importAsset(asset)); continue } catch { lastError = error }
                }
                let provider = selection.itemProvider
                guard let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { continue }
                let semaphore = DispatchSemaphore(value: 0)
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                    defer { semaphore.signal() }
                    do {
                        if let error { throw error }
                        guard let url else { throw self.nativeError("照片不可用") }
                        let type = UTType(identifier)
                        let destination = try self.imports().appendingPathComponent(UUID().uuidString).appendingPathExtension(type?.preferredFilenameExtension ?? "img")
                        try FileManager.default.copyItem(at: url, to: destination)
                        items.append(try self.photoMetadata(destination, sourceID: selection.assetIdentifier ?? UUID().uuidString,
                                                            date: nil, originalName: provider.suggestedName ?? url.lastPathComponent,
                                                            mimeType: type?.preferredMIMEType ?? "application/octet-stream"))
                    } catch { lastError = error }
                }
                semaphore.wait()
            }
            self.finish(result, items.isEmpty && lastError != nil ? self.failure(lastError!) : items)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let result = documentResult else { return }; documentResult = nil
        result(exporting ? false : nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let result = documentResult else { return }; documentResult = nil
        if exporting { result(!urls.isEmpty); return }
        guard let url = urls.first else { result(nil); return }
        work.async {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("shiri")
                try FileManager.default.copyItem(at: url, to: destination)
                self.finish(result, destination.path)
            } catch { self.finish(result, self.failure(error)) }
        }
    }

    private func writeWidget(_ args: [String: Any]) throws {
        guard let json = args["json"] as? String, let data = json.data(using: .utf8),
              var snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              snapshot["version"] as? Int == 1,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { throw nativeError("小组件共享目录不可用，请检查 App Group 签名") }
        var shared = container
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try shared.setResourceValues(values)
        let selected = snapshot["selectedEventId"] as? String
        var sharedCover: String?
        if let path = args["coverPath"] as? String, FileManager.default.fileExists(atPath: path) {
            let source = try privateFile(path)
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1000] as CFDictionary) else { throw nativeError("无法读取小组件封面") }
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { throw nativeError("无法保存小组件封面") }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw nativeError("无法保存小组件封面") }
            let target = container.appendingPathComponent("cover.jpg")
            try (buffer as Data).write(to: target, options: .atomic); sharedCover = target.path
        }
        if var events = snapshot["events"] as? [[String: Any]] {
            for index in events.indices { events[index]["coverPath"] = events[index]["id"] as? String == selected ? (sharedCover as Any? ?? NSNull()) : NSNull() }
            snapshot["events"] = events
        }
        try JSONSerialization.data(withJSONObject: snapshot).write(to: container.appendingPathComponent("snapshot.json"), options: .atomic)
        ShiriWidgetReloader.reload()
    }

    private func bytes(_ args: [String: Any], _ name: String, count: Int? = nil) throws -> Data {
        guard let typed = args[name] as? FlutterStandardTypedData, count == nil || typed.data.count == count else { throw nativeError("加密参数无效") }
        return typed.data
    }

    private func crypto(_ method: String, _ args: [String: Any]) throws -> Any {
        switch method {
        case "cryptoKeyPair":
            keys = keys.filter { Date().timeIntervalSince($0.value.createdAt) < 120 }
            guard keys.count < 32 else { throw nativeError("配对会话过多，请稍后重试") }
            let key = P256.KeyAgreement.PrivateKey(); let handle = UUID().uuidString; keys[handle] = (key, Date())
            return ["handle": handle, "publicKey": FlutterStandardTypedData(bytes: key.publicKey.x963Representation)]
        case "cryptoDerive":
            guard let handle = args["handle"] as? String, let record = keys.removeValue(forKey: handle),
                  Date().timeIntervalSince(record.createdAt) < 120 else { throw nativeError("配对会话已失效") }
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: bytes(args, "peerPublicKey", count: 65))
            let salt = try bytes(args, "salt", count: 32)
            let shared = try record.key.sharedSecretFromKeyAgreement(with: peer)
            let derived = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("shiri-transfer-v1".utf8), outputByteCount: 32)
            return derived.withUnsafeBytes { FlutterStandardTypedData(bytes: Data($0)) }
        case "cryptoSeal":
            let key = SymmetricKey(data: try bytes(args, "key", count: 32))
            let nonce = try AES.GCM.Nonce(data: bytes(args, "nonce", count: 12))
            let sealed = try AES.GCM.seal(bytes(args, "plaintext"), using: key, nonce: nonce, authenticating: bytes(args, "aad"))
            return FlutterStandardTypedData(bytes: sealed.ciphertext + sealed.tag)
        case "cryptoOpen":
            let key = SymmetricKey(data: try bytes(args, "key", count: 32))
            let nonce = try AES.GCM.Nonce(data: bytes(args, "nonce", count: 12))
            let data = try bytes(args, "ciphertext")
            guard data.count >= 16 else { throw nativeError("加密数据不完整") }
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
            return FlutterStandardTypedData(bytes: try AES.GCM.open(box, using: key, authenticating: bytes(args, "aad")))
        default: throw nativeError("加密操作不支持")
        }
    }

    private func startDiscovery(_ args: [String: Any], result: @escaping FlutterResult) {
        stopDiscovery()
        guard let name = args["name"] as? String, let host = args["host"] as? String,
              let port = args["port"] as? Int, (0...65535).contains(port),
              port == 0 || !host.isEmpty else { result(failure(nativeError("互传地址无效"))); return }
        guard CBManager.authorization != .denied && CBManager.authorization != .restricted else { result(false); return }
        advertisesEndpoint = port > 0
        if advertisesEndpoint {
            let payload: [String: Any] = ["name": String(name.prefix(64)), "host": String(host.prefix(128)), "port": port]
            discoveryPayload = try? JSONSerialization.data(withJSONObject: payload)
        }
        discoveryActive = true; discoveryResult = result
        central = CBCentralManager(delegate: self, queue: .main)
        if advertisesEndpoint { peripheralManager = CBPeripheralManager(delegate: self, queue: .main) }
        let generation = discoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.discoveryGeneration == generation, self.discoveryResult != nil else { return }
            self.stopDiscovery()
        }
    }

    private func stopDiscovery() {
        discoveryGeneration += 1; discoveryActive = false
        central?.stopScan()
        for peer in peers.values { central?.cancelPeripheralConnection(peer); peer.delegate = nil }
        peers.removeAll(); peripheralManager?.stopAdvertising(); peripheralManager?.removeAllServices()
        central?.delegate = nil; peripheralManager?.delegate = nil
        central = nil; peripheralManager = nil; servicesAdded = false; discoveryPayload = nil; advertisesEndpoint = false
        if let result = discoveryResult { discoveryResult = nil; result(false) }
        work.async { self.keys.removeAll() }
    }

    @objc private func backgrounded() { stopDiscovery() }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard discoveryActive, self.central === central else { return }
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: [serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            // A sender has no receiving endpoint and only needs central-role scanning.
            if !advertisesEndpoint, let result = discoveryResult { discoveryResult = nil; result(true) }
        case .unsupported, .unauthorized, .poweredOff: stopDiscovery()
        default: break
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard discoveryActive, peripheralManager === peripheral else { return }
        switch peripheral.state {
        case .poweredOn:
            guard !servicesAdded else { return }; servicesAdded = true
            let characteristic = CBMutableCharacteristic(type: characteristicID, properties: [.read], value: nil, permissions: [.readable])
            let service = CBMutableService(type: serviceID, primary: true); service.characteristics = [characteristic]
            peripheral.add(service)
        case .unsupported, .unauthorized, .poweredOff: stopDiscovery()
        default: break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard discoveryActive, peripheralManager === peripheral else { return }
        guard error == nil else { stopDiscovery(); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard discoveryActive, peripheralManager === peripheral else { return }
        if error != nil { stopDiscovery(); return }
        if let result = discoveryResult { discoveryResult = nil; result(true) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == characteristicID, let data = discoveryPayload else { peripheral.respond(to: request, withResult: .attributeNotFound); return }
        guard request.offset <= data.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard discoveryActive, self.central === central, peers[peripheral.identifier] == nil, peers.count < 20 else { return }
        peers[peripheral.identifier] = peripheral; peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([serviceID]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { peers.removeValue(forKey: peripheral.identifier) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { peers.removeValue(forKey: peripheral.identifier) }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { central?.cancelPeripheralConnection(peripheral); return }
        for service in peripheral.services ?? [] where service.uuid == serviceID { peripheral.discoverCharacteristics([characteristicID], for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { central?.cancelPeripheralConnection(peripheral); return }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == characteristicID { peripheral.readValue(for: characteristic) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        defer { central?.cancelPeripheralConnection(peripheral) }
        guard discoveryActive, error == nil, characteristic.uuid == characteristicID,
              let data = characteristic.value, data.count <= 1024,
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = map["name"] as? String, let host = map["host"] as? String,
              let port = map["port"] as? Int, (1...65535).contains(port), !host.isEmpty else { return }
        channel.invokeMethod("onNearbyDevice", arguments: ["name": name, "host": host, "port": port])
    }
}
