# ControlTab（逆向还原工程）

Safari 工具栏「垃圾桶」按钮：**单击关标签页 / 长按新建标签页并聚焦地址栏**。

本工程由 `com.lclrc.controltab_1.0_iphoneos-arm64e.deb` 逆向还原，
原二进制为 **Logos / ObjC++（.xm）** 编译，功能与结构 1:1 对齐。
详细取证见 [`逆向还原报告.md`](./逆向还原报告.md)。

---

## 目录结构

```
ControlTab/
├── Makefile                  # roothide 方案 / arm64+arm64e / min iOS 15.0 / MRR
├── Tweak.xm                  # 全部源码（约 200 行，含逐段注释）
├── ControlTab.plist          # 注入过滤器：仅 com.apple.mobilesafari
├── control                   # Debian 控制信息（★ 含授权指纹，勿随意改）
└── 逆向还原报告.md
```

---

## 构建

原版是 **roothide** 环境（链接 `libroothide` 并调用 `jbroot()`），所以需要用
[roothide/Theos](https://github.com/roothide/theos) 分支，普通 Theos 会因 `jbroot` 未定义而链接失败。

```bash
export THEOS=~/theos
export PATH=$THEOS/bin:$PATH

cd ControlTab
make clean package
# 产物：packages/com.lclrc.controltab_1.0_iphoneos-arm64e.deb
```

需要 **iPhoneOS SDK ≥ 15.0**（原版 minos 15.0）。

### 改成 rootless / rootful

1. `Tweak.xm` 顶部把 `extern NSString *jbroot(NSString *path);` 换成
   ```objc
   static inline NSString *jbroot(NSString *p) { return p; }
   ```
2. `Makefile` 删掉 `export THEOS_PACKAGE_SCHEME = roothide`。

---

## 安装与调试

```bash
make install            # 默认重启 MobileSafari
# 或手动
scp .theos/obj/debug/ControlTab.dylib root@device:/var/jb/Library/MobileSubstrate/DynamicLibraries/
```

看注入是否成功：

```bash
# 确认 dylib 被加载
ssh root@device "grep -i controltab /var/jb/var/mobile/Library/Logs/... 2>/dev/null"
ssh root@device "ps aux | grep MobileSafari"

# 直接看进程里有没有我们的镜像
ssh root@device "cat /proc/\$(pgrep -f MobileSafari | head -1)/maps | grep -i controltab"
```

> 注意：**`ControlTab.dylib` 被加载 ≠ 功能生效**。加载成功但按钮不出现，
> 99% 是第五节说的授权校验没过（静默 return）。见下面「排错」。

---

## ⚠️ 排错第一顺位：授权校验

`%ctor` 在注册任何 hook 之前，会读 `/var/lib/dpkg/status` 并搜索这一整行：

```
SileoDepiction: https://lclrc.github.io/repo/depictions/native/com.lclrc.controltab/depiction.json
```

**搜不到就直接 return，不 hook、不打印、不弹窗。**

所以「装上但毫无反应」时，先手动确认这行在不在：

```bash
ssh root@device "grep -A1 -i '^Package: com.lclrc.controltab' /var/jb/var/lib/dpkg/status | head"
ssh root@device "grep -c 'lclrc.github.io/repo/depictions/native/com.lclrc.controltab' /var/jb/var/lib/dpkg/status"
```

返回 `0` 就是没命中。常见原因：

- 重新打包时 `control` 里的 `SileoDepiction` 被改了 / 被吃了；
- 用 `dpkg -i` 装的 deb，其 `control` 与上面不一致；
- roothide 的 jbroot 路径不对（插件用了 `jbroot()` 翻译，路径是对的，但如果你手动改过 dpkg 位置就会失配）。

**一致性规则：`control` 里那行 与 `Tweak.xm` 的 `kCTDepictionFingerprint` 必须永远逐字相同。**
换 depiction 地址时两处一起改。

开发期建议临时关掉：

```objc
// Tweak.xm 的 %ctor 里
if (!CTPassedInstallCheck()) return;   // ← 调试时注释掉这一行
```

---

## 常见改动指引

| 想改什么 | 改哪里 |
|---|---|
| 按钮图标（默认垃圾桶） | `setItems:` 里 `UIBarButtonSystemItemTrash` |
| 按钮位置（默认倒数第 3） | `setItems:` 里 `count - 3` |
| 触感强度（默认 Soft） | `newTabAndType` 里 `UIImpactFeedbackStyleSoft` |
| 长按行为 | `BrowserToolbar.newTab` → 通知 → `TabController.newTabAndType` |
| 单击行为 | `BrowserToolbar.closeTab` → 通知 → `TabController.closeTab` |
| 只在某些模式生效（如仅无痕） | 在 `newTabAndType` 开头加判断 |
| 适配多窗口 / iPad | 修 `dispatch_once` 全局 token，改为按实例注册（见报告缺陷 #3） |

---

## 与原版的差异

功能语义完全一致，仅修了 4 处会崩溃的路径（过释放、UAF、空指针、负下标）。
逐条对照表见报告第七节。若你要和线上版本做行为比对，注意只有「异常路径」不同。
