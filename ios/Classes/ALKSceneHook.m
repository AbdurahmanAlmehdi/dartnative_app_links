// Hooks DartNativeSceneDelegate at +load so links reach app_links_kit with
// zero app changes. DartNativeSceneDelegate implements only
// scene:willConnectToSession:options:, and plugins get no scene callbacks,
// so the pod wraps that method and adds scene:openURLContexts: and
// scene:continueUserActivity:. Opt out with AppLinksKitAutoHook = NO in
// Info.plist and forward manually through AppLinksKit.handle(...).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern void DNAppLinksReceive(const char *url);

static NSString *const kBaseClassMangled = @"_TtC14dartnative_ios23DartNativeSceneDelegate";
static NSString *const kBaseClassDemangled = @"dartnative_ios.DartNativeSceneDelegate";

static void ALKReceiveURL(NSURL *url) {
  NSString *link = url.absoluteString;
  if (link.length > 0) DNAppLinksReceive(link.UTF8String);
}

static void ALKReceiveContexts(NSSet<UIOpenURLContext *> *contexts) {
  for (UIOpenURLContext *context in contexts) ALKReceiveURL(context.URL);
}

static void ALKReceiveActivity(NSUserActivity *activity) {
  if ([activity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
    ALKReceiveURL(activity.webpageURL);
  }
}

// A subclass override that calls super through objc_msgSendSuper reaches
// both hooks with the same payload object; handle it once.
static BOOL ALKIsNewPayload(id payload) {
  static __weak id last;
  if (payload == nil || payload == last) return NO;
  last = payload;
  return YES;
}

static BOOL ALKDefinesItself(Class cls, SEL sel) {
  unsigned int count = 0;
  Method *methods = class_copyMethodList(cls, &count);
  BOOL found = NO;
  for (unsigned int i = 0; i < count && !found; i++) {
    found = method_getName(methods[i]) == sel;
  }
  free(methods);
  return found;
}

static BOOL ALKIsKindOf(Class cls, Class base) {
  for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
    if (c == base) return YES;
  }
  return NO;
}

static const char *ALKTypes(SEL sel) {
  return protocol_getMethodDescription(@protocol(UISceneDelegate), sel, NO, YES).types;
}

typedef void (*ALKWillConnectFn)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *);
typedef void (*ALKOpenURLFn)(id, SEL, UIScene *, NSSet<UIOpenURLContext *> *);
typedef void (*ALKContinueFn)(id, SEL, UIScene *, NSUserActivity *);

// Captures before the original runs: the original starts the Dart runtime,
// and the link must be stored before Dart can ask for it.
static void ALKHookWillConnect(Class cls) {
  SEL sel = @selector(scene:willConnectToSession:options:);
  if (!ALKDefinesItself(cls, sel)) return;
  Method method = class_getInstanceMethod(cls, sel);
  ALKWillConnectFn original = (ALKWillConnectFn)method_getImplementation(method);
  IMP hooked = imp_implementationWithBlock(
      ^(id me, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *options) {
        if (ALKIsNewPayload(options)) {
          ALKReceiveContexts(options.URLContexts);
          for (NSUserActivity *activity in options.userActivities) ALKReceiveActivity(activity);
        }
        original(me, sel, scene, session, options);
      });
  method_setImplementation(method, hooked);
}

static void ALKHookOpenURL(Class cls, BOOL addIfMissing) {
  SEL sel = @selector(scene:openURLContexts:);
  if (ALKDefinesItself(cls, sel)) {
    Method method = class_getInstanceMethod(cls, sel);
    ALKOpenURLFn original = (ALKOpenURLFn)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(
        ^(id me, UIScene *scene, NSSet<UIOpenURLContext *> *contexts) {
          if (ALKIsNewPayload(contexts)) ALKReceiveContexts(contexts);
          original(me, sel, scene, contexts);
        }));
  } else if (addIfMissing) {
    class_addMethod(cls, sel, imp_implementationWithBlock(
        ^(id me, UIScene *scene, NSSet<UIOpenURLContext *> *contexts) {
          if (ALKIsNewPayload(contexts)) ALKReceiveContexts(contexts);
        }), ALKTypes(sel));
  }
}

static void ALKHookContinue(Class cls, BOOL addIfMissing) {
  SEL sel = @selector(scene:continueUserActivity:);
  if (ALKDefinesItself(cls, sel)) {
    Method method = class_getInstanceMethod(cls, sel);
    ALKContinueFn original = (ALKContinueFn)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(
        ^(id me, UIScene *scene, NSUserActivity *activity) {
          if (ALKIsNewPayload(activity)) ALKReceiveActivity(activity);
          original(me, sel, scene, activity);
        }));
  } else if (addIfMissing) {
    class_addMethod(cls, sel, imp_implementationWithBlock(
        ^(id me, UIScene *scene, NSUserActivity *activity) {
          if (ALKIsNewPayload(activity)) ALKReceiveActivity(activity);
        }), ALKTypes(sel));
  }
}

// The app's own SceneDelegate, from the scene manifest. Swift overrides call
// super directly (not through objc_msgSend), which would skip a base-class
// hook, so methods the app defines itself are wrapped too.
static NSArray<Class> *ALKManifestDelegateClasses(Class base) {
  NSDictionary *manifest = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIApplicationSceneManifest"];
  NSDictionary *configs = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"UISceneConfigurations"] : nil;
  NSArray *roles = [configs isKindOfClass:NSDictionary.class] ? configs[@"UIWindowSceneSessionRoleApplication"] : nil;
  NSMutableArray<Class> *classes = [NSMutableArray array];
  for (NSDictionary *config in [roles isKindOfClass:NSArray.class] ? roles : @[]) {
    NSString *name = [config isKindOfClass:NSDictionary.class] ? config[@"UISceneDelegateClassName"] : nil;
    Class cls = [name isKindOfClass:NSString.class] ? NSClassFromString(name) : Nil;
    if (cls != Nil && cls != base && ALKIsKindOf(cls, base) && ![classes containsObject:cls]) {
      [classes addObject:cls];
    }
  }
  return classes;
}

@interface ALKSceneHook : NSObject
@end

@implementation ALKSceneHook

+ (void)load {
  id flag = [NSBundle.mainBundle objectForInfoDictionaryKey:@"AppLinksKitAutoHook"];
  if ([flag respondsToSelector:@selector(boolValue)] && ![flag boolValue]) {
    NSLog(@"[app_links_kit] AppLinksKitAutoHook = NO: forward links with AppLinksKit.handle(...)");
    return;
  }
  Class base = NSClassFromString(kBaseClassMangled) ?: NSClassFromString(kBaseClassDemangled);
  if (base == Nil) {
    NSLog(@"[app_links_kit] DartNativeSceneDelegate not found; links will not be captured");
    return;
  }
  ALKHookWillConnect(base);
  ALKHookOpenURL(base, YES);
  ALKHookContinue(base, YES);
  for (Class cls in ALKManifestDelegateClasses(base)) {
    ALKHookWillConnect(cls);
    ALKHookOpenURL(cls, NO);
    ALKHookContinue(cls, NO);
  }
}

@end
