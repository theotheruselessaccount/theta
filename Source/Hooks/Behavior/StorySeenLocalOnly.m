#import "Include.h"
#import "Include/ThetaTweakCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

/* Block story seen uploads while optionally leaving local/UI state untouched. */

#pragma mark - Networker ivar swap (idempotent merges)

static __weak id thetaLegacySeenUploader = nil;
static __weak id thetaSundialSeenManager = nil;
/** IDA: story marks can use `-[IGUserSession reelSeenStateUploader]` in parallel to pending-store uploaders. */
static __weak id thetaReelSeenStateUploader = nil;

/** Each entry: @{ @"obj": upload object, @"ivar": @(ivar_ptr), @"was": prior networker } */
static NSMutableArray<NSDictionary *> *thetaSeenNetSwapRecords = nil;

static BOOL theta_seenClassHintsUploader(__unsafe_unretained id obj) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    NSRange su = [n rangeOfString:@"SeenStateUploader"];
    if (su.location != NSNotFound) return YES;
    NSRange ss = [n rangeOfString:@"StorySeen"];
    NSRange up = [n rangeOfString:@"Upload"];
    if (ss.location != NSNotFound && up.location != NSNotFound) return YES;
    return NO;
}

static BOOL theta_seenClassHintsSwiftManager(__unsafe_unretained id obj) {
    if (!obj) return NO;
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n rangeOfString:@"SundialSeenState"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"IGSundialSeenStateManager"].location != NSNotFound) return YES;
    return NO;
}

static BOOL theta_classHintsSeenNetworkingHost(__unsafe_unretained id obj) {
    if (!obj) return NO;
    if (theta_seenClassHintsUploader(obj) || theta_seenClassHintsSwiftManager(obj)) return YES;
    NSString *n = NSStringFromClass(object_getClass(obj));
    if ([n rangeOfString:@"SeenState"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"PendingSeen"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"StorySeen"].location != NSNotFound) return YES;
    return NO;
}

static BOOL theta_ivarNameHintsInjectableNetworkService(NSString *iname) {
    if (!iname.length) return NO;
    NSString *l = iname.lowercaseString;
    if ([l containsString:@"networker"]) return YES;
    if ([l containsString:@"graphql"] && ![l containsString:@"schema"]) return YES;
    if ([l containsString:@"tigon"]) return YES;
    if ([l containsString:@"bladerunner"]) return YES;
    if ([l isEqualToString:@"msi"]) return YES;
    return NO;
}

/** Fullscreen VC / section: only nil networking ivars clearly tied to story seen. */
static BOOL theta_ivarNameHintsStoryReceiptNetwork(NSString *iname) {
    if (!theta_ivarNameHintsInjectableNetworkService(iname)) return NO;
    NSString *l = iname.lowercaseString;
    return [l containsString:@"seen"] || [l containsString:@"pending"] || [l containsString:@"receipt"]
        || [l containsString:@"sundial"] || [l containsString:@"upload"] || [l containsString:@"state"];
}

static BOOL theta_holderAcceptsNetworkishStrip(__unsafe_unretained id holder) {
    if (!holder) return NO;
    // Only strip known seen-upload hosts. Never touch the story viewer / section
    // controller — nil'ing their "state"/"upload" ivars crashes didMarkItemAsSeen.
    return theta_classHintsSeenNetworkingHost(holder);
}

static __unsafe_unretained id thetaHarvestSection = nil;
static __unsafe_unretained id thetaHarvestViewer = nil;

static NSString *theta_swapKey(id obj, Ivar iv) {
    return [NSString stringWithFormat:@"%p|%p", obj, iv];
}

static void theta_recordNilNetworkishIvar(id holder, Ivar iv) {
    if (!holder || !iv) return;
    NSString *iname = @(ivar_getName(iv));
    BOOL allow = NO;
    if (theta_classHintsSeenNetworkingHost(holder))
        allow = theta_ivarNameHintsInjectableNetworkService(iname);
    else if (theta_holderAcceptsNetworkishStrip(holder))
        allow = theta_ivarNameHintsStoryReceiptNetwork(iname);
    if (!allow) return;

    const char *enc = ivar_getTypeEncoding(iv);
    if (!enc || enc[0] != '@') return;
    id cur = nil;
    @try { cur = object_getIvar(holder, iv); } @catch (__unused NSException *e) {}
    if (!cur || cur == holder) return;
    if ([cur isKindOfClass:[NSNumber class]] || [cur isKindOfClass:[NSString class]]) return;

    NSString *k = theta_swapKey(holder, iv);
    if (thetaSeenNetSwapRecords) {
        for (NSDictionary *rec in thetaSeenNetSwapRecords) {
            if ([rec[@"key"] isEqualToString:k]) return;
        }
    }
    @try { object_setIvar(holder, iv, nil); } @catch (__unused NSException *e) { return; }
    NSDictionary *entry = @{ @"obj": holder, @"ivar": @((NSUInteger)(uintptr_t)iv), @"was": cur, @"key": k };
    if (!thetaSeenNetSwapRecords)
        thetaSeenNetSwapRecords = [NSMutableArray array];
    [thetaSeenNetSwapRecords addObject:entry];
}

static void theta_stripNetworkishIvarsOnHolder(id holder) {
    if (!theta_holderAcceptsNetworkishStrip(holder)) return;
    for (Class cls = object_getClass(holder); cls; cls = class_getSuperclass(cls)) {
        unsigned ivc = 0;
        Ivar *ivlist = class_copyIvarList(cls, &ivc);
        if (!ivlist) continue;
        for (unsigned i = 0; i < ivc; i++)
            theta_recordNilNetworkishIvar(holder, ivlist[i]);
        free(ivlist);
    }
}

static void theta_seenHarvestUploadersWalkingIvars(id root, NSUInteger maxDepth, NSMutableSet<id> *visited) {
    if (!root || maxDepth == 0) return;
    if ([visited containsObject:root]) return;
    [visited addObject:root];

    for (Class cls = object_getClass(root); cls; cls = class_getSuperclass(cls)) {
        unsigned ivc = 0;
        Ivar *ivlist = class_copyIvarList(cls, &ivc);
        if (!ivlist) continue;
        for (unsigned i = 0; i < ivc; i++) {
            Ivar iv = ivlist[i];
            const char *enc = ivar_getTypeEncoding(iv);
            if (!enc || enc[0] != '@') continue;

            NSString *iname = @(ivar_getName(iv));
            NSString *lower = [iname lowercaseString];
            BOOL interest = ([lower containsString:@"seen"] || [lower containsString:@"upload"] || [lower containsString:@"sundial"]
                || [lower containsString:@"reel"]);
            id val = nil;
            @try { val = object_getIvar(root, iv); } @catch (__unused NSException *e) {}
            if (!val || val == root) continue;

            if ([val isKindOfClass:[NSNumber class]]
                || [val isKindOfClass:[NSString class]]
                || [val isKindOfClass:[NSValue class]]
                || [val isKindOfClass:[NSDate class]])
                continue;

            if (theta_seenClassHintsUploader(val))
                thetaLegacySeenUploader = val;
            else if (theta_seenClassHintsSwiftManager(val))
                thetaSundialSeenManager = val;

            /* One extra hop helps when IG nests uploader/man inside a coordinator. */
            if (interest && ![val isKindOfClass:[UIView class]])
                theta_seenHarvestUploadersWalkingIvars(val, maxDepth - 1u, visited);
        }
        free(ivlist);
    }
}

void THStorySeenReceiptNetworkGuardHarvestFromContext(id fullscreenSectionController, id storyViewer) {
    if (!ENABLED(@"Seen Receipts Stay Local")) return;
    NSMutableSet *seen = [NSMutableSet setWithCapacity:8];
    theta_seenHarvestUploadersWalkingIvars(fullscreenSectionController, 2u, seen);
    [seen removeAllObjects];
    theta_seenHarvestUploadersWalkingIvars(storyViewer, 3u, seen);
    /* Section view models often retain the sundial/live uploader graphs. */
    @try {
        id vmSec = nil;
        if (fullscreenSectionController)
            vmSec = [fullscreenSectionController valueForKey:@"viewModel"];
        theta_seenHarvestUploadersWalkingIvars(vmSec, 3u, [NSMutableSet set]);
    } @catch (__unused NSException *e) {}
    @try {
        id vmTop = nil;
        if (storyViewer) {
            @try { vmTop = [storyViewer valueForKey:@"currentViewModel"]; } @catch (__unused NSException *e2) {}
            if (!vmTop)
                vmTop = [storyViewer valueForKey:@"viewModel"];
        }
        theta_seenHarvestUploadersWalkingIvars(vmTop, 3u, [NSMutableSet set]);
    } @catch (__unused NSException *e) {}

    /* Session-scoped reel uploader (IGUserSession) — critical path on newer IG. */
    void (^grabReel)(id) = ^(id host) {
        if (!host) return;
        id session = nil;
        @try { session = [host valueForKey:@"userSession"]; } @catch (__unused NSException *e) {}
        if (!session)
            @try { session = [host valueForKey:@"_userSession"]; } @catch (__unused NSException *e) {}
        if (!session) return;
        SEL sr = NSSelectorFromString(@"reelSeenStateUploader");
        if (![session respondsToSelector:sr]) return;
        id reel = ((id (*)(id, SEL))objc_msgSend)(session, sr);
        if (reel) thetaReelSeenStateUploader = reel;
    };
    @try {
        grabReel(storyViewer);
        grabReel(fullscreenSectionController);
    } @catch (__unused NSException *e) {}
}

static void theta_seenNilUploaderNetworkerRecording(id upl) {
    if (!upl) return;
    Class uplCls = object_getClass(upl);
    Ivar netIv = class_getInstanceVariable(uplCls, "_networker");
    if (!netIv) netIv = class_getInstanceVariable(uplCls, "networker");
    if (!netIv) return;
    id cur = nil;
    @try { cur = object_getIvar(upl, netIv); } @catch (__unused NSException *e) {}
    if (!cur) return;
    NSString *k = theta_swapKey(upl, netIv);
    BOOL already = NO;
    if (thetaSeenNetSwapRecords) {
        for (NSDictionary *rec in thetaSeenNetSwapRecords) {
            if ([rec[@"key"] isEqualToString:k]) {
                already = YES;
                break;
            }
        }
    }
    if (already) return;
    @try {
        object_setIvar(upl, netIv, nil);
    } @catch (__unused NSException *e) { return; }

    if (!thetaSeenNetSwapRecords)
        thetaSeenNetSwapRecords = [NSMutableArray array];
    NSDictionary *entry = @{ @"obj": upl, @"ivar": @((NSUInteger)(uintptr_t)netIv), @"was": cur, @"key": k };
    [thetaSeenNetSwapRecords addObject:entry];
}

static void theta_applySeenNetworkerSwapPass(void) {
    if (!thetaSeenNetSwapRecords)
        thetaSeenNetSwapRecords = [NSMutableArray array];

    theta_seenNilUploaderNetworkerRecording(thetaLegacySeenUploader);
    theta_seenNilUploaderNetworkerRecording(thetaReelSeenStateUploader);

    id mgr = thetaSundialSeenManager;
    if (mgr) {
        Class mgrCls = object_getClass(mgr);
        for (NSString *ivName in @[ @"seenStateUploader", @"seenStateUploaderDeprecated" ]) {
            Ivar mgrIv = class_getInstanceVariable(mgrCls, [ivName UTF8String]);
            if (!mgrIv) continue;
            id upl = nil;
            @try { upl = object_getIvar(mgr, mgrIv); } @catch (__unused NSException *e) {}
            theta_seenNilUploaderNetworkerRecording(upl);
        }
    }

    /* Strip GraphQL / Tigon / alternate network injections (names vary by IG build). */
    theta_stripNetworkishIvarsOnHolder(thetaLegacySeenUploader);
    theta_stripNetworkishIvarsOnHolder(thetaReelSeenStateUploader);
    theta_stripNetworkishIvarsOnHolder(thetaSundialSeenManager);
    theta_stripNetworkishIvarsOnHolder(thetaHarvestSection);
    theta_stripNetworkishIvarsOnHolder(thetaHarvestViewer);
}

void THStorySeenReceiptNetworkGuardEnterWithContext(id fullscreenSectionController, id storyViewer) {
    if (!ENABLED(@"Seen Receipts Stay Local")) return;
    thetaHarvestSection = fullscreenSectionController;
    thetaHarvestViewer = storyViewer;
    THStorySeenReceiptNetworkGuardHarvestFromContext(fullscreenSectionController, storyViewer);
    theta_applySeenNetworkerSwapPass();
}

void THStorySeenReceiptNetworkGuardResealAfterMark(id fullscreenSectionController, id storyViewer) {
    if (!ENABLED(@"Seen Receipts Stay Local")) return;
    id sec = fullscreenSectionController ?: thetaHarvestSection;
    id vc = storyViewer ?: thetaHarvestViewer;
    THStorySeenReceiptNetworkGuardHarvestFromContext(sec, vc);
    theta_applySeenNetworkerSwapPass();
}

void THStorySeenReceiptNetworkGuardEnter(void) {
    THStorySeenReceiptNetworkGuardEnterWithContext(nil, nil);
}

void THStorySeenReceiptNetworkGuardLeave(void) {
    if (!thetaSeenNetSwapRecords.count) return;
    /* Restore in reverse so nested edits collapse safely. */
    for (NSUInteger i = thetaSeenNetSwapRecords.count; i > 0; i--) {
        NSDictionary *entry = thetaSeenNetSwapRecords[i - 1];
        id obj = entry[@"obj"];
        NSUInteger ivOpaque = [(NSNumber *)entry[@"ivar"] unsignedIntegerValue];
        Ivar iv = (Ivar)(uintptr_t)ivOpaque;
        id was = entry[@"was"];
        if (!obj || !iv) continue;
        @try { object_setIvar(obj, iv, was); } @catch (__unused NSException *e) {}
    }
    [thetaSeenNetSwapRecords removeAllObjects];
}

static id (*orig_pendingStoreInit)(id, SEL, id, id, id, BOOL);
static id hook_pendingStoreInit(id self, SEL _cmd, id sessionPK, id uploader, id fileMgr, BOOL bgTask) {
    if (uploader) thetaLegacySeenUploader = uploader;
    return orig_pendingStoreInit(self, _cmd, sessionPK, uploader, fileMgr, bgTask);
}

static id (*orig_sundialMgrInit)(id, SEL, id, id, id, id);
static id hook_sundialMgrInit(id self, SEL _cmd, id networker, id diskMgr, id launcherSet, id announcer) {
    id res = orig_sundialMgrInit(self, _cmd, networker, diskMgr, launcherSet, announcer);
    if (res) thetaSundialSeenManager = res;
    return res;
}

#pragma mark - Uploader hooks

static BOOL theta_blockSeenReceipts(void) {
    if (s_thetaAllowStorySeenReceipts) return NO;
    if (s_thetaLocalSeenMarkActive) return YES;
    return ENABLED(@"Seen Receipts Stay Local");
}

static BOOL theta_stringLooksLikeStorySeen(NSString *s) {
    if (!s.length) return NO;
    NSString *l = s.lowercaseString;
    if ([l containsString:@"polarisstories"] && [l containsString:@"seen"]) return YES;
    if ([l containsString:@"storiesv3seen"]) return YES;
    if ([l containsString:@"storiesv2seen"]) return YES;
    if ([l containsString:@"seenmutation"]) return YES;
    if ([l containsString:@"mark_reel_seen"]) return YES;
    if ([l containsString:@"reel_seen"]) return YES;
    if ([l containsString:@"story_seen"]) return YES;
    if ([l containsString:@"stories/reel/seen"]) return YES;
    if ([l containsString:@"/media/seen"]) return YES;
    if ([l containsString:@"seen_reels"]) return YES;
    if ([l containsString:@"seenstatemutation"]) return YES;
    if ([l containsString:@"igstoryseen"]) return YES;
    return NO;
}

static BOOL theta_urlLooksLikeStorySeen(NSURL *url) {
    if (!url) return NO;
    return theta_stringLooksLikeStorySeen(url.absoluteString) || theta_stringLooksLikeStorySeen(url.path);
}

static BOOL theta_requestLooksLikeStorySeen(NSURLRequest *req) {
    if (![req isKindOfClass:[NSURLRequest class]]) return NO;
    if (theta_urlLooksLikeStorySeen(req.URL)) return YES;
    NSData *body = req.HTTPBody;
    if (body.length && body.length < 256u * 1024u) {
        NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding];
        if (theta_stringLooksLikeStorySeen(s)) return YES;
    }
    return NO;
}

static BOOL theta_payloadLooksLikeStorySeen(id obj) {
    if (!obj) return NO;
    if ([obj isKindOfClass:[NSURLRequest class]]) return theta_requestLooksLikeStorySeen(obj);
    if ([obj isKindOfClass:[NSURL class]]) return theta_urlLooksLikeStorySeen(obj);
    if ([obj isKindOfClass:[NSString class]]) return theta_stringLooksLikeStorySeen(obj);
    NSURL *url = nil;
    @try { url = [obj valueForKey:@"URL"]; } @catch (__unused NSException *e) {}
    if (![url isKindOfClass:[NSURL class]]) {
        @try { url = [obj valueForKey:@"url"]; } @catch (__unused NSException *e) {}
    }
    if ([url isKindOfClass:[NSURL class]] && theta_urlLooksLikeStorySeen(url)) return YES;
    id inner = nil;
    @try { inner = [obj valueForKey:@"request"]; } @catch (__unused NSException *e) {}
    if ([inner isKindOfClass:[NSURLRequest class]] && theta_requestLooksLikeStorySeen(inner)) return YES;
    NSString *name = nil;
    @try { name = [obj valueForKey:@"queryName"]; } @catch (__unused NSException *e) {}
    if (![name isKindOfClass:[NSString class]]) {
        @try { name = [obj valueForKey:@"friendlyName"]; } @catch (__unused NSException *e) {}
    }
    if ([name isKindOfClass:[NSString class]] && theta_stringLooksLikeStorySeen(name)) return YES;
    return NO;
}

static BOOL theta_shouldDropStorySeenTraffic(id payload) {
    if (!theta_blockSeenReceipts()) return NO;
    return theta_payloadLooksLikeStorySeen(payload);
}

static NSURLRequest *theta_dummySeenRequest(void) {
    return [NSURLRequest requestWithURL:[NSURL URLWithString:@"data:text/plain,"]];
}

static NSURLSessionDataTask *(*orig_nsurl_dataTaskReqComp)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask *hook_nsurl_dataTaskReqComp(id self, SEL _cmd, NSURLRequest *req, void (^comp)(NSData *, NSURLResponse *, NSError *)) {
    if (theta_shouldDropStorySeenTraffic(req)) {
        if (comp) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
                comp(nil, nil, err);
            });
        }
        NSURLSessionDataTask *task = orig_nsurl_dataTaskReqComp ? orig_nsurl_dataTaskReqComp(self, _cmd, theta_dummySeenRequest(), nil) : nil;
        [task cancel];
        return task;
    }
    return orig_nsurl_dataTaskReqComp(self, _cmd, req, comp);
}

static NSURLSessionDataTask *(*orig_nsurl_dataTaskReq)(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *hook_nsurl_dataTaskReq(id self, SEL _cmd, NSURLRequest *req) {
    if (theta_shouldDropStorySeenTraffic(req)) {
        NSURLSessionDataTask *task = orig_nsurl_dataTaskReq ? orig_nsurl_dataTaskReq(self, _cmd, theta_dummySeenRequest()) : nil;
        [task cancel];
        return task;
    }
    return orig_nsurl_dataTaskReq(self, _cmd, req);
}

static NSURLSessionUploadTask *(*orig_nsurl_uploadReqDataComp)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionUploadTask *hook_nsurl_uploadReqDataComp(id self, SEL _cmd, NSURLRequest *req, NSData *data, void (^comp)(NSData *, NSURLResponse *, NSError *)) {
    if (theta_shouldDropStorySeenTraffic(req) || (theta_blockSeenReceipts() && theta_stringLooksLikeStorySeen([[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding]))) {
        if (comp) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
                comp(nil, nil, err);
            });
        }
        NSURLSessionUploadTask *task = orig_nsurl_uploadReqDataComp ? orig_nsurl_uploadReqDataComp(self, _cmd, theta_dummySeenRequest(), [NSData data], nil) : nil;
        [task cancel];
        return task;
    }
    return orig_nsurl_uploadReqDataComp(self, _cmd, req, data, comp);
}

static void (*orig_dropSeenReq1)(id, SEL, id);
static void hook_dropSeenReq1(id self, SEL _cmd, id req) {
    if (theta_shouldDropStorySeenTraffic(req)) return;
    if (orig_dropSeenReq1) orig_dropSeenReq1(self, _cmd, req);
}

static void (*orig_sundialUploadSeenStateIfNecessary)(id, SEL);
static void hook_sundialUploadSeenStateIfNecessary(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_sundialUploadSeenStateIfNecessary(self, _cmd);
}

static void (*orig_sundialAppendSeenState)(id, SEL, id);
static void hook_sundialAppendSeenState(id self, SEL _cmd, id payload) {
    if (theta_blockSeenReceipts()) return;
    orig_sundialAppendSeenState(self, _cmd, payload);
}

static void (*orig_uploadSeenMedia)(id, SEL, id);
static void hook_uploadSeenMedia(id self, SEL _cmd, id media) {
    if (theta_blockSeenReceipts()) return;
    orig_uploadSeenMedia(self, _cmd, media);
}

static void (*orig_uploadSeenState)(id, SEL);
static void hook_uploadSeenState(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_uploadSeenState(self, _cmd);
}

static void (*orig_uploadSeenStateArg)(id, SEL, id);
static void hook_uploadSeenStateArg(id self, SEL _cmd, id arg1) {
    if (theta_blockSeenReceipts()) return;
    orig_uploadSeenStateArg(self, _cmd, arg1);
}

static void (*orig_sendSeenReceipt)(id, SEL, id);
static void hook_sendSeenReceipt(id self, SEL _cmd, id arg1) {
    if (theta_blockSeenReceipts()) return;
    orig_sendSeenReceipt(self, _cmd, arg1);
}

static void (*orig_sendSeenRequestForCurrentItem)(id, SEL);
static void hook_sendSeenRequestForCurrentItem(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_sendSeenRequestForCurrentItem(self, _cmd);
}

static void (*orig_sendSeenRequestForCurrentItemPriv)(id, SEL);
static void hook_sendSeenRequestForCurrentItemPriv(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_sendSeenRequestForCurrentItemPriv(self, _cmd);
}

static void (*orig_enqueueSeenStateForMedia)(id, SEL, id);
static void hook_enqueueSeenStateForMedia(id self, SEL _cmd, id media) {
    if (theta_blockSeenReceipts()) return;
    orig_enqueueSeenStateForMedia(self, _cmd, media);
}

static void (*orig_uploadSeenStateWithStoryItem)(id, SEL, id);
static void hook_uploadSeenStateWithStoryItem(id self, SEL _cmd, id storyItem) {
    if (theta_blockSeenReceipts()) return;
    orig_uploadSeenStateWithStoryItem(self, _cmd, storyItem);
}

static void (*orig_enqueueSeenStateWithStoryItem)(id, SEL, id);
static void hook_enqueueSeenStateWithStoryItem(id self, SEL _cmd, id storyItem) {
    if (theta_blockSeenReceipts()) return;
    orig_enqueueSeenStateWithStoryItem(self, _cmd, storyItem);
}

static void (*orig_sectionFlushQueuedSeenRequests)(id, SEL);
static void hook_sectionFlushQueuedSeenRequests(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_sectionFlushQueuedSeenRequests(self, _cmd);
}

static void (*orig_sectionFlushQueuedSeenRequestsPriv)(id, SEL);
static void hook_sectionFlushQueuedSeenRequestsPriv(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_sectionFlushQueuedSeenRequestsPriv(self, _cmd);
}

static void (*orig_sectionEnqueueSeenForPlayhead)(id, SEL);
static void hook_sectionEnqueueSeenForPlayhead(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_sectionEnqueueSeenForPlayhead(self, _cmd);
}

#pragma mark - Pending store (blocks secondary flush paths)

static void (*orig_pendingFlushSeenStates)(id, SEL);
static void hook_pendingFlushSeenStates(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_pendingFlushSeenStates(self, _cmd);
}

static void (*orig_pendingFlushSeenStatesPriv)(id, SEL);
static void hook_pendingFlushSeenStatesPriv(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_pendingFlushSeenStatesPriv(self, _cmd);
}

static void (*orig_pendingUploadSeenStates)(id, SEL);
static void hook_pendingUploadSeenStates(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_pendingUploadSeenStates(self, _cmd);
}

static void (*orig_pendingUploadSeenStatesPriv)(id, SEL);
static void hook_pendingUploadSeenStatesPriv(id self, SEL _cmd) {
    if (theta_blockSeenReceipts()) return;
    orig_pendingUploadSeenStatesPriv(self, _cmd);
}

static void (*orig_storyViewerDisappear)(id, SEL, BOOL);
static void hook_storyViewerDisappear(id self, SEL _cmd, BOOL anim) {
    THStorySeenReceiptNetworkGuardLeave();
    orig_storyViewerDisappear(self, _cmd, anim);
}

void THRegisterStorySeenLocalOnlyHooks(void) {
    Class pending = objc_getClass("IGStoryPendingSeenStateStore");
    SEL pendingSel = NSSelectorFromString(@"initWithUserSessionPK:uploader:fileManager:uploadInBackgroundTask:");
    if (pending && class_getInstanceMethod(pending, pendingSel))
        NullHookMessageEx(pending, pendingSel, (void *)hook_pendingStoreInit, &orig_pendingStoreInit);
    if (pending) {
        NullHookMessageIfPresent(pending, NSSelectorFromString(@"flushPendingSeenStates"),
            (void *)hook_pendingFlushSeenStates, &orig_pendingFlushSeenStates);
        NullHookMessageIfPresent(pending, NSSelectorFromString(@"_flushPendingSeenStates"),
            (void *)hook_pendingFlushSeenStatesPriv, &orig_pendingFlushSeenStatesPriv);
        NullHookMessageIfPresent(pending, NSSelectorFromString(@"uploadPendingSeenStates"),
            (void *)hook_pendingUploadSeenStates, &orig_pendingUploadSeenStates);
        NullHookMessageIfPresent(pending, NSSelectorFromString(@"_uploadPendingSeenStates"),
            (void *)hook_pendingUploadSeenStatesPriv, &orig_pendingUploadSeenStatesPriv);
    }

    Class sundialMgr = objc_getClass("_TtC23IGSundialSeenStateSwift25IGSundialSeenStateManager");
    SEL mgrSel = NSSelectorFromString(@"initWithNetworker:diskManager:launcherSet:seenStateManagerAnnouncer:");
    if (sundialMgr && class_getInstanceMethod(sundialMgr, mgrSel))
        NullHookMessageEx(sundialMgr, mgrSel, (void *)hook_sundialMgrInit, &orig_sundialMgrInit);
    if (sundialMgr) {
        NullHookMessageIfPresent(sundialMgr, @selector(uploadSeenStateIfNecessary), (void *)hook_sundialUploadSeenStateIfNecessary,
            &orig_sundialUploadSeenStateIfNecessary);
        NullHookMessageIfPresent(sundialMgr, @selector(appendSeenState:), (void *)hook_sundialAppendSeenState, &orig_sundialAppendSeenState);
    }

    Class viewer = objc_getClass("IGStoryViewerViewController");
    if (viewer)
        NullHookMessageEx(viewer, @selector(viewWillDisappear:), (void *)hook_storyViewerDisappear, &orig_storyViewerDisappear);

    /* Legacy ObjC uploader selectors often disappear once Swift wraps receipts; suppression still runs via networker-nil + fullscreen hook. */
    Class uploader = objc_getClass("IGStorySeenStateUploader");
    if (uploader) {
        NullHookMessageIfPresent(uploader, @selector(uploadSeenStateWithMedia:), (void *)hook_uploadSeenMedia, &orig_uploadSeenMedia);
        NullHookMessageIfPresent(uploader, @selector(uploadSeenState), (void *)hook_uploadSeenState, &orig_uploadSeenState);
        NullHookMessageIfPresent(uploader, NSSelectorFromString(@"_uploadSeenState:"), (void *)hook_uploadSeenStateArg, &orig_uploadSeenStateArg);
        NullHookMessageIfPresent(uploader, @selector(sendSeenReceipt:), (void *)hook_sendSeenReceipt, &orig_sendSeenReceipt);
        NullHookMessageIfPresent(uploader, NSSelectorFromString(@"enqueueSeenStateForMedia:"), (void *)hook_enqueueSeenStateForMedia, &orig_enqueueSeenStateForMedia);
        NullHookMessageIfPresent(uploader, NSSelectorFromString(@"uploadSeenStateWithStoryItem:"), (void *)hook_uploadSeenStateWithStoryItem, &orig_uploadSeenStateWithStoryItem);
        NullHookMessageIfPresent(uploader, NSSelectorFromString(@"enqueueSeenStateWithStoryItem:"), (void *)hook_enqueueSeenStateWithStoryItem, &orig_enqueueSeenStateWithStoryItem);
    }

    Class section = objc_getClass("IGStoryFullscreenSectionController");
    if (section) {
        NullHookMessageIfPresent(section, @selector(sendSeenRequestForCurrentItem), (void *)hook_sendSeenRequestForCurrentItem, &orig_sendSeenRequestForCurrentItem);
        NullHookMessageIfPresent(section, NSSelectorFromString(@"_sendSeenRequestForCurrentItem"), (void *)hook_sendSeenRequestForCurrentItemPriv, &orig_sendSeenRequestForCurrentItemPriv);
        NullHookMessageIfPresent(section, NSSelectorFromString(@"flushQueuedSeenRequests"), (void *)hook_sectionFlushQueuedSeenRequests, &orig_sectionFlushQueuedSeenRequests);
        NullHookMessageIfPresent(section, NSSelectorFromString(@"_flushQueuedSeenRequests"), (void *)hook_sectionFlushQueuedSeenRequestsPriv, &orig_sectionFlushQueuedSeenRequestsPriv);
        NullHookMessageIfPresent(section, NSSelectorFromString(@"enqueueSeenRequestForPlayhead"), (void *)hook_sectionEnqueueSeenForPlayhead, &orig_sectionEnqueueSeenForPlayhead);
    }

    Class nss = [NSURLSession class];
    NullHookMessageIfPresent(nss, @selector(dataTaskWithRequest:completionHandler:), (void *)hook_nsurl_dataTaskReqComp, &orig_nsurl_dataTaskReqComp);
    NullHookMessageIfPresent(nss, @selector(dataTaskWithRequest:), (void *)hook_nsurl_dataTaskReq, &orig_nsurl_dataTaskReq);
    NullHookMessageIfPresent(nss, @selector(uploadTaskWithRequest:fromData:completionHandler:), (void *)hook_nsurl_uploadReqDataComp, &orig_nsurl_uploadReqDataComp);
    Class nssLocal = objc_getClass("__NSURLSessionLocal");
    if (nssLocal && nssLocal != nss) {
        if (!orig_nsurl_dataTaskReqComp)
            NullHookMessageIfPresent(nssLocal, @selector(dataTaskWithRequest:completionHandler:), (void *)hook_nsurl_dataTaskReqComp, &orig_nsurl_dataTaskReqComp);
        if (!orig_nsurl_dataTaskReq)
            NullHookMessageIfPresent(nssLocal, @selector(dataTaskWithRequest:), (void *)hook_nsurl_dataTaskReq, &orig_nsurl_dataTaskReq);
        if (!orig_nsurl_uploadReqDataComp)
            NullHookMessageIfPresent(nssLocal, @selector(uploadTaskWithRequest:fromData:completionHandler:), (void *)hook_nsurl_uploadReqDataComp, &orig_nsurl_uploadReqDataComp);
    }

    NSArray<NSString *> *reqHosts = @[
        @"IGTigonNetworker",
        @"FBTigonService",
        @"TigonService",
        @"IGGraphQLService",
        @"IGGraphQLRequest",
        @"IGAPIRequest",
        @"IGURLRequest"
    ];
    NSArray<NSString *> *reqSels = @[
        @"startRequest:",
        @"addRequest:",
        @"sendRequest:",
        @"startWithRequest:",
        @"startQuery:"
    ];
    for (NSString *cn in reqHosts) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        for (NSString *sn in reqSels) {
            SEL s = NSSelectorFromString(sn);
            if (!class_getInstanceMethod(c, s)) continue;
            if (!orig_dropSeenReq1)
                NullHookMessageIfPresent(c, s, (void *)hook_dropSeenReq1, &orig_dropSeenReq1);
        }
    }

    /* Do not call objc_getClassList here. It realizeAllClasses() and IG 446+ crashes in
       swift_getSingletonMetadata (NULL metadata init). Named classes above are enough. */
    NSArray<NSString *> *extraSeen = @[
        @"IGStorySeenStateStore",
        @"IGReelSeenStateStore",
        @"IGReelSeenStateUploader",
        @"IGSundialSeenStateManager",
        @"_TtC23IGSundialSeenStateSwift25IGSundialSeenStateManager"
    ];
    for (NSString *cn in extraSeen) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        if (!orig_uploadSeenMedia)
            NullHookMessageIfPresent(c, @selector(uploadSeenStateWithMedia:), (void *)hook_uploadSeenMedia, &orig_uploadSeenMedia);
        if (!orig_uploadSeenState)
            NullHookMessageIfPresent(c, @selector(uploadSeenState), (void *)hook_uploadSeenState, &orig_uploadSeenState);
        if (!orig_uploadSeenStateArg)
            NullHookMessageIfPresent(c, NSSelectorFromString(@"_uploadSeenState:"), (void *)hook_uploadSeenStateArg, &orig_uploadSeenStateArg);
        if (!orig_sendSeenReceipt)
            NullHookMessageIfPresent(c, @selector(sendSeenReceipt:), (void *)hook_sendSeenReceipt, &orig_sendSeenReceipt);
        if (!orig_enqueueSeenStateForMedia)
            NullHookMessageIfPresent(c, NSSelectorFromString(@"enqueueSeenStateForMedia:"), (void *)hook_enqueueSeenStateForMedia, &orig_enqueueSeenStateForMedia);
        if (!orig_uploadSeenStateWithStoryItem)
            NullHookMessageIfPresent(c, NSSelectorFromString(@"uploadSeenStateWithStoryItem:"), (void *)hook_uploadSeenStateWithStoryItem, &orig_uploadSeenStateWithStoryItem);
        if (!orig_enqueueSeenStateWithStoryItem)
            NullHookMessageIfPresent(c, NSSelectorFromString(@"enqueueSeenStateWithStoryItem:"), (void *)hook_enqueueSeenStateWithStoryItem, &orig_enqueueSeenStateWithStoryItem);
        if (!orig_sundialUploadSeenStateIfNecessary)
            NullHookMessageIfPresent(c, @selector(uploadSeenStateIfNecessary), (void *)hook_sundialUploadSeenStateIfNecessary, &orig_sundialUploadSeenStateIfNecessary);
        if (!orig_sundialAppendSeenState)
            NullHookMessageIfPresent(c, @selector(appendSeenState:), (void *)hook_sundialAppendSeenState, &orig_sundialAppendSeenState);
    }
}
