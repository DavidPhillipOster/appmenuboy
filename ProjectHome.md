When OS X 10.5.0 (Leopard) changed the way that folders are represented in the Dock, I lost a handy start menu made by dragging the Applications folder to the end of the dock.

Under 10.6 and later, you must Control-Click to see the AppMenuBoy dock menu.

[AppMenuBoy](http://appmenuboy.googlecode.com/svn/html/AppMenuBoy.zip) is a small Cocoa application that creates a hierarchical menu, in the dock, and when it is the frontmost app, in the menu bar, of your apps. It only shows apps. If a folder has a single app, it hoists the app up, so no subfolders of exactly one app.

[Download AppMenuBoy](http://appmenuboy.googlecode.com/svn/html/AppMenuBoy.zip)

Version 1.0.4 adds:
  * As the directories change, AppMenuBoy automatically tracks those changes.
  * AppMenuBoy now uses the localized name of Apps and folders, not the hidden file name.
  * AppMenuBoy now sorts its menu (since localization can change the order.)
  * Now has a preference to skip folders with parenthesized names. Example: (OldStuff)

Version 1.0.7 adds:
  * Skips the {GUID} names that Adobe uninstallers generates.
  * Under OS X 10.7 (Lion) skips Carbon apps.