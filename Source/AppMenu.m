//
//  AppMenu.m
//  AppMenu
//
//  Created by David Oster on 1/20/08.
//  Copyright 2008-2009 Google Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not
//  use this file except in compliance with the License.  You may obtain a copy
//  of the License at
// 
//  http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
//  License for the specific language governing permissions and limitations under
//  the License.
//
// Purpose: in OS X 10.4, you could drag the Applications folder in Finder to
//    the Dock to get a poor man's "Start" menu. 
//    This function is broken in OS X 10.5.0. This app has a dock menu that shows
//    your applications. It also puts a copy in the menu bar, with small icons.
//
//
// Theory of operation:
//   applicationDidFinishLaunching: calls rebuildMenus, which:
//    * discards the contents of the array of KQueue listeners.
//    * rebuilds the hierarchical menu of apps in the menu bar.
//      (which, as a side-effect, rebuilds the array of KQueue listeners)
//    * copies that menu as the dock menu.
//  
// - (void)buildTree:(NSString *)path intoMenu:(NSMenu *)menu depth:(int)depth;
//   does the actual work of building a directory into a menu.
// It loops over all the files in the directory, for each file, categorizing, 
//    then dispatching to a handler.
//
// There are three handlers, each making a menu item:
// - (void)appBundle:(NSString *)file path:(NSString *)path into:(NSMutableArray *)items;
// - (void)carbonApp:(NSString *)file path:(NSString *)path into:(NSMutableArray *)items;
//
// Makes a sub menu menu item for following subfolders.
// - (void)subDir:(NSString *)file path:(NSString *)path into:(NSMutableArray *)items depth:(int)depth;
//
// The O.S. handles hard links and soft links automatically, but Finder Alias
//    Files require us to do some work. 
//
// The "depth" parameter artificially restricts the submenu tree to being at 
//    most N deep.

// DONE:
// * icon for this app.
// * If a subfolder contains only one app, then replace the subfolder by the app.
// * icons with sub menus
// * treat non-app subfolders as hierarchical menus. restrict depths
// * handle Finder Alias files.
// * when clicked, tell application "Finder" to open path
// * put copy of app menu on main menu bar
// 1.0.1 12/12/07
// * folder icons.
// * File menu removed
//  6/16/08
// * Changed format of Interface Builder file for also building on Tiger.
// 1.0.2 8/10/09
// * Listens for directory changes, and rebuild the menu automatically.
// * Uses the localized name from the en.lproj/InfoPlist.strings file.
// * Uses the localized name for folders.
// * Reports its version in the Finder about box.
// * Refactored to build a NSMutableArray, sort, build the menu from that
// * Added a BOOL preference, "ignoringParens", to skip parenthesized folders.
// 1.0.3 8/14/09
// * Refactored to do its work in a thread so U.I. doesn't block.
// * Says "Working…" while its working.
// * Add a BOOL preference dialog to set the ignoringParens preference.
// 1.0.4 8/23/09
// Well, that was a disaster. Now 1.0.3 was hanging often. Rewrite. Remove Threads.
// Since everything is on the main loop, remove locks.
// Add the cheesy yield method to keep the app responsive.
// 1.0.6 11/14/2010
// * Added a preference to point at an alternate root directory
// * must rebuild menu when the alternate root directory changes
// 1.0.7 12/22/2011
// * Hide adobe uninstallers which have uninformative GUID names
// * Omit Carbon Apps in OS X Lion and newer.
// BUG: PowerPC apps should also be omitted on Lion.
// BUG: changes to the menu don't seem to be tracked correctly, particulary when
//   using an alternate root.
// TODO: make two passes over the directory tree, one to get app names, a second
// pass to get the icons. That should make getting the initial menu much faster.
// 1.0.8 4/29/2018
// Allow dragging a folder from the Finder into the preferences text box.
// Error message if text in the preferences text box isn't a folder.
// 1.0.9 11/11/2019 In Catalina, some the apps moved from /Applications to /System/Applications
// 1.0.10 11/14/2020 In Big Sur, found a small memory leak.
// 1.0.11 11/24/2020 macOS V 11. fixed: dock menu was empty initially after boot.
// 1.0.12 Since Catalina there are two utilities menus.
// 1.0.13 12/21/2021 Monterey: merge the two utilities menus. min OS now 10.11, fix all warnings
// TODO: Add error message if root directory set in preferences has no contents.
// TODO: Use FSEvents instead of GTMFileSystemKQueue https://developer.apple.com/documentation/coreservices/file_system_events?language=objc

#import "AppMenu.h"
#import "GTMFileSystemKQueue.h" // see http://code.google.com/mac/

// usage:   DEBUGBLOCK{ NSLog(@"Debugging only code block here."); }
#if DEBUG
#define DEBUGBLOCK if(1)
#else
#define DEBUGBLOCK if(0)
#endif

typedef enum {
  kGoodKind,
  kNonexistentKind,
  kEmptyKind,
} PathKindEnum;

@interface NSArray(AppMenu)
- (NSMenuItem *)firstItemOfTitle:(NSString *)name;
@end
@implementation NSArray(AppMenu)
- (NSMenuItem *)firstItemOfTitle:(NSString *)name {
  for (NSMenuItem *item in self) {
    if ([[item title] isEqual:name]) {
      return item;
    }
  }
  return nil;
}
@end

@interface NSMenu(AppMenu)

- (void)resetFromArray:(NSArray *)array;

@end

@implementation NSMenu(AppMenu)

- (void)resetFromArray:(NSArray *)array {
  [self removeAllItems];
  NSEnumerator *items = [array objectEnumerator];
  NSMenuItem *item;
  while (nil != (item = [items nextObject])) {
    [self addItem:item];
  }
}

@end

@interface NSMenuItem(AppMenu)

- (NSComparisonResult)compareAsFinder:(NSMenuItem *)other;

@end

@implementation NSMenuItem(AppMenu)

- (NSComparisonResult)compareAsFinder:(NSMenuItem *)other {
  return [[self title] localizedCaseInsensitiveCompare:[other title]];
}

@end

@interface NSURL(AppMenu)

- (NSString *)app_displayName;

@end

@implementation NSURL(AppMenu)

- (NSString *)app_displayName {
  NSString *result = nil;
  NSError *error;
  if (![self getResourceValue:&result forKey:NSURLLocalizedNameKey error:&error]) {
    // NSLog(@"%@", error);
  }
  return result;
}

@end

typedef enum  {
  kIgnore,
  kAppBundle,
  kSubDir,
  kCarbonApp
} FileCategoryEnum;

@interface AppMenu(ForwardDeclarations)

// main routine of this program: loop over a directory building menus
- (void)buildTree:(NSString *)path into:(NSMutableArray *)items depth:(int)depth shouldListen:(BOOL)shouldListen;
- (void)buildTree:(NSString *)path intoMenu:(NSMenu *)menu depth:(int)depth shouldListen:(BOOL)shouldListen;

- (void)rebuildMenus;
- (void)scheduleCheckForMore;
- (void)showIgnoringParentheses;

- (BOOL)testAndClearMoreToDo;
- (void)setMoreToDo:(BOOL)moreToDo;

- (GTMFileSystemKQueue *)kqueueForKey:(NSString *)key;
- (void)setKQueue:(GTMFileSystemKQueue *)kqueue forKey:(NSString *)key;
- (void)removeKQueueForKey:(NSString *)key;

- (NSString *)rootPath;

- (void)yield;
@end

@implementation AppMenu {
  IBOutlet NSMenu *dockMenu_;
  IBOutlet NSWindow *preferencesWindow_;
  IBOutlet NSControl *ignoringParentheses_;
  IBOutlet NSTextField *rootField_;
  IBOutlet NSTextField *messageField_;
  NSString *messageDefault_;

  // builder thread only
  NSMenu *appMenu_;
  BOOL isIgnoringParentheses_;

  // Maps paths to kqueues
  NSMutableDictionary *kqueues_;

  // builder state machine reentrancy guard
  BOOL isRebuilding_;

  // between KQueue callback, builder
  BOOL moreToDo_;

  BOOL isTerminating_;

  NSTimeInterval timeOfLastYield_;
}


- (NSMenu *)constructWorkingMenu {
  NSString *workingTitle = NSLocalizedString(@"Working", @"");
  NSMenuItem *workingItem = [[[NSMenuItem alloc] initWithTitle:workingTitle action:nil keyEquivalent:@""] autorelease];
  NSString *menuTitle = NSLocalizedString(@"Apps", @"");
  NSMenu *workingMenu = [[[NSMenu alloc] initWithTitle:menuTitle] autorelease];
  [workingMenu addItem:workingItem];
  return workingMenu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  appMenu_ = [[self constructWorkingMenu] retain];
  NSString *menuTitle = NSLocalizedString(@"Apps", @"");
  NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:menuTitle action:nil keyEquivalent:@""] autorelease];
  [item setSubmenu:appMenu_];
  [[NSApp mainMenu] addItem:item];
  if (nil == dockMenu_) {
    dockMenu_ = [[self constructWorkingMenu] retain];
  }
  kqueues_ = [[NSMutableDictionary alloc] init];
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc addObserver:self selector:@selector(textFieldChanged:) name:NSControlTextDidChangeNotification object:nil];
  [self rebuildMenus];
}

- (void)awakeFromNib {
  messageDefault_ = [[messageField_ stringValue] copy];
}

- (void)dealloc {
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc removeObserver:self];
  [appMenu_ release];
  [dockMenu_ release];
  [ignoringParentheses_ release];
  [kqueues_ release];
  [messageDefault_ release];
  [messageField_ release];
  [preferencesWindow_ release];
  [rootField_ release];
  [super dealloc];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  isTerminating_ = YES;
  if ([preferencesWindow_ isVisible]) {
    [preferencesWindow_ orderOut:self];
  }
  [[NSUserDefaults standardUserDefaults] synchronize];
}

// app will call this to get the dock menu.
- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
  return dockMenu_;
}

// Create a GTMFileSystemKQueue object for the path, and remember it in an array.
- (void)addKQueueForPath:(NSString *)fullPath {
  if (nil == [self kqueueForKey:fullPath]) {
    GTMFileSystemKQueue *kq = [[[GTMFileSystemKQueue alloc] 
        initWithPath:fullPath
           forEvents:kGTMFileSystemKQueueAllEvents
       acrossReplace:NO
              target:self
              action:@selector(fileSystemKQueue:events:)] autorelease];
    if (nil != kq && nil == [self kqueueForKey:[kq path]]) {
      [self setKQueue:kq forKey:[kq path]];
    }
  }
}

// Folder changed. Rebuild the menus in a worker thread.
- (void)fileSystemKQueue:(GTMFileSystemKQueue *)kq
                  events:(GTMFileSystemKQueueEvents)events {
  DEBUGBLOCK{ NSLog(@"%@ %d", kq, events); }
  if (events & (kGTMFileSystemKQueueRevokeEvent|kGTMFileSystemKQueueDeleteEvent|kGTMFileSystemKQueueRenameEvent)) {
    [self removeKQueueForKey:[kq path]];
  }
  [self rebuildMenus];
}

// helper routine: give each item a small icon for app at fullPath.
- (void)setImagePath:(NSString *)fullPath forItem:(NSMenuItem *)item {
  NSWorkspace *ws = [NSWorkspace sharedWorkspace];
  NSImage *image = [ws iconForFile:fullPath];
  if (image) {
    [image setSize:NSMakeSize(16,16)];  // makes it small
    [item setImage:image];
  }
}

#pragma mark -
// Build menu item for an ordinary OS X app.
// 
- (void)appBundle:(NSString *)file path:(NSString *)fullPath into:(NSMutableArray *)items {
  NSString *trimmedFile = nil;

  // Prefer the localized name from the Info.plist.
  if (nil == (trimmedFile = [[NSURL fileURLWithPath:fullPath] app_displayName])) {
    // Should never happen because Launch Services should already have looked up the correct name.
    NSRange matchRange = [file rangeOfString:@".app" options:NSCaseInsensitiveSearch|NSBackwardsSearch|NSAnchoredSearch];
    if (0 != matchRange.length) {
      trimmedFile = [file substringToIndex:matchRange.location];
    }
  }
  // Adobe likes to create uninstallers with uninformative GUID names. Skip them.
  if (!([trimmedFile hasPrefix:@"{"] && [trimmedFile hasSuffix:@"}"])) {
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:trimmedFile action:@selector(openAppItem:) keyEquivalent:@""] autorelease];
    [item setRepresentedObject:fullPath];
    [items addObject:item];
    [self setImagePath:fullPath forItem:item];
  }
}

// Build menu item for a subdirectory
- (void)subDir:(NSString *)file path:(NSString *)fullPath  into:(NSMutableArray *)items depth:(int)depth shouldListen:(BOOL)shouldListen {
  NSMenu *subMenu = [[[NSMenu alloc] initWithTitle:file] autorelease];
  if (depth < 6) {  // limit recursion depth.
    [self buildTree:fullPath intoMenu:subMenu depth:1+depth shouldListen:shouldListen];
  }
  if (0 < [subMenu numberOfItems]) {
    NSMenuItem *item = nil;
    if (1 == [subMenu numberOfItems]) {
      item = [subMenu itemAtIndex:0];
      [[item retain] autorelease];
      [subMenu removeItemAtIndex:0];
    } else {
      NSString *displayName = [[NSURL fileURLWithPath:fullPath] app_displayName];
      if (nil != displayName) {
        file = displayName;
      }
      item = [[[NSMenuItem alloc] initWithTitle:file action:@selector(openAppItem:) keyEquivalent:@""] autorelease];
      [item setRepresentedObject:fullPath];
      [item setSubmenu:subMenu];
      [self setImagePath:fullPath forItem:item];
    }
    [items addObject:item];
  }
}

// Build menu item for an all in one file GUI app.
- (void)carbonApp:(NSString *)file path:(NSString *)fullPath into:(NSMutableArray *)items {
  NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:file action:@selector(openAppItem:) keyEquivalent:@""] autorelease];
  [item setRepresentedObject:fullPath];
  [items addObject:item];
  [self setImagePath:fullPath forItem:item];
}
#pragma mark -

// What kind of file system object is this? returns enum.
- (FileCategoryEnum)categorizeFile:(NSString *)file path:(NSString *)fullPath {
  if (nil == file || [file hasPrefix:@"."]) {
    return kIgnore;
  }
  if (isIgnoringParentheses_ && [file hasPrefix:@"("] && [file hasSuffix:@")"]) {
    return kIgnore;
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL isDirectory = NO;
  if ([fm fileExistsAtPath:fullPath isDirectory:&isDirectory] && isDirectory) {
    NSString *trimmedFile = file;
    NSRange matchRange = [trimmedFile rangeOfString:@".app" options:NSCaseInsensitiveSearch|NSBackwardsSearch|NSAnchoredSearch];
    if (0 != matchRange.length) {
      return kAppBundle;
    }
    // A few early OS X apps don't end in a .app extension. Dig deeper for them.
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    if ([ws isFilePackageAtPath:fullPath]) {
      NSBundle *bundle = [NSBundle bundleWithPath:fullPath];
      NSDictionary *info = [bundle infoDictionary];
      if ([[info objectForKey:@"CFBundlePackageType"] isEqual:@"APPL"]) {
        return kAppBundle;
      }
    }
    return kSubDir;
  }
  return kIgnore;
}


// main routine of this program: loop over a directory building menu items into an array
- (void)buildTree:(NSString *)path into:(NSMutableArray *)items depth:(int)depth shouldListen:(BOOL)shouldListen {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;
  NSArray *files = [fm contentsOfDirectoryAtPath:path error:&error];
  NSEnumerator *fileEnumerator = [files objectEnumerator];
  NSString *file;
  while (nil != (file = [fileEnumerator nextObject])) {
    NSString *fullPath = [path stringByAppendingPathComponent:file];
//    if ([fullPath isAliasFile]) {
//      fullPath = [fullPath resolveAliasFile];
//    }
    switch ([self categorizeFile:file path:fullPath]) {
    case kAppBundle: [self appBundle:file path:fullPath into:items]; break;
    case kSubDir:    [self subDir:file path:fullPath into:items depth:depth + 1 shouldListen:shouldListen]; break;
    case kCarbonApp: [self carbonApp:file path:fullPath into:items];break;
    default:
    case kIgnore:    break;
    }
    [self yield];
  }
}

// loop over a directory building menu
- (void)buildTree:(NSString *)path intoMenu:(NSMenu *)menu depth:(int)depth shouldListen:(BOOL)shouldListen {
  if (shouldListen) {
    [self addKQueueForPath:path];
  }
  NSMutableArray *items = [NSMutableArray array];
  [self buildTree:path into:items depth:depth shouldListen:shouldListen];
  [items sortUsingSelector:@selector(compareAsFinder:)];
  [menu resetFromArray:items];
}

/*
 In macOS 10.15 (Catalina) Apple moved some apps into a second directory. This method takes a second, optional directory and merges both into a single menu.
 */
- (void)buildTree:(NSString *)path secondaryPath:(NSString *)path2 intoMenu:(NSMenu *)menu depth:(int)depth shouldListen:(BOOL)shouldListen {
  if (shouldListen) {
    [self addKQueueForPath:path];
    if (path2.length) {
      [self addKQueueForPath:path2];
    }
  }
  NSMutableArray *items = [NSMutableArray array];
  NSMenuItem *secondaryUtilities = nil;
  if (path2.length) {
    [self buildTree:path2 into:items depth:depth shouldListen:shouldListen];
    secondaryUtilities = [items firstItemOfTitle:@"Utilities"];
  }
  [self buildTree:path into:items depth:depth shouldListen:shouldListen];
  if (secondaryUtilities.submenu.itemArray.count) {
    NSUInteger secondaryIndex = NSNotFound;
    for (NSUInteger i = 0; i < items.count; ++i) {
      NSMenuItem *item = items[i];
      if (secondaryUtilities == item) {
        secondaryIndex = i;
      } else if ([item.title isEqual:@"Utilities"]) {
        NSMenu *subMenu = item.submenu;
        NSMutableArray *subUtils = [subMenu.itemArray mutableCopy];
        // We have to copy the items, because the originals are still in secondaryUtilities.
        for (NSMenuItem *item2 in secondaryUtilities.submenu.itemArray) {
          if ( ! [subUtils containsObject:item2]){
 // 9/06/2021 oster contains check needed to keep every item from appearing twice.
           [subUtils addObject:[[item2 copy] autorelease]];
          }
        }
        [subUtils sortUsingSelector:@selector(compareAsFinder:)];
        [item.submenu resetFromArray:subUtils];
        if (secondaryIndex != NSNotFound) {
          [items removeObjectAtIndex:secondaryIndex];
          secondaryIndex = NSNotFound;
        }
        break;
      }
    }
  }
  [items sortUsingSelector:@selector(compareAsFinder:)];
  [menu resetFromArray:items];
}

// Do the actual work of rebuilding the menus in a worker thread.
- (void)rebuildMenus {
  DEBUGBLOCK{ NSLog(@"rebuildMenus"); }
  isIgnoringParentheses_ = [[NSUserDefaults standardUserDefaults] boolForKey:@"ignoringParens"];
  if (!isRebuilding_) {
    isRebuilding_ = YES;
    NSString *rootPath = [self rootPath];
    NSString *secondaryPath = nil;
    if ([rootPath isEqual:@"/Applications"] || [rootPath isEqual:@"/Applications/"]) {
      secondaryPath = @"/System/Applications";
    }
    [self buildTree:rootPath secondaryPath:secondaryPath intoMenu:appMenu_ depth:0 shouldListen:YES];
    [self buildTree:rootPath secondaryPath:secondaryPath intoMenu:dockMenu_ depth:0 shouldListen:NO];
    isRebuilding_ = NO;
  }
  [self scheduleCheckForMore];
}

// Up in the main event loop, on the main thread, check if the KQueue fired while we were working.
- (void)scheduleCheckForMore {
  [self performSelector:@selector(checkForMore) withObject:nil afterDelay:0.25];
}

// if the KQueue fired while we were working, do it again.
- (void)checkForMore {
  if ([self testAndClearMoreToDo]) {
    [self rebuildMenus];
  }
}


#pragma mark -

- (void)openAppItem:(id)sender {
  NSWorkspace *ws = [NSWorkspace sharedWorkspace];
  NSString *path = [sender representedObject];
  if (path) {
    [ws openFile:path];
  }
}

- (IBAction)showPreferencesPanel:(id)sender {
  if ([preferencesWindow_ isVisible]) {
    [preferencesWindow_ orderOut:self];
  } else {
    [self showIgnoringParentheses];
    NSString *s = [[NSUserDefaults standardUserDefaults] stringForKey:@"rootPath"];
    if (nil == s) { s = @""; }
    [rootField_ setStringValue:s];
    [self validateRootField];
    [preferencesWindow_ makeKeyAndOrderFront:self];
  }
}

- (void)windowWillClose:(NSNotification *)notification {
  NSString *oldS = [[NSUserDefaults standardUserDefaults] stringForKey:@"rootPath"];
  NSString *s = [rootField_ stringValue];
  if (!([oldS isEqual:s] || ([oldS length] == 0 && [s length] == 0))) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([s length]) {
      [ud setObject:s forKey:@"rootPath"];
    } else {
      [ud removeObjectForKey:@"rootPath"];
    }
    [ud synchronize];
    if (!isTerminating_) {
      [self rebuildMenus];
    }
  }
}

- (void)textFieldChanged:(NSNotification *)notification {
  NSTextField *textField = (NSTextField *)[notification object];
  if (textField == rootField_) {
    [self validateRootField];
  }
}

- (NSColor *)redColor {
  return [NSColor colorWithRed:0xAA/255. green:0x0A/255. blue:0x12/255. alpha:1];
}

- (void)validateRootField {
  NSString *path = [rootField_ stringValue];
  switch ([self classifyPath:path]) {
    case kGoodKind:
      [messageField_ setStringValue:messageDefault_];
      [messageField_ setTextColor:[NSColor blackColor]];
      break;
    case kNonexistentKind:
      [messageField_ setTextColor:[self redColor]];
      [messageField_ setStringValue:NSLocalizedString(@"errNonexistent", 0)];
      break;
    case kEmptyKind:
      [messageField_ setTextColor:[self redColor]];
      [messageField_ setStringValue:NSLocalizedString(@"errEmpty", 0)];
      break;
  }
}

- (PathKindEnum)classifyPath:(NSString *)path {
  path = [path stringByExpandingTildeInPath];
  if ([path length] == 0) {
    return kGoodKind;
  } else {
    NSString *file = [path lastPathComponent];
//    if ([path isAliasFile]) {
//      path = [path resolveAliasFile];
//    }
    switch ([self categorizeFile:file path:path]) {
      case kSubDir:
        // TODO: check that the directory has app contents.
        return kGoodKind;
      default:
        return kNonexistentKind;
    }
  }
  return kNonexistentKind;
}


- (IBAction)toggleIgnoringParentheses:(id)sender {
  isIgnoringParentheses_ = !isIgnoringParentheses_;
  [[NSUserDefaults standardUserDefaults] setBool:isIgnoringParentheses_ forKey:@"ignoringParens"];
  [self rebuildMenus];
}

- (void)showIgnoringParentheses {
  isIgnoringParentheses_ = [[NSUserDefaults standardUserDefaults] boolForKey:@"ignoringParens"];
  [ignoringParentheses_ setIntValue:isIgnoringParentheses_];
}

- (NSString *)rootPath {
  NSString *rootPath = [[[NSUserDefaults standardUserDefaults] stringForKey:@"rootPath"] stringByExpandingTildeInPath];
  if (0 == [rootPath length]) {
    rootPath = @"/Applications";
  }
  return rootPath;
}

- (BOOL)testAndClearMoreToDo {
  BOOL moreToDo = moreToDo_;
  moreToDo_ = NO;
  return moreToDo;
}

- (void)setMoreToDo:(BOOL)moreToDo {
  moreToDo_ = moreToDo;
}


- (GTMFileSystemKQueue *)kqueueForKey:(NSString *)key {
  GTMFileSystemKQueue *kqueue = [kqueues_ objectForKey:key];
  return kqueue;
}

- (void)setKQueue:(GTMFileSystemKQueue *)kqueue forKey:(NSString *)key {
  [kqueues_ setObject:kqueue forKey:key];
}

- (void)removeKQueueForKey:(NSString *)key {
  [kqueues_ removeObjectForKey:key];
}

// To prevent the spinning pizza of unresponsiveness, spin the event loop at most 5 times a second.
- (void)yield {
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (0.2 < now - timeOfLastYield_) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    timeOfLastYield_ = [NSDate timeIntervalSinceReferenceDate];
  }
}


@end
// The following was documented as putting an icon in a dock menu item, but I couldn't get it to work:
//http://developer.apple.com/documentation/Carbon/Conceptual/customizing_docktile/tasks/chapter_3_section_5.html
//SetMenuItemIconHandle (myMenu,  // <- menu ref
//                        2,  // <- ones based index.
//                        kMenuIconResourceType,
//                        (Handle) CFSTR("mySpecialIcon.icns") ); // normally a partial path to a .icns file.
//example: (doesn't work)
//MenuRef menu = GetApplicationDockTileMenu();
//SetMenuItemIconHandle(menu,  // <- menu ref
//                        CountMenuItems(menu),  // <- ones based index.
//                        kMenuIconResourceType,
//                        (Handle) CFSTR("/Applications/Address Book.app/Contents/Resources/AddressBook.icns") ); 
