LetsMove
========

A library that prompts users to move a running macOS application to the Applications folder.

![Screenshot](http://i.imgur.com/euTRZiI.png)

[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)


Requirements
------------
Builds and runs on macOS 10.13 or higher. Requires Xcode 15 or later to build. 
Does NOT support sandboxed applications.


Usage
-----

Add this Swift package to your project.
Then, in your application delegate:

```swift
import LetsMove

func applicationWillFinishLaunching(_ notification: Notification) {
    LetsMove.moveToApplicationsFolderIfNecessary()
}
```

License
-------
Public domain



Version History
---------------

* Unreleased
	- Removed AppleScript Trash workaround
	- Removed privileged installer
	- Skip alert if won’t be able to move

* 2.0.0
	- Migrated project to Swift Package Manager
	- Removed legacy Xcode project, CocoaPods, and Carthage support

* 1.25
	- Migrate localization strings to a string catalog (requires Xcode 15)
	- Add Greek and Vietnamese localizations
	- Raise minimum deployment target to macOS 10.11
	- Use ARC and modern Objective-C syntax

* 1.24
	- Add PFMoveIsInProgress function

* 1.23
	- Make usable for Electron based apps or other apps that do not have access to the main thread dispatch queue
	- Update Russian localization

* 1.22
	- Fix not deleting or trashing itself after copying to /Applications in macOS Sierra

* 1.20
	- Support for applications bundled inside another application
	- Brazilian Portuguese localization slightly updated

* 1.19
	- Slovak localization added

* 1.18
	- Catalan localization added

* 1.17
	- Traditional Chinese localization added

* 1.15
	- Swedish localization added

* 1.14
	- Hungarian, Serbian, Turkish, and Macedonian localizations added

* 1.13
	- Polish localization added

* 1.12
	- Minor adjustment to Dutch localization

* 1.11
	- Objective-C++ compatibility

* 1.9
	- Properly detect if the running app is in a disk image
	- Fixed a bug where if the app's name contained a quote, the app could not be moved
	- After a successful move, delete the application instead of moving it to the Trash

* 1.8
	- Added Korean localization

* 1.7.2
	- Fixed an exception that could happen

* 1.7
	- Only move to ~/Applications directory if an app is already in there

* 1.6.3
	- Added Simplified Chinese and European Portuguese localizations

* 1.6.2
	- Use a new method to check if an application is already running

* 1.6.1
	- Use exit(0) to terminate the app before relaunching instead of [NSApp terminate:]. We don't want applicationShouldTerminate or applicationWillTerminate NSApplication delegate methods to be called, possibly introducing side effects.

* 1.6
	- Resolve any aliases when finding the Applications directory

* 1.5
	- Don't prompt to move the application if it has "Applications" in its path somewhere

* 1.3
	- Fixed a rare bug in the shell script that checks to see if the app is already running
	- Clear quarantine flag after copying
	- Compile time option to show normal sized alert suppress checkbox button
	- German, Danish, and Norwegian localizations added

* 1.2
	- Copy application from disk image then unmount disk image
	- Spanish, French, Dutch, and Russian localizations

* 1.1
	- Prefers ~/Applications over /Applications if it exists
	- Escape key pushes the "Do Not Move" button


Code Contributors:
-------------
* Andy Kim
* John Brayton
* Chad Sellers
* Kevin LaCoste
* Rasmus Andersson
* Timothy J. Wood
* Matt Gallagher
* Whitney Young
* Nick Moore
* Nicholas Riley
* Matt Prowse
* Maxim Ananov
* Charlie Stigler


Translators:
------------
* Eita Hayashi (Japanese)
* Gleb M. Borisov, Maxim Ananov (Russian)
* Wouter Broekhof (Dutch)
* Rasmus Andersson / Spotify (French and Spanish)
* Markus Kirschner (German)
* Fredrik Nannestad (Danish)
* Georg Alexander Bøe (Norwegian)
* Marco Improda (Italian)
* Venj Chu (Simplified Chinese)
* Sérgio Miranda (European Portuguese)
* Victor Figueiredo and BR Lingo (Brazilian Portuguese)
* AppLingua (Korean)
* Czech X Team (Czech)
* Marek Telecki (Polish)
* Petar Vlahu (Macedonian)
* Václav Slavík (Hungarian, Serbian, and Turkish)
* Erik Vikström (Swedish)
* Inndy Lin (Traditional Chinese)
* aONe (Catalan)
* Marek Hrusovsky (Slovak)

 
