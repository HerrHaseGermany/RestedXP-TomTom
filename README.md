# RestedXP-TomTom

Disables the built-in RestedXP Guides waypoint arrow and uses TomTom’s Crazy Arrow instead.

This addon does not modify RestedXP guide logic; it only changes how the “where do I go next?” arrow is displayed.

## Requirements

- **RestedXP Guides** (`RXPGuides`)
- **TomTom**

## What it does

- Forces RestedXP’s arrow to be disabled/hidden.
- Mirrors RestedXP’s current active waypoint target into a TomTom waypoint, so TomTom’s Crazy Arrow points to the same location.
- Keeps updating as RestedXP changes the active arrow target.
- Pauses RXP arrow control when another TomTom waypoint is selected. RXP target changes continue to be mirrored without taking over the arrow.
- Automatically resumes the current RXP target once all non-addon waypoints have been removed, after a short settling delay.
- Includes a Waypoint Manager with a configurable minimap launcher and an ordered route for regular TomTom targets.
- Minimap/worldmap pins for the RXP target are optional and can be enabled in the addon settings.

## What it does not do (yet)

- It does not rewrite or replace RestedXP steps.
- It does not try to perfectly replicate all RestedXP arrow edge cases (instances, special world positions, etc.).

## Installation

1. Ensure you have **TomTom** and **RestedXP Guides** installed and working.
2. Copy this folder to your WoW addons directory:
   - Classic Era example: `World of Warcraft/_classic_era_/Interface/AddOns/RestedXP-TomTom`
3. Restart WoW or run `/reload`.
4. In the AddOns list, enable:
   - `RXPGuides`
   - `TomTom`
   - `RestedXP-TomTom`

## Usage

- Start or load a RestedXP guide as normal.
- The RestedXP arrow should remain hidden/disabled.
- TomTom’s Crazy Arrow should point to the current RestedXP target.

If you want to verify it’s working:
- Change steps in the RestedXP guide; the TomTom arrow should “jump” to the new target.

### Slash command

- `/rxptomtom` prints whether TomTom and the RestedXP arrow frame are detected, plus basic info about the current RestedXP arrow target.
- `/rxptomtom debug` toggles debug logging (prints when a TomTom waypoint is set).
- `/rxptomtom clear` removes the currently created TomTom waypoint.
- `/rxptomtom manager` opens or closes the Waypoint Manager.
- `/rxptomtom options` opens the addon settings, including minimap button visibility.

If you manually delete the TomTom waypoint, the addon will recreate it automatically.

### Resume RXP navigation

Choose **Resume RXP navigation** in the Waypoint Manager, RestedXP menu or **RestedXP-TomTom** addon settings (`/rxptomtom options`) to switch the arrow back to the current RXP target immediately. This stops any running manager route. Other TomTom waypoints remain intact. Selecting a foreign waypoint again pauses RXP arrow control again.

Automatic resumption waits until **all** foreign waypoints are gone, including saved targets on other maps. This preserves other managers' opportunity to select their next target. If you keep waypoints for later, use the menu action to resume RXP manually. This is a conservative coexistence rule, not an integration with a particular waypoint manager or its route order.

### Waypoint Manager

- **Minimap button:** left-click opens/closes the manager, right-click resumes RXP, drag moves the button. Hide/show it in the addon settings. The launcher uses the LibDataBroker/LibDBIcon libraries supplied by TomTom; if those are unavailable, use the menu or slash command.
- **List:** includes current TomTom targets across all maps. **Go** selects a target; the **trash icon** deletes it from TomTom, including its saved copy. The RXP entry marks the guide's place in the sequence. RXP and corpse entries cannot themselves be removed or dragged.
- **Add:** enter a map ID, X/Y percentages and an optional title. **My zone** fills the player's map and coordinates. New targets are saved by TomTom, shown on both maps, and do not interrupt navigation.
- **Order:** drag ordinary waypoint rows to reorder them. A gold insertion line shows the drop position; dragging near the list edges scrolls longer routes. Dropping outside the list cancels. The order is saved and restored for matching targets after reload.
- **Compact window:** 300 × 350 pixels with three waypoint rows before scrolling. Map/X/Y fields share the first input row, with the title underneath. **Go** is disabled for the currently selected waypoint; hovering over Go shows the full title, map and coordinates.
- **Manager settings:** under **RestedXP-TomTom → Waypoint Manager** in addon settings (`/rxptomtom options`), set background transparency and controls transparency independently from 0–100%, lock the window position or toggle the minimap button. Background transparency affects the background and border; controls transparency affects text, buttons, inputs and the list. Saved checkbox/slider values are initialized before opening the settings. Changes apply immediately. Position locking still allows waypoint drag-and-drop.
- **After an RXP step:** drag targets **below the RXP entry**, then choose **Start route**. Targets above RXP run first; at RXP the route follows the guide until that step completes or guide progress moves past it. Then the targets below RXP run in order. Merely reaching the RXP coordinates, switching between targets within that step or briefly losing the arrow does not release the waiting targets. An unrelated guide switch stops the waiting route. Before/after placement is saved; a new route binds to the current RXP step when it reaches that entry.
- **Route:** **Start route** navigates from top to bottom. Reached targets are removed using TomTom's arrival distance (15 yards if unset or disabled), then the next target is activated. Removing the active target with its trash icon also advances automatically; removing an inactive target preserves current navigation. When the final active target is removed, RXP resumes. **Stop route** stops automatic advancement and keeps remaining targets. Selecting another target outside the route also stops advancement. Routes do not start automatically after reload, and arrival does not consume targets while on a taxi.
- **Clear & RXP:** stops the route, removes **all** TomTom waypoints across all maps (including saved copies), and recreates the current RXP target. The minimap right-click and existing RXP resume menu actions still preserve other targets.
- The RXP target continues to follow the guide and is never removed by route progression. After the final ordinary target is removed, RXP resumes. The manager remembers whether it is open across reloads/logins; toggle it through the menu, settings or minimap button. It has no close X and Escape does not hide it. Temporary UI hides do not change the saved preference. Hiding the window does not stop a running route; routes themselves still start manually after login.

## Notes on compatibility

- The addon relies on RestedXP’s internal `RXPG_ARROW.element` data structure to read the current arrow target.
  If RestedXP changes that internal representation in a future update, this addon may need updates.
- If TomTom is not loaded, the addon does nothing.

## Troubleshooting

**TomTom arrow doesn’t move**
- Confirm `TomTom` is enabled and its arrow is enabled in TomTom settings.
- Confirm RestedXP is actually producing an arrow target (some steps are text-only).
- Try `/reload`.

**RestedXP arrow still shows**
- Ensure `RestedXP-TomTom` is enabled.
- Check RestedXP settings for arrow-related options; this addon sets `RXPGuides.settings.profile.disableArrow = true` at runtime.
- Try disabling any other addons that also modify RestedXP’s arrow.

## Development notes

Key files:
- `RestedXP-TomTom.toc`
- `RestedXP-TomTom.lua`
- `WaypointManager.lua`

High-level flow:
- On login, periodically:
  - Disable/hide RestedXP arrow frame
  - Read current RestedXP arrow target
  - Replace the active TomTom waypoint so TomTom’s Crazy Arrow points to that target

Navigation regression checks with simulated WoW/TomTom APIs: `lua tests/navigation.lua`.
Manager UI, route and minimap checks: `lua tests/manager.lua`. Login integration: `lua tests/navigation.lua with-manager`.
