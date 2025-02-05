{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}

module PostgREST.MediaType
  ( MediaType(..)
  , MTVndPlanOption (..)
  , MTVndPlanFormat (..)
  , toContentType
  , toMime
  , decodeMediaType
  ) where

import qualified Data.ByteString          as BS
import qualified Data.ByteString.Internal as BS (c2w)

import Network.HTTP.Types.Header (Header, hContentType)

import Protolude

-- | Enumeration of currently supported media types
data MediaType
  = MTApplicationJSON
  | MTGeoJSON
  | MTTextCSV
  | MTTextPlain
  | MTTextXML
  | MTOpenAPI
  | MTUrlEncoded
  | MTOctetStream
  | MTAny
  | MTOther ByteString
  -- vendored media types
  | MTVndArrayJSONStrip
  | MTVndSingularJSON Bool
  -- TODO MTVndPlan should only have its options as [Text]. Its ResultAggregate should have the typed attributes.
  | MTVndPlan MediaType MTVndPlanFormat [MTVndPlanOption]
  deriving (Eq, Show, Generic)
instance Hashable MediaType

data MTVndPlanOption
  = PlanAnalyze | PlanVerbose | PlanSettings | PlanBuffers | PlanWAL
  deriving (Eq, Show, Generic)
instance Hashable MTVndPlanOption

data MTVndPlanFormat
  = PlanJSON | PlanText
  deriving (Eq, Show, Generic)
instance Hashable MTVndPlanFormat

-- | Convert MediaType to a Content-Type HTTP Header
toContentType :: MediaType -> Header
toContentType ct = (hContentType, toMime ct <> charset)
  where
    charset = case ct of
      MTOctetStream -> mempty
      MTOther _     -> mempty
      _             -> "; charset=utf-8"

-- | Convert from MediaType to a ByteString representing the mime type
toMime :: MediaType -> ByteString
toMime MTApplicationJSON      = "application/json"
toMime MTVndArrayJSONStrip    = "application/vnd.pgrst.array+json;nulls=stripped"
toMime MTGeoJSON              = "application/geo+json"
toMime MTTextCSV              = "text/csv"
toMime MTTextPlain            = "text/plain"
toMime MTTextXML              = "text/xml"
toMime MTOpenAPI              = "application/openapi+json"
toMime (MTVndSingularJSON True)  = "application/vnd.pgrst.object+json;nulls=stripped"
toMime (MTVndSingularJSON False) = "application/vnd.pgrst.object+json"
toMime MTUrlEncoded           = "application/x-www-form-urlencoded"
toMime MTOctetStream          = "application/octet-stream"
toMime MTAny                  = "*/*"
toMime (MTOther ct)           = ct
toMime (MTVndPlan mt fmt opts)   =
  "application/vnd.pgrst.plan+" <> toMimePlanFormat fmt <>
  ("; for=\"" <> toMime mt <> "\"") <>
  (if null opts then mempty else "; options=" <> BS.intercalate "|" (toMimePlanOption <$> opts))

toMimePlanOption :: MTVndPlanOption -> ByteString
toMimePlanOption PlanAnalyze  = "analyze"
toMimePlanOption PlanVerbose  = "verbose"
toMimePlanOption PlanSettings = "settings"
toMimePlanOption PlanBuffers  = "buffers"
toMimePlanOption PlanWAL      = "wal"

toMimePlanFormat :: MTVndPlanFormat -> ByteString
toMimePlanFormat PlanJSON = "json"
toMimePlanFormat PlanText = "text"

-- | Convert from ByteString to MediaType.
--
-- >>> decodeMediaType "application/json"
-- MTApplicationJSON
--
-- >>> decodeMediaType "application/vnd.pgrst.plan;"
-- MTVndPlan MTApplicationJSON PlanText []
--
-- >>> decodeMediaType "application/vnd.pgrst.plan;for=\"application/json\""
-- MTVndPlan MTApplicationJSON PlanText []
--
-- >>> decodeMediaType "application/vnd.pgrst.plan+json;for=\"text/csv\""
-- MTVndPlan MTTextCSV PlanJSON []
--
-- >>> decodeMediaType "application/vnd.pgrst.array+json;nulls=stripped"
-- MTVndArrayJSONStrip
--
-- >>> decodeMediaType "application/vnd.pgrst.array+json"
-- MTApplicationJSON
--
-- >>> decodeMediaType "application/vnd.pgrst.object+json;nulls=stripped"
-- MTVndSingularJSON True
--
-- >>> decodeMediaType "application/vnd.pgrst.object+json"
-- MTVndSingularJSON False

decodeMediaType :: BS.ByteString -> MediaType
decodeMediaType mt =
  case BS.split (BS.c2w ';') mt of
    "application/json":_                     -> MTApplicationJSON
    "application/geo+json":_                 -> MTGeoJSON
    "text/csv":_                             -> MTTextCSV
    "text/plain":_                           -> MTTextPlain
    "text/xml":_                             -> MTTextXML
    "application/openapi+json":_             -> MTOpenAPI
    "application/x-www-form-urlencoded":_    -> MTUrlEncoded
    "application/octet-stream":_             -> MTOctetStream
    "application/vnd.pgrst.plan":rest        -> getPlan PlanText rest
    "application/vnd.pgrst.plan+text":rest   -> getPlan PlanText rest
    "application/vnd.pgrst.plan+json":rest   -> getPlan PlanJSON rest
    "application/vnd.pgrst.object+json":rest -> checkSingularNullStrip rest
    "application/vnd.pgrst.object":rest      -> checkSingularNullStrip rest
    "application/vnd.pgrst.array+json":rest  -> checkArrayNullStrip rest
    "application/vnd.pgrst.array":rest       -> checkArrayNullStrip rest
    "*/*":_                                  -> MTAny
    other:_                                  -> MTOther other
    _                                        -> MTAny
  where
    checkArrayNullStrip ["nulls=stripped"] = MTVndArrayJSONStrip
    checkArrayNullStrip  _                 = MTApplicationJSON

    checkSingularNullStrip ["nulls=stripped"] = MTVndSingularJSON True
    checkSingularNullStrip  _                 = MTVndSingularJSON False

    getPlan fmt rest =
      let
        opts         = BS.split (BS.c2w '|') $ fromMaybe mempty (BS.stripPrefix "options=" =<< find (BS.isPrefixOf "options=") rest)
        inOpts str   = str `elem` opts
        dropAround p = BS.dropWhile p . BS.dropWhileEnd p
        mtFor        = fromMaybe MTApplicationJSON $ do
          foundFor    <- find (BS.isPrefixOf "for=") rest
          strippedFor <- BS.stripPrefix "for=" foundFor
          pure . decodeMediaType $ dropAround (== BS.c2w '"') strippedFor
      in
      MTVndPlan mtFor fmt $
        [PlanAnalyze  | inOpts "analyze" ] ++
        [PlanVerbose  | inOpts "verbose" ] ++
        [PlanSettings | inOpts "settings"] ++
        [PlanBuffers  | inOpts "buffers" ] ++
        [PlanWAL      | inOpts "wal"     ]
