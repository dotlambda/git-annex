{- git-annex test suite framework
 -
 - Copyright 2010-2017 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Test.Framework where

import Test.Tasty
import Test.Tasty.Runners
import Test.Tasty.HUnit
import Control.Concurrent

import Common
import Types.Test

import qualified Annex
import qualified Annex.UUID
import qualified Annex.Version
import qualified Types.RepoVersion
import qualified Backend
import qualified Git.CurrentRepo
import qualified Git.Construct
import qualified Types.KeySource
import qualified Types.Backend
import qualified Types
import qualified Remote
import qualified Key
import qualified Types.Key
import qualified Types.Messages
import qualified Config
import qualified Annex.WorkTree
import qualified Annex.Link
import qualified Annex.Init
import qualified Annex.Path
import qualified Annex.Action
import qualified Annex.AdjustedBranch
import qualified Utility.Process
import qualified Utility.Env
import qualified Utility.Env.Set
import qualified Utility.Exception
import qualified Utility.ThreadScheduler
import qualified Utility.Tmp.Dir
import qualified Command.Uninit
import qualified CmdLine.GitAnnex as GitAnnex

-- This is equivilant to running git-annex, but it's all run in-process
-- so test coverage collection works.
git_annex :: String -> [String] -> IO Bool
git_annex command params = git_annex' command params >>= \case
	Right () -> return True
	Left e -> do
		hPutStrLn stderr (show e)
		return False

-- For when git-annex is expected to fail.
git_annex_shouldfail :: String -> [String] -> IO Bool
git_annex_shouldfail command params = git_annex' command params >>= \case
	Right () -> return False
	Left _ -> return True

git_annex' :: String -> [String] -> IO (Either SomeException ())
git_annex' command params = do
	-- catch all errors, including normally fatal errors
	try run ::IO (Either SomeException ())
  where
	run = GitAnnex.run dummyTestOptParser (\_ -> noop) (command:"-q":params)
	dummyTestOptParser = pure mempty

{- Runs git-annex and returns its output. -}
git_annex_output :: String -> [String] -> IO String
git_annex_output command params = do
	pp <- Annex.Path.programPath
	got <- Utility.Process.readProcess pp (command:params)
	-- Since the above is a separate process, code coverage stats are
	-- not gathered for things run in it.
	-- Run same command again, to get code coverage.
	_ <- git_annex command params
	return got

git_annex_expectoutput :: String -> [String] -> [String] -> IO ()
git_annex_expectoutput command params expected = do
	got <- lines <$> git_annex_output command params
	got == expected @? ("unexpected value running " ++ command ++ " " ++ show params ++ " -- got: " ++ show got ++ " expected: " ++ show expected)

-- Runs an action in the current annex. Note that shutdown actions
-- are not run; this should only be used for actions that query state.
annexeval :: Types.Annex a -> IO a
annexeval a = do
	s <- Annex.new =<< Git.CurrentRepo.get
	Annex.eval s $ do
		Annex.setOutput Types.Messages.QuietOutput
		a `finally` Annex.Action.stopCoProcesses

innewrepo :: Assertion -> Assertion
innewrepo a = withgitrepo $ \r -> indir r a

inmainrepo :: Assertion -> Assertion
inmainrepo = indir mainrepodir

with_ssh_origin :: (Assertion -> Assertion) -> (Assertion -> Assertion)
with_ssh_origin cloner a = cloner $ do
	origindir <- absPath
		=<< annexeval (Config.getConfig (Config.ConfigKey config) "/dev/null")
	let originurl = "localhost:" ++ origindir
	boolSystem "git" [Param "config", Param config, Param originurl] @? "git config failed"
	a
  where
	config = "remote.origin.url"

intmpclonerepo :: Assertion -> Assertion
intmpclonerepo a = withtmpclonerepo $ \r -> indir r a

intmpclonerepoInDirect :: Assertion -> Assertion
intmpclonerepoInDirect a = intmpclonerepo $
	ifM isdirect
		( putStrLn "not supported in direct mode; skipping"
		, a
		)
  where
	isdirect = annexeval $ do
		Annex.Init.initialize (Annex.Init.AutoInit False) Nothing Nothing
		Config.isDirect

checkRepo :: Types.Annex a -> FilePath -> IO a
checkRepo getval d = do
	s <- Annex.new =<< Git.Construct.fromPath d
	Annex.eval s $
		getval `finally` Annex.Action.stopCoProcesses

isInDirect :: FilePath -> IO Bool
isInDirect = checkRepo (not <$> Config.isDirect)

intmpbareclonerepo :: Assertion -> Assertion
intmpbareclonerepo a = withtmpclonerepo' (newCloneRepoConfig { bareClone = True } ) $
	\r -> indir r a

intmpsharedclonerepo :: Assertion -> Assertion
intmpsharedclonerepo a = withtmpclonerepo' (newCloneRepoConfig { sharedClone = True } ) $
	\r -> indir r a

withtmpclonerepo :: (FilePath -> Assertion) -> Assertion
withtmpclonerepo = withtmpclonerepo' newCloneRepoConfig

withtmpclonerepo' :: CloneRepoConfig -> (FilePath -> Assertion) -> Assertion
withtmpclonerepo' cfg a = do
	dir <- tmprepodir
	clone <- clonerepo mainrepodir dir cfg
	r <- tryNonAsync (a clone)
	case r of
		Right () -> return ()
		Left e -> do
			whenM (keepFailures <$> getTestMode) $
				putStrLn $ "** Preserving repo for failure analysis in " ++ clone
			throwM e

disconnectOrigin :: Assertion
disconnectOrigin = boolSystem "git" [Param "remote", Param "rm", Param "origin"] @? "remote rm"

withgitrepo :: (FilePath -> Assertion) -> Assertion
withgitrepo = bracket (setuprepo mainrepodir) return

indir :: FilePath -> IO a -> IO a
indir dir a = do
	currdir <- getCurrentDirectory
	-- Assertion failures throw non-IO errors; catch
	-- any type of error and change back to currdir before
	-- rethrowing.
	r <- bracket_
		(changeToTmpDir dir)
		(setCurrentDirectory currdir)
		(tryNonAsync a)
	case r of
		Right v -> return v
		Left e -> throwM e

adjustedbranchsupported :: FilePath -> IO Bool
adjustedbranchsupported repo = indir repo $ annexeval Annex.AdjustedBranch.isSupported

setuprepo :: FilePath -> IO FilePath
setuprepo dir = do
	cleanup dir
	ensuretmpdir
	boolSystem "git" [Param "init", Param "-q", File dir] @? "git init failed"
	configrepo dir
	return dir

data CloneRepoConfig = CloneRepoConfig
	{ bareClone :: Bool
	, sharedClone :: Bool
	}

newCloneRepoConfig :: CloneRepoConfig
newCloneRepoConfig = CloneRepoConfig
	{ bareClone = False
	, sharedClone = False
	}

-- clones are always done as local clones; we cannot test ssh clones
clonerepo :: FilePath -> FilePath -> CloneRepoConfig -> IO FilePath
clonerepo old new cfg = do
	cleanup new
	ensuretmpdir
	let cloneparams = catMaybes
		[ Just $ Param "clone"
		, Just $ Param "-q"
		, if bareClone cfg then Just (Param "--bare") else Nothing
		, if sharedClone cfg then Just (Param "--shared") else Nothing
		, Just $ File old
		, Just $ File new
		]
	boolSystem "git" cloneparams @? "git clone failed"
	configrepo new
	indir new $ do
		ver <- annexVersion <$> getTestMode
		if ver == Annex.Version.defaultVersion
			then git_annex "init" ["-q", new] @? "git annex init failed"
			else git_annex "init" ["-q", new, "--version", show (Types.RepoVersion.fromRepoVersion ver)] @? "git annex init failed"
	unless (bareClone cfg) $
		indir new $
			setupTestMode
	return new

configrepo :: FilePath -> IO ()
configrepo dir = indir dir $ do
	-- ensure git is set up to let commits happen
	boolSystem "git" [Param "config", Param "user.name", Param "Test User"] @? "git config failed"
	boolSystem "git" [Param "config", Param "user.email", Param "test@example.com"] @? "git config failed"
	-- avoid signed commits by test suite
	boolSystem "git" [Param "config", Param "commit.gpgsign", Param "false"] @? "git config failed"
	-- tell git-annex to not annex the ingitfile
	boolSystem "git"
		[ Param "config"
		, Param "annex.largefiles"
		, Param ("exclude=" ++ ingitfile)
		] @? "git config annex.largefiles failed"

ensuretmpdir :: IO ()
ensuretmpdir = do
	e <- doesDirectoryExist tmpdir
	unless e $
		createDirectory tmpdir
	
{- Prevent global git configs from affecting the test suite. -}
isolateGitConfig :: IO a -> IO a
isolateGitConfig a = Utility.Tmp.Dir.withTmpDir "testhome" $ \tmphome -> do
	tmphomeabs <- absPath tmphome
	Utility.Env.Set.setEnv "HOME" tmphomeabs True
	Utility.Env.Set.setEnv "XDG_CONFIG_HOME" tmphomeabs True
	Utility.Env.Set.setEnv "GIT_CONFIG_NOSYSTEM" "1" True
	a

cleanup :: FilePath -> IO ()
cleanup dir = whenM (doesDirectoryExist dir) $ do
	Command.Uninit.prepareRemoveAnnexDir' dir
	-- This can fail if files in the directory are still open by a
	-- subprocess.
	void $ tryIO $ removeDirectoryRecursive dir

finalCleanup :: IO ()
finalCleanup = whenM (doesDirectoryExist tmpdir) $ do
	Annex.Action.reapZombies
	Command.Uninit.prepareRemoveAnnexDir' tmpdir
	catchIO (removeDirectoryRecursive tmpdir) $ \e -> do
		print e
		putStrLn "sleeping 10 seconds and will retry directory cleanup"
		Utility.ThreadScheduler.threadDelaySeconds $
			Utility.ThreadScheduler.Seconds 10
		whenM (doesDirectoryExist tmpdir) $ do
			Annex.Action.reapZombies
			removeDirectoryRecursive tmpdir
	
checklink :: FilePath -> Assertion
checklink f =
	-- in direct mode, it may be a symlink, or not, depending
	-- on whether the content is present.
	unlessM (annexeval Config.isDirect) $
		ifM (annexeval Config.crippledFileSystem)
			( (isJust <$> annexeval (Annex.Link.getAnnexLinkTarget f))
				@? f ++ " is not a (crippled) symlink"
			, do
				s <- getSymbolicLinkStatus f
				isSymbolicLink s @? f ++ " is not a symlink"
			)

checkregularfile :: FilePath -> Assertion
checkregularfile f = do
	s <- getSymbolicLinkStatus f
	isRegularFile s @? f ++ " is not a normal file"
	return ()

checkdoesnotexist :: FilePath -> Assertion
checkdoesnotexist f = 
	(either (const True) (const False) <$> Utility.Exception.tryIO (getSymbolicLinkStatus f))
		@? f ++ " exists unexpectedly"

checkexists :: FilePath -> Assertion
checkexists f = 
	(either (const False) (const True) <$> Utility.Exception.tryIO (getSymbolicLinkStatus f))
		@? f ++ " does not exist"

checkcontent :: FilePath -> Assertion
checkcontent f = do
	c <- Utility.Exception.catchDefaultIO "could not read file" $ readFile f
	assertEqual ("checkcontent " ++ f) (content f) c

checkunwritable :: FilePath -> Assertion
checkunwritable f = unlessM (annexeval Config.isDirect) $ do
	-- Look at permissions bits rather than trying to write or
	-- using fileAccess because if run as root, any file can be
	-- modified despite permissions.
	s <- getFileStatus f
	let mode = fileMode s
	when (mode == mode `unionFileModes` ownerWriteMode) $
		assertFailure $ "able to modify annexed file's " ++ f ++ " content"

checkwritable :: FilePath -> Assertion
checkwritable f = do
	s <- getFileStatus f
	let mode = fileMode s
	unless (mode == mode `unionFileModes` ownerWriteMode) $
		assertFailure $ "unable to modify " ++ f

checkdangling :: FilePath -> Assertion
checkdangling f = ifM (annexeval Config.crippledFileSystem)
	( return () -- probably no real symlinks to test
	, do
		r <- tryIO $ readFile f
		case r of
			Left _ -> return () -- expected; dangling link
			Right _ -> assertFailure $ f ++ " was not a dangling link as expected"
	)

checklocationlog :: FilePath -> Bool -> Assertion
checklocationlog f expected = do
	thisuuid <- annexeval Annex.UUID.getUUID
	r <- annexeval $ Annex.WorkTree.lookupFile f
	case r of
		Just k -> do
			uuids <- annexeval $ Remote.keyLocations k
			assertEqual ("bad content in location log for " ++ f ++ " key " ++ Key.key2file k ++ " uuid " ++ show thisuuid)
				expected (thisuuid `elem` uuids)
		_ -> assertFailure $ f ++ " failed to look up key"

checkbackend :: FilePath -> Types.Backend -> Assertion
checkbackend file expected = do
	b <- annexeval $ maybe (return Nothing) (Backend.getBackend file) 
		=<< Annex.WorkTree.lookupFile file
	assertEqual ("backend for " ++ file) (Just expected) b

checkispointerfile :: FilePath -> Assertion
checkispointerfile f = unlessM (isJust <$> Annex.Link.isPointerFile f) $
	assertFailure $ f ++ " is not a pointer file"

inlocationlog :: FilePath -> Assertion
inlocationlog f = checklocationlog f True

notinlocationlog :: FilePath -> Assertion
notinlocationlog f = checklocationlog f False

runchecks :: [FilePath -> Assertion] -> FilePath -> Assertion
runchecks [] _ = return ()
runchecks (a:as) f = do
	a f
	runchecks as f

annexed_notpresent :: FilePath -> Assertion
annexed_notpresent f = ifM (unlockedFiles <$> getTestMode)
	( annexed_notpresent_unlocked f
	, annexed_notpresent_locked f
	)

annexed_notpresent_locked :: FilePath -> Assertion
annexed_notpresent_locked = runchecks [checklink, checkdangling, notinlocationlog]

annexed_notpresent_unlocked :: FilePath -> Assertion
annexed_notpresent_unlocked = runchecks [checkregularfile, checkispointerfile, notinlocationlog]

annexed_present :: FilePath -> Assertion
annexed_present f = ifM (unlockedFiles <$> getTestMode)
	( annexed_present_unlocked f
	, annexed_present_locked f
	)

annexed_present_locked :: FilePath -> Assertion
annexed_present_locked f = ifM (annexeval Config.crippledFileSystem)
	( runchecks [checklink, inlocationlog] f
	, runchecks [checklink, checkcontent, checkunwritable, inlocationlog] f
	)

annexed_present_unlocked :: FilePath -> Assertion
annexed_present_unlocked = runchecks
	[checkregularfile, checkcontent, checkwritable, inlocationlog]

unannexed :: FilePath -> Assertion
unannexed = runchecks [checkregularfile, checkcontent, checkwritable]

add_annex :: FilePath -> IO Bool
add_annex f = ifM (unlockedFiles <$> getTestMode)
	( boolSystem "git" [Param "add", File f]
	, git_annex "add" [f]
	)

data TestMode = TestMode
	{ forceDirect :: Bool
	, unlockedFiles :: Bool
	, annexVersion :: Types.RepoVersion.RepoVersion
	, keepFailures :: Bool
	} deriving (Read, Show)

testMode :: TestOptions -> Types.RepoVersion.RepoVersion -> TestMode
testMode opts v = TestMode
	{ forceDirect = False
	, unlockedFiles = False
	, annexVersion = v
	, keepFailures = keepFailuresOption opts
	}

withTestMode :: TestMode -> TestTree -> TestTree -> TestTree
withTestMode testmode inittests = withResource prepare release . const
  where
	prepare = do
		setTestMode testmode
		case tryIngredients [consoleTestReporter] mempty inittests of
			Nothing -> error "No tests found!?"
			Just act -> unlessM act $
				error "init tests failed! cannot continue"
		return ()
	release _ = cleanup mainrepodir

setTestMode :: TestMode -> IO ()
setTestMode testmode = do
	currdir <- getCurrentDirectory
	p <- Utility.Env.getEnvDefault "PATH" ""

	mapM_ (\(var, val) -> Utility.Env.Set.setEnv var val True)
		-- Ensure that the just-built git annex is used.
		[ ("PATH", currdir ++ [searchPathSeparator] ++ p)
		, ("TOPDIR", currdir)
		-- Avoid git complaining if it cannot determine the user's
		-- email address, or exploding if it doesn't know the user's
		-- name.
		, ("GIT_AUTHOR_EMAIL", "test@example.com")
		, ("GIT_AUTHOR_NAME", "git-annex test")
		, ("GIT_COMMITTER_EMAIL", "test@example.com")
		, ("GIT_COMMITTER_NAME", "git-annex test")
		-- force gpg into batch mode for the tests
		, ("GPG_BATCH", "1")
		-- Make git and git-annex access ssh remotes on the local
		-- filesystem, without using ssh at all.
		, ("GIT_SSH_COMMAND", "git-annex test --fakessh --")
		, ("GIT_ANNEX_USE_GIT_SSH", "1")
		, ("TESTMODE", show testmode)
		]

runFakeSsh :: [String] -> IO ()
runFakeSsh ("-n":ps) = runFakeSsh ps
runFakeSsh (_host:cmd:[]) = do
	(_, _, _, pid) <- createProcess (shell cmd)
	exitWith =<< waitForProcess pid
runFakeSsh ps = error $ "fake ssh option parse error: " ++ show ps

getTestMode :: IO TestMode
getTestMode = Prelude.read <$> Utility.Env.getEnvDefault "TESTMODE" ""

setupTestMode :: IO ()
setupTestMode = do
	testmode <- getTestMode
	when (forceDirect testmode) $
		git_annex "direct" ["-q"] @? "git annex direct failed"

changeToTmpDir :: FilePath -> IO ()
changeToTmpDir t = do
	topdir <- Utility.Env.getEnvDefault "TOPDIR" (error "TOPDIR not set")
	setCurrentDirectory $ topdir ++ "/" ++ t

tmpdir :: String
tmpdir = ".t"

mainrepodir :: FilePath
mainrepodir = tmpdir </> "repo"

tmprepodir :: IO FilePath
tmprepodir = go (0 :: Int)
  where
	go n = do
		let d = tmpdir </> "tmprepo" ++ show n
		ifM (doesDirectoryExist d)
			( go $ n + 1
			, return d
			)

annexedfile :: String
annexedfile = "foo"

annexedfiledup :: String
annexedfiledup = "foodup"

wormannexedfile :: String
wormannexedfile = "apple"

sha1annexedfile :: String
sha1annexedfile = "sha1foo"

sha1annexedfiledup :: String
sha1annexedfiledup = "sha1foodup"

ingitfile :: String
ingitfile = "bar.c"

content :: FilePath -> String		
content f
	| f == annexedfile = "annexed file content"
	| f == ingitfile = "normal file content"
	| f == sha1annexedfile ="sha1 annexed file content"
	| f == annexedfiledup = content annexedfile
	| f == sha1annexedfiledup = content sha1annexedfile
	| f == wormannexedfile = "worm annexed file content"
	| "import" `isPrefixOf` f = "imported content"
	| otherwise = "unknown file " ++ f

-- Writes new content to a file, and makes sure that it has a different
-- mtime than it did before
writecontent :: FilePath -> String -> IO ()
writecontent f c = go (10000000 :: Integer)
  where
	go ticsleft = do
		oldmtime <- catchMaybeIO $ getModificationTime f
		writeFile f c
		newmtime <- getModificationTime f
		if Just newmtime == oldmtime
			then do
				threadDelay 100000
				let ticsleft' = ticsleft - 100000
				if ticsleft' > 0
					then go ticsleft'
					else do
						hPutStrLn stderr "file mtimes do not seem to be changing (tried for 10 seconds)"
						hFlush stderr
						return ()
			else return ()

changecontent :: FilePath -> IO ()
changecontent f = writecontent f $ changedcontent f

changedcontent :: FilePath -> String
changedcontent f = content f ++ " (modified)"

backendSHA1 :: Types.Backend
backendSHA1 = backend_ "SHA1"

backendSHA256 :: Types.Backend
backendSHA256 = backend_ "SHA256"

backendSHA256E :: Types.Backend
backendSHA256E = backend_ "SHA256E"

backendWORM :: Types.Backend
backendWORM = backend_ "WORM"

backend_ :: String -> Types.Backend
backend_ = Backend.lookupBackendVariety . Types.Key.parseKeyVariety

getKey :: Types.Backend -> FilePath -> IO Types.Key
getKey b f = fromJust <$> annexeval go
  where
	go = Types.Backend.getKey b
		Types.KeySource.KeySource
			{ Types.KeySource.keyFilename = f
			, Types.KeySource.contentLocation = f
			, Types.KeySource.inodeCache = Nothing
			}
