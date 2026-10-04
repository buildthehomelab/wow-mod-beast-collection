-- mod-beast-collection uninstall, characters database. Not run automatically.
--
-- Boxed pets can't go back to the core: it keeps only four stabled pets and the active one. This
-- deletes them, with their spells, auras and cooldowns, so have players call out and stable the
-- pets they want to keep first.

DELETE FROM `pet_aura` WHERE `guid` IN (SELECT `id` FROM `mod_beast_box`);
DELETE FROM `pet_spell` WHERE `guid` IN (SELECT `id` FROM `mod_beast_box`);
DELETE FROM `pet_spell_cooldown` WHERE `guid` IN (SELECT `id` FROM `mod_beast_box`);
DELETE FROM `character_pet_declinedname` WHERE `id` IN (SELECT `id` FROM `mod_beast_box`);

DROP TABLE IF EXISTS `mod_beast_box`;
DROP TABLE IF EXISTS `mod_beast_dex`;
DROP TABLE IF EXISTS `mod_beast_reward_claim`;
