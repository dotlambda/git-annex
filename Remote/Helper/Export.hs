{- exports to remotes
 -
 - Copyright 2017 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE FlexibleInstances #-}

module Remote.Helper.Export where

import Annex.Common
import Types.Remote
import Types.Backend
import Types.Key
import Backend
import Remote.Helper.Encryptable (isEncrypted)
import Database.Export
import Annex.Export
import Config

import qualified Data.Map as M
import Control.Concurrent.STM

-- | Use for remotes that do not support exports.
class HasExportUnsupported a where
	exportUnsupported :: a

instance HasExportUnsupported (RemoteConfig -> RemoteGitConfig -> Annex Bool) where
	exportUnsupported = \_ _ -> return False

instance HasExportUnsupported (Annex (ExportActions Annex)) where
	exportUnsupported = return $ ExportActions
		{ storeExport = \_ _ _ _ -> do
			warning "store export is unsupported"
			return False
		, retrieveExport = \_ _ _ _ -> return False
		, checkPresentExport = \_ _ -> return False
		, removeExport = \_ _ -> return False
		, removeExportDirectory = Just $ \_ -> return False
		, renameExport = \_ _ _ -> return False
		}

exportIsSupported :: RemoteConfig -> RemoteGitConfig -> Annex Bool
exportIsSupported = \_ _ -> return True

-- | Prevent or allow exporttree=yes when setting up a new remote,
-- depending on exportSupported and other configuration.
adjustExportableRemoteType :: RemoteType -> RemoteType
adjustExportableRemoteType rt = rt { setup = setup' }
  where
	setup' st mu cp c gc = do
		let cont = setup rt st mu cp c gc
		ifM (exportSupported rt c gc)
			( case st of
				Init
					| exportTree c && isEncrypted c ->
						giveup "cannot enable both encryption and exporttree"
					| otherwise -> cont
				Enable oldc
					| exportTree c /= exportTree oldc ->
						giveup "cannot change exporttree of existing special remote"
					| otherwise -> cont
			, if exportTree c
				then giveup "exporttree=yes is not supported by this special remote"
				else cont
			)

-- | If the remote is exportSupported, and exporttree=yes, adjust the
-- remote to be an export.
adjustExportable :: Remote -> Annex Remote
adjustExportable r = case M.lookup "exporttree" (config r) of
	Nothing -> notexport
	Just c -> case yesNo c of
		Just True -> ifM (isExportSupported r)
			( isexport
			, notexport
			)
		Just False -> notexport
		Nothing -> do
			warning $ "bad exporttree value for " ++ name r ++ ", assuming not an export"
			notexport
  where
	notexport = return $ r 
		{ exportActions = exportUnsupported
		, remotetype = (remotetype r)
			{ exportSupported = exportUnsupported
			}
		}
	isexport = do
		db <- openDb (uuid r)
		updateflag <- liftIO $ newTVarIO Nothing

		-- When multiple threads run this, all except the first
		-- will block until the first runs doneupdateonce.
		-- Returns True when an update should be done and False
		-- when the update has already been done.
		let startupdateonce = liftIO $ atomically $
			readTVar updateflag >>= \case
				Nothing -> do
					writeTVar updateflag (Just True)
					return True
				Just True -> retry
				Just False -> return False
		let doneupdateonce = \updated ->
			when updated $
				liftIO $ atomically $
					writeTVar updateflag (Just False)
		
		exportinconflict <- liftIO $ newTVarIO False

		-- Get export locations for a key. Checks once
		-- if the export log is different than the database and
		-- updates the database, to notice when an export has been
		-- updated from another repository.
		let getexportlocs = \k -> do
			bracket startupdateonce doneupdateonce $ \updatenow ->
				when updatenow $
					updateExportTreeFromLog db >>= \case
						ExportUpdateSuccess -> return ()
						ExportUpdateConflict -> do
							warnExportConflict r
							liftIO $ atomically $
								writeTVar exportinconflict True
			liftIO $ getExportTree db k

		return $ r
			-- Storing a key on an export could be implemented,
			-- but it would perform unncessary work
			-- when another repository has already stored the
			-- key, and the local repository does not know
			-- about it. To avoid unnecessary costs, don't do it.
			{ storeKey = \_ _ _ -> do
				warning "remote is configured with exporttree=yes; use `git-annex export` to store content on it"
				return False
			-- Keys can be retrieved using retrieveExport, 
			-- but since that retrieves from a path in the
			-- remote that another writer could have replaced
			-- with content not of the requested key,
			-- the content has to be strongly verified.
			--
			-- But, appendonly remotes have a key/value store,
			-- so don't need to use retrieveExport.
			, retrieveKeyFile = if appendonly r
				then retrieveKeyFile r
				else retrieveKeyFileFromExport getexportlocs exportinconflict
			, retrieveKeyFileCheap = if appendonly r
				then retrieveKeyFileCheap r
				else \_ _ _ -> return False
			-- Removing a key from an export would need to
			-- change the tree in the export log to not include
			-- the file. Otherwise, conflicts when removing
			-- files would not be dealt with correctly.
			-- There does not seem to be a good use case for
			-- removing a key from an export in any case.
			, removeKey = \_k -> do
				warning "dropping content from an export is not supported; use `git annex export` to export a tree that lacks the files you want to remove"
				return False
			-- Can't lock content on exports, since they're
			-- not key/value stores, and someone else could
			-- change what's exported to a file at any time.
			--
			-- (except for appendonly remotes)
			, lockContent = if appendonly r
				then lockContent r
				else Nothing
			-- Check if any of the files a key was exported to
			-- are present. This doesn't guarantee the export
			-- contains the right content, which is why export
			-- remotes are untrusted.
			--
			-- (but appendonly remotes work the same as any
			-- non-export remote)
			, checkPresent = if appendonly r
				then checkPresent r
				else \k -> do
					ea <- exportActions r
					anyM (checkPresentExport ea k)
						=<< getexportlocs k
			-- checkPresent from an export is more expensive
			-- than otherwise, so not cheap. Also, this
			-- avoids things that look at checkPresentCheap and
			-- silently skip non-present files from behaving
			-- in confusing ways when there's an export
			-- conflict.
			, checkPresentCheap = False
			, mkUnavailable = return Nothing
			, getInfo = do
				is <- getInfo r
				return (is++[("export", "yes")])
			}
	retrieveKeyFileFromExport getexportlocs exportinconflict k _af dest p = unVerified $
		if maybe False (isJust . verifyKeyContent) (maybeLookupBackendVariety (keyVariety k))
			then do
				locs <- getexportlocs k
				case locs of
					[] -> do
						ifM (liftIO $ atomically $ readTVar exportinconflict)
							( warning "unknown export location, likely due to the export conflict"
							, warning "unknown export location"
							)
						return False
					(l:_) -> do
						ea <- exportActions r
						retrieveExport ea k l dest p
			else do
				warning $ "exported content cannot be verified due to using the " ++ formatKeyVariety (keyVariety k) ++ " backend"
				return False
