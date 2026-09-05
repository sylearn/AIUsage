import Foundation
import os.log

// 运行器直接提取并编译正式方法；这里只替换进程、存储与网络响应边界。
// 不启动 App、不读取账号、不访问真实代理或上游。
let globalProxyManagerLog = Logger(subsystem: "com.aiusage.regression", category: "Manager")
let globalProxyRuntimeLog = Logger(subsystem: "com.aiusage.regression", category: "Runtime")

enum TestTrack: String { case codex, desktop }
struct TestConfig { var activeNodeId: String? = "node-a" }
struct TestNode { let id: String; let name: String }
struct TestAdapter {
    func switchPayload(config: TestConfig, nodeId: String) -> [String: Any]? { ["node_id": nodeId] }
    func adminPath(config: TestConfig) -> String { "/__aiusage/admin/codex-upstream" }
}
extension Notification.Name {
    static let claudeGatewayActiveNodeDidChange = Notification.Name("regression.gateway.changed")
}
final class AppSettings {
    static let shared = AppSettings()
    func t(_ en: String, _ zh: String) -> String { zh }
}

@MainActor final class GlobalProxyRuntime {
    var isProcessRunning = true
    var adminKey: String? = "fixture-admin-key"
    var listenPort = 48999
    let adminPath = "/__aiusage/admin/codex-upstream"
    var activeNodeId: String? = "node-a"
    var activeNodeName: String? = "Node A"
    let track = TestTrack.codex
}

@MainActor final class GlobalProxyManager {
    let runtime = GlobalProxyRuntime()
    let adapter = TestAdapter()
    var config = TestConfig()
    var isBusy = false
    var operationError: String?
    var isRuntimeEnabled = true
    let track = TestTrack.codex
    func node(for id: String?) -> TestNode? { id.map { TestNode(id: $0, name: $0) } }
}

@MainActor final class CLIProxyGatewayManager {
    let gateway = GlobalProxyManager()
    var persistedNodeID: String?
    var operationErrorMessage: String?
    var applyCount = 0

    // 对应正式分发路径的边界：先保存节点，再通过正式 reapply 方法更新运行时。
    func applyManagedProvider(targets: Set<String>) async {
        applyCount += 1
        persistedNodeID = targets.first
        gateway.config.activeNodeId = persistedNodeID
        await gateway.reapplyActiveUpstream()
        operationErrorMessage = gateway.operationError
    }
}

final class AdminResponseProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case success, failure(URLError.Code), rejected }
    static var reply = Reply.success
    static var onStarted: (() -> Void)?
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.port == 48999
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.reply
        Self.onStarted?()
        // 保留一个请求挂起窗口，在明确开始之后取消页面任务。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            switch reply {
            case .failure(let code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case .success, .rejected:
                let status = if case .rejected = reply { 503 } else { 200 }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

@main struct GlobalProxyCancellationRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    @MainActor static func main() async {
        do {
            try expect(URLProtocol.registerClass(AdminResponseProtocol.self), "无法安装隔离网络响应")
            defer { URLProtocol.unregisterClass(AdminResponseProtocol.self) }

            // CPA 已开始保存/下发时切页：事务必须继续，磁盘和运行时最终一致，且无错误弹窗。
            let manager = CLIProxyGatewayManager()
            let page = Task { await manager.upsertManagedProvider(targets: ["node-b"]) }
            AdminResponseProtocol.onStarted = { page.cancel() }
            await page.value
            try expect(page.isCancelled, "测试必须实际取消页面任务")
            try expect(manager.persistedNodeID == "node-b", "节点没有保存")
            try expect(manager.operationErrorMessage == nil && manager.gateway.operationError == nil,
                       "切页出现错误弹窗：\(manager.operationErrorMessage ?? manager.gateway.operationError ?? "")")
            try expect(manager.gateway.runtime.activeNodeId == "node-b", "切页后运行时未完成下发")
            try expect(!manager.gateway.isBusy, "切页后忙状态未释放")
            AdminResponseProtocol.onStarted = nil
            print("PASS: 页面取消后分发完成，配置与运行时一致，无错误弹窗")

            // 页面在事务开始前已经取消：不能再开启写配置操作。
            let abandoned = CLIProxyGatewayManager()
            let cancelledPage = Task { await abandoned.upsertManagedProvider(targets: ["node-b"]) }
            cancelledPage.cancel()
            await cancelledPage.value
            try expect(abandoned.applyCount == 0, "已取消页面仍启动分发")
            print("PASS: 已取消页面不启动新事务")

            // 非分发调用仍允许取消，但不能把 URLSession 的 -999 包装成不可达。
            let gateway = GlobalProxyManager()
            gateway.config.activeNodeId = "node-b"
            let reapply = Task { await gateway.reapplyActiveUpstream() }
            AdminResponseProtocol.onStarted = { reapply.cancel() }
            await reapply.value
            try expect(reapply.isCancelled, "请求中取消场景未触发")
            try expect(gateway.operationError == nil && !gateway.isBusy, "请求取消被显示为故障或忙状态未复位")
            try expect(gateway.runtime.activeNodeId == "node-a", "被取消的请求提前改变运行态")
            AdminResponseProtocol.onStarted = nil
            print("PASS: 请求中取消不冒充网络故障")

            AdminResponseProtocol.reply = .failure(.cancelled)
            await gateway.reapplyActiveUpstream()
            try expect(gateway.operationError == nil && !gateway.isBusy, "URLSession -999 未保留取消语义")
            print("PASS: 独立 URLError.cancelled 正确分类")

            AdminResponseProtocol.reply = .failure(.cannotConnectToHost)
            await gateway.reapplyActiveUpstream()
            try expect(gateway.operationError?.contains("admin 端点不可达") == true, "真正的连接失败被吞掉")
            try expect(!gateway.isBusy, "网络失败后忙状态未复位")
            AdminResponseProtocol.reply = .rejected
            await gateway.reapplyActiveUpstream()
            try expect(gateway.operationError?.contains("503") == true, "HTTP 拒绝被吞掉")
            print("PASS: 真正连接失败与 HTTP 503 仍然报错")

            AdminResponseProtocol.reply = .success
            await gateway.reapplyActiveUpstream()
            try expect(gateway.operationError == nil && gateway.runtime.activeNodeId == "node-b", "重试成功后错误未清除")
            print("PASS: 后续重试可成功并清除错误")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
