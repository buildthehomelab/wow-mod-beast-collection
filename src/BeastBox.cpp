/*
 * mod-beast-collection: the box.
 *
 * Moving a pet between character_pet and mod_beast_box rewrites its row from what the server
 * holds in memory (PetStable::PetInfo, which the core refreshes whenever it saves a pet), in the
 * same transaction that deletes the old row.
 *
 * The writes don't count on the character database's asynchronous queue running in order: with
 * CharacterDatabase.WorkerThreads above 1, two queued writes can land either way round.
 *   - Boxing: RemovePet's save and the move to the box are separate writes. If the save lands
 *     last, the pet is in both tables, unslotted in character_pet. The core deletes unslotted
 *     hunter pet rows on its next pet save, so login keeps the box copy then (it keeps the
 *     character_pet copy only when the pet is current or stabled there).
 *   - Calling from the box: the row goes back into character_pet already marked current. As a
 *     dismissed (unslotted) row it could land after the old pet's save, and that save deletes
 *     every unslotted hunter pet row of the owner.
 *
 * Released under the MIT License.
 */

#include "BeastCollection.h"

#include "CharacterDatabase.h"
#include "Creature.h"
#include "DatabaseEnv.h"
#include "GameTime.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Pet.h"
#include "Player.h"
#include "QueryResult.h"
#include "WorldSession.h"

#include <algorithm>
#include <mutex>

namespace BeastCollection::Box
{
    namespace
    {
        enum PetFlags : uint32
        {
            PET_ACTIVE    = 0x01,  // at the hunter's side (or dismissed: also PET_DISMISSED)
            PET_STABLE    = 0x02,
            PET_BOX       = 0x04,
            PET_DEAD      = 0x08,
            PET_SHINY     = 0x10,
            PET_EXOTIC    = 0x20,
            PET_DISMISSED = 0x40,
        };

        // Map threads (taming) and the world thread (addon requests) both reach the boxes.
        std::mutex sLock;
        std::unordered_map<uint32, std::vector<Entry>> sBoxes;  // by character guid
        std::unordered_map<uint32, uint64> sSwapReadyAt;         // by character guid, game time ms

        std::string Escaped(std::string text)
        {
            CharacterDatabase.EscapeString(text);
            return text;
        }

        uint32 Guid(Player* player)
        {
            return player->GetGUID().GetCounter();
        }

        std::size_t BoxSize(uint32 guid)
        {
            std::lock_guard<std::mutex> guard(sLock);
            auto it = sBoxes.find(guid);
            return it == sBoxes.end() ? 0 : it->second.size();
        }

        bool BoxFull(uint32 guid)
        {
            uint32 max = GetConfig().boxMaxPets;
            return max && BoxSize(guid) >= max;
        }

        // Takes a pet out of the cache; false if it isn't in this character's box.
        bool TakeFromCache(uint32 guid, uint32 petNumber, Entry& out)
        {
            std::lock_guard<std::mutex> guard(sLock);
            auto box = sBoxes.find(guid);
            if (box == sBoxes.end())
                return false;
            auto it = std::find_if(box->second.begin(), box->second.end(),
                [petNumber](Entry const& e) { return e.info.PetNumber == petNumber; });
            if (it == box->second.end())
                return false;
            out = std::move(*it);
            box->second.erase(it);
            return true;
        }

        void AppendBoxRow(CharacterDatabaseTransaction trans, uint32 owner, PetStable::PetInfo const& p, uint32 boxedAt)
        {
            trans->Append("REPLACE INTO `mod_beast_box` (`id`, `entry`, `owner`, `modelid`, `CreatedBySpell`, `PetType`, "
                "`level`, `exp`, `Reactstate`, `name`, `renamed`, `curhealth`, `curmana`, `curhappiness`, `savetime`, "
                "`abdata`, `boxed_at`) VALUES ({}, {}, {}, {}, {}, {}, {}, {}, {}, '{}', {}, {}, {}, {}, {}, '{}', {})",
                p.PetNumber, p.CreatureId, owner, p.DisplayId, p.CreatedBySpellId, uint32(p.Type), uint32(p.Level),
                p.Experience, uint32(p.ReactState), Escaped(p.Name), p.WasRenamed ? 1 : 0, p.Health, p.Mana,
                p.Happiness, p.LastSaveTime, Escaped(p.ActionBar), boxedAt);
        }

        // character_pet -> box. The caller has taken the pet out of the PetStable.
        void MoveToBox(uint32 owner, PetStable::PetInfo const& info)
        {
            uint32 now = uint32(GameTime::GetGameTime().count());
            CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
            AppendBoxRow(trans, owner, info, now);
            trans->Append("DELETE FROM `character_pet` WHERE `id` = {} AND `owner` = {}", info.PetNumber, owner);
            CharacterDatabase.CommitTransaction(trans);

            std::lock_guard<std::mutex> guard(sLock);
            sBoxes[owner].push_back({ info, now });
        }

        // box -> character_pet, in the given slot. The caller has taken it out of the cache.
        void MoveFromBox(uint32 owner, PetStable::PetInfo const& p, PetSaveMode slot)
        {
            CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
            CharacterDatabasePreparedStatement* stmt = CharacterDatabase.GetPreparedStatement(CHAR_REP_CHAR_PET);
            stmt->SetData(0, p.PetNumber);
            stmt->SetData(1, p.CreatureId);
            stmt->SetData(2, owner);
            stmt->SetData(3, p.DisplayId);
            stmt->SetData(4, p.CreatedBySpellId);
            stmt->SetData(5, uint8(p.Type));
            stmt->SetData(6, p.Level);
            stmt->SetData(7, p.Experience);
            stmt->SetData(8, uint8(p.ReactState));
            stmt->SetData(9, p.Name);
            stmt->SetData(10, uint8(p.WasRenamed ? 1 : 0));
            stmt->SetData(11, uint8(slot));
            stmt->SetData(12, p.Health);
            stmt->SetData(13, p.Mana);
            stmt->SetData(14, p.Happiness);
            stmt->SetData(15, p.LastSaveTime);
            stmt->SetData(16, p.ActionBar);
            trans->Append(stmt);
            trans->Append("DELETE FROM `mod_beast_box` WHERE `id` = {}", p.PetNumber);
            CharacterDatabase.CommitTransaction(trans);
        }

        // Forget a pet for good: its row and everything kept under its id.
        void DeletePetData(CharacterDatabaseTransaction trans, std::string const& idSql)
        {
            trans->Append("DELETE FROM `pet_aura` WHERE `guid` IN ({})", idSql);
            trans->Append("DELETE FROM `pet_spell` WHERE `guid` IN ({})", idSql);
            trans->Append("DELETE FROM `pet_spell_cooldown` WHERE `guid` IN ({})", idSql);
            trans->Append("DELETE FROM `character_pet_declinedname` WHERE `id` IN ({})", idSql);
        }

        bool IsHunter(Player* player)
        {
            return player->IsClass(CLASS_HUNTER, CLASS_CONTEXT_PET);
        }

        std::string PetName(PetStable const& stable)
        {
            if (stable.CurrentPet)
                return stable.CurrentPet->Name;
            for (PetStable::PetInfo const& pet : stable.UnslottedPets)
                if (pet.Type == HUNTER_PET)
                    return pet.Name;
            return {};
        }

        bool HasPetToStore(PetStable const& stable)
        {
            if (stable.CurrentPet && stable.CurrentPet->Type == HUNTER_PET)
                return true;
            return std::any_of(stable.UnslottedPets.begin(), stable.UnslottedPets.end(),
                [](PetStable::PetInfo const& pet) { return pet.Type == HUNTER_PET; });
        }

        // Sends the hunter's current pet (out, dismissed or dead) to the box.
        void StoreCurrent(Player* player)
        {
            PetStable* stable = player->GetPetStable();
            if (!stable)
                return;

            if (Pet* pet = player->GetPet())
            {
                if (pet->getPetType() == HUNTER_PET)
                    player->RemovePet(pet, PET_SAVE_NOT_IN_SLOT);
            }
            else if (stable->CurrentPet && stable->CurrentPet->Type == HUNTER_PET)
                player->RemovePet(nullptr, PET_SAVE_NOT_IN_SLOT);

            // It would be summoned back after a mount or a teleport otherwise.
            player->SetTemporaryUnsummonedPetNumber(0);

            uint32 owner = Guid(player);
            for (auto it = stable->UnslottedPets.begin(); it != stable->UnslottedPets.end();)
            {
                if (it->Type != HUNTER_PET)
                {
                    ++it;
                    continue;
                }
                MoveToBox(owner, *it);
                it = stable->UnslottedPets.erase(it);
            }
        }

        // Why a pet can't be called right now, or empty.
        std::string CallBlocker(Player* player)
        {
            if (!player->IsAlive())
                return "dead";
            if (player->IsInCombat())
                return "combat";
            if (player->IsMounted() || player->IsInFlight() || player->GetVehicle())
                return "mounted";
            if (player->InArena())
                return "arena";
            if (!GetConfig().swapInInstances && player->GetMap() && player->GetMap()->Instanceable())
                return "instance";
            if (player->GetCharmGUID())
                return "charm";
            return {};
        }

        uint64 CooldownLeft(uint32 guid)
        {
            uint64 now = uint64(GameTime::GetGameTimeMS().count());
            std::lock_guard<std::mutex> guard(sLock);
            auto it = sSwapReadyAt.find(guid);
            return it != sSwapReadyAt.end() && it->second > now ? it->second - now : 0;
        }

        void StartCooldown(uint32 guid)
        {
            uint32 cooldown = GetConfig().swapCooldownMs;
            if (!cooldown)
                return;
            std::lock_guard<std::mutex> guard(sLock);
            sSwapReadyAt[guid] = uint64(GameTime::GetGameTimeMS().count()) + cooldown;
        }

        std::string PetRow(PetStable::PetInfo const& info, uint32 flags, Catalog::Data const* catalog)
        {
            uint32 family = 0;
            if (CreatureTemplate const* cinfo = sObjectMgr->GetCreatureTemplate(info.CreatureId))
            {
                family = cinfo->family;
                if (cinfo->IsExotic())
                    flags |= PET_EXOTIC;
            }
            if (!info.Health)
                flags |= PET_DEAD;
            if (catalog && catalog->shinyDisplays.count(info.DisplayId))
                flags |= PET_SHINY;
            return std::to_string(info.PetNumber) + "," + std::to_string(info.CreatureId) + ","
                + std::to_string(info.DisplayId) + "," + std::to_string(uint32(info.Level)) + ","
                + std::to_string(flags) + "," + std::to_string(family) + "," + Clean(info.Name);
        }

        void Fail(Player* player, std::string const& command, std::string const& reason)
        {
            Send(player, "ERR:" + command + ":" + reason);
        }
    }

    void ReservePetNumbers()
    {
        QueryResult result = CharacterDatabase.Query("SELECT MAX(`id`) FROM `mod_beast_box`");
        if (!result)
            return;
        uint32 maxBoxed = result->Fetch()[0].Get<uint32>();
        if (!maxBoxed)
            return;
        // The core starts its counter at MAX(character_pet.id); boxed pets aren't in there.
        uint32 skipped = 0;
        while (sObjectMgr->GeneratePetNumber() < maxBoxed)
            ++skipped;
        if (skipped)
            LOG_INFO("module", "mod-beast-collection: pet numbers moved past the box's highest id {} ({} skipped)", maxBoxed, skipped);
    }

    void OnLogin(Player* player)
    {
        uint32 guid = Guid(player);
        std::vector<Entry> entries;

        if (QueryResult result = CharacterDatabase.Query("SELECT `id`, `entry`, `modelid`, `level`, `exp`, `Reactstate`, "
            "`name`, `renamed`, `curhealth`, `curmana`, `curhappiness`, `abdata`, `savetime`, `CreatedBySpell`, "
            "`PetType`, `boxed_at` FROM `mod_beast_box` WHERE `owner` = {}", guid))
        {
            do
            {
                Field* f = result->Fetch();
                Entry e;
                e.info.PetNumber = f[0].Get<uint32>();
                e.info.CreatureId = f[1].Get<uint32>();
                e.info.DisplayId = f[2].Get<uint32>();
                e.info.Level = uint8(f[3].Get<uint16>());
                e.info.Experience = f[4].Get<uint32>();
                e.info.ReactState = ReactStates(f[5].Get<uint8>());
                e.info.Name = f[6].Get<std::string>();
                e.info.WasRenamed = f[7].Get<bool>();
                e.info.Health = f[8].Get<uint32>();
                e.info.Mana = f[9].Get<uint32>();
                e.info.Happiness = f[10].Get<uint32>();
                e.info.ActionBar = f[11].Get<std::string>();
                e.info.LastSaveTime = f[12].Get<uint32>();
                e.info.CreatedBySpellId = f[13].Get<uint32>();
                e.info.Type = PetType(f[14].Get<uint8>());
                e.boxedAt = f[15].Get<uint32>();
                entries.push_back(std::move(e));
            } while (result->NextRow());
        }

        // A pet both here and in character_pet. Current or stabled there, the core has it, so
        // it stays there. Unslotted there, it's a save that landed after the pet was boxed: the
        // core would delete that row on its next pet save, so the box keeps it.
        if (PetStable* stable = player->GetPetStable())
        {
            auto slotted = [stable](uint32 number)
            {
                if (stable->CurrentPet && stable->CurrentPet->PetNumber == number)
                    return true;
                for (auto const& slot : stable->StabledPets)
                    if (slot && slot->PetNumber == number)
                        return true;
                return false;
            };
            for (auto it = entries.begin(); it != entries.end();)
            {
                uint32 const number = it->info.PetNumber;
                auto unslotted = std::find_if(stable->UnslottedPets.begin(), stable->UnslottedPets.end(),
                    [number](PetStable::PetInfo const& p) { return p.PetNumber == number && p.Type == HUNTER_PET; });
                if (slotted(number))
                {
                    LOG_WARN("module", "mod-beast-collection: pet {} of {} was boxed and slotted in character_pet; keeping character_pet",
                        number, guid);
                    CharacterDatabase.Execute("DELETE FROM `mod_beast_box` WHERE `id` = {}", number);
                    it = entries.erase(it);
                    continue;
                }
                if (unslotted != stable->UnslottedPets.end())
                {
                    LOG_WARN("module", "mod-beast-collection: pet {} of {} was boxed and unslotted in character_pet; keeping the box",
                        number, guid);
                    CharacterDatabase.Execute("DELETE FROM `character_pet` WHERE `id` = {} AND `owner` = {}", number, guid);
                    stable->UnslottedPets.erase(unslotted);
                }
                ++it;
            }
        }

        std::lock_guard<std::mutex> guard(sLock);
        sBoxes[guid] = std::move(entries);
    }

    void OnLogout(Player* player)
    {
        uint32 guid = Guid(player);
        std::lock_guard<std::mutex> guard(sLock);
        sBoxes.erase(guid);
        sSwapReadyAt.erase(guid);
    }

    void OnCharacterDeleted(uint32 guidLow)
    {
        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        DeletePetData(trans, "SELECT `id` FROM `mod_beast_box` WHERE `owner` = " + std::to_string(guidLow));
        trans->Append("DELETE FROM `mod_beast_box` WHERE `owner` = {}", guidLow);
        CharacterDatabase.CommitTransaction(trans);
    }

    void OnTameCheck(Player* player, Creature* target)
    {
        Config const& cfg = GetConfig();
        if (!cfg.enabled || !cfg.boxEnabled || !cfg.autoStoreOnTame || IsBot(player) || !IsHunter(player))
            return;

        PetStable* stable = player->GetPetStable();
        if (!stable || !HasPetToStore(*stable))
            return;

        // Only when the tame would otherwise go through, so a failed attempt doesn't put the pet
        // away for nothing. These are Tame Beast's own checks (spell_hun_tame_beast), plus the
        // range, sight and movement checks that come after them.
        CreatureTemplate const* cinfo = target->GetCreatureTemplate();
        if (!cinfo || target->IsPet() || target->GetOwnerGUID() || !target->IsAlive()
            || target->GetLevel() > player->GetLevel() || !cinfo->IsTameable(player->CanTameExoticPets())
            || player->GetCharmGUID() || player->isMoving()
            || !player->IsWithinDistInMap(target, 30.0f) || !player->IsWithinLOSInMap(target))
            return;

        if (BoxFull(Guid(player)))
        {
            Notify(player, "your beast box is full; release a beast to tame another.");
            return;
        }

        std::string name = PetName(*stable);
        StoreCurrent(player);
        if (!name.empty())
            Notify(player, name + " went to your beast box to make room.");
        SendPets(player);
    }

    void SendPets(Player* player)
    {
        auto catalog = Catalog::Get();
        Catalog::Data const* data = catalog.get();
        uint32 guid = Guid(player);
        std::vector<std::string> rows;

        if (PetStable const* stable = player->GetPetStable())
        {
            if (stable->CurrentPet && stable->CurrentPet->Type == HUNTER_PET)
                rows.push_back(PetRow(*stable->CurrentPet, PET_ACTIVE, data));
            for (PetStable::PetInfo const& pet : stable->UnslottedPets)
                if (pet.Type == HUNTER_PET)
                    rows.push_back(PetRow(pet, PET_ACTIVE | PET_DISMISSED, data));
            for (auto const& slot : stable->StabledPets)
                if (slot)
                    rows.push_back(PetRow(*slot, PET_STABLE, data));
        }

        std::size_t boxed = 0;
        {
            std::lock_guard<std::mutex> guard(sLock);
            if (auto it = sBoxes.find(guid); it != sBoxes.end())
            {
                boxed = it->second.size();
                for (Entry const& e : it->second)
                    rows.push_back(PetRow(e.info, PET_BOX, data));
            }
        }

        SendRows(player, "P", rows);
        Send(player, "PE:" + std::to_string(rows.size()) + ":" + std::to_string(CooldownLeft(guid)) + ":"
            + std::to_string(boxed) + ":" + std::to_string(GetConfig().boxMaxPets));
    }

    void HandleCall(Player* player, uint32 petNumber)
    {
        Config const& cfg = GetConfig();
        if (!cfg.boxEnabled)
            return Fail(player, "CALL", "disabled");
        if (!IsHunter(player))
            return Fail(player, "CALL", "class");
        if (std::string blocker = CallBlocker(player); !blocker.empty())
            return Fail(player, "CALL", blocker);

        uint32 guid = Guid(player);
        if (uint64 left = CooldownLeft(guid))
            return Fail(player, "CALL", "cooldown," + std::to_string(left));

        PetStable& stable = player->GetOrInitPetStable();
        if (stable.CurrentPet && stable.CurrentPet->PetNumber == petNumber && player->GetPet())
            return Fail(player, "CALL", "active");

        // Where is it?
        enum class From { None, Box, Stable, Dismissed } from = From::None;
        PetStable::PetInfo const* info = nullptr;
        Entry boxed;
        {
            std::lock_guard<std::mutex> guard(sLock);
            if (auto box = sBoxes.find(guid); box != sBoxes.end())
                for (Entry const& e : box->second)
                    if (e.info.PetNumber == petNumber)
                    {
                        boxed = e;
                        from = From::Box;
                    }
        }
        if (from == From::Box)
            info = &boxed.info;
        for (auto const& slot : stable.StabledPets)
            if (from == From::None && slot && slot->PetNumber == petNumber)
            {
                info = &slot.value();
                from = From::Stable;
            }
        for (PetStable::PetInfo const& pet : stable.UnslottedPets)
            if (from == From::None && pet.PetNumber == petNumber && pet.Type == HUNTER_PET)
            {
                info = &pet;
                from = From::Dismissed;
            }
        if (stable.CurrentPet && stable.CurrentPet->PetNumber == petNumber && from == From::None)
        {
            // The current pet, not out (dead and despawned, or held back): Call Pet's job.
            info = &stable.CurrentPet.value();
            from = From::Dismissed;
        }
        if (from == From::None)
            return Fail(player, "CALL", "notfound");

        CreatureTemplate const* cinfo = sObjectMgr->GetCreatureTemplate(info->CreatureId);
        if (!cinfo || !cinfo->IsTameable(player->CanTameExoticPets()))
            return Fail(player, "CALL", cinfo && cinfo->IsTameable(true) ? "exotic" : "nottameable");

        if (from == From::Stable && BoxFull(guid) && HasPetToStore(stable))
            return Fail(player, "CALL", "full");

        std::string name = info->Name;

        // 1. The pet at the hunter's side goes to the box. A dismissed pet just comes back out.
        if (from != From::Dismissed)
            StoreCurrent(player);
        else if (player->GetPet())
            return Fail(player, "CALL", "active");

        // 2. The new one comes out. LoadPetFromDB finds it in the PetStable, so a boxed pet
        //    goes in there first, as an unslotted (dismissed) pet.
        if (from == From::Box)
        {
            Entry taken;
            if (!TakeFromCache(guid, petNumber, taken))
                return Fail(player, "CALL", "notfound");
            // Already marked current: see the top of this file.
            MoveFromBox(guid, taken.info, PET_SAVE_AS_CURRENT);
            stable.UnslottedPets.push_back(taken.info);
        }

        Pet* pet = new Pet(player, HUNTER_PET);
        bool current = from == From::Dismissed && stable.CurrentPet && stable.CurrentPet->PetNumber == petNumber;
        if (!pet->LoadPetFromDB(player, 0, current ? 0 : petNumber, current))
        {
            delete pet;
            // Put a boxed pet back where it was.
            if (from == From::Box)
            {
                auto it = std::find_if(stable.UnslottedPets.begin(), stable.UnslottedPets.end(),
                    [petNumber](PetStable::PetInfo const& p) { return p.PetNumber == petNumber; });
                if (it != stable.UnslottedPets.end())
                {
                    MoveToBox(guid, *it);
                    stable.UnslottedPets.erase(it);
                }
            }
            SendPets(player);
            return Fail(player, "CALL", "failed");
        }

        // As the core's unstable handler does: the row says "current" straight away.
        CharacterDatabasePreparedStatement* stmt = CharacterDatabase.GetPreparedStatement(CHAR_UPD_CHAR_PET_SLOT_BY_ID);
        stmt->SetData(0, uint8(PET_SAVE_AS_CURRENT));
        stmt->SetData(1, guid);
        stmt->SetData(2, petNumber);
        CharacterDatabase.Execute(stmt);

        StartCooldown(guid);
        Send(player, "OK:CALL:" + std::to_string(petNumber));
        SendPets(player);
    }

    void HandleStore(Player* player, uint32 petNumber)
    {
        if (!GetConfig().boxEnabled)
            return Fail(player, "STORE", "disabled");
        if (!IsHunter(player))
            return Fail(player, "STORE", "class");
        if (player->IsInCombat())
            return Fail(player, "STORE", "combat");

        uint32 guid = Guid(player);
        if (BoxFull(guid))
            return Fail(player, "STORE", "full");

        PetStable* stable = player->GetPetStable();
        if (!stable)
            return Fail(player, "STORE", "notfound");

        bool isCurrent = stable->CurrentPet && stable->CurrentPet->PetNumber == petNumber;
        bool isDismissed = std::any_of(stable->UnslottedPets.begin(), stable->UnslottedPets.end(),
            [petNumber](PetStable::PetInfo const& p) { return p.PetNumber == petNumber && p.Type == HUNTER_PET; });
        if (isCurrent || isDismissed)
        {
            StoreCurrent(player);
            Send(player, "OK:STORE:" + std::to_string(petNumber));
            SendPets(player);
            return;
        }

        for (auto& slot : stable->StabledPets)
        {
            if (slot && slot->PetNumber == petNumber)
            {
                MoveToBox(guid, *slot);
                slot.reset();
                Send(player, "OK:STORE:" + std::to_string(petNumber));
                SendPets(player);
                return;
            }
        }
        Fail(player, "STORE", "notfound");
    }

    void HandleRelease(Player* player, uint32 petNumber)
    {
        uint32 guid = Guid(player);
        Entry taken;
        if (!TakeFromCache(guid, petNumber, taken))
            return Fail(player, "FREE", "notfound");

        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        DeletePetData(trans, std::to_string(petNumber));
        trans->Append("DELETE FROM `mod_beast_box` WHERE `id` = {} AND `owner` = {}", petNumber, guid);
        CharacterDatabase.CommitTransaction(trans);

        Send(player, "OK:FREE:" + std::to_string(petNumber));
        SendPets(player);
    }

    std::vector<uint32> OwnedDisplays(Player* player)
    {
        std::vector<uint32> displays;
        if (PetStable const* stable = player->GetPetStable())
        {
            if (stable->CurrentPet && stable->CurrentPet->Type == HUNTER_PET)
                displays.push_back(stable->CurrentPet->DisplayId);
            for (auto const& slot : stable->StabledPets)
                if (slot)
                    displays.push_back(slot->DisplayId);
            for (PetStable::PetInfo const& pet : stable->UnslottedPets)
                if (pet.Type == HUNTER_PET)
                    displays.push_back(pet.DisplayId);
        }
        std::lock_guard<std::mutex> guard(sLock);
        if (auto it = sBoxes.find(Guid(player)); it != sBoxes.end())
            for (Entry const& e : it->second)
                displays.push_back(e.info.DisplayId);
        return displays;
    }
}
