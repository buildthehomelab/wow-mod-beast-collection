# mod-beast-collection

Hunter stables, Pokémon style, for AzerothCore (3.3.5a).

- **The box.** Keep as many tamed beasts as you like. Beyond the stable's four slots, pets wait in a box, and you can call any of them out **anywhere, out of combat**, from the Beast Collection window. Tame a new beast while a pet is at your side and that pet goes to the box instead of the tame failing.
- **The field guide.** Every look of every tameable beast in the world, grouped by family: 657 looks in 32 families on stock data. **Target** a tameable beast and its look is recorded as found. Cast **Beast Lore** on it and it's studied, which shows what it casts in the wild. **Tame** it and it's in your collection. Each look has a spawn map, drawn from your own world map with a pin for every spot it lives. Each family has a page with its pet talent tree, its diet and every ability its pets learn, with the pet level of each rank. The guide is **shared by every hunter on the account**, and pets you already own count as soon as you log in.
- **Shinies.** Now and then (1% by default) a tameable beast spawns in a rare alternate skin of its own model and sparkles. Tame it and the pet keeps the skin. Shiny looks have their own dex entries.
- **Rewards.** Dex milestones mail you companion pets, a raptor mount and gold, from Hemet Nesingwary Jr. The rewards are in a world table, so you can change them.

The **BeastCollection** addon is the window (`/beasts`, `/fieldguide`, a key binding, or the button on the stable master's window). It has three tabs: Beasts, Field Guide and Rewards. It uses DragonUI's art when DragonUI is installed and the stock Blizzard frames otherwise.

### The field guide

The guide works like Hunter's Field Guide (the Classic Era addon) on WotLK's rules. Its Filters menu has the guide's options:

- **Hide beasts I haven't found** (on by default): immersive mode. Looks the account hasn't found show as `???`, with only their family and level range. Turn it off for a full reference.
- **Beasts on the world map** (on): the world map shows pins for beasts you've found but not tamed, and for your favorites. Click a pin to open its page. Clicking a look's spawn map opens the world map there, with that beast's pins in green.
- **Record beasts I target** (on): targeting or pointing at a tameable beast records it.

The filters are: not tamed yet, not found yet, rare beasts (rare looks are blue everywhere), in my zone, and favorites (the star on a beast's page). Search matches beast names, zones, families and ability names, so `dash` lists every family whose pets learn Dash.

Hunter's Field Guide has two filters the guide leaves out, because WotLK doesn't need them. Pets don't learn abilities from wild beasts here; every family's pets learn theirs as they level. Every pet attacks at the same speed, so a "fast" filter would match everything or nothing.

## How it works

The core keeps a hunter's pets in `character_pet`, but only slots 0–4 mean anything. Every time the active pet is saved, the core deletes that owner's rows above slot 4. Boxed pets therefore live in a table of their own, `mod_beast_box`, which has the same columns. A pet's spells, auras and cooldowns stay in `pet_spell`, `pet_aura` and `pet_spell_cooldown` under the same id, so a pet comes out of the box exactly as it went in. At startup the module moves the core's pet-number counter past the box's highest id, because the core only looks at `character_pet` for that.

Calling a beast works like the stable master's swap, without the stable master. The pet at your side is saved and moved to the box, the chosen beast goes into the core's pet stable as a dismissed pet, and the core's own `LoadPetFromDB` brings it out. Calling is blocked in combat, while mounted or on a taxi, in arenas and while dead, and it has a 10 second cooldown.

Auto-boxing on tame happens in a spell-check hook that runs before Tame Beast's own checks. It only boxes your pet when the tame would otherwise go through: the target's level and exotic flag, range, line of sight and not moving. A tame that was never going to work doesn't put your pet away.

Shinies use the creature's level-selection hook. That hook runs as a creature spawns, and on a respawn it runs just before the core reapplies the creature's display. A shiny skin is another display with the same model file (`CreatureDisplayInfo.dbc` ModelId) that no tameable beast wears, such as a boss wolf's or a quest bear's colouring. Displays scaled very differently from the beast are skipped. The sparkle is the stock Treasure Sparkle aura (58042), marked to survive evading.

Moving pets doesn't need the character database to run its queries in order, so `CharacterDatabase.WorkerThreads` above 1 is fine. With several workers, a pet's save can land after it was moved to the box, leaving it in both tables. If that happens, login keeps the box copy, unless the core has the pet current or stabled.

Found and studied looks are in `mod_beast_seen`. The addon reports the GUID of each beast the player targets or points at. The server records it only if that creature is tameable and the player's client really has it in view, so it can't be faked from across the world. Beast Lore is caught in the spell-cast hook. Only hunters record finds.

Spawn pins are worked out at startup without touching terrain: each spawn goes on the map of the first of the look's sampled zones that covers it, or else on the zone of that map whose middle it's nearest. That can put a spawn right on a border onto the neighbouring zone's map, but the pin is still at the right spot. Spawns inside dungeons get no pins. What a beast casts in the wild comes from its `creature_template_spell` rows and its SmartAI cast actions. Family abilities come from the core's pet level-up spell list.

No client patch is needed.

## Requirements

- AzerothCore (wotlk, master branch) and a WoW 3.3.5a (12340) client. No client patch.
- The `addon/BeastCollection` addon for the window. Players need it to use the box and the field guide. It uses DragonUI's art when DragonUI is installed.
- It also works on the mod-playerbots core fork; it detects `WorldSession::IsHeadless()` or `IsBot()` and needs neither.

## Installation

1. Clone into `modules/mod-beast-collection` (the folder name matters: AzerothCore names the script loader after it) and rebuild the worldserver:

   ```bash
   git clone https://github.com/buildthehomelab/wow-mod-beast-collection.git modules/mod-beast-collection
   ```
2. The SQL in `data/sql` is applied automatically: four characters tables (`mod_beast_box`, `mod_beast_dex`, `mod_beast_seen`, `mod_beast_reward_claim`) and one world table (`mod_beast_collection_reward`).
3. Copy `conf/mod_beast_collection.conf.dist` to your config folder and adjust it.
4. Give players the `addon/BeastCollection` folder. `sql/portalkeeper_addon.sql` makes Portalkeeper install it; run it by hand.

## Configuration

| Option | Default | |
|---|---|---|
| `BeastCollection.Enable` | 1 | Master switch |
| `BeastCollection.Box.Enable` | 1 | The box and calling beasts from it |
| `BeastCollection.Box.MaxPets` | 0 | Box size per character, 0 = no limit |
| `BeastCollection.Box.AutoStoreOnTame` | 1 | Taming with a pet out sends it to the box |
| `BeastCollection.Box.SwapCooldown` | 10 | Seconds between calls |
| `BeastCollection.Box.SwapInInstances` | 1 | Calling inside dungeons and raids |
| `BeastCollection.Dex.ZoneHints` | 1 | Work out each look's zones at startup |
| `BeastCollection.Dex.ZoneSamples` | 4 | Spawns sampled per look for that |
| `BeastCollection.Dex.Discovery` | 1 | Record found (targeted) and studied (Beast Lore) looks |
| `BeastCollection.Dex.MaxPins` | 60 | Spawn map pins per look and zone, 0 = no limit |
| `BeastCollection.Shiny.Enable` | 1 | Shiny spawns |
| `BeastCollection.Shiny.Chance` | 1.0 | Percent per spawn and respawn |
| `BeastCollection.Shiny.Aura` | 58042 | Sparkle visual, 0 = none |
| `BeastCollection.Shiny.UnusedSkins` | 0 | Also use DBC skins no creature wears |
| `BeastCollection.Shiny.InInstances` | 1 | Shinies in dungeons |
| `BeastCollection.Shiny.PetSparkle` | 1 | Shiny pets keep sparkling |
| `BeastCollection.Rewards.Enable` | 1 | Dex milestone rewards |
| `BeastCollection.Rewards.MailSender` | 715 | Creature the reward mail comes from |

## Rewards

`mod_beast_collection_reward` (world). Edit it and run `.reload config`.

| `type` | Reached when |
|---|---|
| 0 | the account has `count` normal looks |
| 1 | the account has `count` shiny looks |
| 2 | every normal look of `family` is tamed (0 = each family, once per family) |

Each row can give an `item` (`item_count`), `money` (copper), a `title` (CharTitles.dbc id) and a `spell`. Items and money come by mail. `per_character` = 1 gives the reward to every hunter on the account; 0 gives it to the first one only. Only hunters receive rewards.

Defaults:

| Milestone | Reward |
|---|---|
| 10 looks | Cat Carrier (Siamese) |
| 25 looks | Parrot Cage (Senegal) |
| 50 looks | Black Kingsnake |
| 100 looks | Whistle of the Mottled Red Raptor |
| 200 looks | Albino Snake + 500 gold |
| first shiny | Spectral Tiger Cub |
| each complete family | 25 gold |

## Protocol

The addon whispers itself `BCOL\t<command>`. The server swallows these messages and answers the same way.

| Client | Server |
|---|---|
| `H` | `HELLO:<protocol>:<catalog hash>:<looks>:<shiny looks>:<cooldown ms>:<flags>:<is hunter>`; flags 1 box, 2 shinies, 4 rewards, 8 finds |
| `CAT` | `F:` family rows (with talent tree and diet), `A:` ability rows (`<family>,<spell>-<pet level>/...`), `C:` look rows (with wild spells), `CE:<hash>:<count>`; the addon caches this per realm by hash |
| `DEX` | `O:` owned displays, `OE`, `R:` reward rows, `RE`, `S:<display>,<1 found / 2 studied>` rows, `SE` |
| `SEE:<guid>` | `SEEN:<display>:<level>:<found>` when it's news, else nothing |
| `MAP:<display>` | `MZ:<display>:<zone>,<name>,<pins>` rows, `MP:<display>:<zone>,<x>,<y>` rows (tenths of a percent), `ME:<display>` |
| `ZONE:<zone name>` | `ZP:<zone>:<display>,<x>,<y>` rows, `ZE:<zone>:<pins>:<name>` (zone 0 when unknown) |
| `PETS` | `P:` pet rows, `PE:<count>:<cooldown left ms>:<boxed>:<box max>` |
| `CALL:<pet>` / `STORE:<pet>` / `FREE:<pet>` | `OK:<command>:<pet>` or `ERR:<command>:<reason>`, then fresh `P` rows |
| | pushed: `NEW:<display>:<looks>:<shiny>`, `REWARD:<id>:<text>` |

## Patch Notes

### 1.1.1

- Fixed: with several character database workers, a beast sent to the box could be lost after a relog.

### 1.1.0: The field guide

- The Beast-dex tab is now the **Field Guide**. Target a tameable beast to record it, cast Beast Lore on it to study it, tame it to collect it.
- Immersive mode hides beasts until you find them. Turn it off in the Filters menu for a full reference.
- Every beast has a **spawn map** with a pin for each spot it lives, drawn from your own world map. Click it to open the world map there.
- **World map pins** for beasts you've found but not tamed, and for favorites. Click one to open its page.
- **Family pages**: pet talent tree, diet, and every ability the family's pets learn, with the pet level of each rank.
- Studying a beast with Beast Lore shows what it casts in the wild.
- New filters: not found yet, rare, in my zone, favorites. Search also finds ability names.
- Rare beasts are shown in blue.

### 1.0.0

- The pet box, the beast-dex, shinies and dex rewards.

## Uninstall

`data/sql/uninstall` has a characters script and a world script. They aren't run automatically. Boxed pets can't go back to the core, because it keeps only four stabled pets and the active one, so the characters script deletes them. Have players call out and stable the pets they want to keep first.

## Testing the addon

```bash
lua tools/addon_smoke_test.lua addon/BeastCollection
```

This stubs enough of the 3.3.5a API to load the addon and replay fake server replies through the real protocol code, the world map calls included.

## Troubleshooting

- **The window has no data:** the addon talks to the server module through addon whispers, so both must be installed. `BeastCollection.Enable` has to be `1`.
- **A boxed pet is in both the box and the stable:** this can happen with `CharacterDatabase.WorkerThreads` above 1. Login keeps the box copy, unless the core has the pet current or stabled.
- **Rewards didn't arrive:** they come by mail from the creature in `BeastCollection.Rewards.MailSender`, and only hunters receive them. Edit `mod_beast_collection_reward` and run `.reload config` to change them.

## Credits

Author: [buildthehomelab](https://github.com/buildthehomelab)

## License

MIT. See [LICENSE](LICENSE).
