# ControlTab（Safari 标签页按钮维护工程）

目标功能：Safari 工具栏中的垃圾桶按钮，单击关闭当前标签页，长按新建标签并尝试聚焦地址栏。功能描述来自随仓库导入的逆向材料；除静态源码检查和云端构建外，当前维护候选尚未完成真机功能验证，因此不据此宣称已兼容全部 iOS 15+ 版本。

原始导入提交 `38cf5e33fb155347a1779ad84f3559e05ad0829e` 保留在 Git 历史中；当前默认且唯一维护分支为 `main`。第一阶段维护候选已合并，当前包版本 `1.0.1~dev1` 仍为设备测试候选，不代表正式发布。

---

## 目录结构

```
ControlTab/
├── Makefile                  # roothide 方案 / arm64+arm64e / min iOS 15.0 / MRR
├── Tweak.xm                  # Logos hooks、运行时门禁与短注释
├── ControlTab.plist          # 注入过滤器：仅 com.apple.mobilesafari
├── control                   # Debian 控制信息，包门禁依赖 SileoDepiction
├── tests/source_contract.py  # 不依赖 SDK 的静态/契约检查
└── .github/workflows/build.yml # 固定工具链的云端 Mac 构建与验包
```

---

## 构建

本项目只维护 roothide 包。最低部署目标为 iOS 15.0，不构成跨版本兼容承诺。CI 使用 macOS 14 / Xcode 15.4、固定 roothide/Theos 提交和官方 SDK 资产 `iPhoneOS16.5.sdk.tar.xz`（资产内部 `SDKSettings.plist` 及产物 `LC_BUILD_VERSION` 标记为 iOS SDK 16.4）；先执行源码测试，再构建并检查 Debian 元数据、包内容、Mach-O 架构和部署/SDK 标记，成功后上传 CI artifact。CI 不会安装设备、respring 或创建 Release。

本地构建要求相同 Xcode、Theos、SDK、GNU make、ldid 和 xz：

```bash
export THEOS="$HOME/theos"
export PATH="$THEOS/bin:$PATH"
gmake clean package FINALPACKAGE=1
```

锁定详情见 [Makefile](./Makefile) 与 [GitHub Actions workflow](./.github/workflows/build.yml)。更新工具链时必须同步更新版本/哈希并重新验包，避免使用 `latest` 漂移。

## 包与兼容性边界

包身份仍为 `com.lclrc.controltab`。`1.0.1~dev1` 是维护候选版本，不代表正式发布。安装门禁保留原 `SileoDepiction` 字段，但现在限定匹配本包的 dpkg status 记录；它不是签名或来源认证。修改 `control` 或源码中的指纹常量时需同步更新测试。

Safari 私有类、selector、ivar 和工具栏布局可能随系统变化。CI 只证明在固定工具链下可编译且通过静态包门禁，不证明注入或功能正确。多窗口通知路由尚未解决：当前全局一次性 observer 缺少 toolbar 到所属 TabController 的可靠映射。设备验证前不可简单改为每个控制器都监听，否则广播可能让多个窗口同时执行操作。

## 安装与调试

本仓库不提供自动设备安装步骤。CI artifact 是供审阅及经设备负责人确认后手动测试的候选包。iOS 不支持 README 旧版 Linux `/proc/<pid>/maps` 诊断；注入、私有 API 和功能结果必须通过目标设备的可用诊断方式独立验证。加载 dylib 不代表按钮功能已生效。

## 常见改动指引

| 想改什么 | 位置 |
|---|---|
| 按钮图标或相对插入位置 | `Tweak.xm` 的 `setItems:` |
| 长按行为 | `BrowserToolbar.newTab` / `TabController.newTabAndType` |
| 单击行为 | `BrowserToolbar.closeTab` / `TabController.closeTab` |
| 支持新的系统版本 | 先记录 Safari 类/方法/ivar 的设备 ABI，再更新支持矩阵与测试；不要仅改最低部署目标 |

## 维护与授权边界

导入仓库没有附带 LICENSE 文件。源码的长期维护、公开分发及包身份/署名沿用前，应先核实原作者或权利方授权；本分支不新增或推定许可证。

## 与导入基线的差异

原始导入和逆向材料保留在 `import/source-1.0`。本分支增加仅针对本插件按钮的关联标记去重、移除全局 toolbar items 保留、按包记录检查安装字段、hook 前私有 API 存在性门禁、固定云端工具链与包门禁。未据静态材料宣称修复 MRR 对象所有权问题；相关计数与报告存在不一致，需后续以原始二进制和设备运行时复核。
