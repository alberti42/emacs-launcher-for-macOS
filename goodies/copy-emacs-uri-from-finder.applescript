use AppleScript version "2.4" -- Yosemite (10.10) or later
use framework "Foundation"
use scripting additions

-- Copy an `emacs://file/<path>` URL for each file selected in Finder to the
-- clipboard (one per line).  Clicking such a URL opens the file in Emacs via the
-- Emacs Launcher app.
--
-- The path is percent-encoded — spaces, `+`, `:` and other specials are escaped —
-- so a literal `+` in a file name is never confused with the `+LINE:COLUMN`
-- position delimiter the scheme uses.  (Finder has no notion of a cursor position,
-- so these URLs carry no +LINE:COLUMN; the .el companion adds one for the buffer
-- at point.)
--
-- Handy as a Shortcuts / Automator "Quick Action" bound to a hotkey, or run
-- straight from Script Editor.

-- URL scheme + host registered by Emacs Launcher.  Change here if you renamed it.
property kPrefix : "emacs://file"

-- Percent-encode a POSIX path, keeping "/" as separators but escaping "+", ":",
-- spaces and the rest.
on encodeURIPath(posixPath)
	set ns to current application's NSString's stringWithString:posixPath
	set allowed to (current application's NSCharacterSet's URLPathAllowedCharacterSet)'s mutableCopy()
	allowed's removeCharactersInString:"+:"
	return (ns's stringByAddingPercentEncodingWithAllowedCharacters:allowed) as text
end encodeURIPath

on selectedFinderURIs()
	tell application "Finder"
		set theSelection to selection
	end tell
	set theURIs to current application's NSMutableArray's array()
	repeat with anItem in theSelection
		set p to POSIX path of (anItem as alias)
		(theURIs's addObject:(kPrefix & my encodeURIPath(p)))
	end repeat
	return (theURIs's componentsJoinedByString:linefeed) as text
end selectedFinderURIs

set theURIs to selectedFinderURIs()

-- Put them on the clipboard.
set pb to current application's NSPasteboard's generalPasteboard()
pb's clearContents()
pb's setString:theURIs forType:(current application's NSPasteboardTypeString)

return theURIs
