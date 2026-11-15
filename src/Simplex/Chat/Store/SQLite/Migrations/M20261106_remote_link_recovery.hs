{-# LANGUAGE QuasiQuotes #-}

module Simplex.Chat.Store.SQLite.Migrations.M20261106_remote_link_recovery where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20261106_remote_link_recovery :: Query
m20261106_remote_link_recovery =
  [sql|
ALTER TABLE remote_hosts ADD COLUMN recovery_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE remote_controllers ADD COLUMN recovery_host TEXT;
ALTER TABLE remote_controllers ADD COLUMN recovery_port INTEGER;
|]

down_m20261106_remote_link_recovery :: Query
down_m20261106_remote_link_recovery =
  [sql|
ALTER TABLE remote_controllers DROP COLUMN recovery_port;
ALTER TABLE remote_controllers DROP COLUMN recovery_host;
ALTER TABLE remote_hosts DROP COLUMN recovery_enabled;
|]
