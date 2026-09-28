#import <AppKit/AppKit.h>

// Private SPI for the experimental Guardian and explicit geometry trial.
@interface MLWindowSpace : NSObject
- (BOOL)attachWindows:(NSArray<NSWindow *> *)windows; // YES: requests issued, not server confirmation.
- (void)close;
@end
