{-# LANGUAGE QuasiQuotes #-}

module Simplex.Chat.Store.Postgres.Migrations.M20261106_remote_link_recovery where

import Data.Text (Text)
import Text.RawString.QQ (r)

m20261106_remote_link_recovery :: Text
m20261106_remote_link_recovery =
  [r|
ALTER TABLE remote_hosts ADD COLUMN recovery_enabled SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE remote_controllers ADD COLUMN recovery_host TEXT;
ALTER TABLE remote_controllers ADD COLUMN recovery_port INTEGER;
|]

down_m20261106_remote_link_recovery :: Text
down_m20261106_remote_link_recovery =
  [r|
ALTER TABLE remote_controllers DROP COLUMN recovery_port;
ALTER TABLE remote_controllers DROP COLUMN recovery_host;
ALTER TABLE remote_hosts DROP COLUMN recovery_enabled;
|]
