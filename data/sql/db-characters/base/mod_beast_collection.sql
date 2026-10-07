-- mod-beast-collection: the pet box, the account-wide beast-dex, field guide finds and claimed rewards.

-- Boxed hunter pets. The same columns as character_pet: a pet moves here when it goes into the
-- box and back when it's called out. Its spells, auras and cooldowns stay in pet_spell, pet_aura
-- and pet_spell_cooldown under the same id the whole time.
CREATE TABLE IF NOT EXISTS `mod_beast_box` (
    `id`             INT UNSIGNED      NOT NULL,
    `entry`          INT UNSIGNED      NOT NULL DEFAULT 0,
    `owner`          INT UNSIGNED      NOT NULL DEFAULT 0,
    `modelid`        INT UNSIGNED      NOT NULL DEFAULT 0,
    `CreatedBySpell` INT UNSIGNED      NOT NULL DEFAULT 0,
    `PetType`        TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `level`          SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `exp`            INT UNSIGNED      NOT NULL DEFAULT 0,
    `Reactstate`     TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `name`           VARCHAR(21) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'Pet',
    `renamed`        TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `curhealth`      INT UNSIGNED      NOT NULL DEFAULT 1,
    `curmana`        INT UNSIGNED      NOT NULL DEFAULT 0,
    `curhappiness`   INT UNSIGNED      NOT NULL DEFAULT 0,
    `savetime`       INT UNSIGNED      NOT NULL DEFAULT 0,
    `abdata`         TEXT,
    `boxed_at`       INT UNSIGNED      NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    KEY `idx_owner` (`owner`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='mod-beast-collection: boxed hunter pets';

-- Every beast look an account has tamed, by creature display id.
CREATE TABLE IF NOT EXISTS `mod_beast_dex` (
    `account`    INT UNSIGNED NOT NULL,
    `display`    INT UNSIGNED NOT NULL,
    `first_guid` INT UNSIGNED NOT NULL DEFAULT 0,
    `first_time` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`account`, `display`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='mod-beast-collection: account beast-dex';

-- Field guide: beast looks an account has found (1, targeted) or studied (2, Beast Lore).
-- Tamed looks are in mod_beast_dex.
CREATE TABLE IF NOT EXISTS `mod_beast_seen` (
    `account`    INT UNSIGNED     NOT NULL,
    `display`    INT UNSIGNED     NOT NULL,
    `level`      TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `first_guid` INT UNSIGNED     NOT NULL DEFAULT 0,
    `first_time` INT UNSIGNED     NOT NULL DEFAULT 0,
    PRIMARY KEY (`account`, `display`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='mod-beast-collection: field guide finds';

-- Rewards already given. `guid` is 0 for a reward given once per account; `family` is the
-- family for a per-family reward, else 0.
CREATE TABLE IF NOT EXISTS `mod_beast_reward_claim` (
    `account`   INT UNSIGNED NOT NULL,
    `guid`      INT UNSIGNED NOT NULL DEFAULT 0,
    `reward_id` INT UNSIGNED NOT NULL,
    `family`    INT UNSIGNED NOT NULL DEFAULT 0,
    `time`      INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`account`, `guid`, `reward_id`, `family`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='mod-beast-collection: rewards given';
