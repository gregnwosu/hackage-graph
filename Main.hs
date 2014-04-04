import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as EvilHack
import qualified Codec.Archive.Tar as Tar
import Data.List.Split
import Data.Ord
import Data.Maybe
import Text.Printf
import Text.Read
import Data.List
import Data.Traversable
import Control.Applicative
import Control.Monad
import System.IO
import System.FilePath (splitDirectories)

import qualified Distribution.Package                          as Cabal
import qualified Distribution.PackageDescription               as Cabal
import qualified Distribution.PackageDescription.Configuration as Cabal
import qualified Distribution.PackageDescription.Parse         as Cabal
import qualified Distribution.Simple.Compiler                  as Cabal
import qualified Distribution.System                           as Cabal
import qualified Distribution.Version                          as Cabal

packageDB :: FilePath
packageDB = "/home/main/.cabal/packages/hackage.haskell.org/00-index.tar"

data Package = Package { name     :: String -- ^ Package name
                       , version  :: Version -- ^ Package version
                       , dotCabal :: BSL.ByteString -- ^ Content of .cabal
                       , path     :: FilePath -- ^ Path to .cabal
                       }

instance Show Package where
      show (Package n v _c p) = printf "Package %s v%s at %s" n (show v) p

-- | a.b.c.d
data Version = Version [Int]
      deriving (Eq, Ord)

instance Show Version where
      show (Version vs) = (intercalate "." (map show vs))

main :: IO ()
main = do
      tarDB <- BSL.readFile packageDB

      let allPackages :: [Package]
          allPackages = getPackages (Tar.read tarDB)

          latestPackages :: [Package]
          latestPackages = map latest (groupPackages allPackages)

          packAndDeps :: [(String, [String])]
          packAndDeps = mapMaybe packageToNode latestPackages

      _ <- hPrintf stderr "Graph size: %d nodes\n" (length packAndDeps)

      putStrLn (toDot packAndDeps)


-- Extract .tar file contents, and put them into a flat list
getPackages :: (Show e)
            => Tar.Entries e -- ^ Raw tar content
            -> [Package]
getPackages (Tar.Next entry xs) = case Tar.entryContent entry of
      Tar.NormalFile content _size -> case toPackage entry content of
            Just package -> package : getPackages xs
            _otherwise   -> getPackages xs
      _otherwise -> getPackages xs
getPackages Tar.Done = []
getPackages (Tar.Fail e) = error ("tar failed: " ++ show e)

-- | Converts an entry in a tar file to a 'Package'. 'Nothing' if the file is
--   not a .cabal.
toPackage :: Tar.Entry -- ^ Tar file 'Tar.Entry'
          -> BSL.ByteString -- ^ File contents
          -> Maybe Package
toPackage entry content = Package <$> n <*> v <*> c <*> p where
      p' = Tar.entryPath entry
      p = p' <$ guard (".cabal" `isSuffixOf` p')
      c = pure content
      (n, v) = case splitDirectories p' of
            (name':versionStr:_) -> (Just name', toVersion versionStr)
            _ -> (Nothing, Nothing)


-- | Parse a version string a la "1.2.3".
toVersion :: String -> Maybe Version
toVersion = fmap Version . traverse readMaybe . splitOn "."

-- | Group packages by name. Assumes the unput is already sorted.
groupPackages :: [Package] -> [[Package]]
groupPackages = groupBy (\x y -> name x == name y)

-- | Find the package with the latest version
latest :: [Package] -> Package
latest = maximumBy (comparing version)

-- | Searches the package DB for all dependencies of a package.
getDependencies :: Package -> Maybe [String]
getDependencies = genPackDescr >=> maybePackDescr >=> extractNames

      where

      genPackDescr :: Package -> Maybe Cabal.GenericPackageDescription
      genPackDescr (Package { dotCabal = c }) =
            case Cabal.parsePackageDescription (EvilHack.unpack c) of
                  Cabal.ParseFailed _e  -> Nothing
                  Cabal.ParseOk _w deps -> Just deps

      finPackDescr :: Cabal.GenericPackageDescription
                   -> Either [Cabal.Dependency]
                             (Cabal.PackageDescription, Cabal.FlagAssignment)
      finPackDescr = Cabal.finalizePackageDescription
                           [] -- "flag assignments", whatever that may be
                           (const True)
                           Cabal.buildPlatform
                           (Cabal.CompilerId Cabal.buildCompilerFlavor
                                             (Cabal.Version [] []))
                           [] -- Additional constraints

      maybePackDescr :: Cabal.GenericPackageDescription
                     -> Maybe [Cabal.Dependency]
      maybePackDescr g = case finPackDescr g of
            Right (descr, _) -> Just (Cabal.buildDepends descr)
            _ -> Nothing

      extractNames :: [Cabal.Dependency] -> Maybe [String]
      extractNames = Just . map getDepName

getDepName :: Cabal.Dependency -> String
getDepName (Cabal.Dependency depName _) = getPName  depName

getPName :: Cabal.PackageName -> String
getPName (Cabal.PackageName pName) = pName

-- | Convert a Package to a pair of its own name and a list of dependencies
packageToNode :: Package -> Maybe (String, [String])
packageToNode p = (,) <$> pName <*> pDeps
      where pName = pure (name p)
            pDeps = getDependencies p

-- | Packages to be ignored
ignore :: [String]
ignore = ["base"]

-- | Convert a graph to .dot format
toDot :: [(String, [String])] -> String
toDot = boilerplate . foldr toEdge "" where
      boilerplate = printf "digraph HackageGraph {\n%s}\n"
      toEdge (pName, pDeps) rest
            | pName `elem` ignore = rest
            | otherwise = edge ++ rest
            where edge = printf "\t%s -> { %s };\n" source targets
                  source = quote pName
                  targets = (intercalate "; "
                            . map quote
                            . filter (`notElem` ignore)) pDeps
                  quote = printf "\"%s\""