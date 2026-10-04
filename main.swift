import Carbon
import Foundation
import IOKit.hid
import Darwin

@_silgen_name("RunApplicationEventLoop")
private func RunApplicationEventLoop()

@_silgen_name("QuitApplicationEventLoop")
private func QuitApplicationEventLoop()

private enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}

private enum MonitorInput: String {
    case dp
    case typec
    case query

    var asciiCommand: String {
        switch self {
        case .dp:
            return "5b00500002\r"
        case .typec:
            return "5b00500003\r"
        case .query:
            return "5800500\r"
        }
    }
}

private enum ReportKind: String, Codable, CaseIterable {
    case feature
    case output

    var ioKitType: IOHIDReportType {
        switch self {
        case .feature:
            return kIOHIDReportTypeFeature
        case .output:
            return kIOHIDReportTypeOutput
        }
    }
}

private struct HIDRoute: Codable {
    var locationID: Int?
    var transport: String?
    var primaryUsagePage: Int?
    var product: String?
    var reportKind: ReportKind
    var reportID: Int
    var includeReportIDByte: Bool
    var reportLength: Int
}

private struct ReportPlan: CustomStringConvertible {
    var reportKind: ReportKind
    var reportID: Int
    var includeReportIDByte: Bool
    var reportLength: Int

    var description: String {
        "\(reportKind.rawValue) reportID=\(reportID) length=\(reportLength) leadingID=\(includeReportIDByte)"
    }
}

private struct DeviceDescriptor {
    var device: IOHIDDevice
    var product: String
    var manufacturer: String
    var transport: String
    var vendorID: Int
    var productID: Int
    var locationID: Int?
    var primaryUsagePage: Int?
    var primaryUsage: Int?
    var maxInputReportSize: Int
    var maxOutputReportSize: Int
    var maxFeatureReportSize: Int
    var inputReportIDs: [Int]
    var outputReportIDs: [Int]
    var featureReportIDs: [Int]

    var summaryLine: String {
        let location = locationID.map { String(format: "0x%08X", $0) } ?? "n/a"
        let usagePage = primaryUsagePage.map { String(format: "0x%04X", $0) } ?? "n/a"
        let usage = primaryUsage.map { String(format: "0x%04X", $0) } ?? "n/a"
        return "\(product) transport=\(transport) location=\(location) usagePage=\(usagePage) usage=\(usage) feature=\(maxFeatureReportSize) output=\(maxOutputReportSize) input=\(maxInputReportSize) featureIDs=\(featureReportIDs) outputIDs=\(outputReportIDs)"
    }
}

private struct ProbeResult {
    var route: HIDRoute?
    var response: [UInt8]?
    var usedFallback: Bool
    var attemptedDevices: Int
}

private enum CLICommand {
    case help
    case probe(writeConfig: Bool, quiet: Bool)
    case query(quiet: Bool)
    case send(MonitorInput, quiet: Bool)
    case daemon(verbose: Bool)
}

private enum Paths {
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MSIF14DP", isDirectory: true)
    static let configURL = supportDirectory.appendingPathComponent("route.json", isDirectory: false)

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}

private final class RouteStore {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> HIDRoute? {
        guard let data = try? Data(contentsOf: Paths.configURL) else {
            return nil
        }
        return try? decoder.decode(HIDRoute.self, from: data)
    }

    func save(_ route: HIDRoute) throws {
        try Paths.ensureSupportDirectory()
        let data = try encoder.encode(route)
        try data.write(to: Paths.configURL, options: .atomic)
    }
}

private final class HIDContext {
    let manager: IOHIDManager
    let devices: [DeviceDescriptor]

    init(vendorID: Int, productID: Int) throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw AppError.message("无法打开 IOHIDManager: \(describeIOReturn(openResult))")
        }

        let rawDevices = IOHIDManagerCopyDevices(manager)
        let deviceRefs = Array((rawDevices as? Set<IOHIDDevice>) ?? [])
        devices = deviceRefs
            .map(Self.describe(device:))
            .sorted(by: { Self.score($0) > Self.score($1) })
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private static func describe(device: IOHIDDevice) -> DeviceDescriptor {
        let product = stringProperty(device, key: kIOHIDProductKey) ?? "Unknown Product"
        let manufacturer = stringProperty(device, key: kIOHIDManufacturerKey) ?? "Unknown Manufacturer"
        let transport = stringProperty(device, key: kIOHIDTransportKey) ?? "Unknown Transport"

        var inputIDs = Set<Int>()
        var outputIDs = Set<Int>()
        var featureIDs = Set<Int>()

        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for element in elements {
                let reportID = Int(IOHIDElementGetReportID(element))
                switch IOHIDElementGetType(element) {
                case kIOHIDElementTypeInput_Misc, kIOHIDElementTypeInput_Button, kIOHIDElementTypeInput_Axis, kIOHIDElementTypeInput_ScanCodes:
                    inputIDs.insert(reportID)
                case kIOHIDElementTypeOutput:
                    outputIDs.insert(reportID)
                case kIOHIDElementTypeFeature:
                    featureIDs.insert(reportID)
                default:
                    continue
                }
            }
        }

        return DeviceDescriptor(
            device: device,
            product: product,
            manufacturer: manufacturer,
            transport: transport,
            vendorID: intProperty(device, key: kIOHIDVendorIDKey) ?? 0,
            productID: intProperty(device, key: kIOHIDProductIDKey) ?? 0,
            locationID: intProperty(device, key: kIOHIDLocationIDKey),
            primaryUsagePage: intProperty(device, key: kIOHIDPrimaryUsagePageKey),
            primaryUsage: intProperty(device, key: kIOHIDPrimaryUsageKey),
            maxInputReportSize: intProperty(device, key: kIOHIDMaxInputReportSizeKey) ?? 0,
            maxOutputReportSize: intProperty(device, key: kIOHIDMaxOutputReportSizeKey) ?? 0,
            maxFeatureReportSize: intProperty(device, key: kIOHIDMaxFeatureReportSizeKey) ?? 0,
            inputReportIDs: sortedReportIDs(inputIDs),
            outputReportIDs: sortedReportIDs(outputIDs),
            featureReportIDs: sortedReportIDs(featureIDs)
        )
    }

    private static func sortedReportIDs(_ ids: Set<Int>) -> [Int] {
        let merged = ids.union([0])
        return merged.sorted()
    }

    private static func score(_ descriptor: DeviceDescriptor) -> Int {
        var score = 0
        if descriptor.transport == "USB" {
            score += 50
        }
        if descriptor.product.contains("MSI") {
            score += 30
        }
        if let usagePage = descriptor.primaryUsagePage, usagePage >= 0xFF00 {
            score += 20
        }
        if descriptor.maxFeatureReportSize >= 64 {
            score += 100
        }
        if descriptor.maxOutputReportSize >= 64 {
            score += 80
        }
        return score
    }
}

private final class MSIController {
    private let vendorID = 0x1462
    private let productID = 0x3FA4
    private let routeStore = RouteStore()

    func listDevices() throws -> [DeviceDescriptor] {
        try HIDContext(vendorID: vendorID, productID: productID).devices
    }

    func probe(writeConfig: Bool, quiet: Bool) throws -> ProbeResult {
        let context = try HIDContext(vendorID: vendorID, productID: productID)
        if context.devices.isEmpty {
            throw AppError.message("没有找到 VID 0x1462 PID 0x3FA4 的 MSI HID 设备。")
        }

        if !quiet {
            print("发现 \(context.devices.count) 个候选 HID 接口：")
            for (index, descriptor) in context.devices.enumerated() {
                print("[\(index)] \(descriptor.summaryLine)")
            }
        }

        if let cached = routeStore.load(),
           let result = try probeRoute(cached, in: context, quiet: quiet)
        {
            if writeConfig {
                try routeStore.save(result.route!)
            }
            return result
        }

        for descriptor in context.devices {
            if let result = try probeDescriptor(descriptor, quiet: quiet) {
                if writeConfig, let route = result.route {
                    try routeStore.save(route)
                }
                return result
            }
        }

        throw AppError.message("探测不到可用的 HID report 路径。")
    }

    func query(quiet: Bool) throws -> ProbeResult {
        let result = try probe(writeConfig: true, quiet: quiet)
        return result
    }

    func send(_ input: MonitorInput, quiet: Bool) throws {
        let context = try HIDContext(vendorID: vendorID, productID: productID)
        if context.devices.isEmpty {
            throw AppError.message("当前看不到 MSI 显示器的 HID 设备。请先让画面停留在 Mac 可见的 Type-C 输入上。")
        }

        var deliveredPlans: [String] = []
        var attemptedKeys = Set<String>()

        if let cached = routeStore.load() {
            for descriptor in context.devices where deviceMatchesRoute(descriptor, route: cached) {
                let plan = ReportPlan(
                    reportKind: cached.reportKind,
                    reportID: cached.reportID,
                    includeReportIDByte: cached.includeReportIDByte,
                    reportLength: cached.reportLength
                )
                let key = planKey(for: descriptor, plan: plan)
                attemptedKeys.insert(key)
                if try send(command: input, to: descriptor, plan: plan) {
                    deliveredPlans.append("\(descriptor.summaryLine) / \(plan)")
                }
            }
        }

        for descriptor in context.devices {
            for plan in plans(for: descriptor, preferred: nil) {
                let key = planKey(for: descriptor, plan: plan)
                guard attemptedKeys.insert(key).inserted else {
                    continue
                }
                if try send(command: input, to: descriptor, plan: plan) {
                    deliveredPlans.append("\(descriptor.summaryLine) / \(plan)")
                }
            }
        }

        guard deliveredPlans.isEmpty == false else {
            throw AppError.message("没有成功发出 \(input.rawValue) 命令。")
        }

        if !quiet {
            print("已发送 \(input.rawValue) 命令，命中 \(deliveredPlans.count) 条可写路径。")
            for plan in deliveredPlans {
                print(plan)
            }
        }
    }

    private func probeRoute(_ route: HIDRoute, in context: HIDContext, quiet: Bool) throws -> ProbeResult? {
        guard let descriptor = context.devices.first(where: { deviceMatchesRoute($0, route: route) }) else {
            return nil
        }
        let plan = ReportPlan(
            reportKind: route.reportKind,
            reportID: route.reportID,
            includeReportIDByte: route.includeReportIDByte,
            reportLength: route.reportLength
        )
        return try probePlan(on: descriptor, plan: plan, quiet: quiet, markAsFallback: false)
    }

    private func probeDescriptor(_ descriptor: DeviceDescriptor, quiet: Bool) throws -> ProbeResult? {
        var lastSuccessfulWrite: ProbeResult?
        for plan in plans(for: descriptor, preferred: nil) {
            if let result = try probePlan(on: descriptor, plan: plan, quiet: quiet, markAsFallback: true) {
                if result.response != nil {
                    return result
                }
                if lastSuccessfulWrite == nil {
                    lastSuccessfulWrite = result
                }
            }
        }
        return lastSuccessfulWrite
    }

    private func probePlan(on descriptor: DeviceDescriptor, plan: ReportPlan, quiet: Bool, markAsFallback: Bool) throws -> ProbeResult? {
        let openResult = IOHIDDeviceOpen(descriptor.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            if !quiet {
                print("打开失败: \(descriptor.summaryLine) / \(plan) / \(describeIOReturn(openResult))")
            }
            return nil
        }
        defer { IOHIDDeviceClose(descriptor.device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let queryPayload = payload(for: .query, plan: plan)
        let writeResult = setReport(descriptor.device, plan: plan, bytes: queryPayload)
        guard writeResult == kIOReturnSuccess else {
            if !quiet {
                print("写 query 失败: \(descriptor.summaryLine) / \(plan) / \(describeIOReturn(writeResult))")
            }
            return nil
        }

        let route = routeFor(descriptor: descriptor, plan: plan)

        let responseAttempts = [
            ReportPlan(reportKind: .feature, reportID: plan.reportID, includeReportIDByte: plan.includeReportIDByte, reportLength: plan.reportLength),
            ReportPlan(reportKind: .feature, reportID: plan.reportID, includeReportIDByte: false, reportLength: 64),
            ReportPlan(reportKind: .feature, reportID: plan.reportID, includeReportIDByte: true, reportLength: 65),
        ]

        for responsePlan in responseAttempts {
            if let response = getReport(descriptor.device, plan: responsePlan), containsUsefulBytes(response) {
                if !quiet {
                    print("命中 query 响应: \(descriptor.summaryLine) / \(plan)")
                    print("响应 ASCII: \(asciiPreview(response))")
                    print("响应 HEX  : \(hexString(response))")
                }
                return ProbeResult(route: route, response: response, usedFallback: markAsFallback, attemptedDevices: 1)
            }
        }

        if !quiet {
            print("命中可写路径，但暂未读到 query 响应: \(descriptor.summaryLine) / \(plan)")
        }
        return ProbeResult(route: route, response: nil, usedFallback: markAsFallback, attemptedDevices: 1)
    }

    private func send(command: MonitorInput, via route: HIDRoute, in context: HIDContext) throws -> Bool {
        guard let descriptor = context.devices.first(where: { deviceMatchesRoute($0, route: route) }) else {
            return false
        }
        let plan = ReportPlan(
            reportKind: route.reportKind,
            reportID: route.reportID,
            includeReportIDByte: route.includeReportIDByte,
            reportLength: route.reportLength
        )
        return try send(command: command, to: descriptor, plan: plan)
    }

    private func send(command: MonitorInput, to descriptor: DeviceDescriptor, plan: ReportPlan) throws -> Bool {
        let openResult = IOHIDDeviceOpen(descriptor.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            return false
        }
        defer { IOHIDDeviceClose(descriptor.device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let writeResult = setReport(descriptor.device, plan: plan, bytes: payload(for: command, plan: plan))
        return writeResult == kIOReturnSuccess
    }

    private func plans(for descriptor: DeviceDescriptor, preferred route: HIDRoute?) -> [ReportPlan] {
        var plans: [ReportPlan] = []
        var seen = Set<String>()

        func append(_ plan: ReportPlan) {
            let key = "\(plan.reportKind.rawValue)-\(plan.reportID)-\(plan.includeReportIDByte)-\(plan.reportLength)"
            guard seen.insert(key).inserted else {
                return
            }
            plans.append(plan)
        }

        if let route, deviceMatchesRoute(descriptor, route: route) {
            append(ReportPlan(
                reportKind: route.reportKind,
                reportID: route.reportID,
                includeReportIDByte: route.includeReportIDByte,
                reportLength: route.reportLength
            ))
        }

        let featureIDs = descriptor.featureReportIDs.isEmpty ? [0] : descriptor.featureReportIDs
        let outputIDs = descriptor.outputReportIDs.isEmpty ? [0] : descriptor.outputReportIDs

        if descriptor.maxFeatureReportSize == 0 || descriptor.maxFeatureReportSize >= 64 {
            for reportID in featureIDs {
                append(ReportPlan(reportKind: .feature, reportID: reportID, includeReportIDByte: false, reportLength: 64))
                append(ReportPlan(reportKind: .feature, reportID: reportID, includeReportIDByte: true, reportLength: 65))
            }
        }

        if descriptor.maxOutputReportSize == 0 || descriptor.maxOutputReportSize >= 64 {
            for reportID in outputIDs {
                append(ReportPlan(reportKind: .output, reportID: reportID, includeReportIDByte: false, reportLength: 64))
                append(ReportPlan(reportKind: .output, reportID: reportID, includeReportIDByte: true, reportLength: 65))
            }
        }

        return plans
    }

    private func routeFor(descriptor: DeviceDescriptor, plan: ReportPlan) -> HIDRoute {
        HIDRoute(
            locationID: descriptor.locationID,
            transport: descriptor.transport,
            primaryUsagePage: descriptor.primaryUsagePage,
            product: descriptor.product,
            reportKind: plan.reportKind,
            reportID: plan.reportID,
            includeReportIDByte: plan.includeReportIDByte,
            reportLength: plan.reportLength
        )
    }

    private func planKey(for descriptor: DeviceDescriptor, plan: ReportPlan) -> String {
        let location = descriptor.locationID ?? -1
        return "\(location)-\(plan.reportKind.rawValue)-\(plan.reportID)-\(plan.includeReportIDByte)-\(plan.reportLength)"
    }

    private func deviceMatchesRoute(_ descriptor: DeviceDescriptor, route: HIDRoute) -> Bool {
        if let locationID = route.locationID, descriptor.locationID == locationID {
            return true
        }
        if let product = route.product, descriptor.product == product,
           let usagePage = route.primaryUsagePage, descriptor.primaryUsagePage == usagePage
        {
            return true
        }
        return false
    }
}

private final class HotKeyDaemon {
    private let controller = MSIController()
    private let verbose: Bool
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var signalSources: [DispatchSourceSignal] = []

    init(verbose: Bool) {
        self.verbose = verbose
    }

    func run() throws {
        try installSignalHandlers()
        let eventTarget = GetEventDispatcherTarget()

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            eventTarget,
            { _, _, userData in
                guard let userData else {
                    return noErr
                }
                let daemon = Unmanaged<HotKeyDaemon>.fromOpaque(userData).takeUnretainedValue()
                daemon.handleHotKey()
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            throw AppError.message("安装 F14 事件处理器失败: \(describeOSStatus(installStatus))")
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("MSI1"), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_F14),
            UInt32(0),
            hotKeyID,
            eventTarget,
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            throw AppError.message("注册 F14 全局热键失败: \(describeOSStatus(registerStatus))")
        }

        if verbose {
            print("F14 常驻已启动，按下 F14 会切到 DP。")
        }

        RunApplicationEventLoop()
    }

    private func handleHotKey() {
        do {
            try controller.send(.dp, quiet: !verbose)
        } catch {
            if verbose {
                fputs("F14 切换失败: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func installSignalHandlers() throws {
        for signalValue in [SIGTERM, SIGINT] {
            signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler {
                QuitApplicationEventLoop()
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

private func payload(for command: MonitorInput, plan: ReportPlan) -> [UInt8] {
    let base = basePayload(for: command)
    if plan.includeReportIDByte {
        return [UInt8(truncatingIfNeeded: plan.reportID)] + base
    }
    return base
}

private func basePayload(for command: MonitorInput) -> [UInt8] {
    let asciiBytes = Array(command.asciiCommand.utf8)
    precondition(asciiBytes.count <= 64, "命令长度超过 64 字节")
    var payload = Array(repeating: UInt8(0), count: 64)
    payload.replaceSubrange(0..<asciiBytes.count, with: asciiBytes)
    return payload
}

private func setReport(_ device: IOHIDDevice, plan: ReportPlan, bytes: [UInt8]) -> IOReturn {
    var mutableBytes = bytes
    return mutableBytes.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return kIOReturnNoMemory
        }
        return IOHIDDeviceSetReport(
            device,
            plan.reportKind.ioKitType,
            CFIndex(plan.reportID),
            baseAddress.assumingMemoryBound(to: UInt8.self),
            bytes.count
        )
    }
}

private func getReport(_ device: IOHIDDevice, plan: ReportPlan) -> [UInt8]? {
    var buffer = Array(repeating: UInt8(0), count: plan.reportLength)
    var length = plan.reportLength
    let result = buffer.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return kIOReturnNoMemory
        }
        return IOHIDDeviceGetReport(
            device,
            plan.reportKind.ioKitType,
            CFIndex(plan.reportID),
            baseAddress.assumingMemoryBound(to: UInt8.self),
            &length
        )
    }
    guard result == kIOReturnSuccess else {
        return nil
    }
    return Array(buffer.prefix(length))
}

private func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
    IOHIDDeviceGetProperty(device, key as CFString) as? String
}

private func intProperty(_ device: IOHIDDevice, key: String) -> Int? {
    if let number = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber {
        return number.intValue
    }
    return nil
}

private func containsUsefulBytes(_ bytes: [UInt8]) -> Bool {
    bytes.contains(where: { $0 != 0 })
}

private func asciiPreview(_ bytes: [UInt8]) -> String {
    let preview = bytes.prefix(while: { $0 != 0 })
    let rendered = preview.map { byte -> Character in
        if byte == 0x0D {
            return "↩"
        }
        if 32...126 ~= byte {
            return Character(UnicodeScalar(byte))
        }
        return "·"
    }
    return String(rendered)
}

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func describeIOReturn(_ value: IOReturn) -> String {
    String(format: "0x%08X", value)
}

private func describeOSStatus(_ value: OSStatus) -> String {
    String(format: "0x%08X", value)
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { partial, byte in
        (partial << 8) | FourCharCode(byte)
    }
}

private func parseCommandLine() throws -> CLICommand {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first else {
        return .help
    }

    switch first {
    case "probe":
        return .probe(writeConfig: args.contains("--write-config"), quiet: args.contains("--quiet"))
    case "query":
        return .query(quiet: args.contains("--quiet"))
    case "dp":
        return .send(.dp, quiet: args.contains("--quiet"))
    case "typec":
        return .send(.typec, quiet: args.contains("--quiet"))
    case "daemon":
        return .daemon(verbose: args.contains("--verbose"))
    case "help", "--help", "-h":
        return .help
    default:
        throw AppError.message("未知命令：\(first)")
    }
}

private func printHelp() {
    print(
        """
        用法:
          msi-f14-dp probe [--write-config] [--quiet]
          msi-f14-dp query [--quiet]
          msi-f14-dp dp [--quiet]
          msi-f14-dp typec [--quiet]
          msi-f14-dp daemon [--verbose]

        说明:
          probe   探测可用 HID report 路径，并可写入缓存
          query   发送查询命令并尝试读取返回
          dp      直接切到 DP
          typec   直接切到 Type-C
          daemon  静默常驻，监听 F14 并切到 DP
        """
    )
}

private func run() throws {
    switch try parseCommandLine() {
    case .help:
        printHelp()

    case let .probe(writeConfig, quiet):
        let result = try MSIController().probe(writeConfig: writeConfig, quiet: quiet)
        guard let route = result.route else {
            throw AppError.message("探测没有得到可用路径。")
        }
        print("Probe route: \(route.reportKind.rawValue) reportID=\(route.reportID) length=\(route.reportLength) leadingID=\(route.includeReportIDByte)")
        if let response = result.response {
            print("Query ASCII: \(asciiPreview(response))")
            print("Query HEX  : \(hexString(response))")
        } else {
            print("Query 响应暂未读到，但该路径可写。")
        }
        if writeConfig {
            print("已写入缓存: \(Paths.configURL.path)")
        }

    case let .query(quiet):
        let result = try MSIController().query(quiet: quiet)
        guard let route = result.route else {
            throw AppError.message("没有探测到可用路径。")
        }
        print("Query route: \(route.reportKind.rawValue) reportID=\(route.reportID) length=\(route.reportLength) leadingID=\(route.includeReportIDByte)")
        if let response = result.response {
            print("Query ASCII: \(asciiPreview(response))")
            print("Query HEX  : \(hexString(response))")
        } else {
            print("Query 响应为空，但写入路径已命中。")
        }

    case let .send(input, quiet):
        try MSIController().send(input, quiet: quiet)
        if quiet == false {
            print("命令完成: \(input.rawValue)")
        }

    case let .daemon(verbose):
        if verbose {
            setbuf(stdout, nil)
            setbuf(stderr, nil)
        }
        try HotKeyDaemon(verbose: verbose).run()
    }
}

do {
    try run()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
