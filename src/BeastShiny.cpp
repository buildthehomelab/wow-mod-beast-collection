/*
 * mod-beast-collection: shiny spawns.
 *
 * Each time a tameable beast spawns or respawns, it has BeastCollection.Shiny.Chance percent to
 * come out shiny: it wears one of the other skins of its own model (see BeastCatalog.cpp) and
 * sparkles. Respawning rolls again, and a beast that comes back plain gets its own skin back.
 *
 * The skin goes on in the creature's level selection hook, which runs as it spawns and, on a
 * respawn, just before the core reapplies the creature's "native" display, so setting both the
 * display and the native display makes it stick until the next respawn. A tamed shiny keeps the
 * skin: the pet takes its display from the creature.
 *
 * The sparkle is a stock visual aura (Treasure Sparkle by default). Evading would wipe it, so
 * it's marked to survive that, and the creature update hook puts it back on a shiny that lost it.
 *
 * Released under the MIT License.
 */

#include "BeastCollection.h"

#include "Creature.h"
#include "DBCStores.h"
#include "Map.h"
#include "ObjectMgr.h"
#include "Pet.h"
#include "Random.h"
#include "SpellInfo.h"
#include "SpellMgr.h"

namespace BeastCollection::Shiny
{
    namespace
    {
        bool Eligible(CreatureTemplate const* cinfo, Creature* creature)
        {
            return cinfo && creature->GetSpawnId() && !creature->IsPet() && !creature->IsSummon()
                && cinfo->IsTameable(true);
        }

        uint32 ModelOf(uint32 display)
        {
            CreatureDisplayInfoEntry const* info = sCreatureDisplayInfoStore.LookupEntry(display);
            return info ? info->ModelId : 0;
        }

        void SetSkin(Creature* creature, uint32 display)
        {
            creature->SetDisplayId(display);
            creature->SetNativeDisplayId(display);
        }
    }

    void ApplySpellChanges()
    {
        Config const& cfg = GetConfig();
        if (!cfg.shinyAura)
            return;
        if (SpellInfo* info = const_cast<SpellInfo*>(sSpellMgr->GetSpellInfo(cfg.shinyAura)))
            info->AttributesCu |= SPELL_ATTR0_CU_IGNORE_EVADE | SPELL_ATTR0_CU_AURA_CANNOT_BE_SAVED;
    }

    void OnSelectLevel(CreatureTemplate const* cinfo, Creature* creature)
    {
        Config const& cfg = GetConfig();
        if (!cfg.enabled || !cfg.shinyEnabled || !Eligible(cinfo, creature))
            return;
        // Only as it spawns or respawns, not when something changes its entry while it's up.
        if (creature->IsInWorld() && creature->IsAlive())
            return;

        auto catalog = Catalog::Get();
        if (!catalog || catalog->shinyByModel.empty())
            return;

        uint32 current = creature->GetNativeDisplayId();
        bool wasShiny = catalog->shinyDisplays.count(current) != 0;
        uint32 base = current;
        if (wasShiny)
        {
            CreatureModel const* model = ObjectMgr::ChooseDisplayId(cinfo, creature->GetCreatureData());
            base = model ? model->CreatureDisplayID : 0;
        }

        bool roll = cfg.shinyChance > 0.0f && roll_chance_f(cfg.shinyChance);
        if (roll && (cfg.shinyInInstances || !creature->GetMap() || !creature->GetMap()->Instanceable()))
        {
            auto skins = catalog->shinyByModel.find(ModelOf(base));
            if (skins != catalog->shinyByModel.end() && !skins->second.empty())
            {
                SetSkin(creature, Acore::Containers::SelectRandomContainerElement(skins->second));
                return;
            }
        }

        if (wasShiny && base)
            SetSkin(creature, base);
    }

    void OnCreatureUpdate(Creature* creature)
    {
        Config const& cfg = GetConfig();
        if (!cfg.shinyAura || !cfg.shinyEnabled || !creature->IsAlive() || !creature->GetSpawnId())
            return;
        CreatureTemplate const* cinfo = creature->GetCreatureTemplate();
        if (!cinfo || !(cinfo->type_flags & CREATURE_TYPE_FLAG_TAMEABLE))
            return;
        Catalog::Data const* catalog = Catalog::Peek();
        if (!catalog || !catalog->shinyDisplays.count(creature->GetNativeDisplayId()))
            return;
        if (!creature->HasAura(cfg.shinyAura))
            creature->AddAura(cfg.shinyAura, creature);
    }

    void OnPetAdded(Pet* pet)
    {
        Config const& cfg = GetConfig();
        if (!cfg.shinyEnabled || !cfg.shinyPetSparkle || !cfg.shinyAura)
            return;
        Catalog::Data const* catalog = Catalog::Peek();
        if (catalog && catalog->shinyDisplays.count(pet->GetNativeDisplayId()) && !pet->HasAura(cfg.shinyAura))
            pet->AddAura(cfg.shinyAura, pet);
    }
}
