/*
 * mod-beast-collection: the beast-dex and its rewards.
 *
 * The dex is per account: every hunter on it adds to the same collection. A look counts once
 * a pet wearing it comes into the world (tamed, called or summoned), and at login everything the
 * account's hunters already own is counted too, so pets tamed before the module was installed
 * aren't lost.
 *
 * The field guide adds two steps before taming, also per account: a look is found once a hunter
 * targets (or points at) a beast wearing it, and studied once they cast Beast Lore on one. The
 * addon reports what the player targets; the server checks the creature is really there.
 *
 * Released under the MIT License.
 */

#include "BeastCollection.h"

#include "CharacterDatabase.h"
#include "Creature.h"
#include "DBCStores.h"
#include "DatabaseEnv.h"
#include "GameTime.h"
#include "Item.h"
#include "Log.h"
#include "Mail.h"
#include "ObjectAccessor.h"
#include "Pet.h"
#include "Player.h"
#include "QueryResult.h"
#include "WorldSession.h"

#include <map>
#include <mutex>
#include <set>
#include <charconv>
#include <tuple>

namespace BeastCollection::Dex
{
    namespace
    {
        enum RewardType : uint8
        {
            REWARD_LOOKS  = 0,  // `count` normal looks
            REWARD_SHINY  = 1,  // `count` shiny looks
            REWARD_FAMILY = 2,  // every normal look of `family` (0 = of each family)
        };

        struct Reward
        {
            uint32 id = 0;
            uint8 type = 0;
            uint32 count = 0;
            uint32 family = 0;
            uint32 item = 0;
            uint32 itemCount = 1;
            uint32 money = 0;
            uint32 title = 0;
            uint32 spell = 0;
            bool perCharacter = false;
            std::string text;
        };

        using ClaimKey = std::tuple<uint32 /*guid, 0 = account*/, uint32 /*reward*/, uint32 /*family*/>;

        enum SeenLevel : uint8
        {
            SEEN_FOUND   = 1,  // targeted
            SEEN_STUDIED = 2,  // Beast Lore
        };

        struct AccountDex
        {
            std::unordered_set<uint32> displays;
            std::unordered_map<uint32, uint8> seen;  // display -> SeenLevel
            std::set<ClaimKey> claims;
            std::unordered_set<uint32> online;  // characters holding this entry
        };

        std::mutex sLock;
        std::unordered_map<uint32, AccountDex> sDex;  // by account
        std::shared_ptr<std::vector<Reward> const> sRewards = std::make_shared<std::vector<Reward>>();

        std::shared_ptr<std::vector<Reward> const> Rewards()
        {
            std::lock_guard<std::mutex> guard(sLock);
            return sRewards;
        }

        uint32 Account(Player* player)
        {
            return player->GetSession()->GetAccountId();
        }

        struct Counts
        {
            uint32 normal = 0;
            uint32 shiny = 0;
            std::map<uint32, uint32> byFamily;  // normal looks
        };

        Counts Count(Catalog::Data const& catalog, std::unordered_set<uint32> const& displays)
        {
            Counts counts;
            for (uint32 display : displays)
            {
                Catalog::Look const* look = Catalog::Find(catalog, display);
                if (!look || look->display != display)
                    continue;
                if (look->flags & Catalog::LOOK_SHINY)
                    ++counts.shiny;
                else
                {
                    ++counts.normal;
                    ++counts.byFamily[look->family];
                }
            }
            return counts;
        }

        std::string FamilyName(Catalog::Data const& catalog, uint32 family)
        {
            for (Catalog::Family const& f : catalog.families)
                if (f.id == family)
                    return f.name;
            return {};
        }

        void Grant(Player* player, Reward const& reward, std::string const& what)
        {
            Config const& cfg = GetConfig();

            if (reward.item || reward.money)
            {
                CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
                MailDraft draft("Beast Collection: " + what,
                    "Your beast collection is growing. Well done, hunter. Here's a little something for it.\n\n"
                    "- Hemet");
                if (reward.item)
                    if (Item* item = Item::CreateItem(reward.item, std::max<uint32>(1, reward.itemCount), player))
                    {
                        item->SaveToDB(trans);
                        draft.AddItem(item);
                    }
                if (reward.money)
                    draft.AddMoney(reward.money);
                MailSender sender = cfg.rewardMailSender
                    ? MailSender(MAIL_CREATURE, cfg.rewardMailSender)
                    : MailSender(MAIL_NORMAL, player->GetGUID().GetCounter());
                draft.SendMailTo(trans, MailReceiver(player, player->GetGUID().GetCounter()), sender, MAIL_CHECK_MASK_COPIED);
                CharacterDatabase.CommitTransaction(trans);
            }

            if (reward.title)
                if (CharTitlesEntry const* title = sCharTitlesStore.LookupEntry(reward.title))
                    if (!player->HasTitle(title))
                        player->SetTitle(title);

            if (reward.spell && !player->HasSpell(reward.spell))
                player->learnSpell(reward.spell);

            Notify(player, "|cffffd100" + what + "|r! " + (reward.item || reward.money ? "Your reward is in the mail." : "Reward granted."));
            Send(player, "REWARD:" + std::to_string(reward.id) + ":" + Clean(what));
        }

        // Gives this character every reward the account's dex has reached and it hasn't had yet.
        void CheckRewards(Player* player)
        {
            Config const& cfg = GetConfig();
            if (!cfg.rewardsEnabled || player->getClass() != CLASS_HUNTER)
                return;

            auto catalog = Catalog::Get();
            auto rewards = Rewards();
            if (!catalog || rewards->empty())
                return;

            uint32 account = Account(player);
            uint32 guid = player->GetGUID().GetCounter();
            Counts counts;
            std::set<ClaimKey> claims;
            {
                std::lock_guard<std::mutex> guard(sLock);
                auto it = sDex.find(account);
                if (it == sDex.end())
                    return;
                counts = Count(*catalog, it->second.displays);
                claims = it->second.claims;
            }

            std::vector<std::pair<Reward const*, uint32 /*family*/>> due;
            for (Reward const& reward : *rewards)
            {
                switch (reward.type)
                {
                    case REWARD_LOOKS:
                        if (reward.count && counts.normal >= reward.count)
                            due.emplace_back(&reward, 0);
                        break;
                    case REWARD_SHINY:
                        if (reward.count && counts.shiny >= reward.count)
                            due.emplace_back(&reward, 0);
                        break;
                    case REWARD_FAMILY:
                        for (Catalog::Family const& family : catalog->families)
                        {
                            if (reward.family && reward.family != family.id)
                                continue;
                            auto have = counts.byFamily.find(family.id);
                            if (family.normalLooks && have != counts.byFamily.end() && have->second >= family.normalLooks)
                                due.emplace_back(&reward, family.id);
                        }
                        break;
                    default:
                        break;
                }
            }

            for (auto const& [reward, family] : due)
            {
                ClaimKey key{ reward->perCharacter ? guid : 0, reward->id, family };
                {
                    std::lock_guard<std::mutex> guard(sLock);
                    auto it = sDex.find(account);
                    if (it == sDex.end() || !it->second.claims.insert(key).second)
                        continue;
                }
                CharacterDatabase.Execute("INSERT IGNORE INTO `mod_beast_reward_claim` (`account`, `guid`, `reward_id`, `family`, `time`) "
                    "VALUES ({}, {}, {}, {}, {})", account, std::get<0>(key), reward->id, family, GameTime::GetGameTime().count());

                std::string what = reward->text.empty() ? "Beast collection milestone" : reward->text;
                if (family)
                    what += ": " + FamilyName(*catalog, family);
                Grant(player, *reward, what);
            }
        }

        // Adds a look to the account's dex. True if it's new.
        bool Register(Player* player, uint32 display, bool announce)
        {
            auto catalog = Catalog::Get();
            Catalog::Look const* look = catalog ? Catalog::Find(*catalog, display) : nullptr;
            uint32 canonical = look ? look->display : display;
            uint32 account = Account(player);

            Counts counts;
            {
                std::lock_guard<std::mutex> guard(sLock);
                auto it = sDex.find(account);
                if (it == sDex.end() || !it->second.displays.insert(canonical).second)
                    return false;
                if (catalog)
                    counts = Count(*catalog, it->second.displays);
            }

            CharacterDatabase.Execute("INSERT IGNORE INTO `mod_beast_dex` (`account`, `display`, `first_guid`, `first_time`) "
                "VALUES ({}, {}, {}, {})", account, canonical, player->GetGUID().GetCounter(), GameTime::GetGameTime().count());

            if (announce && look && catalog)
            {
                bool shiny = look->flags & Catalog::LOOK_SHINY;
                std::string family = FamilyName(*catalog, look->family);
                std::string progress = shiny
                    ? std::to_string(counts.shiny) + "/" + std::to_string(catalog->shinyTotal) + " shiny"
                    : std::to_string(counts.normal) + "/" + std::to_string(catalog->normalTotal);
                Notify(player, std::string("new ") + (shiny ? "|cffff80ffshiny|r " : "") + "look in your beast-dex: |cffffd100"
                    + look->name + "|r (" + family + "), " + progress + ".");
                Send(player, "NEW:" + std::to_string(canonical) + ":" + std::to_string(counts.normal) + ":" + std::to_string(counts.shiny));
            }
            return true;
        }

        // Normal looks the account has found: seen, studied or tamed.
        uint32 FoundCount(Catalog::Data const& catalog, AccountDex const& dex)
        {
            uint32 found = 0;
            for (Catalog::Look const& look : catalog.looks)
                if (!(look.flags & Catalog::LOOK_SHINY) && (dex.displays.count(look.display) || dex.seen.count(look.display)))
                    ++found;
            return found;
        }

        // Records a beast's look as found or studied. Pushes SEEN:<display>:<level>:<found> when
        // that's news.
        void Discover(Player* player, Creature* creature, uint8 level)
        {
            if (!GetConfig().discovery || player->getClass() != CLASS_HUNTER || IsBot(player))
                return;
            CreatureTemplate const* cinfo = creature->GetCreatureTemplate();
            if (!cinfo || !cinfo->IsTameable(true) || creature->IsPet() || creature->GetOwnerGUID() || creature->GetCharmerGUID())
                return;

            auto catalog = Catalog::Get();
            Catalog::Look const* look = catalog ? Catalog::Find(*catalog, creature->GetNativeDisplayId()) : nullptr;
            if (!look)
                return;
            uint32 const display = look->display;
            uint32 const account = Account(player);

            bool tamed = false;
            bool firstFind = false;
            uint32 found = 0;
            {
                std::lock_guard<std::mutex> guard(sLock);
                auto it = sDex.find(account);
                if (it == sDex.end())
                    return;
                AccountDex& dex = it->second;
                uint8& have = dex.seen[display];
                if (have >= level)
                    return;
                tamed = dex.displays.count(display) != 0;
                firstFind = !have && !tamed;
                have = level;
                found = FoundCount(*catalog, dex);
            }

            CharacterDatabase.Execute("INSERT INTO `mod_beast_seen` (`account`, `display`, `level`, `first_guid`, `first_time`) "
                "VALUES ({}, {}, {}, {}, {}) ON DUPLICATE KEY UPDATE `level` = GREATEST(`level`, VALUES(`level`))",
                account, display, level, player->GetGUID().GetCounter(), GameTime::GetGameTime().count());

            bool const shiny = look->flags & Catalog::LOOK_SHINY;
            std::string const name = (shiny ? "|cffff80ffshiny|r " : "") + std::string("|cffffd100") + look->name + "|r";
            if (level >= SEEN_STUDIED)
                Notify(player, "studied " + name + " with Beast Lore. Its abilities are in your field guide.");
            else if (firstFind)
                Notify(player, "found " + name + " (" + FamilyName(*catalog, look->family) + ")"
                    + (shiny ? "" : ", " + std::to_string(found) + "/" + std::to_string(catalog->normalTotal) + " beasts found") + ".");
            Send(player, "SEEN:" + std::to_string(display) + ":" + std::to_string(level) + ":" + std::to_string(found));
        }
    }

    void LoadRewards()
    {
        auto rewards = std::make_shared<std::vector<Reward>>();
        if (QueryResult result = WorldDatabase.Query("SELECT `id`, `type`, `count`, `family`, `item`, `item_count`, `money`, "
            "`title`, `spell`, `per_character`, `text` FROM `mod_beast_collection_reward` ORDER BY `id`"))
        {
            do
            {
                Field* f = result->Fetch();
                Reward r;
                r.id = f[0].Get<uint32>();
                r.type = f[1].Get<uint8>();
                r.count = f[2].Get<uint32>();
                r.family = f[3].Get<uint32>();
                r.item = f[4].Get<uint32>();
                r.itemCount = f[5].Get<uint32>();
                r.money = f[6].Get<uint32>();
                r.title = f[7].Get<uint32>();
                r.spell = f[8].Get<uint32>();
                r.perCharacter = f[9].Get<uint8>() != 0;
                r.text = f[10].Get<std::string>();
                rewards->push_back(std::move(r));
            } while (result->NextRow());
        }
        LOG_INFO("module", "mod-beast-collection: {} dex rewards", rewards->size());

        std::lock_guard<std::mutex> guard(sLock);
        sRewards = std::move(rewards);
    }

    void OnLogin(Player* player)
    {
        uint32 account = Account(player);
        uint32 guid = player->GetGUID().GetCounter();

        bool load = false;
        {
            std::lock_guard<std::mutex> guard(sLock);
            AccountDex& dex = sDex[account];
            load = dex.online.empty();
            dex.online.insert(guid);
        }

        if (load)
        {
            AccountDex loaded;
            if (QueryResult result = CharacterDatabase.Query("SELECT `display` FROM `mod_beast_dex` WHERE `account` = {}", account))
                do
                    loaded.displays.insert(result->Fetch()[0].Get<uint32>());
                while (result->NextRow());
            if (QueryResult result = CharacterDatabase.Query("SELECT `display`, `level` FROM `mod_beast_seen` WHERE `account` = {}", account))
                do
                {
                    Field* f = result->Fetch();
                    loaded.seen[f[0].Get<uint32>()] = f[1].Get<uint8>();
                } while (result->NextRow());
            if (QueryResult result = CharacterDatabase.Query("SELECT `guid`, `reward_id`, `family` FROM `mod_beast_reward_claim` WHERE `account` = {}", account))
                do
                {
                    Field* f = result->Fetch();
                    loaded.claims.emplace(f[0].Get<uint32>(), f[1].Get<uint32>(), f[2].Get<uint32>());
                } while (result->NextRow());

            std::lock_guard<std::mutex> guard(sLock);
            AccountDex& dex = sDex[account];
            dex.displays.insert(loaded.displays.begin(), loaded.displays.end());
            dex.claims.insert(loaded.claims.begin(), loaded.claims.end());
            for (auto const& [display, level] : loaded.seen)
                dex.seen[display] = std::max(dex.seen[display], level);
        }

        // Count what the account's hunters already have, wherever it is.
        std::vector<uint32> owned = Box::OwnedDisplays(player);
        if (load)
        {
            if (QueryResult result = CharacterDatabase.Query("SELECT DISTINCT p.`modelid` FROM `character_pet` p "
                "JOIN `characters` c ON c.`guid` = p.`owner` WHERE c.`account` = {} AND p.`PetType` = {}", account, uint32(HUNTER_PET)))
                do
                    owned.push_back(result->Fetch()[0].Get<uint32>());
                while (result->NextRow());
            if (QueryResult result = CharacterDatabase.Query("SELECT DISTINCT b.`modelid` FROM `mod_beast_box` b "
                "JOIN `characters` c ON c.`guid` = b.`owner` WHERE c.`account` = {}", account))
                do
                    owned.push_back(result->Fetch()[0].Get<uint32>());
                while (result->NextRow());
        }
        for (uint32 display : owned)
            if (display)
                Register(player, display, false);

        CheckRewards(player);
    }

    void OnLogout(Player* player)
    {
        uint32 account = Account(player);
        std::lock_guard<std::mutex> guard(sLock);
        auto it = sDex.find(account);
        if (it == sDex.end())
            return;
        it->second.online.erase(player->GetGUID().GetCounter());
        if (it->second.online.empty())
            sDex.erase(it);
    }

    void OnPetAdded(Pet* pet)
    {
        Player* owner = pet->GetOwner();
        if (!owner || !owner->GetSession() || IsBot(owner))
            return;
        if (Register(owner, pet->GetNativeDisplayId(), true))
            CheckRewards(owner);
    }

    void SendDex(Player* player)
    {
        uint32 account = Account(player);
        uint32 guid = player->GetGUID().GetCounter();
        std::vector<std::string> owned;
        std::set<ClaimKey> claims;
        {
            std::lock_guard<std::mutex> guard(sLock);
            if (auto it = sDex.find(account); it != sDex.end())
            {
                for (uint32 display : it->second.displays)
                    owned.push_back(std::to_string(display));
                claims = it->second.claims;
            }
        }
        SendRows(player, "O", owned);
        Send(player, "OE:" + std::to_string(owned.size()));

        std::vector<std::string> rows;
        for (Reward const& reward : *Rewards())
        {
            uint32 claimed = 0;
            for (ClaimKey const& key : claims)
                if (std::get<1>(key) == reward.id && std::get<0>(key) == (reward.perCharacter ? guid : 0))
                    ++claimed;
            rows.push_back(std::to_string(reward.id) + "," + std::to_string(reward.type) + "," + std::to_string(reward.count)
                + "," + std::to_string(reward.family) + "," + std::to_string(claimed) + "," + std::to_string(reward.item)
                + "," + std::to_string(reward.money) + "," + Clean(reward.text));
        }
        SendRows(player, "R", rows);
        Send(player, "RE:" + std::to_string(rows.size()));

        std::vector<std::string> seen;
        {
            std::lock_guard<std::mutex> guard(sLock);
            if (auto it = sDex.find(account); it != sDex.end())
                for (auto const& [display, level] : it->second.seen)
                    seen.push_back(std::to_string(display) + "," + std::to_string(level));
        }
        SendRows(player, "S", seen);
        Send(player, "SE:" + std::to_string(seen.size()));
    }

    void HandleSee(Player* player, std::string_view guidText)
    {
        if (guidText.size() > 2 && guidText[0] == '0' && (guidText[1] == 'x' || guidText[1] == 'X'))
            guidText.remove_prefix(2);
        uint64 raw = 0;
        auto result = std::from_chars(guidText.data(), guidText.data() + guidText.size(), raw, 16);
        if (result.ec != std::errc{} || result.ptr != guidText.data() + guidText.size())
            return;

        ObjectGuid const guid(raw);
        if (!guid.IsCreature())
            return;
        // Only what the player's client really has in view.
        Creature* creature = ObjectAccessor::GetCreature(*player, guid);
        if (!creature || !player->HaveAtClient(creature))
            return;
        Discover(player, creature, SEEN_FOUND);
    }

    void OnBeastLore(Player* player, Creature* target)
    {
        Discover(player, target, SEEN_STUDIED);
    }
}
