-- mod-beast-collection: beast-dex milestone rewards.
--
-- `type`  0 = a number of normal looks in the dex (`count`)
--         1 = a number of shiny looks in the dex (`count`)
--         2 = every normal look of one family; `family` = that family, or 0 for each family
-- Rewards go out by mail (item, money) or straight away (title, spell). `per_character` 1 gives
-- the reward to every hunter on the account that reaches it, 0 only to the first.
-- Edit freely; the server reads this table at startup and on `.reload config`.

DROP TABLE IF EXISTS `mod_beast_collection_reward`;
CREATE TABLE `mod_beast_collection_reward` (
    `id`            INT UNSIGNED      NOT NULL,
    `type`          TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `count`         INT UNSIGNED      NOT NULL DEFAULT 0,
    `family`        INT UNSIGNED      NOT NULL DEFAULT 0,
    `item`          INT UNSIGNED      NOT NULL DEFAULT 0,
    `item_count`    INT UNSIGNED      NOT NULL DEFAULT 1,
    `money`         INT UNSIGNED      NOT NULL DEFAULT 0 COMMENT 'copper',
    `title`         INT UNSIGNED      NOT NULL DEFAULT 0 COMMENT 'CharTitles.dbc id',
    `spell`         INT UNSIGNED      NOT NULL DEFAULT 0 COMMENT 'learned',
    `per_character` TINYINT UNSIGNED  NOT NULL DEFAULT 0,
    `text`          VARCHAR(100)      NOT NULL DEFAULT '',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='mod-beast-collection: dex milestone rewards';

INSERT INTO `mod_beast_collection_reward`
    (`id`, `type`, `count`, `family`, `item`, `item_count`, `money`, `title`, `spell`, `per_character`, `text`)
VALUES
    (1, 0,  10, 0,  8490, 1,       0, 0, 0, 0, 'Tame 10 beast looks'),
    (2, 0,  25, 0,  8495, 1,       0, 0, 0, 0, 'Tame 25 beast looks'),
    (3, 0,  50, 0, 10360, 1,       0, 0, 0, 0, 'Tame 50 beast looks'),
    (4, 0, 100, 0,  8586, 1,       0, 0, 0, 0, 'Tame 100 beast looks'),
    (5, 0, 200, 0, 44822, 1, 5000000, 0, 0, 0, 'Tame 200 beast looks'),
    (6, 1,   1, 0, 49343, 1,       0, 0, 0, 0, 'Tame a shiny beast'),
    (7, 2,   0, 0,     0, 1,  250000, 0, 0, 0, 'Complete a family');
