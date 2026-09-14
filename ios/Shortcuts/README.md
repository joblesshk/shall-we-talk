# iOS 快捷指令模板

`voice-input-copy.plist` 是“语音输入并复制”的可审查源文件：语音输入→输出非空条件→拷贝该输出到本机剪贴板→结束条件。动作UUID引用及条件包装已通过官方快捷指令App导入检查。依赖iOS build240或更新版本，手机真实语音交付仍需复测。

本仓库提供可审查模板，不包含个人 iCloud 分享链接。请按下列步骤签名并导入你自己的快捷指令。

在macOS生成可导入文件：

```sh
plutil -convert binary1 -o /tmp/voice-input-copy.shortcut ios/Shortcuts/voice-input-copy.plist
shortcuts sign --mode anyone --input /tmp/voice-input-copy.shortcut --output /tmp/voice-input-copy-signed.shortcut
```

build242起，会议动作内部标识仍为`OpenMeetingRecordsIntent`，显示名为“开始或停止会议录音”。保留标识是为了兼容此前“打开会议记录”的用户绑定，但行为已按用户要求改为第一次开录、再次停止；该会议动作会打开App。普通“语音输入”保持后台模式。
