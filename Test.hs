{- git-annex test suite
 -
 - Copyright 2010-2018 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Test where

import Types.Test
import Types.RepoVersion
import Test.Framework
import Options.Applicative.Types

import Test.Tasty
import Test.Tasty.Runners
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck
import Test.Tasty.Ingredients.Rerun
import Options.Applicative (switch, long, help, internal)

import qualified Data.Map as M
import qualified Data.ByteString.Lazy.UTF8 as BU8
import System.Environment

import Common
import CmdLine.GitAnnex.Options

import qualified Utility.SafeCommand
import qualified Annex
import qualified Annex.Version
import qualified Git.Filename
import qualified Git.Types
import qualified Git.Ref
import qualified Git.LsTree
import qualified Git.FilePath
import qualified Annex.Locations
#ifndef mingw32_HOST_OS
import qualified Types.GitConfig
#endif
import qualified Types.TrustLevel
import qualified Types
import qualified Logs.MapLog
import qualified Logs.Trust
import qualified Logs.Remote
import qualified Logs.Unused
import qualified Logs.Transfer
import qualified Logs.Presence
import qualified Logs.PreferredContent
import qualified Types.MetaData
import qualified Remote
import qualified Key
import qualified Config
import qualified Config.Cost
import qualified Crypto
import qualified Database.Keys
import qualified Annex.WorkTree
import qualified Annex.Init
import qualified Annex.CatFile
import qualified Annex.Path
import qualified Annex.VectorClock
import qualified Annex.View
import qualified Annex.View.ViewedFile
import qualified Logs.View
import qualified Utility.Path
import qualified Utility.FileMode
import qualified BuildInfo
import qualified Utility.Format
import qualified Utility.Verifiable
import qualified Utility.Process
import qualified Utility.Misc
import qualified Utility.InodeCache
import qualified Utility.Env
import qualified Utility.Env.Set
import qualified Utility.Matcher
import qualified Utility.Hash
import qualified Utility.Scheduled
import qualified Utility.Scheduled.QuickCheck
import qualified Utility.HumanTime
import qualified Utility.Base64
import qualified Utility.Tmp.Dir
import qualified Utility.FileSystemEncoding
import qualified Utility.Aeson
#ifndef mingw32_HOST_OS
import qualified Remote.Helper.Encryptable
import qualified Types.Crypto
import qualified Utility.Gpg
import qualified Types.Remote
#endif

optParser :: Parser TestOptions
optParser = TestOptions
	<$> suiteOptionParser ingredients (tests False mempty)
	<*> switch
		( long "keep-failures"
		<> help "preserve repositories on test failure"
		)
	<*> switch
		( long "fakessh"
		<> internal
		)
	<*> cmdParams "non-options are for internal use only"

runner :: TestOptions -> IO ()
runner opts
	| fakeSsh opts = runFakeSsh (internalData opts)
	| otherwise = runsubprocesstests =<< Utility.Env.getEnv subenv
  where
	-- Run git-annex test in a subprocess, so that any files
	-- it may open will be closed before running finalCleanup.
	-- This should prevent most failures to clean up after the test
	-- suite.
	subenv = "GIT_ANNEX_TEST_SUBPROCESS"
	runsubprocesstests Nothing = do
		pp <- Annex.Path.programPath
		Utility.Env.Set.setEnv subenv "1" True
		ps <- getArgs
		(Nothing, Nothing, Nothing, pid) <- createProcess (proc pp ps)
		exitcode <- waitForProcess pid
		unless (keepFailuresOption opts) finalCleanup
		exitWith exitcode
	runsubprocesstests (Just _) = isolateGitConfig $ do
		ensuretmpdir
		crippledfilesystem <- fst <$> Annex.Init.probeCrippledFileSystem' tmpdir
		case tryIngredients ingredients (tastyOptionSet opts) (tests crippledfilesystem opts) of
			Nothing -> error "No tests found!?"
			Just act -> ifM act
				( exitSuccess
				, do
					putStrLn "  (Failures above could be due to a bug in git-annex, or an incompatibility"
					putStrLn "   with utilities, such as git, installed on this system.)"
					exitFailure
				)

ingredients :: [Ingredient]
ingredients =
	[ listingTests
	, rerunningTests [consoleTestReporter]
	]

tests :: Bool -> TestOptions -> TestTree
tests crippledfilesystem opts = testGroup "Tests" $ properties :
	map (\(d, te) -> withTestMode te initTests (unitTests d)) testmodes
  where
	testmodes = catMaybes
		[ Just ("v7 unlocked", (testMode opts (RepoVersion 7)) { unlockedFiles = True })
		, unlesscrippled ("v5", testMode opts (RepoVersion 5))
		, unlesscrippled ("v7 locked", testMode opts (RepoVersion 7))
		, Just ("v5 direct", (testMode opts (RepoVersion 5)) { forceDirect = True })
		]
	unlesscrippled v
		| crippledfilesystem = Nothing
		| otherwise = Just v

properties :: TestTree
properties = localOption (QuickCheckTests 1000) $ testGroup "QuickCheck"
	[ testProperty "prop_encode_decode_roundtrip" Git.Filename.prop_encode_decode_roundtrip
	, testProperty "prop_encode_c_decode_c_roundtrip" Utility.Format.prop_encode_c_decode_c_roundtrip
	, testProperty "prop_isomorphic_fileKey" Annex.Locations.prop_isomorphic_fileKey
	, testProperty "prop_isomorphic_key_encode" Key.prop_isomorphic_key_encode
	, testProperty "prop_isomorphic_key_decode" Key.prop_isomorphic_key_decode
	, testProperty "prop_isomorphic_shellEscape" Utility.SafeCommand.prop_isomorphic_shellEscape
	, testProperty "prop_isomorphic_shellEscape_multiword" Utility.SafeCommand.prop_isomorphic_shellEscape_multiword
	, testProperty "prop_isomorphic_configEscape" Logs.Remote.prop_isomorphic_configEscape
	, testProperty "prop_parse_show_Config" Logs.Remote.prop_parse_show_Config
	, testProperty "prop_upFrom_basics" Utility.Path.prop_upFrom_basics
	, testProperty "prop_relPathDirToFile_basics" Utility.Path.prop_relPathDirToFile_basics
	, testProperty "prop_relPathDirToFile_regressionTest" Utility.Path.prop_relPathDirToFile_regressionTest
	, testProperty "prop_cost_sane" Config.Cost.prop_cost_sane
	, testProperty "prop_matcher_sane" Utility.Matcher.prop_matcher_sane
	, testProperty "prop_HmacSha1WithCipher_sane" Crypto.prop_HmacSha1WithCipher_sane
	, testProperty "prop_VectorClock_sane" Annex.VectorClock.prop_VectorClock_sane
	, testProperty "prop_addMapLog_sane" Logs.MapLog.prop_addMapLog_sane
	, testProperty "prop_verifiable_sane" Utility.Verifiable.prop_verifiable_sane
	, testProperty "prop_segment_regressionTest" Utility.Misc.prop_segment_regressionTest
	, testProperty "prop_read_write_transferinfo" Logs.Transfer.prop_read_write_transferinfo
	, testProperty "prop_read_show_inodecache" Utility.InodeCache.prop_read_show_inodecache
	, testProperty "prop_parse_show_log" Logs.Presence.prop_parse_show_log
	, testProperty "prop_read_show_TrustLevel" Types.TrustLevel.prop_read_show_TrustLevel
	, testProperty "prop_parse_show_TrustLog" Logs.Trust.prop_parse_show_TrustLog
	, testProperty "prop_hashes_stable" Utility.Hash.prop_hashes_stable
	, testProperty "prop_mac_stable" Utility.Hash.prop_mac_stable
	, testProperty "prop_schedule_roundtrips" Utility.Scheduled.QuickCheck.prop_schedule_roundtrips
	, testProperty "prop_past_sane" Utility.Scheduled.prop_past_sane
	, testProperty "prop_duration_roundtrips" Utility.HumanTime.prop_duration_roundtrips
	, testProperty "prop_metadata_sane" Types.MetaData.prop_metadata_sane
	, testProperty "prop_metadata_serialize" Types.MetaData.prop_metadata_serialize
	, testProperty "prop_branchView_legal" Logs.View.prop_branchView_legal
	, testProperty "prop_viewPath_roundtrips" Annex.View.prop_viewPath_roundtrips
	, testProperty "prop_view_roundtrips" Annex.View.prop_view_roundtrips
	, testProperty "prop_viewedFile_rountrips" Annex.View.ViewedFile.prop_viewedFile_roundtrips
	, testProperty "prop_b64_roundtrips" Utility.Base64.prop_b64_roundtrips
	, testProperty "prop_standardGroups_parse" Logs.PreferredContent.prop_standardGroups_parse
	]

{- These tests set up the test environment, but also test some basic parts
 - of git-annex. They are always run before the unitTests. -}
initTests :: TestTree
initTests = testGroup "Init Tests"
	[ testCase "init" test_init
	, testCase "add" test_add
	]

unitTests :: String -> TestTree
unitTests note = testGroup ("Unit Tests " ++ note)
	[ testCase "add dup" test_add_dup
	, testCase "add extras" test_add_extras
	, testCase "shared clone" test_shared_clone
	, testCase "log" test_log
	, testCase "import" test_import
	, testCase "reinject" test_reinject
	, testCase "unannex (no copy)" test_unannex_nocopy
	, testCase "unannex (with copy)" test_unannex_withcopy
	, testCase "drop (no remote)" test_drop_noremote
	, testCase "drop (with remote)" test_drop_withremote
	, testCase "drop (untrusted remote)" test_drop_untrustedremote
	, testCase "get" test_get
	, testCase "get (ssh remote)" test_get_ssh_remote
	, testCase "move" test_move
	, testCase "move (ssh remote)" test_move_ssh_remote
	, testCase "copy" test_copy
	, testCase "lock" test_lock
	, testCase "lock (v7 --force)" test_lock_v7_force
	, testCase "edit (no pre-commit)" test_edit
	, testCase "edit (pre-commit)" test_edit_precommit
	, testCase "partial commit" test_partial_commit
	, testCase "fix" test_fix
	, testCase "direct" test_direct
	, testCase "trust" test_trust
	, testCase "fsck (basics)" test_fsck_basic
	, testCase "fsck (bare)" test_fsck_bare
	, testCase "fsck (local untrusted)" test_fsck_localuntrusted
	, testCase "fsck (remote untrusted)" test_fsck_remoteuntrusted
	, testCase "fsck --from remote" test_fsck_fromremote
	, testCase "migrate" test_migrate
	, testCase "migrate (via gitattributes)" test_migrate_via_gitattributes
	, testCase "unused" test_unused
	, testCase "describe" test_describe
	, testCase "find" test_find
	, testCase "merge" test_merge
	, testCase "info" test_info
	, testCase "version" test_version
	, testCase "sync" test_sync
	, testCase "union merge regression" test_union_merge_regression
	, testCase "adjusted branch merge regression" test_adjusted_branch_merge_regression
	, testCase "adjusted branch subtree regression" test_adjusted_branch_subtree_regression
	, testCase "conflict resolution" test_conflict_resolution
	, testCase "conflict resolution (adjusted branch)" test_conflict_resolution_adjusted_branch
	, testCase "conflict resolution movein regression" test_conflict_resolution_movein_regression
	, testCase "conflict resolution (mixed directory and file)" test_mixed_conflict_resolution
	, testCase "conflict resolution symlink bit" test_conflict_resolution_symlink_bit
	, testCase "conflict resolution (uncommitted local file)" test_uncommitted_conflict_resolution
	, testCase "conflict resolution (removed file)" test_remove_conflict_resolution
	, testCase "conflict resolution (nonannexed file)" test_nonannexed_file_conflict_resolution
	, testCase "conflict resolution (nonannexed symlink)" test_nonannexed_symlink_conflict_resolution
	, testCase "conflict resolution (mixed locked and unlocked file)" test_mixed_lock_conflict_resolution
	, testCase "map" test_map
	, testCase "uninit" test_uninit
	, testCase "uninit (in git-annex branch)" test_uninit_inbranch
	, testCase "upgrade" test_upgrade
	, testCase "whereis" test_whereis
	, testCase "hook remote" test_hook_remote
	, testCase "directory remote" test_directory_remote
	, testCase "rsync remote" test_rsync_remote
	, testCase "bup remote" test_bup_remote
	, testCase "crypto" test_crypto
	, testCase "preferred content" test_preferred_content
	, testCase "add subdirs" test_add_subdirs
	, testCase "addurl" test_addurl
	]

-- this test case create the main repo
test_init :: Assertion
test_init = innewrepo $ do
	ver <- annexVersion <$> getTestMode
	if ver == Annex.Version.defaultVersion
		then git_annex "init" [reponame] @? "init failed"
		else git_annex "init" [reponame, "--version", show (fromRepoVersion ver)] @? "init failed"
	setupTestMode
  where
	reponame = "test repo"

-- this test case runs in the main repo, to set up a basic
-- annexed file that later tests will use
test_add :: Assertion
test_add = inmainrepo $ do
	writecontent annexedfile $ content annexedfile
	add_annex annexedfile @? "add failed"
	annexed_present annexedfile
	writecontent sha1annexedfile $ content sha1annexedfile
	git_annex "add" [sha1annexedfile, "--backend=SHA1"] @? "add with SHA1 failed"
	whenM (unlockedFiles <$> getTestMode) $
		git_annex "unlock" [sha1annexedfile] @? "unlock failed"
	annexed_present sha1annexedfile
	checkbackend sha1annexedfile backendSHA1
	ifM (annexeval Config.isDirect)
		( do
			writecontent ingitfile $ content ingitfile
			not <$> boolSystem "git" [Param "add", File ingitfile] @? "git add failed to fail in direct mode"
			nukeFile ingitfile
			git_annex "sync" [] @? "sync failed"
		, do
			writecontent ingitfile $ content ingitfile
			boolSystem "git" [Param "add", File ingitfile] @? "git add failed"
			boolSystem "git" [Param "commit", Param "-q", Param "-m", Param "commit"] @? "git commit failed"
			git_annex "add" [ingitfile] @? "add ingitfile should be no-op"
			unannexed ingitfile
		)

test_add_dup :: Assertion
test_add_dup = intmpclonerepo $ do
	writecontent annexedfiledup $ content annexedfiledup
	add_annex annexedfiledup @? "add of second file with same content failed"
	annexed_present annexedfiledup
	annexed_present annexedfile

test_add_extras :: Assertion
test_add_extras = intmpclonerepo $ do
	writecontent wormannexedfile $ content wormannexedfile
	git_annex "add" [wormannexedfile, "--backend=WORM"] @? "add with WORM failed"
	whenM (unlockedFiles <$> getTestMode) $
		git_annex "unlock" [wormannexedfile] @? "unlock failed"
	annexed_present wormannexedfile
	checkbackend wormannexedfile backendWORM

test_shared_clone :: Assertion
test_shared_clone = intmpsharedclonerepo $ do
	v <- catchMaybeIO $ Utility.Process.readProcess "git" 
		[ "config"
		, "--bool"
		, "--get"
		, "annex.hardlink"
		]
	v == Just "true\n"
		@? "shared clone of repo did not get annex.hardlink set"

test_log :: Assertion
test_log = intmpclonerepo $ do
	git_annex "log" [annexedfile] @? "log failed"

test_import :: Assertion
test_import = intmpclonerepo $ Utility.Tmp.Dir.withTmpDir "importtest" $ \importdir -> do
	(toimport1, importf1, imported1) <- mktoimport importdir "import1"
	git_annex "import" [toimport1] @? "import failed"
	annexed_present_imported imported1
	checkdoesnotexist importf1

	(toimport2, importf2, imported2) <- mktoimport importdir "import2"
	git_annex "import" [toimport2] @? "import of duplicate failed"
	annexed_present_imported imported2
	checkdoesnotexist importf2

	(toimport3, importf3, imported3) <- mktoimport importdir "import3"
	git_annex "import" ["--skip-duplicates", toimport3]
		@? "import of duplicate with --skip-duplicates failed"
	checkdoesnotexist imported3
	checkexists importf3
	git_annex "import" ["--clean-duplicates", toimport3]
		@? "import of duplicate with --clean-duplicates failed"
	checkdoesnotexist imported3
	checkdoesnotexist importf3
	
	(toimport4, importf4, imported4) <- mktoimport importdir "import4"
	git_annex "import" ["--deduplicate", toimport4] @? "import --deduplicate failed"
	checkdoesnotexist imported4
	checkdoesnotexist importf4
	
	(toimport5, importf5, imported5) <- mktoimport importdir "import5"
	git_annex "import" ["--duplicate", toimport5] @? "import --duplicate failed"
	annexed_present_imported imported5
	checkexists importf5
	
	git_annex "drop" ["--force", imported1, imported2, imported5] @? "drop failed"
	annexed_notpresent_imported imported2
	(toimportdup, importfdup, importeddup) <- mktoimport importdir "importdup"
	git_annex_shouldfail "import" ["--clean-duplicates", toimportdup] 
		@? "import of missing duplicate with --clean-duplicates failed to fail"
	checkdoesnotexist importeddup
	checkexists importfdup
  where
	mktoimport importdir subdir = do
		createDirectory (importdir </> subdir)
		let importf = subdir </> "f"
		writecontent (importdir </> importf) (content importf)
		return (importdir </> subdir, importdir </> importf, importf)
	annexed_present_imported f = ifM (annexeval Config.crippledFileSystem)
		( annexed_present_unlocked f
		, annexed_present_locked f
		)
	annexed_notpresent_imported f = ifM (annexeval Config.crippledFileSystem)
		( annexed_notpresent_unlocked f
		, annexed_notpresent_locked f
		)

test_reinject :: Assertion
test_reinject = intmpclonerepoInDirect $ do
	git_annex "drop" ["--force", sha1annexedfile] @? "drop failed"
	annexed_notpresent sha1annexedfile
	writecontent tmp $ content sha1annexedfile
	key <- Key.key2file <$> getKey backendSHA1 tmp
	git_annex "reinject" [tmp, sha1annexedfile] @? "reinject failed"
	annexed_present sha1annexedfile
	-- fromkey can't be used on a crippled filesystem, since it makes a
	-- symlink
	unlessM (annexeval Config.crippledFileSystem) $ do
		git_annex "fromkey" [key, sha1annexedfiledup] @? "fromkey failed for dup"
		annexed_present_locked sha1annexedfiledup
  where
	tmp = "tmpfile"

test_unannex_nocopy :: Assertion
test_unannex_nocopy = intmpclonerepo $ do
	annexed_notpresent annexedfile
	git_annex "unannex" [annexedfile] @? "unannex failed with no copy"
	annexed_notpresent annexedfile

test_unannex_withcopy :: Assertion
test_unannex_withcopy = intmpclonerepo $ do
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	git_annex "unannex" [annexedfile, sha1annexedfile] @? "unannex failed"
	unannexed annexedfile
	git_annex "unannex" [annexedfile] @? "unannex failed on non-annexed file"
	unannexed annexedfile
	unlessM (annexeval Config.isDirect) $ do
		git_annex "unannex" [ingitfile] @? "unannex ingitfile should be no-op"
		unannexed ingitfile

test_drop_noremote :: Assertion
test_drop_noremote = intmpclonerepo $ do
	git_annex "get" [annexedfile] @? "get failed"
	boolSystem "git" [Param "remote", Param "rm", Param "origin"]
		@? "git remote rm origin failed"
	git_annex_shouldfail "drop" [annexedfile] @? "drop wrongly succeeded with no known copy of file"
	annexed_present annexedfile
	git_annex "drop" ["--force", annexedfile] @? "drop --force failed"
	annexed_notpresent annexedfile
	git_annex "drop" [annexedfile] @? "drop of dropped file failed"
	unlessM (annexeval Config.isDirect) $ do
		git_annex "drop" [ingitfile] @? "drop ingitfile should be no-op"
		unannexed ingitfile

test_drop_withremote :: Assertion
test_drop_withremote = intmpclonerepo $ do
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	git_annex "numcopies" ["2"] @? "numcopies config failed"
	git_annex_shouldfail "drop" [annexedfile] @? "drop succeeded although numcopies is not satisfied"
	git_annex "numcopies" ["1"] @? "numcopies config failed"
	git_annex "drop" [annexedfile] @? "drop failed though origin has copy"
	annexed_notpresent annexedfile
	-- make sure that the correct symlink is staged for the file
	-- after drop
	git_annex_expectoutput "status" [] []
	inmainrepo $ annexed_present annexedfile

test_drop_untrustedremote :: Assertion
test_drop_untrustedremote = intmpclonerepo $ do
	git_annex "untrust" ["origin"] @? "untrust of origin failed"
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	git_annex_shouldfail "drop" [annexedfile] @? "drop wrongly succeeded with only an untrusted copy of the file"
	annexed_present annexedfile
	inmainrepo $ annexed_present annexedfile

test_get :: Assertion
test_get = test_get' intmpclonerepo

test_get_ssh_remote :: Assertion
test_get_ssh_remote = test_get' (with_ssh_origin intmpclonerepo)

test_get' :: (Assertion -> Assertion) -> Assertion
test_get' setup = setup $ do
	inmainrepo $ annexed_present annexedfile
	annexed_notpresent annexedfile
	git_annex "get" [annexedfile] @? "get of file failed"
	inmainrepo $ annexed_present annexedfile
	annexed_present annexedfile
	git_annex "get" [annexedfile] @? "get of file already here failed"
	inmainrepo $ annexed_present annexedfile
	annexed_present annexedfile
	unlessM (annexeval Config.isDirect) $ do
		inmainrepo $ unannexed ingitfile
		unannexed ingitfile
		git_annex "get" [ingitfile] @? "get ingitfile should be no-op"
		inmainrepo $ unannexed ingitfile
		unannexed ingitfile

test_move :: Assertion
test_move = test_move' intmpclonerepo

test_move_ssh_remote :: Assertion
test_move_ssh_remote = test_move' (with_ssh_origin intmpclonerepo)

test_move' :: (Assertion -> Assertion) -> Assertion
test_move' setup = setup $ do
	annexed_notpresent annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "move" ["--from", "origin", annexedfile] @? "move --from of file failed"
	annexed_present annexedfile
	inmainrepo $ annexed_notpresent annexedfile
	git_annex "move" ["--from", "origin", annexedfile] @? "move --from of file already here failed"
	annexed_present annexedfile
	inmainrepo $ annexed_notpresent annexedfile
	git_annex "move" ["--to", "origin", annexedfile] @? "move --to of file failed"
	inmainrepo $ annexed_present annexedfile
	annexed_notpresent annexedfile
	git_annex "move" ["--to", "origin", annexedfile] @? "move --to of file already there failed"
	inmainrepo $ annexed_present annexedfile
	annexed_notpresent annexedfile
	unlessM (annexeval Config.isDirect) $ do
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile
		git_annex "move" ["--to", "origin", ingitfile] @? "move of ingitfile should be no-op"
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile
		git_annex "move" ["--from", "origin", ingitfile] @? "move of ingitfile should be no-op"
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile

test_copy :: Assertion
test_copy = intmpclonerepo $ do
	annexed_notpresent annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "copy" ["--from", "origin", annexedfile] @? "copy --from of file failed"
	annexed_present annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "copy" ["--from", "origin", annexedfile] @? "copy --from of file already here failed"
	annexed_present annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "copy" ["--to", "origin", annexedfile] @? "copy --to of file already there failed"
	annexed_present annexedfile
	inmainrepo $ annexed_present annexedfile
	git_annex "move" ["--to", "origin", annexedfile] @? "move --to of file already there failed"
	annexed_notpresent annexedfile
	inmainrepo $ annexed_present annexedfile
	unlessM (annexeval Config.isDirect) $ do
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile
		git_annex "copy" ["--to", "origin", ingitfile] @? "copy of ingitfile should be no-op"
		unannexed ingitfile
		inmainrepo $ unannexed ingitfile
		git_annex "copy" ["--from", "origin", ingitfile] @? "copy of ingitfile should be no-op"
		checkregularfile ingitfile
		checkcontent ingitfile

test_preferred_content :: Assertion
test_preferred_content = intmpclonerepo $ do
	annexed_notpresent annexedfile
	-- get/copy --auto looks only at numcopies when preferred content is not
	-- set, and with 1 copy existing, does not get the file.
	git_annex "get" ["--auto", annexedfile] @? "get --auto of file failed with default preferred content"
	annexed_notpresent annexedfile
	git_annex "copy" ["--from", "origin", "--auto", annexedfile] @? "copy --auto --from of file failed with default preferred content"
	annexed_notpresent annexedfile

	git_annex "wanted" [".", "standard"] @? "set expression to standard failed"
	git_annex "group" [".", "client"] @? "set group to standard failed"
	git_annex "get" ["--auto", annexedfile] @? "get --auto of file failed for client"
	annexed_present annexedfile
	git_annex "drop" [annexedfile] @? "drop of file failed"
	git_annex "copy" ["--from", "origin", "--auto", annexedfile] @? "copy --auto --from of file failed for client"
	annexed_present annexedfile
	git_annex "ungroup" [".", "client"] @? "ungroup failed"

	git_annex "wanted" [".", "standard"] @? "set expression to standard failed"
	git_annex "group" [".", "manual"] @? "set group to manual failed"
	-- drop --auto with manual leaves the file where it is
	git_annex "drop" ["--auto", annexedfile] @? "drop --auto of file failed with manual preferred content"
	annexed_present annexedfile
	git_annex "drop" [annexedfile] @? "drop of file failed"
	annexed_notpresent annexedfile
	-- copy/get --auto with manual does not get the file
	git_annex "get" ["--auto", annexedfile] @? "get --auto of file failed with manual preferred content"
	annexed_notpresent annexedfile
	git_annex "copy" ["--from", "origin", "--auto", annexedfile] @? "copy --auto --from of file failed with manual preferred content"
	annexed_notpresent annexedfile
	git_annex "ungroup" [".", "client"] @? "ungroup failed"
	
	git_annex "wanted" [".", "exclude=*"] @? "set expression to exclude=* failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "drop" ["--auto", annexedfile] @? "drop --auto of file failed with exclude=*"
	annexed_notpresent annexedfile
	git_annex "get" ["--auto", annexedfile] @? "get --auto of file failed with exclude=*"
	annexed_notpresent annexedfile

test_lock :: Assertion
test_lock = intmpclonerepoInDirect $ do
	annexed_notpresent annexedfile
	unlessM (annexeval Annex.Version.versionSupportsUnlockedPointers) $
		ifM (unlockedFiles <$> getTestMode)
			( git_annex_shouldfail "lock" [annexedfile] @? "lock failed to fail with not present file"
			, git_annex_shouldfail "unlock" [annexedfile] @? "unlock failed to fail with not present file"
			)
	annexed_notpresent annexedfile

	-- regression test: unlock of newly added, not committed file
	-- should fail in v5 mode. In v7 mode, this is allowed.
	writecontent "newfile" "foo"
	git_annex "add" ["newfile"] @? "add new file failed"
	ifM (annexeval Annex.Version.versionSupportsUnlockedPointers)
		( git_annex "unlock" ["newfile"] @? "unlock failed on newly added, never committed file in v7 repository"
		, git_annex_shouldfail "unlock" ["newfile"] @? "unlock failed to fail on newly added, never committed file in v5 repository"
		)

	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "unlock" [annexedfile] @? "unlock failed"		
	unannexed annexedfile
	-- write different content, to verify that lock
	-- throws it away
	changecontent annexedfile
	writecontent annexedfile $ content annexedfile ++ "foo"
	git_annex_shouldfail "lock" [annexedfile] @? "lock failed to fail without --force"
	git_annex "lock" ["--force", annexedfile] @? "lock --force failed"
	-- In v7 mode, the original content of the file is not always
	-- preserved after modification, so re-get it.
	git_annex "get" [annexedfile] @? "get of file failed after lock --force"
	annexed_present_locked annexedfile
	git_annex "unlock" [annexedfile] @? "unlock failed"		
	unannexed annexedfile
	changecontent annexedfile
	ifM (annexeval Annex.Version.versionSupportsUnlockedPointers)
		( do
			boolSystem "git" [Param "add", Param annexedfile] @? "add of modified file failed"
			runchecks [checkregularfile, checkwritable] annexedfile
		, do
			git_annex "add" [annexedfile] @? "add of modified file failed"
			runchecks [checklink, checkunwritable] annexedfile
		)
	c <- readFile annexedfile
	assertEqual "content of modified file" c (changedcontent annexedfile)
	r' <- git_annex "drop" [annexedfile]
	not r' @? "drop wrongly succeeded with no known copy of modified file"

-- Regression test: lock --force when work tree file
-- was modified lost the (unmodified) annex object.
-- (Only occurred when the keys database was out of sync.)
test_lock_v7_force :: Assertion
test_lock_v7_force = intmpclonerepoInDirect $ do
	git_annex "upgrade" [] @? "upgrade failed"
	whenM (annexeval Annex.Version.versionSupportsUnlockedPointers) $ do
		git_annex "get" [annexedfile] @? "get of file failed"
		git_annex "unlock" [annexedfile] @? "unlock failed in v7 mode"
		annexeval $ do
			Just k <- Annex.WorkTree.lookupFile annexedfile
			Database.Keys.removeInodeCaches k
			Database.Keys.closeDb
			liftIO . nukeFile =<< Annex.fromRepo Annex.Locations.gitAnnexKeysDbIndexCache
		writecontent annexedfile "test_lock_v7_force content"
		git_annex_shouldfail "lock" [annexedfile] @? "lock of modified file failed to fail in v7 mode"
		git_annex "lock" ["--force", annexedfile] @? "lock --force of modified file failed in v7 mode"
		annexed_present_locked annexedfile

test_edit :: Assertion
test_edit = test_edit' False

test_edit_precommit :: Assertion
test_edit_precommit = test_edit' True

test_edit' :: Bool -> Assertion
test_edit' precommit = intmpclonerepoInDirect $ do
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "edit" [annexedfile] @? "edit failed"
	unannexed annexedfile
	changecontent annexedfile
	boolSystem "git" [Param "add", File annexedfile]
		@? "git add of edited file failed"
	if precommit
		then git_annex "pre-commit" []
			@? "pre-commit failed"
		else boolSystem "git" [Param "commit", Param "-q", Param "-m", Param "contentchanged"]
			@? "git commit of edited file failed"
	ifM (annexeval Annex.Version.versionSupportsUnlockedPointers)
		( runchecks [checkregularfile, checkwritable] annexedfile
		, runchecks [checklink, checkunwritable] annexedfile
		)
	c <- readFile annexedfile
	assertEqual "content of modified file" c (changedcontent annexedfile)
	git_annex_shouldfail "drop" [annexedfile] @? "drop wrongly succeeded with no known copy of modified file"

test_partial_commit :: Assertion
test_partial_commit = intmpclonerepoInDirect $ do
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "unlock" [annexedfile] @? "unlock failed"
	changecontent annexedfile
	ifM (annexeval Annex.Version.versionSupportsUnlockedPointers)
		( boolSystem "git" [Param "commit", Param "-q", Param "-m", Param "test", File annexedfile]
			@? "partial commit of unlocked file should be allowed in v7 repository"
		, not <$> boolSystem "git" [Param "commit", Param "-q", Param "-m", Param "test", File annexedfile]
			@? "partial commit of unlocked file not blocked by pre-commit hook"
		)

test_fix :: Assertion
test_fix = intmpclonerepoInDirect $ unlessM (unlockedFiles <$> getTestMode) $ do
	annexed_notpresent annexedfile
	git_annex "fix" [annexedfile] @? "fix of not present failed"
	annexed_notpresent annexedfile
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "fix" [annexedfile] @? "fix of present file failed"
	annexed_present annexedfile
	createDirectory subdir
	boolSystem "git" [Param "mv", File annexedfile, File subdir]
		@? "git mv failed"
	git_annex "fix" [newfile] @? "fix of moved file failed"
	runchecks [checklink, checkunwritable] newfile
	c <- readFile newfile
	assertEqual "content of moved file" c (content annexedfile)
  where
	subdir = "s"
	newfile = subdir ++ "/" ++ annexedfile

test_direct :: Assertion
test_direct = intmpclonerepoInDirect $ do
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	ifM (annexeval Annex.Version.versionSupportsUnlockedPointers)
		( git_annex_shouldfail "direct" [] @? "switch to direct mode failed to fail in v7 repository"
		, do
			git_annex "direct" [] @? "switch to direct mode failed"
			annexed_present annexedfile
			git_annex "indirect" [] @? "switch to indirect mode failed"
		)

test_trust :: Assertion
test_trust = intmpclonerepo $ do
	git_annex "trust" [repo] @? "trust failed"
	trustcheck Logs.Trust.Trusted "trusted 1"
	git_annex "trust" [repo] @? "trust of trusted failed"
	trustcheck Logs.Trust.Trusted "trusted 2"
	git_annex "untrust" [repo] @? "untrust failed"
	trustcheck Logs.Trust.UnTrusted "untrusted 1"
	git_annex "untrust" [repo] @? "untrust of untrusted failed"
	trustcheck Logs.Trust.UnTrusted "untrusted 2"
	git_annex "dead" [repo] @? "dead failed"
	trustcheck Logs.Trust.DeadTrusted "deadtrusted 1"
	git_annex "dead" [repo] @? "dead of dead failed"
	trustcheck Logs.Trust.DeadTrusted "deadtrusted 2"
	git_annex "semitrust" [repo] @? "semitrust failed"
	trustcheck Logs.Trust.SemiTrusted "semitrusted 1"
	git_annex "semitrust" [repo] @? "semitrust of semitrusted failed"
	trustcheck Logs.Trust.SemiTrusted "semitrusted 2"
  where
	repo = "origin"
	trustcheck expected msg = do
		present <- annexeval $ do
			l <- Logs.Trust.trustGet expected
			u <- Remote.nameToUUID repo
			return $ u `elem` l
		assertBool msg present

test_fsck_basic :: Assertion
test_fsck_basic = intmpclonerepo $ do
	git_annex "fsck" [] @? "fsck failed"
	git_annex "numcopies" ["2"] @? "numcopies config failed"
	fsck_should_fail "numcopies unsatisfied"
	git_annex "numcopies" ["1"] @? "numcopies config failed"
	corrupt annexedfile
	corrupt sha1annexedfile
  where
	corrupt f = do
		git_annex "get" [f] @? "get of file failed"
		Utility.FileMode.allowWrite f
		writecontent f (changedcontent f)
		ifM (annexeval Config.isDirect <||> unlockedFiles <$> getTestMode)
			( git_annex "fsck" [] @? "fsck failed on unlocked file with changed file content"
			, git_annex_shouldfail "fsck" [] @? "fsck failed to fail with corrupted file content"
			)
		git_annex "fsck" [] @? "fsck unexpectedly failed again; previous one did not fix problem with " ++ f

test_fsck_bare :: Assertion
test_fsck_bare = intmpbareclonerepo $
	git_annex "fsck" [] @? "fsck failed"

test_fsck_localuntrusted :: Assertion
test_fsck_localuntrusted = intmpclonerepo $ do
	git_annex "get" [annexedfile] @? "get failed"
	git_annex "untrust" ["origin"] @? "untrust of origin repo failed"
	git_annex "untrust" ["."] @? "untrust of current repo failed"
	fsck_should_fail "content only available in untrusted (current) repository"
	git_annex "trust" ["."] @? "trust of current repo failed"
	git_annex "fsck" [annexedfile] @? "fsck failed on file present in trusted repo"

test_fsck_remoteuntrusted :: Assertion
test_fsck_remoteuntrusted = intmpclonerepo $ do
	git_annex "numcopies" ["2"] @? "numcopies config failed"
	git_annex "get" [annexedfile] @? "get failed"
	git_annex "get" [sha1annexedfile] @? "get failed"
	git_annex "fsck" [] @? "fsck failed with numcopies=2 and 2 copies"
	git_annex "untrust" ["origin"] @? "untrust of origin failed"
	fsck_should_fail "content not replicated to enough non-untrusted repositories"

test_fsck_fromremote :: Assertion
test_fsck_fromremote = intmpclonerepo $ do
	git_annex "fsck" ["--from", "origin"] @? "fsck --from origin failed"

fsck_should_fail :: String -> Assertion
fsck_should_fail m = git_annex_shouldfail "fsck" []
	@? "fsck failed to fail with " ++ m

test_migrate :: Assertion
test_migrate = test_migrate' False

test_migrate_via_gitattributes :: Assertion
test_migrate_via_gitattributes = test_migrate' True

test_migrate' :: Bool -> Assertion
test_migrate' usegitattributes = intmpclonerepoInDirect $ do
	annexed_notpresent annexedfile
	annexed_notpresent sha1annexedfile
	git_annex "migrate" [annexedfile] @? "migrate of not present failed"
	git_annex "migrate" [sha1annexedfile] @? "migrate of not present failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	git_annex "get" [sha1annexedfile] @? "get of file failed"
	annexed_present annexedfile
	annexed_present sha1annexedfile
	if usegitattributes
		then do
			writeFile ".gitattributes" "* annex.backend=SHA1"
			git_annex "migrate" [sha1annexedfile]
				@? "migrate sha1annexedfile failed"
			git_annex "migrate" [annexedfile]
				@? "migrate annexedfile failed"
		else do
			git_annex "migrate" [sha1annexedfile, "--backend", "SHA1"]
				@? "migrate sha1annexedfile failed"
			git_annex "migrate" [annexedfile, "--backend", "SHA1"]
				@? "migrate annexedfile failed"
	annexed_present annexedfile
	annexed_present sha1annexedfile
	checkbackend annexedfile backendSHA1
	checkbackend sha1annexedfile backendSHA1

	-- check that reversing a migration works
	writeFile ".gitattributes" "* annex.backend=SHA256"
	git_annex "migrate" [sha1annexedfile]
		@? "migrate sha1annexedfile failed"
	git_annex "migrate" [annexedfile]
		@? "migrate annexedfile failed"
	annexed_present annexedfile
	annexed_present sha1annexedfile
	checkbackend annexedfile backendSHA256
	checkbackend sha1annexedfile backendSHA256

test_unused :: Assertion
-- This test is broken in direct mode
test_unused = intmpclonerepoInDirect $ do
	checkunused [] "in new clone"
	git_annex "get" [annexedfile] @? "get of file failed"
	git_annex "get" [sha1annexedfile] @? "get of file failed"
	annexedfilekey <- getKey backendSHA256E annexedfile
	sha1annexedfilekey <- getKey backendSHA1 sha1annexedfile
	checkunused [] "after get"
	boolSystem "git" [Param "rm", Param "-fq", File annexedfile] @? "git rm failed"
	checkunused [] "after rm"
	boolSystem "git" [Param "commit", Param "-q", Param "-m", Param "foo"] @? "git commit failed"
	checkunused [] "after commit"
	-- unused checks origin/master; once it's gone it is really unused
	boolSystem "git" [Param "remote", Param "rm", Param "origin"] @? "git remote rm origin failed"
	checkunused [annexedfilekey] "after origin branches are gone"
	boolSystem "git" [Param "rm", Param "-fq", File sha1annexedfile] @? "git rm failed"
	boolSystem "git" [Param "commit", Param "-q", Param "-m", Param "foo"] @? "git commit failed"
	checkunused [annexedfilekey, sha1annexedfilekey] "after rm sha1annexedfile"

	-- good opportunity to test dropkey also
	git_annex "dropkey" ["--force", Key.key2file annexedfilekey]
		@? "dropkey failed"
	checkunused [sha1annexedfilekey] ("after dropkey --force " ++ Key.key2file annexedfilekey)

	git_annex_shouldfail "dropunused" ["1"] @? "dropunused failed to fail without --force"
	git_annex "dropunused" ["--force", "1"] @? "dropunused failed"
	checkunused [] "after dropunused"
	git_annex_shouldfail "dropunused" ["--force", "10", "501"] @? "dropunused failed to fail on bogus numbers"

	-- Unused used to miss renamed symlinks that were not staged
	-- and pointed at annexed content, and think that content was unused.
	-- This is only relevant when using locked files; if the file is
	-- unlocked, the work tree file has the content, and there's no way
	-- to associate it with the key.
	unlessM (unlockedFiles <$> getTestMode) $ do
		writecontent "unusedfile" "unusedcontent"
		git_annex "add" ["unusedfile"] @? "add of unusedfile failed"
		unusedfilekey <- getKey backendSHA256E "unusedfile"
		renameFile "unusedfile" "unusedunstagedfile"
		boolSystem "git" [Param "rm", Param "-qf", File "unusedfile"] @? "git rm failed"
		checkunused [] "with unstaged link"
		removeFile "unusedunstagedfile"
		checkunused [unusedfilekey] "with renamed link deleted"

	-- unused used to miss symlinks that were deleted or modified
	-- manually
	writecontent "unusedfile" "unusedcontent"
	git_annex "add" ["unusedfile"] @? "add of unusedfile failed"
	boolSystem "git" [Param "add", File "unusedfile"] @? "git add failed"
	unusedfilekey' <- getKey backendSHA256E "unusedfile"
	checkunused [] "with staged deleted link"
	boolSystem "git" [Param "rm", Param "-qf", File "unusedfile"] @? "git rm failed"
	checkunused [unusedfilekey'] "with staged link deleted"

	-- unused used to false positive on symlinks that were
	-- deleted or modified manually, but not staged as such
	writecontent "unusedfile" "unusedcontent"
	git_annex "add" ["unusedfile"] @? "add of unusedfile failed"
	boolSystem "git" [Param "add", File "unusedfile"] @? "git add failed"
	checkunused [] "with staged file"
	removeFile "unusedfile"
	checkunused [] "with staged deleted file"

	-- When an unlocked file is modified, git diff will cause git-annex
	-- to add its content to the repository. Make sure that's not
	-- found as unused.
	whenM (unlockedFiles <$> getTestMode) $ do
		let f = "unlockedfile"
		writecontent f "unlockedcontent1"
		boolSystem "git" [Param "add", File "unlockedfile"] @? "git add failed"
		checkunused [] "with unlocked file before modification"
		writecontent f "unlockedcontent2"
		checkunused [] "with unlocked file after modification"
		not <$> boolSystem "git" [Param "diff", Param "--quiet", File f] @? "git diff did not show changes to unlocked file"
		-- still nothing unused because one version is in the index
		-- and the other is in the work tree
		checkunused [] "with unlocked file after git diff"
  where
	checkunused expectedkeys desc = do
		git_annex "unused" [] @? "unused failed"
		unusedmap <- annexeval $ Logs.Unused.readUnusedMap ""
		let unusedkeys = M.elems unusedmap
		assertEqual ("unused keys differ " ++ desc)
			(sort expectedkeys) (sort unusedkeys)

test_describe :: Assertion
test_describe = intmpclonerepo $ do
	git_annex "describe" [".", "this repo"] @? "describe 1 failed"
	git_annex "describe" ["origin", "origin repo"] @? "describe 2 failed"

test_find :: Assertion
test_find = intmpclonerepo $ do
	annexed_notpresent annexedfile
	git_annex_expectoutput "find" [] []
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	annexed_notpresent sha1annexedfile
	git_annex_expectoutput "find" [] [annexedfile]
	git_annex_expectoutput "find" ["--exclude", annexedfile, "--and", "--exclude", sha1annexedfile] []
	git_annex_expectoutput "find" ["--include", annexedfile] [annexedfile]
	git_annex_expectoutput "find" ["--not", "--in", "origin"] []
	git_annex_expectoutput "find" ["--copies", "1", "--and", "--not", "--copies", "2"] [sha1annexedfile]
	git_annex_expectoutput "find" ["--inbackend", "SHA1"] [sha1annexedfile]
	git_annex_expectoutput "find" ["--inbackend", "WORM"] []

	{- --include=* should match files in subdirectories too,
	 - and --exclude=* should exclude them. -}
	createDirectory "dir"
	writecontent "dir/subfile" "subfile"
	git_annex "add" ["dir"] @? "add of subdir failed"
	git_annex_expectoutput "find" ["--include", "*", "--exclude", annexedfile, "--exclude", sha1annexedfile] ["dir/subfile"]
	git_annex_expectoutput "find" ["--exclude", "*"] []

test_merge :: Assertion
test_merge = intmpclonerepo $
	git_annex "merge" [] @? "merge failed"

test_info :: Assertion
test_info = intmpclonerepo $ do
	json <- BU8.fromString <$> git_annex_output "info" ["--json"]
	case Utility.Aeson.eitherDecode json :: Either String Utility.Aeson.Value of
		Right _ -> return ()
		Left e -> assertFailure e

test_version :: Assertion
test_version = intmpclonerepo $
	git_annex "version" [] @? "version failed"

test_sync :: Assertion
test_sync = intmpclonerepo $ do
	git_annex "sync" [] @? "sync failed"
	{- Regression test for bug fixed in 
	 - 7b0970b340d7faeb745c666146c7f701ec71808f, where in direct mode
	 - sync committed the symlink standin file to the annex. -}
	git_annex_expectoutput "find" ["--in", "."] []
	{- Regression test for bug fixed in
	 - 039e83ed5d1a11fd562cce55b8429c840d72443e, where a present
	 - wanted file was dropped. -}
	git_annex "get" [annexedfile] @? "get failed"
	git_annex_expectoutput "find" ["--in", "."] [annexedfile]
	git_annex "wanted" [".", "present"] @? "wanted failed"
	git_annex "sync" ["--content"] @? "sync failed"
	git_annex_expectoutput "find" ["--in", "."] [annexedfile]
	git_annex "drop" [annexedfile] @? "drop failed"
	git_annex_expectoutput "find" ["--in", "."] []
	git_annex "sync" ["--content"] @? "sync failed"
	git_annex_expectoutput "find" ["--in", "."] []

{- Regression test for union merge bug fixed in
 - 0214e0fb175a608a49b812d81b4632c081f63027 -}
test_union_merge_regression :: Assertion
test_union_merge_regression =
	{- We need 3 repos to see this bug. -}
	withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 ->
			withtmpclonerepo $ \r3 -> do
				forM_ [r1, r2, r3] $ \r -> indir r $ do
					when (r /= r1) $
						boolSystem "git" [Param "remote", Param "add", Param "r1", File ("../../" ++ r1)] @? "remote add"
					when (r /= r2) $
						boolSystem "git" [Param "remote", Param "add", Param "r2", File ("../../" ++ r2)] @? "remote add"
					when (r /= r3) $
						boolSystem "git" [Param "remote", Param "add", Param "r3", File ("../../" ++ r3)] @? "remote add"
					git_annex "get" [annexedfile] @? "get failed"
					boolSystem "git" [Param "remote", Param "rm", Param "origin"] @? "remote rm"
				forM_ [r3, r2, r1] $ \r -> indir r $
					git_annex "sync" [] @? ("sync failed in " ++ r)
				forM_ [r3, r2] $ \r -> indir r $
					git_annex "drop" ["--force", annexedfile] @? ("drop failed in " ++ r)
				indir r1 $ do
					git_annex "sync" [] @? "sync failed in r1"
					git_annex_expectoutput "find" ["--in", "r3"] []
					{- This was the bug. The sync
					 - mangled location log data and it
					 - thought the file was still in r2 -}
					git_annex_expectoutput "find" ["--in", "r2"] []

{- Regression test for the automatic conflict resolution bug fixed
 - in f4ba19f2b8a76a1676da7bb5850baa40d9c388e2. -}
test_conflict_resolution_movein_regression :: Assertion
test_conflict_resolution_movein_regression = withtmpclonerepo $ \r1 -> 
	withtmpclonerepo $ \r2 -> do
		let rname r = if r == r1 then "r1" else "r2"
		forM_ [r1, r2] $ \r -> indir r $ do
			{- Get all files, see check below. -}
			git_annex "get" [] @? "get failed"
			disconnectOrigin
		pair r1 r2
		forM_ [r1, r2] $ \r -> indir r $ do
			{- Set up a conflict. -}
			let newcontent = content annexedfile ++ rname r
			ifM (annexeval Config.isDirect)
				( writecontent annexedfile newcontent
				, do
					git_annex "unlock" [annexedfile] @? "unlock failed"		
					writecontent annexedfile newcontent
				)
		{- Sync twice in r1 so it gets the conflict resolution
		 - update from r2 -}
		forM_ [r1, r2, r1] $ \r -> indir r $
			git_annex "sync" ["--force"] @? "sync failed in " ++ rname r
		{- After the sync, it should be possible to get all
		 - files. This includes both sides of the conflict,
		 - although the filenames are not easily predictable.
		 -
		 - The bug caused, in direct mode, one repo to
		 - be missing the content of the file that had
		 - been put in it. -}
		forM_ [r1, r2] $ \r -> indir r $ do
			git_annex "get" [] @? "unable to get all files after merge conflict resolution in " ++ rname r

{- Simple case of conflict resolution; 2 different versions of annexed
 - file. -}
test_conflict_resolution :: Assertion
test_conflict_resolution = 
	withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 -> do
			indir r1 $ do
				disconnectOrigin
				writecontent conflictor "conflictor1"
				add_annex conflictor @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $ do
				disconnectOrigin
				writecontent conflictor "conflictor2"
				add_annex conflictor @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r2"
			pair r1 r2
			forM_ [r1,r2,r1] $ \r -> indir r $
				git_annex "sync" [] @? "sync failed"
			checkmerge "r1" r1
			checkmerge "r2" r2
  where
	conflictor = "conflictor"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		length v == 2
			@? (what ++ " not exactly 2 variant files in: " ++ show l)
		conflictor `notElem` l @? ("conflictor still present after conflict resolution")
		indir d $ do
			git_annex "get" v @? "get failed"
			git_annex_expectoutput "find" v v

{- Conflict resolution while in an adjusted branch. -}
test_conflict_resolution_adjusted_branch :: Assertion
test_conflict_resolution_adjusted_branch =
	withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 -> whenM (adjustedbranchsupported r2) $ do
			indir r1 $ do
				disconnectOrigin
				writecontent conflictor "conflictor1"
				add_annex conflictor @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $ do
				disconnectOrigin
				writecontent conflictor "conflictor2"
				add_annex conflictor @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r2"
				-- need v7 to use adjust
				git_annex "upgrade" [] @? "upgrade failed"
				-- We might be in an adjusted branch
				-- already, when eg on a crippled
				-- filesystem. So, --force it.
				git_annex "adjust" ["--unlock", "--force"] @? "adjust failed"
			pair r1 r2
			forM_ [r1,r2,r1] $ \r -> indir r $
				git_annex "sync" [] @? "sync failed"
			checkmerge "r1" r1
			checkmerge "r2" r2
  where
	conflictor = "conflictor"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		length v == 2
			@? (what ++ " not exactly 2 variant files in: " ++ show l)
		conflictor `notElem` l @? ("conflictor still present after conflict resolution")
		indir d $ do
			git_annex "get" v @? "get failed"
			git_annex_expectoutput "find" v v

{- Check merge conflict resolution when one side is an annexed
 - file, and the other is a directory. -}
test_mixed_conflict_resolution :: Assertion
test_mixed_conflict_resolution = do
	check True
	check False
  where
	check inr1 = withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 -> do
			indir r1 $ do
				disconnectOrigin
				writecontent conflictor "conflictor"
				add_annex conflictor @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $ do
				disconnectOrigin
				createDirectory conflictor
				writecontent subfile "subfile"
				add_annex conflictor @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r2"
			pair r1 r2
			let l = if inr1 then [r1, r2] else [r2, r1]
			forM_ l $ \r -> indir r $
				git_annex "sync" [] @? "sync failed in mixed conflict"
			checkmerge "r1" r1
			checkmerge "r2" r2
	conflictor = "conflictor"
	subfile = conflictor </> "subfile"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		doesDirectoryExist (d </> conflictor) @? (d ++ " conflictor directory missing")
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		not (null v)
			@? (what ++ " conflictor variant file missing in: " ++ show l )
		length v == 1
			@? (what ++ " too many variant files in: " ++ show v)
		indir d $ do
			git_annex "get" (conflictor:v) @? ("get failed in " ++ what)
			git_annex_expectoutput "find" [conflictor] [Git.FilePath.toInternalGitPath subfile]
			git_annex_expectoutput "find" v v

{- Check merge conflict resolution when both repos start with an annexed
 - file; one modifies it, and the other deletes it. -}
test_remove_conflict_resolution :: Assertion
test_remove_conflict_resolution = do
	check True
	check False
  where
	check inr1 = withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 -> do
			indir r1 $ do
				disconnectOrigin
				writecontent conflictor "conflictor"
				add_annex conflictor @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $
				disconnectOrigin
			pair r1 r2
			indir r2 $ do
				git_annex "sync" [] @? "sync failed in r2"
				git_annex "get" [conflictor]
					@? "get conflictor failed"
				unlessM (annexeval Config.isDirect) $ do
					git_annex "unlock" [conflictor]
						@? "unlock conflictor failed"
				writecontent conflictor "newconflictor"
			indir r1 $
				nukeFile conflictor
			let l = if inr1 then [r1, r2, r1] else [r2, r1, r2]
			forM_ l $ \r -> indir r $
				git_annex "sync" [] @? "sync failed"
			checkmerge "r1" r1
			checkmerge "r2" r2
	conflictor = "conflictor"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		not (null v)
			@? (what ++ " conflictor variant file missing in: " ++ show l )
		length v == 1
			@? (what ++ " too many variant files in: " ++ show v)

{- Check merge confalict resolution when a file is annexed in one repo,
 - and checked directly into git in the other repo.
 -
 - This test requires indirect mode to set it up, but tests both direct and
 - indirect mode.
 -}
test_nonannexed_file_conflict_resolution :: Assertion
test_nonannexed_file_conflict_resolution = do
	check True False
	check False False
	check True True
	check False True
  where
	check inr1 switchdirect = withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 ->
			whenM (isInDirect r1 <&&> isInDirect r2) $ do
				indir r1 $ do
					disconnectOrigin
					writecontent conflictor "conflictor"
					add_annex conflictor @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r1"
				indir r2 $ do
					disconnectOrigin
					writecontent conflictor nonannexed_content
					boolSystem "git"
						[ Param "config"
						, Param "annex.largefiles"
						, Param ("exclude=" ++ ingitfile ++ " and exclude=" ++ conflictor)
						] @? "git config annex.largefiles failed"
					boolSystem "git" [Param "add", File conflictor] @? "git add conflictor failed"
					git_annex "sync" [] @? "sync failed in r2"
				pair r1 r2
				let l = if inr1 then [r1, r2] else [r2, r1]
				forM_ l $ \r -> indir r $ do
					when switchdirect $
						whenM (annexeval Annex.Version.versionSupportsDirectMode) $
							git_annex "direct" [] @? "failed switching to direct mode"
					git_annex "sync" [] @? "sync failed"
				checkmerge ("r1" ++ show switchdirect) r1
				checkmerge ("r2" ++ show switchdirect) r2
	conflictor = "conflictor"
	nonannexed_content = "nonannexed"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		not (null v)
			@? (what ++ " conflictor variant file missing in: " ++ show l )
		length v == 1
			@? (what ++ " too many variant files in: " ++ show v)
		conflictor `elem` l @? (what ++ " conflictor file missing in: " ++ show l)
		s <- catchMaybeIO (readFile (d </> conflictor))
		s == Just nonannexed_content
			@? (what ++ " wrong content for nonannexed file: " ++ show s)


{- Check merge confalict resolution when a file is annexed in one repo,
 - and is a non-git-annex symlink in the other repo.
 -
 - Test can only run when coreSymlinks is supported, because git needs to
 - be able to check out the non-git-annex symlink.
 -}
test_nonannexed_symlink_conflict_resolution :: Assertion
test_nonannexed_symlink_conflict_resolution = do
	check True False
	check False False
	check True True
	check False True
  where
	check inr1 switchdirect = withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 ->
			whenM (checkRepo (Types.coreSymlinks <$> Annex.getGitConfig) r1
			       <&&> isInDirect r1 <&&> isInDirect r2) $ do
				indir r1 $ do
					disconnectOrigin
					writecontent conflictor "conflictor"
					add_annex conflictor @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r1"
				indir r2 $ do
					disconnectOrigin
					createSymbolicLink symlinktarget "conflictor"
					boolSystem "git" [Param "add", File conflictor] @? "git add conflictor failed"
					git_annex "sync" [] @? "sync failed in r2"
				pair r1 r2
				let l = if inr1 then [r1, r2] else [r2, r1]
				forM_ l $ \r -> indir r $ do
					when switchdirect $
						whenM (annexeval Annex.Version.versionSupportsDirectMode) $ do
							git_annex "direct" [] @? "failed switching to direct mode"
					git_annex "sync" [] @? "sync failed"
				checkmerge ("r1" ++ show switchdirect) r1
				checkmerge ("r2" ++ show switchdirect) r2
	conflictor = "conflictor"
	symlinktarget = "dummy-target"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = do
		l <- getDirectoryContents d
		let v = filter (variantprefix `isPrefixOf`) l
		not (null v)
			@? (what ++ " conflictor variant file missing in: " ++ show l )
		length v == 1
			@? (what ++ " too many variant files in: " ++ show v)
		conflictor `elem` l @? (what ++ " conflictor file missing in: " ++ show l)
		s <- catchMaybeIO (readSymbolicLink (d </> conflictor))
		s == Just symlinktarget
			@? (what ++ " wrong target for nonannexed symlink: " ++ show s)

{- Check merge conflict resolution when there is a local file,
 - that is not staged or committed, that conflicts with what's being added
 - from the remmote.
 -
 - Case 1: Remote adds file named conflictor; local has a file named
 - conflictor.
 -
 - Case 2: Remote adds conflictor/file; local has a file named conflictor.
 -}
test_uncommitted_conflict_resolution :: Assertion
test_uncommitted_conflict_resolution = do
	check conflictor
	check (conflictor </> "file")
  where
	check remoteconflictor = withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 -> do
			indir r1 $ do
				disconnectOrigin
				createDirectoryIfMissing True (parentDir remoteconflictor)
				writecontent remoteconflictor annexedcontent
				add_annex conflictor @? "add remoteconflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $ do
				disconnectOrigin
				writecontent conflictor localcontent
			pair r1 r2
			indir r2 $ ifM (annexeval Config.isDirect)
				( do
					git_annex "sync" [] @? "sync failed"
					let local = conflictor ++ localprefix
					doesFileExist local @? (local ++ " missing after merge")
					s <- readFile local
					s == localcontent @? (local ++ " has wrong content: " ++ s)
					git_annex "get" [conflictor] @? "get failed"
					doesFileExist remoteconflictor @? (remoteconflictor ++ " missing after merge")
					s' <- readFile remoteconflictor
					s' == annexedcontent @? (remoteconflictor ++ " has wrong content: " ++ s)
				-- this case is intentionally not handled
				-- in indirect mode, since the user
				-- can recover on their own easily
				, git_annex_shouldfail "sync" [] @? "sync failed to fail"
				)
	conflictor = "conflictor"
	localprefix = ".variant-local"
	localcontent = "local"
	annexedcontent = "annexed"

{- On Windows/FAT, repeated conflict resolution sometimes 
 - lost track of whether a file was a symlink. 
 -}
test_conflict_resolution_symlink_bit :: Assertion
test_conflict_resolution_symlink_bit = unlessM (unlockedFiles <$> getTestMode) $
	withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 ->
			withtmpclonerepo $ \r3 -> do
				indir r1 $ do
					writecontent conflictor "conflictor"
					git_annex "add" [conflictor] @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r1"
					check_is_link conflictor "r1"
				indir r2 $ do
					createDirectory conflictor
					writecontent (conflictor </> "subfile") "subfile"
					git_annex "add" [conflictor] @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r2"
					check_is_link (conflictor </> "subfile") "r2"
				indir r3 $ do
					writecontent conflictor "conflictor"
					git_annex "add" [conflictor] @? "add conflicter failed"
					git_annex "sync" [] @? "sync failed in r1"
					check_is_link (conflictor </> "subfile") "r3"
  where
	conflictor = "conflictor"
	check_is_link f what = do
		git_annex_expectoutput "find" ["--include=*", f] [Git.FilePath.toInternalGitPath f]
		l <- annexeval $ Annex.inRepo $ Git.LsTree.lsTreeFiles Git.Ref.headRef [f]
		all (\i -> Git.Types.toTreeItemType (Git.LsTree.mode i) == Just Git.Types.TreeSymlink) l
			@? (what ++ " " ++ f ++ " lost symlink bit after merge: " ++ show l)

{- A v7 unlocked file that conflicts with a locked file should be resolved
 - in favor of the unlocked file, with no variant files, as long as they
 - both point to the same key. -}
test_mixed_lock_conflict_resolution :: Assertion
test_mixed_lock_conflict_resolution = 
	withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 -> do
			indir r1 $ whenM shouldtest $ do
				disconnectOrigin
				writecontent conflictor "conflictor"
				git_annex "add" [conflictor] @? "add conflicter failed"
				git_annex "sync" [] @? "sync failed in r1"
			indir r2 $ whenM shouldtest $ do
				disconnectOrigin
				writecontent conflictor "conflictor"
				git_annex "add" [conflictor] @? "add conflicter failed"
				git_annex "unlock" [conflictor] @? "unlock conflicter failed"
				git_annex "sync" [] @? "sync failed in r2"
			pair r1 r2
			forM_ [r1,r2,r1] $ \r -> indir r $
				git_annex "sync" [] @? "sync failed"
			checkmerge "r1" r1
			checkmerge "r2" r2
  where
	shouldtest = annexeval Annex.Version.versionSupportsUnlockedPointers
	conflictor = "conflictor"
	variantprefix = conflictor ++ ".variant"
	checkmerge what d = indir d $ whenM shouldtest $ do
		l <- getDirectoryContents "."
		let v = filter (variantprefix `isPrefixOf`) l
		length v == 0
			@? (what ++ " not exactly 0 variant files in: " ++ show l)
		conflictor `elem` l @? ("conflictor not present after conflict resolution")
		git_annex "get" [conflictor] @? "get failed"
		git_annex_expectoutput "find" [conflictor] [conflictor]
		-- regular file because it's unlocked
		checkregularfile conflictor

{- Regression test for a bad merge between two adjusted branch repos,
 - where the same file is added to both independently. The bad merge
 - emptied the whole tree. -}
test_adjusted_branch_merge_regression :: Assertion
test_adjusted_branch_merge_regression = do
	withtmpclonerepo $ \r1 ->
		withtmpclonerepo $ \r2 -> whenM (adjustedbranchsupported r1) $ do
			pair r1 r2
			setup r1
			setup r2
			checkmerge "r1" r1
			checkmerge "r2" r2
  where
	conflictor = "conflictor"
	setup r = indir r $ do
		disconnectOrigin
		git_annex "upgrade" [] @? "upgrade failed"
		git_annex "adjust" ["--unlock", "--force"] @? "adjust failed"
		writecontent conflictor "conflictor"
		git_annex "add" [conflictor] @? "add conflicter failed"
		git_annex "sync" [] @? "sync failed"
	checkmerge what d = indir d $ do
		git_annex "sync" [] @? ("sync failed in " ++ what)
		l <- getDirectoryContents "."
		conflictor `elem` l
			@? ("conflictor not present after merge in " ++ what)

{- Regression test for a bug in adjusted branch syncing code, where adding
 - a subtree to an existing tree lost files. -}
test_adjusted_branch_subtree_regression :: Assertion
test_adjusted_branch_subtree_regression = 
	withtmpclonerepo $ \r -> whenM (adjustedbranchsupported r) $ do
		indir r $ do
			disconnectOrigin
			git_annex "upgrade" [] @? "upgrade failed"
			git_annex "adjust" ["--unlock", "--force"] @? "adjust failed"
			createDirectoryIfMissing True "a/b/c"
			writecontent "a/b/c/d" "foo"
			git_annex "add" ["a/b/c"] @? "add a/b/c failed"
			git_annex "sync" [] @? "sync failed"
			createDirectoryIfMissing True "a/b/x"
			writecontent "a/b/x/y" "foo"
			git_annex "add" ["a/b/x"] @? "add a/b/x failed"
			git_annex "sync" [] @? "sync failed"
			boolSystem "git" [Param "checkout", Param "master"] @? "git checkout master failed"
			doesFileExist "a/b/x/y" @? ("a/b/x/y missing from master after adjusted branch sync")

{- Set up repos as remotes of each other. -}
pair :: FilePath -> FilePath -> Assertion
pair r1 r2 = forM_ [r1, r2] $ \r -> indir r $ do
	when (r /= r1) $
		boolSystem "git" [Param "remote", Param "add", Param "r1", File ("../../" ++ r1)] @? "remote add"
	when (r /= r2) $
		boolSystem "git" [Param "remote", Param "add", Param "r2", File ("../../" ++ r2)] @? "remote add"

test_map :: Assertion
test_map = intmpclonerepo $ do
	-- set descriptions, that will be looked for in the map
	git_annex "describe" [".", "this repo"] @? "describe 1 failed"
	git_annex "describe" ["origin", "origin repo"] @? "describe 2 failed"
	-- --fast avoids it running graphviz, not a build dependency
	git_annex "map" ["--fast"] @? "map failed"

test_uninit :: Assertion
test_uninit = intmpclonerepo $ do
	git_annex "get" [] @? "get failed"
	annexed_present annexedfile
	_ <- git_annex "uninit" [] -- exit status not checked; does abnormal exit
	checkregularfile annexedfile
	doesDirectoryExist ".git" @? ".git vanished in uninit"

test_uninit_inbranch :: Assertion
test_uninit_inbranch = intmpclonerepoInDirect $ do
	boolSystem "git" [Param "checkout", Param "git-annex"] @? "git checkout git-annex"
	git_annex_shouldfail "uninit" [] @? "uninit failed to fail when git-annex branch was checked out"

test_upgrade :: Assertion
test_upgrade = intmpclonerepo $
	git_annex "upgrade" [] @? "upgrade failed"

test_whereis :: Assertion
test_whereis = intmpclonerepo $ do
	annexed_notpresent annexedfile
	git_annex "whereis" [annexedfile] @? "whereis on non-present file failed"
	git_annex "untrust" ["origin"] @? "untrust failed"
	git_annex_shouldfail "whereis" [annexedfile] @? "whereis on non-present file only present in untrusted repo failed to fail"
	git_annex "get" [annexedfile] @? "get failed"
	annexed_present annexedfile
	git_annex "whereis" [annexedfile] @? "whereis on present file failed"

test_hook_remote :: Assertion
test_hook_remote = intmpclonerepo $ do
#ifndef mingw32_HOST_OS
	git_annex "initremote" (words "foo type=hook encryption=none hooktype=foo") @? "initremote failed"
	createDirectory dir
	git_config "annex.foo-store-hook" $
		"cp $ANNEX_FILE " ++ loc
	git_config "annex.foo-retrieve-hook" $
		"cp " ++ loc ++ " $ANNEX_FILE"
	git_config "annex.foo-remove-hook" $
		"rm -f " ++ loc
	git_config "annex.foo-checkpresent-hook" $
		"if [ -e " ++ loc ++ " ]; then echo $ANNEX_KEY; fi"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to hook remote failed"
	annexed_present annexedfile
	git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
	annexed_notpresent annexedfile
	git_annex "move" [annexedfile, "--from", "foo"] @? "move --from hook remote failed"
	annexed_present annexedfile
	git_annex_shouldfail "drop" [annexedfile, "--numcopies=2"] @? "drop failed to fail"
	annexed_present annexedfile
  where
	dir = "dir"
	loc = dir ++ "/$ANNEX_KEY"
	git_config k v = boolSystem "git" [Param "config", Param k, Param v]
		@? "git config failed"
#else
	-- this test doesn't work in Windows TODO
	noop
#endif

test_directory_remote :: Assertion
test_directory_remote = intmpclonerepo $ do
	createDirectory "dir"
	git_annex "initremote" (words "foo type=directory encryption=none directory=dir") @? "initremote failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to directory remote failed"
	annexed_present annexedfile
	git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
	annexed_notpresent annexedfile
	git_annex "move" [annexedfile, "--from", "foo"] @? "move --from directory remote failed"
	annexed_present annexedfile
	git_annex_shouldfail "drop" [annexedfile, "--numcopies=2"] @? "drop failed to fail"
	annexed_present annexedfile

test_rsync_remote :: Assertion
test_rsync_remote = intmpclonerepo $ do
	createDirectory "dir"
	git_annex "initremote" (words "foo type=rsync encryption=none rsyncurl=dir") @? "initremote failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to rsync remote failed"
	annexed_present annexedfile
	git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
	annexed_notpresent annexedfile
	git_annex "move" [annexedfile, "--from", "foo"] @? "move --from rsync remote failed"
	annexed_present annexedfile
	git_annex_shouldfail "drop" [annexedfile, "--numcopies=2"] @? "drop failed to fail"
	annexed_present annexedfile

test_bup_remote :: Assertion
test_bup_remote = intmpclonerepo $ when BuildInfo.bup $ do
	dir <- absPath "dir" -- bup special remote needs an absolute path
	createDirectory dir
	git_annex "initremote" (words $ "foo type=bup encryption=none buprepo="++dir) @? "initremote failed"
	git_annex "get" [annexedfile] @? "get of file failed"
	annexed_present annexedfile
	git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to bup remote failed"
	annexed_present annexedfile
	git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
	annexed_notpresent annexedfile
	git_annex "copy" [annexedfile, "--from", "foo"] @? "copy --from bup remote failed"
	annexed_present annexedfile
	git_annex "move" [annexedfile, "--from", "foo"] @? "move --from bup remote failed"
	annexed_present annexedfile

-- gpg is not a build dependency, so only test when it's available
test_crypto :: Assertion
#ifndef mingw32_HOST_OS
test_crypto = do
	testscheme "shared"
	testscheme "hybrid"
	testscheme "pubkey"
  where
	gpgcmd = Utility.Gpg.mkGpgCmd Nothing
	testscheme scheme = intmpclonerepo $ whenM (Utility.Path.inPath (Utility.Gpg.unGpgCmd gpgcmd)) $ do
		Utility.Gpg.testTestHarness gpgcmd 
			@? "test harness self-test failed"
		Utility.Gpg.testHarness gpgcmd $ do
			createDirectory "dir"
			let a cmd = git_annex cmd $
				[ "foo"
				, "type=directory"
				, "encryption=" ++ scheme
				, "directory=dir"
				, "highRandomQuality=false"
				] ++ if scheme `elem` ["hybrid","pubkey"]
					then ["keyid=" ++ Utility.Gpg.testKeyId]
					else []
			a "initremote" @? "initremote failed"
			not <$> a "initremote" @? "initremote failed to fail when run twice in a row"
			a "enableremote" @? "enableremote failed"
			a "enableremote" @? "enableremote failed when run twice in a row"
			git_annex "get" [annexedfile] @? "get of file failed"
			annexed_present annexedfile
			git_annex "copy" [annexedfile, "--to", "foo"] @? "copy --to encrypted remote failed"
			(c,k) <- annexeval $ do
				uuid <- Remote.nameToUUID "foo"
				rs <- Logs.Remote.readRemoteLog
				Just k <- Annex.WorkTree.lookupFile annexedfile
				return (fromJust $ M.lookup uuid rs, k)
			let key = if scheme `elem` ["hybrid","pubkey"]
					then Just $ Utility.Gpg.KeyIds [Utility.Gpg.testKeyId]
					else Nothing
			testEncryptedRemote scheme key c [k] @? "invalid crypto setup"
	
			annexed_present annexedfile
			git_annex "drop" [annexedfile, "--numcopies=2"] @? "drop failed"
			annexed_notpresent annexedfile
			git_annex "move" [annexedfile, "--from", "foo"] @? "move --from encrypted remote failed"
			annexed_present annexedfile
			git_annex_shouldfail "drop" [annexedfile, "--numcopies=2"] @? "drop failed to fail"
			annexed_present annexedfile
	{- Ensure the configuration complies with the encryption scheme, and
	 - that all keys are encrypted properly for the given directory remote. -}
	testEncryptedRemote scheme ks c keys = case Remote.Helper.Encryptable.extractCipher c of
		Just cip@Crypto.SharedCipher{} | scheme == "shared" && isNothing ks ->
			checkKeys cip Nothing
		Just cip@(Crypto.EncryptedCipher encipher v ks')
			| checkScheme v && keysMatch ks' ->
				checkKeys cip (Just v) <&&> checkCipher encipher ks'
		_ -> return False
	  where
		keysMatch (Utility.Gpg.KeyIds ks') =
			maybe False (\(Utility.Gpg.KeyIds ks2) ->
					sort (nub ks2) == sort (nub ks')) ks
		checkCipher encipher = Utility.Gpg.checkEncryptionStream gpgcmd encipher . Just
		checkScheme Types.Crypto.Hybrid = scheme == "hybrid"
		checkScheme Types.Crypto.PubKey = scheme == "pubkey"
		checkKeys cip mvariant = do
			dummycfg <- Types.GitConfig.dummyRemoteGitConfig
			let encparams = (mempty :: Types.Remote.RemoteConfig, dummycfg)
			cipher <- Crypto.decryptCipher gpgcmd encparams cip
			files <- filterM doesFileExist $
				map ("dir" </>) $ concatMap (key2files cipher) keys
			return (not $ null files) <&&> allM (checkFile mvariant) files
		checkFile mvariant filename =
			Utility.Gpg.checkEncryptionFile gpgcmd filename $
				if mvariant == Just Types.Crypto.PubKey then ks else Nothing
		key2files cipher = Annex.Locations.keyPaths .
			Crypto.encryptKey Types.Crypto.HmacSha1 cipher
#else
test_crypto = putStrLn "gpg testing not implemented on Windows"
#endif

test_add_subdirs :: Assertion
test_add_subdirs = intmpclonerepo $ do
	createDirectory "dir"
	writecontent ("dir" </> "foo") $ "dir/" ++ content annexedfile
	git_annex "add" ["dir"] @? "add of subdir failed"

	{- Regression test for Windows bug where symlinks were not
	 - calculated correctly for files in subdirs. -}
	unlessM (unlockedFiles <$> getTestMode) $ do
		git_annex "sync" [] @? "sync failed"
		l <- annexeval $ Utility.FileSystemEncoding.decodeBS
			<$> Annex.CatFile.catObject (Git.Types.Ref "HEAD:dir/foo")
		"../.git/annex/" `isPrefixOf` l @? ("symlink from subdir to .git/annex is wrong: " ++ l)

	createDirectory "dir2"
	writecontent ("dir2" </> "foo") $ content annexedfile
	setCurrentDirectory "dir"
	git_annex "add" [".." </> "dir2"] @? "add of ../subdir failed"

test_addurl :: Assertion
test_addurl = intmpclonerepo $ do
	-- file:// only; this test suite should not hit the network
	let filecmd c ps = git_annex c ("-cannex.security.allowed-url-schemes=file" : ps)
	f <- absPath "myurl"
	let url = replace "\\" "/" ("file:///" ++ dropDrive f)
	writecontent f "foo"
	git_annex_shouldfail "addurl" [url] @? "addurl failed to fail on file url"
	filecmd "addurl" [url] @? ("addurl failed on " ++ url)
	let dest = "addurlurldest"
	filecmd "addurl" ["--file", dest, url] @? ("addurl failed on " ++ url ++ "  with --file")
	doesFileExist dest @? (dest ++ " missing after addurl --file")
