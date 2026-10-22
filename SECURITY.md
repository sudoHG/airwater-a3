# Security and privacy

这是实验性的单设备、本地控制器。它不是公网 MQTT 服务，也不是多用户家庭网关。

- 当前 DNS 会拒绝原厂两个域名及测试域名以外的查询。个人热点仅用于 A3；其他设备自动加入可能受到影响。结束后关闭个人热点，恢复系统正常服务。退出后的系统 DNS 恢复尚未跨设备验证。
- HTTP/MQTT 只允许热点子网客户端；这不是完整的设备身份隔离。原厂协议使用 HTTP 和未加 TLS 的 MQTT，消息签名不等于加密。请勿转发这些端口到互联网，勿向不信任的设备分享热点。
- Wi-Fi 凭据经蓝牙交给选中的设备。源码没有应用层配网加密；蓝牙链路层加密能力尚未核实。
- 设备密钥保存在本机 `WhenUnlockedThisDeviceOnly` Keychain；未启用 iCloud 同步。状态与诊断可能写入 App 沙盒。当前没有开发者云端、广告或分析上传。卸载 App 不应被当作已确认删除 Keychain 数据的方法。
- 当前后台执行有限，不能保证锁屏后连接。服务断开不等于设备关机；应以设备本身的状态为准。

## 报告问题

普通复现步骤可在 GitHub Issue 提交。安全漏洞或可能包含敏感数据的报告，请发送到维护者的公开联系邮箱 **by331works@gmail.com**；不要在公开 Issue 中粘贴凭据。

不要提交 Wi-Fi 密码、设备 key、MAC/蓝牙标识、完整 Flash/NVS、原始抓包、配网截图或未脱敏的诊断日志。固件研究仅需要确认不包含个人配置的程序分区；先描述来源、型号和提取范围，不要直接上传整机备份。报告漏洞不需要运行未知 OTA 或绕过机器保护。

This is an experimental, single-device local controller. Do not expose its services to the internet. Report security issues privately to the email above; omit credentials, device identifiers, full flash dumps and raw captures from public issues. A disconnected app does not mean the humidifier is powered off.
