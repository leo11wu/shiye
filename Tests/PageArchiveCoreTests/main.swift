import Foundation

do {
    let root=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "/private/tmp/shiye-tests-\(UUID().uuidString)")
    let results=try runScenarios(root:root)+runBookConversionScenarios(root:root)
        + runPageWorkQueueScenarios(root:root)+runCancelExportScenarios(root:root)
        + runOCRAgentScenarios(root:root)
    let output=results.map{["name":$0.0,"passed":$0.1,"detail":$0.2] as [String:Any]}
    try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("test-results.json"),options:.atomic)
    print("\(results.filter{$0.1}.count)/\(results.count) checks passed")
    exit(results.allSatisfy{$0.1} ? 0 : 1)
} catch {print(error);exit(1)}
