#import <UIKit/UIKit.h>
#import <SpringBoard/SBApplicationController.h>
#import <SpringBoard/SBAwayBulletinListItem.h>
#import <SpringBoard/SBApplicationIcon.h>
#import <SpringBoard/SBLockScreenNotificationListView.h>
#import <SpringBoard/SBBulletinBannerController.h>
#import <BulletinBoard/BBBulletin.h>
#import <UIKit/UIImage+Private.h>
#import <objc/runtime.h>
#import <substrate.h>

#define PHPrefsPath @"/var/mobile/Library/Preferences/com.thomasfinch.priorityhub.plist"
#define IS_IPAD (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone)

#ifdef DEBUG
    #define PRLog(fmt, ...) NSLog((@"[PriorityHub] %s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
    #define PRLog(fmt, ...) 
#endif

/* TODO:
        All notifications view
        Fix crash when tapping or whatever
        SubtleLock compatibility
*/

static UIView *view, *selectedView, *allNotifsView;
static UIScrollView *appListView;
static NSMutableDictionary *prefsDict, *appData;
static UITableView *notificationTableView;
static NSString *curAppID = nil;
static BOOL shouldBlockFade = YES, isLocked = YES, timerRunning = NO, xViewIsSolid = NO, shouldClearNotifs = NO, inAllNotifsMode = NO;
static id controller, observer;
static NSBundle *iconsBundle, *imagesBundle;
static NSTimer *timer;
static UIImageView *xImageView;

static void priorityPrefsChanged(CFNotificationCenterRef center, void *observer,CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    prefsDict = [NSMutableDictionary dictionaryWithContentsOfFile:PHPrefsPath];
    
    //Add preferences if they don't already exist
    if (![prefsDict objectForKey:@"showNumbers"]) {
        [prefsDict setObject:@(YES) forKey:@"showNumbers"];
    }

    if (![prefsDict objectForKey:@"iconLocation"]) {
        [prefsDict setObject:@(0) forKey:@"iconLocation"];
    }
    
    [prefsDict writeToFile:PHPrefsPath atomically:YES];
}

%ctor {
    dlopen("/Library/MobileSubstrate/DynamicLibraries/SubtleLock.dylib", RTLD_NOW);
    
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, &priorityPrefsChanged, CFSTR("com.thomasfinch.priorityhub-prefschanged"), NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
    
    //Load bundles for themed images
    iconsBundle = [[NSBundle alloc] initWithPath:@"/Library/Application Support/PriorityHub/Icons.bundle"];
    imagesBundle = [[NSBundle alloc] initWithPath:@"/Library/Application Support/PriorityHub/Images.bundle"];
    
    //Initial load of preferences
    priorityPrefsChanged(nil,nil,nil,nil,nil);
}

static CGFloat iconSize() {
    return IS_IPAD ? 40.0 : 30.0;
}

static CGFloat viewWidth() {
    return iconSize() * 1.55;
}

static float viewHeight() {
    if ([[prefsDict objectForKey:@"showNumbers"] boolValue]) {
        return iconSize() * 1.85;
    }

    else {
        return viewWidth();
    }
}

static BOOL tweakIsInstalled(NSString *tweakName) {
    return [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithFormat:@"/Library/MobileSubstrate/DynamicLibraries/%@.dylib", tweakName]];
}

static BOOL shouldFilterIndexPath(id indexPath) {
    if (inAllNotifsMode) {
        return NO;
    }

    else if (!curAppID) { //If no app is selected, none should be shown
        return YES;
    }

    SBAwayBulletinListItem *item = [controller listItemAtIndexPath:indexPath];
    BBBulletin *bulletin = [item activeBulletin];
    NSString *sectionID = [bulletin sectionID];

    return ![sectionID isEqualToString:curAppID];
}

static UIImage * iconForAppID(NSString* appID) {
    if (!iconsBundle) {
        iconsBundle = [[NSBundle alloc] initWithPath:@"/Library/Application Support/PriorityHub/Icons.bundle"];
    }
    
    UIImage *img = [UIImage imageNamed:[NSString stringWithFormat:@"%@.png",appID] inBundle:iconsBundle];
    if (img) {
        return img;
    }

    else {
        SBApplicationController *controller = [%c(SBApplicationController) sharedInstance];
        SBApplication *application = [controller applicationWithDisplayIdentifier:appID];
        SBApplicationIcon *icon = [[%c(SBApplicationIcon) alloc] initWithApplication:application];
        return [icon getIconImage:SBApplicationIconFormatSpotlight];
    }
}

// wut
static CGRect selectedFrameForContainerFrame(CGRect frame) {
    return CGRectMake(frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
}

static void switchToAppID(NSString *appID) {
    if (!appID) { //If appID is nil, deselects the current view
        curAppID = nil;

        [UIView animateWithDuration:0.15 animations:^{
            selectedView.alpha = 0.0;
            notificationTableView.alpha = 0.0;
        } completion:^(BOOL completed) {
            //Reload notifications list table view
            if (controller) {
                id notificationView = MSHookIvar<id>(controller,"_notificationView");
                UITableView *tableView = MSHookIvar<UITableView*>(notificationView, "_tableView");
                [tableView reloadData];
            }
        }];
    }

    else if ([appID isEqualToString:@"allNotifs"]) { //Switch to the all notifications view
        //curAppID = ???
        inAllNotifsMode = YES;

        [UIView animateWithDuration:0.15 animations:^{
            selectedView.alpha = 1.0;
            selectedView.frame = allNotifsView.frame;
            allNotifsView.alpha = 1.0;
            
            for (NSString *key in [appData allKeys]) {
                ((UIView*)[[appData objectForKey:key] objectForKey:@"view"]).alpha = 0.0;
            }  
        } completion:^(BOOL completed){
            //Reload notifications list table view
            if (controller) {
                id notificationView = MSHookIvar<id>(controller,"_notificationView");
                UITableView *tableView = MSHookIvar<UITableView*>(notificationView, "_tableView");
                [tableView reloadData];
            }
        }];
    }

    else if ([appID isEqualToString:@"notAllNotifs"]) { //Switch back from all notifications view
        curAppID = nil;
        inAllNotifsMode = NO;

        [UIView animateWithDuration:0.15 animations:^{
            selectedView.alpha = 0.0;
            allNotifsView.alpha = 0.0;
            
            for (NSString *key in [appData allKeys]) {
                ((UIView*)[[appData objectForKey:key] objectForKey:@"view"]).alpha = 1.0;
            }
            
        }completion:^(BOOL completed){
            //Reload notifications list table view
           if (controller) {
                SBLockScreenNotificationListView *notificationView = MSHookIvar<id>(controller,"_notificationView");
                UITableView *tableView = MSHookIvar<UITableView*>(notificationView, "_tableView");
                [tableView reloadData];
            }        
        }];
    }

    else { //Otherwise, animates the selection view sliding
        if (shouldBlockFade && controller) {
            SBLockScreenNotificationListView *notificationView = MSHookIvar<id>(controller,"_notificationView");
            [notificationView _resetAllFadeTimers];
        }

        shouldBlockFade = YES;
        BOOL wasAppSelected = (curAppID != nil);
        curAppID = appID;


        if (controller) {   //Reload notifications list table view
            SBLockScreenNotificationListView *notificationView = MSHookIvar<id>(controller,"_notificationView");
            UITableView *tableView = MSHookIvar<UITableView*>(notificationView, "_tableView");
            [tableView reloadData];
        }

        if (!wasAppSelected) {
            UIView *appView = (UIView *) [[appData objectForKey:appID] objectForKey:@"view"];
            selectedView.frame = selectedFrameForContainerFrame(appView.frame);
        }
        
        [UIView animateWithDuration:0.15 animations:^{
            selectedView.alpha = 1.0;
            notificationTableView.alpha = 1.0;

            if (wasAppSelected) {
                UIView *appView = (UIView *) [[appData objectForKey:appID] objectForKey:@"view"];
                selectedView.frame = selectedFrameForContainerFrame(appView.frame);
            }
        } completion:nil];
    }
}

//Lays out the app's container views centered in the main scroll view
static void layoutSubviews() {
    CGFloat totalViewWidth = [[appData allKeys] count] * viewWidth();
    CGFloat startX = (appListView.frame.size.width - totalViewWidth) / 2.0;
    if (startX < 0) {
        startX = 0;
    }
    
    appListView.contentSize = CGSizeZero;
    appListView.contentOffset = CGPointZero;
    
    for (NSString *key in [appData allKeys]) {
        UIView *view = (UIView *) [[appData objectForKey:key] objectForKey:@"view"];
        view.frame = CGRectMake(startX+appListView.contentSize.width, 0, viewWidth(), viewHeight());
        appListView.contentSize = CGSizeMake(appListView.contentSize.width + viewWidth(), viewHeight());
        
        if (![view superview]) {
            [appListView addSubview:view];
        }
    }
}

static CGRect frameForAppListView() {
    if (tweakIsInstalled(@"SubtleLock")) {
        if ([[prefsDict objectForKey:@"iconLocation"] intValue] == 0) { //Icons are at top
            return CGRectMake(0.0, 0.0, view.frame.size.width, viewHeight());
        }

        else {
            return CGRectMake(0.0 ,notificationTableView.frame.size.height + 15.0, view.frame.size.width, viewHeight());
        }
    }

    else {
        if ([[prefsDict objectForKey:@"iconLocation"] intValue] == 0) { //Icons are at top
            return CGRectMake(0.0, view.frame.origin.y - viewHeight() - 2.5, view.frame.size.width, viewHeight());
        }

        else {
            return CGRectMake(0.0, view.frame.origin.y+view.frame.size.height + 2.5, view.frame.size.width, viewHeight());
        }
    }   
}

%hook SBLockScreenNotificationListView

- (void)layoutSubviews {
    %orig();
    
    PRLog(@"LAYING OUT VIEWS");
    appData = [[NSMutableDictionary alloc] init];
    
    notificationTableView = MSHookIvar<UITableView*>(self,"_tableView");
    view = MSHookIvar<UIView*>(self,"_containerView");
    
    appListView = [[UIScrollView alloc] init];
    appListView.contentSize = CGSizeMake(0,viewHeight());
    
    //appListView.backgroundColor = [UIColor blueColor];
    //notificationTableView.backgroundColor = [UIColor redColor];
    
    if (tweakIsInstalled(@"SubtleLock")) {
        if ([[prefsDict objectForKey:@"iconLocation"] intValue] == 0) { //Icons are at top
            notificationTableView.frame = CGRectMake(0, viewHeight() + 15.0, notificationTableView.frame.size.width, notificationTableView.frame.size.height - viewHeight() - 2.5);
        }

        else {
            notificationTableView.frame = CGRectMake(0.0, 0.0, notificationTableView.frame.size.width, notificationTableView.frame.size.height-viewHeight() - 15.0);
        }
            
        [view addSubview:appListView];
    }

    else {
        if ([[prefsDict objectForKey:@"iconLocation"] intValue] == 0) { //Icons are at top
            view.frame = CGRectMake(view.frame.origin.x, view.frame.origin.y + viewHeight() + 2.5, view.frame.size.width,view.frame.size.height - viewHeight());
            notificationTableView.frame = CGRectMake(0.0, 0.0, notificationTableView.frame.size.width, view.frame.size.height);
        }

        else {
            view.frame = CGRectMake(view.frame.origin.x, view.frame.origin.y, view.frame.size.width, view.frame.size.height - viewHeight() - 2.5);
            notificationTableView.frame = CGRectMake(0.0, 0.0, notificationTableView.frame.size.width, view.frame.size.height);
        }
        
        [self addSubview:appListView];
    }
    
    appListView.frame = frameForAppListView();
    
    //Make sure app list view stays in the right spot when rotated
    // appListView.autoresizingMask = (UIViewAutoresizingFlexibleWidth);
    // appListView.center = CGPointMake(appListView.frame.origin.x+appListView.frame.size.width/2,appListView.frame.origin.y+appListView.frame.size.height/2);
    // appListView.bounds = appListView.frame;
    
    selectedView = [[UIView alloc] init];
    selectedView.backgroundColor = [UIColor colorWithWhite:0.75 alpha:0.3];
    selectedView.layer.cornerRadius = 10.0;
    selectedView.layer.masksToBounds = YES;
    [appListView addSubview:selectedView];
    
    // allNotifsView = [[UIView alloc] initWithFrame:CGRectMake((appListView.frame.size.width-viewWidth())/2,0,viewWidth(),viewHeight())];
    // allNotifsView.backgroundColor = [UIColor redColor];
    // allNotifsView.alpha = 0.0f;
    // [appListView addSubview:allNotifsView];
    
    if (!imagesBundle) {
        imagesBundle = [NSBundle bundleWithPath:@"/Library/Application Support/PriorityHub/Images.bundle"];
    }
    
    xImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"CloseXEmpty.png" inBundle:imagesBundle]];
    xImageView.frame = CGRectMake((notificationTableView.frame.size.width - iconSize()) / 2.0, -1.5 * iconSize(),iconSize(), iconSize());
    [notificationTableView addSubview:xImageView];
    
    curAppID = nil;
}

- (void)scrollViewDidScroll:(UIScrollView*)scrollView {
    %orig();

    if (!xViewIsSolid && scrollView.contentOffset.y < (-1.5 * iconSize())) {
        xViewIsSolid = YES;
        xImageView.image = [UIImage imageNamed:@"CloseXFilled.png" inBundle:imagesBundle];
    }

    else if (xViewIsSolid && !shouldClearNotifs && scrollView.contentOffset.y > (-1.5 * iconSize())) {
        xViewIsSolid = NO;
        xImageView.image = [UIImage imageNamed:@"CloseXEmpty.png" inBundle:imagesBundle];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView*)scrollView willDecelerate:(_Bool)arg2 {
    %orig();
    shouldClearNotifs = (scrollView.contentOffset.y < (-1.5 * iconSize()));
}

- (void)scrollViewDidEndDecelerating:(UIScrollView*)scrollView {
    %orig();
    xViewIsSolid = NO;
    xImageView.image = [UIImage imageNamed:@"CloseXEmpty.png" inBundle:imagesBundle];
    
    if (shouldClearNotifs) {
        NSString *oldAppId = curAppID;
        //Clear notifications for the current app
        SBBulletinBannerController *bannerController = controller;
        for (id bulletin in [[appData objectForKey:curAppID] objectForKey:@"bulletins"]) {
            [bannerController observer:observer removeBulletin:bulletin];
        }
        
        PRLog(@"OLD: %@",oldAppId);
        if (oldAppId) {
            [appData removeObjectForKey:oldAppId];
        }

        switchToAppID(nil);
    }
    
    shouldClearNotifs = NO;
}

%new - (void)orientationChanged {
    // Update location of appListView
    // if ([[prefsDict objectForKey:@"iconLocation"] intValue] == 0)
    //    appListView.frame = CGRectMake(0,view.frame.origin.y-viewHeight()-2.5, view.frame.size.width, viewHeight());
    // else
    //    appListView.frame = CGRectMake(0,view.frame.origin.y+view.frame.size.height+2.5, view.frame.size.width, viewHeight());
    
    layoutSubviews();
}

- (void)setInScreenOffMode:(BOOL)screenOff {
    PRLog(@"VIEW: %@",appListView);
    appListView.frame = frameForAppListView();
    if (screenOff && isLocked) {
        switchToAppID(nil);
    }
        
    %orig();
}

- (CGFloat)tableView:(id)arg1 heightForRowAtIndexPath:(id)arg2 {
    return shouldFilterIndexPath(arg2) ? 0.0 : %orig();
}

- (id)initWithFrame:(CGRect)arg1 {
    id orig = %orig;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:orig selector:@selector(orientationChanged) name:@"UIDeviceOrientationDidChangeNotification" object:nil];
    return orig;
}

%end

%hook SBLockScreenNotificationListController

- (void)observer:(id)arg1 addBulletin:(id)bulletin forFeed:(unsigned long long)arg3 {
    PRLog(@"ADD BULLETIN");
    
    controller = self;
    appListView.hidden = NO;
    isLocked = YES;
    observer = arg1;
    
    if (![appData objectForKey:[bulletin sectionID]]) { //If there are no notifications for this app yet, create the views for it
        UIView *containerView = [[UIView alloc] initWithFrame:CGRectMake(appListView.contentSize.width, 0.0, viewWidth(), viewHeight())];
        containerView.tag = 1;
        UITapGestureRecognizer *singleFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
        [containerView addGestureRecognizer:singleFingerTap];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        [containerView addGestureRecognizer:longPress];
        
        UIImageView *iconImageView = [[UIImageView alloc] initWithImage:iconForAppID([bulletin sectionID])];
        iconImageView.frame = CGRectMake((viewWidth() - iconSize()) /2.0, 5.0, iconSize(), iconSize());
        [containerView addSubview:iconImageView];
        
        if ([[prefsDict objectForKey:@"showNumbers"] boolValue]) {
            UILabel *numberLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, iconImageView.frame.origin.y+iconImageView.frame.size.height + ((containerView.frame.size.height - (iconImageView.frame.origin.y+iconImageView.frame.size.height)) - 15.9) / 2.0, viewWidth(), 15.0)];
            numberLabel.text = @"1";
            numberLabel.textColor = [UIColor whiteColor];
            numberLabel.textAlignment = UITextAlignmentCenter;
            [containerView addSubview:numberLabel];
        }

        else {
            iconImageView.frame = CGRectMake((viewHeight() - iconSize()) / 2.0, (viewWidth() - iconSize()) / 2.0, iconSize(), iconSize());
        }

        NSMutableArray *bulletins = [[NSMutableArray alloc] init];
        [bulletins addObject:bulletin];

        [appData setObject:@{ @"bulletins" : bulletins, @"view" : containerView } forKey:[bulletin sectionID]];    
        layoutSubviews();
    }

    else { //If there are already some notifications for this app
        [[[appData objectForKey:[bulletin sectionID]] objectForKey:@"bulletins"] addObject:bulletin];

        if ([[prefsDict objectForKey:@"showNumbers"] boolValue]) {
            NSDictionary *bulletinDict = [appData objectForKey:[bulletin sectionID]];
            UILabel *bulletinlabel = (UILabel *)[[bulletinDict objectForKey:@"view"] subviews][1];
            NSMutableArray *bulletins = (NSMutableArray *)[[appData objectForKey:[bulletin sectionID]] objectForKey:@"bulletins"];
            bulletinlabel.text = [@([bulletins count]) stringValue];
        }
    }
    
    %orig();
    
    //Switch to the app for the notification that just came in
    shouldBlockFade = NO;
    switchToAppID([bulletin sectionID]);
}

%new - (void)handleSingleTap:(UITapGestureRecognizer*)recognizer {
    if (!timerRunning) {
        timerRunning = YES;
        SBLockScreenNotificationListView *notificationView = MSHookIvar<id>(self,"_notificationView");
        [notificationView _disableIdleTimer:YES];
        timer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(reenableIdleTimer) userInfo:nil repeats:NO];
    }

    NSString *tappedAppID;
    for (NSString *key in [appData allKeys]) {
        if ([[appData objectForKey:key] objectForKey:@"view"] == recognizer.view) {
            tappedAppID = key;
            break;
        }
    }

    if ([tappedAppID isEqualToString:curAppID]) {
        switchToAppID(nil);
    }

    else {
        switchToAppID(tappedAppID);
    }
}

%new - (void)handleLongPress:(UILongPressGestureRecognizer*)recognizer {
//    if (recognizer.state == UIGestureRecognizerStateEnded)
//    {
//        if (inAllNotifsMode)
//            switchToAppID(@"notAllNotifs");
//        else
//            switchToAppID(@"allNotifs");
//    }
}

%new - (void)reenableIdleTimer {
    timerRunning = NO;

    SBLockScreenNotificationListView *notificationView = MSHookIvar<id>(self,"_notificationView");
    [notificationView _disableIdleTimer:timerRunning];
}

- (void)observer:(id)arg1 removeBulletin:(id)bulletin {
    PRLog(@"REMOVE BULLETIN");
    NSMutableArray *bulletins = (NSMutableArray *)[[appData objectForKey:[bulletin sectionID]] objectForKey:@"bulletins"];
    UIView *view = [[appData objectForKey:[bulletin sectionID]] objectForKey:@"view"];

    if (!shouldClearNotifs) {
        [bulletins removeObject:bulletin];
    }
    
    if ([[prefsDict objectForKey:@"showNumbers"] boolValue]) {
        UILabel *bulletinlabel = (UILabel *) [view subviews][1];
        bulletinlabel.text = [@([bulletins count]) stringValue];
    }
    
    if ([bulletins count] == 0 || shouldClearNotifs) {
        [view removeFromSuperview];
        [appData removeObjectForKey:[bulletin sectionID]];
        
        switchToAppID(nil);
        layoutSubviews();
    }
    
    %orig();
}

%end

%hook SBLockScreenNotificationCell

- (id)initWithStyle:(long long)arg1 reuseIdentifier:(id)arg2 {
    id orig = %orig;
    MSHookIvar<UIView*>(orig,"_topSeparatorView") = nil;
    MSHookIvar<UIView*>(orig,"_bottomSeparatorView") = nil;
    return orig;
}

%end

%hook SBLockScreenManager

- (void)_setUILocked:(BOOL)locked {
    //When device is unlocked, clear all notifications and hide the views
    if (!locked) {
        for (NSString *key in [appData allKeys]) {
            [[[appData objectForKey:key] objectForKey:@"view"] removeFromSuperview];
        }
        
        isLocked = NO;
    }
    
    %orig();
}

%end
