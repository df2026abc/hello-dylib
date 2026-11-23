#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

static void dd_show(NSString* text) {
  UIApplication* app = UIApplication.sharedApplication;
  UIWindow* win = app.keyWindow;
  if (!win) { for (UIWindow* w in app.windows) { if (!w.hidden) { win = w; break; } } }
  if (!win) return;
  UITextView* tv = [[UITextView alloc] initWithFrame:win.bounds];
  tv.text = text;
  tv.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0];
  tv.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.85];
  tv.editable = NO;
  tv.font = [UIFont fontWithName:@"Menlo" size:11];
  [win addSubview:tv];
}

__attribute__((constructor))
static void dd_init(void) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    dd_show(@"dylib loaded OK\n注入链路通了");
  });
}
