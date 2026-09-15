#import <objc/runtime.h>
#import <objc/message.h>

extern void THStorySeenReceiptNetworkGuardEnter(void);
extern void THStorySeenReceiptNetworkGuardEnterWithContext(id fullscreenSectionController, id storyViewer);
extern void THStorySeenReceiptNetworkGuardResealAfterMark(id fullscreenSectionController, id storyViewer);
extern void THStorySeenReceiptNetworkGuardLeave(void);

@class IGVideo;
static void downloadHDVideo(IGVideo *inputVideo);
static UIImage *thetaColoredSystemSymbol(NSString *name, UIColor *color);

static const NSInteger kThetaStoryButtonTag = 77001;

static void (*orig_storyGhost2)(id self, SEL _cmd, id fullscreenSectionController, id didMarkItemAsSeen);
static void (*orig_storyGhost3)(id self, SEL _cmd, id fullscreenSectionController, id didMarkItemAsSeen, NSInteger entryPoint);
static void (*orig_sectionMarkCurrent)(id self, SEL _cmd);
static void (*orig_sectionMarkItem)(id self, SEL _cmd, id item);

static void hook_storyGhost2(id self, SEL _cmd, id fullscreenSectionController, id didMarkItemAsSeen);
static void hook_storyGhost3(id self, SEL _cmd, id fullscreenSectionController, id didMarkItemAsSeen, NSInteger entryPoint);
static void hook_sectionMarkCurrent(id self, SEL _cmd);
static void hook_sectionMarkItem(id self, SEL _cmd, id item);
static BOOL thetaLooksLikeStorySection(id obj);
static BOOL thetaStoryObjectIsJunkSection(id obj);
static id thetaStorySectionFromListAdapter(id adapter, UICollectionViewCell *cell);
static id thetaStoryListAdapterFromHost(id host);

static char kThetaBtnTouchUpInsideBlockKey;
static char kThetaBtnTouchDownBlockKey;
static void *UIGestureBlockKey = &UIGestureBlockKey;

@interface UIButton (BlockTarget)
- (void)handleControlEvent:(UIControlEvents)event withBlock:(void (^)(id sender))block;
@end

@implementation UIButton (BlockTarget)
- (void)handleControlEvent:(UIControlEvents)event withBlock:(void (^)(id sender))block {
    // Separate keys so TouchDown + TouchUpInside don't clobber each other.
    if (event == UIControlEventTouchDown) {
        objc_setAssociatedObject(self, &kThetaBtnTouchDownBlockKey, block, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [self addTarget:self action:@selector(theta_fireTouchDownBlock:) forControlEvents:UIControlEventTouchDown];
        return;
    }
    objc_setAssociatedObject(self, &kThetaBtnTouchUpInsideBlockKey, block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self addTarget:self action:@selector(theta_fireTouchUpInsideBlock:) forControlEvents:event];
}

- (void)theta_fireTouchUpInsideBlock:(id)sender {
    void (^block)(id) = objc_getAssociatedObject(self, &kThetaBtnTouchUpInsideBlockKey);
    if (block) {
        @try { block(sender ?: self); } @catch (__unused NSException *e) {}
    }
}

- (void)theta_fireTouchDownBlock:(id)sender {
    void (^block)(id) = objc_getAssociatedObject(self, &kThetaBtnTouchDownBlockKey);
    if (block) {
        @try { block(sender ?: self); } @catch (__unused NSException *e) {}
    }
}
@end

@interface UIGestureRecognizer (BlockTarget)
- (void)addActionBlock:(void (^)(UIGestureRecognizer *sender))block;
@end

@implementation UIGestureRecognizer (BlockTarget)
- (void)addActionBlock:(void (^)(UIGestureRecognizer *sender))block {
    objc_setAssociatedObject(self, UIGestureBlockKey, block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self addTarget:self action:@selector(theta_gestureCallActionBlock:)];
}

- (void)theta_gestureCallActionBlock:(UIGestureRecognizer *)sender {
    void (^block)(UIGestureRecognizer *) = objc_getAssociatedObject(self, UIGestureBlockKey);
    if (block) {
        @try { block(sender); } @catch (__unused NSException *e) {}
    }
}
@end

static void thetaStoryAddTap(UIButton *button, void (^handler)(void)) {
    if (!button || !handler) return;
    void (^copied)(void) = [handler copy];
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        @try { copied(); } @catch (__unused NSException *e) {}
    }] forControlEvents:UIControlEventTouchUpInside];
}

static void thetaStorySkipIfEnabled(id firstDelegate) {
    if (!ENABLED(@"Skip On Seen") || !firstDelegate) return;
    if (![firstDelegate respondsToSelector:@selector(fullscreenOverlayDidTapNextStoryButton:)]) return;
    @try {
        [firstDelegate fullscreenOverlayDidTapNextStoryButton:nil];
    } @catch (__unused NSException *e) {}
}

static id thetaStorySectionControllerFromCell(IGStoryFullscreenCell *cell) {
    if (!cell) return nil;
    NSMutableArray *cands = [NSMutableArray array];
    void (^add)(id) = ^(id obj) {
        if (!obj) return;
        if ([cands indexOfObjectIdenticalTo:obj] != NSNotFound) return;
        [cands addObject:obj];
    };
    @try {
        if ([cell respondsToSelector:@selector(delegate)]) {
            add([cell performSelector:@selector(delegate)]);
        }
    } @catch (__unused NSException *e) {}
    id container = ThetaValueForKey(cell, @"containerView");
    add(ThetaValueForKey(container, @"delegate"));
    id overlay = ThetaValueForKey(cell, @"overlayView") ?: ThetaValueForKey(cell, @"_overlayView");
    add(ThetaValueForKey(overlay, @"delegate"));
    for (id c in cands) {
        if (thetaLooksLikeStorySection(c)) return c;
    }
    for (id c in cands) {
        if (!thetaStoryObjectIsJunkSection(c)) return c;
    }
    return nil;
}

static BOOL thetaIsStoryViewerObject(id obj) {
    if (!obj) return NO;
    Class exact = NSClassFromString(@"IGStoryViewerViewController");
    if (exact && [obj isKindOfClass:exact]) return YES;
    NSString *name = NSStringFromClass(object_getClass(obj));
    if (![name isKindOfClass:[NSString class]]) return NO;
    if ([name containsString:@"StoryViewerViewController"]) return YES;
    if ([name containsString:@"StoryViewer"] && [name containsString:@"Controller"]) return YES;
    if ([name isEqualToString:@"IGStoryViewerViewController"]) return YES;
    return NO;
}

static id thetaStoryViewerFromCell(IGStoryFullscreenCell *cell) {
    id section = thetaStorySectionControllerFromCell(cell);
    id candidate = ThetaValueForKey(section, @"delegate");
    if (thetaIsStoryViewerObject(candidate)) return candidate;

    UIView *view = (UIView *)cell;
    while (view) {
        UIResponder *r = view.nextResponder;
        while (r) {
            if (thetaIsStoryViewerObject(r)) return r;
            r = r.nextResponder;
        }
        view = view.superview;
    }

    for (NSString *key in @[ @"storyViewer", @"viewController", @"parentViewController", @"delegate", @"viewerViewController" ]) {
        id fromKey = ThetaValueForKey(section, key);
        if (thetaIsStoryViewerObject(fromKey)) return fromKey;
    }

    @try {
        UIViewController *top = [ThetaHelper topViewController];
        UIViewController *p = top;
        while (p) {
            if (thetaIsStoryViewerObject(p)) return p;
            p = p.parentViewController;
        }
        p = top;
        while (p) {
            if (thetaIsStoryViewerObject(p)) return p;
            p = p.presentingViewController;
        }
    } @catch (__unused NSException *e) {}

    if (candidate) return candidate;
    return nil;
}

static id thetaStoryPreferredSection(IGStoryFullscreenCell *cell, id viewer) {
    NSMutableArray *cands = [NSMutableArray array];
    void (^add)(id) = ^(id obj) {
        if (!obj || thetaStoryObjectIsJunkSection(obj)) return;
        if ([cands indexOfObjectIdenticalTo:obj] != NSNotFound) return;
        [cands addObject:obj];
    };
    add(thetaStorySectionControllerFromCell(cell));
    if (viewer) {
        for (NSString *selName in @[
            @"_getMostVisibleSectionController",
            @"mostVisibleSectionController",
            @"currentSectionController",
            @"focusedSectionController",
            @"visibleSectionController"
        ]) {
            SEL s = NSSelectorFromString(selName);
            if (!class_getInstanceMethod(object_getClass(viewer), s)) continue;
            id vis = nil;
            @try { vis = ((id (*)(id, SEL))objc_msgSend)(viewer, s); } @catch (__unused NSException *e) {}
            add(vis);
        }
        for (NSString *key in @[ @"currentSectionController", @"focusedSectionController", @"visibleSectionController" ]) {
            add(ThetaValueForKey(viewer, key));
        }
        id adapter = thetaStoryListAdapterFromHost(viewer);
        add(thetaStorySectionFromListAdapter(adapter, (UICollectionViewCell *)cell));
    }
    if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        UIView *v = ((UIView *)cell).superview;
        while (v && ![v isKindOfClass:[UICollectionView class]]) v = v.superview;
        if ([v isKindOfClass:[UICollectionView class]]) {
            id adapter = ThetaValueForKey(v, @"delegate");
            NSString *an = adapter ? NSStringFromClass([adapter class]) : nil;
            if (![an containsString:@"ListAdapter"]) adapter = ThetaValueForKey(v, @"dataSource");
            an = adapter ? NSStringFromClass([adapter class]) : nil;
            if (![an containsString:@"ListAdapter"]) adapter = nil;
            add(thetaStorySectionFromListAdapter(adapter, (UICollectionViewCell *)cell));
        }
    }
    for (id c in cands) {
        if (thetaLooksLikeStorySection(c)) return c;
    }
    return nil;
}

static id thetaStoryCurrentItem(id section, id viewer) {
    NSArray *hosts = viewer && section ? @[section, viewer] : (section ? @[section] : (viewer ? @[viewer] : @[]));
    NSArray *selNames = @[ @"currentStoryItem", @"currentItem", @"focusedStoryItem", @"currentReelItem", @"focusedItem", @"storyItem" ];
    NSArray *keys = @[ @"currentStoryItem", @"currentItem", @"focusedStoryItem", @"currentReelItem", @"storyItem", @"media" ];
    for (id host in hosts) {
        for (NSString *selName in selNames) {
            SEL s = NSSelectorFromString(selName);
            if (!class_getInstanceMethod(object_getClass(host), s)) continue;
            id v = nil;
            @try { v = ((id (*)(id, SEL))objc_msgSend)(host, s); } @catch (__unused NSException *e) {}
            if (v) return v;
        }
        for (NSString *key in keys) {
            id v = ThetaValueForKey(host, key);
            if (v) return v;
        }
    }
    return nil;
}

static BOOL thetaLooksLikeStorySection(id obj) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    if (![n isKindOfClass:[NSString class]]) return NO;
    NSString *l = n.lowercaseString;
    if ([l containsString:@"nux"] || [l containsString:@"dismisshandler"] || [l containsString:@"gesture"]) return NO;
    if ([l containsString:@"overlay"] || [l containsString:@"footer"] || [l containsString:@"header"]) return NO;
    if ([n containsString:@"StoryFullscreenSectionController"]) return YES;
    if ([n containsString:@"FullscreenSectionController"]) return YES;
    if ([n containsString:@"StorySectionController"]) return YES;
    if ([n containsString:@"SectionController"]
        && class_getInstanceMethod(object_getClass(obj), @selector(currentStoryItem))) {
        return YES;
    }
    return NO;
}

static BOOL thetaStoryObjectIsJunkSection(id obj) {
    if (!obj) return YES;
    NSString *n = NSStringFromClass(object_getClass(obj));
    if (![n isKindOfClass:[NSString class]]) return YES;
    NSString *l = n.lowercaseString;
    if ([l containsString:@"nux"] || [l containsString:@"dismisshandler"]) return YES;
    if (thetaIsStoryViewerObject(obj)) return YES;
    return NO;
}

static id thetaStoryObjectIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    for (Class cls = object_getClass(obj); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (!iv) continue;
        const char *enc = ivar_getTypeEncoding(iv);
        if (!enc || enc[0] != '@') return nil;
        id val = nil;
        @try { val = object_getIvar(obj, iv); } @catch (__unused NSException *e) {}
        return val;
    }
    return nil;
}

static id thetaStoryListAdapterFromHost(id host) {
    if (!host) return nil;
    for (NSString *key in @[ @"listAdapter", @"_listAdapter", @"adapter" ]) {
        id a = ThetaValueForKey(host, key);
        NSString *n = a ? NSStringFromClass([a class]) : nil;
        if ([n containsString:@"ListAdapter"]) return a;
    }
    id a = thetaStoryObjectIvar(host, "_listAdapter") ?: thetaStoryObjectIvar(host, "listAdapter");
    NSString *n = a ? NSStringFromClass([a class]) : nil;
    if ([n containsString:@"ListAdapter"]) return a;
    return nil;
}

static id thetaStorySectionFromListAdapter(id adapter, UICollectionViewCell *cell) {
    if (!adapter) return nil;
    NSArray *vis = nil;
    SEL visSel = NSSelectorFromString(@"visibleSectionControllers");
    if (class_getInstanceMethod(object_getClass(adapter), visSel)) {
        @try { vis = ((id (*)(id, SEL))objc_msgSend)(adapter, visSel); } @catch (__unused NSException *e) {}
        if ([vis isKindOfClass:[NSArray class]]) {
            for (id sc in vis) {
                if (thetaLooksLikeStorySection(sc)) return sc;
            }
        }
    }
    UICollectionView *cv = nil;
    if ([cell isKindOfClass:[UICollectionViewCell class]]) {
        UIView *v = cell.superview;
        while (v && ![v isKindOfClass:[UICollectionView class]]) v = v.superview;
        cv = (UICollectionView *)v;
    }
    NSIndexPath *ip = (cv && cell) ? [cv indexPathForCell:cell] : nil;
    if (ip) {
        for (NSString *name in @[ @"sectionControllerForSection:", @"sectionControllerForSectionIndex:" ]) {
            SEL s = NSSelectorFromString(name);
            if (!class_getInstanceMethod(object_getClass(adapter), s)) continue;
            id sc = nil;
            @try { sc = ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, s, ip.section); } @catch (__unused NSException *e) {}
            if (thetaLooksLikeStorySection(sc)) return sc;
        }
        SEL objSel = NSSelectorFromString(@"objectForSection:");
        SEL scSel = NSSelectorFromString(@"sectionControllerForObject:");
        if (class_getInstanceMethod(object_getClass(adapter), objSel) && class_getInstanceMethod(object_getClass(adapter), scSel)) {
            id obj = nil;
            @try { obj = ((id (*)(id, SEL, NSInteger))objc_msgSend)(adapter, objSel, ip.section); } @catch (__unused NSException *e) {}
            if (obj) {
                id sc = nil;
                @try { sc = ((id (*)(id, SEL, id))objc_msgSend)(adapter, scSel, obj); } @catch (__unused NSException *e) {}
                if (thetaLooksLikeStorySection(sc)) return sc;
            }
        }
    }
    NSArray *objects = nil;
    SEL objectsSel = NSSelectorFromString(@"objects");
    SEL scForObj = NSSelectorFromString(@"sectionControllerForObject:");
    if (class_getInstanceMethod(object_getClass(adapter), objectsSel)
        && class_getInstanceMethod(object_getClass(adapter), scForObj)) {
        @try { objects = ((id (*)(id, SEL))objc_msgSend)(adapter, objectsSel); } @catch (__unused NSException *e) {}
        if ([objects isKindOfClass:[NSArray class]]) {
            id preferred = nil;
            if (ip && ip.section >= 0 && ip.section < (NSInteger)objects.count) {
                id obj = objects[(NSUInteger)ip.section];
                @try { preferred = ((id (*)(id, SEL, id))objc_msgSend)(adapter, scForObj, obj); } @catch (__unused NSException *e) {}
                if (thetaLooksLikeStorySection(preferred)) return preferred;
            }
            for (id obj in objects) {
                id sc = nil;
                @try { sc = ((id (*)(id, SEL, id))objc_msgSend)(adapter, scForObj, obj); } @catch (__unused NSException *e) {}
                if (thetaLooksLikeStorySection(sc)) {
                    if (!preferred) preferred = sc;
                }
            }
            if (preferred) return preferred;
        }
    }
    return nil;
}

static void thetaStoryAddUnique(NSMutableArray *into, id obj) {
    if (!obj || !into) return;
    if ([into indexOfObjectIdenticalTo:obj] != NSNotFound) return;
    [into addObject:obj];
}

static BOOL thetaStoryHasSelector(id obj, SEL sel) {
    if (!obj || !sel) return NO;
    return class_getInstanceMethod(object_getClass(obj), sel) != NULL;
}

static BOOL thetaStorySelLooksLikeMarkSeen(NSString *name) {
    if (!name.length) return NO;
    NSString *l = name.lowercaseString;
    if ([l hasPrefix:@"is"] || [l hasPrefix:@"has"] || [l hasPrefix:@"get"] || [l hasPrefix:@"set"]) return NO;
    if ([l containsString:@"didmarkitemasseen"]) return YES;
    if ([l containsString:@"markitemasseen"]) return YES;
    if ([l containsString:@"markcurrentitemasseen"]) return YES;
    if ([l containsString:@"markstoryitemasseen"]) return YES;
    if ([l containsString:@"markitemseen"]) return YES;
    if ([l containsString:@"didmarkasseen"]) return YES;
    if ([l containsString:@"sendseenrequest"]) return YES;
    if ([l containsString:@"enqueueseenrequest"]) return YES;
    return NO;
}

static BOOL thetaStorySignatureSafeToInvoke(NSMethodSignature *sig) {
    if (!sig) return NO;
    NSUInteger n = sig.numberOfArguments;
    if (n > 6) return NO;
    for (NSUInteger i = 2; i < n; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        if (!t) return NO;
        while (*t == 'r' || *t == 'n' || *t == 'N' || *t == 'o' || *t == 'O' || *t == 'V') t++;
        char c = *t;
        if (c == '@' || c == '#' || c == ':' || c == 'B' || c == 'c' || c == 'C' || c == 's' || c == 'S'
            || c == 'i' || c == 'I' || c == 'l' || c == 'L' || c == 'q' || c == 'Q' || c == 'f' || c == 'd') {
            continue;
        }
        return NO;
    }
    return YES;
}

static BOOL thetaStoryInvokeSeenSelector(id target, SEL sel, id section, id item) {
    if (!target || !sel || !thetaStoryHasSelector(target, sel)) return NO;

    IMP live = method_getImplementation(class_getInstanceMethod(object_getClass(target), sel));
    if (live == (IMP)hook_storyGhost2 && orig_storyGhost2) {
        @try {
            orig_storyGhost2(target, sel, section, item);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[Theta] StoryGhost: orig2 %@ threw %@", NSStringFromSelector(sel), e);
            return NO;
        }
    }
    if (live == (IMP)hook_storyGhost3 && orig_storyGhost3) {
        @try {
            orig_storyGhost3(target, sel, section, item, 0);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[Theta] StoryGhost: orig3 %@ threw %@", NSStringFromSelector(sel), e);
            return NO;
        }
    }
    if (live == (IMP)hook_sectionMarkCurrent && orig_sectionMarkCurrent) {
        @try {
            orig_sectionMarkCurrent(target, sel);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[Theta] StoryGhost: orig markCurrent %@ threw %@", NSStringFromSelector(sel), e);
            return NO;
        }
    }
    if (live == (IMP)hook_sectionMarkItem && orig_sectionMarkItem) {
        @try {
            orig_sectionMarkItem(target, sel, item);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[Theta] StoryGhost: orig markItem %@ threw %@", NSStringFromSelector(sel), e);
            return NO;
        }
    }

    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) {
        NSUInteger colons = [[NSStringFromSelector(sel) componentsSeparatedByString:@":"] count] - 1;
        @try {
            if (colons == 0) {
                ((void (*)(id, SEL))objc_msgSend)(target, sel);
                return YES;
            }
            if (colons == 1) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, sel, item);
                return YES;
            }
            if (colons == 2) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(target, sel, section ?: item, item);
                return YES;
            }
            if (colons == 3) {
                ((void (*)(id, SEL, id, id, NSInteger))objc_msgSend)(target, sel, section, item, 0);
                return YES;
            }
        } @catch (__unused NSException *e) {}
        return NO;
    }
    if (!thetaStorySignatureSafeToInvoke(sig)) return NO;

    NSString *name = NSStringFromSelector(sel);
    BOOL sectionFirst = [name containsString:@"SectionController:"] || [name containsString:@"sectionController:"];
    id objArgs[3] = { sectionFirst ? section : item, sectionFirst ? item : section, nil };
    NSInteger zero = 0;
    NSUInteger objIdx = 0;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target];
    [inv setSelector:sel];
    for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        while (t && (*t == 'r' || *t == 'n' || *t == 'N' || *t == 'o' || *t == 'O' || *t == 'V')) t++;
        if (!t) continue;
        if (*t == '@' || *t == '#') {
            id a = (objIdx < 3) ? objArgs[objIdx] : nil;
            objIdx++;
            [inv setArgument:&a atIndex:i];
        } else if (*t == 'f') {
            float z = 0;
            [inv setArgument:&z atIndex:i];
        } else if (*t == 'd') {
            double z = 0;
            [inv setArgument:&z atIndex:i];
        } else {
            [inv setArgument:&zero atIndex:i];
        }
    }
    @try {
        [inv invoke];
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[Theta] StoryGhost: %@ on %@ threw %@", name, NSStringFromClass([target class]), e);
        return NO;
    }
}

static NSArray<NSString *> *thetaStoryMarkSeenSelectorNamesOn(id obj) {
    if (!obj) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (Class cls = object_getClass(obj); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned n = 0;
        Method *list = class_copyMethodList(cls, &n);
        if (list) {
            for (unsigned i = 0; i < n; i++) {
                NSString *name = NSStringFromSelector(method_getName(list[i]));
                if (!thetaStorySelLooksLikeMarkSeen(name) || [seen containsObject:name]) continue;
                [seen addObject:name];
                [out addObject:name];
            }
            free(list);
        }
        if (cls == [UIViewController class] || cls == [UIView class]) break;
    }
    return out;
}

static BOOL thetaStoryMarkItemAsSeen(IGStoryFullscreenCell *cell, id item) {
    if (!cell || !item) return NO;
    id viewer = thetaStoryViewerFromCell(cell);
    id section = thetaStoryPreferredSection(cell, viewer);
    if (thetaStoryObjectIsJunkSection(section) || !thetaLooksLikeStorySection(section))
        section = nil;

    NSMutableArray *targets = [NSMutableArray array];
    thetaStoryAddUnique(targets, viewer);
    if (section) {
        id secDel = ThetaValueForKey(section, @"delegate");
        if (!thetaStoryObjectIsJunkSection(secDel) || thetaIsStoryViewerObject(secDel))
            thetaStoryAddUnique(targets, secDel);
        thetaStoryAddUnique(targets, section);
    }

    if (targets.count == 0) {
        NSLog(@"[Theta] StoryGhost: no viewer/section for mark-seen");
        return NO;
    }
    if (!section) {
        NSLog(@"[Theta] StoryGhost: fullscreen section missing (viewer=%@ cellDel=%@)",
              NSStringFromClass([viewer class]),
              NSStringFromClass([ThetaValueForKey(cell, @"delegate") class]));
        return NO;
    }

    static NSArray<NSString *> *kKnownViewerSels;
    static NSArray<NSString *> *kKnownSectionItemSels;
    static NSArray<NSString *> *kKnownSectionVoidSels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kKnownViewerSels = @[
            @"fullscreenSectionController:didMarkItemAsSeen:",
            @"fullscreenSectionController:didMarkItemAsSeen:entryPoint:",
            @"fullscreenSectionController:didMarkItemAsSeen:source:",
            @"fullscreenSectionController:didMarkItemAsSeen:entryPoint:source:",
            @"storySectionController:didMarkItemAsSeen:",
            @"sectionController:didMarkItemAsSeen:",
            @"fullscreenSectionController:didEndViewingItem:"
        ];
        kKnownSectionItemSels = @[
            @"markItemAsSeen:",
            @"_markItemAsSeen:",
            @"markStoryItemAsSeen:",
            @"markCurrentItemAsSeen:",
            @"_markCurrentItemAsSeen:"
        ];
        kKnownSectionVoidSels = @[
            @"markCurrentItemAsSeen",
            @"_markCurrentItemAsSeen",
            @"sendSeenRequestForCurrentItem",
            @"_sendSeenRequestForCurrentItem"
        ];
    });

    BOOL invoked = NO;

    if (orig_storyGhost2 && viewer) {
        @try {
            orig_storyGhost2(viewer, @selector(fullscreenSectionController:didMarkItemAsSeen:), section, item);
            invoked = YES;
        } @catch (NSException *e) {
            NSLog(@"[Theta] StoryGhost: orig didMarkItemAsSeen threw %@", e);
        }
    }
    if (orig_storyGhost3 && viewer) {
        @try {
            orig_storyGhost3(viewer, NSSelectorFromString(@"fullscreenSectionController:didMarkItemAsSeen:entryPoint:"), section, item, 0);
            invoked = YES;
        } @catch (NSException *e) {
            NSLog(@"[Theta] StoryGhost: orig didMarkItemAsSeen:entryPoint: threw %@", e);
        }
    }
    if (orig_sectionMarkCurrent) {
        @try {
            orig_sectionMarkCurrent(section, NSSelectorFromString(@"markCurrentItemAsSeen"));
            invoked = YES;
        } @catch (NSException *e) {
            NSLog(@"[Theta] StoryGhost: orig markCurrentItemAsSeen threw %@", e);
        }
    }
    if (orig_sectionMarkItem) {
        @try {
            orig_sectionMarkItem(section, NSSelectorFromString(@"markItemAsSeen:"), item);
            invoked = YES;
        } @catch (NSException *e) {
            NSLog(@"[Theta] StoryGhost: orig markItemAsSeen: threw %@", e);
        }
    }

    for (id target in targets) {
        if (thetaStoryObjectIsJunkSection(target) && !thetaIsStoryViewerObject(target) && target != section)
            continue;
        for (NSString *name in kKnownViewerSels) {
            invoked = thetaStoryInvokeSeenSelector(target, NSSelectorFromString(name), section, item) || invoked;
        }
        for (NSString *name in kKnownSectionItemSels) {
            invoked = thetaStoryInvokeSeenSelector(target, NSSelectorFromString(name), section, item) || invoked;
        }
        for (NSString *name in kKnownSectionVoidSels) {
            if (s_thetaLocalSeenMarkActive && [name.lowercaseString containsString:@"sendseen"]) continue;
            invoked = thetaStoryInvokeSeenSelector(target, NSSelectorFromString(name), section, item) || invoked;
        }
        if (invoked) break;
    }

    if (!invoked) {
        for (id target in targets) {
            for (NSString *name in thetaStoryMarkSeenSelectorNamesOn(target)) {
                if (s_thetaLocalSeenMarkActive && [name.lowercaseString containsString:@"sendseen"]) continue;
                invoked = thetaStoryInvokeSeenSelector(target, NSSelectorFromString(name), section, item) || invoked;
            }
            if (invoked) break;
        }
    }

    if (!invoked) {
        NSMutableArray *clsNames = [NSMutableArray array];
        for (id t in targets) {
            NSString *cn = NSStringFromClass([t class]) ?: @"?";
            [clsNames addObject:cn];
            NSArray *sels = thetaStoryMarkSeenSelectorNamesOn(t);
            if (sels.count)
                NSLog(@"[Theta] StoryGhost: %@ mark-sels=%@", cn, [sels componentsJoinedByString:@","]);
        }
        NSLog(@"[Theta] StoryGhost: no mark-seen IMP targets=%@", [clsNames componentsJoinedByString:@","]);
    }
    return invoked;
}

static NSURL *thetaStoryURLFromCandidate(id cand) {
    if (!cand) return nil;
    if ([cand isKindOfClass:[NSURL class]]) return cand;
    if ([cand isKindOfClass:[NSString class]]) {
        NSURL *u = [NSURL URLWithString:(NSString *)cand];
        return u.scheme.length ? u : nil;
    }
    id url = ThetaValueForKey(cand, @"url");
    if ([url isKindOfClass:[NSURL class]]) return url;
    if ([url isKindOfClass:[NSString class]]) {
        NSURL *u = [NSURL URLWithString:(NSString *)url];
        return u.scheme.length ? u : nil;
    }
    return nil;
}

static NSURL *thetaStoryBestImageURLFromMedia(id media) {
    if (!media) return nil;
    // IG 441+: IGMedia exposes hintableImageURLs instead of isPhotoMedia/photo.
    if ([media respondsToSelector:@selector(hintableImageURLs)]) {
        id urls = nil;
        @try { urls = [media performSelector:@selector(hintableImageURLs)]; } @catch (__unused NSException *e) {}
        if ([urls isKindOfClass:[NSArray class]] && [urls count] > 0) {
            NSURL *u = thetaStoryURLFromCandidate([urls lastObject]);
            if (u) return u;
            for (id o in urls) {
                u = thetaStoryURLFromCandidate(o);
                if (u) return u;
            }
        } else if ([urls isKindOfClass:[NSSet class]]) {
            for (id o in (NSSet *)urls) {
                NSURL *u = thetaStoryURLFromCandidate(o);
                if (u) return u;
            }
        }
    }

    id photo = nil;
    if ([media respondsToSelector:@selector(photo)]) {
        @try { photo = [media performSelector:@selector(photo)]; } @catch (__unused NSException *e) {}
    }
    if (!photo) photo = ThetaValueForKey(media, @"photo");
    if (!photo) photo = ThetaValueForKey(media, @"rawPhoto");

    NSArray *versions = ThetaValueForKey(photo, @"_originalImageVersions");
    if (![versions isKindOfClass:[NSArray class]]) versions = ThetaValueForKey(photo, @"imageVersions");
    if (![versions isKindOfClass:[NSArray class]]) versions = ThetaValueForKey(media, @"imageVersions");
    if ([versions isKindOfClass:[NSArray class]] && versions.count > 0) {
        NSURL *u = thetaStoryURLFromCandidate([versions lastObject]);
        if (u) return u;
    }
    return nil;
}

static id thetaStoryVideoObjectFromMedia(id media) {
    if (!media) return nil;
    id video = nil;
    if ([media respondsToSelector:@selector(video)]) {
        @try { video = [media performSelector:@selector(video)]; } @catch (__unused NSException *e) {}
    }
    if (!video) video = ThetaValueForKey(media, @"video");
    if (!video) video = ThetaValueForKey(media, @"rawVideo");
    return video;
}

static void thetaStorySaveURL(NSURL *url, BOOL isVideoHint) {
    if (![url isKindOfClass:[NSURL class]]) return;
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error || !location) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ENABLED(@"Show Banners")) {
                    [ThetaHelper showToastWithTitle:@"Save failed" subtitle:error.localizedDescription ?: @"Download error" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
                }
            });
            return;
        }
        NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *ext = url.pathExtension.length ? url.pathExtension : (isVideoHint ? @"mp4" : @"jpg");
        NSString *newFilename = [NSString stringWithFormat:@"story-%@.%@", [[NSUUID UUID] UUIDString], ext];
        NSString *permanentFilePath = [documentsPath stringByAppendingPathComponent:newFilename];
        NSError *fileError = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:permanentFilePath] error:&fileError];
        if (fileError) return;

        NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
        if (saveMethod == 0) {
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                if (isVideoHint || [ext.lowercaseString isEqualToString:@"mp4"] || [ext.lowercaseString isEqualToString:@"mov"]) {
                    [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:permanentFilePath]];
                } else {
                    [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:[NSURL fileURLWithPath:permanentFilePath]];
                }
            } completionHandler:^(BOOL success, NSError * _Nullable err) {
                [[NSFileManager defaultManager] removeItemAtPath:permanentFilePath error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        if (success) {
                            [ThetaHelper showToastWithTitle:@"Saved to camera roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                        } else {
                            [ThetaHelper showToastWithTitle:@"Save failed" subtitle:err.localizedDescription ?: @"Photos error" icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
                        }
                    }
                });
            }];
        } else {
            NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
                [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
            }
            NSString *destPath = [audioNotesDir stringByAppendingPathComponent:newFilename];
            [[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ENABLED(@"Show Banners")) {
                    [ThetaHelper showToastWithTitle:@"Saved!" subtitle:@"Saved to Documents." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:nil];
                }
            });
        }
    }];
    [downloadTask resume];
    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"Saving…" subtitle:@"Downloading story media" icon:[UIImage systemImageNamed:@"arrow.down.circle"] autoHide:2 openURL:nil];
    }
}

static NSString *thetaStoryOwnerKey(id owner) {
    if (!owner) return nil;
    @try {
        if ([owner respondsToSelector:@selector(name)]) {
            id n = [owner performSelector:@selector(name)];
            if ([n isKindOfClass:[NSString class]] && [(NSString *)n length]) return [(NSString *)n lowercaseString];
        }
    } @catch (__unused NSException *e) {}
    id n = ThetaValueForKey(owner, @"username");
    if (![n isKindOfClass:[NSString class]] || ![n length]) n = ThetaValueForKey(owner, @"pk");
    if ([n isKindOfClass:[NSString class]] || [n isKindOfClass:[NSNumber class]]) {
        return [[[n description] lowercaseString] copy];
    }
    return [NSString stringWithFormat:@"%p", owner];
}
static void downloadButtonTapped(IGStoryFullscreenCell *self) {
	[ThetaHelper performHapticFeedbackIfEnabled];

	id firstDelegate = thetaStorySectionControllerFromCell(self);
	id currentMedia = nil;
	@try {
		if ([firstDelegate respondsToSelector:@selector(currentStoryItem)]) {
			currentMedia = [firstDelegate performSelector:@selector(currentStoryItem)];
		}
	} @catch (__unused NSException *e) {}
	if (!currentMedia) {
		id viewer = thetaStoryViewerFromCell(self);
		@try {
			if ([viewer respondsToSelector:@selector(currentStoryItem)]) {
				currentMedia = [viewer performSelector:@selector(currentStoryItem)];
			}
		} @catch (__unused NSException *e) {}
	}
	if (!currentMedia) {
		if (ENABLED(@"Show Banners")) {
			[ThetaHelper showToastWithTitle:@"Save failed" subtitle:@"Couldn't find the current story item." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
		}
		return;
	}

	// Prefer image URLs (works for photo stories on IG 441+ without isPhotoMedia).
	NSURL *imageURL = thetaStoryBestImageURLFromMedia(currentMedia);
	id video = thetaStoryVideoObjectFromMedia(currentMedia);

	// Progressive / dash URLs directly on the story item.
	NSURL *directVideoURL = nil;
	if ([currentMedia respondsToSelector:@selector(allVideoURLs)]) {
		id set = nil;
		@try { set = [currentMedia performSelector:@selector(allVideoURLs)]; } @catch (__unused NSException *e) {}
		if ([set isKindOfClass:[NSSet class]]) directVideoURL = thetaStoryURLFromCandidate([(NSSet *)set anyObject]);
		else if ([set isKindOfClass:[NSArray class]] && [set count]) directVideoURL = thetaStoryURLFromCandidate([set lastObject]);
	}
	if (!directVideoURL && video && [video respondsToSelector:@selector(allVideoURLs)]) {
		id set = nil;
		@try { set = [video performSelector:@selector(allVideoURLs)]; } @catch (__unused NSException *e) {}
		if ([set isKindOfClass:[NSSet class]]) directVideoURL = thetaStoryURLFromCandidate([(NSSet *)set anyObject]);
	}

	NSInteger mediaType = -1;
	@try {
		if ([currentMedia respondsToSelector:@selector(mediaTypeEnum)]) {
			mediaType = ((NSInteger (*)(id, SEL))objc_msgSend)(currentMedia, @selector(mediaTypeEnum));
		} else if ([currentMedia respondsToSelector:@selector(mediaType)]) {
			mediaType = ((NSInteger (*)(id, SEL))objc_msgSend)(currentMedia, @selector(mediaType));
		}
	} @catch (__unused NSException *e) {}

	BOOL looksVideo = (mediaType == 2) || (video != nil) || (directVideoURL != nil);
	BOOL looksPhoto = (mediaType == 1) || (imageURL != nil && !looksVideo);

	if (looksPhoto && imageURL) {
		thetaStorySaveURL(imageURL, NO);
		return;
	}

	if (video) {
		@try {
			downloadHDVideo(video);
			return;
		} @catch (NSException *exception) {
			NSLog(@"Error downloading video: %@", exception);
		}
	}

	if (directVideoURL) {
		thetaStorySaveURL(directVideoURL, YES);
		return;
	}

	// Last resort: image URL even if type detection was ambiguous.
	if (imageURL) {
		thetaStorySaveURL(imageURL, NO);
		return;
	}

	if (ENABLED(@"Show Banners")) {
		[ThetaHelper showToastWithTitle:@"Save failed" subtitle:@"No downloadable photo/video URL on this story." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
	}
}

static void downloadAllMedia(IGStoryFullscreenCell *self) {
	id firstDelegate = nil;
	@try {
		if ([self respondsToSelector:@selector(delegate)]) {
			firstDelegate = [self performSelector:@selector(delegate)];
		} else if ([self respondsToSelector:@selector(valueForKey:)]) {
			id container = [self valueForKey:@"containerView"];
			if (container && [container respondsToSelector:@selector(valueForKey:)]) {
				firstDelegate = [container valueForKey:@"delegate"];
			}
		}
	} @catch (__unused NSException *e) {}
	if (!firstDelegate) return;

	id secondDelegate = nil;
	@try {
		secondDelegate = [firstDelegate valueForKey:@"delegate"];
	} @catch (__unused NSException *e) {}
	if (!secondDelegate) return;

	id viewModel = nil;
	@try {
		viewModel = [secondDelegate valueForKey:@"currentViewModel"];
	} @catch (__unused NSException *e) {}
	if (!viewModel) return;

	NSArray *items = nil;
	@try {
		items = [viewModel valueForKey:@"items"];
	} @catch (__unused NSException *e) {}
	if (![items isKindOfClass:[NSArray class]] || items.count == 0) return;

	NSMutableArray *mediaItems = [NSMutableArray array];
	NSMutableArray *igvideos = [NSMutableArray array];
	//NSString *toastTitle = currentMedia.items.count > 1 ? @"Fetching media..." : @"Saving media...";
	NSString *toastTitle = items.count > 1 ? @"Fetching media..." : @"Saving media...";
	if (ENABLED(@"Show Banners")) {
		UIImage *fetchingImage = [UIImage systemImageNamed:@"arrow.clockwise"];
		[ThetaHelper showToastWithTitle:toastTitle subtitle:@"This will only take a second." icon:fetchingImage autoHide:4 openURL:nil];
	}
	NSURL *url = nil;
	UIImage *preview = nil;
	if (viewModel) {
		for (id item in items) {
			if (item && [item isKindOfClass:NSClassFromString(@"IGMedia")]) {
				id media = item;
				BOOL isPhoto = NO;
				@try {
					if ([media respondsToSelector:@selector(isPhotoMedia)]) {
						isPhoto = ((BOOL (*)(id, SEL))objc_msgSend)(media, @selector(isPhotoMedia));
					} else {
						id flag = [media valueForKey:@"isPhotoMedia"];
						if ([flag isKindOfClass:[NSNumber class]]) {
							isPhoto = [flag boolValue];
						}
					}
				} @catch (__unused NSException *e) {}
				if (isPhoto) {
					@try {
						id photo = nil;
						if ([media respondsToSelector:@selector(photo)]) {
							photo = [media performSelector:@selector(photo)];
						}
						if (!photo) continue;
						NSArray *originalImageVersions = nil;
						@try {
							originalImageVersions = [photo valueForKey:@"_originalImageVersions"];
						} @catch (__unused NSException *e) {}
						id photoURL;
						if ([originalImageVersions isKindOfClass:[NSArray class]] && [originalImageVersions count] > 1) {
							photoURL = [originalImageVersions lastObject];
							@try { url = [photoURL valueForKey:@"url"]; } @catch (__unused NSException *e) {}
							if ([url isKindOfClass:[NSURL class]]) {
								NSData *data = [NSData dataWithContentsOfURL:url];
								if (data) preview = [UIImage imageWithData:data];
							} else {
								url = nil;
							}
						}
					} @catch (NSException *exception) {
						NSLog(@"Error downloading image: %@", exception);
					}
				} else {
					@try {
						id video = nil;
						if ([media respondsToSelector:@selector(video)]) {
							video = [media performSelector:@selector(video)];
						}
						if (video) {
							[igvideos addObject:video];
						}
					} @catch (NSException *exception) {
						NSLog(@"Error downloading video: %@", exception);
					}
				}
			}
			
			if (url && url.absoluteString) {  // Make sure we have a valid URL
				NSDictionary *mediaDict = @{ @"url": url.absoluteString, @"preview": preview ?: [UIImage systemImageNamed:@"photo"] };
				[mediaItems addObject:mediaDict];
				url = nil;  // Reset URL to avoid duplicates
				preview = nil;
			}
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			// If we have HD videos always use the HD path
			if (igvideos.count > 0) {
				// Preload HD video thumbnails before showing the view controller
				[MediaSelectionViewController preloadHDVideoThumbnails:igvideos completion:^{
					dispatch_async(dispatch_get_main_queue(), ^{
						MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:mediaItems hdVideos:igvideos withCount:mediaItems.count + igvideos.count];
						UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
						[[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
					});
				}];
				return;
			}

			// Handle regular media items
			if (mediaItems.count == 1) {
				NSDictionary *mediaDict = mediaItems.firstObject;
				NSURL *url = [NSURL URLWithString:mediaDict[@"url"]];
				if (url) {
					MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] init];
					[mediaSelectionVC downloadMediaToTemp:url completion:^(NSString *filePath, NSString *fileExtension){
						if (ENABLED(@"Show Banners")) {
                            [ThetaHelper showToastWithTitle:@"Saved to camera roll!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:4 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                        }
					}];
				}
				return;
			}

			if (mediaItems.count > 1) {
				MediaSelectionViewController *mediaSelectionVC = [[MediaSelectionViewController alloc] initWithMediaItems:mediaItems withCount:mediaItems.count];
				UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mediaSelectionVC];
											[[ThetaHelper topViewController] presentViewController:navController animated:YES completion:nil];
			}
		});
	}
}

/// Mark as seen on this device only (`Seen Receipts Stay Local`). Tap = current item; long-press = every item in this reel.
static void thetaLocalSeenResolveDelegates(IGStoryFullscreenCell *self, id *outFirst, id *outSecond) {
    id viewer = thetaStoryViewerFromCell(self);
    id section = thetaStoryPreferredSection(self, viewer);
    if (outFirst) *outFirst = section;
    if (outSecond) *outSecond = viewer;
}

/// Resolves NSArray of objects acceptable for `-fullscreenSectionController:didMarkItemAsSeen:` (often `IGStoryItem`, not bare `IGMedia`).
static NSArray *theta_storyResolvedItemsForMarkAll(id firstDelegate, id secondDelegate) {
    id vm = nil;
    @try { vm = [firstDelegate valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
    if (!vm) @try { vm = [secondDelegate valueForKey:@"currentViewModel"]; } @catch (__unused NSException *e) {}
    if (!vm) @try { vm = [secondDelegate valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
    if (!vm) return nil;

    NSArray * (^bundleFromKeys)(id) = ^NSArray *(id model) {
        for (NSString *key in @[ @"storyItems", @"items", @"sortedStoryItems", @"reelItems", @"mediaItems" ]) {
            NSArray *a = nil;
            @try {
                id o = [model valueForKey:key];
                if ([o isKindOfClass:[NSArray class]])
                    a = (NSArray *)o;
            } @catch (__unused NSException *e) {}
            if (a.count > 0u)
                return a;
        }
        return nil;
    };

    NSArray *bucket = bundleFromKeys(vm);
    if (bucket.count == 0u)
        return nil;

    id cur = nil;
    @try {
        if (firstDelegate && [firstDelegate respondsToSelector:@selector(currentStoryItem)])
            cur = [firstDelegate performSelector:@selector(currentStoryItem)];
    } @catch (__unused NSException *e) {}

    Class curCls = cur ? object_getClass(cur) : Nil;
    Class mediaCls = NSClassFromString(@"IGMedia");
    Class storyItemCls = NSClassFromString(@"IGStoryItem");

    if (curCls && bucket.count && [bucket.firstObject isKindOfClass:curCls])
        return bucket;

    if (storyItemCls && mediaCls && bucket.count && [bucket.firstObject isKindOfClass:mediaCls]) {
        NSArray *alternate = nil;
        for (NSString *key in @[ @"storyItems", @"sortedStoryItems", @"storyItemList", @"items" ]) {
            @try {
                id o = [vm valueForKey:key];
                if ([o isKindOfClass:[NSArray class]] && [(NSArray *)o count] > 0u &&
                    [((NSArray *)o).firstObject isKindOfClass:storyItemCls])
                    alternate = (NSArray *)o;
            } @catch (__unused NSException *e) {}
            if (alternate.count)
                break;
        }
        if (alternate.count)
            return alternate;

        /* Last resort: map each IGMedia from `bucket` onto story items gathered from parallel arrays / pk. */
        NSMutableArray *truthItems = [NSMutableArray array];
        for (NSString *key in @[ @"storyItems", @"sortedStoryItems", @"storyItemList", @"items" ]) {
            @try {
                id o = [vm valueForKey:key];
                if (![o isKindOfClass:[NSArray class]])
                    continue;
                for (id cand in (NSArray *)o) {
                    if ([cand isKindOfClass:storyItemCls])
                        [truthItems addObject:cand];
                }
            } @catch (__unused NSException *e) {}
        }
        NSArray *truth = truthItems.count ? truthItems : @[];

        NSMutableArray *out = [NSMutableArray arrayWithCapacity:bucket.count];
        for (id media in bucket) {
            id matched = nil;
            for (id cand in truth) {
                id m = nil;
                @try { m = [cand valueForKey:@"media"]; } @catch (__unused NSException *e) {}
                if (m == media || (m && media && [(id)m isEqual:(id)media])) {
                    matched = cand;
                    break;
                }
            }
            if (!matched && storyItemCls) {
                for (id cand in truth) {
                    NSString *pk1 = nil, *pk2 = nil;
                    @try {
                        id pkMed = nil;
                        @try { pkMed = [media valueForKey:@"pk"]; } @catch (__unused NSException *e) {}
                        if (pkMed) pk1 = [pkMed description];
                        id cm = nil;
                        @try { cm = [cand valueForKey:@"media"]; } @catch (__unused NSException *e) {}
                        if (cm) pk2 = [[[cm valueForKey:@"pk"] description] ?: @"" copy];
                    } @catch (__unused NSException *e) {}
                    if (pk1.length && pk2.length && [pk1 isEqualToString:pk2]) {
                        matched = cand;
                        break;
                    }
                }
            }
            [out addObject:matched ?: media];
        }
        return out;
    }

    return bucket;
}

static void thetaLocalSeenMarkCurrent(IGStoryFullscreenCell *self) {
    if (!ENABLED(@"Seen Receipts Stay Local")) return;
    [ThetaHelper performHapticFeedbackIfEnabled];
    id firstDelegate = nil;
    id secondDelegate = nil;
    thetaLocalSeenResolveDelegates(self, &firstDelegate, &secondDelegate);
    if (!firstDelegate || !secondDelegate) {
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Mark failed" subtitle:@"Story viewer not found." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
        return;
    }
    id currentItem = nil;
    @try {
        if ([firstDelegate respondsToSelector:@selector(currentStoryItem)])
            currentItem = [firstDelegate performSelector:@selector(currentStoryItem)];
    } @catch (__unused NSException *e) {}
    if (!currentItem)
        currentItem = thetaStoryCurrentItem(firstDelegate, secondDelegate);
    if (!currentItem) return;

    THStorySeenReceiptNetworkGuardEnterWithContext(firstDelegate, secondDelegate);
    BOOL ghostOn = ENABLED(@"Story Ghost");
    s_thetaLocalSeenMarkActive = YES;
    if (ghostOn) shouldBeSeen = YES;
    BOOL ok = thetaStoryMarkItemAsSeen(self, currentItem);
    if (ghostOn) shouldBeSeen = NO;
    THStorySeenReceiptNetworkGuardResealAfterMark(firstDelegate, secondDelegate);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        s_thetaLocalSeenMarkActive = NO;
        THStorySeenReceiptNetworkGuardLeave();
    });

    if (ENABLED(@"Show Banners")) {
        if (ok) {
            [ThetaHelper showToastWithTitle:@"Marked on this device"
                                    subtitle:@"Stories clear here; receipts are not sent."
                                        icon:[UIImage systemImageNamed:@"iphone"]
                                    autoHide:3
                                     openURL:nil];
        } else {
            [ThetaHelper showToastWithTitle:@"Mark failed" subtitle:@"Couldn't update seen state." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
    }
    if (ok) thetaStorySkipIfEnabled(firstDelegate);
}

static void thetaLocalSeenMarkAll(IGStoryFullscreenCell *self) {
    if (!ENABLED(@"Seen Receipts Stay Local")) return;
    [ThetaHelper performHapticFeedbackIfEnabled];
    id firstDelegate = nil;
    id secondDelegate = nil;
    thetaLocalSeenResolveDelegates(self, &firstDelegate, &secondDelegate);
    if (!firstDelegate || !secondDelegate) return;

    NSArray *items = theta_storyResolvedItemsForMarkAll(firstDelegate, secondDelegate);
    if (![items isKindOfClass:[NSArray class]] || items.count == 0u) return;

    /* Only the item aligned with `-currentStoryItem` is honored; iterate by retargeting the playhead between marks (restore after). */
    id priorFocused = nil;
    @try {
        if ([firstDelegate respondsToSelector:@selector(currentStoryItem)])
            priorFocused = [firstDelegate performSelector:@selector(currentStoryItem)];
    } @catch (__unused NSException *e) {}

    THStorySeenReceiptNetworkGuardEnterWithContext(firstDelegate, secondDelegate);
    BOOL ghostOn = ENABLED(@"Story Ghost");
    s_thetaLocalSeenMarkActive = YES;
    if (ghostOn) shouldBeSeen = YES;
    @try {
        for (id item in items) {
            if (!item) continue;
            @try {
                if ([firstDelegate respondsToSelector:@selector(setCurrentStoryItem:)])
                    ((void (*)(id, SEL, id))objc_msgSend)(firstDelegate, @selector(setCurrentStoryItem:), item);
                else
                    ThetaSetValueForKey(firstDelegate, item, @"currentStoryItem");
            } @catch (__unused NSException *e) {}
            (void)thetaStoryMarkItemAsSeen(self, item);
        }
    } @catch (__unused NSException *e) {}
    if (ghostOn) shouldBeSeen = NO;
    THStorySeenReceiptNetworkGuardResealAfterMark(firstDelegate, secondDelegate);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        s_thetaLocalSeenMarkActive = NO;
        THStorySeenReceiptNetworkGuardLeave();
    });

    if (priorFocused) {
        @try {
            if ([firstDelegate respondsToSelector:@selector(setCurrentStoryItem:)])
                ((void (*)(id, SEL, id))objc_msgSend)(firstDelegate, @selector(setCurrentStoryItem:), priorFocused);
            else
                ThetaSetValueForKey(firstDelegate, priorFocused, @"currentStoryItem");
        } @catch (__unused NSException *e) {}
    }

    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"All marked on this device"
                                subtitle:@"Receipts are not sent."
                                    icon:[UIImage systemImageNamed:@"iphone"]
                                autoHide:3
                                 openURL:nil];
    }
    thetaStorySkipIfEnabled(firstDelegate);
}

static void handleLocalSeenTap(IGStoryFullscreenCell *self, UIButton *sender) {
    thetaLocalSeenMarkCurrent(self);
}

static void handleLocalSeenLongPress(IGStoryFullscreenCell *self, UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan)
        thetaLocalSeenMarkAll(self);
}

static void seenButtonPressedAll(IGStoryFullscreenCell *self) {
    id viewer = thetaStoryViewerFromCell(self);
    id firstDelegate = thetaStoryPreferredSection(self, viewer);
    id secondDelegate = viewer;
    if (!firstDelegate || !secondDelegate) return;

    NSArray *items = theta_storyResolvedItemsForMarkAll(firstDelegate, secondDelegate);
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
        id viewModel = ThetaValueForKey(secondDelegate, @"currentViewModel");
        items = ThetaValueForKey(viewModel, @"items");
    }
    if (![items isKindOfClass:[NSArray class]]) return;

    for (id item in items) {
        shouldBeSeen = true;
        s_thetaAllowStorySeenReceipts = YES;
        (void)thetaStoryMarkItemAsSeen(self, item);
        s_thetaAllowStorySeenReceipts = NO;
        shouldBeSeen = false;
    }

    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"Marked all as seen!" subtitle:@"They know we are here." icon:[UIImage systemImageNamed:@"eye"] autoHide:4 openURL:nil];
    }

    thetaStorySkipIfEnabled(firstDelegate);
}

static void seenButtonPressedCurrent(IGStoryFullscreenCell *self) {
    id viewer = thetaStoryViewerFromCell(self);
    id section = thetaStoryPreferredSection(self, viewer);
    id currentItem = thetaStoryCurrentItem(section, viewer);
    if (!currentItem) {
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Mark failed" subtitle:@"Current story item not found." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
        return;
    }

    shouldBeSeen = true;
    s_thetaAllowStorySeenReceipts = YES;
    BOOL ok = thetaStoryMarkItemAsSeen(self, currentItem);
    s_thetaAllowStorySeenReceipts = NO;
    shouldBeSeen = false;

	if (ENABLED(@"Show Banners")) {
        if (ok) {
            [ThetaHelper showToastWithTitle:@"Marked as seen!" subtitle:@"They know we are here." icon:[UIImage systemImageNamed:@"eye"] autoHide:4 openURL:nil];
        } else {
            [ThetaHelper showToastWithTitle:@"Mark failed" subtitle:@"Couldn't update seen state." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:3 openURL:nil];
        }
	}

	if (ok) thetaStorySkipIfEnabled(section ?: thetaStorySectionControllerFromCell(self));
}

static NSMutableDictionary *lastSetupOwnerForCell;

/// Returns YES if the given IGUser's username is in the Story Ghost auto-mark list.
static BOOL isStoryOwnerInAutoMarkList(IGUser *owner) {
    if (!owner) return NO;
    NSString *username = nil;
    @try {
        if ([owner respondsToSelector:@selector(name)]) {
            username = [[owner performSelector:@selector(name)] copy];
        } else {
            id n = [owner valueForKey:@"username"];
            if (!n) n = [owner valueForKey:@"name"];
            if ([n isKindOfClass:[NSString class]]) username = [n copy];
        }
    } @catch (__unused NSException *e) {}
    if (!username.length) return NO;
    username = [username lowercaseString];
    NSArray *list = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_StoryGhost_AutoMarkUserIds"];
    if (![list isKindOfClass:[NSArray class]]) return NO;
    for (id obj in list) {
        if ([obj isKindOfClass:[NSString class]] && [[(NSString *)obj lowercaseString] isEqualToString:username])
            return YES;
    }
    return NO;
}

__attribute__((constructor))
static void StoryGhostInit() {
    lastSetupOwnerForCell = [NSMutableDictionary dictionary];
}

static void handleDownloadButtonTap(IGStoryFullscreenCell *self, UIButton *sender) {
    downloadButtonTapped(self);
}

static void handleDownloadButtonLongPress(IGStoryFullscreenCell *self, UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        downloadAllMedia(self);
    }
}

static void handleSeenButtonTap(IGStoryFullscreenCell *self, UIButton *sender) {
    seenButtonPressedCurrent(self);
}

static void handleSeenButtonLongPress(IGStoryFullscreenCell *self, UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        seenButtonPressedAll(self);
    }
}

static NSArray<IGUser *> *storyMentionUsersForCell(IGStoryFullscreenCell *self) {
    id firstDelegate = nil;
    @try {
        if ([self respondsToSelector:@selector(delegate)]) {
            firstDelegate = [self performSelector:@selector(delegate)];
        } else if ([self respondsToSelector:@selector(valueForKey:)]) {
            id container = [self valueForKey:@"containerView"];
            if (container && [container respondsToSelector:@selector(valueForKey:)]) {
                firstDelegate = [container valueForKey:@"delegate"];
            }
        }
    } @catch (__unused NSException *e) {}
    if (!firstDelegate) return @[];

    id currentItem = nil;
    @try {
        if ([firstDelegate respondsToSelector:@selector(currentStoryItem)]) {
            currentItem = [firstDelegate performSelector:@selector(currentStoryItem)];
        } else {
            currentItem = [firstDelegate valueForKey:@"currentStoryItem"];
        }
    } @catch (__unused NSException *e) {}
    if (!currentItem) return @[];

    NSArray *reelMentions = nil;
    @try {
        if ([currentItem respondsToSelector:@selector(reelMentions)]) {
            reelMentions = [currentItem performSelector:@selector(reelMentions)];
        } else {
            reelMentions = [currentItem valueForKey:@"reelMentions"];
        }
    } @catch (__unused NSException *e) {}
    if (![reelMentions isKindOfClass:[NSArray class]] || reelMentions.count == 0) {
        return @[];
    }

    NSMutableArray<IGUser *> *users = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *seenUsernames = [NSMutableOrderedSet orderedSet];
    for (id mention in reelMentions) {
        id user = nil;
        @try { user = [mention valueForKey:@"user"]; } @catch (__unused NSException *e) {}
        if (!user) continue;

        NSString *username = nil;
        @try {
            if ([user respondsToSelector:@selector(name)]) {
                username = [user performSelector:@selector(name)];
            }
        } @catch (__unused NSException *e) {}

        if (username.length > 0) {
            if ([seenUsernames containsObject:username]) continue;
            [seenUsernames addObject:username];
        }
        [users addObject:user];
    }

    return users;
}

static NSString *mentionDisplayTitle(IGUser *user) {
    NSString *displayName = nil;
    NSString *username = nil;
    @try { displayName = [user valueForKey:@"secondaryName"]; } @catch (__unused NSException *e) {}
    @try {
        if ([user respondsToSelector:@selector(name)]) {
            username = [user performSelector:@selector(name)];
        }
    } @catch (__unused NSException *e) {}

    if (displayName.length > 0 && username.length > 0) {
        return [NSString stringWithFormat:@"%@ (@%@)", displayName, username];
    }
    if (username.length > 0) {
        return [NSString stringWithFormat:@"@%@", username];
    }
    if (displayName.length > 0) {
        return displayName;
    }
    return @"Unknown user";
}

static UIImage *thetaImageFromBundle(NSString *fileName) {
    if (fileName.length == 0) return nil;
    NSString *mainBundlePath = [NSBundle mainBundle].bundlePath;
    NSString *resourceBundlePath = [[NSBundle mainBundle] pathForResource:@"ThetaResources" ofType:@"bundle"];
    NSString *rootBundlePath = mainBundlePath.length > 0 ? [mainBundlePath stringByAppendingPathComponent:@"ThetaResources.bundle"] : nil;
    NSString *resourcesBundlePath = [NSBundle mainBundle].resourcePath.length > 0 ? [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:@"ThetaResources.bundle"] : nil;
    NSArray<NSString *> *bundlePaths = @[
        rootBundlePath ?: @"",
        resourceBundlePath ?: @"",
        resourcesBundlePath ?: @"",
        @"/Library/Application Support/ThetaResources.bundle",
        @"/var/jb/Library/Application Support/ThetaResources.bundle"
    ];
    for (NSString *bundlePath in bundlePaths) {
        if (bundlePath.length == 0) continue;
        NSString *imagePath = [bundlePath stringByAppendingPathComponent:fileName];
        UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
        if (image) return image;
    }
    return nil;
}

// Returns a solid white SF Symbol image for use in toasts, so it renders white regardless of view tint.
static UIImage *thetaWhiteSystemSymbol(NSString *name) {
    if (name.length == 0) return nil;
    UIImage *img = [UIImage systemImageNamed:name];
    if (!img) return nil;
    CGSize size = img.size;
    CGFloat scale = img.scale > 0 ? img.scale : [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx && img.CGImage) {
        CGRect rect = CGRectMake(0, 0, size.width, size.height);
        CGContextTranslateCTM(ctx, 0, size.height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextClipToMask(ctx, rect, img.CGImage);
        [[UIColor whiteColor] setFill];
        CGContextFillRect(ctx, rect);
    }
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [result imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static void openProfileForUser(IGUser *user) {
    if (!user) return;
    NSString *username = nil;
    @try {
        if ([user respondsToSelector:@selector(name)]) {
            username = [user performSelector:@selector(name)];
        }
    } @catch (__unused NSException *e) {}
    if (username.length == 0) return;

    NSString *encoded = [username stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    if (encoded.length == 0) return;

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"instagram://user?username=%@", encoded]];
    if (!url) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[UIApplication sharedApplication] respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
    });
}

static UIMenu *buildMentionsMenu(IGStoryFullscreenCell *self) {
    if (!NSClassFromString(@"UIMenu") || !NSClassFromString(@"UIAction")) {
        return nil;
    }
    NSArray<IGUser *> *users = storyMentionUsersForCell(self);
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    if (users.count == 0) {
        UIAction *emptyAction = [UIAction actionWithTitle:@"No mentions found"
                                                   image:[UIImage systemImageNamed:@"person.crop.circle.badge.xmark"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
            // No-op
        }];
        emptyAction.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:emptyAction];
    } else {
        for (IGUser *user in users) {
            NSString *title = mentionDisplayTitle(user);
            UIAction *action = [UIAction actionWithTitle:title
                                                   image:[UIImage systemImageNamed:@"person.crop.circle"]
                                              identifier:nil
                                                 handler:^(__kindof UIAction *action) {
                openProfileForUser(user);
            }];
            [actions addObject:action];
        }
    }

    return [UIMenu menuWithTitle:@"Story Mentions" children:actions];
}

static void presentMentionsAlert(IGStoryFullscreenCell *self) {
    NSArray<IGUser *> *users = storyMentionUsersForCell(self);
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    if (users.count == 0) {
        [actions addObject:@{ @"title": @"No mentions found", @"handler": ^{ /* no-op */ } }];
    } else {
        for (IGUser *user in users) {
            NSString *title = mentionDisplayTitle(user);
            [actions addObject:@{
                @"title": title ?: @"@user",
                @"handler": ^{
                    openProfileForUser(user);
                }
            }];
        }
    }
    [actions addObject:@{ @"title": @"Cancel", @"handler": ^{ /* no-op */ } }];
    [ThetaHelper showCustomAlertWithActions:@"Story Mentions" description:@"Select a user to open their profile." actions:actions];
}

static Class theta_storyFullscreenCellClass(void) {
    static Class cached = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = NSClassFromString(@"IGStoryFullscreenCell");
        if (cached) return;
        Class alt = NSClassFromString(@"IGStoryCell");
        if (alt && [alt isSubclassOfClass:[UICollectionViewCell class]])
            cached = alt;
    });
    return cached;
}

static UIView *thetaStoryOverlayHost(IGStoryFullscreenCell *cell) {
    if (!cell) return nil;
    for (NSString *key in @[ @"overlayView", @"_overlayView", @"fullscreenOverlayView", @"storyOverlayView" ]) {
        id v = nil;
        @try { v = [cell valueForKey:key]; } @catch (__unused NSException *e) {}
        if ([v isKindOfClass:[UIView class]]) return v;
    }
    return (UIView *)cell;
}

static id thetaStoryViewModelFromSection(id section, IGStoryFullscreenCell *cell) {
    for (NSString *key in @[ @"viewModel", @"currentViewModel", @"_viewModel", @"storyViewModel", @"reelViewModel" ]) {
        id vm = ThetaValueForKey(section, key);
        if (vm) return vm;
    }
    id viewer = thetaStoryViewerFromCell(cell);
    for (NSString *key in @[ @"currentViewModel", @"viewModel" ]) {
        id vm = ThetaValueForKey(viewer, key);
        if (vm) return vm;
    }
    return nil;
}

static id thetaStoryOwnerFromViewModel(id viewModel) {
    for (NSString *key in @[ @"owner", @"reelOwner", @"storyOwner", @"ownerUser", @"user", @"poster" ]) {
        id o = ThetaValueForKey(viewModel, key);
        if (o) return o;
    }
    return nil;
}

static BOOL thetaStoryViewHasTaggedButtons(UIView *view) {
    if (!view) return NO;
    for (UIView *sub in view.subviews) {
        if (sub.tag == kThetaStoryButtonTag) return YES;
    }
    return NO;
}

static void thetaStoryRemoveTaggedButtonsFromView(UIView *view) {
    if (!view) return;
    for (UIView *sub in [view.subviews copy]) {
        if (sub.tag == kThetaStoryButtonTag) [sub removeFromSuperview];
    }
}

static void setupButtons(IGStoryFullscreenCell *self) {
    static BOOL s_guard;
    if (s_guard) return;
    if (!self || ![(UIView *)self window]) return;
    if (!(ENABLED(@"Save Media") || ENABLED(@"Story Ghost") || ENABLED(@"Seen Receipts Stay Local") || ENABLED(@"See Story Mentions"))) {
        return;
    }

    s_guard = YES;
    @try {
    id firstDelegate = thetaStorySectionControllerFromCell(self);
    id viewModel = thetaStoryViewModelFromSection(firstDelegate, self);
    IGUser *owner = thetaStoryOwnerFromViewModel(viewModel);

    UIView *host = thetaStoryOverlayHost(self);
    if (!host) host = (UIView *)self;

    NSNumber *cellKey = @((uintptr_t)self);
    NSString *ownerKey = thetaStoryOwnerKey(owner) ?: @"";
    NSString *lastOwnerKey = lastSetupOwnerForCell[cellKey];
    BOOL alreadyShown = thetaStoryViewHasTaggedButtons(host) || thetaStoryViewHasTaggedButtons((UIView *)self);
    if (alreadyShown && [lastOwnerKey isKindOfClass:[NSString class]] && [lastOwnerKey isEqualToString:ownerKey]) {
        for (UIView *button in host.subviews) {
            if (button.tag == kThetaStoryButtonTag) [host bringSubviewToFront:button];
        }
        return;
    }
    lastSetupOwnerForCell[cellKey] = ownerKey;

    thetaStoryRemoveTaggedButtonsFromView((UIView *)self);
    thetaStoryRemoveTaggedButtonsFromView(host);

    UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    downloadButton.tag = kThetaStoryButtonTag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Save Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [downloadButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        NSLog(@"Error setting download button color: %@", exception);
        [downloadButton setTintColor:[UIColor labelColor]];
    }
    [downloadButton setImage:[UIImage systemImageNamed:@"arrow.down"] forState:UIControlStateNormal];
    downloadButton.layer.shadowColor = [UIColor blackColor].CGColor;
    downloadButton.layer.shadowOpacity = 0.4;
    downloadButton.layer.shadowOffset = CGSizeMake(-2, 0);
    downloadButton.layer.shadowRadius = 3;
    downloadButton.layer.masksToBounds = NO;
    [downloadButton setTranslatesAutoresizingMaskIntoConstraints:false];

    UIButton *seenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    seenButton.tag = kThetaStoryButtonTag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Seen Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [seenButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        NSLog(@"Error setting seen button color: %@", exception);
        [seenButton setTintColor:[UIColor labelColor]];
    }
    [seenButton setImage:[UIImage systemImageNamed:@"eye"] forState:UIControlStateNormal];
    seenButton.layer.shadowColor = [UIColor blackColor].CGColor;
    seenButton.layer.shadowOpacity = 0.4;
    seenButton.layer.shadowOffset = CGSizeMake(-2, 0);
    seenButton.layer.shadowRadius = 3;
    seenButton.layer.masksToBounds = NO;
    [seenButton setTranslatesAutoresizingMaskIntoConstraints:false];

    UIButton *localSeenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    localSeenButton.tag = kThetaStoryButtonTag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Seen Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [localSeenButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        [localSeenButton setTintColor:[UIColor labelColor]];
    }
    UIImage *localIcon = [UIImage systemImageNamed:@"iphone"];
    if (!localIcon) localIcon = [UIImage systemImageNamed:@"iphone.circle"];
    if (!localIcon) localIcon = [UIImage systemImageNamed:@"internaldrive"];
    [localSeenButton setImage:localIcon forState:UIControlStateNormal];
    localSeenButton.layer.shadowColor = [UIColor blackColor].CGColor;
    localSeenButton.layer.shadowOpacity = 0.4;
    localSeenButton.layer.shadowOffset = CGSizeMake(-2, 0);
    localSeenButton.layer.shadowRadius = 3;
    localSeenButton.layer.masksToBounds = NO;
    [localSeenButton setTranslatesAutoresizingMaskIntoConstraints:false];

    BOOL downloadVideos = ENABLED(@"Save Media");
    BOOL hideSeenState = ENABLED(@"Story Ghost");
    BOOL showLocalSeenOnly = ENABLED(@"Seen Receipts Stay Local");
    BOOL showMentions = ENABLED(@"See Story Mentions");

    NSArray *items = nil;
    @try {
        items = [viewModel valueForKey:@"items"];
    } @catch (__unused NSException *e) {}
    NSInteger itemCount = [items isKindOfClass:[NSArray class]] ? items.count : 0;

    UIButton *mentionsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    mentionsButton.tag = kThetaStoryButtonTag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:@"Mentions Button Color_Color"];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [mentionsButton setTintColor:color ?: [UIColor labelColor]];
    } @catch (NSException *exception) {
        NSLog(@"Error setting mentions button color: %@", exception);
        [mentionsButton setTintColor:[UIColor labelColor]];
    }
    UIImage *mentionsImage = nil;
    @try {
        mentionsImage = thetaImageFromBundle(@"ig_icon_story_mention_pano_outline_24_Normal2x.png");
    } @catch (__unused NSException *exception) {}
    [mentionsButton setImage:mentionsImage ?: [UIImage systemImageNamed:@"at"] forState:UIControlStateNormal];
    mentionsButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    mentionsButton.imageEdgeInsets = UIEdgeInsetsMake(2, 2, 2, 2);
    mentionsButton.layer.shadowColor = [UIColor blackColor].CGColor;
    mentionsButton.layer.shadowOpacity = 0.4;
    mentionsButton.layer.shadowOffset = CGSizeMake(-2, 0);
    mentionsButton.layer.shadowRadius = 3;
    mentionsButton.layer.masksToBounds = NO;
    [mentionsButton setTranslatesAutoresizingMaskIntoConstraints:false];

    NSArray<IGUser *> *mentionUsers = nil;
    @try {
        mentionUsers = storyMentionUsersForCell(self);
    } @catch (__unused NSException *exception) {}
    NSInteger mentionCount = [mentionUsers isKindOfClass:[NSArray class]] ? mentionUsers.count : 0;
    BOOL hasMentions = (mentionCount > 0);

    mentionsButton.enabled = hasMentions;
    mentionsButton.alpha = hasMentions ? 1.0 : 0.5;

    UILabel *mentionsBadge = [[UILabel alloc] init];
    mentionsBadge.textAlignment = NSTextAlignmentCenter;
    mentionsBadge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    mentionsBadge.textColor = [UIColor whiteColor];
    mentionsBadge.backgroundColor = [UIColor systemRedColor];
    mentionsBadge.layer.cornerRadius = 8;
    mentionsBadge.layer.masksToBounds = YES;
    mentionsBadge.text = [NSString stringWithFormat:@"%ld", (long)mentionCount];
    mentionsBadge.hidden = !hasMentions;
    mentionsBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [mentionsButton addSubview:mentionsBadge];
    [NSLayoutConstraint activateConstraints:@[
        [mentionsBadge.widthAnchor constraintGreaterThanOrEqualToConstant:16],
        [mentionsBadge.heightAnchor constraintEqualToConstant:16],
        [mentionsBadge.trailingAnchor constraintEqualToAnchor:mentionsButton.trailingAnchor constant:2],
        [mentionsBadge.bottomAnchor constraintEqualToAnchor:mentionsButton.bottomAnchor constant:2]
    ]];

    UIMenu *mentionsMenu = nil;
    @try {
        mentionsMenu = buildMentionsMenu(self);
    } @catch (__unused NSException *exception) {}
    if (hasMentions && mentionsMenu && [mentionsButton respondsToSelector:@selector(setShowsMenuAsPrimaryAction:)]) {
        mentionsButton.showsMenuAsPrimaryAction = YES;
        mentionsButton.menu = mentionsMenu;
    }

    NSMutableArray<UIButton *> *buttonStack = [NSMutableArray array];
    if (downloadVideos) {
        [buttonStack addObject:downloadButton];
    }
    if (hideSeenState) {
        [buttonStack addObject:seenButton];
    }
    if (showLocalSeenOnly) {
        [buttonStack addObject:localSeenButton];
    }
    if (showMentions) {
        [buttonStack addObject:mentionsButton];
    }

    UIButton *previousButton = nil;
    for (UIButton *button in buttonStack) {
        ThetaSetCaptureHiding(button);
        [host addSubview:button];
        [host bringSubviewToFront:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.trailingAnchor constraintEqualToAnchor:host.trailingAnchor constant:-8],
            [button.widthAnchor constraintEqualToConstant:30],
            [button.heightAnchor constraintEqualToConstant:30]
        ]];

        if (!previousButton) {
            [NSLayoutConstraint activateConstraints:@[
                [button.bottomAnchor constraintEqualToAnchor:host.bottomAnchor constant:-150]
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [button.bottomAnchor constraintEqualToAnchor:previousButton.topAnchor constant:-20]
            ]];
        }
        previousButton = button;
    }

    __weak IGStoryFullscreenCell *weakSelf = self;
    if (downloadVideos) {
        thetaStoryAddTap(downloadButton, ^{
            IGStoryFullscreenCell *cell = weakSelf;
            if (cell) downloadButtonTapped(cell);
        });
        
        // Add long press gesture for downloading all
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] init];
        [longPress addActionBlock:^(UIGestureRecognizer *recognizer) {
            if (((UILongPressGestureRecognizer *)recognizer).state == UIGestureRecognizerStateBegan) {
                IGStoryFullscreenCell *cell = weakSelf;
                if (cell) downloadAllMedia(cell);
            }
        }];
        longPress.minimumPressDuration = 0.5;
        [downloadButton addGestureRecognizer:longPress];
    }

    if (hideSeenState) {
        thetaStoryAddTap(seenButton, ^{
            IGStoryFullscreenCell *cell = weakSelf;
            if (cell) seenButtonPressedCurrent(cell);
        });

        // Long press: show menu — Mark all as seen / Add owner to auto-mark list
        NSString *ownerUsername = nil;
        @try {
            if ([owner respondsToSelector:@selector(name)]) {
                ownerUsername = [owner performSelector:@selector(name)];
            } else {
                id n = ThetaValueForKey(owner, @"username");
                if (!n) n = ThetaValueForKey(owner, @"name");
                if ([n isKindOfClass:[NSString class]]) ownerUsername = n;
            }
        } @catch (__unused NSException *e) {}
        NSString *displayName = ownerUsername.length ? [NSString stringWithFormat:@"@%@", ownerUsername] : @"this user";
        __weak IGStoryFullscreenCell *weakCell = self;
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] init];
        [longPress addActionBlock:^(UIGestureRecognizer *recognizer) {
            if (((UILongPressGestureRecognizer *)recognizer).state != UIGestureRecognizerStateBegan) return;

            // Determine current membership so we can show Add/Remove appropriately.
            BOOL inAutoList = NO;
            NSString *lower = nil;
            if (ownerUsername.length) {
                lower = [[ownerUsername lowercaseString] copy];
                NSArray *stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_StoryGhost_AutoMarkUserIds"];
                if ([stored isKindOfClass:[NSArray class]] && [stored containsObject:lower]) {
                    inAutoList = YES;
                }
            }

            NSString *toggleTitle = inAutoList
                ? [NSString stringWithFormat:@"Remove %@ from auto-mark list", displayName]
                : [NSString stringWithFormat:@"Add %@ to auto-mark list", displayName];

            NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];

            // Mark all as seen — run after alert dismisses so delegate chain is still valid
            [actions addObject:@{
                @"title": @"Mark all as seen",
                @"handler": ^(id sender){
                    IGStoryFullscreenCell *cell = weakCell;
                    if (!cell) return;
                    __strong IGStoryFullscreenCell *strongCell = cell;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!strongCell) return;
                        seenButtonPressedAll(strongCell);
                    });
                }
            }];

            // Add / Remove from auto-mark list
            [actions addObject:@{
                @"title": toggleTitle,
                @"handler": ^(id sender){
                    if (!ownerUsername.length) return;
                    NSString *lowerLocal = [ownerUsername lowercaseString];
                    NSMutableArray *list = [NSMutableArray array];
                    NSArray *stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"Theta_StoryGhost_AutoMarkUserIds"];
                    if ([stored isKindOfClass:[NSArray class]]) [list addObjectsFromArray:stored];

                    BOOL currentlyInList = [list containsObject:lowerLocal];
                    if (currentlyInList) {
                        // Remove from list
                        [list removeObject:lowerLocal];
                        [[NSUserDefaults standardUserDefaults] setObject:list forKey:@"Theta_StoryGhost_AutoMarkUserIds"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        if (ENABLED(@"Show Banners")) {
                            UIImage *icon = thetaColoredSystemSymbol(@"minus.circle", [UIColor systemRedColor]);
                            [ThetaHelper showToastWithTitle:[NSString stringWithFormat:@"Removed %@ from list", displayName]
                                                    subtitle:@"They won't know we're here."
                                                        icon:icon
                                                    autoHide:3
                                                     openURL:nil];
                        }
                    } else {
                        // Add to list
                        [list addObject:lowerLocal];
                        [[NSUserDefaults standardUserDefaults] setObject:list forKey:@"Theta_StoryGhost_AutoMarkUserIds"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        if (ENABLED(@"Show Banners")) {
                            UIImage *icon = thetaColoredSystemSymbol(@"checkmark.circle.fill", [UIColor systemGreenColor]);
                            [ThetaHelper showToastWithTitle:[NSString stringWithFormat:@"Added %@ to list", displayName]
                                                    subtitle:@"They will know we're here."
                                                        icon:icon
                                                    autoHide:3
                                                     openURL:nil];
                        }
                    }
                }
            }];

            // Cancel
            [actions addObject:@{
                @"title": @"Cancel",
                @"handler": ^(id sender){}
            }];

            [ThetaHelper showCustomAlertWithActions:@"✋ Woah! Hold up!"
                                         description:@"What would you like to do?"
                                             actions:actions];
        }];
        longPress.minimumPressDuration = 0.5;
        [seenButton addGestureRecognizer:longPress];
    }

    if (showLocalSeenOnly) {
        thetaStoryAddTap(localSeenButton, ^{
            IGStoryFullscreenCell *cell = weakSelf;
            if (cell) handleLocalSeenTap(cell, localSeenButton);
        });
        UILongPressGestureRecognizer *localLP = [[UILongPressGestureRecognizer alloc] init];
        [localLP addActionBlock:^(UIGestureRecognizer *recognizer) {
            IGStoryFullscreenCell *cell = weakSelf;
            if (cell) handleLocalSeenLongPress(cell, (UILongPressGestureRecognizer *)recognizer);
        }];
        localLP.minimumPressDuration = 0.5;
        [localSeenButton addGestureRecognizer:localLP];
    }

    if (showMentions) {
        [mentionsButton handleControlEvent:UIControlEventTouchDown withBlock:^(id sender) {
            if (!hasMentions) return;
            IGStoryFullscreenCell *cell = weakSelf;
            if (!cell) return;
            @try {
                UIMenu *menu = buildMentionsMenu(cell);
                if (menu) {
                    mentionsButton.menu = menu;
                }
            } @catch (__unused NSException *exception) {}
        }];
        thetaStoryAddTap(mentionsButton, ^{
            if (!hasMentions) return;
            IGStoryFullscreenCell *cell = weakSelf;
            if (!cell) return;
            if (!mentionsButton.menu) {
                presentMentionsAlert(cell);
            }
        });
    }

    if (hideSeenState && isStoryOwnerInAutoMarkList(owner)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IGStoryFullscreenCell *cell = weakSelf;
            if (!cell) return;
            seenButtonPressedCurrent(cell);
            id firstDel = nil;
            @try {
                if ([cell respondsToSelector:@selector(delegate)]) {
                    firstDel = [cell performSelector:@selector(delegate)];
                } else {
                    id container = ThetaValueForKey(cell, @"containerView");
                    if (container) firstDel = ThetaValueForKey(container, @"delegate");
                }
            } @catch (__unused NSException *e) {}
            thetaStorySkipIfEnabled(firstDel);
        });
    }
    } @finally {
        s_guard = NO;
    }
}

static id (*orig_storyGhost)(id self, SEL _cmd);
static id hook_storyGhost(id self, SEL _cmd) {
    id media = nil;
    if (orig_storyGhost) {
        @try {
            media = orig_storyGhost(self, _cmd);
        } @catch (__unused NSException *e) {
            media = nil;
        }
    }

    @try {
        setupButtons(self);
    } @catch (NSException *exception) {
        NSLog(@"[Theta] StoryGhost setupButtons: %@", exception);
    }
    return media;
}

static void (*orig_storyGhostLayout)(id self, SEL _cmd);
static void hook_storyGhostLayout(id self, SEL _cmd) {
    if (orig_storyGhostLayout) orig_storyGhostLayout(self, _cmd);
    @try {
        setupButtons(self);
    } @catch (NSException *exception) {
        NSLog(@"[Theta] StoryGhost layout setupButtons: %@", exception);
    }
}

static void (*orig_storyGhostDidMoveToWindow)(id self, SEL _cmd);
static void hook_storyGhostDidMoveToWindow(id self, SEL _cmd) {
    if (orig_storyGhostDidMoveToWindow) orig_storyGhostDidMoveToWindow(self, _cmd);
    if (![(UIView *)self window]) return;
    @try {
        setupButtons(self);
    } @catch (__unused NSException *e) {}
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { setupButtons(self); } @catch (__unused NSException *e) {}
    });
}

static void (*orig_storyOverlayLayout)(id self, SEL _cmd);
static void hook_storyOverlayLayout(id self, SEL _cmd) {
    if (orig_storyOverlayLayout) orig_storyOverlayLayout(self, _cmd);
    UIView *v = (UIView *)self;
    Class cellCls = theta_storyFullscreenCellClass();
    while (v) {
        if (cellCls && [v isKindOfClass:cellCls]) {
            @try { setupButtons((IGStoryFullscreenCell *)v); } @catch (__unused NSException *e) {}
            break;
        }
        v = v.superview;
    }
    for (UIView *sub in [((UIView *)self).subviews copy]) {
        if (sub.tag == kThetaStoryButtonTag) [(UIView *)self bringSubviewToFront:sub];
    }
}

static void hook_storyGhost2(id self, SEL _cmd, id fullscreenSectionController, id didMarkItemAsSeen) {
    if (!orig_storyGhost2) return;

    if (!ENABLED(@"Story Ghost")) {
        if (ENABLED(@"Seen Receipts Stay Local")) {
            THStorySeenReceiptNetworkGuardEnterWithContext(fullscreenSectionController, self);
            @try {
                orig_storyGhost2(self, _cmd, fullscreenSectionController, didMarkItemAsSeen);
            } @catch (__unused NSException *e) {
            }
            THStorySeenReceiptNetworkGuardLeave();
            return;
        }
        @try {
            orig_storyGhost2(self, _cmd, fullscreenSectionController, didMarkItemAsSeen);
        } @catch (__unused NSException *e) {
        }
        return;
    }

    if (shouldBeSeen) {
        shouldBeSeen = false;
        @try {
            orig_storyGhost2(self, _cmd, fullscreenSectionController, didMarkItemAsSeen);
        } @catch (__unused NSException *e) {
        }
    }
}

static void hook_storyGhost3(id self, SEL _cmd, id fullscreenSectionController, id didMarkItemAsSeen, NSInteger entryPoint) {
    if (!orig_storyGhost3) return;
    if (!ENABLED(@"Story Ghost")) {
        if (ENABLED(@"Seen Receipts Stay Local")) {
            THStorySeenReceiptNetworkGuardEnterWithContext(fullscreenSectionController, self);
            @try {
                orig_storyGhost3(self, _cmd, fullscreenSectionController, didMarkItemAsSeen, entryPoint);
            } @catch (__unused NSException *e) {}
            THStorySeenReceiptNetworkGuardLeave();
            return;
        }
        @try {
            orig_storyGhost3(self, _cmd, fullscreenSectionController, didMarkItemAsSeen, entryPoint);
        } @catch (__unused NSException *e) {}
        return;
    }
    if (shouldBeSeen) {
        shouldBeSeen = false;
        @try {
            orig_storyGhost3(self, _cmd, fullscreenSectionController, didMarkItemAsSeen, entryPoint);
        } @catch (__unused NSException *e) {}
    }
}

static void hook_sectionMarkCurrent(id self, SEL _cmd) {
    if (!orig_sectionMarkCurrent) return;
    if (!ENABLED(@"Story Ghost")) {
        @try { orig_sectionMarkCurrent(self, _cmd); } @catch (__unused NSException *e) {}
        return;
    }
    if (shouldBeSeen) {
        shouldBeSeen = false;
        @try { orig_sectionMarkCurrent(self, _cmd); } @catch (__unused NSException *e) {}
    }
}

static void hook_sectionMarkItem(id self, SEL _cmd, id item) {
    if (!orig_sectionMarkItem) return;
    if (!ENABLED(@"Story Ghost")) {
        @try { orig_sectionMarkItem(self, _cmd, item); } @catch (__unused NSException *e) {}
        return;
    }
    if (shouldBeSeen) {
        shouldBeSeen = false;
        @try { orig_sectionMarkItem(self, _cmd, item); } @catch (__unused NSException *e) {}
    }
}

static void downloadStoryMedia(id self) {
    @try {
        IGStoryFullscreenCell *firstDelegate = nil;
        @try {
            id container = [self valueForKey:@"containerView"];
            if (container && [container respondsToSelector:@selector(valueForKey:)]) {
                firstDelegate = [container valueForKey:@"delegate"];
            }
        } @catch (__unused NSException *e) {}
        if (!firstDelegate) {
            NSLog(@"No delegate found for story download");
            return;
        }
        
        IGPhoto *photo = nil;
        @try { photo = [firstDelegate valueForKey:@"_photo"]; } @catch (__unused NSException *e) {}
        if (!photo) {
            NSLog(@"No photo found for story download");
            return;
        }
        
        NSArray *originalImageVersions = nil;
        @try { originalImageVersions = [photo valueForKey:@"_originalImageVersions"]; } @catch (__unused NSException *e) {}
        if (!originalImageVersions || originalImageVersions.count == 0) {
            NSLog(@"No image versions found for story download");
            return;
        }
        
        id photoURL = [originalImageVersions lastObject];
        NSURL *url = nil;
        @try { url = [photoURL valueForKey:@"url"]; } @catch (__unused NSException *e) {}
        if (!url) {
            NSLog(@"No URL found for story download");
            return;
        }

        NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
        if (saveMethod == 0) {
            // Check photo library permission first
            PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
            if (status == PHAuthorizationStatusNotDetermined) {
                [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus authorizationStatus) {
                    if (authorizationStatus == PHAuthorizationStatusAuthorized) {
                        performStoryDownloadWithURL(url);
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (ENABLED(@"Show Banners")) {
                                [ThetaHelper showToastWithTitle:@"Permission Denied" subtitle:@"Please enable photo library access in Settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                            }
                        });
                    }
                }];
            } else if (status == PHAuthorizationStatusAuthorized) {
                performStoryDownloadWithURL(url);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Permission Denied" subtitle:@"Please enable photo library access in Settings." icon:[UIImage systemImageNamed:@"exclamationmark.triangle"] autoHide:4 openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                    }
                });
            }
        } else {
            // Local folder mode does not require Photos permission
            performStoryDownloadWithURL(url);
        }
    } @catch (NSException *exception) {
        NSLog(@"Error downloading image: %@", exception);
    }
}

static void performStoryDownloadWithURL(NSURL *url) {
    @autoreleasepool {
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error downloading file: %@", error);
                return;
            }

            NSError *moveError;
            NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *newFilename = [NSString stringWithFormat:@"story-%@.jpg", [[NSUUID UUID] UUIDString]];
            NSString *permanentFilePath = [documentsPath stringByAppendingPathComponent:newFilename];
            
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:permanentFilePath] error:&moveError];
            if (moveError) {
                NSLog(@"Error moving downloaded file: %@", moveError);
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
                if (saveMethod == 0) {
                    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                        [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:[NSURL fileURLWithPath:permanentFilePath]];
                    } completionHandler:^(BOOL success, NSError *error) {
                        if (!success) {
                            NSLog(@"Error saving image to camera roll: %@", error);
                        }

                        // Clean up temporary file after saving to Photos
                        NSError *deleteError;
                        [[NSFileManager defaultManager] removeItemAtPath:permanentFilePath error:&deleteError];
                        if (deleteError) {
                            NSLog(@"Error deleting temporary file: %@", deleteError);
                        }

                        if (success && ENABLED(@"Show Banners")) {
                            [ThetaHelper showToastWithTitle:@"Story saved!" subtitle:@"Tap here to go to camera roll." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:[NSURL URLWithString:@"photos-redirect://"]];
                        }
                    }];
                } else {
                    // Local folder mode: move into Documents/AudioNotes
                    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                    NSString *audioNotesDir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
                    BOOL isDir = NO;
                    if (![[NSFileManager defaultManager] fileExistsAtPath:audioNotesDir isDirectory:&isDir] || !isDir) {
                        [[NSFileManager defaultManager] createDirectoryAtPath:audioNotesDir withIntermediateDirectories:YES attributes:nil error:nil];
                    }
                    NSString *destPath = [audioNotesDir stringByAppendingPathComponent:[permanentFilePath lastPathComponent]];
                    NSError *moveErr = nil;
                    if (![[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:&moveErr]) {
                        NSString *unique = [NSString stringWithFormat:@"story-%@.jpg", [[NSUUID UUID] UUIDString]];
                        destPath = [audioNotesDir stringByAppendingPathComponent:unique];
                        [[NSFileManager defaultManager] moveItemAtPath:permanentFilePath toPath:destPath error:nil];
                    }
                    if (ENABLED(@"Show Banners")) {
                        [ThetaHelper showToastWithTitle:@"Story saved!" subtitle:@"Saved to local folder." icon:[UIImage systemImageNamed:@"checkmark.circle.fill"] autoHide:3 openURL:nil];
                    }
                }
            });
        }];
        [downloadTask resume];
    }
}

void THRegisterStoryGhostHooks(void) {
    Class cellCls = theta_storyFullscreenCellClass() ?: ThetaFirstClass(@[ @"IGStoryFullscreenCell" ]);
    Class viewerCls = ThetaFirstClass(@[ @"IGStoryViewerViewController" ]);
    Class overlayCls = ThetaFirstClass(@[
        @"IGStoryFullscreenOverlayView",
        @"IGStoryOverlayView"
    ]);
    NullHookMessageIfPresent(cellCls, @selector(mediaView), (void *)hook_storyGhost, &orig_storyGhost);
    NullHookMessageIfPresent(cellCls, @selector(layoutSubviews), (void *)hook_storyGhostLayout, &orig_storyGhostLayout);
    NullHookMessageIfPresent(cellCls, @selector(didMoveToWindow), (void *)hook_storyGhostDidMoveToWindow, &orig_storyGhostDidMoveToWindow);
    NullHookMessageIfPresent(overlayCls, @selector(layoutSubviews), (void *)hook_storyOverlayLayout, &orig_storyOverlayLayout);

    SEL markSel = @selector(fullscreenSectionController:didMarkItemAsSeen:);
    SEL markSel3 = NSSelectorFromString(@"fullscreenSectionController:didMarkItemAsSeen:entryPoint:");
    NullHookMessageIfPresent(viewerCls, markSel, (void *)hook_storyGhost2, &orig_storyGhost2);
    NullHookMessageIfPresent(viewerCls, markSel3, (void *)hook_storyGhost3, &orig_storyGhost3);

    Class sectionCls = ThetaFirstClass(@[ @"IGStoryFullscreenSectionController" ]);
    NullHookMessageIfPresent(sectionCls, NSSelectorFromString(@"markCurrentItemAsSeen"), (void *)hook_sectionMarkCurrent, &orig_sectionMarkCurrent);
    NullHookMessageIfPresent(sectionCls, NSSelectorFromString(@"markItemAsSeen:"), (void *)hook_sectionMarkItem, &orig_sectionMarkItem);

    // Extra named classes only — objc_getClassList realizeAllClasses() crashes IG 446+ Swift metadata.
    NSArray<NSString *> *extraViewers = @[
        @"IGStoryViewerViewController",
        @"IGStoryViewerViewControllerV2"
    ];
    NSArray<NSString *> *extraSections = @[
        @"IGStoryFullscreenSectionController",
        @"IGStorySectionController"
    ];
    for (NSString *cn in extraViewers) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        if (!orig_storyGhost2)
            NullHookMessageIfPresent(c, markSel, (void *)hook_storyGhost2, &orig_storyGhost2);
        if (!orig_storyGhost3)
            NullHookMessageIfPresent(c, markSel3, (void *)hook_storyGhost3, &orig_storyGhost3);
    }
    for (NSString *cn in extraSections) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        if (!orig_sectionMarkCurrent)
            NullHookMessageIfPresent(c, NSSelectorFromString(@"markCurrentItemAsSeen"), (void *)hook_sectionMarkCurrent, &orig_sectionMarkCurrent);
        if (!orig_sectionMarkItem)
            NullHookMessageIfPresent(c, NSSelectorFromString(@"markItemAsSeen:"), (void *)hook_sectionMarkItem, &orig_sectionMarkItem);
        if (!orig_sectionMarkItem)
            NullHookMessageIfPresent(c, NSSelectorFromString(@"_markItemAsSeen:"), (void *)hook_sectionMarkItem, &orig_sectionMarkItem);
    }

    if (!orig_storyGhost && !orig_storyGhostLayout && !orig_storyGhostDidMoveToWindow) {
        NSLog(@"[Theta] StoryGhost: no cell overlay hook installed — story buttons may be unavailable");
    }
    if (!orig_storyGhost2 && !orig_storyGhost3) {
        NSLog(@"[Theta] StoryGhost: didMarkItemAsSeen hook missing orig — will try live msgSend + section mark APIs");
    }
}