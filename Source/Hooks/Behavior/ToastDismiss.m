static void (*orig_IGNotificationPresenter_dismissAnimated)(id, SEL, BOOL) = nil;
static void hook_IGNotificationPresenter_dismissAnimated(id self, SEL _cmd, BOOL animated) {
    // Only hold dismiss for Theta-owned native toasts. Applying this to Instagram's
    // own banners (account switch, "video unavailable", etc.) leaves the presenter
    // in a bad state and the app freezes shortly after the banner appears.
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (s_lastToastShowTime > 0 && (now - s_lastToastShowTime) < 1.5) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (orig_IGNotificationPresenter_dismissAnimated) orig_IGNotificationPresenter_dismissAnimated(self, _cmd, animated);
        });
        return;
    }
    if (orig_IGNotificationPresenter_dismissAnimated) orig_IGNotificationPresenter_dismissAnimated(self, _cmd, animated);
}

void THRegisterToastDismissHooks(void) {
    NullHookMessageIfPresent(objc_getClass("IGNotificationPresenter"),
                             NSSelectorFromString(@"dismissAnimated:"),
                             (void *)hook_IGNotificationPresenter_dismissAnimated,
                             (void **)&orig_IGNotificationPresenter_dismissAnimated);
}
