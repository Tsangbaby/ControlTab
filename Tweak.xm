// ControlTab — 控制 Safari 标签页
// 由 com.lclrc.controltab 1.0 (iphoneos-arm64e) 二进制逆向还原
//
// 功能：在 Safari 底部工具栏插入一个「垃圾桶」按钮
//   · 单击 → 关闭当前标签页
//   · 长按 → 新建标签页并聚焦地址栏（可直接输入）
//
// 原二进制为 Logos 编译，%ctor / %hook / %new / MSHookMessageEx 可一一对应。
// 本文件按原结构还原（MRR，非 ARC）。私有 API 与对象所有权仍需按目标 Safari 版本验证；
// 下方只做可静态确认的防护，不把静态分析当作运行时兼容证明。

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

// 插件不保留 toolbar items 的进程级副本，避免不同 toolbar 互相覆盖状态。

// 原版用它保证通知只注册一次（多窗口路由仍待设备侧解决）
static dispatch_once_t gObserverOnceToken;

// 本插件自定义的两个通知名，用于把「工具栏按钮点击」转发给 TabController
static NSString *const kCTNotificationOpenNewTab = @"openNewTabFromCustomTrashButton";
static NSString *const kCTNotificationCloseTab  = @"closeTabFromCustomTrashButton";

// 只标记本插件创建的 UIBarButtonItem，供 setItems: 重入时幂等去重。
// 使用 key 的地址作为关联对象键，不靠图标或 selector 猜测按钮归属。
static char kCTInjectedButtonKey;

static BOOL CTIsInjectedButton(id item)
{
    return [item isKindOfClass:[UIBarButtonItem class]] &&
           objc_getAssociatedObject(item, &kCTInjectedButtonKey) != nil;
}

static void CTRemoveInjectedButtons(NSMutableArray *items)
{
    NSInteger index = (NSInteger)[items count] - 1;
    for (; index >= 0; index--) {
        id item = [items objectAtIndex:(NSUInteger)index];
        if (CTIsInjectedButton(item)) {
            [items removeObjectAtIndex:(NSUInteger)index];
        }
    }
}

#pragma mark - 授权校验

static BOOL CTPassedInstallCheck(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *statusPath = jbroot(kCTDpkgStatusPath);
    if (![fm fileExistsAtPath:statusPath]) {
        return NO;
    }

    NSError *error = nil;
    NSString *status = [NSString stringWithContentsOfFile:statusPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
    if (status.length == 0 || error != nil) {
        return NO;
    }

    NSString *normalized = [status stringByReplacingOccurrencesOfString:@"\r\n"
                                                             withString:@"\n"];
    NSArray *records = [normalized componentsSeparatedByString:@"\n\n"];
    for (NSString *record in records) {
        BOOL isTargetPackage = NO;
        BOOL hasExpectedDepiction = NO;
        NSArray *lines = [record componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line hasPrefix:@"Package:"]) {
                NSString *packageName = [[line substringFromIndex:8]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                isTargetPackage = [packageName isEqualToString:@"com.lclrc.controltab"];
            } else if ([line isEqualToString:kCTDepictionFingerprint]) {
                hasExpectedDepiction = YES;
            }
        }
        if (isTargetPackage && hasExpectedDepiction) {
            return YES;
        }
    }
    return NO;
}

static BOOL CTMethodHasShape(Class cls, SEL selector, char returnKind, unsigned int argumentCount)
{
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != argumentCount) {
        return NO;
    }

    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == returnKind;
}

static BOOL CTArgumentIsObject(Method method, unsigned int index)
{
    if (method == NULL || index >= method_getNumberOfArguments(method)) {
        return NO;
    }
    char argumentType[64] = {0};
    method_getArgumentType(method, index, argumentType, sizeof(argumentType));
    return argumentType[0] == '@';
}

static BOOL CTRequiredSafariAPIsPresent(void)
{
    Class tabControllerClass = objc_getClass("TabController");
    Class toolbarClass = objc_getClass("BrowserToolbar");
    if (tabControllerClass == Nil || toolbarClass == Nil) {
        return NO;
    }

    Method currentTabs = class_getInstanceMethod(tabControllerClass, @selector(_currentTabs));
    Method activeDocument = class_getInstanceMethod(tabControllerClass, @selector(activeTabDocument));
    Method toolbarItems = class_getInstanceMethod(toolbarClass, @selector(setItems:));

    return CTMethodHasShape(tabControllerClass, @selector(_currentTabs), '@', 2) &&
           CTMethodHasShape(tabControllerClass, @selector(_newTabFromTabViewButton), 'v', 2) &&
           CTMethodHasShape(tabControllerClass, @selector(activeTabDocument), '@', 2) &&
           CTMethodHasShape(tabControllerClass, @selector(closeTab), 'v', 2) &&
           CTMethodHasShape(toolbarClass, @selector(setItems:), 'v', 3) &&
           CTArgumentIsObject(toolbarItems, 2) &&
           currentTabs != NULL && activeDocument != NULL;
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

    // 复用 Safari 私有的「新建标签」路径；实际类型、顺序和动画需目标设备验证。
    [self _newTabFromTabViewButton];

    // MRR 下对 +0 返回值保留一个局部所有权，确保读取 ivar 和同步调用期间 document 存活。
    id document = [[self activeTabDocument] retain];
    if (document != nil) {
        Ivar ivar = class_getInstanceVariable(object_getClass(document), "_browserController");
        const char *ivarType = (ivar != NULL) ? ivar_getTypeEncoding(ivar) : NULL;
        if (ivar != NULL && ivarType != NULL && ivarType[0] == '@') {
            id *slot = (id *)((char *)document + ivar_getOffset(ivar));
            id browserController = *slot;
            if ([browserController respondsToSelector:
                    @selector(navigationBarURLWasTapped:completionHandler:)]) {
                [browserController navigationBarURLWasTapped:nil completionHandler:nil];
            }
        }
    }
    [document release];

    [generator release];
}

// 控制器销毁时摘掉通知，避免向已释放对象回调。
// 原版顺序是「先 %orig 再 removeObserver:self」，属 use-after-free，此处已纠正。
- (void)dealloc
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:kCTNotificationOpenNewTab object:nil];
    [nc removeObserver:self name:kCTNotificationCloseTab object:nil];
    %orig;
}

%end


%hook BrowserToolbar

- (void)setItems:(NSArray *)items
{
    if (items == nil) {
        %orig;
        return;
    }

    // 每次只使用局部副本；先移除上次注入且带有本插件标记的按钮。
    NSMutableArray *mutableItems = [items mutableCopy];
    if (mutableItems == nil) {
        %orig;
        return;
    }
    CTRemoveInjectedButtons(mutableItems);

    UIBarButtonItem *trashItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                     target:self
                                                     action:@selector(closeTab)];
    if (trashItem == nil) {
        %orig(items);
        [mutableItems release];
        return;
    }
    objc_setAssociatedObject(trashItem,
                             &kCTInjectedButtonKey,
                             [NSNumber numberWithBool:YES],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Safari 私有能力：给同一个按钮再挂一个长按 action。
    // 若系统没有这个方法（未来版本被移除）就退化为「只有单击」。
    if ([trashItem respondsToSelector:@selector(_sf_setTarget:longPressAction:)]) {
        [trashItem _sf_setTarget:self longPressAction:@selector(newTab)];
    }

    // 保留原来的相对插入规则，并对短数组做下界保护。
    NSInteger index = (NSInteger)[mutableItems count] - 3;
    if (index < 0) index = 0;
    if (index > (NSInteger)[mutableItems count]) index = (NSInteger)[mutableItems count];
    [mutableItems insertObject:trashItem atIndex:(NSUInteger)index];
    [trashItem release];

    %orig(mutableItems);
    [mutableItems release];
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
        BOOL installGatePassed = CTPassedInstallCheck();
        if (!installGatePassed) {
#if CT_DIAGNOSTICS
            NSLog(@"[ControlTab] hooks skipped: package-record gate failed");
#endif
            return;
        }

        if (!CTRequiredSafariAPIsPresent()) {
#if CT_DIAGNOSTICS
            NSLog(@"[ControlTab] hooks skipped: required Safari API shape mismatch");
#endif
            return;
        }

        %init(ControlTabHooks);
    }
}
