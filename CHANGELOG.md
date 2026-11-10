## CHANGELOG

# 1.5.1
- Support Ctrl/Cmd+V directly in any waypoint field, automatically distributing full /way commands, explicit map IDs, coordinates alone and decimal commas. No activation button is needed. Rename My zone to My position.
- Add right-click waypoint export with preselected text for Ctrl/Cmd+C, and brief zone-name feedback for map IDs.
- Normalize # prefixes in map IDs before passing numeric values to TomTom.

# 1.5
- Add a compact 300 × 350 Waypoint Manager with three visible rows, add/go/trash controls, saved drag-and-drop ordering, and route start/stop controls.
- Allow targets below the RXP entry so routes can wait for the guide step to complete before continuing.
- Automatically advance after removing the active target; add "Clear & RXP" to remove all targets and resume the current guide target.
- Add an optional draggable minimap launcher and manager settings for position locking and independent background/controls transparency.
- Initialize checkbox and slider values immediately and restore manager visibility across sessions. Toggle visibility through menus or the minimap button, without a close X or Escape closing.
- Keep the manager below normal interface windows and dialogs.
- Pause RXP arrow control while navigating to other TomTom waypoints and resume after all foreign targets are removed. Manual RXP resume actions preserve other targets.
- Detect deleted RXP waypoints even when the guide target has not changed.

# 1.3.3
- minor edit

# 1.3.2
- improved waypoint stability 

# 1.3.1
- improved waypoint clearing

# 1.3
- improved waypoint tracking
- added Optionsmenu
- added optional TomTom-Waypoints on Minimap and/or Worldmap

# 1.2.8
- Small changes to improve debugging on the developer side

# 1.2.7
- added loading message

# 1.2.6
- added a handler to run when you regain control after tax

# 1.2.5
- license update

# 1.2.4
- fix handling of unavailable waypoints

# 1.2.3
- add all active step waypoints to TomTom and stabilize arrow switching.

# 1.2.2
- improved TBC rapid waypoint switching.

# 1.2.1
- Add Logo

# 1.2
- TBC Compability

# 1.0.1
- minor cleanup

# 1.0

- Initial release.
- Disables RestedXP Guides waypoint arrow and uses TomTom Crazy Arrow instead.
- Creates and updates a TomTom waypoint based on RestedXP’s current arrow target.
- Adds `RXP Step N` titles on the TomTom waypoint when the step number is known.
- Removes experimental click/menu waypoint setting (not needed); adds `/rxptomtom clear`.
