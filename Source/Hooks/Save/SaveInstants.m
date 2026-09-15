#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdint.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "Include/ThetaHelper.h"
#import "Include/ThetaSubstrate.h"
#import "Include/MediaSelectionViewController.h"

static const NSInteger kThetaInstantSaveButtonTag = 0x74685356; // 'thSV'
static const NSInteger kThetaInstantSeenButtonTag = 0x74685353; // 'thSS'
static char kThetaInstantHostVCKey;

static NSString *sThetaInstantGhostAllowMediaId = nil;
static NSString *sThetaInstantCurrentGraphQLID = nil;
static BOOL sThetaInstantSkipConsumptionTransition = NO;
static __weak id sThetaInstantQuickSnapService;

static id (*orig_instantSeenRequestInit)(id self, SEL _cmd, id mediaIds);
static id (*orig_instantSeenRequestData)(id self, SEL _cmd, id mediaIds);
static void (*orig_instantSyncSeenSnaps)(id self, SEL _cmd, id sessionId, id onSuccess, id onFailure);
static id (*orig_instantSeenMutationBuilder)(id self, SEL _cmd, id includeMusic, id input);

static void (*orig_instantConsumptionLayout)(id self, SEL _cmd);
static void (*orig_instantQuickSnapLayout)(id self, SEL _cmd);
static void (*orig_instantDetailsLayout)(id self, SEL _cmd);
static void (*orig_instantNavLayout)(id self, SEL _cmd);
static void (*orig_instantConsumptionAppear)(id self, SEL _cmd, BOOL animated);
static void (*orig_instantNavAppear)(id self, SEL _cmd, BOOL animated);

static void thetaInstantEnsureGhostHooks(void);

static NSURL *thetaInstantURLFromCandidate(id cand) {
    if (!cand) return nil;
    if ([cand isKindOfClass:[NSURL class]]) return (NSURL *)cand;
    if ([cand isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)cand;
        return s.length ? [NSURL URLWithString:s] : nil;
    }
    id url = ThetaValueForKey(cand, @"url");
    if (!url) url = ThetaValueForKey(cand, @"URL");
    if ([url isKindOfClass:[NSURL class]]) return (NSURL *)url;
    if ([url isKindOfClass:[NSString class]] && [(NSString *)url length]) return [NSURL URLWithString:(NSString *)url];
    return nil;
}

static NSURL *thetaInstantURLFromImageView(id imageView) {
    if (!imageView) return nil;
    @try {
        id specifier = ThetaValueForKey(imageView, @"imageSpecifier");
        if (!specifier) specifier = ThetaValueForKey(imageView, @"_imageSpecifier");
        NSURL *fromSpecifier = thetaInstantURLFromCandidate(specifier);
        if (fromSpecifier) return fromSpecifier;
        if (specifier) {
            NSURL *nested = thetaInstantURLFromCandidate(ThetaValueForKey(specifier, @"url"));
            if (nested) return nested;
        }
        for (NSString *key in @[ @"imageURL", @"_imageURL", @"currentImageURL", @"lastLoadedImageURL" ]) {
            NSURL *url = thetaInstantURLFromCandidate(ThetaValueForKey(imageView, key));
            if (url) return url;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSURL *thetaInstantURLFromPlayer(id player) {
    if (!player) return nil;
    id item = nil;
    @try {
        if ([player respondsToSelector:@selector(currentItem)]) item = [player currentItem];
    } @catch (__unused NSException *e) {}
    if (!item) item = ThetaValueForKey(player, @"currentItem");
    id asset = ThetaValueForKey(item, @"asset");
    if ([asset isKindOfClass:[AVURLAsset class]]) return [(AVURLAsset *)asset URL];
    NSURL *url = thetaInstantURLFromCandidate(ThetaValueForKey(asset, @"URL"));
    if (url) return url;
    return thetaInstantURLFromCandidate(ThetaValueForKey(item, @"url"));
}

static NSURL *thetaInstantURLFromVideoView(id videoView) {
    if (!videoView) return nil;
    NSArray<NSString *> *playerKeys = @[ @"player", @"_player", @"avPlayer", @"assetPlayer", @"_assetPlayer" ];
    for (NSString *key in playerKeys) {
        NSURL *url = thetaInstantURLFromPlayer(ThetaValueForKey(videoView, key));
        if (url) return url;
    }
    @try {
        if ([videoView respondsToSelector:@selector(player)]) {
            NSURL *url = thetaInstantURLFromPlayer(((id (*)(id, SEL))objc_msgSend)(videoView, @selector(player)));
            if (url) return url;
        }
    } @catch (__unused NSException *e) {}
    return thetaInstantURLFromImageView(videoView);
}

static NSString *thetaInstantStringValue(id val) {
    if (!val || val == (id)[NSNull null]) return nil;
    if ([val isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)val;
        return s.length ? s : nil;
    }
    if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val stringValue];
    if ([val isKindOfClass:[NSURL class]]) {
        NSString *s = [(NSURL *)val absoluteString];
        return s.length ? s : nil;
    }
    @try {
        if ([val respondsToSelector:@selector(stringValue)]) {
            id sv = [val stringValue];
            if ([sv isKindOfClass:[NSString class]] && [(NSString *)sv length]) return sv;
        }
    } @catch (__unused NSException *e) {}
    NSString *cls = NSStringFromClass(object_getClass(val));
    if ([cls containsString:@"String"]) {
        NSString *s = [NSString stringWithFormat:@"%@", val];
        if (s.length && ![s hasPrefix:@"<"]) return s;
    }
    return nil;
}

static NSString *thetaInstantMediaIdRaw(id obj) {
    if (!obj) return nil;
    @try {
        if ([obj respondsToSelector:@selector(graphQLID)]) {
            NSString *gid = thetaInstantStringValue(((id (*)(id, SEL))objc_msgSend)(obj, @selector(graphQLID)));
            if (gid.length) return gid;
        }
    } @catch (__unused NSException *e) {}
    for (NSString *key in @[ @"graphQLID", @"pk", @"mediaPK", @"mediaId", @"mediaID", @"strongID", @"strongId", @"itemId", @"media_id", @"id" ]) {
        NSString *val = thetaInstantStringValue(ThetaValueForKey(obj, key));
        if (val.length) return val;
    }
    return nil;
}

static NSString *thetaInstantMediaId(id obj) {
    if (!obj) return nil;
    NSString *direct = thetaInstantMediaIdRaw(obj);
    if (direct.length) return direct;
    SEL maps[] = { @selector(asIGMediaIdentityFragmentImmutableModel), @selector(asIGQuickSnapMediaImmutableModel) };
    for (size_t i = 0; i < sizeof(maps) / sizeof(maps[0]); i++) {
        @try {
            if (![obj respondsToSelector:maps[i]]) continue;
            id mapped = ((id (*)(id, SEL))objc_msgSend)(obj, maps[i]);
            if (!mapped || mapped == obj) continue;
            NSString *nested = thetaInstantMediaIdRaw(mapped);
            if (nested.length) return nested;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static NSURL *thetaInstantBestURLFromPhoto(id photo) {
    if (!photo) return nil;
    for (NSString *key in @[ @"_originalImageVersions", @"imageVersions", @"_imageVersions" ]) {
        id versions = ThetaValueForKey(photo, key);
        if ([versions isKindOfClass:[NSDictionary class]]) {
            versions = [(NSDictionary *)versions objectForKey:@"candidates"] ?: [(NSDictionary *)versions objectForKey:@"_candidates"];
        }
        if (![versions isKindOfClass:[NSArray class]] || ![versions count]) continue;
        for (id cand in [versions reverseObjectEnumerator]) {
            NSURL *u = thetaInstantURLFromCandidate(cand);
            if (u) return u;
        }
    }
    return thetaInstantURLFromCandidate(photo);
}

static NSURL *thetaInstantURLFromMedia(id media) {
    if (!media) return nil;
    @try {
        if ([media respondsToSelector:@selector(asIGQuickSnapMediaImmutableModel)]) {
            id mapped = [media performSelector:@selector(asIGQuickSnapMediaImmutableModel)];
            if (mapped && mapped != media) {
                NSURL *mappedURL = thetaInstantURLFromMedia(mapped);
                if (mappedURL) return mappedURL;
            }
        }
    } @catch (__unused NSException *e) {}
    id photo = ThetaValueForKey(media, @"photo");
    if (!photo) photo = ThetaValueForKey(media, @"rawPhoto");
    if (!photo) photo = ThetaValueForKey(media, @"_photo_photo");
    NSURL *fromPhoto = thetaInstantBestURLFromPhoto(photo);
    if (fromPhoto) return fromPhoto;
    NSArray *versions = ThetaValueForKey(media, @"imageVersions");
    if ([versions isKindOfClass:[NSArray class]] && versions.count) {
        NSURL *u = thetaInstantURLFromCandidate([versions lastObject]);
        if (u) return u;
    }
    id imageVersions2 = ThetaValueForKey(media, @"imageVersions2");
    id candidates = ThetaValueForKey(imageVersions2, @"candidates");
    if (![candidates isKindOfClass:[NSArray class]]) candidates = ThetaValueForKey(imageVersions2, @"_candidates");
    if ([candidates isKindOfClass:[NSArray class]] && [candidates count]) {
        NSURL *u = thetaInstantURLFromCandidate([candidates lastObject]);
        if (u) return u;
    }
    id video = nil;
    if ([media respondsToSelector:@selector(video)]) {
        @try { video = [media performSelector:@selector(video)]; } @catch (__unused NSException *e) {}
    }
    if (!video) video = ThetaValueForKey(media, @"video");
    if (!video) video = ThetaValueForKey(media, @"rawVideo");
    if (!video) video = ThetaValueForKey(media, @"_video_video");
    NSArray<id> *videoHosts = video ? @[ media, video ] : @[ media ];
    for (id host in videoHosts) {
        if (![host respondsToSelector:@selector(allVideoURLs)]) continue;
        id set = nil;
        @try { set = [host performSelector:@selector(allVideoURLs)]; } @catch (__unused NSException *e) {}
        if ([set isKindOfClass:[NSSet class]]) {
            NSURL *u = thetaInstantURLFromCandidate([(NSSet *)set anyObject]);
            if (u) return u;
        } else if ([set isKindOfClass:[NSArray class]] && [set count]) {
            NSURL *u = thetaInstantURLFromCandidate([set lastObject]);
            if (u) return u;
        }
    }
    return nil;
}

static BOOL thetaInstantClassContains(id obj, NSString *needle) {
    if (!obj || !needle.length) return NO;
    Class cls = object_getClass(obj);
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls);
    return name.length && [name containsString:needle];
}

static id thetaInstantIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (!iv) continue;
        const char *encoding = ivar_getTypeEncoding(iv);
        if (encoding && encoding[0] != '@') return nil;
        id val = nil;
        @try { val = object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; }
        return val;
    }
    return nil;
}

static BOOL thetaInstantIsLikelySnapHost(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return NO;
    NSString *name = NSStringFromClass([view class]);
    return [name containsString:@"IGQuickSnapImmersiveViewerSingleSnapView"]
        || [name containsString:@"IGQuickSnapScrollingDetailsPreviewView"]
        || [name containsString:@"IGQuickSnapPhotoCardView"];
}

static BOOL thetaInstantIsOverlayChrome(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return NO;
    NSString *name = NSStringFromClass([view class]);
    return [name containsString:@"Avatar"]
        || [name containsString:@"Pill"]
        || [name containsString:@"Blur"]
        || [name containsString:@"Prompt"]
        || [name containsString:@"Border"]
        || [name containsString:@"Badge"]
        || view.tag == kThetaInstantSaveButtonTag
        || view.tag == kThetaInstantSeenButtonTag;
}

static UIImage *thetaInstantImageFromView(id view) {
    if (![view isKindOfClass:[UIImageView class]]) return nil;
    UIImage *image = nil;
    @try { image = [(UIImageView *)view image]; } @catch (__unused NSException *e) {}
    if ([image isKindOfClass:[UIImage class]] && image.size.width >= 40) return image;
    return nil;
}

static BOOL thetaInstantImageHasUsefulAlpha(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return NO;
    CGImageAlphaInfo info = CGImageGetAlphaInfo(cg);
    return info == kCGImageAlphaFirst || info == kCGImageAlphaLast
        || info == kCGImageAlphaPremultipliedFirst || info == kCGImageAlphaPremultipliedLast;
}

static UIImage *thetaInstantRectangularPhoto(UIImage *image) {
    if (![image isKindOfClass:[UIImage class]] || image.size.width < 40) return nil;
    if (!thetaInstantImageHasUsefulAlpha(image) || !image.CGImage) return image;

    CGImageRef cg = image.CGImage;
    size_t width = CGImageGetWidth(cg);
    size_t height = CGImageGetHeight(cg);
    if (width < 40 || height < 40) return image;

    size_t bpr = width * 4;
    uint8_t *pixels = (uint8_t *)calloc(height, bpr);
    if (!pixels) return image;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, width, height, 8, bpr, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) {
        free(pixels);
        return image;
    }
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cg);

    size_t maxInset = (size_t)(MIN(width, height) * 0.22);
    size_t inset = 0;
    BOOL found = NO;
    for (size_t i = 0; i <= maxInset; i++) {
        BOOL opaque = YES;
        size_t x0 = i, x1 = width - 1 - i, y0 = i, y1 = height - 1 - i;
        for (size_t x = x0; x <= x1 && opaque; x++) {
            if (pixels[y0 * bpr + x * 4 + 3] < 64 || pixels[y1 * bpr + x * 4 + 3] < 64) opaque = NO;
        }
        for (size_t y = y0; y <= y1 && opaque; y++) {
            if (pixels[y * bpr + x0 * 4 + 3] < 64 || pixels[y * bpr + x1 * 4 + 3] < 64) opaque = NO;
        }
        if (opaque) {
            inset = i;
            found = YES;
            break;
        }
    }
    if (!found) inset = maxInset / 2;

    CGContextRelease(ctx);
    free(pixels);

    if (inset == 0) return image;
    CGFloat scale = image.scale > 0 ? image.scale : 1;
    CGRect crop = CGRectMake(inset / scale, inset / scale, (width - inset * 2) / scale, (height - inset * 2) / scale);
    if (crop.size.width < 40 || crop.size.height < 40) return image;
    CGImageRef cropped = CGImageCreateWithImageInRect(cg, CGRectMake(inset, inset, width - inset * 2, height - inset * 2));
    if (!cropped) return image;
    UIImage *out = [UIImage imageWithCGImage:cropped scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cropped);
    return out ?: image;
}

static UIImage *thetaInstantBestRawImageInView(UIView *root) {
    if (![root isKindOfClass:[UIView class]]) return nil;
    UIImage *best = thetaInstantImageFromView(root);
    CGFloat bestPixels = best ? (best.size.width * best.size.height * best.scale * best.scale) : 0;
    for (UIView *view in root.subviews) {
        if (thetaInstantIsOverlayChrome(view)) continue;
        UIImage *nested = thetaInstantBestRawImageInView(view);
        if (!nested) continue;
        CGFloat pixels = nested.size.width * nested.size.height * nested.scale * nested.scale;
        if (pixels > bestPixels) {
            bestPixels = pixels;
            best = nested;
        }
    }
    return best;
}

static void thetaInstantCollectSubviews(UIView *root, NSMutableArray<UIView *> *out, NSMutableSet *seen) {
    if (!root || [seen containsObject:root]) return;
    [seen addObject:root];
    [out addObject:root];
    for (UIView *sub in root.subviews) {
        thetaInstantCollectSubviews(sub, out, seen);
    }
}

static void thetaInstantCollectFromViewController(UIViewController *vc, NSMutableArray<UIView *> *views, NSMutableSet *seenVCs, NSMutableSet *seenViews) {
    if (!vc || [seenVCs containsObject:vc]) return;
    [seenVCs addObject:vc];
    if ([vc isViewLoaded]) thetaInstantCollectSubviews(vc.view, views, seenViews);
    for (UIViewController *child in vc.childViewControllers) {
        thetaInstantCollectFromViewController(child, views, seenVCs, seenViews);
    }
    if (vc.presentedViewController) {
        thetaInstantCollectFromViewController(vc.presentedViewController, views, seenVCs, seenViews);
    }
}

static NSArray<UIView *> *thetaInstantAllViews(UIView *host, id viewController) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSMutableSet *seenViews = [NSMutableSet set];
    NSMutableSet *seenVCs = [NSMutableSet set];
    if ([viewController isKindOfClass:[UIViewController class]]) {
        thetaInstantCollectFromViewController((UIViewController *)viewController, views, seenVCs, seenViews);
        UIViewController *parent = [(UIViewController *)viewController parentViewController];
        while (parent) {
            thetaInstantCollectFromViewController(parent, views, seenVCs, seenViews);
            parent = parent.parentViewController;
        }
    }
    UIView *window = nil;
    if ([host isKindOfClass:[UIView class]]) window = host.window ?: host;
    if (window) thetaInstantCollectSubviews(window, views, seenViews);
    return views;
}

static void thetaInstantHarvestObject(id obj, NSMutableArray *urls, NSMutableArray *images, NSMutableSet *seen, NSInteger depth) {
    if (!obj || depth > 2 || seen.count > 80) return;
    @try {
        if ([seen containsObject:obj]) return;
        [seen addObject:obj];
    } @catch (__unused NSException *e) {
        return;
    }

    NSURL *fromImageView = thetaInstantURLFromImageView(obj);
    if (fromImageView && [urls indexOfObject:fromImageView] == NSNotFound) [urls addObject:fromImageView];

    NSURL *fromVideo = thetaInstantURLFromVideoView(obj);
    if (fromVideo && [urls indexOfObject:fromVideo] == NSNotFound) [urls addObject:fromVideo];

    UIImage *image = thetaInstantImageFromView(obj);
    if (image && [images indexOfObjectIdenticalTo:image] == NSNotFound) [images addObject:image];

    if (![obj isKindOfClass:[UIView class]] || depth >= 2) return;
    for (UIView *sub in [(UIView *)obj subviews]) {
        thetaInstantHarvestObject(sub, urls, images, seen, depth + 1);
    }
}

static UIImage *thetaInstantRenderView(UIView *view) {
    if (![view isKindOfClass:[UIView class]] || CGRectIsEmpty(view.bounds)) return nil;
    CGSize size = view.bounds.size;
    if (size.width < 40 || size.height < 40) return nil;
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    @try {
        [view.layer renderInContext:ctx];
    } @catch (__unused NSException *e) {
        UIGraphicsEndImageContext();
        return nil;
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIView *thetaInstantBestSnapView(NSArray<UIView *> *views) {
    UIView *best = nil;
    CGFloat bestScore = -1;
    for (UIView *view in views) {
        if (view.hidden || view.alpha < 0.2) continue;
        if (!thetaInstantIsLikelySnapHost(view)) continue;
        UIView *ref = view.window ?: view.superview;
        CGRect bounds = ref ? ref.bounds : view.bounds;
        CGRect frame = ref ? [view convertRect:view.bounds toView:ref] : view.bounds;
        CGRect vis = CGRectIntersection(frame, bounds);
        if (CGRectIsNull(vis) || vis.size.width < 40 || vis.size.height < 40) continue;
        CGFloat score = vis.size.width * vis.size.height;
        if (score > bestScore) {
            bestScore = score;
            best = view;
        }
    }
    return best;
}

static UIView *thetaInstantPhotoSurfaceInView(UIView *root) {
    if (![root isKindOfClass:[UIView class]]) return nil;
    id named = thetaInstantIvarObject(root, "imageView");
    if (!named) named = thetaInstantIvarObject(root, "$__lazy_storage_$_imageView");
    if (!named) named = thetaInstantIvarObject(root, "photoImageView");
    if (!named) named = ThetaValueForKey(root, @"imageView");
    if ([named isKindOfClass:[UIImageView class]] && !thetaInstantIsOverlayChrome(named)) return named;

    Class igImageViewCls = NSClassFromString(@"IGImageView");
    UIView *best = nil;
    CGFloat bestArea = -1;
    NSMutableArray<UIView *> *subs = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    UIView *searchRoot = [named isKindOfClass:[UIView class]] ? named : root;
    thetaInstantCollectSubviews(searchRoot, subs, seen);
    if (searchRoot != root) thetaInstantCollectSubviews(root, subs, seen);
    for (UIView *view in subs) {
        if (view.hidden || view.alpha < 0.2 || thetaInstantIsOverlayChrome(view)) continue;
        BOOL isPhoto = (igImageViewCls && [view isKindOfClass:igImageViewCls]) || [view isKindOfClass:[UIImageView class]];
        if (!isPhoto) continue;
        CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
        if (area < 80.0 * 80.0) continue;
        if (area > bestArea) {
            bestArea = area;
            best = view;
        }
    }
    return best;
}

static UIImage *thetaInstantRenderUnmasked(UIView *view) {
    if (![view isKindOfClass:[UIImageView class]]) return nil;
    UIImage *image = thetaInstantImageFromView(view);
    if (image) return image;
    return thetaInstantRenderView(view);
}

static BOOL thetaInstantLooksVideoURL(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"]) return YES;
    NSString *s = url.absoluteString.lowercaseString;
    return [s containsString:@".mp4"] || [s containsString:@"video"];
}

static void thetaInstantToastFailure(NSString *subtitle) {
    if (!ENABLED(@"Show Banners")) return;
    [ThetaHelper showToastWithTitle:@"Save failed"
                           subtitle:subtitle ?: @"Couldn't find Instant media."
                               icon:[UIImage systemImageNamed:@"exclamationmark.triangle"]
                           autoHide:3
                            openURL:nil];
}

static void thetaInstantToastSuccess(void) {
    if (!ENABLED(@"Show Banners")) return;
    NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
    if (saveMethod == 0) {
        [ThetaHelper showToastWithTitle:@"Saved Instant!"
                               subtitle:@"Tap here to go to camera roll."
                                   icon:[UIImage systemImageNamed:@"checkmark.circle.fill"]
                               autoHide:4
                                openURL:[NSURL URLWithString:@"photos-redirect://"]];
    } else {
        [ThetaHelper showToastWithTitle:@"Saved Instant!"
                               subtitle:@"Saved to local folder."
                                   icon:[UIImage systemImageNamed:@"checkmark.circle.fill"]
                               autoHide:4
                                openURL:nil];
    }
}

static void thetaInstantSaveImage(UIImage *image) {
    image = thetaInstantRectangularPhoto(image);
    if (![image isKindOfClass:[UIImage class]]) {
        thetaInstantToastFailure(@"No image on this Instant.");
        return;
    }
    if (![ThetaHelper tryBeginGlobalDownloadOrNotify]) return;
    NSInteger saveMethod = [[NSUserDefaults standardUserDefaults] integerForKey:@"Save Method_SegmentIndex"];
    if (saveMethod == 0) {
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        } completionHandler:^(BOOL success, NSError * _Nullable error) {
            [ThetaHelper endGlobalDownload];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) thetaInstantToastSuccess();
                else thetaInstantToastFailure(error.localizedDescription);
            });
        }];
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Saving…" subtitle:@"Saving Instant photo" icon:[UIImage systemImageNamed:@"arrow.down.circle"] autoHide:2 openURL:nil];
        }
        return;
    }
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [documentsPath stringByAppendingPathComponent:@"AudioNotes"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"instant-%@.jpg", [[NSUUID UUID] UUIDString]]];
    NSData *data = UIImageJPEGRepresentation(image, 0.95);
    BOOL ok = [data writeToFile:path atomically:YES];
    [ThetaHelper endGlobalDownload];
    if (ok) thetaInstantToastSuccess();
    else thetaInstantToastFailure(@"Couldn't write the photo.");
}

static void thetaInstantSaveURL(NSURL *url, BOOL isVideoHint) {
    if (![url isKindOfClass:[NSURL class]]) {
        thetaInstantToastFailure(@"No media URL on this Instant.");
        return;
    }
    if (![ThetaHelper tryBeginGlobalDownloadOrNotify]) return;
    static MediaSelectionViewController *sInstantDownloader = nil;
    sInstantDownloader = [[MediaSelectionViewController alloc] init];
    [sInstantDownloader downloadMediaToTemp:url completion:^(NSString *filePath, NSString *fileExtension) {
        sInstantDownloader = nil;
        [ThetaHelper endGlobalDownload];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (filePath.length) thetaInstantToastSuccess();
            else thetaInstantToastFailure(@"Download failed.");
        });
        (void)fileExtension;
    }];
    (void)isVideoHint;
    if (ENABLED(@"Show Banners")) {
        [ThetaHelper showToastWithTitle:@"Saving…" subtitle:@"Downloading Instant" icon:[UIImage systemImageNamed:@"arrow.down.circle"] autoHide:2 openURL:nil];
    }
}

static id thetaInstantMediaFromHost(id viewController, UIView *snap) {
    NSMutableArray *hosts = [NSMutableArray array];
    NSMutableSet *seenHosts = [NSMutableSet set];
    void (^addHost)(id) = ^(id host) {
        if (!host || host == [NSNull null]) return;
        NSValue *key = [NSValue valueWithNonretainedObject:host];
        if ([seenHosts containsObject:key]) return;
        [seenHosts addObject:key];
        [hosts addObject:host];
    };
    addHost(viewController);
    addHost(snap);
    if ([viewController isKindOfClass:[UIViewController class]]) {
        UIViewController *parent = [(UIViewController *)viewController parentViewController];
        while (parent && hosts.count < 12) {
            addHost(parent);
            parent = parent.parentViewController;
        }
        NSArray *children = nil;
        @try { children = [(UIViewController *)viewController childViewControllers]; } @catch (__unused NSException *e) {}
        for (id child in children) {
            addHost(child);
            if (hosts.count >= 16) break;
        }
    }
    NSUInteger baseCount = hosts.count;
    for (NSUInteger i = 0; i < baseCount && hosts.count < 20; i++) {
        addHost(thetaInstantIvarObject(hosts[i], "context"));
        addHost(ThetaValueForKey(hosts[i], @"context"));
        addHost(thetaInstantIvarObject(hosts[i], "viewController"));
    }
    NSArray<NSString *> *keys = @[
        @"currentMedia", @"media", @"quickSnapMedia", @"snap", @"currentSnap",
        @"item", @"currentItem", @"viewModel", @"mediaModel", @"promptModel",
        @"consumptionState", @"state"
    ];
    for (id host in hosts) {
        for (NSString *key in keys) {
            id val = ThetaValueForKey(host, key);
            if (!val) val = thetaInstantIvarObject(host, key.UTF8String);
            if (!val) continue;
            @try {
                if ([val respondsToSelector:@selector(asIGQuickSnapMediaImmutableModel)]) {
                    id mapped = [val performSelector:@selector(asIGQuickSnapMediaImmutableModel)];
                    if (mapped) val = mapped;
                }
            } @catch (__unused NSException *e) {}
            if (thetaInstantURLFromMedia(val) || thetaInstantMediaId(val)) return val;
            id nested = ThetaValueForKey(val, @"media");
            if (nested && (thetaInstantURLFromMedia(nested) || thetaInstantMediaId(nested))) return nested;
        }
    }
    return nil;
}

static BOOL thetaInstantLooksLikeSnapMedia(id obj) {
    if (!obj) return NO;
    NSString *name = NSStringFromClass(object_getClass(obj));
    if ([name containsString:@"User"] && ![name containsString:@"Media"]) return NO;
    Class mediaCls = NSClassFromString(@"IGMedia");
    if (mediaCls && [obj isKindOfClass:mediaCls]) return YES;
    if ([obj respondsToSelector:@selector(asIGQuickSnapMediaImmutableModel)]) return YES;
    if ([obj respondsToSelector:@selector(asIGMediaIdentityFragmentImmutableModel)]) return YES;
    if ([name containsString:@"QuickSnapMedia"] || [name containsString:@"MediaFragment"] || [name containsString:@"MediaIdentity"] || [name containsString:@"IGMedia"]) return YES;
    if (thetaInstantURLFromMedia(obj)) return YES;
    if (ThetaValueForKey(obj, @"photo") || ThetaValueForKey(obj, @"video") || ThetaValueForKey(obj, @"imageVersions2")) return YES;
    return NO;
}

static NSString *thetaInstantURLKey(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    NSString *last = url.path.lastPathComponent;
    if (last.pathExtension.length) last = [last stringByDeletingPathExtension];
    if (last.length > 8) return last;
    NSString *abs = url.absoluteString;
    return abs.length ? abs : nil;
}

static NSString *thetaInstantCacheKey(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"ig_cache_key"] || !item.value.length) continue;
        NSString *value = [item.value stringByRemovingPercentEncoding] ?: item.value;
        NSString *pk = [[value componentsSeparatedByString:@":"] firstObject];
        return pk.length ? pk : value;
    }
    return nil;
}

static BOOL thetaInstantURLMatchesMedia(NSURL *visible, id media) {
    if (![visible isKindOfClass:[NSURL class]] || !media) return NO;
    NSURL *mediaURL = thetaInstantURLFromMedia(media);
    NSString *a = thetaInstantURLKey(visible);
    NSString *b = thetaInstantURLKey(mediaURL);
    if (a.length && b.length && [a isEqualToString:b]) return YES;
    NSString *mediaId = thetaInstantMediaId(media);
    NSString *abs = visible.absoluteString;
    if (mediaId.length >= 6 && abs.length && [abs containsString:mediaId]) return YES;
    NSString *cacheKey = thetaInstantCacheKey(visible);
    if (cacheKey.length >= 6 && mediaId.length && [mediaId containsString:cacheKey]) return YES;
    if (cacheKey.length >= 6 && mediaId.length && [cacheKey containsString:mediaId]) return YES;
    NSString *mediaCache = thetaInstantCacheKey(mediaURL);
    if (cacheKey.length && mediaCache.length && [cacheKey isEqualToString:mediaCache]) return YES;
    return NO;
}

static void thetaInstantCollectSnapMedia(id obj, NSMutableArray *medias, NSMutableSet *seen, int depth) {
    if (!obj || depth > 4 || medias.count > 40) return;
    NSValue *key = [NSValue valueWithNonretainedObject:obj];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        for (id item in (id<NSFastEnumeration>)obj) thetaInstantCollectSnapMedia(item, medias, seen, depth + 1);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id k, id val, BOOL *stop) {
            (void)k; (void)stop;
            thetaInstantCollectSnapMedia(val, medias, seen, depth + 1);
        }];
        return;
    }
    if (thetaInstantLooksLikeSnapMedia(obj) && thetaInstantMediaId(obj).length) {
        [medias addObject:obj];
    }
    if (depth >= 3) return;
    if ([obj isKindOfClass:[UIImage class]] || [obj isKindOfClass:[NSURL class]] || [obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) return;
    unsigned ivc = 0;
    Ivar *ivs = class_copyIvarList(object_getClass(obj), &ivc);
    if (!ivs) return;
    for (unsigned i = 0; i < ivc; i++) {
        const char *enc = ivar_getTypeEncoding(ivs[i]);
        if (!enc || enc[0] != '@') continue;
        id val = nil;
        @try { val = object_getIvar(obj, ivs[i]); } @catch (__unused NSException *e) { continue; }
        if (!val || val == obj) continue;
        if ([val isKindOfClass:[UIView class]] && depth > 0) continue;
        thetaInstantCollectSnapMedia(val, medias, seen, depth + 1);
    }
    free(ivs);
}

static NSInteger thetaInstantIvarInt(id obj, const char *name, BOOL *ok) {
    if (ok) *ok = NO;
    if (!obj || !name) return 0;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (!iv) continue;
        ptrdiff_t off = ivar_getOffset(iv);
        if (off < 0) continue;
        const char *enc = ivar_getTypeEncoding(iv);
        if (enc && enc[0] == '@') {
            id val = nil;
            @try { val = object_getIvar(obj, iv); } @catch (__unused NSException *e) { return 0; }
            if (![val isKindOfClass:[NSNumber class]]) return 0;
            if (ok) *ok = YES;
            return [val integerValue];
        }
        if (enc && enc[0] && enc[0] != 'q' && enc[0] != 'Q' && enc[0] != 'l' && enc[0] != 'L' && enc[0] != 'i' && enc[0] != 'I') {
            return 0;
        }
        if (ok) *ok = YES;
        char *base = (char *)(__bridge void *)obj + off;
        if (enc && (enc[0] == 'i' || enc[0] == 'I')) return *(int *)base;
        return *(NSInteger *)base;
    }
    return 0;
}

static UIView *thetaInstantAnimatingStackView(NSArray<UIView *> *views) {
    UIView *best = nil;
    CGFloat bestArea = -1;
    for (UIView *view in views) {
        if (![view isKindOfClass:[UIView class]] || view.hidden || view.alpha < 0.05) continue;
        NSString *name = NSStringFromClass([view class]);
        if (![name containsString:@"AnimatingSnapStackView"]) continue;
        if ([name containsString:@"Animator"] || [name containsString:@"State"]
            || [name containsString:@"Controller"] || [name containsString:@"Observer"]
            || [name containsString:@"Plugin"] || [name containsString:@"Delegate"]
            || [name containsString:@"Keyboard"] || [name containsString:@"Tap"]) continue;
        CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
        if (area > bestArea) {
            bestArea = area;
            best = view;
        }
    }
    return best;
}

static NSArray *thetaInstantKeyedArray(id container, NSArray<NSString *> *keys) {
    if (!container) return nil;
    for (NSString *key in keys) {
        id val = ThetaValueForKey(container, key);
        if ([val isKindOfClass:[NSArray class]] && [val count]) return val;
    }
    return nil;
}

static NSString *thetaInstantMediaIdAtIndex(NSArray *arr, NSInteger index) {
    if (![arr isKindOfClass:[NSArray class]] || index < 0 || index >= (NSInteger)arr.count) return nil;
    id item = arr[(NSUInteger)index];
    NSString *mediaId = thetaInstantMediaId(item);
    if (mediaId.length) return mediaId;
    return thetaInstantMediaId(ThetaValueForKey(item, @"media"));
}

static NSString *thetaInstantIdFromStack(NSArray<UIView *> *views) {
    UIView *stack = thetaInstantAnimatingStackView(views);
    if (!stack) return nil;
    id state = thetaInstantIvarObject(stack, "state") ?: ThetaValueForKey(stack, @"state");
    if (!thetaInstantClassContains(state, @"AnimatingSnapStackViewState")) return nil;
    BOOL ok = NO;
    NSInteger index = thetaInstantIvarInt(state, "currentlyDisplayingQuickSnapIndex", &ok);
    if (!ok || index < 0 || index > 50) return nil;

    NSArray<NSString *> *keys = @[ @"snaps", @"currentImages", @"quickSnaps", @"medias", @"items", @"itemsOrderedByTime" ];
    NSArray *arr = thetaInstantKeyedArray(state, keys);
    if (!arr) {
        id images = ThetaValueForKey(stack, @"currentImages");
        if ([images isKindOfClass:[NSArray class]]) arr = images;
    }

    NSString *fromArray = thetaInstantMediaIdAtIndex(arr, index);
    if (fromArray.length) return fromArray;

    NSMutableArray *medias = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    thetaInstantCollectSnapMedia(arr, medias, seen, 0);
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    for (id media in medias) {
        NSString *mediaId = thetaInstantMediaId(media);
        if (mediaId.length) [ids addObject:mediaId];
    }
    if (index < (NSInteger)ids.count) return [ids objectAtIndex:(NSUInteger)index];
    return nil;
}

static NSString *thetaInstantIdFromSpecifier(id specifier) {
    if (!specifier) return nil;
    for (NSString *key in @[ @"graphQLID", @"mediaID", @"mediaId", @"pk", @"mediaPK", @"media_id", @"strongID" ]) {
        NSString *val = thetaInstantStringValue(ThetaValueForKey(specifier, key));
        if (val.length > 6) return val;
    }
    NSString *fromMedia = thetaInstantMediaId(ThetaValueForKey(specifier, @"media"));
    return fromMedia.length > 6 ? fromMedia : nil;
}

static NSString *thetaInstantVisibleMediaId(UIView *host, id viewController) {
    if (sThetaInstantCurrentGraphQLID.length) return sThetaInstantCurrentGraphQLID;

    NSArray<UIView *> *views = thetaInstantAllViews(host, viewController);
    NSString *fromStack = thetaInstantIdFromStack(views);
    if (fromStack.length) return fromStack;

    UIView *snap = thetaInstantBestSnapView(views);
    UIView *photoView = thetaInstantPhotoSurfaceInView(snap);
    id videoView = thetaInstantIvarObject(snap, "videoView");
    if (![videoView isKindOfClass:[UIView class]]) videoView = ThetaValueForKey(snap, @"videoView");
    NSURL *visibleURL = thetaInstantURLFromImageView(photoView);
    if (!visibleURL) visibleURL = thetaInstantURLFromVideoView(videoView);
    if (!visibleURL) visibleURL = thetaInstantURLFromPlayer(videoView);

    NSString *fromSpecifier = thetaInstantIdFromSpecifier(ThetaValueForKey(photoView, @"imageSpecifier") ?: ThetaValueForKey(photoView, @"_imageSpecifier"));
    if (fromSpecifier.length) return fromSpecifier;

    NSMutableArray *medias = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    thetaInstantCollectSnapMedia(snap, medias, seen, 0);
    NSUInteger snapCount = medias.count;
    thetaInstantCollectSnapMedia(viewController, medias, seen, 0);
    thetaInstantCollectSnapMedia(thetaInstantIvarObject(viewController, "context"), medias, seen, 0);
    if ([viewController isKindOfClass:[UIViewController class]]) {
        UIViewController *parent = [(UIViewController *)viewController parentViewController];
        while (parent && medias.count < 40) {
            thetaInstantCollectSnapMedia(parent, medias, seen, 0);
            thetaInstantCollectSnapMedia(thetaInstantIvarObject(parent, "context"), medias, seen, 0);
            parent = parent.parentViewController;
        }
    }

    if (visibleURL) {
        NSString *cacheKey = thetaInstantCacheKey(visibleURL);
        for (id media in medias) {
            if (thetaInstantURLMatchesMedia(visibleURL, media)) {
                NSString *mediaId = thetaInstantMediaId(media);
                if (mediaId.length) return mediaId;
            }
            if (cacheKey.length >= 6) {
                NSString *mediaId = thetaInstantMediaId(media);
                if (mediaId.length && ([mediaId containsString:cacheKey] || [cacheKey containsString:mediaId])) return mediaId;
            }
        }
    }

    if (snapCount == 1) return thetaInstantMediaId(medias.firstObject);

    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    for (id media in medias) {
        NSString *mediaId = thetaInstantMediaId(media);
        if (mediaId.length) [ids addObject:mediaId];
    }
    if (ids.count == 1) return ids.firstObject;
    return nil;
}

static void thetaInstantSaveFromHost(UIView *host, id viewController) {
    @try {
        NSArray<UIView *> *views = thetaInstantAllViews(host, viewController);
        UIView *snap = thetaInstantBestSnapView(views);
        UIView *photoView = thetaInstantPhotoSurfaceInView(snap);
        if (!photoView) {
            Class igImageViewCls = NSClassFromString(@"IGImageView");
            UIView *bestPhoto = nil;
            CGFloat bestArea = -1;
            for (UIView *view in views) {
                if (view.hidden || view.alpha < 0.2 || thetaInstantIsOverlayChrome(view)) continue;
                BOOL isPhoto = (igImageViewCls && [view isKindOfClass:igImageViewCls]) || [view isKindOfClass:[UIImageView class]];
                if (!isPhoto) continue;
                CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
                if (area < 80.0 * 80.0) continue;
                if (area > bestArea) {
                    bestArea = area;
                    bestPhoto = view;
                }
            }
            photoView = bestPhoto;
        }

        id videoView = thetaInstantIvarObject(snap, "videoView");
        if (![videoView isKindOfClass:[UIView class]]) videoView = thetaInstantIvarObject(snap, "$__lazy_storage_$_videoPlayerView");
        if (![videoView isKindOfClass:[UIView class]]) videoView = ThetaValueForKey(snap, @"videoView");
        if (![videoView isKindOfClass:[UIView class]]) videoView = ThetaValueForKey(snap, @"videoPlayerView");

        NSURL *videoURL = thetaInstantURLFromVideoView(videoView);
        if (!videoURL) videoURL = thetaInstantURLFromPlayer(videoView);
        NSURL *imageURL = thetaInstantURLFromImageView(photoView);
        id media = thetaInstantMediaFromHost(viewController, snap);
        NSURL *fromMedia = thetaInstantURLFromMedia(media);
        if (fromMedia) {
            if (thetaInstantLooksVideoURL(fromMedia)) {
                if (!videoURL) videoURL = fromMedia;
            } else {
                imageURL = fromMedia;
            }
        }

        NSMutableArray *urls = [NSMutableArray array];
        NSMutableArray *images = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        thetaInstantHarvestObject(videoView, urls, images, seen, 0);
        thetaInstantHarvestObject(photoView, urls, images, seen, 0);
        for (NSURL *url in urls) {
            if (![url isKindOfClass:[NSURL class]]) continue;
            NSString *scheme = url.scheme.lowercaseString;
            if (![scheme hasPrefix:@"http"] && ![scheme isEqualToString:@"file"]) continue;
            if (thetaInstantLooksVideoURL(url)) {
                if (!videoURL) videoURL = url;
            } else if (!imageURL) {
                imageURL = url;
            }
        }
        if (videoURL) {
            thetaInstantSaveURL(videoURL, YES);
            return;
        }
        if (imageURL) {
            thetaInstantSaveURL(imageURL, NO);
            return;
        }

        UIImage *rawImage = thetaInstantBestRawImageInView(photoView);
        if (!rawImage) {
            UIImage *bestImage = nil;
            CGFloat bestPixels = 0;
            for (UIImage *img in images) {
                if (![img isKindOfClass:[UIImage class]]) continue;
                CGFloat pixels = img.size.width * img.size.height * img.scale * img.scale;
                if (pixels > bestPixels && img.size.width >= 40) {
                    bestPixels = pixels;
                    bestImage = img;
                }
            }
            rawImage = bestImage;
        }
        if (rawImage) {
            thetaInstantSaveImage(rawImage);
            return;
        }

        UIImage *rendered = thetaInstantRenderUnmasked(photoView);
        if (rendered.size.width >= 40) {
            thetaInstantSaveImage(rendered);
            return;
        }

        thetaInstantToastFailure(@"Couldn't find the current Instant photo/video.");
    } @catch (__unused NSException *e) {
        thetaInstantToastFailure(@"Couldn't find the current Instant photo/video.");
    }
}

static UIButton *thetaInstantFindButton(UIView *root, NSInteger tag) {
    if (!root) return nil;
    if (root.tag == tag && [root isKindOfClass:[UIButton class]]) return (UIButton *)root;
    for (UIView *sub in root.subviews) {
        UIButton *found = thetaInstantFindButton(sub, tag);
        if (found) return found;
    }
    return nil;
}

static UIButton *thetaInstantMakeChromeButton(NSInteger tag, NSString *symbol, NSString *colorKey) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = tag;
    @try {
        NSData *data = [[NSUserDefaults standardUserDefaults] objectForKey:colorKey];
        UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:data error:nil];
        [button setTintColor:color ?: [UIColor labelColor]];
    } @catch (__unused NSException *e) {
        [button setTintColor:[UIColor labelColor]];
    }
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.layer.shadowColor = [UIColor blackColor].CGColor;
    button.layer.shadowOpacity = 0.4;
    button.layer.shadowOffset = CGSizeMake(-2, 0);
    button.layer.shadowRadius = 3;
    button.layer.masksToBounds = NO;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    ThetaSetCaptureHiding(button);
    return button;
}

static BOOL thetaInstantGhostEnabled(void) {
    return ENABLED(@"Instant Ghost");
}

static BOOL thetaInstantGhostShouldBlockNetwork(void) {
    return thetaInstantGhostEnabled() && !sThetaInstantGhostAllowMediaId.length;
}

static BOOL thetaInstantStringLooksLikeSeen(NSString *s) {
    if (!s.length) return NO;
    NSString *l = s.lowercaseString;
    if ([l containsString:@"xdt_mark_quick_snap_seen"]) return YES;
    if ([l containsString:@"mark_quick_snap_seen"]) return YES;
    if ([l containsString:@"markquicksnapseen"]) return YES;
    if ([l containsString:@"quicksnapupdateseenstatemutation"]) return YES;
    if ([l containsString:@"igxdtmarkquicksnapseen"]) return YES;
    return NO;
}

static BOOL thetaInstantPayloadLooksLikeSeen(id obj) {
    if (!obj) return NO;
    if ([obj isKindOfClass:[NSString class]]) return thetaInstantStringLooksLikeSeen(obj);
    if ([obj isKindOfClass:[NSURL class]]) {
        NSURL *url = (NSURL *)obj;
        return thetaInstantStringLooksLikeSeen(url.absoluteString) || thetaInstantStringLooksLikeSeen(url.path);
    }
    if ([obj isKindOfClass:[NSURLRequest class]]) {
        NSURLRequest *req = (NSURLRequest *)obj;
        if (thetaInstantPayloadLooksLikeSeen(req.URL)) return YES;
        NSString *friendly = [req valueForHTTPHeaderField:@"X-FB-Friendly-Name"];
        if (thetaInstantStringLooksLikeSeen(friendly)) return YES;
        NSData *body = req.HTTPBody;
        if (body.length && body.length < 256u * 1024u) {
            NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
            if (!s) s = [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding];
            if (thetaInstantStringLooksLikeSeen(s)) return YES;
        }
        return NO;
    }
    NSString *name = ThetaValueForKey(obj, @"queryName");
    if (![name isKindOfClass:[NSString class]]) name = ThetaValueForKey(obj, @"friendlyName");
    if (thetaInstantStringLooksLikeSeen(name)) return YES;
    NSURL *url = ThetaValueForKey(obj, @"URL");
    if (![url isKindOfClass:[NSURL class]]) url = ThetaValueForKey(obj, @"url");
    if (thetaInstantPayloadLooksLikeSeen(url)) return YES;
    id inner = ThetaValueForKey(obj, @"request");
    if (inner && inner != obj) return thetaInstantPayloadLooksLikeSeen(inner);
    return NO;
}

static id thetaInstantFilterMediaIds(id mediaIds) {
    if (!thetaInstantGhostEnabled()) return mediaIds;
    if (sThetaInstantGhostAllowMediaId.length) return @[ sThetaInstantGhostAllowMediaId ];
    return @[];
}

static id hook_instantSeenRequestInit(id self, SEL _cmd, id mediaIds) {
    if (thetaInstantGhostShouldBlockNetwork()) {
        if (orig_instantSeenRequestInit) return orig_instantSeenRequestInit(self, _cmd, @[]);
        return self;
    }
    if (!orig_instantSeenRequestInit) return self;
    return orig_instantSeenRequestInit(self, _cmd, thetaInstantFilterMediaIds(mediaIds));
}

static id hook_instantSeenRequestData(id self, SEL _cmd, id mediaIds) {
    if (thetaInstantGhostShouldBlockNetwork()) return nil;
    if (!orig_instantSeenRequestData) return nil;
    return orig_instantSeenRequestData(self, _cmd, thetaInstantFilterMediaIds(mediaIds));
}

static void hook_instantSyncSeenSnaps(id self, SEL _cmd, id sessionId, id onSuccess, id onFailure) {
    sThetaInstantQuickSnapService = self;
    if (thetaInstantGhostShouldBlockNetwork()) {
        if (onSuccess) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @try { ((void (^)(void))onSuccess)(); } @catch (__unused NSException *e) {}
            });
        }
        return;
    }
    if (sThetaInstantGhostAllowMediaId.length && orig_instantSeenRequestData) {
        Class reqCls = NSClassFromString(@"IGXDTMarkQuickSnapSeenRequest");
        if (reqCls) orig_instantSeenRequestData(reqCls, @selector(dataWithMediaIds:), @[ sThetaInstantGhostAllowMediaId ]);
    }
    if (orig_instantSyncSeenSnaps) orig_instantSyncSeenSnaps(self, _cmd, sessionId, onSuccess, onFailure);
}

static id hook_instantSeenMutationBuilder(id self, SEL _cmd, id includeMusic, id input) {
    if (thetaInstantGhostShouldBlockNetwork()) return nil;
    if (!orig_instantSeenMutationBuilder) return nil;
    return orig_instantSeenMutationBuilder(self, _cmd, includeMusic, input);
}

static NSURLRequest *thetaInstantDummyRequest(void) {
    return [NSURLRequest requestWithURL:[NSURL URLWithString:@"data:text/plain,"]];
}

static NSURLSessionDataTask *(*orig_instantNSURLDataTaskComp)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask *hook_instantNSURLDataTaskComp(id self, SEL _cmd, NSURLRequest *req, void (^comp)(NSData *, NSURLResponse *, NSError *)) {
    if (thetaInstantGhostShouldBlockNetwork() && thetaInstantPayloadLooksLikeSeen(req)) {
        if (comp) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
                comp(nil, nil, err);
            });
        }
        NSURLSessionDataTask *task = orig_instantNSURLDataTaskComp ? orig_instantNSURLDataTaskComp(self, _cmd, thetaInstantDummyRequest(), nil) : nil;
        [task cancel];
        return task;
    }
    return orig_instantNSURLDataTaskComp(self, _cmd, req, comp);
}

static NSURLSessionDataTask *(*orig_instantNSURLDataTask)(id, SEL, NSURLRequest *);
static NSURLSessionDataTask *hook_instantNSURLDataTask(id self, SEL _cmd, NSURLRequest *req) {
    if (thetaInstantGhostShouldBlockNetwork() && thetaInstantPayloadLooksLikeSeen(req)) {
        NSURLSessionDataTask *task = orig_instantNSURLDataTask ? orig_instantNSURLDataTask(self, _cmd, thetaInstantDummyRequest()) : nil;
        [task cancel];
        return task;
    }
    return orig_instantNSURLDataTask(self, _cmd, req);
}

static NSURLSessionUploadTask *(*orig_instantNSURLUpload)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionUploadTask *hook_instantNSURLUpload(id self, SEL _cmd, NSURLRequest *req, NSData *data, void (^comp)(NSData *, NSURLResponse *, NSError *)) {
    BOOL drop = thetaInstantGhostShouldBlockNetwork() && (thetaInstantPayloadLooksLikeSeen(req) || thetaInstantStringLooksLikeSeen([[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding]));
    if (drop) {
        if (comp) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
                comp(nil, nil, err);
            });
        }
        NSURLSessionUploadTask *task = orig_instantNSURLUpload ? orig_instantNSURLUpload(self, _cmd, thetaInstantDummyRequest(), [NSData data], nil) : nil;
        [task cancel];
        return task;
    }
    return orig_instantNSURLUpload(self, _cmd, req, data, comp);
}

static void (*orig_instantSetHTTPBody)(id, SEL, NSData *);
static void hook_instantSetHTTPBody(id self, SEL _cmd, NSData *data) {
    if (thetaInstantGhostShouldBlockNetwork() && data.length && data.length < 256u * 1024u) {
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        if (thetaInstantStringLooksLikeSeen(s)) {
            if (orig_instantSetHTTPBody) orig_instantSetHTTPBody(self, _cmd, [NSData data]);
            return;
        }
    }
    if (orig_instantSetHTTPBody) orig_instantSetHTTPBody(self, _cmd, data);
}

static void (*orig_instantSetHeader)(id, SEL, NSString *, NSString *);
static void hook_instantSetHeader(id self, SEL _cmd, NSString *value, NSString *field) {
    if (thetaInstantGhostShouldBlockNetwork() && thetaInstantStringLooksLikeSeen(value)) {
        if (orig_instantSetHeader) orig_instantSetHeader(self, _cmd, @"", field);
        return;
    }
    if (orig_instantSetHeader) orig_instantSetHeader(self, _cmd, value, field);
}

static void (*orig_instantDropReq)(id, SEL, id);
static void hook_instantDropReq(id self, SEL _cmd, id req) {
    if (thetaInstantGhostShouldBlockNetwork() && thetaInstantPayloadLooksLikeSeen(req)) return;
    if (orig_instantDropReq) orig_instantDropReq(self, _cmd, req);
}

static void (*orig_instantDefaultsSetObject)(id, SEL, id, id);
static void hook_instantDefaultsSetObject(id self, SEL _cmd, id obj, id key) {
    if ([key isKindOfClass:[NSString class]] && [(NSString *)key isEqualToString:@"kIGQuickSnapSeenStateKey"]) {
        if (thetaInstantGhostShouldBlockNetwork()) return;
    }
    if (orig_instantDefaultsSetObject) orig_instantDefaultsSetObject(self, _cmd, obj, key);
}

/* Swift Instant mark-seen: self lives in x20. Save/restore around ObjC work so orig still sees the store/VC. */
static uint64_t thetaInstantLoadX20(void) {
    uint64_t value;
    __asm__ volatile("mov %0, x20" : "=r"(value));
    return value;
}

static void thetaInstantStoreX20(uint64_t value) {
    __asm__ volatile("mov x20, %0" :: "r"(value) : "x20");
}

/* IDA 0x100000000: didPanConsumptionView: 0x10a74d26c, consumption mark-seen 0x10a1e8840, seenSnapPks writer 0x10a2e6fbc, syncSeenSnaps 0x1084afa6c, current snap 0x101afeaec, consumption transition 0x102df1ec8 */
static const uintptr_t kThetaIDADidPanConsumption = 0x10a74d26c;
static const uintptr_t kThetaIDASyncSeenSnaps = 0x1084afa6c;
static const uintptr_t kThetaIDAConsumptionMarkSeen = 0x10a1e8840;
static const uintptr_t kThetaIDAStoreSeenPks = 0x10a2e6fbc;
static const uintptr_t kThetaIDACurrentSnap = 0x101afeaec;
static const uintptr_t kThetaIDAConsumptionTransition = 0x102df1ec8;

static void *thetaInstantResolveFromAnchor(void *anchor, uintptr_t idaAnchor, uintptr_t idaTarget) {
    if (!anchor || !idaAnchor) return NULL;
    void *target = (void *)((uintptr_t)anchor + (idaTarget - idaAnchor));
    Dl_info anchorInfo, targetInfo;
    if (!dladdr(anchor, &anchorInfo) || !dladdr(target, &targetInfo)) return NULL;
    if (anchorInfo.dli_fbase != targetInfo.dli_fbase) return NULL;
    return target;
}

static void (*orig_instantConsumptionMarkSeen)(uint8_t shouldMark);
static void hook_instantConsumptionMarkSeen(uint8_t shouldMark) {
    uint64_t swiftSelf = thetaInstantLoadX20();
    BOOL block = thetaInstantGhostShouldBlockNetwork();
    thetaInstantStoreX20(swiftSelf);
    if (orig_instantConsumptionMarkSeen) orig_instantConsumptionMarkSeen(block ? 0 : shouldMark);
}

static void (*orig_instantStoreSeenPks)(void *pks);
static void hook_instantStoreSeenPks(void *pks) {
    uint64_t swiftSelf = thetaInstantLoadX20();
    BOOL block = thetaInstantGhostShouldBlockNetwork();
    thetaInstantStoreX20(swiftSelf);
    if (block) return;
    if (orig_instantStoreSeenPks) orig_instantStoreSeenPks(pks);
}

static void *(*orig_instantCurrentSnap)(void);
static void *hook_instantCurrentSnap(void) {
    uint64_t swiftSelf = thetaInstantLoadX20();
    thetaInstantStoreX20(swiftSelf);
    void *snap = orig_instantCurrentSnap ? orig_instantCurrentSnap() : NULL;
    thetaInstantStoreX20(swiftSelf);
    if (snap) {
        @try {
            NSString *mediaId = thetaInstantMediaId((__bridge id)snap);
            if (mediaId.length) sThetaInstantCurrentGraphQLID = [mediaId copy];
        } @catch (__unused NSException *e) {}
    }
    return snap;
}

static int64_t (*orig_instantConsumptionTransition)(int64_t, int64_t, int64_t);
static int64_t hook_instantConsumptionTransition(int64_t a1, int64_t a2, int64_t a3) {
    uint64_t swiftSelf = thetaInstantLoadX20();
    if (sThetaInstantSkipConsumptionTransition) {
        thetaInstantStoreX20(swiftSelf);
        return 0;
    }
    thetaInstantStoreX20(swiftSelf);
    return orig_instantConsumptionTransition ? orig_instantConsumptionTransition(a1, a2, a3) : 0;
}

static void (*orig_instantDidPanConsumption)(id, SEL, id);
static void hook_instantDidPanConsumption(id self, SEL _cmd, id gesture) {
    thetaInstantEnsureGhostHooks();
    if (orig_instantDidPanConsumption) orig_instantDidPanConsumption(self, _cmd, gesture);
}

static void (*orig_instantSwipeDownGesture)(id, SEL, id);
static void hook_instantSwipeDownGesture(id self, SEL _cmd, id gesture) {
    thetaInstantEnsureGhostHooks();
    if (orig_instantSwipeDownGesture) orig_instantSwipeDownGesture(self, _cmd, gesture);
}

static BOOL thetaInstantPickAnchor(void **outAnchor, uintptr_t *outIDA) {
    if (!outAnchor || !outIDA) return NO;
    if (orig_instantDidPanConsumption && orig_instantDidPanConsumption != hook_instantDidPanConsumption) {
        *outAnchor = (void *)orig_instantDidPanConsumption;
        *outIDA = kThetaIDADidPanConsumption;
        return YES;
    }
    Class pan = ThetaFirstClass(@[
        @"_TtC40IGQuickSnapNavigationV3PanGestureHandler40IGQuickSnapNavigationV3PanGestureHandler",
        @"IGQuickSnapNavigationV3PanGestureHandler",
    ]);
    Method panMethod = pan ? class_getInstanceMethod(pan, NSSelectorFromString(@"didPanConsumptionView:")) : NULL;
    IMP panImp = panMethod ? method_getImplementation(panMethod) : NULL;
    if (panImp && panImp != (IMP)hook_instantDidPanConsumption) {
        *outAnchor = (void *)panImp;
        *outIDA = kThetaIDADidPanConsumption;
        return YES;
    }
    if (orig_instantSyncSeenSnaps && orig_instantSyncSeenSnaps != hook_instantSyncSeenSnaps) {
        *outAnchor = (void *)orig_instantSyncSeenSnaps;
        *outIDA = kThetaIDASyncSeenSnaps;
        return YES;
    }
    return NO;
}

static void thetaInstantEnsureGhostHooks(void) {
    if (!orig_instantSeenRequestInit || !orig_instantSeenRequestData) {
        Class seenReq = ThetaFirstClass(@[ @"IGXDTMarkQuickSnapSeenRequest" ]);
        if (seenReq && !orig_instantSeenRequestInit)
            NullHookMessageIfPresent(seenReq, @selector(initWithMediaIds:), (void *)hook_instantSeenRequestInit, &orig_instantSeenRequestInit);
        if (seenReq && !orig_instantSeenRequestData)
            NullHookMessageIfPresent(seenReq, @selector(dataWithMediaIds:), (void *)hook_instantSeenRequestData, &orig_instantSeenRequestData);
    }
    if (!orig_instantSyncSeenSnaps) {
        NullHookMessageIfPresent(ThetaFirstClass(@[
            @"_TtC18IGQuickSnapService18IGQuickSnapService",
            @"IGQuickSnapService",
        ]), @selector(syncSeenSnapsWithServerWithDirectSessionId:onSuccess:onFailure:), (void *)hook_instantSyncSeenSnaps, &orig_instantSyncSeenSnaps);
    }
    if (!orig_instantSeenMutationBuilder) {
        NullHookMessageIfPresent(NSClassFromString(@"IGQuickSnapUpdateSeenStateMutationBuilder"),
                                 @selector(builderWithIncludeMusic:input:),
                                 (void *)hook_instantSeenMutationBuilder,
                                 &orig_instantSeenMutationBuilder);
    }
    if (!orig_instantNSURLDataTaskComp) {
        NullHookMessageIfPresent([NSURLSession class], @selector(dataTaskWithRequest:completionHandler:), (void *)hook_instantNSURLDataTaskComp, &orig_instantNSURLDataTaskComp);
        Class local = NSClassFromString(@"__NSURLSessionLocal");
        if (local && !orig_instantNSURLDataTaskComp)
            NullHookMessageIfPresent(local, @selector(dataTaskWithRequest:completionHandler:), (void *)hook_instantNSURLDataTaskComp, &orig_instantNSURLDataTaskComp);
    }
    if (!orig_instantNSURLDataTask) {
        NullHookMessageIfPresent([NSURLSession class], @selector(dataTaskWithRequest:), (void *)hook_instantNSURLDataTask, &orig_instantNSURLDataTask);
        Class local = NSClassFromString(@"__NSURLSessionLocal");
        if (local && !orig_instantNSURLDataTask)
            NullHookMessageIfPresent(local, @selector(dataTaskWithRequest:), (void *)hook_instantNSURLDataTask, &orig_instantNSURLDataTask);
    }
    if (!orig_instantNSURLUpload) {
        NullHookMessageIfPresent([NSURLSession class], @selector(uploadTaskWithRequest:fromData:completionHandler:), (void *)hook_instantNSURLUpload, &orig_instantNSURLUpload);
        Class local = NSClassFromString(@"__NSURLSessionLocal");
        if (local && !orig_instantNSURLUpload)
            NullHookMessageIfPresent(local, @selector(uploadTaskWithRequest:fromData:completionHandler:), (void *)hook_instantNSURLUpload, &orig_instantNSURLUpload);
    }
    if (!orig_instantSetHTTPBody)
        NullHookMessageIfPresent([NSMutableURLRequest class], @selector(setHTTPBody:), (void *)hook_instantSetHTTPBody, &orig_instantSetHTTPBody);
    if (!orig_instantSetHeader)
        NullHookMessageIfPresent([NSMutableURLRequest class], @selector(setValue:forHTTPHeaderField:), (void *)hook_instantSetHeader, &orig_instantSetHeader);

    if (!orig_instantDropReq) {
        NSArray<NSString *> *hosts = @[
            @"IGTigonNetworker", @"FBTigonService", @"TigonService",
            @"IGGraphQLService", @"IGGraphQLRequest", @"IGAPIRequest", @"IGURLRequest",
            @"PNPandoGraphQLService", @"FBGraphQLService"
        ];
        NSArray<NSString *> *sels = @[
            @"startRequest:", @"addRequest:", @"sendRequest:", @"startWithRequest:", @"startQuery:", @"handleQuery:"
        ];
        for (NSString *cn in hosts) {
            if (orig_instantDropReq) break;
            Class c = NSClassFromString(cn);
            if (!c) continue;
            for (NSString *sn in sels) {
                SEL s = NSSelectorFromString(sn);
                if (!class_getInstanceMethod(c, s) && !class_getClassMethod(c, s)) continue;
                NullHookMessageIfPresent(c, s, (void *)hook_instantDropReq, &orig_instantDropReq);
                if (orig_instantDropReq) break;
            }
        }
    }

    if (!orig_instantDefaultsSetObject)
        NullHookMessageIfPresent([NSUserDefaults class], @selector(setObject:forKey:), (void *)hook_instantDefaultsSetObject, &orig_instantDefaultsSetObject);

    if (!orig_instantConsumptionMarkSeen || !orig_instantStoreSeenPks || !orig_instantCurrentSnap || !orig_instantConsumptionTransition) {
        void *anchor = NULL;
        uintptr_t idaAnchor = 0;
        if (thetaInstantPickAnchor(&anchor, &idaAnchor)) {
            if (!orig_instantConsumptionMarkSeen) {
                void *sym = thetaInstantResolveFromAnchor(anchor, idaAnchor, kThetaIDAConsumptionMarkSeen);
                if (sym) ThetaMSHookFunction(sym, (void *)hook_instantConsumptionMarkSeen, (void **)&orig_instantConsumptionMarkSeen);
            }
            if (!orig_instantStoreSeenPks) {
                void *sym = thetaInstantResolveFromAnchor(anchor, idaAnchor, kThetaIDAStoreSeenPks);
                if (sym) ThetaMSHookFunction(sym, (void *)hook_instantStoreSeenPks, (void **)&orig_instantStoreSeenPks);
            }
            if (!orig_instantCurrentSnap) {
                void *sym = thetaInstantResolveFromAnchor(anchor, idaAnchor, kThetaIDACurrentSnap);
                if (sym) ThetaMSHookFunction(sym, (void *)hook_instantCurrentSnap, (void **)&orig_instantCurrentSnap);
            }
            if (!orig_instantConsumptionTransition) {
                void *sym = thetaInstantResolveFromAnchor(anchor, idaAnchor, kThetaIDAConsumptionTransition);
                if (sym) ThetaMSHookFunction(sym, (void *)hook_instantConsumptionTransition, (void **)&orig_instantConsumptionTransition);
            }
        }
    }

    if (!orig_instantDidPanConsumption) {
        NullHookMessageIfPresent(ThetaFirstClass(@[
            @"_TtC40IGQuickSnapNavigationV3PanGestureHandler40IGQuickSnapNavigationV3PanGestureHandler",
            @"IGQuickSnapNavigationV3PanGestureHandler",
        ]), NSSelectorFromString(@"didPanConsumptionView:"), (void *)hook_instantDidPanConsumption, &orig_instantDidPanConsumption);
    }
    if (!orig_instantSwipeDownGesture) {
        NullHookMessageIfPresent(ThetaFirstClass(@[
            @"_TtC36IGQuickSnapConsumptionGestureHandler46IGQuickSnapConsumptionGestureHandlerController",
            @"IGQuickSnapConsumptionGestureHandlerController",
        ]), NSSelectorFromString(@"handleSwipeDownGestureWithGesture:"), (void *)hook_instantSwipeDownGesture, &orig_instantSwipeDownGesture);
    }
}

static id thetaInstantFindQuickSnapService(id viewController) {
    if (sThetaInstantQuickSnapService) return sThetaInstantQuickSnapService;
    NSMutableArray *hosts = [NSMutableArray array];
    if (viewController) [hosts addObject:viewController];
    if ([viewController isKindOfClass:[UIViewController class]]) {
        UIViewController *parent = [(UIViewController *)viewController parentViewController];
        while (parent && hosts.count < 8) {
            [hosts addObject:parent];
            parent = parent.parentViewController;
        }
    }
    for (id host in hosts) {
        for (NSString *key in @[ @"quickSnapService", @"service", @"_quickSnapService" ]) {
            id val = ThetaValueForKey(host, key);
            if (val && [NSStringFromClass([val class]) containsString:@"IGQuickSnapService"]) return val;
        }
        id session = ThetaValueForKey(host, @"userSession");
        if (!session) session = ThetaValueForKey(host, @"_userSession");
        id fromSession = ThetaValueForKey(session, @"quickSnapService");
        if (fromSession && [NSStringFromClass([fromSession class]) containsString:@"IGQuickSnapService"]) return fromSession;
    }
    return nil;
}

static void thetaInstantClearGhostAllow(void) {
    sThetaInstantGhostAllowMediaId = nil;
}

static BOOL thetaInstantAddSeenIdToDefaults(id defaults, NSString *mediaId) {
    if (!defaults || !mediaId.length) return NO;
    if (![defaults respondsToSelector:@selector(objectForKey:)] || ![defaults respondsToSelector:@selector(setObject:forKey:)]) return NO;
    id existing = nil;
    @try { existing = [defaults objectForKey:@"kIGQuickSnapSeenStateKey"]; } @catch (__unused NSException *e) {}
    id next = nil;
    if ([existing isKindOfClass:[NSArray class]]) {
        if ([existing containsObject:mediaId]) return YES;
        NSMutableArray *arr = [existing mutableCopy] ?: [NSMutableArray array];
        [arr addObject:mediaId];
        next = arr;
    } else if ([existing isKindOfClass:[NSSet class]]) {
        if ([existing containsObject:mediaId]) return YES;
        NSMutableSet *set = [existing mutableCopy] ?: [NSMutableSet set];
        [set addObject:mediaId];
        next = set;
    } else if (!existing || existing == [NSNull null]) {
        next = @[ mediaId ];
    } else {
        return NO;
    }
    @try {
        [defaults setObject:next forKey:@"kIGQuickSnapSeenStateKey"];
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static id thetaInstantFindNavConsumptionVC(id start) {
    UIViewController *root = nil;
    if ([start isKindOfClass:[UIViewController class]]) {
        UIViewController *cursor = (UIViewController *)start;
        while (cursor) {
            NSString *name = NSStringFromClass([cursor class]);
            if ([name containsString:@"IGQuickSnapNavigationV3ConsumptionViewController"]) return cursor;
            root = cursor;
            cursor = cursor.parentViewController;
        }
    }
    NSMutableArray *queue = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    if (root) [queue addObject:root];
    else if ([start isKindOfClass:[UIViewController class]]) [queue addObject:start];
    while (queue.count) {
        UIViewController *item = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (![item isKindOfClass:[UIViewController class]] || [seen containsObject:item]) continue;
        [seen addObject:item];
        NSString *name = NSStringFromClass([item class]);
        if ([name containsString:@"IGQuickSnapNavigationV3ConsumptionViewController"]) return item;
        for (UIViewController *child in item.childViewControllers) [queue addObject:child];
        if (item.presentedViewController) [queue addObject:item.presentedViewController];
    }
    return nil;
}

static BOOL thetaInstantMarkSeenWithInstagram(id viewController) {
    thetaInstantEnsureGhostHooks();
    if (!orig_instantConsumptionMarkSeen || !orig_instantConsumptionTransition) return NO;
    id nav = thetaInstantFindNavConsumptionVC(viewController);
    if (!nav) return NO;
    sThetaInstantSkipConsumptionTransition = YES;
    uint64_t saved = thetaInstantLoadX20();
    @try {
        thetaInstantStoreX20((uint64_t)(__bridge void *)nav);
        orig_instantConsumptionMarkSeen(1);
    } @finally {
        thetaInstantStoreX20(saved);
        sThetaInstantSkipConsumptionTransition = NO;
    }
    return YES;
}

static BOOL thetaInstantCommitLocalSeen(id viewController, NSString *mediaId) {
    if (!mediaId.length) return NO;
    id service = thetaInstantFindQuickSnapService(viewController);
    NSMutableArray *defaultsList = [NSMutableArray array];
    void (^addDefaults)(id) = ^(id defaults) {
        if (!defaults || defaults == [NSNull null]) return;
        if (![defaultsList containsObject:defaults]) [defaultsList addObject:defaults];
    };
    addDefaults(ThetaValueForKey(service, @"sessionUserDefaults"));
    addDefaults(thetaInstantIvarObject(service, "sessionUserDefaults"));
    id store = ThetaValueForKey(service, @"quickSnapStore") ?: thetaInstantIvarObject(service, "quickSnapStore");
    addDefaults(ThetaValueForKey(store, @"sessionUserDefaults"));
    addDefaults(thetaInstantIvarObject(store, "sessionUserDefaults"));
    addDefaults([NSUserDefaults standardUserDefaults]);

    BOOL wrote = NO;
    for (id defaults in defaultsList) {
        if (thetaInstantAddSeenIdToDefaults(defaults, mediaId)) wrote = YES;
    }
    if (service) {
        @try {
            if ([service respondsToSelector:@selector(refreshSeenStateFromSharedStorage)]) {
                ((void (*)(id, SEL))objc_msgSend)(service, @selector(refreshSeenStateFromSharedStorage));
            }
        } @catch (__unused NSException *e) {}
        @try {
            SEL announce = @selector(announceSnapStateUpdateWithDidReceiveNewSnaps:);
            if ([service respondsToSelector:announce]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(service, announce, NO);
            }
        } @catch (__unused NSException *e) {}
    }
    return wrote;
}

static void thetaInstantMarkCurrentSeen(UIView *host, id viewController) {
    @try {
        NSString *mediaId = thetaInstantVisibleMediaId(host, viewController);
        if (!mediaId.length) {
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Couldn't mark seen"
                                       subtitle:@"Couldn't find this Instant."
                                           icon:[UIImage systemImageNamed:@"exclamationmark.triangle"]
                                       autoHide:3
                                        openURL:nil];
            }
            return;
        }
        id service = thetaInstantFindQuickSnapService(viewController);
        sThetaInstantGhostAllowMediaId = [mediaId copy];
        BOOL started = thetaInstantMarkSeenWithInstagram(viewController);
        if (!started) started = thetaInstantCommitLocalSeen(viewController, mediaId);
        else thetaInstantCommitLocalSeen(viewController, mediaId);
        if (orig_instantSeenRequestData) {
            Class reqCls = NSClassFromString(@"IGXDTMarkQuickSnapSeenRequest");
            if (reqCls) {
                @try {
                    orig_instantSeenRequestData(reqCls, @selector(dataWithMediaIds:), @[ mediaId ]);
                    started = YES;
                } @catch (__unused NSException *e) {}
            }
        }
        if (service && [service respondsToSelector:@selector(syncSeenSnapsWithServerWithDirectSessionId:onSuccess:onFailure:)]) {
            id sessionId = ThetaValueForKey(viewController, @"directSessionId");
            if (!sessionId) sessionId = ThetaValueForKey(viewController, @"sessionId");
            @try {
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, @selector(syncSeenSnapsWithServerWithDirectSessionId:onSuccess:onFailure:), sessionId, ^{
                    thetaInstantClearGhostAllow();
                }, ^{
                    thetaInstantClearGhostAllow();
                });
                started = YES;
            } @catch (__unused NSException *e) {}
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            thetaInstantClearGhostAllow();
        });
        if (!started) {
            thetaInstantClearGhostAllow();
            if (ENABLED(@"Show Banners")) {
                [ThetaHelper showToastWithTitle:@"Couldn't mark seen"
                                       subtitle:@"Couldn't find this Instant."
                                           icon:[UIImage systemImageNamed:@"exclamationmark.triangle"]
                                       autoHide:3
                                        openURL:nil];
            }
            return;
        }
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Marked as seen!"
                                   subtitle:@"Only this Instant was marked seen."
                                       icon:[ThetaHelper imageFromEmojiString:@"👀" width:60]
                                   autoHide:4
                                    openURL:nil];
        }
    } @catch (__unused NSException *e) {
        thetaInstantClearGhostAllow();
        if (ENABLED(@"Show Banners")) {
            [ThetaHelper showToastWithTitle:@"Couldn't mark seen"
                                   subtitle:@"Something went wrong."
                                       icon:[UIImage systemImageNamed:@"exclamationmark.triangle"]
                                   autoHide:3
                                    openURL:nil];
        }
    }
}

static BOOL thetaInstantShouldSkipDuplicateHost(id viewController) {
    UIViewController *parent = nil;
    @try { parent = [viewController parentViewController]; } @catch (__unused NSException *e) {}
    while (parent) {
        NSString *name = NSStringFromClass([parent class]);
        if ([name containsString:@"IGQuickSnapViewController"] && ![name containsString:@"Consumption"]) {
            return YES;
        }
        parent = parent.parentViewController;
    }
    return NO;
}

static char kThetaInstantButtonLaidOutKey;

static void thetaInstantInstallButtons(id viewController) {
    UIView *host = nil;
    @try { host = [viewController view]; } @catch (__unused NSException *e) {}
    if (![host isKindOfClass:[UIView class]]) return;

    BOOL saveOn = ENABLED(@"Save Instants");
    BOOL ghostOn = thetaInstantGhostEnabled();
    UIButton *saveButton = thetaInstantFindButton(host, kThetaInstantSaveButtonTag);
    UIButton *seenButton = thetaInstantFindButton(host, kThetaInstantSeenButtonTag);

    if (!saveOn) {
        [saveButton removeFromSuperview];
        saveButton = nil;
    }
    if (!ghostOn) {
        [seenButton removeFromSuperview];
        seenButton = nil;
    }
    if (!saveOn && !ghostOn) return;
    if (thetaInstantShouldSkipDuplicateHost(viewController)) return;

    if (saveOn && !saveButton) {
        saveButton = thetaInstantMakeChromeButton(kThetaInstantSaveButtonTag, @"arrow.down", @"Save Button Color_Color");
        [host addSubview:saveButton];
        objc_setAssociatedObject(saveButton, &kThetaInstantHostVCKey, viewController, OBJC_ASSOCIATION_ASSIGN);
        __weak UIView *weakHost = host;
        __weak UIButton *weakButton = saveButton;
        [saveButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            [ThetaHelper performHapticFeedbackIfEnabled];
            UIButton *button = weakButton;
            id vc = button ? objc_getAssociatedObject(button, &kThetaInstantHostVCKey) : nil;
            UIView *strongHost = button.window ?: weakHost;
            if (!strongHost) return;
            @try { thetaInstantSaveFromHost(strongHost, vc); } @catch (__unused NSException *e) {
                thetaInstantToastFailure(@"Couldn't find the current Instant photo/video.");
            }
        }] forControlEvents:UIControlEventTouchUpInside];
        [NSLayoutConstraint activateConstraints:@[
            [saveButton.trailingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor constant:-12],
            [saveButton.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:-120],
            [saveButton.widthAnchor constraintEqualToConstant:32],
            [saveButton.heightAnchor constraintEqualToConstant:32],
        ]];
        objc_setAssociatedObject(saveButton, &kThetaInstantButtonLaidOutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (ghostOn && !seenButton) {
        seenButton = thetaInstantMakeChromeButton(kThetaInstantSeenButtonTag, @"eye", @"Seen Button Color_Color");
        [host addSubview:seenButton];
        objc_setAssociatedObject(seenButton, &kThetaInstantHostVCKey, viewController, OBJC_ASSOCIATION_ASSIGN);
        __weak UIView *weakHost = host;
        __weak UIButton *weakButton = seenButton;
        [seenButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            [ThetaHelper performHapticFeedbackIfEnabled];
            UIButton *button = weakButton;
            id vc = button ? objc_getAssociatedObject(button, &kThetaInstantHostVCKey) : nil;
            UIView *strongHost = button.window ?: weakHost;
            if (!strongHost) return;
            thetaInstantMarkCurrentSeen(strongHost, vc);
        }] forControlEvents:UIControlEventTouchUpInside];
        NSLayoutAnchor *below = saveButton ? saveButton.topAnchor : host.safeAreaLayoutGuide.bottomAnchor;
        CGFloat belowConst = saveButton ? -20 : -120;
        [NSLayoutConstraint activateConstraints:@[
            [seenButton.trailingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor constant:-12],
            [seenButton.bottomAnchor constraintEqualToAnchor:below constant:belowConst],
            [seenButton.widthAnchor constraintEqualToConstant:32],
            [seenButton.heightAnchor constraintEqualToConstant:32],
        ]];
        objc_setAssociatedObject(seenButton, &kThetaInstantButtonLaidOutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (saveButton) [host bringSubviewToFront:saveButton];
    if (seenButton) [host bringSubviewToFront:seenButton];
}

static void hook_instantConsumptionLayout(id self, SEL _cmd) {
    orig_instantConsumptionLayout(self, _cmd);
    @try {
        thetaInstantEnsureGhostHooks();
        thetaInstantInstallButtons(self);
    } @catch (__unused NSException *e) {}
}

static void hook_instantQuickSnapLayout(id self, SEL _cmd) {
    orig_instantQuickSnapLayout(self, _cmd);
    @try {
        thetaInstantEnsureGhostHooks();
        thetaInstantInstallButtons(self);
    } @catch (__unused NSException *e) {}
}

static void hook_instantDetailsLayout(id self, SEL _cmd) {
    orig_instantDetailsLayout(self, _cmd);
    @try {
        thetaInstantEnsureGhostHooks();
        thetaInstantInstallButtons(self);
    } @catch (__unused NSException *e) {}
}

static void hook_instantNavLayout(id self, SEL _cmd) {
    orig_instantNavLayout(self, _cmd);
    @try {
        thetaInstantEnsureGhostHooks();
        thetaInstantInstallButtons(self);
    } @catch (__unused NSException *e) {}
}

static void hook_instantConsumptionAppear(id self, SEL _cmd, BOOL animated) {
    @try { thetaInstantEnsureGhostHooks(); } @catch (__unused NSException *e) {}
    if (orig_instantConsumptionAppear) orig_instantConsumptionAppear(self, _cmd, animated);
    @try { thetaInstantInstallButtons(self); } @catch (__unused NSException *e) {}
}

static void hook_instantNavAppear(id self, SEL _cmd, BOOL animated) {
    @try { thetaInstantEnsureGhostHooks(); } @catch (__unused NSException *e) {}
    if (orig_instantNavAppear) orig_instantNavAppear(self, _cmd, animated);
    @try { thetaInstantInstallButtons(self); } @catch (__unused NSException *e) {}
}

void THRegisterSaveInstantsHooks(void) {
    Class consumption = ThetaFirstClass(@[
        @"_TtC26IGQuickSnapConsumptionCore36IGQuickSnapConsumptionViewController",
        @"IGQuickSnapConsumptionViewController",
    ]);
    NullHookMessageIfPresent(consumption, @selector(viewDidLayoutSubviews), (void *)hook_instantConsumptionLayout, &orig_instantConsumptionLayout);
    NullHookMessageIfPresent(consumption, @selector(viewWillAppear:), (void *)hook_instantConsumptionAppear, &orig_instantConsumptionAppear);

    NullHookMessageIfPresent(ThetaFirstClass(@[
        @"_TtC11IGQuickSnap25IGQuickSnapViewController",
        @"IGQuickSnapViewController",
    ]), @selector(viewDidLayoutSubviews), (void *)hook_instantQuickSnapLayout, &orig_instantQuickSnapLayout);

    NullHookMessageIfPresent(ThetaFirstClass(@[
        @"_TtC27IGQuickSnapScrollingDetails41IGQuickSnapScrollingDetailsViewController",
        @"IGQuickSnapScrollingDetailsViewController",
    ]), @selector(viewDidLayoutSubviews), (void *)hook_instantDetailsLayout, &orig_instantDetailsLayout);

    Class nav = ThetaFirstClass(@[
        @"_TtC32IGQuickSnapNavigationV3Container46IGQuickSnapNavigationV3ContainerViewController",
        @"IGQuickSnapNavigationV3ContainerViewController",
    ]);
    NullHookMessageIfPresent(nav, @selector(viewDidLayoutSubviews), (void *)hook_instantNavLayout, &orig_instantNavLayout);
    NullHookMessageIfPresent(nav, @selector(viewDidAppear:), (void *)hook_instantNavAppear, &orig_instantNavAppear);

    thetaInstantEnsureGhostHooks();
}
