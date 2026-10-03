-- Trigger: AppleScript. Run with:  osascript handoff.applescript [contract]
-- Uses the URL scheme (no Automation permission needed to script TerrierGPTMenu), then reads
-- the result from latest.json.
on run argv
	set contractQuery to ""
	if (count of argv) > 0 then set contractQuery to "?contract=" & item 1 of argv
	set latestPath to (POSIX path of (path to application support folder from user domain)) & "TerrierGPTMenu/handoffs/latest.json"
	set startStamp to do shell script "stat -f %m " & quoted form of latestPath & " 2>/dev/null || echo 0"
	delay 1
	open location "terriergpt://handoff" & contractQuery
	repeat 30 times
		delay 0.5
		set stamp to do shell script "stat -f %m " & quoted form of latestPath & " 2>/dev/null || echo 0"
		if (stamp as integer) > (startStamp as integer) then return (do shell script "cat " & quoted form of latestPath)
	end repeat
	error "No new handoff after 15s — check the toast in the TerrierGPT panel."
end run
