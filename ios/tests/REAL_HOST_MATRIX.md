# VoicePen 真实宿主验收矩阵

这套验收把“共享数据正确”和“iOS 真的让宿主收到文本”分开。`VoicePenHost`
是独立开发 App，里面使用真实 `UITextView` / `UITextField` / `UISearchTextField`。
测试时 Shall We Talk 仍由 iOS 作为第三方键盘扩展运行，不嵌入键盘控制器，
不使用 mock `UITextDocumentProxy`。这个 target 不被主 App 依赖，不会进入分发包。

## 自动化矩阵

| 场景 | 宿主条件 | 通过标准 |
|---|---|---|
| 空 `UITextView` | 普通编辑位 | 中英文与 emoji 完整插入 |
| 光标中间 | 已有前后文 | 只在选定光标处插入，前后文不变 |
| 长 Unicode 多行 | 256 组中文、ZWJ emoji、组合字符与换行 | 字符与行结构逐字符相等 |
| 快速连续结果 | 两个不同 request ID | 按发布顺序各插入一次，不丢失、不重复 |
| 单行 `UITextField` | 已有前后文、光标在中间 | 保留前后文并在指定位置插入一次 |
| `UISearchTextField` | 已有搜索词、光标在中间 | 搜索控件收到完整文字且光标位置正确 |

基础事务层另外覆盖：1,024 组长 Unicode、错误 request ID、3 分钟过期、
锁冲突保留、32 个并发消费者仅一个成功，以及 250 次快速连续请求。

## 运行

```bash
# 无系统权限前置，每次都应通过
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ios/tests/pending_text_transaction.sh

# 真实系统键盘宿主矩阵
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ios/tests/real_host_matrix.sh
```

脚本会把当前构建安装到指定模拟器，并自动完成“添加 Shall We Talk 键盘 →
允许完全访问”的系统设置前置；任何一步做不到都会失败，不会把 skip 计为通过。
默认运行 iOS 27.0 的 iPhone Air；也可用 `VOICEPEN_HOST_UDID=<UDID>` 指定一台
已创建的模拟器。真机的系统确认仍须由人手工完成。

## 当前内部验证记录（2026-08-14）

- iOS 26.5 / iPhone 17 Simulator：六个宿主场景分别通过；权限确认测试通过。
- iOS 27.0 / iPhone Air Simulator：`real_host_matrix.sh` 单命令从构建、安装、
  权限确认到六个宿主场景全部通过，0 failure、0 skip。
- 仓库级 `scripts/verify.sh` 通过：115 个 core 测试中 113 通过、2 个依赖真实服务
  凭证的 live 测试按设计跳过；事务并发、键盘集成守卫、iOS 与 macOS 构建均成功。

这些结果证明开发宿主与模拟器系统键盘路径稳定，不替代发布前在备忘录、Safari、
微信和邮件等第三方 App 上的真机人工矩阵。

## 发布前人工宿主补充矩阵

| 宿主 | 最少场景 | 需留存的证据 |
|---|---|---|
| 备忘录 | 长文、多行、光标中间 | 录屏 + 最终文本 |
| Safari | 网页 `textarea` / `contenteditable` | 页面地址 + 录屏 |
| 微信 | 单行、多行、快速连续两次 | 录屏 + 诊断日志 |
| 邮件 | 主题单行 + 正文多行 | 录屏 + 最终文本 |
| 搜索框 | `UISearchTextField` 光标中间 | 录屏 |

密码和其他 secure text fields 不列为失败项：iOS 本来就会禁用第三方键盘。
