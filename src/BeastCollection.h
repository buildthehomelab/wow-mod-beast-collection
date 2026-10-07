/*
 * mod-beast-collection
 *
 * Hunter stables, Pokémon style.
 *
 *   - The box: as many tamed beasts as you like. Beyond the stable's four slots, pets wait in a
 *     box of their own (characters table mod_beast_box), and any of them can be called out
 *     anywhere out of combat from the Beast Collection window. Taming a new beast with a pet
 *     already at your side sends that pet to the box instead of failing.
 *   - The beast-dex: every look (creature model) of every tameable beast in the world, grouped
 *     by family, with what you have tamed marked. It's shared by all characters on the account.
 *   - Shinies: now and then a tameable beast spawns in a rare alternate skin of its own model,
 *     sparkling. Tame it and the pet keeps the skin; shiny looks have their own dex entries.
 *   - Rewards for dex milestones (world table mod_beast_collection_reward), by mail or straight
 *     away.
 *   - The field guide: target a tameable beast and its look is recorded as found; cast Beast Lore
 *     on it and it's studied. Each look has a spawn map, each family its diet, talent tree and
 *     the abilities its pets learn.
 *
 * The BeastCollection addon is the window. It talks to the module through addon whispers, the
 * same way RetailAH does.
 *
 * Why a table of its own: the core keeps a hunter's pets in character_pet, but only slots 0-4
 * mean anything, and every time the active pet is saved it deletes the owner's rows above slot
 * 4. Boxed pets therefore live in mod_beast_box, with the same columns. Their spells, auras and
 * cooldowns stay where they are (keyed by the pet's id), so a pet comes out of the box exactly
 * as it went in.
 *
 * Released under the MIT License.
 */

#ifndef MOD_BEAST_COLLECTION_H
#define MOD_BEAST_COLLECTION_H

#include "Define.h"
#include "PetDefines.h"
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

class Creature;
class Pet;
class Player;
struct CreatureTemplate;

namespace BeastCollection
{
    // Addon message prefix; the client sends "BCOL\t<command>" as a whisper to itself.
    constexpr char const* PREFIX = "BCOL";

    // Bumped when a message changes shape. The addon refuses to run against another version.
    constexpr uint32 PROTOCOL_VERSION = 1;

    // Leaves room for the prefix and tab inside the client's 255-byte chat message limit.
    constexpr std::size_t MAX_PAYLOAD = 240;

    struct Config
    {
        bool enabled = true;

        bool boxEnabled = true;
        uint32 boxMaxPets = 0;            // 0 = no limit
        bool autoStoreOnTame = true;
        uint32 swapCooldownMs = 10000;
        bool swapInInstances = true;

        bool zoneHints = true;
        uint32 zoneSamples = 4;
        bool discovery = true;
        uint32 maxPins = 60;              // per look and zone

        bool shinyEnabled = true;
        float shinyChance = 1.0f;         // percent
        uint32 shinyAura = 58042;         // Treasure Sparkle
        bool shinyUnusedSkins = false;
        bool shinyInInstances = true;
        bool shinyPetSparkle = true;

        bool rewardsEnabled = true;
        uint32 rewardMailSender = 715;    // Hemet Nesingwary Jr.
    };

    Config& GetConfig();
    void LoadConfig();

    // ---- BeastCollection.cpp: transport --------------------------------------------------------

    void Send(Player* player, std::string const& payload);
    // Sends "<header>:<row>;<row>;..." in as many messages as it takes, never splitting a row.
    void SendRows(Player* player, std::string const& header, std::vector<std::string> const& rows);
    // Takes out the characters the protocol uses as separators.
    std::string Clean(std::string_view text);
    bool ParseUInt(std::string_view text, uint32& out);
    // A line in the player's chat frame, for players without the addon too.
    void Notify(Player* player, std::string const& text);
    // Bots (playerbots) have no client; nothing here is for them.
    bool IsBot(Player* player);

    // ---- BeastCatalog.cpp: every tameable look -------------------------------------------------

    namespace Catalog
    {
        enum LookFlags : uint8
        {
            LOOK_EXOTIC = 0x1,  // Beast Mastery only
            LOOK_SHINY  = 0x2,  // an alternate skin; only from shiny spawns
            LOOK_RARE   = 0x4,  // only rare beasts wear it
        };

        // A spawn on a zone's world map, in tenths of a percent (0-1000) like the client's map.
        struct Pin
        {
            uint32 zone = 0;
            uint16 x = 0;
            uint16 y = 0;
        };

        struct Look
        {
            uint32 display = 0;
            uint32 family = 0;
            uint8 flags = 0;
            uint32 entry = 0;     // a creature that wears it, for the addon's 3D preview
            uint8 minLevel = 0;
            uint8 maxLevel = 0;
            std::string name;     // the beast to look for (for a shiny, the beast it replaces)
            std::string zones;    // where it lives, "Zone/Zone"
            std::vector<uint32> spells;  // what it casts in the wild, revealed by Beast Lore
            std::vector<Pin> pins;       // by zone, the zone with most spawns first
        };

        struct Family
        {
            uint32 id = 0;
            std::string name;
            bool exotic = false;
            uint32 normalLooks = 0;
            uint32 shinyLooks = 0;
            int32 talentType = 0;   // CreatureFamily.dbc: 0 Ferocity, 1 Tenacity, 2 Cunning
            uint32 foodMask = 0;    // CreatureFamily.dbc petFoodMask
        };

        struct ZonePin
        {
            uint32 display = 0;
            uint16 x = 0;
            uint16 y = 0;
        };

        struct Data
        {
            std::vector<Look> looks;
            std::unordered_map<uint32, std::size_t> byDisplay;  // incl. other-gender aliases
            std::vector<Family> families;
            uint32 normalTotal = 0;
            uint32 shinyTotal = 0;
            // ModelId (CreatureDisplayInfo.dbc) -> shiny displays sharing that model
            std::unordered_map<uint32, std::vector<uint32>> shinyByModel;
            std::unordered_set<uint32> shinyDisplays;
            std::unordered_map<uint32, std::vector<ZonePin>> pinsByZone;  // every normal look's pins
            std::unordered_map<uint32, std::string> zoneNames;
            std::unordered_map<std::string, uint32> zoneByName;           // lower case
            uint32 hash = 0;  // changes when the catalog does, so the addon can cache it
            std::vector<std::string> familyRows;
            std::vector<std::string> abilityRows;
            std::vector<std::string> lookRows;
        };

        // Built once at startup.
        void Build();
        std::shared_ptr<Data const> Get();
        // The same without the reference count, for hot paths (creature updates).
        Data const* Peek();
        Look const* Find(Data const& data, uint32 display);

        // The spawn map of one look, and every normal look's spawns in a zone (by name, as the
        // client's world map calls it).
        void SendMap(Player* player, uint32 display);
        void SendZone(Player* player, std::string_view zoneName);
    }

    // ---- BeastBox.cpp: the box and calling pets out --------------------------------------------

    namespace Box
    {
        struct Entry
        {
            PetStable::PetInfo info;
            uint32 boxedAt = 0;
        };

        // Startup: keeps the core's pet number counter above the ids parked in the box.
        void ReservePetNumbers();
        void OnLogin(Player* player);
        void OnLogout(Player* player);
        void OnCharacterDeleted(uint32 guidLow);

        // Before Tame Beast's own checks: send the current pet to the box so the tame can go on.
        void OnTameCheck(Player* player, Creature* target);

        // "P" rows: the active pet, the stable and the box.
        void SendPets(Player* player);
        void HandleCall(Player* player, uint32 petNumber);
        void HandleStore(Player* player, uint32 petNumber);
        void HandleRelease(Player* player, uint32 petNumber);

        // Every pet the character owns, active, stabled or boxed: their displays, for the dex.
        std::vector<uint32> OwnedDisplays(Player* player);
    }

    // ---- BeastDex.cpp: the account's dex and the rewards ---------------------------------------

    namespace Dex
    {
        void LoadRewards();
        void OnLogin(Player* player);
        void OnLogout(Player* player);
        // A hunter pet came into the world: register its look.
        void OnPetAdded(Pet* pet);
        void SendDex(Player* player);
        // The addon saw a beast (target or mouseover): "SEE:<guid>", the client's hex GUID.
        void HandleSee(Player* player, std::string_view guidText);
        // Beast Lore landed on a beast: its look is studied.
        void OnBeastLore(Player* player, Creature* target);
    }

    // ---- BeastShiny.cpp: shiny spawns ----------------------------------------------------------

    namespace Shiny
    {
        void ApplySpellChanges();
        void OnSelectLevel(CreatureTemplate const* cinfo, Creature* creature);
        void OnCreatureUpdate(Creature* creature);
        void OnPetAdded(Pet* pet);
    }
}

#endif
