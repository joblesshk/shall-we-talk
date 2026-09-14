import Foundation
import Darwin
@main struct Benchmark {
 static func footprint() -> Double {
  var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
  return result == KERN_SUCCESS ? Double(info.phys_footprint)/1048576 : -1
 }
 static func main() {
  let before=footprint(), start=ProcessInfo.processInfo.systemUptime
  let e=PinyinEngine();var ready=false;e.loadAsync {ready=true}
  while !ready {RunLoop.main.run(until:Date().addingTimeInterval(0.001))}
  let load=(ProcessInfo.processInfo.systemUptime-start)*1000, after=footprint()
  var samples=["nihao","xiexie","shurufa","rengongzhineng","jijin","womingtianqushanghai","nihaom","nh","xx","xian","nihoa","xiezup","zhonghuarenmingongheguo","zhonghuarenmingongheguoguowuyuan","beijingdaxue","shanghaijiaotongdaxue","yiliaoqixie","jingjitequ","zichanfuzhaibiao","gupiaoshichang","qingbangwofayixiawenjian","zheshiwoxiangyaodeshuru","zzzzzz","aaaaaaaa"]
  if CommandLine.arguments.count > 1,
     let extra = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
      samples += extra.split(separator: "\n").map(String.init)
  }
  let repetitions = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 3 : 3
  var result:[String:Any]=["entries":e.dictionary.loadedEntryCount,"load_ms":load,"load_footprint_mb":after-before,"before_mb":before]
  for mode in [PinyinInputMode.twentySixKey,.nineKey] {
   var times:[Double]=[]
   for _ in 0..<repetitions { for input in samples { e.setInputMode(mode);e.clear()
    let text=mode == .nineKey ? T9KeyMap.code(for:input)! : input
    for c in text {let t=ProcessInfo.processInfo.systemUptime;if mode == .nineKey {e.inputT9Digit(c)} else {e.input(c)};times.append((ProcessInfo.processInfo.systemUptime-t)*1000)}
   }}
   times.sort();result[mode == .nineKey ? "t9" : "pinyin"]=["count":Double(times.count),"p50":times[times.count/2],"p95":times[Int(Double(times.count-1)*0.95)],"p99":times[Int(Double(times.count-1)*0.99)],"max":times.last!]
  }
  result["final_footprint_delta_mb"]=footprint()-before
  print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
 }
}
