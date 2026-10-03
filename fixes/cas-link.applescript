-- Hands cas:// links from the Mac browser to the CAS launcher in the
-- FIFA 17 bottle. CAS finishes Discord sign-in through a cas:// link;
-- that scheme is registered only inside the bottle, so without this the
-- browser has nowhere to send it. Starting cas.exe with the link is enough:
-- CAS's single-instance plugin passes it to the window already open.
--
-- A template: setup.sh step 9c puts the CrossOver copy's wine and name, the
-- bottle's name and the folder it is in where @WINE@, @APPNAME@, @BOTTLE@
-- and @BOTTLE_PATH@ stand, compiles it with osacompile into
-- ~/Applications/CAS Link (CrossOver).app, and only then edits the
-- Info.plist, because osacompile writes a fresh one.
on open location theURL
	set cx to "@WINE@"
	set bottleName to "@BOTTLE@"
	set bottlePath to "@BOTTLE_PATH@"
	set casExe to "C:\\users\\crossover\\AppData\\Local\\CAS\\cas.exe"
	-- Log the link's shape (query values dropped: they are one-time codes).
	do shell script "printf '%s %s\\n' \"$(date '+%F %T')\" \"$(printf %s " & quoted form of theURL & " | sed -E 's/=[^&]*/=…/g')\" >> ~/Library/Logs/cas-link.log"
	do shell script "CX_BOTTLE_PATH=" & quoted form of bottlePath & " CX_BOTTLE=" & quoted form of bottleName & " " & quoted form of cx & " " & quoted form of casExe & " " & quoted form of theURL & " >/dev/null 2>&1 &"
end open location

on run
	display dialog "This app passes cas:// sign-in links to CAS in @APPNAME@ (bottle @BOTTLE@). It has nothing to do on its own." buttons {"OK"} default button 1
end run
