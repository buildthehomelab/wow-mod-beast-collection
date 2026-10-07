/*
 * mod-beast-collection: the catalog of beast looks.
 *
 * A look is a creature display (model + skin). The dex lists every look a hunter can tame: the
 * displays of every tameable creature that is spawned somewhere in the world, grouped by family.
 * Each look remembers a beast that wears it, the levels it's found at and, when
 * BeastCollection.Dex.ZoneHints is on, the zones it lives in (worked out from spawn positions
 * at startup).
 *
 * For the field guide each look also carries what it casts in the wild (creature_template_spell
 * and SmartAI casts) and its spawns as pins on the zone world maps, and each family the abilities
 * its pets learn as they level (the core's pet level-up spell list).
 *
 * Shiny looks are the other skins of the same models: displays that share a tameable look's
 * model file (CreatureDisplayInfo.dbc ModelId) but that no tameable beast wears, like a boss
 * wolf's or a quest bear's colouring. Sharing the model means they animate the same way, so any
 * of them can be put on a beast of that model when it spawns shiny.
 *
 * Released under the MIT License.
 */

#include "BeastCollection.h"

#include "DBCStores.h"
#include "Log.h"
#include "MapMgr.h"
#include "DatabaseEnv.h"
#include "ObjectMgr.h"
#include "QueryResult.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "Timer.h"
#include "World.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <set>
#include <tuple>

namespace BeastCollection::Catalog
{
    namespace
    {
        // Set once at startup, before any map updates; read-only afterwards, so no lock.
        std::shared_ptr<Data const> sData;

        struct Spawn
        {
            uint16 map;
            uint32 phaseMask;
            float x, y, z;

            float posX() const { return x; }
            float posY() const { return y; }
        };

        uint32 Fnv(uint32 hash, std::string const& text)
        {
            for (unsigned char c : text)
            {
                hash ^= c;
                hash *= 16777619u;
            }
            return hash;
        }

        bool IsRareRank(uint32 rank)
        {
            return rank == CREATURE_ELITE_RARE || rank == CREATURE_ELITE_RAREELITE;
        }

        uint32 ModelOf(uint32 display)
        {
            CreatureDisplayInfoEntry const* info = sCreatureDisplayInfoStore.LookupEntry(display);
            return info ? info->ModelId : 0;
        }

        float ScaleOf(uint32 display)
        {
            CreatureDisplayInfoEntry const* info = sCreatureDisplayInfoStore.LookupEntry(display);
            return info && info->scale > 0.0f ? info->scale : 1.0f;
        }

        // Prefer a creature with this one model, so the addon's preview shows exactly this look;
        // then the lowest level one.
        bool BetterPreview(CreatureTemplate const* candidate, CreatureTemplate const* current)
        {
            if (!current)
                return true;
            bool candidateSingle = candidate->Models.size() == 1;
            bool currentSingle = current->Models.size() == 1;
            if (candidateSingle != currentSingle)
                return candidateSingle;
            return candidate->minlevel < current->minlevel;
        }

        std::string ZoneName(uint32 zone, LocaleConstant locale)
        {
            AreaTableEntry const* area = sAreaTableStore.LookupEntry(zone);
            if (!area)
                return {};
            char const* name = area->area_name[locale];
            if (!name || !*name)
                name = area->area_name[LOCALE_enUS];
            return name && *name ? Clean(name) : std::string();
        }

        // The zones a sample of spawns are in, most spawns first.
        std::vector<uint32> ZonesOf(std::vector<Spawn> const& spawns, uint32 samples)
        {
            if (spawns.empty())
                return {};

            std::map<uint32, uint32> counts;
            std::size_t const step = std::max<std::size_t>(1, spawns.size() / samples);
            for (std::size_t i = 0, taken = 0; i < spawns.size() && taken < samples; i += step, ++taken)
            {
                Spawn const& s = spawns[i];
                uint32 zone = sMapMgr->GetZoneId(s.phaseMask ? s.phaseMask : PHASEMASK_NORMAL, s.map, s.x, s.y, s.z);
                if (zone)
                    ++counts[zone];
            }

            std::vector<std::pair<uint32, uint32>> sorted(counts.begin(), counts.end());
            std::stable_sort(sorted.begin(), sorted.end(), [](auto const& a, auto const& b) { return a.second > b.second; });

            std::vector<uint32> out;
            for (auto const& [zone, count] : sorted)
                out.push_back(zone);
            return out;
        }

        // "Zone/Zone": the first two zones with a name.
        std::string ZoneText(std::vector<uint32> const& zones, LocaleConstant locale)
        {
            std::string out;
            uint32 named = 0;
            for (uint32 zone : zones)
            {
                std::string name = ZoneName(zone, locale);
                if (name.empty())
                    continue;
                if (!out.empty())
                    out += '/';
                out += name;
                if (++named == 2)
                    break;
            }
            return out;
        }

        // World map coordinates (0-100) for a spot, if the zone has a map of its own on that map.
        bool OnZoneMap(uint32 zone, uint16 map, float worldX, float worldY, float& x, float& y)
        {
            AreaTableEntry const* area = sAreaTableStore.LookupEntry(zone);
            if (!area || area->mapid != map)
                return false;
            x = worldX;
            y = worldY;
            Map2ZoneCoordinates(x, y, zone);
            return x >= 0.0f && x <= 100.0f && y >= 0.0f && y <= 100.0f && !(x == worldX && y == worldY);
        }

        // Top-level zones of each map that have a world map, for spawns outside a look's zones.
        std::unordered_map<uint32, std::vector<uint32>> MapZones()
        {
            std::unordered_map<uint32, std::vector<uint32>> zones;
            for (AreaTableEntry const* area : sAreaTableStore)
            {
                if (area->zone)
                    continue;
                float x = 123456.0f;
                float y = 654321.0f;
                Map2ZoneCoordinates(x, y, area->ID);
                if (x != 123456.0f || y != 654321.0f)  // left alone: no world map
                    zones[area->mapid].push_back(area->ID);
            }
            return zones;
        }

        // Pins for a look's spawns. A spawn goes on the first of the look's zones whose map covers
        // it, or else on the map of whichever zone of that map it's nearest the middle of.
        // Spawns closer than 1% of the map to a pin already there are dropped, and each zone keeps
        // at most maxPins, spread over its spawns.
        std::vector<Pin> PinsOf(std::vector<Spawn> const& spawns, std::vector<uint32> const& zones,
            std::unordered_map<uint32, std::vector<uint32>> const& mapZones, uint32 maxPins)
        {
            std::map<uint32, std::vector<Pin>> byZone;
            std::set<std::tuple<uint32, uint16, uint16>> taken;
            for (Spawn const& s : spawns)
            {
                uint32 zone = 0;
                float x = 0.0f;
                float y = 0.0f;
                for (uint32 candidate : zones)
                    if (OnZoneMap(candidate, s.map, s.posX(), s.posY(), x, y))
                    {
                        zone = candidate;
                        break;
                    }
                if (!zone)
                {
                    auto itr = mapZones.find(s.map);
                    float best = 0.0f;
                    if (itr != mapZones.end())
                        for (uint32 candidate : itr->second)
                        {
                            float cx;
                            float cy;
                            if (!OnZoneMap(candidate, s.map, s.posX(), s.posY(), cx, cy))
                                continue;
                            float distance = (cx - 50.0f) * (cx - 50.0f) + (cy - 50.0f) * (cy - 50.0f);
                            if (!zone || distance < best)
                            {
                                zone = candidate;
                                best = distance;
                                x = cx;
                                y = cy;
                            }
                        }
                }
                if (!zone)
                    continue;
                if (!taken.emplace(zone, uint16(x), uint16(y)).second)
                    continue;
                byZone[zone].push_back({ zone, uint16(x * 10.0f + 0.5f), uint16(y * 10.0f + 0.5f) });
            }

            std::vector<std::pair<uint32, std::vector<Pin>>> sorted(byZone.begin(), byZone.end());
            std::stable_sort(sorted.begin(), sorted.end(), [](auto const& a, auto const& b) { return a.second.size() > b.second.size(); });

            std::vector<Pin> out;
            for (auto& [zone, pins] : sorted)
            {
                if (maxPins && pins.size() > maxPins)
                {
                    std::vector<Pin> spread;
                    for (uint32 i = 0; i < maxPins; ++i)
                        spread.push_back(pins[i * pins.size() / maxPins]);
                    pins = std::move(spread);
                }
                out.insert(out.end(), pins.begin(), pins.end());
            }
            return out;
        }

        // Spells each creature casts: its creature_template_spell list and SmartAI casts.
        std::unordered_map<uint32, std::vector<uint32>> WildSpells(std::unordered_set<uint32> const& entries)
        {
            std::unordered_map<uint32, std::vector<uint32>> spells;
            auto add = [&](uint32 entry, uint32 spell)
            {
                if (!spell || !entries.count(entry))
                    return;
                SpellInfo const* info = sSpellMgr->GetSpellInfo(spell);
                if (!info || info->IsPassive())
                    return;
                std::vector<uint32>& list = spells[entry];
                if (std::find(list.begin(), list.end(), spell) == list.end())
                    list.push_back(spell);
            };

            for (uint32 entry : entries)
                if (CreatureTemplate const* cinfo = sObjectMgr->GetCreatureTemplate(entry))
                    for (uint32 spell : cinfo->spells)
                        add(entry, spell);

            // SMART_SCRIPT_TYPE_CREATURE (0), SMART_ACTION_CAST (11)
            if (QueryResult result = WorldDatabase.Query("SELECT `entryorguid`, `action_param1` FROM `smart_scripts` "
                "WHERE `source_type` = 0 AND `action_type` = 11 AND `entryorguid` > 0 ORDER BY `entryorguid`, `id`"))
            {
                do
                {
                    Field* f = result->Fetch();
                    add(uint32(f[0].Get<int32>()), f[1].Get<uint32>());
                } while (result->NextRow());
            }
            return spells;
        }

        // "<family>,<spell>-<pet level>/<spell>-<pet level>..." per ability, ranks in order.
        std::vector<std::string> AbilityRows(uint32 family)
        {
            PetLevelupSpellSet const* levelup = sSpellMgr->GetPetLevelupSpellList(family);
            if (!levelup)
                return {};

            std::vector<std::pair<uint32 /*first*/, std::string>> abilities;
            for (auto const& [level, spell] : *levelup)
            {
                uint32 first = sSpellMgr->GetFirstSpellInChain(spell);
                auto itr = std::find_if(abilities.begin(), abilities.end(), [first](auto const& a) { return a.first == first; });
                if (itr == abilities.end())
                {
                    abilities.emplace_back(first, std::to_string(family) + ",");
                    itr = std::prev(abilities.end());
                }
                else
                    itr->second += '/';
                itr->second += std::to_string(spell) + "-" + std::to_string(level);
            }

            std::vector<std::string> rows;
            for (auto& [first, row] : abilities)
                rows.push_back(std::move(row));
            return rows;
        }
    }

    void Build()
    {
        uint32 const startTime = getMSTime();
        Config const& cfg = GetConfig();
        LocaleConstant const locale = sWorld->GetDefaultDbcLocale();
        auto data = std::make_shared<Data>();

        // Where each creature is spawned.
        std::unordered_map<uint32, std::vector<Spawn>> spawnsByEntry;
        for (auto const& [spawnId, creature] : sObjectMgr->GetAllCreatureData())
        {
            Spawn spawn{ creature.mapid, creature.phaseMask, creature.posX, creature.posY, creature.posZ };
            for (uint32 id : { creature.id, creature.id2, creature.id3 })
                if (id)
                    spawnsByEntry[id].push_back(spawn);
        }

        // The normal looks: every model of every spawned tameable creature.
        struct Building
        {
            Look look;
            CreatureTemplate const* preview = nullptr;
            bool allRare = true;
            std::vector<Spawn> spawns;
            std::vector<uint32> entries;
        };
        std::map<uint32, Building> normal;  // ordered, so the catalog (and its hash) is stable

        CreatureTemplateContainer const* templates = sObjectMgr->GetCreatureTemplates();
        for (auto const& [entry, cinfo] : *templates)
        {
            if (!cinfo.IsTameable(true))
                continue;
            CreatureFamilyEntry const* family = sCreatureFamilyStore.LookupEntry(cinfo.family);
            if (!family || family->petTalentType < 0)
                continue;
            auto spawned = spawnsByEntry.find(entry);
            if (spawned == spawnsByEntry.end())
                continue;

            for (CreatureModel const& model : cinfo.Models)
            {
                uint32 display = model.CreatureDisplayID;
                if (!display || !sCreatureDisplayInfoStore.LookupEntry(display))
                    continue;

                Building& b = normal[display];
                if (!b.look.display)
                {
                    b.look.display = display;
                    b.look.family = cinfo.family;
                    b.look.minLevel = cinfo.minlevel;
                    b.look.maxLevel = cinfo.maxlevel;
                }
                b.look.minLevel = std::min(b.look.minLevel, cinfo.minlevel);
                b.look.maxLevel = std::max(b.look.maxLevel, cinfo.maxlevel);
                if (cinfo.IsExotic())
                    b.look.flags |= LOOK_EXOTIC;
                if (!IsRareRank(cinfo.rank))
                    b.allRare = false;
                if (BetterPreview(&cinfo, b.preview))
                    b.preview = &cinfo;
                b.spawns.insert(b.spawns.end(), spawned->second.begin(), spawned->second.end());
                b.entries.push_back(entry);
            }
        }

        // Shiny candidates: other displays sharing a normal look's model.
        std::unordered_map<uint32, uint32> baseOfModel;     // ModelId -> the normal display it came from
        for (auto const& [display, b] : normal)
            if (uint32 model = ModelOf(display); model && !baseOfModel.count(model))
                baseOfModel[model] = display;

        std::map<uint32, CreatureTemplate const*> shinyPreview;  // shiny display -> a creature wearing it
        auto consider = [&](uint32 display, CreatureTemplate const* wearer)
        {
            if (!display || normal.count(display))
                return;
            uint32 model = ModelOf(display);
            auto base = baseOfModel.find(model);
            if (base == baseOfModel.end())
                return;
            // A boss's skin is often scaled up; keep shinies about the size of the beast.
            float ratio = ScaleOf(display) / ScaleOf(base->second);
            if (ratio < 0.6f || ratio > 1.5f)
                return;
            auto [it, inserted] = shinyPreview.emplace(display, wearer);
            if (!inserted && wearer && BetterPreview(wearer, it->second))
                it->second = wearer;
        };

        if (cfg.shinyEnabled)
        {
            for (auto const& [entry, cinfo] : *templates)
                for (CreatureModel const& model : cinfo.Models)
                    consider(model.CreatureDisplayID, &cinfo);
            if (cfg.shinyUnusedSkins)
                for (uint32 i = 0; i < sCreatureDisplayInfoStore.GetNumRows(); ++i)
                    if (CreatureDisplayInfoEntry const* info = sCreatureDisplayInfoStore.LookupEntry(i))
                        consider(info->Displayid, nullptr);
        }

        // What the beasts cast in the wild.
        std::unordered_set<uint32> tameEntries;
        for (auto const& [display, b] : normal)
            tameEntries.insert(b.entries.begin(), b.entries.end());
        std::unordered_map<uint32, std::vector<uint32>> wildSpells = WildSpells(tameEntries);
        std::unordered_map<uint32, std::vector<uint32>> const mapZones = MapZones();

        // Assemble.
        std::map<uint32, Family> families;
        for (auto& [display, b] : normal)
        {
            Look& look = b.look;
            if (b.allRare)
                look.flags |= LOOK_RARE;
            look.entry = b.preview ? b.preview->Entry : 0;
            look.name = b.preview ? Clean(b.preview->Name) : "?";
            std::vector<uint32> zones;
            if (cfg.zoneHints)
            {
                zones = ZonesOf(b.spawns, cfg.zoneSamples);
                look.zones = ZoneText(zones, locale);
            }
            look.pins = PinsOf(b.spawns, zones, mapZones, cfg.maxPins);
            for (Pin const& pin : look.pins)
            {
                data->pinsByZone[pin.zone].push_back({ display, pin.x, pin.y });
                if (!data->zoneNames.count(pin.zone))
                    data->zoneNames[pin.zone] = ZoneName(pin.zone, locale);
            }
            // The preview creature's spells first, then the others wearing the look; six at most.
            std::stable_partition(b.entries.begin(), b.entries.end(), [&](uint32 entry) { return entry == look.entry; });
            for (uint32 entry : b.entries)
                if (auto itr = wildSpells.find(entry); itr != wildSpells.end())
                    for (uint32 spell : itr->second)
                        if (look.spells.size() < 6 && std::find(look.spells.begin(), look.spells.end(), spell) == look.spells.end())
                            look.spells.push_back(spell);
            data->byDisplay[display] = data->looks.size();
            data->looks.push_back(look);
            ++families[look.family].normalLooks;
            ++data->normalTotal;
        }

        for (auto const& [display, wearer] : shinyPreview)
        {
            uint32 model = ModelOf(display);
            Building const& base = normal.at(baseOfModel.at(model));
            Look look;
            look.display = display;
            look.family = base.look.family;
            look.flags = LOOK_SHINY | (base.look.flags & LOOK_EXOTIC);
            look.entry = wearer ? wearer->Entry : 0;
            look.minLevel = base.look.minLevel;
            look.maxLevel = base.look.maxLevel;
            look.name = base.look.name;
            Look const& baseLook = data->looks[data->byDisplay.at(base.look.display)];
            look.zones = baseLook.zones;
            look.spells = baseLook.spells;
            look.pins = baseLook.pins;
            data->byDisplay[display] = data->looks.size();
            data->looks.push_back(look);
            data->shinyByModel[model].push_back(display);
            data->shinyDisplays.insert(display);
            ++families[look.family].shinyLooks;
            ++data->shinyTotal;
        }

        // A beast of the other gender wears its own display; count it as the same look.
        std::vector<std::pair<uint32, std::size_t>> aliases;
        for (auto const& [display, index] : data->byDisplay)
            if (CreatureModelInfo const* info = sObjectMgr->GetCreatureModelInfo(display))
                if (info->modelid_other_gender && !data->byDisplay.count(info->modelid_other_gender))
                    aliases.emplace_back(info->modelid_other_gender, index);
        for (auto const& [display, index] : aliases)
            data->byDisplay.emplace(display, index);

        for (auto& [id, family] : families)
        {
            family.id = id;
            CreatureFamilyEntry const* entry = sCreatureFamilyStore.LookupEntry(id);
            char const* name = entry ? entry->Name[locale] : nullptr;
            if ((!name || !*name) && entry)
                name = entry->Name[LOCALE_enUS];
            family.name = name && *name ? Clean(name) : ("Family " + std::to_string(id));
            family.talentType = entry ? entry->petTalentType : 0;
            family.foodMask = entry ? entry->petFoodMask : 0;
            for (Look const& look : data->looks)
                if (look.family == id && (look.flags & LOOK_EXOTIC))
                    family.exotic = true;
            data->families.push_back(family);
        }

        // The rows the addon gets, and their hash.
        uint32 hash = 2166136261u;
        for (Family const& f : data->families)
        {
            std::string row = std::to_string(f.id) + "," + f.name + "," + (f.exotic ? "1" : "0") + ","
                + std::to_string(f.normalLooks) + "," + std::to_string(f.shinyLooks) + ","
                + std::to_string(f.talentType) + "," + std::to_string(f.foodMask);
            hash = Fnv(hash, row);
            data->familyRows.push_back(std::move(row));
            for (std::string& ability : AbilityRows(f.id))
            {
                hash = Fnv(hash, ability);
                data->abilityRows.push_back(std::move(ability));
            }
        }
        for (Look const& l : data->looks)
        {
            std::string spells;
            for (uint32 spell : l.spells)
                spells += (spells.empty() ? "" : "/") + std::to_string(spell);
            std::string row = std::to_string(l.display) + "," + std::to_string(l.family) + "," + std::to_string(l.flags)
                + "," + std::to_string(l.entry) + "," + std::to_string(l.minLevel) + "," + std::to_string(l.maxLevel)
                + "," + l.name + "," + l.zones + "," + spells;
            hash = Fnv(hash, row);
            data->lookRows.push_back(std::move(row));
        }
        data->hash = hash ? hash : 1;

        for (auto const& [zone, name] : data->zoneNames)
        {
            std::string lower = name;
            std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });
            if (!lower.empty())
                data->zoneByName.emplace(std::move(lower), zone);
        }

        std::size_t pinCount = 0;
        for (auto const& [zone, pins] : data->pinsByZone)
            pinCount += pins.size();
        LOG_INFO("module", "mod-beast-collection: {} beast looks in {} families, {} shiny skins, {} map pins in {} zones ({} ms)",
            data->normalTotal, data->families.size(), data->shinyTotal, pinCount, data->pinsByZone.size(), GetMSTimeDiffToNow(startTime));

        sData = std::move(data);
    }

    std::shared_ptr<Data const> Get()
    {
        return sData;
    }

    Data const* Peek()
    {
        return sData.get();
    }

    Look const* Find(Data const& data, uint32 display)
    {
        auto it = data.byDisplay.find(display);
        return it == data.byDisplay.end() ? nullptr : &data.looks[it->second];
    }

    // MZ:<display>:<zone>,<name>,<pins>;...  MP:<display>:<zone>,<x>,<y>;...  ME:<display>
    void SendMap(Player* player, uint32 display)
    {
        auto data = Get();
        Look const* look = data ? Find(*data, display) : nullptr;
        if (!look)
        {
            Send(player, "ME:" + std::to_string(display));
            return;
        }

        std::vector<std::string> zones;
        std::vector<std::string> pins;
        for (std::size_t i = 0; i < look->pins.size(); ++i)
        {
            Pin const& pin = look->pins[i];
            if (i == 0 || look->pins[i - 1].zone != pin.zone)
            {
                std::size_t count = 0;
                while (i + count < look->pins.size() && look->pins[i + count].zone == pin.zone)
                    ++count;
                auto name = data->zoneNames.find(pin.zone);
                zones.push_back(std::to_string(pin.zone) + "," + (name != data->zoneNames.end() ? name->second : "") + ","
                    + std::to_string(count));
            }
            pins.push_back(std::to_string(pin.zone) + "," + std::to_string(pin.x) + "," + std::to_string(pin.y));
        }

        std::string const id = std::to_string(display);
        SendRows(player, "MZ:" + id, zones);
        SendRows(player, "MP:" + id, pins);
        Send(player, "ME:" + id);
    }

    // ZP:<zone>:<display>,<x>,<y>;...  ZE:<zone>:<pins>:<name as asked>
    void SendZone(Player* player, std::string_view zoneName)
    {
        std::string const asked = Clean(zoneName);
        std::string lower = asked;
        std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });

        auto data = Get();
        if (!data)
        {
            Send(player, "ZE:0:0:" + asked);
            return;
        }
        auto zone = data->zoneByName.find(lower);
        if (zone == data->zoneByName.end())
        {
            Send(player, "ZE:0:0:" + asked);
            return;
        }

        std::vector<std::string> rows;
        if (auto pins = data->pinsByZone.find(zone->second); pins != data->pinsByZone.end())
            for (ZonePin const& pin : pins->second)
                rows.push_back(std::to_string(pin.display) + "," + std::to_string(pin.x) + "," + std::to_string(pin.y));

        std::string const id = std::to_string(zone->second);
        SendRows(player, "ZP:" + id, rows);
        Send(player, "ZE:" + id + ":" + std::to_string(rows.size()) + ":" + asked);
    }
}
