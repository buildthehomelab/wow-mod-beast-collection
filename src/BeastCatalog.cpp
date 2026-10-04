/*
 * mod-beast-collection: the catalog of beast looks.
 *
 * A look is a creature display (model + skin). The dex lists every look a hunter can tame: the
 * displays of every tameable creature that is spawned somewhere in the world, grouped by family.
 * Each look remembers a beast that wears it, the levels it's found at and, when
 * BeastCollection.Dex.ZoneHints is on, the zones it lives in (worked out from spawn positions
 * at startup).
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
#include "ObjectMgr.h"
#include "Timer.h"
#include "World.h"

#include <algorithm>
#include <map>

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

        // The most common zones among a sample of spawns, "Zone/Zone".
        std::string ZonesOf(std::vector<Spawn> const& spawns, uint32 samples, LocaleConstant locale)
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
            std::sort(sorted.begin(), sorted.end(), [](auto const& a, auto const& b) { return a.second > b.second; });

            std::string out;
            for (std::size_t i = 0; i < sorted.size() && i < 2; ++i)
            {
                AreaTableEntry const* area = sAreaTableStore.LookupEntry(sorted[i].first);
                if (!area)
                    continue;
                char const* name = area->area_name[locale];
                if (!name || !*name)
                    name = area->area_name[LOCALE_enUS];
                if (!name || !*name)
                    continue;
                if (!out.empty())
                    out += '/';
                out += Clean(name);
            }
            return out;
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

        // Assemble.
        std::map<uint32, Family> families;
        for (auto& [display, b] : normal)
        {
            Look& look = b.look;
            if (b.allRare)
                look.flags |= LOOK_RARE;
            look.entry = b.preview ? b.preview->Entry : 0;
            look.name = b.preview ? Clean(b.preview->Name) : "?";
            if (cfg.zoneHints)
                look.zones = ZonesOf(b.spawns, cfg.zoneSamples, locale);
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
            look.zones = data->looks[data->byDisplay.at(base.look.display)].zones;
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
                + std::to_string(f.normalLooks) + "," + std::to_string(f.shinyLooks);
            hash = Fnv(hash, row);
            data->familyRows.push_back(std::move(row));
        }
        for (Look const& l : data->looks)
        {
            std::string row = std::to_string(l.display) + "," + std::to_string(l.family) + "," + std::to_string(l.flags)
                + "," + std::to_string(l.entry) + "," + std::to_string(l.minLevel) + "," + std::to_string(l.maxLevel)
                + "," + l.name + "," + l.zones;
            hash = Fnv(hash, row);
            data->lookRows.push_back(std::move(row));
        }
        data->hash = hash ? hash : 1;

        LOG_INFO("module", "mod-beast-collection: {} beast looks in {} families, {} shiny skins ({} ms)",
            data->normalTotal, data->families.size(), data->shinyTotal, GetMSTimeDiffToNow(startTime));

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
}
