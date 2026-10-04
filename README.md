# mod-beast-collection

Hunter stables, Pokémon style, for AzerothCore (3.3.5a).

- **The box.** Keep as many tamed beasts as you like. Beyond the stable's four slots, pets wait in a box, and you can call any of them out **anywhere, out of combat**, from the Beast Collection window. Tame a new beast while a pet is at your side and that pet goes to the box instead of the tame failing.
- **The beast-dex.** Every look of every tameable beast in the world, grouped by family: 657 looks in 32 families on stock data. Each look shows its level range and the zones it lives in. Looks you haven't tamed show as a black silhouette. The dex is **shared by every hunter on the account**, and pets you already own count as soon as you log in.
- **Shinies.** Now and then (1% by default) a tameable beast spawns in a rare alternate skin of its own model and sparkles. Tame it and the pet keeps the skin. Shiny looks have their own dex entries.
- **Rewards.** Dex milestones mail you companion pets, a raptor mount and gold, from Hemet Nesingwary Jr. The rewards are in a world table, so you can change them.

The **BeastCollection** addon is the window (`/beasts`, a key binding, or the button on the stable master's window). It has three tabs: Beasts, Beast-dex and Rewards. It uses DragonUI's art when DragonUI is installed and the stock Blizzard frames otherwise.

## How it works

The core keeps a hunter's pets in `character_pet`, but only slots 0–4 mean anything. Every time the active pet is saved, the core deletes that owner's rows above slot 4. Boxed pets therefore live in a table of their own, `mod_beast_box`, which has the same columns. A pet's spells, auras and cooldowns stay in `pet_spell`, `pet_aura` and `pet_spell_cooldown` under the same id, so a pet comes out of the box exactly as it went in. At startup the module moves the core's pet-number counter past the box's highest id, because the core only looks at `character_pet` for that.

Calling a beast works like the stable master's swap, without the stable master. The pet at your side is saved and moved to the box, the chosen beast goes into the core's pet stable as a dismissed pet, and the core's own `LoadPetFromDB` brings it out. Calling is blocked in combat, while mounted or on a taxi, in arenas and while dead, and it has a 10 second cooldown.

Auto-boxing on tame happens in a spell-check hook that runs before Tame Beast's own checks. It only boxes your pet when the tame would otherwise go through: the target's level and exotic flag, range, line of sight and not moving. A tame that was never going to work doesn't put your pet away.

Shinies use the creature's level-selection hook. That hook runs as a creature spawns, and on a respawn it runs just before the core reapplies the creature's display. A shiny skin is another display with the same model file (`CreatureDisplayInfo.dbc` ModelId) that no tameable beast wears, such as a boss wolf's or a quest bear's colouring. Displays scaled very differently from the beast are skipped. The sparkle is the stock Treasure Sparkle aura (58042), marked to survive evading.

Like the core's own stable handlers, moving pets assumes the character database runs its queries in order (`CharacterDatabase.WorkerThreads = 1`, the default). If a pet ever ends up in both tables, login keeps the `character_pet` copy.

No client patch is needed.

## Install

1. Clone into `modules/mod-beast-collection` and rebuild the worldserver.
2. The SQL in `data/sql` is applied automatically: three characters tables (`mod_beast_box`, `mod_beast_dex`, `mod_beast_reward_claim`) and one world table (`mod_beast_collection_reward`).
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
| `H` | `HELLO:<protocol>:<catalog hash>:<looks>:<shiny looks>:<cooldown ms>:<flags>:<is hunter>` |
| `CAT` | `F:` family rows, `C:` look rows, `CE:<hash>:<count>`; the addon caches this per realm by hash |
| `DEX` | `O:` owned displays, `OE`, `R:` reward rows, `RE` |
| `PETS` | `P:` pet rows, `PE:<count>:<cooldown left ms>:<boxed>:<box max>` |
| `CALL:<pet>` / `STORE:<pet>` / `FREE:<pet>` | `OK:<command>:<pet>` or `ERR:<command>:<reason>`, then fresh `P` rows |
| | pushed: `NEW:<display>:<looks>:<shiny>`, `REWARD:<id>:<text>` |

## Uninstall

`data/sql/uninstall` has a characters script and a world script. They aren't run automatically. Boxed pets can't go back to the core, because it keeps only four stabled pets and the active one, so the characters script deletes them. Have players call out and stable the pets they want to keep first.

## Testing the addon

```bash
lua tools/addon_smoke_test.lua addon/BeastCollection
```

This stubs enough of the 3.3.5a API to load the addon and replay fake server replies through the real protocol code.

Released under the MIT License.
