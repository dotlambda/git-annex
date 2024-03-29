{- Sqlite database used for exports to special remotes.
 -
 - Copyright 2017 Joey Hess <id@joeyh.name>
 -:
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE QuasiQuotes, TypeFamilies, TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings, GADTs, FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE CPP #-}

module Database.Export (
	ExportHandle,
	openDb,
	closeDb,
	flushDbQueue,
	addExportedLocation,
	removeExportedLocation,
	getExportedLocation,
	isExportDirectoryEmpty,
	getExportTreeCurrent,
	recordExportTreeCurrent,
	getExportTree,
	addExportTree,
	removeExportTree,
	updateExportTree,
	updateExportTree',
	updateExportTreeFromLog,
	ExportedId,
	ExportedDirectoryId,
	ExportTreeId,
	ExportTreeCurrentId,
	ExportUpdateResult(..),
) where

import Database.Types
import qualified Database.Queue as H
import Database.Init
import Annex.Locations
import Annex.Common hiding (delete)
import Types.Export
import Annex.Export
import qualified Logs.Export as Log
import Annex.LockFile
import Git.Types
import Git.Sha
import Git.FilePath
import qualified Git.DiffTree

import Database.Persist.Sql hiding (Key)
import Database.Persist.TH

data ExportHandle = ExportHandle H.DbQueue UUID

share [mkPersist sqlSettings, mkMigrate "migrateExport"] [persistLowerCase|
-- Files that have been exported to the remote and are present on it.
Exported
  key IKey
  file SFilePath
  ExportedIndex key file
-- Directories that exist on the remote, and the files that are in them.
ExportedDirectory
  subdir SFilePath
  file SFilePath
  ExportedDirectoryIndex subdir file
-- The content of the tree that has been exported to the remote.
-- Not all of these files are necessarily present on the remote yet.
ExportTree
  key IKey
  file SFilePath
  ExportTreeIndex key file
-- The tree stored in ExportTree
ExportTreeCurrent
  tree SRef
  UniqueTree tree
|]

{- Opens the database, creating it if it doesn't exist yet.
 -
 - Only a single process should write to the export at a time, so guard
 - any writes with the gitAnnexExportLock.
 -}
openDb :: UUID -> Annex ExportHandle
openDb u = do
	dbdir <- fromRepo (gitAnnexExportDbDir u)
	let db = dbdir </> "db"
	unlessM (liftIO $ doesFileExist db) $ do
		initDb db $ void $
			runMigrationSilent migrateExport
	h <- liftIO $ H.openDbQueue H.SingleWriter db "exported"
	return $ ExportHandle h u

closeDb :: ExportHandle -> Annex ()
closeDb (ExportHandle h _) = liftIO $ H.closeDbQueue h

queueDb :: ExportHandle -> SqlPersistM () -> IO ()
queueDb (ExportHandle h _) = H.queueDb h checkcommit
  where
	-- commit queue after 1000 changes
	checkcommit sz _lastcommittime
		| sz > 1000 = return True
		| otherwise = return False

flushDbQueue :: ExportHandle -> IO ()
flushDbQueue (ExportHandle h _) = H.flushDbQueue h

recordExportTreeCurrent :: ExportHandle -> Sha -> IO ()
recordExportTreeCurrent h s = queueDb h $ do
	deleteWhere ([] :: [Filter ExportTreeCurrent])
	void $ insertUnique $ ExportTreeCurrent $ toSRef s

getExportTreeCurrent :: ExportHandle -> IO (Maybe Sha)
getExportTreeCurrent (ExportHandle h _) = H.queryDbQueue h $ do
	l <- selectList ([] :: [Filter ExportTreeCurrent]) []
	case l of
		(s:[]) -> return $ Just $ fromSRef $ exportTreeCurrentTree $ entityVal s
		_ -> return Nothing

addExportedLocation :: ExportHandle -> Key -> ExportLocation -> IO ()
addExportedLocation h k el = queueDb h $ do
	void $ insertUnique $ Exported ik ef
	let edirs = map
		(\ed -> ExportedDirectory (toSFilePath (fromExportDirectory ed)) ef)
		(exportDirectories el)
#if MIN_VERSION_persistent(2,8,1)
	putMany edirs
#else
	mapM_ insertUnique edirs
#endif
  where
	ik = toIKey k
	ef = toSFilePath (fromExportLocation el)

removeExportedLocation :: ExportHandle -> Key -> ExportLocation -> IO ()
removeExportedLocation h k el = queueDb h $ do
	deleteWhere [ExportedKey ==. ik, ExportedFile ==. ef]
	let subdirs = map (toSFilePath . fromExportDirectory)
		(exportDirectories el)
	deleteWhere [ExportedDirectoryFile ==. ef, ExportedDirectorySubdir <-. subdirs]
  where
	ik = toIKey k
	ef = toSFilePath (fromExportLocation el)

{- Note that this does not see recently queued changes. -}
getExportedLocation :: ExportHandle -> Key -> IO [ExportLocation]
getExportedLocation (ExportHandle h _) k = H.queryDbQueue h $ do
	l <- selectList [ExportedKey ==. ik] []
	return $ map (mkExportLocation . fromSFilePath . exportedFile . entityVal) l
  where
	ik = toIKey k

{- Note that this does not see recently queued changes. -}
isExportDirectoryEmpty :: ExportHandle -> ExportDirectory -> IO Bool
isExportDirectoryEmpty (ExportHandle h _) d = H.queryDbQueue h $ do
	l <- selectList [ExportedDirectorySubdir ==. ed] []
	return $ null l
  where
	ed = toSFilePath $ fromExportDirectory d

{- Get locations in the export that might contain a key. -}
getExportTree :: ExportHandle -> Key -> IO [ExportLocation]
getExportTree (ExportHandle h _) k = H.queryDbQueue h $ do
	l <- selectList [ExportTreeKey ==. ik] []
	return $ map (mkExportLocation . fromSFilePath . exportTreeFile . entityVal) l
  where
	ik = toIKey k

addExportTree :: ExportHandle -> Key -> ExportLocation -> IO ()
addExportTree h k loc = queueDb h $
	void $ insertUnique $ ExportTree ik ef
  where
	ik = toIKey k
	ef = toSFilePath (fromExportLocation loc)

removeExportTree :: ExportHandle -> Key -> ExportLocation -> IO ()
removeExportTree h k loc = queueDb h $
	deleteWhere [ExportTreeKey ==. ik, ExportTreeFile ==. ef]
  where
	ik = toIKey k
	ef = toSFilePath (fromExportLocation loc)

{- Diff from the old to the new tree and update the ExportTree table. -}
updateExportTree :: ExportHandle -> Sha -> Sha -> Annex ()
updateExportTree h old new = do
	(diff, cleanup) <- inRepo $
		Git.DiffTree.diffTreeRecursive old new
	forM_ diff $ \i -> do
		srcek <- getek (Git.DiffTree.srcsha i)
		dstek <- getek (Git.DiffTree.dstsha i)
		updateExportTree' h srcek dstek i
	void $ liftIO cleanup
  where
	getek sha
		| sha == nullSha = return Nothing
		| otherwise = Just <$> exportKey sha

updateExportTree' :: ExportHandle -> Maybe ExportKey -> Maybe ExportKey -> Git.DiffTree.DiffTreeItem -> Annex ()
updateExportTree' h srcek dstek i = do
	case srcek of
		Nothing -> return ()
		Just k -> liftIO $ removeExportTree h (asKey k) loc
	case dstek of
		Nothing -> return ()
		Just k -> liftIO $ addExportTree h (asKey k) loc
  where
	loc = mkExportLocation $ getTopFilePath $ Git.DiffTree.file i

data ExportUpdateResult = ExportUpdateSuccess | ExportUpdateConflict
	deriving (Eq)

updateExportTreeFromLog :: ExportHandle -> Annex ExportUpdateResult
updateExportTreeFromLog db@(ExportHandle _ u) = 
	withExclusiveLock (gitAnnexExportLock u) $ do
		old <- liftIO $ fromMaybe emptyTree
			<$> getExportTreeCurrent db
		l <- Log.getExport u
		case map Log.exportedTreeish l of
			[] -> return ExportUpdateSuccess
			(new:[]) | new /= old -> do
				updateExportTree db old new
				liftIO $ recordExportTreeCurrent db new
				liftIO $ flushDbQueue db
				return ExportUpdateSuccess
			_ts -> return ExportUpdateConflict
