# 构建与安装 / Build and install

这是源码分发，需要 Mac、Xcode 和自己的 Apple 开发签名。仓库不包含 IPA、描述文件、签名安装包或他人的开发证书。普通用户目前不能从仓库直接安装一个已分发的 App。

## 环境

- macOS 和 Xcode 27（包含 iOS 27 SDK）。源码引用 iOS 27 的条件 API；把部署目标设为 iOS 16 不代表旧 SDK 能编译。
- XcodeGen。安装方式参见 [XcodeGen 官方说明](https://github.com/yonaskolb/XcodeGen)。
- Python 3，用于快捷指令生成和发布目录检查。
- 工程部署目标为 iOS 16；实际设备记录仅覆盖 iPhone 17 Pro Max / iOS 27.0。旧系统运行和快捷指令兼容性尚未确认。

## 生成工程

```sh
git clone https://github.com/sudoHG/airwater-a3.git
cd airwater-a3
make generate
open AirwaterProbe.xcodeproj
```

在 Xcode 的 Signing & Capabilities 选择自己的 Team，并把 Bundle Identifier 改为自己的唯一标识。也可以先修改 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER` 再生成；重新生成工程会覆盖只在 Xcode 中修改的设置。不要把个人签名信息加入提交。

用数据线连接并解锁 iPhone，在 Xcode 选择这台手机后运行。按系统要求启用开发者模式、信任签名。不同开发账号的签名有效期与能力由 Apple 决定；源码开源不会消除这些限制。

Mac 只负责编译和 USB 安装，保持现有网络，不加入 iPhone 热点，不改 Mac 的 Wi-Fi、DNS 或路由。模拟器可用于界面/编译检查，不能验收真实 A3 的蓝牙及个人热点连接。

## 可选：生成快捷指令

`Shortcuts/` 包含可审查的 XML 模板，个人 Team ID 已替换成占位符。用与安装版相同的 Bundle ID 和 Team ID 生成：

```sh
python3 scripts/prepare_shortcuts.py \
  --bundle-id com.example.airwater \
  --team-id YOURTEAMID \
  --sign
make generate
```

`YOURTEAMID` 是示意值，请替换成自己的 10 位 Team ID。`--sign` 调用 macOS 自带的 `shortcuts sign`；可能需要本机 Shortcuts/iCloud 的正常配置。脚本仅生成和签名文件，不执行快捷指令、不切换任何网络。生成的个人文件受 `.gitignore` 排除。签名失败时可在 iPhone 上手动建立流程。

重新构建后，App 内可分享/添加「连接 A3」快捷指令。首次允许 Shortcuts 调用 App。编译成功不能保证换签名后的自动化在另一台手机上已验证。

手动建立一个名为「连接 A3」的快捷指令，顺序为：

1. 系统「设定个人热点」：关闭。
2. 本 App「准备 A3 连接」。
3. 系统「设定个人热点」：打开。
4. 本 App「打开 A3 控制页」，将「连接编号」绑定到第 2 步输出。

只想手动控制时，可以跳过快捷指令：关闭手机热点 → App 中「手动连接 / 准备本地服务」→ 服务就绪后开启手机热点 → 返回 App。首次需在手机系统设置中开启热点的「最大兼容性」，再使用 App 的蓝牙配网页交给 A3 热点名称和密码。

## 验证

```sh
make check
make build
```

`make check` 检查待公开文件、敏感文件类型、模板结构和隐私清单。它不是完整秘密扫描或真机测试。

`make build` 生成工程并执行不签名的 iOS 编译；默认要求 Data 卷至少空余 80 GiB，构建目录为 `.derivedData/opensource`。它不会安装、启动 App、改变网络或向 A3 发送命令。构建结束且没有相关编译进程使用该目录后，可删除这一任务目录释放空间。

2026-10-22 已用 Xcode 27.0 / iOS 27 SDK 验证该公开工程的 `make build` 成功；未做新的真机控制测试。快捷指令模板已使用示例身份生成并检查动作顺序与参数引用，未对公开版本执行签名或手机导入验收。

现有 `--run-self-check` 是仅解析器/合成数据检查；它在 App 沙盒写入结果。`--run-connection-checks` 会实际绑定网络监听端口，不能把它当作纯离线测试。调试参数 `--verify-power-roundtrip` 会真实改变设备电源；不要作为安装或验证默认参数，也不要在缺水、脏污或状态不明的设备上运行。正常无参数启动不会自动执行这些测试。

## English quick guide

Use Xcode 27, XcodeGen and Python 3. Run `make generate`, open the generated project, set your own development team and unique bundle identifier, and install over USB. Keep the Mac on its existing network. No pre-signed app is distributed.

For the optional shortcut, run `scripts/prepare_shortcuts.py` with the **same** bundle/team identifiers and `--sign`, regenerate the project, then rebuild. Alternatively create the four-action workflow on the iPhone: hotspot off → Prepare A3 Connection → hotspot on → Open A3 Control Page (pass the preparation token). The manual connection path also works without Shortcuts.

`make build` compiles without signing, installation or device/network operations. Only one iPhone/iOS/A3 combination has historical hardware validation; compilation is not a hardware compatibility test.
