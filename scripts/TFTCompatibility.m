#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <string.h>

static id send_id(id receiver, const char *selector)
{
    return ((id (*)(id, SEL))objc_msgSend)(receiver, sel_registerName(selector));
}

static CGPoint send_point(id receiver, const char *selector)
{
    return ((CGPoint (*)(id, SEL))objc_msgSend)(receiver, sel_registerName(selector));
}

static CGRect send_rect(id receiver, const char *selector)
{
    return ((CGRect (*)(id, SEL))objc_msgSend)(receiver, sel_registerName(selector));
}

static IMP original_construct_bundle_url;
static IMP original_load_file_url;
static IMP original_navigation_policy;
static IMP original_wkwebview_init;
static IMP original_application_send_event;
static NSBundle *riot_framework_bundle;
static NSInteger mouse_touch_id = -1;
static id mouse_touch_window;
static id mouse_touch_view;
static CGPoint mouse_touch_point;

@protocol TFTURLSchemeTask <NSObject>
- (NSURLRequest *)request;
- (void)didReceiveResponse:(NSURLResponse *)response;
- (void)didReceiveData:(NSData *)data;
- (void)didFinish;
- (void)didFailWithError:(NSError *)error;
@end

@interface TFTResourceSchemeHandler : NSObject
@end

static NSString *mime_type_for_path(NSString *path)
{
    NSString *extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"html"]) return @"text/html";
    if ([extension isEqualToString:@"js"]) return @"text/javascript";
    if ([extension isEqualToString:@"css"]) return @"text/css";
    if ([extension isEqualToString:@"json"]) return @"application/json";
    if ([extension isEqualToString:@"png"]) return @"image/png";
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([extension isEqualToString:@"svg"]) return @"image/svg+xml";
    if ([extension isEqualToString:@"woff2"]) return @"font/woff2";
    if ([extension isEqualToString:@"woff"]) return @"font/woff";
    return @"application/octet-stream";
}

@implementation TFTResourceSchemeHandler

- (void)webView:(id)webView startURLSchemeTask:(id<TFTURLSchemeTask>)task
{
    NSURL *url = task.request.URL;
    NSString *bundle_name = url.host;
    NSString *relative_path = [url.path stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    BOOL allowed_bundle = [bundle_name isEqualToString:@"platform-ui"] ||
        [bundle_name isEqualToString:@"rso-mobile-ui"];
    if (!allowed_bundle || relative_path.length == 0 ||
        [relative_path containsString:@".."] || [relative_path hasPrefix:@"/"]) {
        [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                   code:NSURLErrorFileDoesNotExist
                                               userInfo:nil]];
        return;
    }

    NSURL *root = [riot_framework_bundle URLForResource:bundle_name withExtension:@"bundle"];
    NSString *root_path = root.path.stringByStandardizingPath;
    NSString *file_path = [[root_path stringByAppendingPathComponent:relative_path]
        stringByStandardizingPath];
    NSString *required_prefix = [root_path stringByAppendingString:@"/"];
    NSData *body = root_path && [file_path hasPrefix:required_prefix]
        ? [NSData dataWithContentsOfFile:file_path] : nil;
    if (!body) {
        [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                   code:NSURLErrorFileDoesNotExist
                                               userInfo:nil]];
        return;
    }

    NSString *mime_type = mime_type_for_path(file_path);
    BOOL is_text = [mime_type hasPrefix:@"text/"] ||
        [mime_type isEqualToString:@"application/json"] ||
        [mime_type isEqualToString:@"image/svg+xml"];
    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:url
                                                       MIMEType:mime_type
                                          expectedContentLength:(NSInteger)body.length
                                               textEncodingName:is_text ? @"utf-8" : nil];
    [task didReceiveResponse:response];
    [task didReceiveData:body];
    [task didFinish];
}

- (void)webView:(id)webView stopURLSchemeTask:(id<TFTURLSchemeTask>)task
{
}

@end


static TFTResourceSchemeHandler *resource_scheme_handler;

static BOOL use_file_authentication_origin(void)
{
    NSString *value = NSProcessInfo.processInfo.environment[@"MACTICIAN_TFT_AUTH_BOOTSTRAP"];
    return value.boolValue;
}

static id wkwebview_init_with_configuration(id receiver, SEL selector, CGRect frame,
                                            id configuration)
{
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        configuration, sel_registerName("setURLSchemeHandler:forURLScheme:"),
        resource_scheme_handler, @"mactician");
    id (*original)(id, SEL, CGRect, id) = (void *)original_wkwebview_init;
    id web_view = original(receiver, selector, frame, configuration);
    NSString *user_agent = @"Mozilla/5.0 (iPad; CPU OS 26_6 like Mac OS X) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
    ((void (*)(id, SEL, id))objc_msgSend)(web_view,
        sel_registerName("setCustomUserAgent:"), user_agent);
    return web_view;
}

static id construct_bundle_url_fixed(id receiver, SEL selector, NSURL *url, NSString *bundle_id)
{
    id (*original)(id, SEL, id, id) = (void *)original_construct_bundle_url;
    NSURL *result = original(receiver, selector, url, bundle_id);
    if (use_file_authentication_origin() || !result.isFileURL) return result;

    NSURLComponents *source = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"mactician";
    components.host = [bundle_id stringByDeletingPathExtension];
    components.path = [NSString stringWithFormat:@"/%@", url.lastPathComponent];
    components.percentEncodedQuery = source.percentEncodedQuery;
    components.percentEncodedFragment = source.percentEncodedFragment;
    return components.URL;
}

static void load_file_url_fixed(id receiver, SEL selector, NSURL *url)
{
    if (use_file_authentication_origin() && url.isFileURL) {
        NSString *bundle_name = [url.path containsString:@"rso-mobile-ui.bundle"]
            ? @"rso-mobile-ui" : @"platform-ui";
        NSURL *bundle_root = [riot_framework_bundle URLForResource:bundle_name
                                                      withExtension:@"bundle"];
        NSURL *document_url = [bundle_root URLByAppendingPathComponent:url.lastPathComponent];
        NSString *html = [NSString stringWithContentsOfURL:document_url
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if (html) {
            NSURLComponents *source = [NSURLComponents componentsWithURL:url
                                                 resolvingAgainstBaseURL:NO];
            NSURLComponents *document = [NSURLComponents componentsWithURL:document_url
                                                   resolvingAgainstBaseURL:NO];
            document.percentEncodedQuery = source.percentEncodedQuery;
            document.percentEncodedFragment = source.percentEncodedFragment;
            NSString *base = [NSString stringWithFormat:
                @"<base href=\"mactician://%@/\">", bundle_name];
            NSRange head = [html rangeOfString:@"<head>" options:NSCaseInsensitiveSearch];
            if (head.location != NSNotFound) {
                html = [html stringByReplacingCharactersInRange:
                    NSMakeRange(NSMaxRange(head), 0) withString:base];
            } else {
                html = [base stringByAppendingString:html];
            }

            id web_view = send_id(receiver, "webView");
            ((id (*)(id, SEL, id, id))objc_msgSend)(web_view,
                sel_registerName("loadHTMLString:baseURL:"), html, document.URL);
            return;
        }
    }
    if ([url.scheme isEqualToString:@"mactician"]) {
        id web_view = send_id(receiver, "webView");
        NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                            timeoutInterval:30.0];
        ((id (*)(id, SEL, id))objc_msgSend)(web_view, sel_registerName("loadRequest:"), request);
        return;
    }
    void (*original)(id, SEL, id) = (void *)original_load_file_url;
    original(receiver, selector, url);
}

static void decide_navigation_policy(id receiver, SEL selector, id web_view,
                                     id navigation_action, void (^decision_handler)(NSInteger))
{
    NSURLRequest *request = send_id(navigation_action, "request");
    if ([request.URL.scheme isEqualToString:@"mactician"]) {
        decision_handler(1);
        return;
    }
    void (*original)(id, SEL, id, id, id) = (void *)original_navigation_policy;
    original(receiver, selector, web_view, navigation_action, decision_handler);
}

static void install_webview_compatibility(void)
{
    riot_framework_bundle = [NSBundle bundleForClass:NSClassFromString(@"PlatformUIWebViewController")];
    resource_scheme_handler = [TFTResourceSchemeHandler new];

    Method init_method = class_getInstanceMethod(NSClassFromString(@"WKWebView"),
                                                  sel_registerName("initWithFrame:configuration:"));
    if (init_method) {
        original_wkwebview_init = method_getImplementation(init_method);
        method_setImplementation(init_method, (IMP)wkwebview_init_with_configuration);
    }

    Class controller = NSClassFromString(@"PlatformUIWebViewController");
    Method construct_method = class_getClassMethod(controller,
        sel_registerName("constructBundleUrl:bundleId:"));
    if (construct_method) {
        original_construct_bundle_url = method_getImplementation(construct_method);
        method_setImplementation(construct_method, (IMP)construct_bundle_url_fixed);
    }

    Class platform_web_view = NSClassFromString(@"PlatformUIWebView");
    Method load_method = class_getInstanceMethod(platform_web_view, sel_registerName("loadFileURL:"));
    if (load_method) {
        original_load_file_url = method_getImplementation(load_method);
        method_setImplementation(load_method, (IMP)load_file_url_fixed);
    }

    Method policy_method = class_getInstanceMethod(platform_web_view,
        sel_registerName("webView:decidePolicyForNavigationAction:decisionHandler:"));
    if (policy_method) {
        original_navigation_policy = method_getImplementation(policy_method);
        method_setImplementation(policy_method, (IMP)decide_navigation_policy);
    }

    os_log(OS_LOG_DEFAULT, "Mactician TFT WebKit compatibility enabled");
}

static NSInteger send_touch(id touch_class, NSInteger touch_id, id window, id view,
                            CGPoint point, NSInteger phase)
{
    SEL selector = sel_registerName("fakeTouchId:AtPoint:withTouchPhase:inWindow:onView:");
    return ((NSInteger (*)(id, SEL, NSInteger, CGPoint, NSInteger, id, id))objc_msgSend)(
        touch_class, selector, touch_id, point, phase, window, view);
}

static BOOL event_mouse_point(id event, CGPoint *result, id *window, id *view)
{
    id application = send_id(NSClassFromString(@"UIApplication"), "sharedApplication");
    id key_window = send_id(application, "keyWindow");
    if (!key_window) return NO;

    id root_view_controller = send_id(key_window, "rootViewController");
    id root_view = send_id(root_view_controller, "view");
    CGRect view_rect = send_rect(root_view, "bounds");
    id native_window = send_id(event, "window");
    id content_view = send_id(native_window, "contentView");
    CGRect content_rect = send_rect(content_view, "bounds");
    if (!native_window || content_rect.size.width < 1 || content_rect.size.height < 1) return NO;

    CGPoint point = send_point(event, "locationInWindow");
    point = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(
        content_view, sel_registerName("convertPoint:fromView:"), point, nil);
    if (!CGRectContainsPoint(content_rect, point)) return NO;
    point.x *= view_rect.size.width / content_rect.size.width;
    point.y = view_rect.size.height - point.y * view_rect.size.height / content_rect.size.height;
    if (!CGRectContainsPoint(view_rect, point)) return NO;

    id target_view = ((id (*)(id, SEL, CGPoint, id))objc_msgSend)(
        key_window, sel_registerName("hitTest:withEvent:"), point, nil);
    *result = point;
    *window = key_window;
    *view = target_view ?: root_view;
    return YES;
}

static void handle_native_mouse_event(id event)
{
    NSInteger event_type = ((NSInteger (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("type"));
    BOOL pressed = event_type == 1;
    if (!pressed && event_type != 2) return;

    CGPoint point;
    id window;
    id view;
    BOOL has_point = event_mouse_point(event, &point, &window, &view);
    if (!has_point && (pressed || mouse_touch_id < 0)) return;
    if (!has_point) point = mouse_touch_point;

    id touch_class = NSClassFromString(@"PTFakeMetaTouch");
    if (pressed) {
        if (mouse_touch_id >= 0) return;
        mouse_touch_window = window;
        mouse_touch_view = view;
        mouse_touch_point = point;
        mouse_touch_id = send_touch(touch_class, -1, window, view, point, 0);
    } else if (mouse_touch_id >= 0) {
        mouse_touch_id = send_touch(touch_class, mouse_touch_id,
                                    mouse_touch_window, mouse_touch_view, point, 3);
        mouse_touch_window = nil;
        mouse_touch_view = nil;
    }
}

static void application_send_event(id receiver, SEL selector, id event)
{
    handle_native_mouse_event(event);
    ((void (*)(id, SEL, id))original_application_send_event)(receiver, selector, event);
}

static void install_mouse_touch_bridge(void)
{
    if (!NSClassFromString(@"PTFakeMetaTouch")) {
        NSLog(@"Mactician TFT: PTFakeMetaTouch is unavailable");
        return;
    }
    id native_application = send_id(NSClassFromString(@"NSApplication"), "sharedApplication");
    Method send_event = class_getInstanceMethod(object_getClass(native_application),
                                                 sel_registerName("sendEvent:"));
    if (!send_event) {
        NSLog(@"Mactician TFT: NSApplication sendEvent is unavailable");
        return;
    }
    original_application_send_event = method_getImplementation(send_event);
    method_setImplementation(send_event, (IMP)application_send_event);
    NSLog(@"Mactician TFT mouse-to-touch bridge enabled");
}

static IMP previous_symbol_named(IMP start, const char *required_name)
{
    Dl_info origin = {0};
    if (!start || !dladdr((void *)start, &origin) || !origin.dli_fname) return NULL;

    uintptr_t origin_address = (uintptr_t)start;
    uintptr_t cursor = origin_address;
    const uintptr_t maximum_distance = 4 * 1024 * 1024;
    for (NSUInteger index = 0; index < 100000 && cursor >= 4; index++) {
        Dl_info candidate = {0};
        if (!dladdr((void *)(cursor - 4), &candidate) || !candidate.dli_saddr) break;

        uintptr_t candidate_address = (uintptr_t)candidate.dli_saddr;
        if (candidate_address >= cursor || origin_address - candidate_address > maximum_distance) {
            break;
        }
        if (candidate.dli_fname && strcmp(candidate.dli_fname, origin.dli_fname) == 0 &&
            candidate.dli_sname && strcmp(candidate.dli_sname, required_name) == 0) {
            return (IMP)candidate_address;
        }
        cursor = candidate_address;
    }
    return NULL;
}

static void repair_playtools_view_swizzle(void)
{
    Class view_controller = NSClassFromString(@"UIViewController");
    Method view_method = class_getInstanceMethod(view_controller, sel_registerName("view"));
    Method coder_method = class_getInstanceMethod(view_controller,
                                                   sel_registerName("initWithCoder:"));
    if (!view_method || !coder_method) return;

    IMP view_implementation = method_getImplementation(view_method);
    IMP coder_implementation = method_getImplementation(coder_method);
    Dl_info current = {0};
    BOOL is_coder_implementation = view_implementation == coder_implementation;
    if (dladdr((void *)view_implementation, &current) && current.dli_sname) {
        is_coder_implementation = is_coder_implementation ||
            strcmp(current.dli_sname, "-[UIViewController initWithCoder:]") == 0;
    }
    if (!is_coder_implementation) return;

    IMP expected = previous_symbol_named(view_implementation, "-[UIViewController view]");
    if (!expected) {
        NSLog(@"Mactician TFT: UIViewController.view repair target was not found");
        return;
    }

    method_setImplementation(view_method, expected);
    if (method_getImplementation(view_method) == expected) {
        NSLog(@"Mactician TFT: repaired PlayTools UIViewController.view swizzle");
    }
}

static void initialize_tft_compatibility(void)
{
    repair_playtools_view_swizzle();
    install_webview_compatibility();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        install_mouse_touch_bridge();
    });
}

__attribute__((used, section("__DATA,__mod_init_func")))
static void (*tft_compatibility_initializer)(void) = initialize_tft_compatibility;
