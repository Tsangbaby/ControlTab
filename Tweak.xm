// ControlTab — 控制 Safari 标签页
// 由 com.lclrc.controltab 1.0 (iphoneos-arm64e) 二进制逆向还原
//
// 功能：在 Safari 底部工具栏插入一个「垃圾桶」按钮
//   · 单击 → 关闭当前标签页
//   · 长按 → 新建标签页并聚焦地址栏（可直接输入）
//
// 原二进制为 Logos 编译，%ctor / %hook / %new / MSHookMessageEx 可一一对应。
// 本文件按原结构还原（MRR，非 ARC，与原版一致），并修正了原版两处生命周期缺陷。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>

// roothide 路径翻译。原二进制确实链接 @loader_path/.jbroot/usr/lib/libroothide.dylib，
// 并在读取 /var/lib/dpkg/status 前调用了 jbroot()。
// 若要改成非 roothide（rootless / rootful）的包，把下面一行换成恒等实现：
//     static inline NSString *jbroot(NSString *p) { return p; }
extern NSString *jbroot(NSString *path);

#pragma mark - 授权校验常量

// 原版用「控制文件指纹」做安装来源校验：直接读 dpkg 数据库，
// 检查本包的控制信息里是否带有下面这一整行。
// 任何字符不同 → 静默跳过所有 hook（无弹窗、无日志、无任何提示）。
// 重新打包时若 control 里这行被改动，插件会「装上但完全没反应」，改动前务必备份本常量。
static NSString *const kCTDepictionFingerprint =
    @"SileoDepiction: https://lclrc.github.io/repo/depictions/native/com.lclrc.controltab/depiction.json";

static NSString *const kCTDpkgStatusPath = @"/var/lib/dpkg/status";

#pragma mark - 私有 API 声明

@interface TabController : NSObject
- (NSArray *)_currentTabs;                 // 原版只把它当作「控制器就绪」的时机
- (void)_newTabFromTabViewButton;          // 从标签页总览左下角「＋」新建标签
- (id)activeTabDocument;                   // 当前标签页的 TabDocument
- (void)closeTab;                          // Safari 原有：关闭当前标签
@end

@interface BrowserToolbar : UIView
- (void)setItems:(NSArray *)items;
@end

@interface BrowserController : NSObject
// 模拟「点了一下地址栏」，用于新建标签后把光标放进 URL 输入框
- (void)navigationBarURLWasTapped:(id)sender completionHandler:(id)handler;
@end

// Safari 给 UIBarButtonItem 加的私有分类方法：为同一个按钮再挂一个长按 action
@interface UIBarButtonItem (ControlTabPrivate)
- (void)_sf_setTarget:(id)target longPressAction:(SEL)action;
@end

#pragma mark - 全局状态

// 改写后的工具栏 items。原版位于 __common 段（零初始化）。
static NSMutableArray *gToolbarItems = nil;

// 原版用它保证通知只注册一次（见报告「已知缺陷 #3」）
static dispatch_once_t gObserverOnceToken;

// 本插件自定义的两个通知名，用于把「工具栏按钮点击」转发给 TabController
static NSString *const kCTNotificationOpenNewTab = @"openNewTabFromCustomTrashButton";
static NSString *const kCTNotificationCloseTab  = @"closeTabFromCustomTrashButton";

#pragma mark - 授权校验

static BOOL CTPassedInstallCheck(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *statusPath = jbroot(kCTDpkgStatusPath);

    if (![fm fileExistsAtPath:statusPath]) {
        return NO;
    }

    NSString *status = [NSString stringWithContentsOfFile:statusPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    if (status.length == 0) {
        return NO;
    }

    NSRange r = [status rangeOfString:kCTDepictionFingerprint];
    return r.location != NSNotFound;
}

#pragma mark - Hooks

%group ControlTabHooks

%hook TabController

// 原版把「注册通知」挂在 _currentTabs 上：这是 TabController 最早被稳定调用的时机之一。
// 必须原样返回 %orig。
- (NSArray *)_currentTabs
{
    dispatch_once(&gObserverOnceToken, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self
               selector:@selector(newTabAndType)
                   name:kCTNotificationOpenNewTab
                 object:nil];
        [nc addObserver:self
               selector:@selector(closeTab)
                   name:kCTNotificationCloseTab
                 object:nil];
    });

    return %orig;
}

// 长按垃圾桶 → 新建标签并把光标放进地址栏
%new
- (void)newTabAndType
{
    // 触感反馈：UIImpactFeedbackStyleSoft == 3（原版硬编码 3）
    UIImpactFeedbackGenerator *generator =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
    [generator prepare];
    [generator impactOccurred];

    // 走 Safari 自己的「＋」路径，保证新标签的类型 / 位置 / 动画与系统一致
    [self _newTabFromTabViewButton];

    // 直接取 ivar：TabDocument 的 _browserController，
    // 再调私有方法模拟点击地址栏，从而自动聚焦输入框。
    // 原版此处有一次多余的 release（对同一对象释放两次），已修正。
    id document = [self activeTabDocument];
    Ivar ivar = class_getInstanceVariable(object_getClass(document), "_browserController");
    if (ivar != NULL) {
        id *slot = (id *)((char *)document + ivar_getOffset(ivar));
        id browserController = *slot;
        if (browserController != nil) {
            [browserController navigationBarURLWasTapped:nil completionHandler:nil];
        }
    }

    [generator release];
}

// 控制器销毁时摘掉通知，避免向已释放对象回调。
// 原版顺序是「先 %orig 再 removeObserver:self」，属 use-after-free，此处已纠正。
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    %orig;
}

%end


%hook BrowserToolbar

- (void)setItems:(NSArray *)items
{
    // mutableCopy 带 +1，随后直接交给全局变量持有（与原版一致）
    NSMutableArray *mutableItems = [items mutableCopy];
    if (mutableItems == nil) {
        %orig;
        return;
    }

    [gToolbarItems release];
    gToolbarItems = mutableItems;

    // 垃圾桶图标：UIBarButtonSystemItemTrash == 16（原版硬编码 16）
    UIBarButtonItem *trashItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                     target:self
                                                     action:@selector(closeTab)];

    // Safari 私有能力：给同一个按钮再挂一个长按 action。
    // 若系统没有这个方法（未来版本被移除）就退化为「只有单击」。
    if ([trashItem respondsToSelector:@selector(_sf_setTarget:longPressAction:)]) {
        [trashItem _sf_setTarget:self longPressAction:@selector(newTab)];
    }

    // 插到倒数第 3 个位置：位于「分享 / 书签」之前，右侧原有两个按钮位置不变。
    // 原版未做越界保护，items 少于 3 个时 atIndex 为负数会抛异常，此处已加钳制。
    NSInteger index = (NSInteger)[gToolbarItems count] - 3;
    if (index < 0) index = 0;
    if (index > (NSInteger)[gToolbarItems count]) index = (NSInteger)[gToolbarItems count];
    [gToolbarItems insertObject:trashItem atIndex:(NSUInteger)index];

    [trashItem release];

    // 注意：原版传给原实现的是「改过的数组」，不是入参 items
    %orig(gToolbarItems);
}

// 单击垃圾桶：只广播通知，真正的关闭动作交给 TabController 自己的 closeTab
%new
- (void)newTab
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kCTNotificationOpenNewTab
                                                        object:self];
}

%new
- (void)closeTab
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kCTNotificationCloseTab
                                                        object:self];
}

%end

%end // ControlTabHooks


#pragma mark - 入口

%ctor
{
    @autoreleasepool {
        // 原版：校验不通过就整体不 hook，且没有任何提示
        if (!CTPassedInstallCheck()) {
            return;
        }

        %init(ControlTabHooks);
    }
}
