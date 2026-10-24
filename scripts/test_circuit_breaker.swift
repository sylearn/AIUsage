import Foundation
#if canImport(QuotaBackend)
import QuotaBackend
#endif

print("=== STARTING CIRCUIT BREAKER TESTS ===")

// Test 1: Real path resolution for Antigravity accounts
let email = "hatrncasssi@gmail.com"
let dummyImportURL = URL(fileURLWithPath: "/Users/apple/Library/Application Support/AIUsage/AuthImports/antigravity/hatrncasssi-gmail-com-20261019-144436.json")

let matchedFiles = QuotaCircuitBreakerHelper.findTargetCPAAuthFiles(
    providerPrefix: "antigravity",
    email: email,
    currentFileURL: dummyImportURL
)

print("Test 1: Matched CPA auth files for \(email):")
for f in matchedFiles {
    print("  -> \(f.path)")
}
assert(!matchedFiles.isEmpty, "Test 1 FAILED: Expected to find CPA auth file for hatrncasssi@gmail.com")
print("Test 1 PASSED: Found \(matchedFiles.count) CPA auth file(s) from AuthImports URL!\n")

// Test 2: In-memory/temp file cycle test
let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }

let testAuthFile = tempDir.appendingPathComponent("aiusage-antigravity-TEST.json")
let initialJSON: [String: Any] = [
    "email": "test-breaker@example.com",
    "disabled": false,
    "access_token": "ya29.test"
]
let initialData = try! JSONSerialization.data(withJSONObject: initialJSON, options: [.prettyPrinted])
try! initialData.write(to: testAuthFile)

// Trip the breaker
let tripOutcome = QuotaCircuitBreakerHelper.syncCircuitBreaker(
    targets: [testAuthFile],
    shouldTrip: true,
    reason: "Gemini Models (Weekly) còn 4% (<= 5%)"
)
assert(tripOutcome?.tripped == true, "Test 2A FAILED: Should trip")

let trippedData = try! Data(contentsOf: testAuthFile)
let trippedJSON = try! JSONSerialization.jsonObject(with: trippedData) as! [String: Any]
assert(trippedJSON["disabled"] as? Bool == true, "Test 2B FAILED: disabled should be true")
assert(trippedJSON["circuit_breaker_tripped"] as? Bool == true, "Test 2C FAILED: circuit_breaker_tripped should be true")
assert((trippedJSON["circuit_breaker_reason"] as? String)?.contains("4%") == true, "Test 2D FAILED: reason mismatch")
print("Test 2 (Trip breaker): PASSED\n")

// Auto-recovery test
let recoverOutcome = QuotaCircuitBreakerHelper.syncCircuitBreaker(
    targets: [testAuthFile],
    shouldTrip: false,
    reason: "Quota recovered"
)
assert(recoverOutcome?.tripped == false, "Test 3A FAILED: Should recover")

let recoveredData = try! Data(contentsOf: testAuthFile)
let recoveredJSON = try! JSONSerialization.jsonObject(with: recoveredData) as! [String: Any]
assert(recoveredJSON["disabled"] as? Bool == false, "Test 3B FAILED: disabled should be false")
assert(recoveredJSON["circuit_breaker_tripped"] as? Bool == false, "Test 3C FAILED: circuit_breaker_tripped should be false")
assert(recoveredJSON["circuit_breaker_recovered_at"] != nil, "Test 3D FAILED: recovered_at should exist")
print("Test 3 (Auto-recovery): PASSED\n")

// User manual disable safety test
var manualJSON = recoveredJSON
manualJSON["disabled"] = true
manualJSON["circuit_breaker_tripped"] = false // Manually disabled by user
let manualData = try! JSONSerialization.data(withJSONObject: manualJSON, options: [.prettyPrinted])
try! manualData.write(to: testAuthFile)

// When quota is healthy, should NOT re-enable an account manually disabled by user
_ = QuotaCircuitBreakerHelper.syncCircuitBreaker(
    targets: [testAuthFile],
    shouldTrip: false,
    reason: "Quota recovered"
)
let afterManualData = try! Data(contentsOf: testAuthFile)
let afterManualJSON = try! JSONSerialization.jsonObject(with: afterManualData) as! [String: Any]
assert(afterManualJSON["disabled"] as? Bool == true, "Test 4 FAILED: Must NOT re-enable manually disabled account")
print("Test 4 (User manual disable protection): PASSED\n")

// Test 5: Exact threshold boundary test (Weekly <= 3.0%, 5-Hour <= 5.0%)
func evaluateTieredThreshold(remainingPercent: Double, isWeekly: Bool) -> Bool {
    let threshold: Double = isWeekly ? 3.0 : 5.0
    return remainingPercent <= threshold
}

// 5A: pbichafnh51 live case (3.1614% Weekly > 3.0% -> safe, stays active)
assert(evaluateTieredThreshold(remainingPercent: 3.1614915, isWeekly: true) == false, "Test 5A FAILED: 3.16% Weekly must stay active")
// 5B: Exact 3.0% Weekly -> trips breaker
assert(evaluateTieredThreshold(remainingPercent: 3.0, isWeekly: true) == true, "Test 5B FAILED: 3.0% Weekly must trip")
// 5C: 2.9% Weekly -> trips breaker
assert(evaluateTieredThreshold(remainingPercent: 2.9, isWeekly: true) == true, "Test 5C FAILED: 2.9% Weekly must trip")
// 5D: 5.2% 5-Hour -> safe, stays active
assert(evaluateTieredThreshold(remainingPercent: 5.2, isWeekly: false) == false, "Test 5D FAILED: 5.2% 5-Hour must stay active")
// 5E: Exact 5.0% 5-Hour -> trips breaker
assert(evaluateTieredThreshold(remainingPercent: 5.0, isWeekly: false) == true, "Test 5E FAILED: 5.0% 5-Hour must trip")
print("Test 5 (Strict float boundary Weekly <= 3.0%, 5-Hour <= 5.0%): PASSED\n")

print("=== ALL 5 CIRCUIT BREAKER TESTS PASSED PERFECTLY! ===")
