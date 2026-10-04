/*
 * mod-beast-collection: configuration, the addon transport and the hooks.
 *
 * Released under the MIT License.
 */

#include "BeastCollection.h"

#include "Chat.h"
#include "Config.h"
#include "Creature.h"
#include "Pet.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "Spell.h"
#include "SpellInfo.h"
#include "WorldPacket.h"
#include "WorldSession.h"

#include <algorithm>
#include <charconv>
#include <type_traits>
#include <utility>

namespace BeastCollection
{
    namespace
    {
        Config sConfig;

        constexpr uint32 SPELL_TAME_BEAST = 1515;

        // Bots are sessions without a socket. AzerothCore marks them with
        // WorldSession::IsHeadless(); older playerbots core forks have WorldSession::IsBot()
        // instead, and older stock cores have neither. Looking for both at compile time lets the
        // module build on all of them.
        template <typename Session, typename = void>
        struct HasIsHeadless : std::false_type { };

        template <typename Session>
        struct HasIsHeadless<Session, std::void_t<decltype(std::declval<Session&>().IsHeadless())>> : std::true_type { };

        template <typename Session, typename = void>
        struct HasIsBot : std::false_type { };

        template <typename Session>
        struct HasIsBot<Session, std::void_t<decltype(std::declval<Session&>().IsBot())>> : std::true_type { };

        template <typename Session>
        bool IsBotSession(Session* session)
        {
            if constexpr (HasIsHeadless<Session>::value)
                return session->IsHeadless();
            else if constexpr (HasIsBot<Session>::value)
                return session->IsBot();
            else
                return false;
        }

        void SendHello(Player* player)
        {
            auto catalog = Catalog::Get();
            Config const& cfg = GetConfig();
            uint32 flags = 0;
            if (cfg.boxEnabled)
                flags |= 0x1;
            if (cfg.shinyEnabled)
                flags |= 0x2;
            if (cfg.rewardsEnabled)
                flags |= 0x4;
            bool hunter = player->getClass() == CLASS_HUNTER;
            Send(player, "HELLO:" + std::to_string(PROTOCOL_VERSION)
                + ":" + std::to_string(catalog ? catalog->hash : 0)
                + ":" + std::to_string(catalog ? catalog->normalTotal : 0)
                + ":" + std::to_string(catalog ? catalog->shinyTotal : 0)
                + ":" + std::to_string(cfg.swapCooldownMs)
                + ":" + std::to_string(flags)
                + ":" + (hunter ? "1" : "0"));
        }

        void SendCatalog(Player* player)
        {
            auto catalog = Catalog::Get();
            if (!catalog)
            {
                Send(player, "ERR:CAT:notready");
                return;
            }
            SendRows(player, "F", catalog->familyRows);
            SendRows(player, "C", catalog->lookRows);
            Send(player, "CE:" + std::to_string(catalog->hash) + ":" + std::to_string(catalog->looks.size()));
        }

        void Dispatch(Player* player, std::string_view msg)
        {
            std::string_view command = msg;
            std::string_view arg;
            if (std::size_t colon = msg.find(':'); colon != std::string_view::npos)
            {
                command = msg.substr(0, colon);
                arg = msg.substr(colon + 1);
            }

            uint32 number = 0;
            if (command == "H")
                SendHello(player);
            else if (command == "CAT")
                SendCatalog(player);
            else if (command == "DEX")
                Dex::SendDex(player);
            else if (command == "PETS")
                Box::SendPets(player);
            else if (command == "CALL" && ParseUInt(arg, number))
                Box::HandleCall(player, number);
            else if (command == "STORE" && ParseUInt(arg, number))
                Box::HandleStore(player, number);
            else if (command == "FREE" && ParseUInt(arg, number))
                Box::HandleRelease(player, number);
            else
                Send(player, "ERR:" + std::string(command) + ":unknown");
        }
    }

    Config& GetConfig()
    {
        return sConfig;
    }

    void LoadConfig()
    {
        Config& c = sConfig;
        c.enabled = sConfigMgr->GetOption<bool>("BeastCollection.Enable", true);

        c.boxEnabled = sConfigMgr->GetOption<bool>("BeastCollection.Box.Enable", true);
        c.boxMaxPets = sConfigMgr->GetOption<uint32>("BeastCollection.Box.MaxPets", 0);
        c.autoStoreOnTame = sConfigMgr->GetOption<bool>("BeastCollection.Box.AutoStoreOnTame", true);
        c.swapCooldownMs = std::min<uint32>(sConfigMgr->GetOption<uint32>("BeastCollection.Box.SwapCooldown", 10), 3600) * IN_MILLISECONDS;
        c.swapInInstances = sConfigMgr->GetOption<bool>("BeastCollection.Box.SwapInInstances", true);

        c.zoneHints = sConfigMgr->GetOption<bool>("BeastCollection.Dex.ZoneHints", true);
        c.zoneSamples = std::clamp<uint32>(sConfigMgr->GetOption<uint32>("BeastCollection.Dex.ZoneSamples", 4), 1, 50);

        c.shinyEnabled = sConfigMgr->GetOption<bool>("BeastCollection.Shiny.Enable", true);
        c.shinyChance = std::clamp(sConfigMgr->GetOption<float>("BeastCollection.Shiny.Chance", 1.0f), 0.0f, 100.0f);
        c.shinyAura = sConfigMgr->GetOption<uint32>("BeastCollection.Shiny.Aura", 58042);
        c.shinyUnusedSkins = sConfigMgr->GetOption<bool>("BeastCollection.Shiny.UnusedSkins", false);
        c.shinyInInstances = sConfigMgr->GetOption<bool>("BeastCollection.Shiny.InInstances", true);
        c.shinyPetSparkle = sConfigMgr->GetOption<bool>("BeastCollection.Shiny.PetSparkle", true);

        c.rewardsEnabled = sConfigMgr->GetOption<bool>("BeastCollection.Rewards.Enable", true);
        c.rewardMailSender = sConfigMgr->GetOption<uint32>("BeastCollection.Rewards.MailSender", 715);
    }

    void Send(Player* player, std::string const& payload)
    {
        if (!player || !player->GetSession())
            return;

        std::string full = std::string(PREFIX) + "\t" + payload;

        WorldPacket data;
        ChatHandler::BuildChatPacket(data, CHAT_MSG_WHISPER, LANG_ADDON, player, player, full);
        player->GetSession()->SendPacket(&data);
    }

    void SendRows(Player* player, std::string const& header, std::vector<std::string> const& rows)
    {
        std::string line;
        std::size_t const budget = MAX_PAYLOAD - header.size() - 1;
        for (std::string const& row : rows)
        {
            if (!line.empty() && line.size() + 1 + row.size() > budget)
            {
                Send(player, header + ":" + line);
                line.clear();
            }
            if (!line.empty())
                line += ';';
            line += row;
        }
        if (!line.empty())
            Send(player, header + ":" + line);
    }

    std::string Clean(std::string_view text)
    {
        std::string out;
        out.reserve(text.size());
        for (char c : text)
        {
            if (c == ';' || c == ',' || c == ':' || c == '|' || c == '\t' || c == '\n' || c == '\r')
                out += ' ';
            else
                out += c;
        }
        return out;
    }

    bool ParseUInt(std::string_view text, uint32& out)
    {
        if (text.empty())
            return false;
        auto result = std::from_chars(text.data(), text.data() + text.size(), out, 10);
        return result.ec == std::errc{} && result.ptr == text.data() + text.size();
    }

    void Notify(Player* player, std::string const& text)
    {
        if (player && player->GetSession())
            ChatHandler(player->GetSession()).SendSysMessage("|cffb48c4bBeast Collection:|r " + text);
    }

    bool IsBot(Player* player)
    {
        WorldSession* session = player ? player->GetSession() : nullptr;
        return session && IsBotSession(session);
    }
}

using namespace BeastCollection;

class BeastCollectionWorldScript : public WorldScript
{
public:
    BeastCollectionWorldScript() : WorldScript("BeastCollectionWorldScript",
        {
            WORLDHOOK_ON_AFTER_CONFIG_LOAD,
            WORLDHOOK_ON_STARTUP
        }) { }

    void OnAfterConfigLoad(bool reload) override
    {
        LoadConfig();
        if (reload)
            Dex::LoadRewards();
    }

    void OnStartup() override
    {
        Box::ReservePetNumbers();
        Shiny::ApplySpellChanges();
        Catalog::Build();
        Dex::LoadRewards();
    }
};

class BeastCollectionPlayerScript : public PlayerScript
{
public:
    BeastCollectionPlayerScript() : PlayerScript("BeastCollectionPlayerScript",
        {
            PLAYERHOOK_CAN_PLAYER_USE_PRIVATE_CHAT,
            PLAYERHOOK_ON_LOGIN,
            PLAYERHOOK_ON_LOGOUT,
            PLAYERHOOK_ON_DELETE
        }) { }

    // The addon whispers itself; swallow those messages so they never show up as chat.
    bool OnPlayerCanUseChat(Player* player, uint32 /*type*/, uint32 lang, std::string& msg, Player* receiver) override
    {
        if (lang != LANG_ADDON || !receiver || receiver != player)
            return true;

        std::string const prefixTab = std::string(PREFIX) + "\t";
        if (msg.compare(0, prefixTab.size(), prefixTab) != 0)
            return true;

        if (!GetConfig().enabled)
        {
            Send(player, "OFF:0");
            return false;
        }

        Dispatch(player, std::string_view(msg).substr(prefixTab.size()));
        return false;
    }

    void OnPlayerLogin(Player* player) override
    {
        if (!GetConfig().enabled || IsBot(player))
            return;
        Box::OnLogin(player);
        Dex::OnLogin(player);
    }

    void OnPlayerLogout(Player* player) override
    {
        Box::OnLogout(player);
        Dex::OnLogout(player);
    }

    void OnPlayerDelete(ObjectGuid guid, uint32 /*accountId*/) override
    {
        Box::OnCharacterDeleted(guid.GetCounter());
    }
};

class BeastCollectionPetScript : public PetScript
{
public:
    BeastCollectionPetScript() : PetScript("BeastCollectionPetScript", { PETHOOK_ON_PET_ADD_TO_WORLD }) { }

    void OnPetAddToWorld(Pet* pet) override
    {
        if (!GetConfig().enabled || !pet || pet->getPetType() != HUNTER_PET)
            return;
        Shiny::OnPetAdded(pet);
        Dex::OnPetAdded(pet);
    }
};

class BeastCollectionCreatureScript : public AllCreatureScript
{
public:
    BeastCollectionCreatureScript() : AllCreatureScript("BeastCollectionCreatureScript") { }

    void OnCreatureSelectLevel(CreatureTemplate const* cinfo, Creature* creature) override
    {
        Shiny::OnSelectLevel(cinfo, creature);
    }

    void OnAllCreatureUpdate(Creature* creature, uint32 /*diff*/) override
    {
        Shiny::OnCreatureUpdate(creature);
    }
};

class BeastCollectionSpellScript : public AllSpellScript
{
public:
    BeastCollectionSpellScript() : AllSpellScript("BeastCollectionSpellScript", { ALLSPELLHOOK_ON_SPELL_CHECK_CAST }) { }

    // Runs before Tame Beast's own checks, which fail while the hunter has a pet.
    void OnSpellCheckCast(Spell* spell, bool strict, SpellCastResult& res) override
    {
        if (!strict || res != SPELL_CAST_OK || spell->GetSpellInfo()->Id != SPELL_TAME_BEAST)
            return;
        Player* player = spell->GetCaster() ? spell->GetCaster()->ToPlayer() : nullptr;
        Unit* target = spell->m_targets.GetUnitTarget();
        if (player && target && target->IsCreature())
            Box::OnTameCheck(player, target->ToCreature());
    }
};

void AddBeastCollectionScripts()
{
    new BeastCollectionWorldScript();
    new BeastCollectionPlayerScript();
    new BeastCollectionPetScript();
    new BeastCollectionCreatureScript();
    new BeastCollectionSpellScript();
}
