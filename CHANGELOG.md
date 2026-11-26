# Changelog

## 0.3.0
**New**
- A ship can hit people and NPCs. Slow it does nothing, at around 300 units a second it hurts, fast it kills.

**Ships and the world**
- Ships hit everything solid: frozen and welded props, buildings, ramps, DHDs, big moving things, other ships, and shields that are up. They used to only bump into the map and other ships.
- Loose barrels and crates in the way get knocked aside.
- A Stargate's ring never catches a ship, and a ship comes out of a gate fully in front of it, over the ramp.

**Everything on board**
- Frozen props, things built from several parts, cars, ragdolls, NPCs and smaller ships parked inside stay where they are while the ship flies. Before, the walls went right through them.
- Nothing aboard shakes anymore, on the lift either. NPCs and cars stand still in turns and climbs.
- A smaller ship standing in a hall doesn't push its carrier away, and rides along through gates and hyperspace.
- A hoverball keeps its height, turrets stay on the deck, and people or NPCs who die aboard stay in the ship. If you die aboard, your body stays in the ship too.
- Ragdolls don't stick a limb through the deck or a wall anymore.
- A smaller ship parked on the roof of a flying carrier rides along on its spot.
- If a ship's hull is destroyed (by a kawoosh or the remover), the things welded in it fall down instead of hanging in the air.
- Welded things come along on a hyperspace jump.
- NPCs beamed or dropped into a flying hall are aboard right away and land where they should.

**People aboard**
- You stand upright in a flying ship. Before, you leaned with the ship's speed, up to 45 degrees in flight.
- Other people aboard don't jump around when drawn anymore, also in boost.

**Performance**
- Things lying still in a flying ship cost almost nothing. A hall full of stuff went from 46 to 180 fps.

**Also**
- If a ship gets cut in two in flight, the front half keeps its speed, and nobody gets run over by it.

**Gates**
- Loose cargo and the people standing in a ship go through a Stargate with it. Before, crates fell out under the ship and people were left behind.
- If a ship gets lost in a gate (closed iris, gate shuts on the way), everything in it is lost with it.

**Other**
- The pilot stays in the seat whatever the ship flies into, and the view from the seat follows the nose (ALT to look around).
- The physgun can't pull welded parts around on their weld anymore.
- The build tool's preview disappears while you sit.

## 0.2.1
**New**
- Settings page in the spawn menu's SpaceGrid tab (Settings > SpaceGrid): the server settings "Open ends shut by themselves" and "Ships with a pilot seat get a StarCore core" (only admins change them, everybody sees them) and your own view, glow, machine sounds, room light and fast drawing settings. Texts in all 12 languages.
- Undo for joining and cutting: undo after joining takes the two ships apart again where they are; undo after a cut puts the cut-off pieces back onto the ship where they were - wherever they flew since - with what is welded to them.

**Fixed**
- A shut door, gate or holding force field is now a wall for other SpaceGrid ships too: a ship flying into another ship's shut hangar gate stops at it instead of passing through. Things that drive themselves (cars, Ascension Gates ships, props pushed every tick) are put back out of the sheet, so they no longer push through either.
- A ship stops at a Stargate's ramp or DHD instead of flying through it (not at one welded on the ship). A ship that comes out of a Stargate with its bottom in the ground is lifted out of it.

## 0.2.0
**New**
- Gate halls and a Gate hall bridge with room for a Stargate. With Ascension Gates a ship flies through a Stargate.
- Glass and force-field plugs for every corridor and hall size, also as the wall in a joint.
- Flat hangar doors XL / XXL for the joint of two halls; R shuts or opens that joint.
- Captain's chairs (Gate hall bridge, Bridge XL, Great bridge XXL) and crew roles on every cockpit and bridge: pilot, gunner, engineer for StarCore.
- A destroyed ship looks destroyed: dark hull, fires, then smoke.

**Better**
- Big ships no longer crash the game when they move: the hull follows a hidden keel.
- Welded weapons and props move exactly with the ship; loose crates and props stay where they lie, also in hard turns, and no longer slide on a hovering ship's deck.
- Joining and cutting ships keeps opened ends, plugs and welded things; landing legs keep the StarCore core.
- The pilot camera follows and tilts with the ship's nose and sits higher, so the crosshair is above the ship; in free flight it rolls with the ship.
- Right click turns every part every way, and new parts start upright. Menu order: cockpits, rooms, corridors. Clearer part names and texts in 12 languages.

**Fixed**
- Cutting a ship apart (E+R) no longer crashes the game; sitting down on uneven ground no longer throws the ship into the air.
- Things spawned or frozen inside a ship stay inside; the physgun can't push props through the hull.
- Things another addon moves on a ship keep their place (an Ascension Gates ZPM hub's ZPMs sit in their slots and slide with E).
- Seated crew no longer open and shut the ship's own doors and airlocks.
- The hull keeps its damage when the core is lost; a core removed while the pilot sits is remade at once, so the ship does not fall.
- R on a door, gate or hangar door in an opening removes it; R pressed fast no longer lags; R and the remover no longer take off the wrong thing.
- Gates: E works at once and as often as you like, turns the gate back mid-move; a player beside it no longer keeps it open.
- Players standing where a new wall appears are moved out; area damage no longer hits a ship twice; a part's model no longer stays after its ship is deleted; a big hall's rooms keep their own air.

## 0.1.0
First release (early version).

- About 250 parts that snap into one solid ship: corridors, halls, hangars, rooms, bridges, engines, doors, airlocks
- Every open end closes itself: whatever you build is airtight
- Flies with StarCore, holds air for PowerGrid, Wire inputs and outputs
- All texts in 12 languages
