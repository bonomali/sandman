{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Applicative
import Control.Monad
import Data.List           (stripPrefix)
import Data.Maybe          (isJust, listToMaybe)
import Data.Monoid
import Data.Set            (Set)
import Data.Text           (Text)
import System.Directory    (copyFile, createDirectoryIfMissing,
                            doesDirectoryExist, getHomeDirectory, removeFile)
import System.Exit         (ExitCode (..))
import System.FilePath     (splitDirectories, takeFileName, (</>))

import qualified Data.Set                          as Set
import qualified Data.Text                         as T
import qualified Data.Text.IO                      as TIO
import qualified Distribution.InstalledPackageInfo as PInfo
import qualified Options.Applicative               as O
import qualified System.Process                    as Proc

import Sandman.InstalledPackage
import Sandman.PackageDb
import Sandman.Util

------------------------------------------------------------------------------
-- | Main context for the program.
--
-- Currently this just consists of the root directory where all sandman files
-- will be stored.
newtype Sandman = Sandman { sandmanDirectory :: FilePath }
    deriving (Show, Ord, Eq)


-- | Build the context with default settings.
defaultSandman :: IO Sandman
defaultSandman = do
    home <- getHomeDirectory
    return $! Sandman (home </> ".sandman")


-- | Path to the directory which will hold the sandboxes.
sandboxesDirectory :: Sandman -> FilePath
sandboxesDirectory Sandman{sandmanDirectory} =
    sandmanDirectory </> "sandboxes"


-- | Get all managed sandboxes.
getSandboxes :: Sandman -> IO [Sandbox]
getSandboxes sandman = do
    exists <- doesDirectoryExist sandboxesDir
    if exists
      then map Sandbox <$> listDirectory sandboxesDir
      else return []
  where
    sandboxesDir = sandboxesDirectory sandman


-- | Get the sandbox with the given name.
getSandbox :: Sandman -> Text -> IO (Maybe Sandbox)
getSandbox sandman name = do
    exists <- doesDirectoryExist sandboxDir
    if exists
        then return . Just . Sandbox $ sandboxDir
        else return Nothing
  where
    sandboxDir = sandboxesDirectory sandman </> T.unpack name


------------------------------------------------------------------------------
-- | Represents a cabal sandbox.
newtype Sandbox = Sandbox {
    sandboxRoot :: FilePath
  -- ^ Path to the sandbox root.
  --
  -- Note: This is /not/ the project root. It just happens to be that the
  -- project root and sandbox root is the same for managed sandboxes.
  } deriving (Show, Ord, Eq)


-- | Name of the sandbox.
sandboxName :: Sandbox -> Text
sandboxName = T.pack . takeFileName . sandboxRoot


-- | Create a new managed sandbox with the given name.
createSandbox :: Sandman -> Text -> IO Sandbox
createSandbox sandman name = do
    whenM (doesDirectoryExist sandboxDir) $
        die $ "Sandbox " <> name <> " already exists."

    createDirectoryIfMissing True sandboxDir

    let proc = (Proc.proc "cabal" ["sandbox", "init", "--sandbox=."]) {
            Proc.cwd = Just sandboxDir
          }

    (_, _, _, procHandle) <- Proc.createProcess proc
    exitResult <- Proc.waitForProcess procHandle
    case exitResult of
        ExitSuccess   -> return $! Sandbox sandboxDir
        ExitFailure _ -> die $ "Failed to create sandbox " <> name
  where
    sandboxDir = sandboxesDirectory sandman </> T.unpack name


-- | Install the specified packages into the sandbox.
installPackages :: Sandbox -> [Text] -> IO ()
installPackages sandbox@Sandbox{sandboxRoot} packages = do
    (_, _, _, procHandle) <- Proc.createProcess proc
    exitResult <- Proc.waitForProcess procHandle
    case exitResult of
        ExitSuccess -> return ()
        ExitFailure _ -> die $ "Failed to install packages to " <> name
  where
    name = sandboxName sandbox
    proc = (Proc.proc "cabal" $ ["install"] <> map T.unpack packages) {
        Proc.cwd = Just sandboxRoot
      }

------------------------------------------------------------------------------

-- | Get the PackageDb for the given package.
--
-- The package root is the directory containing the @cabal.sandbox.config@.
determinePackageDb :: FilePath -> IO (Either String PackageDb)
determinePackageDb packageRoot = do
    -- TODO check if sandboxConfig exists
    matches <- TIO.readFile sandboxConfig
        <&> filter ("package-db:" `T.isPrefixOf`) . T.lines
    case listToMaybe matches of
        Nothing -> return . Left $
            "Could not determine package DB for " ++ packageRoot
        Just line ->
            let right = T.drop 1 $ T.dropWhile (/= ':') line
                value = T.dropWhile (\c -> c == ' ' || c == '\t') right
                root  = T.unpack value
            in getPackageDb root
  where
    sandboxConfig = packageRoot </> "cabal.sandbox.config"

-- | Get the number of packages installed in the given package DB.
installedPackageCount :: PackageDb -> Int
installedPackageCount = length . packageDbInstalledPackages


------------------------------------------------------------------------------
list :: IO ()
list = do
    sandman <- defaultSandman -- FIXME
    sandboxes <- getSandboxes sandman
    when (null sandboxes) $
        putStrLn "No sandboxes created."
    forM_ sandboxes $ \sandbox -> do
        let name = sandboxName sandbox
        packageDb' <- determinePackageDb (sandboxRoot sandbox)
        case packageDb' of
          Left err -> do
              warn (T.pack err)
              TIO.putStrLn $ name <> "(ERROR: could not read package DB)"
          Right packageDb -> do
              let packageCount = installedPackageCount packageDb
              TIO.putStrLn $ T.unwords
                  [name, "(" <> tshow packageCount, "packages)"]


------------------------------------------------------------------------------
new :: Text -> IO ()
new name = do
    sandman <- defaultSandman -- FIXME
    _ <- createSandbox sandman name
    TIO.putStrLn $ "Created sandbox " <> name <> "."


------------------------------------------------------------------------------
destroy :: Text -> IO ()
destroy name = do
    sandman <- defaultSandman
    Sandbox{sandboxRoot} <- getSandbox sandman name
        >>= maybe (die $ "Sandbox " <> name <> " does not exist.") return
    removeTree sandboxRoot
    TIO.putStrLn $ "Removed sandbox " <> name <> "."


------------------------------------------------------------------------------
install :: Text -> [Text] -> IO ()
install name packages = do
    -- TODO parse package IDs
    sandman <- defaultSandman
    sandbox <- getSandbox sandman name
        >>= maybe (die $ "Sandbox " <> name <> " does not exist.") return
    installPackages sandbox packages


------------------------------------------------------------------------------
listPackages :: Text -> IO ()
listPackages name = do
    sandman <- defaultSandman
    -- TODO get rid of all this duplication
    sandbox <- getSandbox sandman name
        >>= maybe (die $ "Sandbox " <> name <> " does not exist.") return
    packageDb <- determinePackageDb (sandboxRoot sandbox)
             >>= either fail return
    let packageIds = packageDbInstalledPackages packageDb
                 <&> installedPackageId

    when (null packageIds) $
        dieHappy $ name <> " does not contain any packages."

    forM_ packageIds TIO.putStrLn


------------------------------------------------------------------------------
mix :: Text -> IO ()
mix name = do
    currentPackageDb <- determinePackageDb "." >>= either fail return

    sandman <- defaultSandman
    sandbox <- getSandbox sandman name
        >>= maybe (die $ "Sandbox " <> name <> " does not exist.") return
    sandboxPackageDb <- determinePackageDb (sandboxRoot sandbox)
                    >>= either fail return

    let packagesToInstall = filterPackages
            (packageDbInstalledPackages currentPackageDb)
            (packageDbInstalledPackages sandboxPackageDb)
        newPackageCount = length packagesToInstall

    when (newPackageCount == 0) $
        dieHappy "No packages to mix in."

    putStrLn $ unwords [
        "Mixing", show newPackageCount
      , "new packages into package DB at"
      , packageDbRoot currentPackageDb
      ]

    let currentPackageDbRoot = packageDbRoot currentPackageDb
    forM_ packagesToInstall $ \installedPackage ->
      let currentPath = installedPackageInfoPath installedPackage
          newPath = currentPackageDbRoot </> takeFileName currentPath
      in copyFile currentPath newPath

    putStrLn "Rebuilding package cache."
    Proc.callProcess "cabal" ["sandbox", "hc-pkg", "recache"]
  where
    filterPackages installed = loop []
      where
        installedIndex :: Set Text
        installedIndex = Set.fromList $ map installedPackageId installed

        loop toInstall [] = toInstall
        loop toInstall (c:candidates)
            | installedPackageId c `Set.member` installedIndex
                = loop toInstall candidates
            | otherwise = loop (c:toInstall) candidates


------------------------------------------------------------------------------
clean :: IO ()
clean = do
    currentPackageDb <- determinePackageDb "." >>= either fail return
    sandman <- defaultSandman
    putStrLn "Removing all mixed sandboxes."

    let packages = filterPackages sandman $
            packageDbInstalledPackages currentPackageDb

    when (null packages) $
        dieHappy "No packages to remove."

    forM_ packages $ removeFile . installedPackageInfoPath
    putStrLn $ "Removed " <> show (length packages) <> " packages."

    putStrLn "Rebuilding package cache."
    Proc.callProcess "cabal" ["sandbox", "hc-pkg", "recache"]
  where
    -- FIXME this will probably cause all kinds of trouble if one managed
    -- sandbox is mixed into another. That should be disallowed or this should
    -- be smarter.
    filterPackages :: Sandman -> [InstalledPackage] -> [InstalledPackage]
    filterPackages Sandman{sandmanDirectory} = filter isMixedIn
      where
        isSandmanPath p = isJust $
            stripPrefix (splitDirectories sandmanDirectory)
                        (splitDirectories p)

        isMixedIn installedPackage = any isSandmanPath $
            concatMap ($ packageInfo) [
                PInfo.importDirs
              , PInfo.libraryDirs
              , PInfo.haddockInterfaces
              ]
          where
            packageInfo = installedPackageInfo installedPackage


------------------------------------------------------------------------------
argParser :: O.Parser (IO ())
argParser = O.subparser $ mconcat [
      -- TODO come up with a better name for managed sandboxes than "sandman
      -- sandboxes"
      command "list" "List sandman sandboxes or the packages in them" $
        maybe list listPackages <$> listNameArgument
    , command "new" "Create a new sandman sandbox" $
        new <$> nameArgument
    , command "destroy" "Delete a sandman sandbox" $
        destroy <$> nameArgument
    , command "install" "Install a new package" $
        install <$> nameArgument <*> packagesArgument
    , command "mix" "Mix a sandman sandbox into the current project" $
        mix <$> nameArgument
    , command "clean" "Remove all mixed sandboxes from the current project" $
        pure clean
    ]
  where
    listNameArgument = O.optional . textArgument $ O.metavar "name" <>
        O.help (unwords [
            "If given, list packages installed in the specified sandbox,"
          , "otherwise list all sandman sandboxes"
          ])
    packagesArgument = O.some . textArgument $
        O.metavar "PACKAGES" <> O.help "Packages to install"
    nameArgument = textArgument $
        O.metavar "NAME" <> O.help "Name of the sandman sandbox"
    textArgument = fmap T.pack . O.strArgument
    command name desc p =
        O.command name (O.info (O.helper <*> p) (O.progDesc desc))


main :: IO ()
main = join $ O.execParser opts
  where
    opts = O.info (O.helper <*> argParser) O.fullDesc
